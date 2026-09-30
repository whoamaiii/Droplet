import Cocoa
import Combine

/// Development updater; customer engine delivery replaces Homebrew in WHO-238.
@MainActor
final class EngineUpdater: ObservableObject {
    @Published private(set) var updateNote = ""
    @Published private(set) var isUpdating = false
    private let environment: DownloadEnvironment
    private var updateTask: Process?
    private var updatePipe: Pipe?
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
        updateNote = ""
        isUpdating = false
    }

    func updateDownloader() {
        guard updateTask == nil, versionProbe == nil else { return }
        generation += 1
        let token = generation
        dismiss?.cancel()
        deadline?.cancel()
        isUpdating = true
        updateNote = "Updating yt-dlp…"
        let process = environment.makeProcess()
        process.executableURL = environment.brewURL
        process.arguments = ["upgrade", "yt-dlp"]
        var env = environment.processEnvironment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = env
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
                    let probe = EngineVersionProbe(environment: self.environment)
                    self.versionProbe = probe
                    probe.start { [weak self, weak probe] version in
                        guard let self, let probe, self.generation == token, self.versionProbe === probe else { return }
                        self.versionProbe = nil
                        self.isUpdating = false
                        self.updateNote = version.map { "yt-dlp \($0) ✓" } ?? "Update finished; version check unavailable."
                        self.scheduleDismiss(token: token)
                    }
                } else {
                    self.isUpdating = false
                    self.updateNote = "Update failed — try: brew upgrade yt-dlp"
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
                self.updateNote = "Engine update timed out after 15 minutes. Try again later."
                self.scheduleDismiss(token: token)
            }
            deadline = timer
            environment.clock.scheduleOnMain(900, timer)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            isUpdating = false
            updateNote = "Couldn't run the engine updater."
            scheduleDismiss(token: token)
        }
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
