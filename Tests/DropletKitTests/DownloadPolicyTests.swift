import Foundation
@testable import DropletKit

struct DownloadPolicyTests {
    @MainActor
    func testEngineEnvironmentIsExplicit() {
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        let values = h.processes[0].environment!
        expectEqual(Set(values.keys), Set(["HOME", "TMPDIR", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "PYTHONNOUSERSITE", "PYTHONUTF8"]))
        expectEqual(values["PYTHONNOUSERSITE"], "1")
        expectEqual(values["HOME"], FileManager.default.homeDirectoryForCurrentUser.path)
        expectTrue(values["PATH"]!.contains(h.environment.ffmpegDirectory.path))
        for blocked in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "PYTHONPATH", "PYTHONHOME", "DYLD_INSERT_LIBRARIES", "SSL_CERT_FILE", "YTDLP_CONFIG"] {
            expectNil(values[blocked])
        }
        manager.cancel()
        h.clock.runCleanup()
    }

    func testFailureClassification() {
        let cases: [(String, DownloadFailure)] = [
            ("ERROR: No space left on device", .disk),
            ("ERROR: Permission denied", .permission),
            ("ERROR: Sign in to confirm your age", .authentication),
            ("ERROR: Unsupported URL", .source),
            ("ERROR: HTTP Error 403: Forbidden", .source),
            ("ERROR: Requested format is not available", .source),
            ("ERROR: HTTP Error 503: Service Unavailable", .network),
            ("ERROR: Resource temporarily unavailable", .network),
            ("ERROR: Connection reset by peer", .network),
            ("ERROR: certificate verify failed", .unknown),
            ("ERROR: unexpected internal failure", .unknown)
        ]
        for (message, category) in cases {
            expectEqual(DownloadFailure.classify(message), category, message)
            expectEqual(DownloadFailure.classify(message).retryable, category == .network)
        }
    }

    func testURLsAndDomainBoundaries() {
        for invalid in ["", "file:///tmp/video", "ftp://example.com/v", "https://", "https://user:secret@example.com/v", "https://example.com:0/v", "https://example.com:65536/v", "https://bad..example/v", "https://-bad.example/v", "https://example.com/a\nb", "https://example.com/a b", "https://example.com/%ZZ", "https://example.com/%", "https://[not-an-ip]/v"] {
            expectNil(DownloadURLPolicy.parse(invalid), invalid)
        }
        for valid in ["https://example.com/video?a=1&b=%20", "http://127.0.0.1:1234/v.mp4", "https://[::1]/v", "https://example.com/$(touch)?a='quoted'&b=;value"] {
            expectTrue(DownloadURLPolicy.parse(valid) != nil, valid)
        }
        for host in ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"] {
            expectTrue(DownloadURLPolicy.isYouTube(URL(string: "https://\(host)/v")!))
        }
        for host in ["notyoutube.com", "youtube.com.evil.test", "youtu.be.evil.test", "evil-youtube.com"] {
            expectFalse(DownloadURLPolicy.isYouTube(URL(string: "https://\(host)/v")!))
        }
    }

    @MainActor
    func testExplicitRetryAndClipboardReplacement() async {
        let h = DownloadHarness()
        let original = URL(string: "https://example.invalid/video?a='quoted'&b=$(touch)&c=;value")!
        h.clipboard = original
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        expectEqual(h.processes[0].arguments?.last, original.absoluteString)
        h.processes[0].finish(status: 1)
        await drainMainQueue()
        h.clipboard = URL(string: "https://different.invalid/new")!
        manager.beginSession()
        expectTrue(manager.canRetry, "Reopening must preserve the failed job and original URL")
        manager.retryFromFailure()
        expectEqual(h.processes.count, 2)
        expectEqual(h.processes[1].arguments?.last, original.absoluteString)
        expectEqual(manager.phase, .downloading)
        h.processes[1].finish(status: 1)
        await drainMainQueue()
        manager.useNewClipboardLink()
        expectEqual(manager.phase, .idle)
        expectEqual(manager.clipboardURL, h.clipboard)
        expectEqual(h.processes.count, 2, "Choosing a new link must not start it automatically")
        expectFalse(manager.canRetry)
        manager.startDownload()
        expectEqual(h.processes[2].arguments?.last, h.clipboard.absoluteString)
        manager.cancel()
        h.clock.runCleanup()
    }

    @MainActor
    func testInvalidInjectedURLCannotStartProcess() {
        let h = DownloadHarness()
        h.clipboard = URL(string: "https://user:secret@example.invalid/video")!
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload()
        expectEqual(h.processes.count, 0)
        expectFalse(manager.canRetry)
        if case .failed = manager.phase { expectTrue(true) }
        else { recordFailure("Invalid input must fail before starting the engine") }
    }
}
