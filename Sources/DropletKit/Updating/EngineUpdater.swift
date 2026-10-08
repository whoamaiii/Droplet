import Cocoa
import Combine

/// Updates yt-dlp without Homebrew and without touching the signed bundle:
/// a private copy is staged, updated by yt-dlp's own verified updater, and
/// installed only after it reports a valid version.
@MainActor
final class EngineUpdater: ObservableObject {
    @Published private(set) var updateNote = ""
    @Published private(set) var isUpdating = false
    /// The engine downloads should use after a verified update.
    @Published private(set) var installedEngine: URL?
    private var environment: DownloadEnvironment
    private var updateTask: Process?
    private var updatePipe: Pipe?
    private var staged: URL?
    private var versionProbe: EngineVersionProbe?
    private var deadline: DispatchWorkItem?
    private var dismiss: DispatchWorkItem?
    private var generation = 0
    private var cleanups: [OnceCleanup] = []

    init(environment: DownloadEnvironment) { self.environment = environment }

    func shutdown() {
        generation += 1
        deadline?.cancel()
        dismiss?.cancel()
        versionProbe?.cancel()
        versionProbe = nil
        stopUpdate()
        for cleanup in cleanups { cleanup.run() }
        cleanups.removeAll()
        discardStaged()
        updateNote = ""
        isUpdating = false
    }

    func updateDownloader() {
        guard updateTask == nil, versionProbe == nil else { return }
        generation += 1
        let token = generation
        dismiss?.cancel()
        deadline?.cancel()
        let staged: URL
        do { staged = try environment.engineStaging.prepareStaging(from: environment.downloaderURL) }
        catch EngineStagingError.unsupported {
            updateNote = "This development build uses Homebrew. Run: brew upgrade yt-dlp"
            scheduleDismiss(token: token)
            return
        } catch {
            updateNote = "Couldn't prepare the engine update. Check free disk space and try again."
            scheduleDismiss(token: token)
            return
        }
        self.staged = staged
        isUpdating = true
        updateNote = "Updating yt-dlp…"
        let process = environment.makeProcess()
        process.executableURL = staged
        process.arguments = ["--ignore-config", "--no-plugin-dirs", "--update-to", "stable"]
        process.environment = environment.processEnvironment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.updateTask === finished else { return }
                self.deadline?.cancel()
                self.deadline = nil
                self.updateTask = nil
                self.updatePipe?.fileHandleForReading.readabilityHandler = nil
                self.updatePipe = nil
                if finished.terminationStatus == 0 {
                    self.updateNote = "Checking engine version…"
                    let probe = EngineVersionProbe(environment: self.environment, executable: staged)
                    self.versionProbe = probe
                    probe.start { [weak self, weak probe] version in
                        guard let self, let probe, self.generation == token, self.versionProbe === probe else { return }
                        self.versionProbe = nil
                        self.isUpdating = false
                        self.finishInstall(version: version)
                        self.scheduleDismiss(token: token)
                    }
                } else {
                    self.isUpdating = false
                    self.discardStaged()
                    self.updateNote = "Engine update failed. Check your connection and try again later."
                    self.scheduleDismiss(token: token)
                }
            }
        }
        do {
            try process.run()
            updateTask = process
            updatePipe = pipe
            let timer = DispatchWorkItem { [weak self, weak process] in
                guard let self, let process, self.generation == token, self.updateTask === process else { return }
                self.stopUpdate()
                self.discardStaged()
                self.updateNote = "Engine update timed out after 15 minutes. Try again later."
                self.scheduleDismiss(token: token)
            }
            deadline = timer
            environment.clock.scheduleOnMain(900, timer)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            isUpdating = false
            discardStaged()
            updateNote = "Couldn't run the engine updater."
            scheduleDismiss(token: token)
        }
    }

    private func finishInstall(version: String?) {
        guard let staged else { return }
        self.staged = nil
        guard let version else {
            environment.engineStaging.discard(staged: staged)
            updateNote = "The update could not be verified, so it was not installed."
            return
        }
        do {
            let installed = try environment.engineStaging.install(staged: staged, version: version)
            environment.downloaderURL = installed
            installedEngine = installed
            updateNote = "yt-dlp \(version) ✓"
        } catch {
            environment.engineStaging.discard(staged: staged)
            updateNote = "The update could not be installed. Check free disk space and try again."
        }
    }

    private func discardStaged() {
        guard let staged else { return }
        self.staged = nil
        environment.engineStaging.discard(staged: staged)
    }

    private func scheduleDismiss(token: Int) {
        dismiss?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.updateTask == nil, self.versionProbe == nil else { return }
            self.updateNote = ""
        }
        dismiss = timer
        environment.clock.scheduleOnMain(8, timer)
    }

    private func stopUpdate() {
        isUpdating = false
        deadline?.cancel()
        deadline = nil
        guard let process = updateTask else { return }
        updateTask = nil
        updatePipe?.fileHandleForReading.readabilityHandler = nil
        updatePipe = nil
        let pid = process.processIdentifier
        let children = environment.descendants(pid)
        let owned = OwnedProcessSnapshot(pids: [pid] + children,
            identify: environment.processIdentity, signal: environment.signal)
        if process.isRunning { process.terminate() }
        let cleanup = OnceCleanup { owned.send(SIGKILL) }
        // Retain until shutdown so quitting cannot discard a pending hard kill.
        cleanups.append(cleanup)
        environment.clock.scheduleCleanup(1, DispatchWorkItem { cleanup.run() })
    }
}
