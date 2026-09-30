import Foundation
@testable import DropletKit

struct EngineUpdaterTests {
    @MainActor
    func testSuccessIncludesAsynchronousVersionAndCannotOverlap() async {
        let h = DownloadHarness()
        let updater = EngineUpdater(environment: h.environment)
        updater.updateDownloader()
        h.processes[0].finish(status: 0)
        await drainMainQueue()
        expectEqual(updater.updateNote, "Checking engine version…")
        expectEqual(h.processes.count, 2)
        updater.updateDownloader()
        expectEqual(h.processes.count, 2)
        h.processes[1].enqueueOutput("2026.08.19\n")
        h.processes[1].finish(status: 0)
        await drainMainQueue()
        expectEqual(updater.updateNote, "yt-dlp 2026.08.19 ✓")
        h.clock.runMain()
        expectEqual(updater.updateNote, "")
    }

    @MainActor
    func testTimeoutAndShutdownCleanOwnedJobsAndIgnoreOldExit() async {
        let h = DownloadHarness()
        h.children = [21001]
        h.alive.formUnion([21001, 99999])
        let updater = EngineUpdater(environment: h.environment)
        updater.updateDownloader()
        let old = h.processes[0]
        expectEqual(h.clock.mainActions.first?.0, 900)
        h.clock.runMain()
        expectTrue(updater.updateNote.contains("timed out"))
        expectEqual(old.terminateCount, 1)
        updater.updateDownloader()
        expectEqual(h.processes.count, 2)
        old.finish(status: 0)
        await drainMainQueue()
        expectEqual(updater.updateNote, "Updating yt-dlp…")
        expectEqual(h.processes.count, 2, "Old success cannot launch a version query")
        updater.shutdown()
        expectFalse(h.alive.contains(h.processes[1].fakePID))
        expectFalse(h.alive.contains(21001))
        expectTrue(h.alive.contains(99999))
        h.processes[1].finish(status: 0)
        h.clock.runMain()
        await drainMainQueue()
        expectEqual(updater.updateNote, "")
        expectEqual(h.processes.count, 2)
    }

    @MainActor
    func testShutdownDuringVersionAndMissingUpdater() async {
        let h = DownloadHarness()
        let updater = EngineUpdater(environment: h.environment)
        updater.updateDownloader()
        h.processes[0].finish(status: 0)
        await drainMainQueue()
        updater.shutdown()
        expectEqual(h.processes[1].terminateCount, 1)
        h.processes[1].finish(status: 0)
        await drainMainQueue()
        expectEqual(updater.updateNote, "")
        h.launchError = CocoaError(.fileNoSuchFile)
        updater.updateDownloader()
        expectEqual(updater.updateNote, "Couldn't run the engine updater.")
        h.clock.runMain()
        expectEqual(updater.updateNote, "")
    }
}
