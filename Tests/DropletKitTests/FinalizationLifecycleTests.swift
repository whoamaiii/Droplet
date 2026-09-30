import Foundation
import Darwin
@testable import DropletKit

private actor VerificationGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

struct FinalizationLifecycleTests {
    @MainActor
    private func prepareOutput(_ process: FakeProcess) throws -> URL {
        let args = process.arguments!
        let file = URL(fileURLWithPath: args[args.firstIndex(of: "-o")! + 1].replacingOccurrences(of: "%(ext)s", with: "mp4"))
        let encoder = Process()
        encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        encoder.arguments = ["-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=160x90:r=12", "-t", "0.25", "-an", "-c:v", "libx264", file.path]
        encoder.standardOutput = FileHandle.nullDevice
        encoder.standardError = FileHandle.nullDevice
        try encoder.run(); encoder.waitUntilExit()
        guard encoder.terminationStatus == 0 else { throw NSError(domain: "Fixture", code: 1) }
        process.enqueueOutput(process.eventLine(["event":"result", "path":file.path, "title":"Finalization test"]) + "\n")
        process.finish(status: 0)
        return file
    }

    @MainActor
    func testCancelAndReplacementDuringVerification() async throws {
        let h = DownloadHarness()
        let gate = VerificationGate()
        var environment = h.environment
        environment.verifyMedia = { url in
            await gate.wait()
            return try await MediaVerifier().verify(url)
        }
        let manager = DownloadManager(environment: environment)
        manager.startDownload()
        let oldFile = try prepareOutput(h.processes[0])
        let deadline = Date().addingTimeInterval(5)
        while !(await gate.started) && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        expectTrue(await gate.started)
        manager.cancel()
        expectEqual(manager.phase, .idle)
        manager.startDownload()
        await gate.release()
        while FileManager.default.fileExists(atPath: oldFile.path) && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        expectFalse(FileManager.default.fileExists(atPath: oldFile.path))
        expectEqual(manager.phase, .downloading)
        expectNil(manager.result)
        expectEqual(h.processes.count, 2)
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: h.folder.path).count, 1, "Only the replacement staging folder may remain")
        manager.cancel()
        h.clock.runCleanup()
    }

    @MainActor
    func testPublicationFailuresDoNotBecomeSuccess() async throws {
        for code in [ENOSPC, EACCES, ENOENT] {
            let h = DownloadHarness()
            var environment = h.environment
            environment.makeWorkspace = { try DownloadWorkspace(destination: $0, linkFile: { _, _ in code }) }
            let manager = DownloadManager(environment: environment)
            manager.startDownload()
            _ = try prepareOutput(h.processes[0])
            let deadline = Date().addingTimeInterval(5)
            while manager.phase == .downloading && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            if case .failed(let message) = manager.phase {
                expectTrue(message.contains(code == ENOSPC ? "disk space" : code == EACCES ? "permissions" : "moved or removed"))
            } else { recordFailure("Publication error produced success") }
            expectNil(manager.result)
            expectEqual(try FileManager.default.contentsOfDirectory(atPath: h.folder.path).count, 0)
        }
    }
    @MainActor
    func testQuitCleansSuspendedVerificationBeforeReturning() async throws {
        let h = DownloadHarness()
        let gate = VerificationGate()
        var environment = h.environment
        environment.verifyMedia = { url in
            await gate.wait()
            return try await MediaVerifier().verify(url)
        }
        let manager = DownloadManager(environment: environment)
        manager.startDownload()
        let file = try prepareOutput(h.processes[0])
        let deadline = Date().addingTimeInterval(5)
        while !(await gate.started) && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        expectTrue(await gate.started)
        manager.shutdownForQuit()
        expectEqual(manager.phase, .idle)
        expectFalse(FileManager.default.fileExists(atPath: file.path))
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: h.folder.path).count, 0)
        await gate.release()
        await drainMainQueue()
        expectNil(manager.result)
        expectEqual(manager.phase, .idle)
    }

}
