import Foundation
import Darwin

/// Validation may suspend; publication must follow a final cancellation/run-token
/// check by the owner. Keeping these separate prevents a cancelled async check
/// from publishing a file after a replacement download has started.
struct DownloadFinalizer {
    struct Prepared {
        fileprivate let sourceURL: URL
        fileprivate let identity: VideoIdentity
        fileprivate let stagedFile: URL
        fileprivate let title: String
        fileprivate let media: VerifiedMedia
    }

    func prepare(workspace: DownloadWorkspace, reported: URL, source: URL,
                 identity: VideoIdentity, title: String, expectsAudio: Bool = false,
                 verify: @Sendable (URL) async throws -> VerifiedMedia = { try await MediaVerifier().verify($0) }) async throws -> Prepared {
        guard !identity.extractor.isEmpty, !identity.mediaID.isEmpty else {
            throw Failure.missingIdentity
        }
        let candidate = try workspace.checkedFile(reported)
        let media = try await verify(candidate.url)
        try Task.checkCancellation()
        if expectsAudio && media.audioCodec == nil { throw Failure.missingSourceAudio }
        guard candidate.size == media.byteCount else { throw DownloadWorkspace.Failure.changedOutput }
        return Prepared(sourceURL: source, identity: identity, stagedFile: candidate.url,
                        title: title, media: media)
    }

    func commit(_ prepared: Prepared, workspace: DownloadWorkspace) throws -> DownloadResult {
        try Task.checkCancellation()
        let final = try workspace.publish(prepared.stagedFile, expectedSize: prepared.media.byteCount,
                                          title: prepared.title, identity: prepared.identity.storageKey)
        return DownloadResult(sourceURL: prepared.sourceURL, identity: prepared.identity,
                              fileURL: final, media: prepared.media, isNewFile: true)
    }

    enum Failure: Error { case missingIdentity, missingSourceAudio }

    static func message(for error: Error) -> String {
        if error is MediaVerifier.Failure {
            return "The downloaded file is not a playable MP4 with H.264 video and optional AAC audio. No final file was saved."
        }
        if case Failure.missingSourceAudio = error {
            return "This source has audio, but a compatible audio track could not be saved. No silent replacement was saved."
        }
        if error is Failure {
            return "The download engine did not identify this video. No final file was saved."
        }
        if case DownloadWorkspace.Failure.invalidFolder = error {
            return "The download folder is not a regular folder, or it is a symbolic link. Choose another folder in Settings."
        }
        let ns = error as NSError
        let code: Int32?
        if case let DownloadWorkspace.Failure.filesystem(value) = error { code = value }
        else if ns.domain == NSPOSIXErrorDomain { code = Int32(ns.code) }
        else if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
                underlying.domain == NSPOSIXErrorDomain { code = Int32(underlying.code) }
        else { code = nil }
        if code == ENOSPC || (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError) {
            return "There is not enough disk space. Free some space and try again."
        }
        if code == EACCES || code == EPERM || (ns.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code)) {
            return "Droplet cannot access your download folder. Check its permissions or choose another folder in Settings."
        }
        if code == ENOENT || (ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code)) {
            return "The download folder or file was moved or removed. Restore it or choose another folder in Settings."
        }
        return "The downloaded file could not be safely checked or saved. No existing file was overwritten. Please try again."
    }
}
