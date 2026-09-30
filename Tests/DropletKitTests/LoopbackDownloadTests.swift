import Foundation
@testable import DropletKit

struct LoopbackDownloadTests {
    @MainActor
    func run(urlText: String, rootPath: String) async throws {
        guard let url = URL(string: urlText), url.scheme == "http", url.host == "127.0.0.1" else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let downloads = root.appendingPathComponent("CodeQA", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
        var environment = DownloadEnvironment.live
        environment.downloadsFolder = downloads
        environment.readClipboardURL = { url }
        environment.playSound = { _ in }
        var launches = 0
        environment.makeProcess = { launches += 1; return Process() }
        let store = TrialFileStore(directory: root.appendingPathComponent("CodeTrial"))
        let manager = DownloadManager(environment: environment, trialStore: store)
        manager.startDownload()
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.cancel()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        expectEqual(manager.trialRemaining, 3, "Real cancelled engine must not use credit")
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path).filter { $0.hasSuffix(".mp4") }.count, 0)
        let source = try Data(contentsOf: root.appendingPathComponent("source/Droplet-QA.mp4"))
        var saved = Set<URL>()
        for remaining in (0...2).reversed() {
            manager.useNewClipboardLink()
            manager.startDownload()
            let deadline = Date().addingTimeInterval(25)
            while manager.phase == .downloading && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            guard manager.phase == .done, let result = manager.result else {
                manager.cancel()
                throw NSError(domain: "LoopbackQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download did not finish: \(manager.phase)"])
            }
            expectEqual(try Data(contentsOf: result.fileURL), source, "Published bytes must match fixture")
            expectEqual(result.media.videoCodec, "h264")
            expectEqual(result.media.audioCodec, "aac")
            expectTrue(saved.insert(result.fileURL).inserted, "Repeated title must preserve all previous files")
            expectEqual(manager.trialRemaining, remaining)
            expectEqual(try PersistentTrialAccounting(store: store).remaining, remaining)
            manager.beginSession()
            expectEqual(manager.phase, .done, "Reopen preserves saved-file state")
        }
        let before = launches
        manager.useNewClipboardLink()
        manager.startDownload()
        expectEqual(launches, before, "Fourth download must never start engine")
        expectEqual(saved.count, 3)
        let files = try FileManager.default.contentsOfDirectory(atPath: downloads.path)
        expectEqual(files.filter { $0.hasSuffix(".mp4") }.count, 3)
        expectEqual(files.filter { $0.hasPrefix(".droplet-") }.count, 0, "No abandoned workspace after cancellation/completion")
        manager.shutdownForQuit()
        print("Real loopback cancellation, three H264/AAC saves, byte integrity, persistence and fourth-start gate verified")
    }
}
