import Foundation
@testable import DropletKit

struct EngineUpdaterTests {
    @MainActor
    func testSuccessIncludesAsynchronousVersionAndCannotOverlap() async {
        let h = DownloadHarness()
        let updater = EngineUpdater(environment: h.environment)
        updater.updateDownloader()
        let staged = h.engineStaging.staged[0]
        expectEqual(h.processes[0].executableURL, staged, "The updater runs the private staged copy")
        expectTrue(h.processes[0].arguments!.contains("--update-to"))
        expectFalse(h.processes[0].arguments!.contains("brew"))
        h.processes[0].finish(status: 0)
        await drainMainQueue()
        expectEqual(updater.updateNote, "Checking engine version…")
        expectEqual(h.processes.count, 2)
        expectEqual(h.processes[1].executableURL, staged, "The staged copy is verified before installation")
        updater.updateDownloader()
        expectEqual(h.processes.count, 2)
        h.processes[1].enqueueOutput("2026.08.19\n")
        h.processes[1].finish(status: 0)
        await drainMainQueue()
        expectEqual(updater.updateNote, "yt-dlp 2026.08.19 ✓")
        expectEqual(h.engineStaging.installed.map(\.1), ["2026.08.19"])
        expectEqual(updater.installedEngine, h.engineStaging.installedURL)
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
        expectEqual(h.engineStaging.discarded.count, 1)
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
        expectEqual(h.engineStaging.discarded.count, 2, "Shutdown discards the in-progress staged copy")
        h.processes[1].finish(status: 0)
        h.clock.runMain()
        await drainMainQueue()
        expectEqual(updater.updateNote, "")
        expectEqual(h.processes.count, 2)
        expectTrue(h.engineStaging.installed.isEmpty)
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
        expectTrue(h.engineStaging.installed.isEmpty)
        h.launchError = CocoaError(.fileNoSuchFile)
        updater.updateDownloader()
        expectEqual(updater.updateNote, "Couldn't run the engine updater.")
        h.clock.runMain()
        expectEqual(updater.updateNote, "")
    }

    @MainActor
    func testUnverifiedOrUnsupportedUpdatesAreNeverInstalled() async {
        let h = DownloadHarness()
        let updater = EngineUpdater(environment: h.environment)
        updater.updateDownloader()
        h.processes[0].finish(status: 0)
        await drainMainQueue()
        h.processes[1].enqueueOutput("not a version; rm -rf\n")
        h.processes[1].finish(status: 0)
        await drainMainQueue()
        expectTrue(h.engineStaging.installed.isEmpty, "Unparseable version output never installs")
        expectEqual(h.engineStaging.discarded.count, 1)
        expectNil(updater.installedEngine)
        expectTrue(updater.updateNote.contains("not installed"))

        h.engineStaging.unsupported = true
        h.clock.runMain()
        updater.updateDownloader()
        expectEqual(h.processes.count, 2, "A Homebrew development engine is never self-updated")
        expectTrue(updater.updateNote.contains("brew upgrade"))
        expectFalse(updater.isUpdating)
    }

    @MainActor
    func testInstalledEngineIsUsedByTheNextDownload() async {
        let h = DownloadHarness()
        let updater = EngineUpdater(environment: h.environment)
        let manager = DownloadManager(environment: h.environment, updater: updater)
        manager.updateDownloader()
        h.processes[0].finish(status: 0)
        await drainMainQueue()
        h.processes[1].enqueueOutput("2026.09.30\n")
        h.processes[1].finish(status: 0)
        await drainMainQueue()
        manager.startDownload()
        expectEqual(h.processes.count, 3)
        expectEqual(h.processes[2].executableURL, h.engineStaging.installedURL)
        manager.cancel()
        h.clock.runCleanup()
    }
}
