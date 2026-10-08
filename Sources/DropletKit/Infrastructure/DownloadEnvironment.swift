import Cocoa

/// All external effects of the existing engine. Tests supply private processes,
/// clipboard values and a virtual clock; they never inspect real browser data.
@MainActor
struct DownloadEnvironment {
    var makeWorkspace: (URL) throws -> DownloadWorkspace = { try DownloadWorkspace(destination: $0) }
    var verifyMedia: @Sendable (URL) async throws -> VerifiedMedia = { try await MediaVerifier().verify($0) }
    var makeProcess: () -> Process = { Process() }
    var readClipboardURL: () -> URL? = { DownloadManager.readClipboardURL() }
    var downloadsFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    /// Bundled helpers in customer builds; Homebrew only in development builds.
    var engine = EngineLocator.live
    var downloaderURL: URL {
        get { engine.downloader }
        set { engine.downloader = newValue }
    }
    var ffmpegDirectory: URL {
        get { engine.ffmpegDirectory }
        set { engine.ffmpegDirectory = newValue }
    }
    var jsRuntimeURL: URL? {
        get { engine.jsRuntime }
        set { engine.jsRuntime = newValue }
    }
    var processEnvironment: [String: String] {
        EngineProcessEnvironment.make(home: FileManager.default.homeDirectoryForCurrentUser,
            temporary: FileManager.default.temporaryDirectory, engine: downloaderURL, ffmpeg: ffmpegDirectory)
    }
    var engineStaging: any EngineStaging = UpdatedEngineStore.live
    var descendants: (pid_t) -> [pid_t] = { ProcessInspector.descendantPIDs(of: $0) }
    var processIdentity: (pid_t) -> ProcessIdentity? = { ProcessInspector.identity(of: $0) }
    var signal: (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }
    var playSound: (String) -> Void = { NSSound(named: $0)?.play() }
    var clock = RuntimeClock.live

    static var live: Self { Self() }
}

struct RuntimeClock {
    var now: () -> Date
    var sleep: (TimeInterval) -> Void
    var scheduleOnMain: (TimeInterval, DispatchWorkItem) -> Void
    var scheduleCleanup: (TimeInterval, DispatchWorkItem) -> Void

    static var live: Self {
        Self(
            now: { Date() },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            scheduleOnMain: { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) },
            scheduleCleanup: { delay, action in DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: action) }
        )
    }
}

enum DropletLog {
    static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["DROPLET_DEBUG"] == "1" else { return }
        print("[droplet] \(message)")
        fflush(stdout)
    }
}
