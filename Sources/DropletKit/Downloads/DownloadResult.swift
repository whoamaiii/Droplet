import Foundation

struct VideoIdentity: Equatable, Sendable {
    let extractor: String
    let mediaID: String
    var storageKey: String { extractor + ":" + mediaID }
}

/// Produced only after media verification and atomic publication. Fresh isolated
/// staging means an engine's pre-existing destination can never earn new credit.
struct DownloadResult: Equatable, Sendable {
    let sourceURL: URL
    let identity: VideoIdentity
    let fileURL: URL
    let media: VerifiedMedia
    let isNewFile: Bool
    var byteCount: Int64 { media.byteCount }
}
