import Foundation
import CoreFoundation

enum DownloadStage: String, Equatable {
    case fetching = "Fetching video…"
    case video = "Downloading video"
    case audio = "Downloading audio"
    case media = "Downloading media"
    case merging = "Merging video and audio…"
    case processing = "Processing file…"
    case finalizing = "Finishing file…"
}

/// Explicit JSON fields from yt-dlp, scoped by a per-attempt marker. Titles and
/// file paths are JSON-escaped by yt-dlp rather than parsed from terminal prose.
struct DownloadOutputProtocol {
    let marker: String
    init(marker: String = "DROPLET_" + UUID().uuidString + ":") { self.marker = marker }

    var arguments: [String] {
        let download = #"{"event":"download","status":%(progress.status)j,"downloaded":%(progress.downloaded_bytes)j,"total":%(progress.total_bytes,progress.total_bytes_estimate)j,"vcodec":%(info.vcodec)j,"acodec":%(info.acodec)j,"title":%(info.title)j}"#
        let postprocess = #"{"event":"postprocess","processor":%(progress.postprocessor)j,"title":%(info.title)j}"#
        let result = #"{"event":"result","path":%(filepath)j,"title":%(title)j,"extractor":%(extractor_key,extractor)j,"id":%(id)j,"audio_codecs":%(formats.:.acodec)j,"acodec":%(acodec)j}"#
        return ["--output-na-placeholder", "null", "--no-simulate", "--progress", "--newline", "--no-colors",
                "--progress-template", "download:" + marker + download,
                "--progress-template", "postprocess:" + marker + postprocess,
                "--print", "after_move:" + marker + result]
    }

    enum Event: Equatable {
        case transfer(DownloadStage, Double?, String?)
        case processing(DownloadStage, String?)
        case result(String, String?, VideoIdentity, Bool)
        case error(String)
        case malformed
    }

    func parse(_ line: String) -> Event? {
        if line.hasPrefix("ERROR:") { return .error(line) }
        guard line.hasPrefix(marker) else { return nil }
        guard let data = String(line.dropFirst(marker.count)).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any], let kind = fields["event"] as? String else { return .malformed }
        let title = (fields["title"] as? String).flatMap { $0 == "NA" ? nil : $0 }
        switch kind {
        case "download":
            guard let status = fields["status"] as? String,
                  ["downloading", "finished"].contains(status) else { return .malformed }
            let vcodec = fields["vcodec"] as? String
            let acodec = fields["acodec"] as? String
            let stage: DownloadStage = vcodec == "none" ? .audio : (acodec == "none" ? .video : .media)
            func number(_ key: String) -> Double? {
                guard let value = fields[key] as? NSNumber,
                      CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                      value.doubleValue >= 0 else { return nil }
                return value.doubleValue
            }
            let downloaded = number("downloaded")
            let total = number("total")
            let fraction: Double? = total.flatMap { total in
                guard total > 0, let downloaded else { return nil }
                // Transfer percent is scoped to this stream. Keep the visible
                // bar below complete while the file is still being processed.
                return min(0.99, max(0, downloaded / total))
            }
            return .transfer(stage, fraction, title)
        case "postprocess":
            guard let processor = fields["processor"] as? String else { return .malformed }
            return .processing(processor == "Merger" ? .merging : .processing, title)
        case "result":
            guard let path = fields["path"] as? String, path.hasPrefix("/"), !path.contains("\0") else { return .malformed }
            guard let extractor = fields["extractor"] as? String, !extractor.isEmpty,
                  let id = fields["id"] as? String, !id.isEmpty else { return .malformed }
            guard fields.keys.contains("audio_codecs"), fields.keys.contains("acodec") else { return .malformed }
            let codecs = ((fields["audio_codecs"] as? [Any])?.compactMap { $0 as? String } ?? []) + [fields["acodec"] as? String ?? "none"]
            let hasAudio = codecs.contains { !["none", "null", "NA", ""].contains($0) }
            return .result(path, title, VideoIdentity(extractor: extractor, mediaID: id), hasAudio)
        default: return .malformed
        }
    }
}
