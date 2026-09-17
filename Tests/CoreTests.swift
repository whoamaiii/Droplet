import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: " + message) }
}

private func command(_ script: String, cancelAfter: Double? = nil,
                     timeout: Double = 5) -> (CommandResult, [String]) {
    let runner = ManagedCommand()
    let done = DispatchSemaphore(value: 0)
    let queue = DispatchQueue(label: "test.callbacks.\(UUID())")
    var lines: [String] = []
    var result: CommandResult?
    runner.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                 environment: EngineTools.environment, timeout: timeout, callbackQueue: queue,
                 onLines: { lines += $0 }, onCompletion: { result = $0; done.signal() })
    if let cancelAfter {
        DispatchQueue.global().asyncAfter(deadline: .now() + cancelAfter) { runner.cancel() }
    }
    expect(done.wait(timeout: .now() + timeout + 5) == .success, "command completes without blocking")
    return (result!, lines)
}

@main
struct CoreTests {
    static func main() throws {
        var count = 0
        func passed(_ name: String) { count += 1; print("PASS \(count): \(name)") }
        let input = "DROPLET_META:[\"Øæ☔️\",null,\"v\"]\r\nERROR: final failure"
        for width in 1...64 {
            var framer = LineFramer()
            let data = Data(input.utf8)
            var lines: [String] = []
            for offset in stride(from: 0, to: data.count, by: width) {
                lines += framer.append(data.subdata(in: offset..<min(data.count, offset + width)))
            }
            lines += framer.finish()
            expect(lines == ["DROPLET_META:[\"Øæ☔️\",null,\"v\"]", "ERROR: final failure"], "byte splits and UTF-8")
        }
        passed("split lines, CRLF, split UTF-8, final line without newline (64 chunk sizes)")

        var bounded = LineFramer()
        _ = bounded.append(Data(repeating: 65, count: 100_000))
        expect(bounded.append(Data("\nERROR: recovered\n".utf8)) == ["ERROR: recovered"], "oversized line recovers")
        passed("bounded line memory and recovery")

        var output = DownloadOutput()
        output.consume(#"DROPLET_META:["Test",[{"format_id":"v","filesize":800},{"format_id":"a","filesize":200}],"v+a"]"#)
        output.consume(#"DROPLET_PROGRESS:["v","100.0%"]"#)
        expect(abs(output.progress - 0.76) < 0.0001, "video is not the full download")
        output.consume(#"DROPLET_PROGRESS:["a","0.0%"]"#)
        expect(abs(output.progress - 0.76) < 0.0001, "audio doesn't reset progress")
        output.consume(#"DROPLET_PROGRESS:["a","50.0%"]"#)
        expect(abs(output.progress - 0.855) < 0.0001, "weighted audio progress")
        output.consume(#"DROPLET_PROGRESS:["a","100.0%"]"#)
        expect(abs(output.progress - 0.95) < 0.0001, "reserve progress for finalization")
        output.consume(#"DROPLET_PROGRESS:["a","nan%"]"#)
        expect(output.progress.isFinite, "invalid floats are ignored")
        passed("two-stream weighted progress, no regression, no premature 100%")

        var unknown = DownloadOutput()
        unknown.consume(#"DROPLET_META:["T",[{"format_id":"v"},{"format_id":"a"}],"v+a"]"#)
        unknown.consume(#"DROPLET_PROGRESS:["v","100%"]"#)
        expect(abs(unknown.progress - 0.475) < 0.0001, "unknown sizes use equal weights")
        passed("unknown-size streams use stage estimates")

        expect(DownloadPolicy.hint(for: "robots.txt id14031") == nil, "no bot/403 substring false positives")
        expect(DownloadPolicy.hint(for: "HTTP Error 403: Forbidden") != nil, "real HTTP 403")
        expect(DownloadPolicy.hint(for: "Sign in to confirm you're not a bot") != nil, "real bot check")
        passed("error hints have word boundaries")

        expect(DownloadPolicy.isYouTube(URL(string: "https://m.youtube.com/watch?v=1")!), "YouTube subdomain")
        expect(!DownloadPolicy.isYouTube(URL(string: "https://notyoutube.com/")!), "no host substring match")
        let request = DownloadRequest(url: URL(string: "https://youtu.be/example")!,
            executable: URL(fileURLWithPath: "/bin/true"), ffmpeg: URL(fileURLWithPath: "/bin/true"),
            attempts: DownloadPolicy.attempts(for: URL(string: "https://youtu.be/example")!, browsers: []),
            outputTemplate: "/tmp/%(title)s [%(id)s].%(ext)s")
        let args = DownloadPolicy.arguments(for: request, attempt: request.attempts[1])
        expect(args.contains("--no-overwrites") && args.contains("--ignore-config"), "safe explicit options")
        expect(args.suffix(2) == ["--", request.url.absoluteString], "captured URL follows option terminator")
        expect(!DownloadPolicy.format.hasSuffix("/best"), "no incompatible unrestricted fallback")
        passed("immutable URL, host matching, no-overwrites and strict codec policy")

        let (final, finalLines) = command("printf 'ERR'; sleep 0.02; printf 'OR: split final error' >&2; exit 1")
        expect(final.status == 1 && final.lastError == "ERROR: split final error", "final error available at completion")
        expect(finalLines.last == final.lastError, "output callback precedes completion")
        passed("live subprocess final-error/EOF ordering")

        let (noisy, _) = command("i=0; while [ $i -lt 12000 ]; do printf 'a moderately long diagnostic line\\n'; i=$((i+1)); done; printf 'ERROR: last\\n' >&2; exit 7")
        expect(noisy.status == 7 && noisy.lastError == "ERROR: last", "drain more than pipe capacity")
        expect(noisy.tail.count == 20, "tail is bounded")
        passed("large stdout/stderr cannot deadlock; bounded diagnostic tail")

        let started = ProcessInfo.processInfo.systemUptime
        let (cancelled, _) = command("trap '' TERM; sleep 30 & wait", cancelAfter: 0.15)
        expect(cancelled.cancelled, "cancellation retained")
        expect(ProcessInfo.processInfo.systemUptime - started < 4, "SIGKILL escalation completes")
        passed("TERM-resistant child group cancellation and escalation")

        let (timed, _) = command("sleep 30", timeout: 0.15)
        expect(timed.status == 124 && timed.lastError.contains("timed out"), "bounded timeout")
        passed("command timeout cancels owned work")

        let orphanStart = ProcessInfo.processInfo.systemUptime
        let (orphan, _) = command("(trap '' TERM; sleep 30) & printf 'root finished\\n'; exit 0")
        expect(orphan.status == 0 && ProcessInfo.processInfo.systemUptime - orphanStart < 4, "leader-first exit handled")
        passed("leader exit before descendants does not hang EOF or lose ownership")

        let sentinel = ManagedCommand()
        let sentinelDone = DispatchSemaphore(value: 0)
        sentinel.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"],
            environment: EngineTools.environment, callbackQueue: .global(), onLines: { _ in },
            onCompletion: { _ in sentinelDone.signal() })
        _ = command("sleep 30", cancelAfter: 0.1)
        expect(sentinelDone.wait(timeout: .now() + 0.2) == .timedOut, "unrelated group survives cancellation")
        sentinel.cancel()
        expect(sentinelDone.wait(timeout: .now() + 4) == .success, "sentinel cleaned up")
        passed("cancelling one command leaves another process group running")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockPath = directory.appendingPathComponent("lock").path
        let first = droplet_lock(lockPath)
        expect(first >= 0, "first lock acquired")
        expect(droplet_lock(lockPath) == -1, "second lock rejected atomically")
        close(first)
        let next = droplet_lock(lockPath)
        expect(next >= 0, "lock acquired after owner closes")
        close(next)
        passed("single-instance lock: first wins; new instance can take over after exit")

        var single = DownloadOutput()
        single.consume(#"DROPLET_META:["Single file",null,"combined"]"#)
        single.consume(#"DROPLET_PROGRESS:["combined","50%"]"#)
        expect(single.title == "Single file" && abs(single.progress - 0.475) < 0.0001, "missing optional stream metadata")
        single.consume(#"DROPLET_PROGRESS:[null,null]"#)
        expect(abs(single.progress - 0.475) < 0.0001, "missing progress ignored")
        expect(DownloadPolicy.metadataTemplate.contains("filesize_approx}|null)j"), "valid JSON default for optional fields")
        passed("single-file downloads and missing JSON fields")
        print("All \(count) core/runtime tests passed. No network downloads were performed.")
    }
}
