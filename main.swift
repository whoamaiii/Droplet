//
//  Droplet — one-click menu-bar video downloader (yt-dlp front end).
//  Click the droplet in the menu bar → press Download → the URL in your
//  clipboard is saved as an MP4 into ~/Downloads. No dialogs, no approvals.
//
//  Swift + SwiftUI + AppKit. Single file, no external dependencies.
//

import Cocoa
import Combine
import SwiftUI

// MARK: - Download manager

@MainActor
final class DownloadManager: ObservableObject {

    enum Phase: Equatable {
        case idle
        case downloading
        case done
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var title: String = ""
    @Published var clipboardURL: URL?
    /// Shown in the bubble while a fallback attempt is running.
    @Published var retryNote: String = ""
    /// Status text for the "update download engine" action.
    @Published var updateNote: String = ""
    /// Bumps every time the bubble opens → the whole UI is re-created so the
    /// droplet entrance animation replays.
    @Published var session = 0

    let downloadsFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads")

    private var task: Process?
    private var lastErrorLine = ""

    /// One download attempt: a note shown in the UI plus extra yt-dlp args.
    private struct Attempt {
        let note: String
        let extra: [String]
    }
    private var attempts: [Attempt] = []
    private var attemptIndex = 0
    private var isCancelled = false
    /// Error from the very first attempt — what the user is told at the end.
    private var firstErrorLine = ""

    /// A realistic browser UA — many hosts (and YouTube) return
    /// 403 Forbidden to requests that look like a bare script.
    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    func beginSession() {
        session += 1
        if phase != .downloading {
            phase = .idle
            progress = 0
            title = ""
        }
        clipboardURL = Self.readClipboardURL()
    }

    func retryFromFailure() {
        phase = .idle
        progress = 0
    }

    static func readClipboardURL() -> URL? {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil else { return nil }
        return url
    }

    func startDownload() {
        if phase == .downloading { return }

        guard let url = clipboardURL ?? Self.readClipboardURL() else {
            clipboardURL = nil
            phase = .failed("No video link found in your clipboard.\nCopy a video URL first, then open Droplet again.")
            return
        }
        clipboardURL = url

        isCancelled = false
        firstErrorLine = ""
        attempts = Self.makeAttempts(for: url)
        runAttempt(0)
    }

    /// Builds the retry ladder. Attempt 1 is plain yt-dlp; the later attempts
    /// automatically apply the workarounds that fix the overwhelming majority
    /// of HTTP 403 / "forbidden" / bot-check / hotlink failures.
    private static func makeAttempts(for url: URL) -> [Attempt] {
        var ladder: [Attempt] = [Attempt(note: "", extra: [])]

        let host = (url.host() ?? "").lowercased()
        if host.contains("youtube") || host.contains("youtu.be") {
            // alternate player clients dodge YouTube's "Sign in to confirm
            // you're not a bot" 403 without needing any cookies
            ladder.append(Attempt(
                note: "Retrying with an alternate YouTube client…",
                extra: ["--extractor-args",
                        "youtube:player_client=default,web_safari,tv,ios"]))
        }
        // cookies from the user's own browser: fixes login-required and
        // signed-URL 403s (Instagram, TikTok, private/unlisted, age-gated, …).
        // Only browsers actually installed on this Mac are tried.
        for browser in installedCookieBrowsers() {
            ladder.append(Attempt(
                note: "Retrying with \(browser.capitalized) cookies…",
                extra: ["--cookies-from-browser", browser]))
        }
        return ladder
    }

    /// Browsers whose cookie stores exist on this Mac (skips pointless attempts
    /// and keeps the final error message about the real problem).
    private static func installedCookieBrowsers() -> [String] {
        let home = NSHomeDirectory()
        let candidates: [(String, String)] = [
            ("safari", home + "/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
            ("chrome", home + "/Library/Application Support/Google/Chrome"),
            ("brave",  home + "/Library/Application Support/BraveSoftware/Brave-Browser"),
            ("edge",   home + "/Library/Application Support/Microsoft Edge"),
            ("firefox", home + "/Library/Application Support/Firefox/Profiles"),
        ]
        return candidates
            .filter { FileManager.default.fileExists(atPath: $0.1) }
            .map { $0.0 }
    }

    /// Runs attempt number `index` of the ladder. On failure it automatically
    /// advances to the next workaround; only the last one reports an error.
    private func runAttempt(_ index: Int) {
        guard let url = clipboardURL, index < attempts.count else { return }
        attemptIndex = index
        let attempt = attempts[index]

        phase = .downloading
        progress = 0
        lastErrorLine = ""
        retryNote = attempt.note
        if index == 0 { title = "" }
        AppDelegate.debugLog("attempt \(index + 1)/\(attempts.count): \(attempt.note.isEmpty ? "base" : attempt.note)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp")
        process.arguments = [
            "--newline",
            "--no-playlist",
            "--no-warnings",
            "--no-mtime",
            "--ffmpeg-location", "/opt/homebrew/bin",
            "--retries", "8",
            "--fragment-retries", "8",
            "--retry-sleep", "1",
            // realistic browser headers — many hosts 403 script-looking requests
            "--user-agent", Self.browserUserAgent,
            "--referer", url.absoluteString,
            "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
            "--merge-output-format", "mp4",
            "-o", downloadsFolder.path + "/%(title)s.%(ext)s",
        ] + attempt.extra + [url.absoluteString]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: chunk, as: UTF8.self)

            // Compiled once per output chunk (cheap) so nothing isolated
            // is touched from this background closure.
            let percentRegex = try! NSRegularExpression(pattern: #"\[download\]\s+(\d+(?:\.\d+)?)%"#)
            let destRegex    = try! NSRegularExpression(pattern: #"\[download\] Destination: (.+)"#)
            let fragRegex    = try! NSRegularExpression(pattern: #"\.f\d+\.\w+$"#)

            func prettyTitle(_ path: String) -> String {
                var file = (path as NSString).lastPathComponent
                if let m = fragRegex.firstMatch(in: file, range: NSRange(file.startIndex..., in: file)) {
                    file = (file as NSString).substring(to: m.range.location)
                }
                if let dot = file.lastIndex(of: ".") {
                    file = String(file[..<dot])
                }
                return file
            }

            var percent: Double?
            var name: String?
            var errorLine: String?

            for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = String(rawLine)
                let range = NSRange(line.startIndex..., in: line)

                if let match = percentRegex.firstMatch(in: line, range: range),
                   let value = Double((line as NSString).substring(with: match.range(at: 1))) {
                    percent = value
                }
                if let match = destRegex.firstMatch(in: line, range: range) {
                    name = prettyTitle((line as NSString).substring(with: match.range(at: 1)))
                }
                if line.hasPrefix("ERROR:") {
                    errorLine = line
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                if let percent { self.progress = percent / 100.0 }
                if let name { self.title = name }
                if let errorLine { self.lastErrorLine = errorLine }
            }
        }

        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.task = nil

                if self.isCancelled {
                    self.phase = .idle
                    self.progress = 0
                    self.retryNote = ""
                    return
                }

                if finished.terminationStatus == 0 {
                    self.retryNote = ""
                    self.phase = .done
                    NSSound(named: "Tink")?.play()
                    return
                }

                if finished.terminationStatus == 15 {
                    // cancelled by the user — go quietly back to idle
                    self.phase = .idle
                    self.progress = 0
                    self.retryNote = ""
                    return
                }

                // failed → silently advance to the next workaround, if any
                let next = self.attemptIndex + 1
                if next < self.attempts.count {
                    if self.attemptIndex == 0 { self.firstErrorLine = self.lastErrorLine }
                    self.title = ""
                    self.runAttempt(next)
                    return
                }

                // report the ORIGINAL failure (not an incidental fallback error)
                var message = self.firstErrorLine.isEmpty ? self.lastErrorLine : self.firstErrorLine
                if message.hasPrefix("ERROR:") {
                    message = String(message.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                }
                if message.isEmpty {
                    message = "yt-dlp exited with status \(finished.terminationStatus)."
                }
                if let hint = Self.hint(for: message) {
                    message += "\n\n" + hint
                }
                self.retryNote = ""
                self.phase = .failed(message)
                NSSound(named: "Basso")?.play()
            }
        }

        do {
            try process.run()
            task = process
        } catch {
            retryNote = ""
            phase = .failed("Couldn't launch yt-dlp: \(error.localizedDescription)")
        }
    }

    /// Turns cryptic yt-dlp failures into something actionable.
    private static func hint(for message: String) -> String? {
        let lower = message.lowercased()
        if lower.contains("sign in to confirm") || lower.contains("bot") {
            return "YouTube is asking for a human check. Press ↻ in the footer to update the engine, or sign in to YouTube in Safari and press Try Again."
        }
        if lower.contains("403") || lower.contains("forbidden") {
            return "The site blocked the download. Press ↻ in the footer to update the download engine (fixes most of these), or open the page while signed in and copy the link fresh."
        }
        if lower.contains("private") || lower.contains("login") || lower.contains("members") {
            return "This video needs a signed-in session. Sign in with your browser, keep that browser's cookies, then press Try Again."
        }
        if lower.contains("not available") || lower.contains("unavailable") || lower.contains("removed") {
            return "The video may be region-locked or deleted."
        }
        return nil
    }

    private var killTimer: DispatchWorkItem?
    private var updateTask: Process?

    /// Updates the download engine (yt-dlp) in the background. YouTube and other
    /// sites change constantly, and a stale engine is the #1 cause of
    /// "HTTP Error 403: Forbidden" — so this is one click away.
    func updateDownloader() {
        guard updateTask == nil else { return }
        updateNote = "Updating yt-dlp…"
        AppDelegate.debugLog("update: brew upgrade yt-dlp")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        process.arguments = ["upgrade", "yt-dlp"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // drain the output so brew can never block on a full pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateTask = nil
                pipe.fileHandleForReading.readabilityHandler = nil
                if finished.terminationStatus == 0 {
                    let version = Self.ytDlpVersion()
                    self.updateNote = version.isEmpty ? "yt-dlp updated ✓" : "yt-dlp \(version) ✓"
                    AppDelegate.debugLog("update: done, version \(version)")
                } else {
                    self.updateNote = "Update failed — try: brew upgrade yt-dlp"
                    AppDelegate.debugLog("update: failed status \(finished.terminationStatus)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    if self?.updateTask == nil { self?.updateNote = "" }
                }
            }
        }

        do {
            try process.run()
            updateTask = process
        } catch {
            updateNote = "Couldn't run brew"
            AppDelegate.debugLog("update: launch failed \(error)")
        }
    }

    /// Installed yt-dlp version string ("" if unavailable).
    static func ytDlpVersion() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp")
        process.arguments = ["--version"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Soft-cancel (Cancel button): SIGTERM now, SIGKILL fallback in 1s.
    func cancel() {
        guard let process = task else { return }
        task = nil
        isCancelled = true
        phase = .idle
        progress = 0
        retryNote = ""
        let pid = process.processIdentifier
        process.terminate()   // SIGTERM — yt-dlp cleans up its ffmpeg children

        let timer = DispatchWorkItem {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
        killTimer = timer
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0, execute: timer)
    }

    /// Called when the user quits: guaranteed total shutdown.
    /// Kills any running download by polling the process directly — no
    /// waitUntilExit (its exit callback needs the main thread, which would
    /// deadlock the quit path) — so nothing can hang the shutdown.
    func shutdownForQuit() {
        killTimer?.cancel()
        killTimer = nil

        updateTask?.terminate()   // stop any engine update too
        updateTask = nil

        guard let process = task else { return }
        task = nil
        isCancelled = true
        phase = .idle
        progress = 0
        retryNote = ""

        // also stop an in-flight download-engine update
        updateTask?.terminate()
        updateTask = nil
        updateNote = ""

        let pid = process.processIdentifier
        process.terminate()   // SIGTERM — yt-dlp cleans up its ffmpeg children

        // wait up to 0.5s for a graceful exit...
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if kill(pid, 0) != 0 { break }   // process is gone
            Thread.sleep(forTimeInterval: 0.02)
        }
        // ...then hard-kill whatever is left (harmless if already a zombie)
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }

    /// Belt-and-suspenders: sweep the whole system for any yt-dlp / ffmpeg
    /// processes (including orphans from earlier runs) so quitting really
    /// leaves nothing running in the background.
    func sweepBackgroundProcesses() {
        let pkillPath = "/usr/bin/pkill"
        let patterns = ["yt-dlp", "ffmpeg"]

        // polite SIGTERM pass
        for pattern in patterns {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: pkillPath)
            p.arguments = ["-TERM", "-f", pattern]
            try? p.run()
            p.waitUntilExit()
        }

        // brief grace period, then force-kill pass
        Thread.sleep(forTimeInterval: 0.3)
        for pattern in patterns {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: pkillPath)
            p.arguments = ["-KILL", "-f", pattern]
            try? p.run()
            p.waitUntilExit()
        }
    }
}

// MARK: - Visuals

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct DropletShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        guard w > 1, h > 1 else { return Path() }

        let y0 = h * 0.60      // top of the round belly
        let r = w * 0.5        // belly radius
        let k = 0.5523 * r     // cubic-circle approximation constant

        var p = Path()
        p.move(to: CGPoint(x: w * 0.5, y: 0))
        p.addQuadCurve(to: CGPoint(x: 0, y: y0),
                       control: CGPoint(x: w * 0.06, y: h * 0.26))
        p.addCurve(to: CGPoint(x: w * 0.5, y: y0 + r),
                   control1: CGPoint(x: 0, y: y0 + k),
                   control2: CGPoint(x: w * 0.5 - k, y: y0 + r))
        p.addCurve(to: CGPoint(x: w, y: y0),
                   control1: CGPoint(x: w * 0.5 + k, y: y0 + r),
                   control2: CGPoint(x: w, y: y0 + k))
        p.addQuadCurve(to: CGPoint(x: w * 0.5, y: 0),
                       control: CGPoint(x: w * 0.94, y: h * 0.26))
        p.closeSubpath()
        return p
    }
}

struct DropletHeader: View {
    @State private var droppedIn = false
    @State private var ripple = false
    @State private var bob = false

    var body: some View {
        ZStack {
            // ripple rings expanding after the drop lands
            Circle()
                .stroke(Color.cyan.opacity(ripple ? 0 : 0.55), lineWidth: 2)
                .frame(width: 34, height: 34)
                .scaleEffect(ripple ? 3.2 : 0.7)
                .animation(.easeOut(duration: 0.9).delay(0.35), value: ripple)

            Circle()
                .stroke(Color.blue.opacity(ripple ? 0 : 0.40), lineWidth: 1.5)
                .frame(width: 34, height: 34)
                .scaleEffect(ripple ? 2.4 : 0.7)
                .animation(.easeOut(duration: 0.9).delay(0.50), value: ripple)

            // the droplet itself: falls in with a springy bounce, then floats
            DropletShape()
                .fill(
                    LinearGradient(colors: [.cyan, .blue, .indigo],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 44, height: 56)
                .overlay(
                    Ellipse()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 9, height: 15)
                        .blur(radius: 1.5)
                        .offset(x: -10, y: 10)
                )
                .shadow(color: .blue.opacity(0.5), radius: 12, y: 5)
                .scaleEffect(droppedIn ? 1 : 0.8, anchor: .bottom)
                .offset(y: droppedIn ? 0 : -90)
                .animation(.spring(response: 0.55, dampingFraction: 0.6).delay(0.05), value: droppedIn)
                .offset(y: bob ? -3.5 : 3.5)
                .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true).delay(1.0), value: bob)
        }
        .frame(height: 96)
        .clipped()
        .padding(.top, 14)
        .onAppear {
            droppedIn = true
            ripple = true
            bob = true
        }
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Main bubble UI

struct MainView: View {
    @ObservedObject var manager: DownloadManager
    var onOpenDownloads: () -> Void
    var onQuit: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DropletHeader()

            Text("Droplet")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .padding(.top, 2)

            Text("Clipboard → MP4 in your Downloads")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)

            Group {
                switch manager.phase {
                case .idle:           idleView
                case .downloading:    downloadingView
                case .done:           doneView
                case .failed(let message): failedView(message)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .frame(maxHeight: .infinity, alignment: .top)

            footer
        }
        .frame(width: 320, height: 420)
        .background(VisualEffectView())
        .onChange(of: manager.phase) { _, newPhase in
            if newPhase == .done {
                // seamless: success → auto-close the bubble
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { onClose() }
            }
        }
        .id(manager.session)   // replays the droplet animation every time
    }

    // MARK: idle

    @ViewBuilder
    private var linkPreview: some View {
        if let url = manager.clipboardURL {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.host() ?? url.absoluteString)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(url.path.isEmpty ? "/" : url.path)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quinary))
        } else {
            HStack(spacing: 6) {
                Image(systemName: "clipboard")
                    .font(.system(size: 10, weight: .semibold))
                Text("Copy a video link — it shows up here")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.tertiary)
            .padding(.vertical, 6)
        }
    }

    private var idleView: some View {
        VStack(spacing: 14) {
            linkPreview

            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    manager.startDownload()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 14, weight: .bold))
                    Text(manager.clipboardURL == nil ? "Grab Link from Clipboard" : "Download")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    Capsule().fill(
                        LinearGradient(colors: [.cyan, .blue, .indigo],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                )
                .shadow(color: .blue.opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(PressableButtonStyle())

            // Explicit full-quit: closes the app AND kills every background
            // yt-dlp/ffmpeg process on the system.
            Button {
                onQuit()
            } label: {
                Label("Quit Droplet — stop everything", systemImage: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(.quinary))
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, 2)
        }
    }

    // MARK: downloading

    private var downloadingView: some View {
        VStack(spacing: 14) {
            Text(manager.title.isEmpty ? "Fetching video…" : manager.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quinary)
                    Capsule()
                        .fill(LinearGradient(colors: [.cyan, .blue, .indigo],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(10, geo.size.width * manager.progress))
                }
            }
            .frame(height: 9)
            .animation(.linear(duration: 0.25), value: manager.progress)

            HStack(spacing: 10) {
                Text("\(Int(manager.progress * 100))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Button {
                    manager.cancel()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if !manager.retryNote.isEmpty {
                Text(manager.retryNote)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 4)
    }

    // MARK: done

    private var doneView: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.green, .teal],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(.white)
            }
            .shadow(color: .green.opacity(0.45), radius: 12, y: 4)
            .transition(.scale(scale: 0.4).combined(with: .opacity))

            Text("Saved to Downloads")
                .font(.system(size: 15, weight: .bold))

            if !manager.title.isEmpty {
                Text(manager.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
            }

            Button {
                onOpenDownloads()
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.link)
        }
    }

    // MARK: failed

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.yellow.gradient)
            Text(message)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(9)
                .padding(.horizontal, 2)
            Button {
                withAnimation { manager.retryFromFailure() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(
                        Capsule().fill(
                            LinearGradient(colors: [.orange, .red],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                    )
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button {
                onOpenDownloads()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("Open Downloads folder")

            Spacer()

            if !manager.updateNote.isEmpty {
                Text(manager.updateNote)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("yt-dlp · MP4 · 1000+ sites")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.quaternary)
            }

            Spacer()

            Button {
                manager.updateDownloader()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Update download engine (yt-dlp)")

            Button {
                onQuit()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Quit Droplet")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }
}

// MARK: - App delegate & bootstrap

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let manager = DownloadManager()
    private var phaseCancellable: AnyCancellable?
    private var lastCloseAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        // single-instance guard (first-one-wins): if another Droplet is already
        // in the menu bar, this newborn exits quietly. Never kill the other
        // instance — killing launchd's KeepAlive instance triggers a respawn
        // war (the other instance would kill us back mid-quit).
        if anotherDropletInstanceIsRunning() {
            exit(0)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Droplet")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item

        let root = MainView(
            manager: manager,
            onOpenDownloads: { [weak self] in self?.openDownloads() },
            onQuit: { [weak self] in self?.quitApp() },
            onClose: { [weak self] in self?.popover.performClose(nil) }
        )
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []          // fixed bubble size, no jumping
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient    // click anywhere else to dismiss
        popover.animates = true
        popover.delegate = self

        phaseCancellable = manager.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.updateStatusIcon(for: phase) }

        // Hidden self-test for the engine updater: --smoke-update
        if CommandLine.arguments.contains("--smoke-update") {
            manager.updateDownloader()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                if let note = self?.manager.updateNote { Self.debugLog("update note: '\(note)'") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                if let note = self?.manager.updateNote { Self.debugLog("note after clear: '\(note)'") }
                self?.quitApp()
            }
        }

        // Hidden self-test: launch with "--smoke-test" to verify the quit
        // path kills a live download completely (used by build verification).
        // Optional: --smoke-url=<url> to override, --smoke-quit=<seconds>.
        if CommandLine.arguments.contains("--smoke-test") {
            let urlArg = CommandLine.arguments
                .first { $0.hasPrefix("--smoke-url=") }?
                .replacingOccurrences(of: "--smoke-url=", with: "")
            manager.clipboardURL = URL(string: urlArg ?? "https://www.youtube.com/watch?v=jNQXAC9IVRw")
            manager.startDownload()

            let quitAfter = CommandLine.arguments
                .first { $0.hasPrefix("--smoke-quit=") }
                .map { $0.replacingOccurrences(of: "--smoke-quit=", with: "") }
                .flatMap { Double($0) } ?? 2.5

            DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) { [weak self] in
                if let phase = self?.manager.phase { Self.debugLog("final phase: \(phase)") }
                self?.quitApp()
            }
        }
    }

    /// Debug helper — prints to stdout only when DROPLET_DEBUG=1 is set.
    static func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["DROPLET_DEBUG"] == "1" else { return }
        print("[droplet] \(message)")
        fflush(stdout)
    }

    private func updateStatusIcon(for phase: DownloadManager.Phase) {
        guard let button = statusItem?.button else { return }
        switch phase {
        case .downloading:
            button.image = NSImage(systemSymbolName: "drop.circle.fill", accessibilityDescription: nil)
            button.contentTintColor = NSColor.controlAccentColor
        case .done:
            button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            button.contentTintColor = NSColor.systemGreen
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                guard let self, case .done = self.manager.phase else { return }
                self.setBaseIcon()
            }
        default:
            setBaseIcon()
        }
    }

    private func setBaseIcon() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Droplet")
        button.contentTintColor = nil
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else if Date().timeIntervalSince(lastCloseAt) > 0.3 {
            manager.beginSession()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        lastCloseAt = Date()
        // if a download is running it just continues in the background —
        // the menu-bar icon stays switched to the "active" droplet
    }

    private func openDownloads() {
        NSWorkspace.shared.open(manager.downloadsFolder)
    }

    // MARK: quitting — full shutdown, no background leftovers

    /// There is a launchd LaunchAgent (~/Library/LaunchAgents/com.quentinthiessen.droplet.plist)
    /// with KeepAlive=true that restarts this app ~2s after it exits.
    /// Booting the job out tells launchd to stand down — quitting then REALLY quits.
    /// (The agent reloads at next login, so autostart still works after reboot.)
    private func bootOutKeepAliveAgent() {
        let uid = getuid()
        let commands: [[String]] = [
            ["bootout", "gui/\(uid)/com.quentinthiessen.droplet"],
            ["remove", "com.quentinthiessen.droplet"],
            ["unload", NSHomeDirectory() + "/Library/LaunchAgents/com.quentinthiessen.droplet.plist"],
        ]
        for args in commands {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    /// True if another running app has our bundle id.
    private func anotherDropletInstanceIsRunning() -> Bool {
        let myPID = getpid()
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
                && $0.processIdentifier != myPID
        }
    }

    /// Force-terminate every other running Droplet instance so no duplicate
    /// menu-bar droplets survive. Only used in the quit path.
    private func terminateOtherDropletInstances() {
        let myPID = getpid()
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == Bundle.main.bundleIdentifier
           && app.processIdentifier != myPID {
            app.forceTerminate()
        }
    }

    private func quitApp() {
        popover.performClose(nil)
        manager.shutdownForQuit()             // kill our own running download
        manager.sweepBackgroundProcesses()    // kill ANY leftover yt-dlp/ffmpeg
        bootOutKeepAliveAgent()               // tell launchd to stand down (may
                                              // SIGTERM us if launchd owns us —
                                              // cleanup is already done by then)
        terminateOtherDropletInstances()      // no duplicate icons either
        fflush(stdout)
        exit(0)                               // unconditional: app can never survive
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // any other quit path (logout, etc.) runs the same full shutdown
        quitApp()
        return .terminateNow
    }
}

@MainActor
private func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu-bar-only: no Dock icon
    app.run()
}

await runApp()
