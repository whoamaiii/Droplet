import Foundation
@testable import DropletKit

struct BrowserLoginTests {
    @MainActor
    func testPublicFailuresNeverImportBrowserSessions() async {
        for error in ["ERROR: network timeout", "ERROR: No space left on device", "ERROR: Unsupported URL"] {
            let h = DownloadHarness()
            h.clipboard = URL(string: "https://www.youtube.com/watch?v=fixture")!
            let manager = DownloadManager(environment: h.environment)
            manager.startDownload()
            let expectedAttempts = error.contains("timeout") ? 2 : 1
            for attempt in 0..<expectedAttempts {
                let process = h.processes[attempt]
                let args = process.arguments!
                expectTrue(args.contains("--no-cookies"))
                expectTrue(args.contains("--no-cookies-from-browser"))
                expectTrue(args.contains("--ignore-config"))
                expectFalse(args.contains("--netrc"))
                expectFalse(args.contains("--netrc-cmd"))
                expectFalse(args.contains("--cookies-from-browser"))
                process.enqueueOutput(error + "\n")
                process.finish(status: 1)
                await drainMainQueue()
            }
            expectEqual(h.processes.count, expectedAttempts, "Permanent failures stop; no per-browser fallback may appear")
            if case .failed = manager.phase { expectTrue(true) }
            else { recordFailure("Expected terminal failure") }
        }
    }

    @MainActor
    func testConsentIsBoundToOneURLAndDoesNotCarryToNextDownload() async throws {
        let h = DownloadHarness()
        let original = URL(string: "https://example.invalid/approved")!
        let consent = try BrowserLoginConsent(sourceURL: original, browser: .chrome, profile: "Profile 2")
        h.clipboard = URL(string: "https://different.invalid/changed")!
        let manager = DownloadManager(environment: h.environment)
        manager.startDownload(using: consent)
        let process = h.processes[0]
        let args = process.arguments!
        expectEqual(args.last, original.absoluteString)
        expectEqual(args.filter { $0 == "--cookies-from-browser" }.count, 1)
        expectEqual(args[args.firstIndex(of: "--cookies-from-browser")! + 1], "chrome:Profile 2")
        process.finish(status: 1)
        await drainMainQueue()
        expectEqual(h.processes.count, 1, "Consented attempt must not try other profiles")
        manager.startDownload()
        expectFalse(h.processes[1].arguments!.contains("--cookies-from-browser"))
        manager.cancel()
        h.clock.runCleanup()
    }

    @MainActor
    func testCancelRevokesTheConsentedRun() async throws {
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment)
        let consent = try BrowserLoginConsent(sourceURL: URL(string: "https://example.invalid/approved")!, browser: .firefox)
        manager.startDownload(using: consent)
        let process = h.processes[0]
        manager.cancel()
        expectEqual(process.terminateCount, 1)
        h.clock.runCleanup()
        expectTrue(h.signals.contains { $0.0 == process.fakePID && $0.1 == SIGKILL })
        process.finish(status: 1)
        await drainMainQueue()
        expectEqual(h.processes.count, 1, "Cancellation cannot start another authenticated attempt")
        manager.startDownload()
        expectFalse(h.processes[1].arguments!.contains("--cookies-from-browser"))
        manager.cancel()
        h.clock.runCleanup()
    }

    func testConsentValidatesProfileAndURL() throws {
        let url = URL(string: "https://example.invalid/video")!
        expectThrows(try BrowserLoginConsent(sourceURL: url, browser: .chrome, profile: "Default::container"))
        expectThrows(try BrowserLoginConsent(sourceURL: url, browser: .chrome, profile: "Profile\nother"))
        expectThrows(try BrowserLoginConsent(sourceURL: url, browser: .safari, profile: "custom"))
        expectThrows(try BrowserLoginConsent(sourceURL: URL(string: "file:///tmp/example")!, browser: .firefox))
        expectThrows(try BrowserLoginConsent(sourceURL: URL(string: "https://user:password@example.invalid")!, browser: .firefox))
        expectEqual(try BrowserLoginConsent(sourceURL: url, browser: .firefox).arguments,
                    ["--no-cookies", "--cookies-from-browser", "firefox"])
    }
}
