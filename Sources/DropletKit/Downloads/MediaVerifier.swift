import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import AudioToolbox

struct VerifiedMedia: Equatable, Sendable {
    let byteCount: Int64
    let duration: Double
    let container: String
    let videoCodec: String
    let audioCodec: String?
}

/// Native verification independent of the downloader's claimed extension.
/// Validates structure/codecs and decodes the first sample of every media track;
/// this is not a promise that every frame of a long file has been decoded.
struct MediaVerifier {
    enum Failure: Error, Equatable {
        case notRegularFile, emptyFile, unsupportedContainer, notPlayable
        case invalidDuration, missingVideo, unsupportedCodec, undecodableTrack
    }

    func verify(_ file: URL) async throws -> VerifiedMedia {
        try Task.checkCancellation()
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw Failure.notRegularFile }
        guard let size = attrs[.size] as? NSNumber, size.int64Value > 0 else { throw Failure.emptyFile }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4096) ?? Data()
        guard header.count >= 16, String(decoding: header[4..<8], as: UTF8.self) == "ftyp" else {
            throw Failure.unsupportedContainer
        }
        let brand = String(decoding: header[8..<12], as: UTF8.self)
        guard ["isom", "iso2", "mp41", "mp42", "avc1", "M4V ", "MSNV"].contains(brand) else {
            throw Failure.unsupportedContainer
        }
        let asset = AVURLAsset(url: file)
        guard try await asset.load(.isPlayable) else { throw Failure.notPlayable }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Failure.invalidDuration }
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard !videos.isEmpty else { throw Failure.missingVideo }
        for track in videos + audios {
            try Task.checkCancellation()
            let video = track.mediaType == .video
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty,
                  descriptions.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == (video ? kCMVideoCodecType_H264 : kAudioFormatMPEG4AAC) }) else {
                throw Failure.unsupportedCodec
            }
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = video
                ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                : [AVFormatIDKey: kAudioFormatLinearPCM]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            guard reader.canAdd(output) else { throw Failure.undecodableTrack }
            reader.add(output)
            guard reader.startReading() else { throw Failure.undecodableTrack }
            let sample = output.copyNextSampleBuffer()
            let decoded = sample.map { CMSampleBufferIsValid($0) && CMSampleBufferGetNumSamples($0) > 0 } ?? false
            let failed = reader.status == .failed
            reader.cancelReading()
            guard decoded, !failed else { throw Failure.undecodableTrack }
        }
        try Task.checkCancellation()
        return VerifiedMedia(byteCount: size.int64Value, duration: duration, container: "mp4",
                             videoCodec: "h264", audioCodec: audios.isEmpty ? nil : "aac")
    }
}
