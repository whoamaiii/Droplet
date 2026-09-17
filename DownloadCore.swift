import Foundation

struct Attempt {
    let note: String
    let extra: [String]
}

struct DownloadRequest {
    let id = UUID()
    let url: URL
    let executable: URL
    let ffmpeg: URL
    let attempts: [Attempt]
    let outputTemplate: String
}

enum EngineTools {
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        paths += ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin",
                  "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let pythonRoot = home + "/Library/Python"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: pythonRoot)) ?? []
        paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { pythonRoot + "/" + $0 + "/bin" }
        var seen = Set<String>()
        env["PATH"] = paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        return env
    }

    static func find(_ name: String, override: String? = nil) -> URL? {
        let env = environment
        if let override, let path = env[override], !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: expanded) else { return nil }
            return URL(fileURLWithPath: expanded)
        }
        for directory in (env["PATH"] ?? "").split(separator: ":") {
            let path = String(directory) + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static func isInside(_ executable: URL, prefix: URL) -> Bool {
        let root = prefix.resolvingSymlinksInPath().standardizedFileURL.path
        let path = executable.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root + "/")
    }
}

enum DownloadPolicy {
    // Strict H.264/AAC selection, not merely an MP4 extension. No silent VP9/Opus
    // fallback; fail clearly when the site offers no compatible combination.
    static let format = "bv[ext=mp4][vcodec~='^(avc1|h264)']+ba[ext=m4a][acodec~='^(mp4a|aac)']/b[ext=mp4][vcodec~='^(avc1|h264)'][acodec~='^(mp4a|aac)']"
    // yt-dlp skips the JSON conversion when a field is missing. Explicit null
    // defaults keep the enclosing array valid for combined/single-file formats.
    static let metadataTemplate = "before_dl:DROPLET_META:[%(title|null)j,%(requested_formats.:.{format_id,filesize,filesize_approx}|null)j,%(format_id|null)j]"
    static let progressTemplate = "download:DROPLET_PROGRESS:[%(info.format_id|null)j,%(progress._percent_str|null)j]"

    static func arguments(for request: DownloadRequest, attempt: Attempt) -> [String] {
        ["--ignore-config", "--no-playlist", "--newline", "--no-colors", "--progress",
         "--no-simulate", "--no-mtime", "--no-overwrites", "--continue",
         "--ffmpeg-location", request.ffmpeg.path,
         "--retries", "8", "--fragment-retries", "8", "--retry-sleep", "1",
         "--print", metadataTemplate, "--progress-template", progressTemplate,
         "--progress-template", "postprocess:DROPLET_POSTPROCESS",
         "--print", "after_move:DROPLET_FILE:%(filepath|null)j",
         "--referer", request.url.absoluteString,
         "-f", format, "--merge-output-format", "mp4",
         "-o", request.outputTemplate] + attempt.extra + ["--", request.url.absoluteString]
    }

    static func isYouTube(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host == "youtube.com" || host.hasSuffix(".youtube.com") ||
               host == "youtu.be" || host.hasSuffix(".youtu.be")
    }

    static func attempts(for url: URL, browsers: [String]) -> [Attempt] {
        var result = [Attempt(note: "", extra: [])]
        if isYouTube(url) {
            result.append(Attempt(note: "Retrying with an alternate YouTube client…",
                                  extra: ["--extractor-args", "youtube:player_client=default,web_safari"]))
        }
        for browser in browsers {
            result.append(Attempt(note: "Retrying with \(browser.capitalized) cookies…",
                                  extra: ["--cookies-from-browser", browser]))
        }
        return result
    }

    static func installedCookieBrowsers() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ("safari", home + "/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
            ("chrome", home + "/Library/Application Support/Google/Chrome"),
            ("brave", home + "/Library/Application Support/BraveSoftware/Brave-Browser"),
            ("edge", home + "/Library/Application Support/Microsoft Edge"),
            ("firefox", home + "/Library/Application Support/Firefox/Profiles")
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.1) }.map { $0.0 }
    }

    private static let botPattern = try? NSRegularExpression(pattern: #"\b(?:not a bot|bot check|bot-check|captcha|sign in to confirm)\b"#, options: .caseInsensitive)
    private static let forbiddenPattern = try? NSRegularExpression(pattern: #"\b403\b|\bforbidden\b"#, options: .caseInsensitive)
    private static func matches(_ regex: NSRegularExpression?, _ message: String) -> Bool {
        regex?.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) != nil
    }

    static func hint(for message: String) -> String? {
        let lower = message.lowercased()
        if lower.contains("requested format is not available") {
            return "This site did not offer the H.264 video + AAC audio required by Droplet's compatible MP4 mode. Update the engine or choose another source; Droplet will not disguise incompatible codecs as MP4."
        }
        if matches(botPattern, message) {
            return "The site requested a human check. Update the engine, or sign in through your browser and retry. Browser-cookie access may require macOS permission."
        }
        if matches(forbiddenPattern, message) {
            return "The site refused access. Try updating the engine or copy a fresh link from a page you can access while signed in. An update is not guaranteed to resolve this."
        }
        if lower.contains("private video") || lower.contains("login required") || lower.contains("members-only") {
            return "This video requires an authorized signed-in session. Sign in using your browser, then retry."
        }
        if lower.contains("not available") || lower.contains("unavailable") || lower.contains("removed") {
            return "The video may be unavailable, region-restricted, or removed."
        }
        return nil
    }
}

/// Aggregate progress across the selected streams. Size-weighted when every
/// stream has a size estimate, otherwise equal-stage weighted. Reserve the last
/// 5% for merge/postprocessing; 100% means successful command completion only.
struct DownloadOutput {
    private(set) var title = ""
    private(set) var progress = 0.0
    private(set) var stage = "Fetching video…"
    private(set) var savedPath: String?
    private var weights: [String: Double] = [:]
    private var fractions: [String: Double] = [:]

    private static func json(after prefix: String, in line: String) -> Any? {
        guard line.hasPrefix(prefix) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(line.dropFirst(prefix.count).utf8), options: [.fragmentsAllowed])
    }
    private static func identifier(_ value: Any) -> String? {
        if let s = value as? String, !s.isEmpty, s != "NA" { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    mutating func consume(_ line: String) {
        if let meta = Self.json(after: "DROPLET_META:", in: line) as? [Any], meta.count == 3 {
            title = meta[0] as? String ?? ""
            let streams = meta[1] as? [[String: Any]] ?? []
            let known = streams.compactMap { stream -> (String, Double?)? in
                guard let id = stream["format_id"].flatMap(Self.identifier) else { return nil }
                let size = (stream["filesize"] as? NSNumber)?.doubleValue ??
                           (stream["filesize_approx"] as? NSNumber)?.doubleValue
                return (id, size.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
            }
            let sizeWeighted = !known.isEmpty && known.allSatisfy { $0.1 != nil }
            weights.removeAll(); fractions.removeAll()
            for (id, size) in known { weights[id] = sizeWeighted ? (size ?? 1) : 1 }
            if weights.isEmpty, let id = Self.identifier(meta[2]) { weights[id] = 1 }
            stage = "Downloading…"
        } else if let fields = Self.json(after: "DROPLET_PROGRESS:", in: line) as? [Any], fields.count == 2,
                  let id = Self.identifier(fields[0]), let text = fields[1] as? String,
                  let percent = Double(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)),
                  percent.isFinite {
            guard weights[id] != nil else {
                // Unknown stream layout: don't lie by announcing 100% per file.
                stage = "Downloading stream…"
                return
            }
            fractions[id] = max(fractions[id] ?? 0, min(1, max(0, percent / 100)))
            let total = weights.values.reduce(0, +)
            let completed = weights.reduce(0.0) { $0 + $1.value * (fractions[$1.key] ?? 0) }
            if total > 0 { progress = max(progress, min(0.95, 0.95 * completed / total)) }
            let finished = fractions.values.filter { $0 >= 1 }.count
            stage = finished == weights.count ? "Finishing MP4…" : "Downloading \(weights.count > 1 ? "video + audio" : "video")…"
        } else if line.hasPrefix("DROPLET_POSTPROCESS") || line.hasPrefix("[Merger]") {
            progress = max(progress, 0.95)
            stage = "Finishing MP4…"
        } else if let path = Self.json(after: "DROPLET_FILE:", in: line) as? String {
            savedPath = path
        }
    }
}
