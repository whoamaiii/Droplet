import Foundation
@testable import DropletKit

private final class TrialMemoryStore: StateStore {
    var data: Data?
    var failWrites = false
    var writeCount = 0
    var failFromWrite: Int?
    func read(key: String) throws -> Data? { data }
    func write(_ data: Data, key: String) throws {
        writeCount += 1
        if failWrites || failFromWrite.map({ writeCount >= $0 }) == true { throw CocoaError(.fileWriteNoPermission) }
        self.data = data
    }
}

struct TrialAccountingTests {
    @MainActor
    func testThreeNewSuccessesAndIdempotentCompletion() throws {
        let store = TrialMemoryStore()
        let trial = try PersistentTrialAccounting(store: store)
        let result = DownloadResult(sourceURL: URL(string: "https://example.com/video")!,
            identity: VideoIdentity(extractor: "fixture", mediaID: "one"),
            fileURL: URL(fileURLWithPath: "/tmp/video.mp4"),
            media: VerifiedMedia(byteCount: 1, duration: 1, container: "mp4", videoCodec: "h264", audioCodec: nil), isNewFile: true)
        for remaining in (0...2).reversed() {
            let job = UUID()
            try trial.reserve(jobID: job)
            try trial.complete(jobID: job, result: result)
            try trial.complete(jobID: job, result: result)
            expectEqual(trial.remaining, remaining)
        }
        expectThrows(try trial.reserve(jobID: UUID()))
        expectEqual(try PersistentTrialAccounting(store: store).remaining, 0)
    }

    @MainActor
    func testCancelledAndExistingFilesDoNotUseCredit() throws {
        let trial = try PersistentTrialAccounting(store: TrialMemoryStore())
        let job = UUID()
        try trial.reserve(jobID: job)
        try trial.release(jobID: job)
        let next = UUID()
        try trial.reserve(jobID: next)
        let result = DownloadResult(sourceURL: URL(string: "https://example.com/video")!,
            identity: VideoIdentity(extractor: "fixture", mediaID: "one"), fileURL: URL(fileURLWithPath: "/tmp/video.mp4"),
            media: VerifiedMedia(byteCount: 1, duration: 1, container: "mp4", videoCodec: "h264", audioCodec: nil), isNewFile: false)
        try trial.complete(jobID: next, result: result)
        expectEqual(trial.remaining, 3)
    }

    @MainActor
    func testCrashBetweenPublicationAndAccountingRecoversExactlyOnce() throws {
        let store = TrialMemoryStore()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let staged = folder.appendingPathComponent(".staged")
        try Data("verified fixture".utf8).write(to: staged)
        let trial = try PersistentTrialAccounting(store: store)
        let job = UUID()
        try trial.reserve(jobID: job)
        try trial.preparePublication(jobID: job, stagedFile: staged, destination: folder)
        try FileManager.default.linkItem(at: staged, to: folder.appendingPathComponent("video.mp4"))
        try FileManager.default.removeItem(at: staged)
        expectEqual(try PersistentTrialAccounting(store: store).remaining, 2)
        expectEqual(try PersistentTrialAccounting(store: store).remaining, 2)
    }

    @MainActor
    func testCrashBeforePublicationDoesNotUseCreditAndCorruptionFailsClosed() throws {
        let store = TrialMemoryStore()
        let trial = try PersistentTrialAccounting(store: store)
        try trial.reserve(jobID: UUID())
        expectEqual(try PersistentTrialAccounting(store: store).remaining, 3)
        store.failWrites = true
        expectThrows(try trial.reserve(jobID: UUID()))
        expectEqual(trial.remaining, 3)
        store.failWrites = false
        store.data = Data("broken".utf8)
        expectThrows(try PersistentTrialAccounting(store: store))
    }

    @MainActor
    func testUnpublishedWitnessAndUnrelatedFileDoNotConsumeCredit() throws {
        let store = TrialMemoryStore()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let staged = folder.appendingPathComponent(".staged")
        try Data("fixture".utf8).write(to: staged)
        try Data("fixture".utf8).write(to: folder.appendingPathComponent("old.mp4"))
        let trial = try PersistentTrialAccounting(store: store)
        let job = UUID()
        try trial.reserve(jobID: job)
        try trial.preparePublication(jobID: job, stagedFile: staged, destination: folder)
        expectEqual(try PersistentTrialAccounting(store: store).remaining, 3)
    }

    @MainActor
    func testGateBlocksProcessAfterQuotaOrUnavailableState() throws {
        let store = TrialMemoryStore()
        let trial = try PersistentTrialAccounting(store: store)
        let result = DownloadResult(sourceURL: URL(string: "https://example.com/video")!,
            identity: VideoIdentity(extractor: "fixture", mediaID: "one"), fileURL: URL(fileURLWithPath: "/tmp/video.mp4"),
            media: VerifiedMedia(byteCount: 1, duration: 1, container: "mp4", videoCodec: "h264", audioCodec: nil), isNewFile: true)
        for _ in 0..<3 { let job = UUID(); try trial.reserve(jobID: job); try trial.complete(jobID: job, result: result) }
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment, trialAccounting: trial)
        manager.startDownload()
        expectEqual(h.processes.count, 0)
        expectTrue(manager.trialExhausted)
        if case .failed = manager.phase {} else { recordFailure("Exhausted trial started download") }
    }
    @MainActor
    func testUnreadableTrialFactoryBlocksAllStarts() {
        let store = TrialMemoryStore()
        store.data = Data("corrupt".utf8)
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment, trialStore: store)
        manager.startDownload()
        manager.beginSession()
        manager.useNewClipboardLink()
        manager.startDownload()
        expectEqual(h.processes.count, 0)
        expectTrue(manager.trialProblem != nil)
    }

    @MainActor
    func testDoneReopensAndUpdatesCannotOverlapDownloads() async {
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        manager.phase = .done
        manager.beginSession()
        expectEqual(manager.phase, .done)
        manager.useNewClipboardLink()
        manager.updateDownloader()
        expectTrue(manager.isUpdating)
        manager.startDownload()
        expectEqual(h.processes.count, 1, "Updater must be the only process")
        expectTrue(manager.canRetry, "The updater gate must keep the link for Try Again")
        h.processes[0].finish(status: 1)
        await drainMainQueue()
        expectFalse(manager.isUpdating)
        manager.retryFromFailure()
        expectEqual(h.processes.count, 2, "Try Again after the update starts the kept link")
        manager.updateDownloader()
        expectEqual(h.processes.count, 2, "Download blocks updater launch")
        manager.cancel()
        h.clock.runCleanup()
    }

    @MainActor
    func testTrialFailureCancelAndRetryKeepAllCredits() async throws {
        let store = TrialMemoryStore()
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment, trialStore: store)
        manager.startDownload()
        h.processes[0].enqueueOutput("ERROR: unsupported url\n")
        h.processes[0].finish(status: 1)
        await drainMainQueue()
        expectEqual(manager.trialRemaining, 3)
        manager.retryFromFailure()
        expectEqual(h.processes.count, 2)
        manager.cancel()
        h.clock.runCleanup()
        expectEqual(manager.trialRemaining, 3)
        expectEqual(try PersistentTrialAccounting(store: store).remaining, 3)
    }

    @MainActor
    func testAccountingWriteFailureBeforeAndAfterPublication() async throws {
        for failedWrite in [3, 4] {
            let store = TrialMemoryStore()
            store.failFromWrite = failedWrite
            let h = DownloadHarness()
            var environment = h.environment
            environment.verifyMedia = { url in
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                return VerifiedMedia(byteCount: (attrs[.size] as! NSNumber).int64Value,
                    duration: 1, container: "mp4", videoCodec: "h264", audioCodec: nil)
            }
            let manager = DownloadManager(environment: environment, trialStore: store)
            manager.startDownload()
            let process = h.processes[0]
            let args = process.arguments!
            let staged = URL(fileURLWithPath: args[args.firstIndex(of: "-o")! + 1].replacingOccurrences(of: "%(ext)s", with: "mp4"))
            try Data("fixture bytes".utf8).write(to: staged)
            process.enqueueOutput(process.eventLine(["event": "result", "path": staged.path, "title": "Trial fixture"]) + "\n")
            process.finish(status: 0)
            let deadline = Date().addingTimeInterval(5)
            while manager.phase == .downloading && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            expectTrue(manager.trialProblem != nil)
            if failedWrite == 3 {
                expectNil(manager.result)
                if case .failed = manager.phase {} else { recordFailure("Witness write failure published a file") }
            } else {
                expectEqual(manager.phase, .done)
                expectTrue(manager.result.map { FileManager.default.fileExists(atPath: $0.fileURL.path) } == true)
            }
            manager.useNewClipboardLink()
            manager.startDownload()
            expectEqual(h.processes.count, 1)
            store.failFromWrite = nil
            expectEqual(try PersistentTrialAccounting(store: store).remaining, failedWrite == 3 ? 3 : 2)
        }
    }

    @MainActor
    func testDormantTakeoverLoadsFreshQuotaAndRecoveryFailures() throws {
        let store = TrialMemoryStore()
        let owner = try PersistentTrialAccounting(store: store)
        let resource = OwnershipBoundResource<PersistentTrialAccounting>()
        resource.initialize(ownership: .occupied) { owner }
        let result = DownloadResult(sourceURL: URL(string: "https://example.com/video")!,
            identity: VideoIdentity(extractor: "fixture", mediaID: "one"), fileURL: URL(fileURLWithPath: "/tmp/video.mp4"),
            media: VerifiedMedia(byteCount: 1, duration: 1, container: "mp4", videoCodec: "h264", audioCodec: nil), isNewFile: true)
        let job = UUID()
        try owner.reserve(jobID: job)
        try owner.complete(jobID: job, result: result)
        let successor = try PersistentTrialAccounting(store: store)
        resource.initialize(ownership: .acquired) { successor }
        expectEqual(resource.value?.remaining, 2, "Takeover must load quota after prior owner completion")
        let pending = UUID()
        try successor.reserve(jobID: pending)
        let journal = store.data
        store.failWrites = true
        expectThrows(try PersistentTrialAccounting(store: store))
        expectEqual(store.data, journal, "Recovery write failure must preserve previous journal")
        store.failWrites = false
        expectEqual(try PersistentTrialAccounting(store: store).remaining, 2)
    }

}
