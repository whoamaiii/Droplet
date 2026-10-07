import Foundation
@testable import DropletKit

final class DownloadFolderTests {
    @MainActor
    func testFolderChoicePersistsAndInvalidChoicePreservesPrevious() throws {
        let suite = "DropletTests.folder." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DownloadFolderStore(defaults: defaults)
        expectNil(try store.load())
        let h = DownloadHarness()
        let chosen = h.folder.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
        let manager = DownloadManager(environment: h.environment)
        try manager.chooseDownloadsFolder(chosen, store: store)
        expectEqual(manager.downloadsFolder, chosen)
        expectEqual(try store.load()?.standardizedFileURL, chosen.standardizedFileURL)
        let second = DownloadManager(environment: h.environment)
        second.restoreDownloadsFolder(from: store)
        expectEqual(second.downloadsFolder.standardizedFileURL, chosen.standardizedFileURL)
        expectThrows(try manager.chooseDownloadsFolder(chosen.appendingPathComponent("missing"), store: store))
        expectEqual(manager.downloadsFolder, chosen)
        expectEqual(try store.load()?.standardizedFileURL, chosen.standardizedFileURL)
        manager.startDownload()
        expectEqual(manager.phase, .downloading)
        expectThrows(try manager.chooseDownloadsFolder(h.folder, store: store))
        expectEqual(manager.downloadsFolder, chosen)
        manager.shutdownForQuit()
    }

    @MainActor
    func testUnavailableBookmarkBlocksUntilExplicitRecovery() throws {
        let suite = "DropletTests.folder." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DownloadFolderStore(defaults: defaults)
        defaults.set(Data("broken".utf8), forKey: "downloadFolderBookmark.v1")
        expectThrows(try store.load())
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        manager.restoreDownloadsFolder(from: store)
        expectTrue(manager.destinationProblem != nil)
        manager.startDownload()
        expectEqual(h.processes.count, 0)
        if case .failed = manager.phase {} else { recordFailure("Missing folder must not silently use Downloads") }
        expectTrue(manager.canRetry, "The destination gate must keep the link for Try Again")
        try manager.chooseDownloadsFolder(h.folder, store: store)
        expectNil(manager.destinationProblem)
        manager.retryFromFailure()
        expectEqual(h.processes.count, 1, "Try Again after choosing a folder starts the kept link")
        expectEqual(h.processes[0].arguments?.last, h.clipboard.absoluteString)
        manager.shutdownForQuit()
        try FileManager.default.removeItem(at: h.folder)
        expectThrows(try store.load())
    }
}
