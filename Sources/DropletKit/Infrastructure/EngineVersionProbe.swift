import Foundation

/// Read-only version query with bounded output and lifetime. No synchronous
/// pipe read or process wait ever runs on the app's main thread.
@MainActor
final class EngineVersionProbe {
    private let environment: DownloadEnvironment
    private let executable: URL
    private var process: Process?
    private var pipe: Pipe?
    private var deadline: DispatchWorkItem?
    private var completion: ((String?) -> Void)?
    private var output = ""
    private var invalidOutput = false

    /// `executable` defaults to the active engine; the updater probes its staged copy.
    init(environment: DownloadEnvironment, executable: URL? = nil) {
        self.environment = environment
        self.executable = executable ?? environment.downloaderURL
    }

    func start(completion: @escaping (String?) -> Void) {
        guard process == nil else { return }
        self.completion = completion
        output = ""
        invalidOutput = false
        let child = environment.makeProcess()
        child.executableURL = executable
        child.environment = environment.processEnvironment
        child.arguments = ["--ignore-config", "--no-plugin-dirs", "--version"]
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        self.pipe = pipe
        self.process = child
        let coordinator = ProcessOutputCoordinator(onLines: { [weak self, weak child] lines in
            MainActor.assumeIsolated {
                guard let self, let child, self.process === child else { return }
                for line in lines {
                    if self.output.utf8.count + line.utf8.count > 256 { self.invalidOutput = true; continue }
                    self.output += line + "\n"
                }
            }
        }, onCompletion: { [weak self, weak child] error in
            MainActor.assumeIsolated {
                guard let self, let child, self.process === child else { return }
                let value = self.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let valid = error == nil && !self.invalidOutput && child.terminationStatus == 0
                    && !value.isEmpty && value.utf8.count <= 128
                    && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || ".-_+".unicodeScalars.contains($0) }
                self.finish(valid ? value : nil, stop: false)
            }
        })
        pipe.fileHandleForReading.readabilityHandler = { coordinator.read($0) }
        child.terminationHandler = { _ in coordinator.processExited() }
        do {
            try child.run()
            let work = DispatchWorkItem { [weak self, weak child] in
                guard let self, let child, self.process === child else { return }
                self.finish(nil, stop: true)
            }
            deadline = work
            environment.clock.scheduleOnMain(5, work)
        } catch { finish(nil, stop: false) }
    }

    func cancel() {
        completion = nil
        finish(nil, stop: true)
    }

    private func finish(_ version: String?, stop: Bool) {
        deadline?.cancel()
        deadline = nil
        if stop, let process {
            let children = environment.descendants(process.processIdentifier)
            let owned = OwnedProcessSnapshot(pids: [process.processIdentifier] + children,
                identify: environment.processIdentity, signal: environment.signal)
            if process.isRunning { process.terminate() }
            owned.send(SIGKILL)
        }
        process = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        let callback = completion
        completion = nil
        callback?(version)
    }
}
