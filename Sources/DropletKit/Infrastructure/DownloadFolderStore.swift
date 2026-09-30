import Foundation

/// A local bookmark follows a renamed/moved folder without storing credentials.
/// Missing/corrupt bookmarks are not silently treated as a fresh default choice.
struct DownloadFolderStore {
    let defaults: UserDefaults
    private let key = "downloadFolderBookmark.v1"

    func load() throws -> URL? {
        guard let value = defaults.object(forKey: key) else { return nil }
        guard let data = value as? Data else { throw CocoaError(.fileReadCorruptFile) }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        try Self.validate(url)
        if stale { try save(url) }
        return url
    }

    func save(_ url: URL) throws {
        try Self.validate(url)
        let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: key)
    }

    static func validate(_ url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
    }
}
