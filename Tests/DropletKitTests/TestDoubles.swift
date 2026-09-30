import Cocoa
@testable import DropletKit

final class FakeProcess: Process, @unchecked Sendable {
    let fakePID: Int32
    var fakeRunning = false
    var status: Int32 = 0
    var launchError: Error?
    var terminateCount = 0
    private var fakeExecutableURL: URL?
    private var fakeArguments: [String]?
    private var fakeEnvironment: [String: String]?
    private var fakeOutput: Any?
    private var fakeError: Any?
    private var fakeTerminationHandler: (@Sendable (Process) -> Void)?

    // Process is a Foundation class cluster. All accessed abstract properties
    // must be supplied by the fake, not forwarded to NSTask's abstract base.
    override var executableURL: URL? {
        get { fakeExecutableURL }
        set { fakeExecutableURL = newValue }
    }
    override var arguments: [String]? {
        get { fakeArguments }
        set { fakeArguments = newValue }
    }
    override var environment: [String: String]? {
        get { fakeEnvironment }
        set { fakeEnvironment = newValue }
    }
    override var standardOutput: Any? {
        get { fakeOutput }
        set { fakeOutput = newValue }
    }
    override var standardError: Any? {
        get { fakeError }
        set { fakeError = newValue }
    }
    override var terminationHandler: (@Sendable (Process) -> Void)? {
        get { fakeTerminationHandler }
        set { fakeTerminationHandler = newValue }
    }

    init(pid: Int32) { fakePID = pid; super.init() }
    override var isRunning: Bool { fakeRunning }
    override var processIdentifier: Int32 { fakePID }
    override var terminationStatus: Int32 { status }
    override func run() throws {
        if let launchError { throw launchError }
        fakeRunning = true
    }
    override func terminate() { terminateCount += 1 }

    func finish(status: Int32) {
        self.status = status
        fakeRunning = false
        terminationHandler?(self)
        if let pipe = standardOutput as? Pipe {
            let reader = pipe.fileHandleForReading
            let handler = reader.readabilityHandler
            reader.readabilityHandler = nil
            try? pipe.fileHandleForWriting.close()
            handler?(reader)
        }
    }

    /// Exercise the production pipe handler, then let the main queue deliver
    /// the event. Detaching first avoids two readers racing for the same bytes.
    func eventLine(_ fields: [String: Any]) -> String {
        let template = arguments!.first { $0.hasPrefix("download:DROPLET_") }!
        let marker = String(template.dropFirst("download:".count).prefix { $0 != "{" })
        var fields = fields
        if fields["event"] as? String == "result" {
            fields["extractor"] = fields["extractor"] ?? "fixture"
            fields["id"] = fields["id"] ?? "123"
            fields["audio_codecs"] = fields["audio_codecs"] ?? ["none"]
            fields["acodec"] = fields["acodec"] ?? "none"
        }
        return marker + String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
    }

    func enqueueOutput(_ text: String) {
        guard let pipe = standardOutput as? Pipe else { preconditionFailure("No output pipe") }
        let reader = pipe.fileHandleForReading
        let handler = reader.readabilityHandler
        reader.readabilityHandler = nil
        pipe.fileHandleForWriting.write(Data(text.utf8))
        handler?(reader)
        reader.readabilityHandler = handler
    }
}

final class TestClock {
    var date = Date(timeIntervalSince1970: 1_000)
    var mainActions: [(TimeInterval, DispatchWorkItem)] = []
    var cleanupActions: [(TimeInterval, DispatchWorkItem)] = []

    var runtime: RuntimeClock {
        RuntimeClock(
            now: { self.date },
            sleep: { self.date.addTimeInterval($0) },
            scheduleOnMain: { self.mainActions.append(($0, $1)) },
            scheduleCleanup: { self.cleanupActions.append(($0, $1)) }
        )
    }

    func runCleanup() {
        let actions = cleanupActions
        cleanupActions = []
        for (delay, work) in actions {
            date.addTimeInterval(delay)
            if !work.isCancelled { work.perform() }
        }
    }

    func runMain() {
        let actions = mainActions
        mainActions = []
        for (delay, work) in actions {
            date.addTimeInterval(delay)
            if !work.isCancelled { work.perform() }
        }
    }
}

@MainActor
final class DownloadHarness {
    let clock = TestClock()
    let folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    init() { try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
    deinit { try? FileManager.default.removeItem(at: folder) }
    var processes: [FakeProcess] = []
    var clipboard = URL(string: "https://example.invalid/original")!
    var signals: [(Int32, Int32)] = []
    var children: [Int32] = []
    var alive: Set<Int32> = []
    var launchError: Error?
    var identityGenerations: [Int32: Int] = [:]

    var environment: DownloadEnvironment {
        var environment = DownloadEnvironment.live
        environment.makeProcess = {
            let process = FakeProcess(pid: Int32(20_000 + self.processes.count))
            process.launchError = self.launchError
            self.processes.append(process)
            self.alive.insert(process.fakePID)
            return process
        }
        environment.readClipboardURL = { self.clipboard }
        environment.downloadsFolder = folder
        environment.descendants = { _ in self.children }
        environment.processIdentity = { pid in
            guard self.alive.contains(pid) else { return nil }
            return ProcessIdentity(pid: pid, seconds: self.identityGenerations[pid] ?? 1, microseconds: 0)
        }
        environment.signal = { pid, signal in
            self.signals.append((pid, signal))
            if signal == 0 { return self.alive.contains(pid) ? 0 : -1 }
            self.alive.remove(pid)
            return 0
        }
        environment.playSound = { _ in }
        environment.clock = clock.runtime
        return environment
    }
}

func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
