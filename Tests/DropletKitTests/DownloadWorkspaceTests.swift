import Foundation
@testable import DropletKit

struct DownloadWorkspaceTests {
    func testSameTitlePublicationNeverOverwrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try DownloadWorkspace(destination: root)
        let second = try DownloadWorkspace(destination: root)
        expectFalse(first.directory == second.directory)
        let a = first.directory.appendingPathComponent("media.mp4")
        let b = second.directory.appendingPathComponent("media.mp4")
        try Data([1, 2]).write(to: a)
        try Data([3, 4]).write(to: b)
        let outA = try first.publish(a, expectedSize: 2, title: "Same title", identity: "site:123")
        let outB = try second.publish(b, expectedSize: 2, title: "Same title", identity: "site:123")
        expectFalse(outA == outB)
        expectEqual(try Data(contentsOf: outA), Data([1, 2]))
        expectEqual(try Data(contentsOf: outB), Data([3, 4]))
        try first.remove()
        expectTrue(FileManager.default.fileExists(atPath: second.directory.path))
        expectTrue(FileManager.default.fileExists(atPath: outA.path))
    }

    func testUnsafeAndChangedOutputsAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try DownloadWorkspace(destination: root)
        let outside = root.appendingPathComponent("outside.mp4")
        try Data([7]).write(to: outside)
        expectThrows(try workspace.checkedFile(outside))
        let symlink = workspace.directory.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        expectThrows(try workspace.checkedFile(symlink))
        let empty = workspace.directory.appendingPathComponent("empty.mp4")
        try Data().write(to: empty)
        expectThrows(try workspace.checkedFile(empty))
        try Data([1]).write(to: empty)
        expectThrows(try workspace.publish(empty, expectedSize: 2, title: "x", identity: "x"))
        try FileManager.default.removeItem(at: root)
        expectThrows(try workspace.publish(empty, expectedSize: 1, title: "x", identity: "x"))
    }

    func testUnicodeAndLongNamesAreBounded() {
        let title = DownloadWorkspace.safeTitle(String(repeating: "🍓Blåbær/", count: 100) + "\n:..")
        expectTrue(title.utf8.count <= 120)
        expectFalse(title.contains("/"))
        expectFalse(title.contains("\n"))
        expectEqual(DownloadWorkspace.safeTitle(" ... "), "Video")
        expectEqual(DownloadWorkspace.safeTitle("Blåbær 🍓"), "Blåbær 🍓")
    }
    func testActionableFilesystemFailures() {
        expectTrue(DownloadFinalizer.message(for: DownloadWorkspace.Failure.filesystem(28)).contains("disk space"))
        expectTrue(DownloadFinalizer.message(for: DownloadWorkspace.Failure.filesystem(13)).contains("permissions"))
        expectTrue(DownloadFinalizer.message(for: DownloadWorkspace.Failure.filesystem(2)).contains("moved or removed"))
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        expectTrue(DownloadFinalizer.message(for: cocoa).contains("disk space"))
    }

}
