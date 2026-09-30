import Foundation
@testable import DropletKit

struct DownloadOutputTests {
    func testStructuredEventsAndUnknownTotals() {
        let parser = DownloadOutputProtocol(marker: "test:")
        expectEqual(parser.parse(#"test:{"event":"download","status":"downloading","downloaded":42,"total":100,"vcodec":"h264","acodec":"none","title":"Blåbær 🍓"}"#), .transfer(.video, 0.42, "Blåbær 🍓"))
        expectEqual(parser.parse(#"test:{"event":"download","status":"finished","downloaded":100,"total":100,"vcodec":"none"}"#), .transfer(.audio, 0.99, nil))
        expectEqual(parser.parse(#"test:{"event":"download","status":"downloading","downloaded":42,"total":null}"#), .transfer(.media, nil, nil))
        expectEqual(parser.parse(#"test:{"event":"download","status":"downloading","downloaded":true,"total":100}"#), .transfer(.media, nil, nil))
        expectEqual(parser.parse(#"test:{"event":"postprocess","processor":"Merger"}"#), .processing(.merging, nil))
        expectEqual(parser.parse(#"test:{"event":"result","path":"/tmp/quote\" and\nnewline.mp4","extractor":"fixture","id":"123","audio_codecs":["none"],"acodec":"none"}"#), .result("/tmp/quote\" and\nnewline.mp4", nil, VideoIdentity(extractor: "fixture", mediaID: "123"), false))
        expectEqual(parser.parse("test:{broken"), .malformed)
        expectNil(parser.parse("[download] 100%"))
        expectNil(parser.parse("different:{\"event\":\"result\"}"))
    }

    @MainActor
    func testTransferCompletionCannotFinishWithoutSavedFile() async {
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        let process = h.processes[0]
        process.enqueueOutput(process.eventLine(["event":"download", "status":"finished", "downloaded":100, "total":100, "vcodec":"none"]) + "\n")
        await drainMainQueue()
        expectEqual(manager.phase, .downloading)
        expectEqual(manager.stage, .audio)
        expectEqual(manager.progress, 0.99)
        process.enqueueOutput(process.eventLine(["event":"postprocess", "processor":"Merger"]) + "\n")
        await drainMainQueue()
        expectEqual(manager.stage, .merging)
        expectFalse(manager.progressKnown)
        process.finish(status: 0)
        await drainMainQueue()
        if case .failed = manager.phase { expectTrue(true) }
        else { recordFailure("Exit zero without a saved output must fail") }
    }

    @MainActor
    func testSavedResultWaitsForEOFAndSuccessfulExit() async throws {
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        var outputs: [URL] = []
        for _ in 0..<2 {
            manager.startDownload()
            let process = h.processes.last!
            let args = process.arguments!
            let path = args[args.firstIndex(of: "-o")! + 1].replacingOccurrences(of: "%(ext)s", with: "mp4")
            let encoder = Process()
            encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            encoder.arguments = ["-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=160x90:r=12", "-t", "0.25", "-an", "-c:v", "libx264", path]
            encoder.standardOutput = FileHandle.nullDevice
            encoder.standardError = FileHandle.nullDevice
            try encoder.run()
            encoder.waitUntilExit()
            expectEqual(encoder.terminationStatus, 0)
            process.enqueueOutput(process.eventLine(["event":"result", "path":path, "title":"Test"]) + "\n")
            await drainMainQueue()
            expectEqual(manager.phase, .downloading)
            expectEqual(manager.stage, .finalizing)
            process.finish(status: 0)
            let deadline = Date().addingTimeInterval(5)
            while manager.phase == .downloading && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            expectEqual(manager.phase, .done)
            expectEqual(manager.progress, 1)
            guard let result = manager.result else { recordFailure("Missing verified result"); return }
            expectEqual(result.identity, VideoIdentity(extractor: "fixture", mediaID: "123"))
            expectEqual(result.media.videoCodec, "h264")
            expectTrue(result.isNewFile)
            expectTrue(FileManager.default.fileExists(atPath: result.fileURL.path))
            expectFalse(FileManager.default.fileExists(atPath: path))
            outputs.append(result.fileURL)
        }
        expectFalse(outputs[0] == outputs[1])
        expectTrue(FileManager.default.fileExists(atPath: outputs[0].path))
        manager.startDownload()
        let process = h.processes.last!
        let args = process.arguments!
        let path = args[args.firstIndex(of: "-o")! + 1].replacingOccurrences(of: "%(ext)s", with: "mp4")
        try FileManager.default.copyItem(atPath: outputs[0].path, toPath: path)
        process.enqueueOutput(process.eventLine(["event":"result", "path":path, "title":"Must keep audio", "audio_codecs":["none", "opus"]]) + "\n")
        process.finish(status: 0)
        let deadline = Date().addingTimeInterval(5)
        while manager.phase == .downloading && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        if case .failed(let message) = manager.phase {
            expectTrue(message.contains("audio"))
        } else { recordFailure("Source audio silently lost") }
        expectNil(manager.result)
        expectFalse(FileManager.default.fileExists(atPath: path))
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: h.folder.path).count, 2)
    }

    @MainActor
    func testProtocolErrorsCannotTurnIntoSuccess() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for malformed in [false, true] {
            let h = DownloadHarness()
            let manager = DownloadManager(environment: h.environment)
            manager.startDownload()
            let process = h.processes[0]
            let invalid = malformed ? process.eventLine(["event":"unknown"]) : "ERROR: broken output"
            process.enqueueOutput(invalid + "\n" + process.eventLine(["event":"result", "path":file.path]) + "\n")
            process.finish(status: 0)
            await drainMainQueue()
            if case .failed = manager.phase { expectTrue(true) }
            else { recordFailure("Invalid output accepted as success") }
        }
    }

}
