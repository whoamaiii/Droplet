import Cocoa
import Combine
import SwiftUI

@MainActor
final class DownloadManager: ObservableObject {

    enum Phase: Equatable {
        case idle
        case downloading
        case done
        case failed(String)
    }

    @Published var phase: Phase = .idle {
        didSet {
            if phase != .downloading, let job = trialJobID {
                do { try trialAccounting?.release(jobID: job) }
                catch { trialProblem = Self.trialStorageMessage }
                trialJobID = nil
                trialRemaining = trialAccounting?.remaining
            }
        }
    }
    @Published var progress: Double = 0
    @Published var stage: DownloadStage = .fetching
    @Published var progressKnown = false
    @Published private(set) var result: DownloadResult?
    private var reportedFinalPath: String?
    private var reportedIdentity: VideoIdentity?
    private var sourceHasAudio = false
    private var activeWorkspace: DownloadWorkspace?
    private var completionTask: Task<Void, Never>?
    private var validationWorkspaces: [Int: DownloadWorkspace] = [:]
    private var outputMalformed = false
    @Published var title: String = ""
    @Published var clipboardURL: URL?
    /// Shown in the bubble while a fallback attempt is running.
    @Published var retryNote: String = ""
    /// Status text for the "update download engine" action.
    @Published var updateNote: String = ""
    /// Bumps every time the bubble opens → the whole UI is re-created so the
    /// droplet entrance animation replays.
    @Published var session = 0

    @Published private(set) var downloadsFolder: URL
    @Published private(set) var destinationProblem: String?
    private var environment: DownloadEnvironment
    private let updater: EngineUpdater
    private var updateObservation: AnyCancellable?
    private var updatingObservation: AnyCancellable?
    private var engineObservation: AnyCancellable?
    @Published private(set) var isUpdating = false
    private var authenticationFailure = false

    @Published private(set) var trialRemaining: Int?
    @Published private(set) var trialProblem: String?
    var trialExhausted: Bool { trialRemaining == 0 }
    /// Paid access bypasses the trial entirely. Supplied by the license controller.
    var isLicensed: () -> Bool = { false }
    /// Whether this build can sell a license (store configured).
    var purchaseAvailable = false
    /// True while the visible failure is the trial limit (not some other
    /// failure that happens after the trial), so the bubble can offer
    /// Buy / Enter key instead of a pointless retry.
    var needsLicense: Bool {
        guard case .failed(let message) = phase else { return false }
        return message == trialLimitMessage && !isLicensed()
    }
    private var trialLimitMessage: String {
        purchaseAvailable
            ? "Your three free downloads are used. Buy Droplet or enter your license key to keep downloading."
            : "Your three free downloads are complete. Paid activation is not available in this build."
    }
    private let trialAccounting: (any TrialAccounting)?
    private var trialJobID: UUID?
    private static let trialStorageMessage = "Droplet could not safely save your free download count. Any video already saved remains available. Restore access to your previous download folder, check Application Support permissions, then restart Droplet before downloading again."

    convenience init() { self.init(environment: .live, trialStore: TrialFileStore.live) }

    convenience init(environment: DownloadEnvironment, trialStore: any StateStore) {
        do { self.init(environment: environment, trialAccounting: try PersistentTrialAccounting(store: trialStore)) }
        catch {
            self.init(environment: environment)
            trialProblem = Self.trialStorageMessage
        }
    }

    init(environment: DownloadEnvironment, updater: EngineUpdater? = nil, trialAccounting: (any TrialAccounting)? = nil) {
        self.trialAccounting = trialAccounting
        self.trialRemaining = trialAccounting?.remaining
        self.environment = environment
        self.downloadsFolder = environment.downloadsFolder
        self.updater = updater ?? EngineUpdater(environment: environment)
        updateObservation = self.updater.$updateNote.sink { [weak self] in self?.updateNote = $0 }
        updatingObservation = self.updater.$isUpdating.sink { [weak self] in self?.isUpdating = $0 }
        // A verified engine update applies to the next download.
        engineObservation = self.updater.$installedEngine.sink { [weak self] url in
            if let url { self?.environment.downloaderURL = url }
        }
    }

    func restoreDownloadsFolder(from store: DownloadFolderStore) {
        guard phase != .downloading else { return }
        do {
            if let url = try store.load() { downloadsFolder = url }
            destinationProblem = nil
        } catch {
            destinationProblem = "Your saved download folder is unavailable. Choose a folder in Settings to continue."
        }
    }

    func chooseDownloadsFolder(_ url: URL, store: DownloadFolderStore) throws {
        guard phase != .downloading else { throw CocoaError(.fileWriteUnknown) }
        try store.save(url)
        downloadsFolder = url
        destinationProblem = nil
    }

    private var task: Process?
    private var watchdog: DispatchWorkItem?
    private var attemptStarted = Date.distantPast
    private var lastActivity = Date.distantPast
    private var lastTransferRecord: String?

    /// Read end of the running process's pipe, so its output handler can be
    /// detached the moment the process is cancelled or superseded.
    private var taskPipe: Pipe?
    /// Identifies the currently live yt-dlp run. Cancelling, starting a new
    /// download and advancing the retry ladder all bump it, so a callback from
    /// a superseded process — `terminationHandler` can fire up to a second
    /// after `cancel()` returns — is recognised as stale and dropped instead
    /// of overwriting the state of the run that replaced it.
    private var runToken = 0
    /// The URL captured when the download started. The retry ladder keeps
    /// using it even if the clipboard changes mid-download.
    private var activeURL: URL?
    private var lastErrorLine = ""

    /// One download attempt: a note shown in the UI plus extra yt-dlp args.
    private struct Attempt {
        let note: String
        let extra: [String]
    }
    private var attempts: [Attempt] = []
    private var attemptIndex = 0
    private var isCancelled = false
    /// Error from the very first attempt — what the user is told at the end.
    private var firstErrorLine = ""

    func beginSession() {
        session += 1
        if case .failed = phase { return } // Preserve explicit retry/new-link choice when reopening.
        if phase == .done { return } // Keep saved-file actions until the user chooses a new link.
        if phase != .downloading {
            phase = .idle
            progress = 0
            title = ""
        }
        clipboardURL = environment.readClipboardURL()
    }

    /// False in development builds that use Homebrew instead of bundled helpers.
    var engineIsBundled: Bool { environment.engine.isBundled }

    var canRetry: Bool {
        if case .failed = phase { return activeURL != nil }
        return false
    }

    func retryFromFailure() {
        guard case .failed = phase, let url = activeURL else { return }
        // A previous browser approval never silently carries into a retry.
        beginDownload(url: url, consent: nil)
    }

    func useNewClipboardLink() {
        guard phase != .downloading else { return }
        activeURL = nil
        result = nil
        title = ""
        progress = 0
        clipboardURL = environment.readClipboardURL().flatMap { DownloadURLPolicy.parse($0.absoluteString) }
        phase = clipboardURL == nil
            ? .failed("No valid video link found. Copy an HTTP or HTTPS link, then choose Use new clipboard link.")
            : .idle
    }

    static func readClipboardURL() -> URL? {
        NSPasteboard.general.string(forType: .string).flatMap(DownloadURLPolicy.parse)
    }

    var browserLoginURL: URL? {
        guard case .failed = phase, authenticationFailure else { return nil }
        return activeURL
    }

    func startDownload() {
        guard phase != .downloading else { return }
        guard let url = clipboardURL ?? environment.readClipboardURL() else {
            clipboardURL = nil
            phase = .failed("No video link found in your clipboard.\nCopy a video URL, then choose Use new clipboard link.")
            return
        }
        beginDownload(url: url, consent: nil)
    }

    func startDownload(using consent: BrowserLoginConsent) {
        guard phase != .downloading else { return }
        beginDownload(url: consent.sourceURL, consent: consent)
    }

    private func beginDownload(url: URL, consent: BrowserLoginConsent?) {
        authenticationFailure = false
        guard let validated = DownloadURLPolicy.parse(url.absoluteString) else {
            activeURL = nil
            phase = .failed("Invalid video link. Use an HTTP or HTTPS URL without embedded account credentials.")
            return
        }
        clipboardURL = validated
        activeURL = validated          // the ladder must not follow a clipboard change

        // Pre-flight failures keep the validated link so the explicit Try Again
        // action the messages point to is actually available afterwards.
        guard !isUpdating else {
            phase = .failed("The download engine is updating. Wait for the update to finish, then try again.")
            return
        }
        let licensed = isLicensed()
        if !licensed, let trialProblem { phase = .failed(trialProblem); return }
        if !licensed, trialExhausted {
            phase = .failed(trialLimitMessage)
            return
        }
        if let destinationProblem {
            phase = .failed(destinationProblem)
            return
        }

        if !licensed, let trialAccounting {
            let job = UUID()
            do { try trialAccounting.reserve(jobID: job); trialJobID = job }
            catch {
                trialProblem = Self.trialStorageMessage
                phase = .failed(trialProblem!)
                return
            }
        }
        isCancelled = false
        result = nil
        firstErrorLine = ""
        attempts = Self.makeAttempts(for: validated, consent: consent)
        runAttempt(0)
    }

    /// Public attempts never discover or read browser profiles. Consent grants
    /// one browser/profile to one run, with no fallback to another profile.
    private static func makeAttempts(for url: URL, consent: BrowserLoginConsent?) -> [Attempt] {
        if let consent {
            return [Attempt(note: "Using \(consent.browser.title) login for this download…", extra: consent.arguments)]
        }
        let noCookies = ["--no-cookies", "--no-cookies-from-browser"]
        var ladder = [Attempt(note: "", extra: noCookies)]
        if DownloadURLPolicy.isYouTube(url) {
            ladder.append(Attempt(note: "Retrying with an alternate YouTube client…",
                extra: noCookies + ["--extractor-args", "youtube:player_client=default,web_safari,tv,ios"]))
        }
        return ladder
    }

    /// Runs attempt number `index` of the ladder. On failure it automatically
    /// advances to the next workaround; only the last one reports an error.
    private func runAttempt(_ index: Int) {
        guard let url = activeURL, index < attempts.count else { return }
        attemptIndex = index
        runToken &+= 1
        let token = runToken     // stamped into this process's callbacks
        let attempt = attempts[index]
        watchdog?.cancel()
        attemptStarted = environment.clock.now()
        lastActivity = attemptStarted
        lastTransferRecord = nil

        phase = .downloading
        progress = 0
        stage = .fetching
        progressKnown = false
        reportedFinalPath = nil
        reportedIdentity = nil
        sourceHasAudio = false
        outputMalformed = false
        lastErrorLine = ""
        retryNote = attempt.note
        if index == 0 { title = "" }
        DropletLog.debug("attempt \(index + 1)/\(attempts.count): \(attempt.note.isEmpty ? "base" : attempt.note)")

        let workspace: DownloadWorkspace
        do { workspace = try environment.makeWorkspace(downloadsFolder) }
        catch {
            phase = .failed(DownloadFinalizer.message(for: error))
            return
        }
        activeWorkspace = workspace
        let outputProtocol = DownloadOutputProtocol()
        let process = environment.makeProcess()
        process.executableURL = environment.downloaderURL
        process.environment = environment.processEnvironment
        // Built in steps: one long `+` chain is too slow for the Swift 6 type checker.
        var arguments: [String] = [
            "--ignore-config", "--no-plugin-dirs",
            "--newline",
            "--no-playlist",
            "--no-warnings",
            "--no-mtime",
            "--ffmpeg-location", environment.ffmpegDirectory.path,
            "--socket-timeout", "15",
            "--retries", "2",
            "--fragment-retries", "2",
            "--extractor-retries", "2",
            "--retry-sleep", "1",
            // yt-dlp's maintained per-site headers are used as-is; a fixed
            // browser user agent ages and breaks client-specific requests.
            "-f", DownloadFormatPolicy.selector,
            "--merge-output-format", "mp4",
            "-o", workspace.outputTemplate,
        ]
        if let runtime = environment.jsRuntimeURL {
            arguments += ["--js-runtimes", "deno:" + runtime.path]
        }
        arguments += outputProtocol.arguments
        arguments += attempt.extra
        arguments.append(url.absoluteString)
        process.arguments = arguments

        let pipe = Pipe()
        // Never the terminal: yt-dlp and FFmpeg would be stopped (SIGTTIN)
        // if Droplet was started from a shell and they tried to read it.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe

        let output = ProcessOutputCoordinator(onLines: { [weak self, weak process] lines in
            MainActor.assumeIsolated {
                guard let self, self.runToken == token, self.task === process else { return }
                for line in lines {
                    guard let event = outputProtocol.parse(line) else { continue }
                    switch event {
                    case let .transfer(stage, fraction, title):
                        // The record includes downloaded bytes, even when total
                        // size is unknown. Repeated identical progress is not activity.
                        if self.lastTransferRecord != line {
                            self.lastActivity = self.environment.clock.now()
                            self.lastTransferRecord = line
                        }
                        self.stage = stage
                        self.progressKnown = fraction != nil
                        self.progress = fraction ?? 0
                        if let title { self.title = title }
                    case let .processing(stage, title):
                        if self.stage != stage { self.lastActivity = self.environment.clock.now() }
                        self.stage = stage
                        self.progressKnown = false
                        self.progress = 0
                        if let title { self.title = title }
                    case let .result(path, title, identity, sourceHasAudio):
                        self.lastActivity = self.environment.clock.now()
                        self.sourceHasAudio = sourceHasAudio
                        self.reportedIdentity = identity
                        self.reportedFinalPath = path
                        self.stage = .finalizing
                        self.progressKnown = false
                        if let title { self.title = title }
                    case let .error(message): self.lastErrorLine = message
                    case .malformed: self.outputMalformed = true
                    }
                }
            }
        }, onCompletion: { [weak self, weak process] framingError in
            MainActor.assumeIsolated {
                guard let finished = process else { return }
                // `cancel()` clears `task` immediately but this handler can fire
                // up to a second later (SIGTERM → SIGKILL fallback). Without
                // this check a stale exit would wipe the *new* download's
                // process reference and flip the UI back to idle underneath it.
                guard let self, self.runToken == token, self.task === finished else {
                    try? workspace.remove()
                    return
                }
                self.watchdog?.cancel()
                self.watchdog = nil
                self.task = nil
                self.activeWorkspace = nil
                self.taskPipe = nil

                if self.isCancelled {
                    try? workspace.remove()
                    self.phase = .idle
                    self.progress = 0
                    self.retryNote = ""
                    return
                }

                if framingError != nil {
                    try? workspace.remove()
                    self.retryNote = ""
                    self.phase = .failed("The download engine sent an oversized output record. Please try again.")
                    return
                }

                if finished.terminationStatus == 0 {
                    self.retryNote = ""
                    guard !self.outputMalformed, self.lastErrorLine.isEmpty,
                          let path = self.reportedFinalPath, let identity = self.reportedIdentity else {
                        try? workspace.remove()
                        self.phase = .failed("The engine finished without a valid output record. Please try again.")
                        return
                    }
                    self.finishDownload(workspace: workspace, path: URL(fileURLWithPath: path),
                                        source: url, identity: identity, title: self.title, expectsAudio: self.sourceHasAudio, token: token)
                    return
                }
                try? workspace.remove()

                if finished.terminationStatus == 15 {
                    // cancelled by the user — go quietly back to idle
                    self.phase = .idle
                    self.progress = 0
                    self.retryNote = ""
                    return
                }

                // failed → silently advance to the next workaround, if any
                let next = self.attemptIndex + 1
                if DownloadFailure.classify(self.lastErrorLine).retryable && next < self.attempts.count {
                    if self.attemptIndex == 0 { self.firstErrorLine = self.lastErrorLine }
                    self.title = ""
                    self.runAttempt(next)
                    return
                }

                // report the ORIGINAL failure (not an incidental fallback error)
                var message = self.firstErrorLine.isEmpty ? self.lastErrorLine : self.firstErrorLine
                if message.hasPrefix("ERROR:") {
                    message = String(message.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                }
                if message.isEmpty {
                    message = "yt-dlp exited with status \(finished.terminationStatus)."
                }
                self.authenticationFailure = DownloadFailure.classify(message) == .authentication
                switch DownloadFailure.classify(message) {
                case .network: message = "Could not reach the video service. Check your connection and try this link again later."
                case .disk: message = "The video could not be saved because the disk is full or read-only. Free space or check your Downloads folder before trying again."
                case .permission: message = "Access was denied. Check that Droplet can write to Downloads and that the selected source is accessible."
                case .authentication: message = "This source requires sign-in or a human check. Open the original page to confirm access. Browser login is optional for this download."
                case .source: message = "This video or format is unavailable, unsupported or blocked by the site. Check the original page or use another video link."
                default:
                    message = String(message.prefix(400))
                    if let hint = Self.hint(for: message) { message += "\n\n" + hint }
                }
                self.retryNote = ""
                self.phase = .failed(message)
                self.environment.playSound("Basso")
            }
        })
        pipe.fileHandleForReading.readabilityHandler = { handle in output.read(handle) }
        process.terminationHandler = { _ in output.processExited() }

        do {
            try process.run()
            task = process
            taskPipe = pipe
            scheduleWatchdog(token: token)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            activeWorkspace = nil
            try? workspace.remove()
            retryNote = ""
            switch DownloadFailure.launch(error) {
            case .missingEngine: phase = .failed("The download engine is missing. Repair or reinstall Droplet before trying again.")
            case .permission: phase = .failed("macOS could not run the download engine. Check the app installation and permissions.")
            default: phase = .failed("Couldn't launch the download engine: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleWatchdog(token: Int) {
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.runToken == token, self.task != nil else { return }
            let now = self.environment.clock.now()
            let idleLimit: TimeInterval
            switch self.stage {
            case .fetching: idleLimit = 120
            case .video, .audio, .media: idleLimit = 300
            case .merging, .processing, .finalizing: idleLimit = 1800
            }
            let totalExpired = now.timeIntervalSince(self.attemptStarted) >= 6 * 60 * 60
            if totalExpired || now.timeIntervalSince(self.lastActivity) >= idleLimit {
                let original = self.activeURL
                self.cancel()
                self.activeURL = original
                self.phase = .failed(totalExpired
                    ? "The download exceeded the six-hour limit and was stopped. You can try the same link again."
                    : "The download engine stopped making progress and was stopped. Check your connection or available disk space, then try again.")
                return
            }
            self.scheduleWatchdog(token: token)
        }
        watchdog = check
        environment.clock.scheduleOnMain(10, check)
    }

    private func finishDownload(workspace: DownloadWorkspace, path: URL, source: URL,
                                identity: VideoIdentity, title: String, expectsAudio: Bool, token: Int) {
        stage = .finalizing
        progressKnown = false
        let verify = environment.verifyMedia
        validationWorkspaces[token] = workspace
        completionTask = Task { [weak self] in
            defer {
                try? workspace.remove()
                self?.validationWorkspaces.removeValue(forKey: token)
            }
            do {
                let finalizer = DownloadFinalizer()
                let prepared = try await finalizer.prepare(workspace: workspace, reported: path,
                    source: source, identity: identity, title: title, expectsAudio: expectsAudio, verify: verify)
                try Task.checkCancellation()
                guard let self, self.runToken == token else { return }
                // No await between final identity check, publication and state.
                if let job = self.trialJobID {
                    do { try self.trialAccounting?.preparePublication(jobID: job, stagedFile: path, destination: workspace.destination) }
                    catch {
                        self.trialProblem = Self.trialStorageMessage
                        self.completionTask = nil
                        self.phase = .failed(Self.trialStorageMessage)
                        return
                    }
                }
                let result = try finalizer.commit(prepared, workspace: workspace)
                if let job = self.trialJobID {
                    do {
                        try self.trialAccounting?.complete(jobID: job, result: result)
                        self.trialJobID = nil
                    } catch {
                        // Publication succeeded: retain the real result. The
                        // persisted witness recovers credit after restart.
                        self.trialProblem = Self.trialStorageMessage
                    }
                    self.trialRemaining = self.trialAccounting?.remaining
                }
                self.result = result
                self.progress = 1
                self.phase = .done
                self.completionTask = nil
                self.environment.playSound("Tink")
            } catch {
                guard let self, self.runToken == token else { return }
                self.completionTask = nil
                self.phase = .failed(DownloadFinalizer.message(for: error))
            }
        }
    }

    /// Turns cryptic yt-dlp failures into something actionable.
    private static func hint(for message: String) -> String? {
        let lower = message.lowercased()
        switch DownloadFailure.classify(message) {
        case .disk: return "Free some space or choose a writable disk before trying again."
        case .permission: return "Check that Droplet can write to your Downloads folder."
        case .network: return "Check your connection and try this link again later."
        default: break
        }
        if lower.contains("sign in to confirm") || lower.contains("not a bot") || lower.contains("captcha") {
            return "The site is asking for a human check. Open the original page to confirm access. Browser login is optional and requires your approval for this download."
        }
        if lower.contains("403") || lower.contains("forbidden") {
            return "The site blocked the download. Check that the original link still works. Some sites do not allow downloading; signing in may not resolve this."
        }
        if lower.contains("private") || lower.contains("login") || lower.contains("members") {
            return "This video requires a signed-in session. You can choose browser login for this download, or use a publicly accessible video link."
        }
        if lower.contains("not available") || lower.contains("unavailable") || lower.contains("removed") {
            return "The video may be region-locked or deleted."
        }
        return nil
    }

    private var pendingCleanups: [UUID: OnceCleanup] = [:]
    func updateDownloader() {
        guard phase != .downloading else { return }
        updater.updateDownloader()
    }

    /// Soft-cancel (Cancel button): SIGTERM now, SIGKILL fallback in 1s.
    func cancel() {
        watchdog?.cancel()
        watchdog = nil
        guard task != nil || completionTask != nil else { return }
        let process = task
        let workspace = activeWorkspace
        activeWorkspace = nil
        completionTask?.cancel()
        completionTask = nil
        // Everything this process reports from here on is stale.
        runToken &+= 1
        task = nil
        taskPipe?.fileHandleForReading.readabilityHandler = nil
        taskPipe = nil
        activeURL = nil
        isCancelled = true
        phase = .idle
        progress = 0
        retryNote = ""
        guard let process else { return }
        let pid = process.processIdentifier
        // Snapshot the children (ffmpeg, …) now: if yt-dlp has to be hard-killed
        // it never gets to clean them up, and once it dies they reparent to
        // launchd and can no longer be found by walking down from our own PID.
        let children = environment.descendants(pid)
        let owned = OwnedProcessSnapshot(pids: [pid] + children,
            identify: environment.processIdentity, signal: environment.signal)
        process.terminate()   // Original Process object owns the immediate graceful signal.
        let cleanup = OnceCleanup {
            owned.send(SIGKILL)
            try? workspace?.remove()
        }
        let cleanupID = UUID()
        pendingCleanups[cleanupID] = cleanup
        let timer = DispatchWorkItem { [weak self] in
            cleanup.run()
            DispatchQueue.main.async { self?.pendingCleanups.removeValue(forKey: cleanupID) }
        }
        environment.clock.scheduleCleanup(1.0, timer)
    }

    /// Called when the user quits: guaranteed total shutdown.
    /// Kills the running download by polling the process directly — no
    /// waitUntilExit (its exit callback needs the main thread, which would
    /// deadlock the quit path) — so nothing can hang the shutdown.
    func shutdownForQuit() {
        if let job = trialJobID {
            do { try trialAccounting?.release(jobID: job) }
            catch { trialProblem = Self.trialStorageMessage }
            trialJobID = nil
            trialRemaining = trialAccounting?.remaining
        }
        watchdog?.cancel()
        watchdog = nil
        // A prior Cancel already detached its process. Flush every pending
        // cleanup rather than cancelling the only route to those jobs.
        for cleanup in pendingCleanups.values { cleanup.run() }
        pendingCleanups.removeAll()

        updater.shutdown()
        updateNote = ""
        if completionTask != nil {
            runToken &+= 1
            completionTask?.cancel()
            completionTask = nil
            phase = .idle
        }
        for workspace in validationWorkspaces.values { try? workspace.remove() }
        validationWorkspaces.removeAll()
        let workspace = activeWorkspace
        activeWorkspace = nil
        defer { try? workspace?.remove() }

        guard let process = task else { return }
        runToken &+= 1
        task = nil
        taskPipe?.fileHandleForReading.readabilityHandler = nil
        taskPipe = nil
        activeURL = nil
        isCancelled = true
        phase = .idle
        progress = 0
        retryNote = ""

        let pid = process.processIdentifier
        // Snapshot yt-dlp's children before killing it — afterwards they
        // reparent to launchd and are no longer reachable from our PID.
        let children = environment.descendants(pid)
        let owned = OwnedProcessSnapshot(pids: [pid] + children,
            identify: environment.processIdentity, signal: environment.signal)
        process.terminate()
        let deadline = environment.clock.now().addingTimeInterval(0.5)
        while environment.clock.now() < deadline && owned.hasLiveMember {
            environment.clock.sleep(0.02)
        }
        owned.send(SIGKILL)
    }

    /// Belt-and-suspenders: kill anything still running that *this app*
    /// spawned — yt-dlp, the ffmpeg workers it started, brew — so quitting
    /// leaves nothing of ours behind.
    ///
    /// This deliberately walks our own process tree instead of running
    /// `pkill -f ffmpeg`: a name match would also kill the ffmpeg of every
    /// other app on the Mac (screen recorders, transcoders, the user's own
    /// terminal jobs), destroying unrelated work on quit.
    func sweepBackgroundProcesses() {
        let mine = environment.descendants(getpid())
        guard !mine.isEmpty else { return }

        let owned = OwnedProcessSnapshot(pids: mine,
            identify: environment.processIdentity, signal: environment.signal)
        owned.send(SIGTERM)
        environment.clock.sleep(0.2)
        owned.send(SIGKILL)
    }
}
