import Foundation
@testable import DropletKit

final class MemoryFingerprintStore: EngineFingerprintStore {
    var value: String?
    func load() -> String? { value }
    func save(_ digest: String) throws { value = digest }
}

struct EngineLocatorTests {
    func testBundledUpdatedAndDevelopmentResolution() {
        let helpers = URL(fileURLWithPath: "/App/Droplet.app/Contents/Helpers")
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin")
        let updated = (url: URL(fileURLWithPath: "/Users/me/Library/Application Support/Droplet/Engine/yt-dlp"), version: "2026.09.30")
        func resolve(_ present: Set<String>, updated: (url: URL, version: String)? = nil, bundled: String? = "2026.08.19",
                     release: Bool = true) -> EngineLocation {
            EngineLocator.resolve(helpers: release ? helpers : nil, updated: updated, bundledVersion: bundled,
                                  developmentDirectories: [brew], isExecutable: { present.contains($0.path) })
        }
        let bundle: Set<String> = [helpers.path + "/yt-dlp", helpers.path + "/ffmpeg", helpers.path + "/deno", brew.path + "/yt-dlp"]
        let bundled = resolve(bundle)
        expectEqual(bundled.downloader.path, helpers.path + "/yt-dlp", "Bundled helpers win over Homebrew")
        expectEqual(bundled.ffmpegDirectory, helpers)
        expectEqual(bundled.jsRuntime?.path, helpers.path + "/deno")
        expectTrue(bundled.isBundled)
        expectEqual(resolve(bundle, updated: updated).downloader, updated.url, "A newer verified update is used")
        expectEqual(resolve(bundle, updated: updated).ffmpegDirectory, helpers, "FFmpeg always comes from the bundle")
        expectEqual(resolve(bundle, updated: (updated.url, "2026.08.19")).downloader.path, helpers.path + "/yt-dlp",
                    "An equal version prefers the signed bundled copy")
        expectEqual(resolve(bundle, updated: (updated.url, "2026.01.01")).downloader.path, helpers.path + "/yt-dlp",
                    "An app update with a newer bundled engine wins over an older download")
        expectNil(resolve(bundle.subtracting([helpers.path + "/deno"])).jsRuntime)

        let development = resolve([brew.path + "/yt-dlp"], updated: updated, release: false)
        expectEqual(development.downloader.path, brew.path + "/yt-dlp")
        expectEqual(development.ffmpegDirectory, brew)
        expectFalse(development.isBundled)

        let damaged = resolve([helpers.path + "/yt-dlp", brew.path + "/yt-dlp"], updated: updated)
        expectEqual(damaged.downloader.path, helpers.path + "/yt-dlp",
                    "A damaged release bundle never falls back to Homebrew or the updated copy")
        expectTrue(damaged.isBundled)
    }

    func testVersionOrdering() {
        expectTrue(EngineVersion.isNewer("2026.09.01", than: "2026.08.19"))
        expectTrue(EngineVersion.isNewer("2026.08.19.120000", than: "2026.08.19"))
        expectTrue(EngineVersion.isNewer("2026.10.01", than: "2026.9.30"))
        expectFalse(EngineVersion.isNewer("2026.08.19", than: "2026.08.19"))
        expectFalse(EngineVersion.isNewer("2026.08.18", than: "2026.08.19"))
        expectTrue(EngineVersion.isNewer("2026.08.18", than: nil), "Without a recorded bundled version, a valid update is used")
        for invalid in ["", "latest", "2026.08", "2026.08.19.1.2", "2026.-1.01", "2026.08.19 ", "２０２６.08.19"] {
            expectFalse(EngineVersion.isNewer(invalid, than: "2026.01.01"), invalid)
        }
    }

    func testPrivateStagingAndInstallation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helpers = root.appendingPathComponent("Helpers", isDirectory: true)
        let other = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let bundled = helpers.appendingPathComponent("yt-dlp")
        try Data("#!/bin/sh\necho bundled\n".utf8).write(to: bundled)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        let foreign = other.appendingPathComponent("yt-dlp")
        try Data("#!/bin/sh\n".utf8).write(to: foreign)

        let directory = root.appendingPathComponent("Engine", isDirectory: true)
        let fingerprints = MemoryFingerprintStore()
        let store = UpdatedEngineStore(directory: directory, updatableSources: [helpers, directory], fingerprints: fingerprints)
        expectNil(store.installed())
        expectThrows(try store.prepareStaging(from: foreign), "Only the bundled or previously updated engine is staged")

        let staged = try store.prepareStaging(from: bundled)
        expectEqual(try Data(contentsOf: staged), try Data(contentsOf: bundled))
        expectTrue(UpdatedEngineStore.isPrivate(staged, directory: false))
        expectThrows(try store.install(staged: staged, version: "not-a-version"))
        let installed = try store.install(staged: staged, version: "2026.09.30")
        expectEqual(store.installed()?.url, installed)
        expectEqual(store.installed()?.version, "2026.09.30")
        expectEqual(fingerprints.value, UpdatedEngineStore.sha256(installed))
        expectFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path), "Staging is removed")

        let second = try store.prepareStaging(from: installed)
        store.discard(staged: second)
        expectFalse(FileManager.default.fileExists(atPath: second.deletingLastPathComponent().path))
        store.discard(staged: bundled)
        expectTrue(FileManager.default.fileExists(atPath: bundled.path), "Discard never touches files outside staging")

        let original = try Data(contentsOf: installed)
        try Data("#!/bin/sh\necho planted\n".utf8).write(to: installed)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installed.path)
        expectNil(store.installed(), "A replaced engine no longer matches its recorded fingerprint")
        try original.write(to: installed)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installed.path)
        expectEqual(store.installed()?.url, installed)
        fingerprints.value = nil
        expectNil(store.installed(), "Without a recorded fingerprint the update is not trusted")
        fingerprints.value = UpdatedEngineStore.sha256(installed)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: installed.path)
        expectNil(store.installed(), "A writable-by-others engine is never executed")
    }
}
