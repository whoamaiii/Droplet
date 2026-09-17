import Cocoa
import Foundation

@main
struct ManagerTests {
    @MainActor static func until(_ predicate: () -> Bool, timeout: Double = 8) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, "Timed out waiting for manager state")
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
    @MainActor static func shutdown(_ manager: DownloadManager) async {
        await withCheckedContinuation { continuation in
            manager.shutdownForQuit { continuation.resume() }
        }
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("droplet-manager-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("yt-dlp")
        let log = root.appendingPathComponent("urls.log")
        let script = #"""
        #!/bin/sh
        if [ "$1" = --version ]; then sleep 0.2; echo 2026.test; exit 0; fi
        for arg do url="$arg"; done
        printf '%s\n' "$url" >> "$DROPLET_TEST_LOG"
        case "$url" in
          */old) trap '' TERM; sleep 30; exit 1 ;;
          */new) sleep 2 ;;
          *youtu.be/retry)
            count=$(grep -c 'youtu.be/retry' "$DROPLET_TEST_LOG")
            if [ "$count" -eq 1 ]; then sleep 0.2; printf 'ERROR: original reason'; exit 1; fi ;;
          */fail) printf 'ERROR: exact final failure'; exit 42 ;;
        esac
        printf 'DROPLET_META:["New download",null,"v"]\n'
        printf 'DROPLET_PROGRESS:["v","100%%"]\n'
        exit 0
        """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        setenv("DROPLET_YTDLP", fake.path, 1)
        setenv("DROPLET_FFMPEG", "/usr/bin/true", 1)
        setenv("DROPLET_TEST_LOG", log.path, 1)
        defer { unsetenv("DROPLET_YTDLP"); unsetenv("DROPLET_FFMPEG"); unsetenv("DROPLET_TEST_LOG") }

        let race = DownloadManager()
        race.clipboardURL = URL(string: "https://example.test/old")!
        race.startDownload()
        try await Task.sleep(nanoseconds: 200_000_000)
        race.cancel()
        race.clipboardURL = URL(string: "https://example.test/new")!
        race.startDownload()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        precondition(race.phase == .downloading, "Old completion must not wipe the new active download")
        try await until { race.phase == .done }
        precondition(race.title == "New download")
        await shutdown(race)
        print("PASS manager: cancel -> immediate restart ignores stale completion/output")

        try "".write(to: log, atomically: true, encoding: .utf8)
        let retry = DownloadManager()
        retry.clipboardURL = URL(string: "https://youtu.be/retry")!
        retry.startDownload()
        retry.clipboardURL = URL(string: "https://example.test/changed")!
        try await until { retry.phase == .done }
        let urls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        precondition(urls.count == 2 && urls.allSatisfy { $0 == "https://youtu.be/retry" })
        await shutdown(retry)
        print("PASS manager: automatic retry uses the originally captured URL")

        let failed = DownloadManager()
        failed.clipboardURL = URL(string: "https://example.test/fail")!
        failed.startDownload()
        try await until { if case .failed = failed.phase { return true }; return false }
        if case .failed(let message) = failed.phase {
            precondition(message == "exact final failure", "Final ERROR must be present at failure evaluation")
        }
        let before = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count
        failed.clipboardURL = URL(string: "https://example.test/changed")!
        failed.retryFromFailure()
        precondition(failed.phase == .downloading, "Try Again must start immediately")
        try await until { if case .failed = failed.phase { return true }; return false }
        let after = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        precondition(after.count > before && after.last == "https://example.test/fail")
        await shutdown(failed)
        print("PASS manager: real Try Again preserves URL and useful error")

        let quitting = DownloadManager()
        quitting.clipboardURL = URL(string: "https://example.test/old")!
        quitting.startDownload()
        try await Task.sleep(nanoseconds: 100_000_000)
        quitting.cancel()
        quitting.clipboardURL = URL(string: "https://example.test/new")!
        quitting.startDownload()
        await shutdown(quitting)
        precondition(quitting.isShuttingDown)
        print("PASS manager: quit waits for both active and retiring command cleanup")
        print("All 4 macOS manager tests passed; only temporary fake executables were used.")
    }
}
