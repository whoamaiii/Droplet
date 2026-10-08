import Foundation
import Darwin

/// The executables a download needs. `jsRuntime` is passed to yt-dlp
/// explicitly; YouTube requires a JavaScript runtime for its challenges.
struct EngineLocation: Equatable {
    var downloader: URL
    var ffmpegDirectory: URL
    var jsRuntime: URL?
    /// True when the engine ships inside the signed app bundle.
    var isBundled: Bool
}

/// Customer builds carry the engine in `Contents/Helpers`. A newer yt-dlp
/// fetched by the in-app updater is preferred only while it is newer than the
/// bundled copy, so an app update with a fresher engine wins automatically.
/// Development builds without helpers fall back to Homebrew.
enum EngineLocator {
    static let downloaderName = "yt-dlp"
    static let ffmpegName = "ffmpeg"
    static let ffprobeName = "ffprobe"
    static let jsRuntimeName = "deno"

    static func resolve(helpers: URL?, updated: (url: URL, version: String)?, bundledVersion: String?,
                        developmentDirectories: [URL], isExecutable: (URL) -> Bool) -> EngineLocation {
        if let helpers,
           isExecutable(helpers.appendingPathComponent(downloaderName)),
           isExecutable(helpers.appendingPathComponent(ffmpegName)) {
            var downloader = helpers.appendingPathComponent(downloaderName)
            if let updated, EngineVersion.isNewer(updated.version, than: bundledVersion) {
                downloader = updated.url
            }
            let runtime = helpers.appendingPathComponent(jsRuntimeName)
            return EngineLocation(downloader: downloader, ffmpegDirectory: helpers,
                                  jsRuntime: isExecutable(runtime) ? runtime : nil, isBundled: true)
        }
        for directory in developmentDirectories where isExecutable(directory.appendingPathComponent(downloaderName)) {
            // A development runtime on PATH is found by yt-dlp itself.
            return EngineLocation(downloader: directory.appendingPathComponent(downloaderName),
                                  ffmpegDirectory: directory, jsRuntime: nil, isBundled: false)
        }
        // Nothing usable: keep the expected bundle location so the launch
        // failure is reported as a missing engine.
        let expected = helpers ?? developmentDirectories.first ?? URL(fileURLWithPath: "/opt/homebrew/bin")
        return EngineLocation(downloader: expected.appendingPathComponent(downloaderName),
                              ffmpegDirectory: expected, jsRuntime: nil, isBundled: helpers != nil)
    }

    static var bundleHelpers: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    static var live: EngineLocation {
        resolve(helpers: bundleHelpers,
                updated: UpdatedEngineStore.live.installed(),
                bundledVersion: Bundle.main.object(forInfoDictionaryKey: "DropletBundledEngineVersion") as? String,
                developmentDirectories: [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")],
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }
}

/// yt-dlp versions are dates with an optional build suffix: 2026.08.19 or
/// 2026.08.19.123456. Anything else is not comparable and never wins.
enum EngineVersion {
    static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (3...4).contains(parts.count) else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.count <= 9, part.allSatisfy(\.isASCII), let value = Int(part), value >= 0 else { return nil }
            values.append(value)
        }
        return values
    }

    static func isNewer(_ candidate: String, than baseline: String?) -> Bool {
        guard let new = components(candidate) else { return false }
        guard let baseline, let old = components(baseline) else { return true }
        let width = max(new.count, old.count)
        let a = new + Array(repeating: 0, count: width - new.count)
        let b = old + Array(repeating: 0, count: width - old.count)
        return b.lexicographicallyPrecedes(a)
    }
}

/// Staging and installation of an updated engine. The signed bundle is never
/// modified; the in-app updater works on a private copy.
protocol EngineStaging {
    /// Copies `current` to a fresh private staging location and returns it.
    func prepareStaging(from current: URL) throws -> URL
    /// Atomically replaces the installed update with `staged`.
    func install(staged: URL, version: String) throws -> URL
    func discard(staged: URL)
}

enum EngineStagingError: Error, Equatable {
    /// The current engine is not a standalone yt-dlp this app may update
    /// (for example a Homebrew development install).
    case unsupported
    case unsafeLocation
    case invalidVersion
}

struct UpdatedEngineStore: EngineStaging {
    let directory: URL
    /// Only standalone copies from these directories may be updated.
    let updatableSources: [URL]

    static var live: UpdatedEngineStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Droplet/Engine", isDirectory: true)
        return UpdatedEngineStore(directory: support, updatableSources: [EngineLocator.bundleHelpers, support])
    }

    private var executable: URL { directory.appendingPathComponent(EngineLocator.downloaderName) }
    private var metadataFile: URL { directory.appendingPathComponent("engine.json") }
    private struct Metadata: Codable { let version: String }

    /// The installed update, if it is a private, user-owned executable with a
    /// recorded version. Anything else is ignored rather than executed.
    func installed() -> (url: URL, version: String)? {
        guard Self.isPrivate(directory, directory: true), Self.isPrivate(executable, directory: false),
              let data = try? Data(contentsOf: metadataFile), data.count <= 4096,
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              EngineVersion.components(metadata.version) != nil else { return nil }
        return (executable, metadata.version)
    }

    func prepareStaging(from current: URL) throws -> URL {
        let source = current.standardizedFileURL
        guard updatableSources.contains(where: { $0.standardizedFileURL == source.deletingLastPathComponent() }) else {
            throw EngineStagingError.unsupported
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard Self.isPrivate(directory, directory: true) else { throw EngineStagingError.unsafeLocation }
        // Leftovers from an interrupted update are never reused.
        for item in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix("staging-") {
            try? FileManager.default.removeItem(at: item)
        }
        let staging = directory.appendingPathComponent("staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let staged = staging.appendingPathComponent(EngineLocator.downloaderName)
        try FileManager.default.copyItem(at: source, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.path)
        return staged
    }

    func install(staged: URL, version: String) throws -> URL {
        guard EngineVersion.components(version) != nil else { throw EngineStagingError.invalidVersion }
        guard staged.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              Self.isPrivate(staged, directory: false) else { throw EngineStagingError.unsafeLocation }
        // Binary first, then metadata: an interruption leaves an older
        // recorded version, which only makes the bundled copy more likely to win.
        guard Darwin.rename(staged.path, executable.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))])
        }
        try JSONEncoder().encode(Metadata(version: version)).write(to: metadataFile, options: [.atomic])
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        return executable
    }

    func discard(staged: URL) {
        let staging = staged.deletingLastPathComponent()
        guard staging.lastPathComponent.hasPrefix("staging-"),
              staging.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: staging)
    }

    /// Owned by this user and not writable by anyone else.
    static func isPrivate(_ url: URL, directory: Bool) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { return false }
        let type = info.st_mode & S_IFMT
        if directory { return type == S_IFDIR }
        return type == S_IFREG && info.st_mode & S_IXUSR != 0
    }
}
