// Droplet: clipboard video downloads, with isolated process ownership.
import Cocoa
import Combine
import SwiftUI
import OSLog

@MainActor
final class DownloadManager: ObservableObject {
    enum Phase: Equatable { case idle, downloading, done, failed(String) }
    @Published var phase: Phase = .idle
    @Published var progress = 0.0
    @Published var title = ""
    @Published var clipboardURL: URL?
    @Published var retryNote = ""
    @Published var stageNote = ""
    @Published var updateNote = ""
    @Published var isUpdating = false
    @Published var isShuttingDown = false
    @Published var session = 0
    private(set) var downloadGeneration = UUID()
    let downloadsFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    private var request: DownloadRequest?
    private var failedURL: URL?
    private var activeCommand: ManagedCommand?
    private var commands: [UUID: ManagedCommand] = [:] // includes cancelled/retiring attempts
    private var firstError = ""
    private var output = DownloadOutput()
    private var updateGeneration = UUID()
    private var shutdownCompletion: (() -> Void)?

    static func readClipboardURL() -> URL? {
        guard let raw = NSPasteboard.general.string(forType: .string),
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }

    func beginSession() {
        session += 1
        if phase != .downloading {
            phase = .idle; progress = 0; title = ""; retryNote = ""; stageNote = ""
        }
        clipboardURL = Self.readClipboardURL()
        // request.url is immutable and is never refreshed from this clipboard.
    }

    func startDownload() { startDownload(url: clipboardURL ?? Self.readClipboardURL()) }

    func retryFromFailure() {
        guard case .failed = phase else { return }
        startDownload(url: failedURL ?? clipboardURL ?? Self.readClipboardURL())
    }

    private func startDownload(url: URL?) {
        guard phase != .downloading, !isUpdating, !isShuttingDown else { return }
        guard let url else {
            clipboardURL = nil; failedURL = nil
            phase = .failed("No video link found in your clipboard. Copy a video URL first.")
            return
        }
        failedURL = url
        guard let engine = EngineTools.find("yt-dlp", override: "DROPLET_YTDLP") else {
            phase = .failed("yt-dlp was not found. Install it with Homebrew (brew install yt-dlp ffmpeg), or set DROPLET_YTDLP to its absolute executable path.")
            return
        }
        guard let ffmpeg = EngineTools.find("ffmpeg", override: "DROPLET_FFMPEG") else {
            phase = .failed("ffmpeg was not found. Install it with brew install ffmpeg, or set DROPLET_FFMPEG to its absolute executable path.")
            return
        }
        do { try FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true) }
        catch { phase = .failed("Couldn't open Downloads: \(error.localizedDescription)"); return }
        clipboardURL = url
        let newRequest = DownloadRequest(url: url, executable: engine, ffmpeg: ffmpeg,
            attempts: DownloadPolicy.attempts(for: url, browsers: DownloadPolicy.installedCookieBrowsers()),
            outputTemplate: downloadsFolder.path + "/%(title).160B [%(extractor_key)s-%(id)s].%(ext)s")
        request = newRequest
        downloadGeneration = newRequest.id
        firstError = ""
        runAttempt(0, request: newRequest)
    }

    private func runAttempt(_ index: Int, request current: DownloadRequest) {
        guard !isShuttingDown, request?.id == current.id, index < current.attempts.count else { return }
        let attempt = current.attempts[index]
        phase = .downloading; progress = 0; title = ""
        retryNote = attempt.note; stageNote = "Fetching video…"
        output = DownloadOutput()
        let command = ManagedCommand()
        activeCommand = command // assign identity BEFORE spawning, including fast failures
        run(command, executable: current.executable,
            arguments: DownloadPolicy.arguments(for: current, attempt: attempt),
            onLines: { [weak self, weak command] lines in
                guard let self, let command, self.activeCommand === command,
                      self.request?.id == current.id else { return }
                for line in lines { self.output.consume(line) }
                self.progress = self.output.progress
                self.title = self.output.title
                self.stageNote = self.output.stage
            }, completion: { [weak self, weak command] result in
                guard let self, let command, self.activeCommand === command,
                      self.request?.id == current.id else { return }
                self.activeCommand = nil
                if result.cancelled { return }
                if result.status == 0 {
                    self.progress = 1; self.retryNote = ""; self.stageNote = ""
                    self.phase = .done
                    NSSound(named: "Tink")?.play()
                    return
                }
                let error = result.lastError.isEmpty ? "yt-dlp exited with status \(result.status)." : result.lastError
                if index == 0 { self.firstError = error }
                // A codec mismatch or failure to execute won't improve with cookies.
                let terminal = result.status == 127 || error.lowercased().contains("requested format is not available")
                if !terminal && index + 1 < current.attempts.count {
                    self.runAttempt(index + 1, request: current)
                    return
                }
                var message = self.firstError.isEmpty ? error : self.firstError
                if message.hasPrefix("ERROR:") { message = String(message.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                if let hint = DownloadPolicy.hint(for: message) { message += "\n\n" + hint }
                self.retryNote = ""; self.stageNote = ""
                self.phase = .failed(message)
                NSSound(named: "Basso")?.play()
            })
    }

    /// Every command is retained until its group is stopped, output drained and
    /// leader reaped, even after the UI immediately starts a new attempt.
    private func run(_ command: ManagedCommand, executable: URL, arguments: [String],
                     timeout: TimeInterval? = nil,
                     onLines: @escaping ([String]) -> Void = { _ in },
                     completion: @escaping (CommandResult) -> Void) {
        commands[command.id] = command
        command.start(executable: executable, arguments: arguments, environment: EngineTools.environment,
                      timeout: timeout, onLines: onLines) { [weak self] result in
            guard let self else { return }
            // Keep a strong local reference through completion's identity check.
            let retained = self.commands.removeValue(forKey: command.id)
            withExtendedLifetime(retained) {
                if !self.isShuttingDown { completion(result) }
            }
            self.finishShutdownIfReady()
        }
    }

    func cancel() {
        guard let command = activeCommand else { return }
        // Invalidate first: queued output, completion and timers become harmless.
        activeCommand = nil; request = nil; downloadGeneration = UUID()
        command.cancel()
        phase = .idle; progress = 0; retryNote = ""; stageNote = ""; title = ""
    }

    func updateDownloader() {
        guard !isUpdating, !isShuttingDown, phase != .downloading else { return }
        updateGeneration = UUID()
        let generation = updateGeneration
        guard let engine = EngineTools.find("yt-dlp", override: "DROPLET_YTDLP") else {
            updateNote = "yt-dlp not found. Install using brew install yt-dlp ffmpeg."
            return
        }
        guard let brew = EngineTools.find("brew", override: "DROPLET_BREW") else {
            updateNote = "No Homebrew found. Update yt-dlp with its original pip, pipx, or standalone installer."
            return
        }
        isUpdating = true
        updateNote = "Checking engine installation…"
        // Query the actual formula prefix instead of assuming that a PATH match
        // or the presence of brew means this yt-dlp is Homebrew-managed.
        run(ManagedCommand(), executable: brew, arguments: ["--prefix", "yt-dlp"], timeout: 30) { [weak self] result in
            guard let self, self.updateGeneration == generation else { return }
            guard result.status == 0,
                  let prefix = result.tail.last(where: { $0.hasPrefix("/") }),
                  EngineTools.isInside(engine, prefix: URL(fileURLWithPath: prefix)) else {
                self.isUpdating = false
                self.updateNote = "This yt-dlp is not managed by this Homebrew. Update it with its original installer (pip/pipx/standalone)."
                return
            }
            self.updateNote = "Updating yt-dlp…"
            self.run(ManagedCommand(), executable: brew, arguments: ["upgrade", "yt-dlp"], timeout: 600) { [weak self] result in
                guard let self, self.updateGeneration == generation else { return }
                guard result.status == 0 else {
                    self.isUpdating = false
                    self.updateNote = "Update failed: " + (result.lastError.isEmpty ? (result.tail.last ?? "brew exited with status \(result.status)") : result.lastError)
                    return
                }
                self.run(ManagedCommand(), executable: engine, arguments: ["--version"], timeout: 15) { [weak self] result in
                    guard let self, self.updateGeneration == generation else { return }
                    self.isUpdating = false
                    let version = result.status == 0 ? result.tail.last ?? "" : ""
                    self.updateNote = version.isEmpty ? "yt-dlp updated; version check unavailable." : "yt-dlp \(version) ✓"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                        guard let self, !self.isShuttingDown, self.updateGeneration == generation,
                              !self.isUpdating else { return }
                        self.updateNote = ""
                    }
                }
            }
        }
    }

    func shutdownForQuit(completion: @escaping () -> Void) {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        shutdownCompletion = completion
        activeCommand = nil; request = nil; downloadGeneration = UUID(); updateGeneration = UUID()
        phase = .idle; progress = 0; retryNote = ""; stageNote = ""; updateNote = ""; isUpdating = false
        for command in commands.values { command.cancel() }
        finishShutdownIfReady()
    }

    private func finishShutdownIfReady() {
        guard isShuttingDown, commands.isEmpty, let completion = shutdownCompletion else { return }
        shutdownCompletion = nil
        DispatchQueue.main.async(execute: completion)
    }
}

// MARK: - Visuals

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct DropletShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        guard w > 1, h > 1 else { return Path() }

        let y0 = h * 0.60      // top of the round belly
        let r = w * 0.5        // belly radius
        let k = 0.5523 * r     // cubic-circle approximation constant

        var p = Path()
        p.move(to: CGPoint(x: w * 0.5, y: 0))
        p.addQuadCurve(to: CGPoint(x: 0, y: y0),
                       control: CGPoint(x: w * 0.06, y: h * 0.26))
        p.addCurve(to: CGPoint(x: w * 0.5, y: y0 + r),
                   control1: CGPoint(x: 0, y: y0 + k),
                   control2: CGPoint(x: w * 0.5 - k, y: y0 + r))
        p.addCurve(to: CGPoint(x: w, y: y0),
                   control1: CGPoint(x: w * 0.5 + k, y: y0 + r),
                   control2: CGPoint(x: w, y: y0 + k))
        p.addQuadCurve(to: CGPoint(x: w * 0.5, y: 0),
                       control: CGPoint(x: w * 0.94, y: h * 0.26))
        p.closeSubpath()
        return p
    }
}

struct DropletHeader: View {
    @State private var droppedIn = false
    @State private var ripple = false
    @State private var bob = false

    var body: some View {
        ZStack {
            // ripple rings expanding after the drop lands
            Circle()
                .stroke(Color.cyan.opacity(ripple ? 0 : 0.55), lineWidth: 2)
                .frame(width: 34, height: 34)
                .scaleEffect(ripple ? 3.2 : 0.7)
                .animation(.easeOut(duration: 0.9).delay(0.35), value: ripple)

            Circle()
                .stroke(Color.blue.opacity(ripple ? 0 : 0.40), lineWidth: 1.5)
                .frame(width: 34, height: 34)
                .scaleEffect(ripple ? 2.4 : 0.7)
                .animation(.easeOut(duration: 0.9).delay(0.50), value: ripple)

            // the droplet itself: falls in with a springy bounce, then floats
            DropletShape()
                .fill(
                    LinearGradient(colors: [.cyan, .blue, .indigo],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 44, height: 56)
                .overlay(
                    Ellipse()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 9, height: 15)
                        .blur(radius: 1.5)
                        .offset(x: -10, y: 10)
                )
                .shadow(color: .blue.opacity(0.5), radius: 12, y: 5)
                .scaleEffect(droppedIn ? 1 : 0.8, anchor: .bottom)
                .offset(y: droppedIn ? 0 : -90)
                .animation(.spring(response: 0.55, dampingFraction: 0.6).delay(0.05), value: droppedIn)
                .offset(y: bob ? -3.5 : 3.5)
                .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true).delay(1.0), value: bob)
        }
        .frame(height: 96)
        .clipped()
        .padding(.top, 14)
        .onAppear {
            droppedIn = true
            ripple = true
            bob = true
        }
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Main bubble UI

struct MainView: View {
    @ObservedObject var manager: DownloadManager
    var onOpenDownloads: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DropletHeader()

            Text("Droplet")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .padding(.top, 2)

            Text("Clipboard → MP4 in your Downloads")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)

            Group {
                switch manager.phase {
                case .idle:           idleView
                case .downloading:    downloadingView
                case .done:           doneView
                case .failed(let message): failedView(message)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .frame(maxHeight: .infinity, alignment: .top)

            footer
        }
        .frame(width: 320, height: 420)
        .background(VisualEffectView())
        .id(manager.session)   // replays the droplet animation every time
    }

    // MARK: idle

    @ViewBuilder
    private var linkPreview: some View {
        if let url = manager.clipboardURL {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.host() ?? url.absoluteString)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(url.path.isEmpty ? "/" : url.path)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quinary))
        } else {
            HStack(spacing: 6) {
                Image(systemName: "clipboard")
                    .font(.system(size: 10, weight: .semibold))
                Text("Copy a video link — it shows up here")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.tertiary)
            .padding(.vertical, 6)
        }
    }

    private var idleView: some View {
        VStack(spacing: 14) {
            linkPreview

            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    manager.startDownload()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 14, weight: .bold))
                    Text(manager.clipboardURL == nil ? "Grab Link from Clipboard" : "Download")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    Capsule().fill(
                        LinearGradient(colors: [.cyan, .blue, .indigo],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                )
                .shadow(color: .blue.opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(manager.isUpdating || manager.isShuttingDown)

            // Quit cancels only processes owned by this Droplet instance.
            Button {
                onQuit()
            } label: {
                Label("Quit Droplet", systemImage: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(.quinary))
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, 2)
        }
    }

    // MARK: downloading

    private var downloadingView: some View {
        VStack(spacing: 14) {
            Text(manager.title.isEmpty ? "Fetching video…" : manager.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quinary)
                    Capsule()
                        .fill(LinearGradient(colors: [.cyan, .blue, .indigo],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(10, geo.size.width * manager.progress))
                }
            }
            .frame(height: 9)
            .animation(.linear(duration: 0.25), value: manager.progress)

            HStack(spacing: 10) {
                Text("≈\(Int(manager.progress * 100))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Button {
                    manager.cancel()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(manager.stageNote)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            if !manager.retryNote.isEmpty {
                Text(manager.retryNote)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 4)
    }

    // MARK: done

    private var doneView: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.green, .teal],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(.white)
            }
            .shadow(color: .green.opacity(0.45), radius: 12, y: 4)
            .transition(.scale(scale: 0.4).combined(with: .opacity))

            Text("Saved to Downloads")
                .font(.system(size: 15, weight: .bold))

            if !manager.title.isEmpty {
                Text(manager.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
            }

            Button {
                onOpenDownloads()
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.link)
        }
    }

    // MARK: failed

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.yellow.gradient)
            ScrollView {
            Text(message)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 150)
            Button {
                withAnimation { manager.retryFromFailure() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(
                        Capsule().fill(
                            LinearGradient(colors: [.orange, .red],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                    )
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button {
                onOpenDownloads()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("Open Downloads folder")
            .accessibilityLabel("Open Downloads folder")

            Spacer()

            if !manager.updateNote.isEmpty {
                Text(manager.updateNote)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(manager.updateNote)
                    .accessibilityLabel(manager.updateNote)
            } else {
                Text("yt-dlp · H.264 + AAC · MP4")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.quaternary)
            }

            Spacer()

            Button {
                manager.updateDownloader()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Update download engine (yt-dlp)")
            .accessibilityLabel("Update download engine")
            .disabled(manager.isUpdating || manager.phase == .downloading || manager.isShuttingDown)

            Button {
                onQuit()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Quit Droplet")
            .accessibilityLabel("Quit Droplet")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }
}

// MARK: - App delegate & bootstrap

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let manager = DownloadManager()
    private var phaseCancellable: AnyCancellable?
    private var lastCloseAt = Date.distantPast
    private var instanceLock: Int32 = -1
    private var autoClose: DispatchWorkItem?
    private var iconReset: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var quitting = false
    private var readyToQuit = false
    private static let logger = Logger(subsystem: "com.quentinthiessen.droplet", category: "lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Droplet")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            instanceLock = droplet_lock(directory.appendingPathComponent("instance.lock").path)
        } catch {
            showStartupError(error.localizedDescription)
            return
        }
        if instanceLock == -1 {
            let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.quentinthiessen.droplet")
                .first { $0.processIdentifier != getpid() }
            existing?.activate(options: [])
            // SuccessfulExit=false in the versioned agent means no respawn loop.
            // flock is atomic: two simultaneous launches cannot both lose.
            exit(0)
        }
        guard instanceLock >= 0 else {
            showStartupError("Couldn't acquire the instance lock: \(String(cString: strerror(errno)))")
            return
        }
        installTerminationSignals()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Droplet")
            button.action = #selector(togglePopover(_:)); button.target = self
            button.setAccessibilityLabel("Droplet: ready")
        }
        statusItem = item
        let root = MainView(manager: manager,
                            onOpenDownloads: { [weak self] in self?.openDownloads() },
                            onQuit: { [weak self] in self?.quitApp() })
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient; popover.animates = true; popover.delegate = self
        phaseCancellable = manager.$phase.receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.phaseDidChange(phase) }
        publishReadiness()
    }

    private func publishReadiness() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Droplet/running.plist")
        let state: [String: Any] = ["pid": Int(getpid()),
            "build": Bundle.main.object(forInfoDictionaryKey: "DropletBuildID") as? String ?? "development"]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0)
            try data.write(to: path, options: .atomic)
        } catch { Self.debugLog("Could not write readiness marker: \(error.localizedDescription)") }
    }

    private func showStartupError(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "Droplet couldn't start"
        alert.informativeText = detail
        alert.runModal()
        // A configuration failure must not create an automatic retry storm.
        exit(0)
    }

    static func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["DROPLET_DEBUG"] == "1" else { return }
        logger.debug("\(message, privacy: .private)")
    }

    private func phaseDidChange(_ phase: DownloadManager.Phase) {
        autoClose?.cancel(); autoClose = nil
        iconReset?.cancel(); iconReset = nil
        guard let button = statusItem?.button, !quitting else { return }
        switch phase {
        case .downloading:
            button.image = NSImage(systemSymbolName: "drop.circle.fill", accessibilityDescription: "Droplet: downloading")
            button.setAccessibilityLabel("Droplet: downloading")
            button.contentTintColor = .controlAccentColor
        case .done:
            button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Droplet: download complete")
            button.setAccessibilityLabel("Droplet: download complete")
            button.contentTintColor = .systemGreen
            let generation = manager.downloadGeneration
            let session = manager.session
            if popover.isShown {
                let close = DispatchWorkItem { [weak self] in
                    guard let self, !self.quitting, self.popover.isShown,
                          self.manager.phase == .done, self.manager.session == session,
                          self.manager.downloadGeneration == generation else { return }
                    self.popover.performClose(nil)
                }
                autoClose = close
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.9, execute: close)
            }
            let reset = DispatchWorkItem { [weak self] in
                guard let self, !self.quitting, self.manager.phase == .done,
                      self.manager.downloadGeneration == generation else { return }
                self.setBaseIcon()
            }
            iconReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: reset)
        case .failed:
            button.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "Droplet: download failed")
            button.setAccessibilityLabel("Droplet: download failed")
            button.contentTintColor = .systemOrange
        case .idle:
            setBaseIcon()
        }
    }

    private func setBaseIcon() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Droplet")
        button.setAccessibilityLabel("Droplet: ready")
        button.contentTintColor = nil
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard !quitting, let button = statusItem?.button else { return }
        autoClose?.cancel(); autoClose = nil
        if popover.isShown { popover.performClose(sender) }
        else if Date().timeIntervalSince(lastCloseAt) > 0.3 {
            manager.beginSession()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        lastCloseAt = Date()
        autoClose?.cancel(); autoClose = nil
    }

    private func openDownloads() { NSWorkspace.shared.open(manager.downloadsFolder) }
    private func quitApp() { NSApplication.shared.terminate(nil) }

    private func installTerminationSignals() {
        // launchctl bootout / rebuild SIGTERM follows the same async cleanup as
        // the Quit button. Spawned children get their default signal handlers.
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.quitApp() }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToQuit { return .terminateNow }
        if quitting { return .terminateLater }
        quitting = true
        autoClose?.cancel(); iconReset?.cancel()
        popover.performClose(nil)
        manager.shutdownForQuit { [weak self] in
            guard let self else { return }
            self.readyToQuit = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // The OS closes the lock descriptor at exit. Do not release it early while
    // a terminating instance could still own a menu item or child processes.
}

#if !DROPLET_TESTING
@main
struct DropletApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

#endif
