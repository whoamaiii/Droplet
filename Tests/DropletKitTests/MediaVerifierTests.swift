import Foundation
@testable import DropletKit

struct MediaVerifierTests {
    func testRealMP4MediaAndUnsupportedCodec() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func generate(_ name: String, codec: String, audio: Bool) throws -> URL {
            let file = root.appendingPathComponent(name)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            p.arguments = ["-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=160x90:r=12"]
                + (audio ? ["-f", "lavfi", "-i", "sine=frequency=440"] : [])
                + ["-t", "0.25", "-c:v", codec] + (audio ? ["-c:a", "aac"] : ["-an"])
                + [file.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw NSError(domain: "FixtureEncoder", code: Int(p.terminationStatus)) }
            return file
        }
        let soundVideo = try generate("sound.mp4", codec: "libx264", audio: true)
        let verified = try await MediaVerifier().verify(soundVideo)
        expectEqual(verified.container, "mp4")
        expectEqual(verified.videoCodec, "h264")
        expectEqual(verified.audioCodec, "aac")
        expectTrue(verified.byteCount > 0)
        expectTrue(verified.duration > 0)
        let workspace = try DownloadWorkspace(destination: root)
        let staged = workspace.directory.appendingPathComponent("media.mp4")
        try FileManager.default.copyItem(at: soundVideo, to: staged)
        let identity = VideoIdentity(extractor: "fixture", mediaID: "local-123")
        let finalizer = DownloadFinalizer()
        let prepared = try await finalizer.prepare(workspace: workspace, reported: staged,
            source: URL(string: "https://example.invalid/test")!, identity: identity, title: "Blåbær 🍓")
        let published = try finalizer.commit(prepared, workspace: workspace)
        expectEqual(published.identity, identity)
        expectEqual(published.media, verified)
        expectTrue(published.isNewFile)
        expectEqual(published.fileURL.deletingLastPathComponent().path, root.path)
        expectEqual(try Data(contentsOf: published.fileURL), try Data(contentsOf: soundVideo))
        let cancelled = Task { () throws -> DownloadResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try finalizer.commit(prepared, workspace: workspace)
        }
        do {
            _ = try await cancelled.value
            recordFailure("Cancelled validation published a file")
        } catch { expectTrue(error is CancellationError) }
        let visible = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        expectEqual(visible.filter { $0.lastPathComponent.hasPrefix("Blåbær") }.count, 1)
        try workspace.remove()
        let silent = try generate("silent.mp4", codec: "libx264", audio: false)
        expectNil(try await MediaVerifier().verify(silent).audioCodec)
        let unsupported = try generate("unsupported.mp4", codec: "mpeg4", audio: false)
        do {
            _ = try await MediaVerifier().verify(unsupported)
            recordFailure("Unsupported codec accepted")
        } catch { expectTrue(true) }
        let disguised = root.appendingPathComponent("disguised.mp4")
        try Data("not a video".utf8).write(to: disguised)
        do {
            _ = try await MediaVerifier().verify(disguised)
            recordFailure("Extension accepted without media")
        } catch { expectTrue(true) }
        let truncated = root.appendingPathComponent("truncated.mp4")
        try Data(contentsOf: soundVideo).prefix(32).write(to: truncated)
        do {
            _ = try await MediaVerifier().verify(truncated)
            recordFailure("Truncated header accepted")
        } catch { expectTrue(true) }
    }
}
