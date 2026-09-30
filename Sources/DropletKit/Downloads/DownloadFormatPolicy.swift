/// Unknown codec labels are allowed provisionally, then checked from the actual
/// media. Known incompatible codecs are never hidden by changing the extension.
/// A video-only fallback is accepted only when final verification proves that
/// audio known to exist in the source was not lost.
enum DownloadFormatPolicy {
    static let selector = "bestvideo[ext=mp4][vcodec~=?'^(avc1|h264)']+bestaudio[ext=m4a][acodec~=?'^(mp4a|aac)']/best[ext=mp4][vcodec~=?'^(avc1|h264)'][acodec~=?'^(mp4a|aac)']/bestvideo[ext=mp4][vcodec~=?'^(avc1|h264)']"
}
