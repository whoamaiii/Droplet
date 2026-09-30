import Foundation
import CryptoKit
import Darwin

/// A fresh private directory prevents title collisions and reuse of another
/// job's partial files. Publication creates a new directory entry atomically.
final class DownloadWorkspace {
    enum Failure: Error, Equatable {
        case invalidFolder, outputOutsideWorkspace, invalidOutput, changedOutput
        case filesystem(Int32), nameExhausted
    }
    let directory: URL
    let destination: URL
    private let linkFile: (String, String) -> Int32

    static func atomicLink(_ source: String, _ destination: String) -> Int32 {
        Darwin.link(source, destination) == 0 ? 0 : errno
    }

    init(destination: URL, linkFile: @escaping (String, String) -> Int32 = DownloadWorkspace.atomicLink) throws {
        self.linkFile = linkFile
        let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.invalidFolder }
        self.destination = destination.standardizedFileURL
        directory = destination.appendingPathComponent(".droplet-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    var outputTemplate: String { directory.appendingPathComponent("media.%(ext)s").path }

    func checkedFile(_ reported: URL) throws -> (url: URL, size: Int64) {
        let path = reported.standardizedFileURL
        guard path.deletingLastPathComponent() == directory.standardizedFileURL else { throw Failure.outputOutsideWorkspace }
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.int64Value > 0 else { throw Failure.invalidOutput }
        return (path, size.int64Value)
    }

    /// The caller must validate media first. link(2) fails on an existing name;
    /// unlike a check-then-move sequence, another job cannot be overwritten.
    func publish(_ reported: URL, expectedSize: Int64, title: String, identity: String) throws -> URL {
        let file = try checkedFile(reported)
        guard file.size == expectedSize else { throw Failure.changedOutput }
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let stem = Self.safeTitle(title) + " [" + digest + "]"
        for index in 1...10_000 {
            let suffix = index == 1 ? "" : " (\(index))"
            let target = destination.appendingPathComponent(stem + suffix + ".mp4")
            let code = linkFile(file.url.path, target.path)
            if code == 0 { return target }
            guard code == EEXIST else { throw Failure.filesystem(code) }
        }
        throw Failure.nameExhausted
    }

    /// Deletes only this workspace, never a destination or another job's files.
    func remove() throws { try FileManager.default.removeItem(at: directory) }

    static func safeTitle(_ title: String) -> String {
        let cleaned = String(title.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == ":" || scalar == "\\" { return "_" }
            return Character(String(scalar))
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        for character in cleaned {
            if result.utf8.count + String(character).utf8.count > 120 { break }
            result.append(character)
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return result.isEmpty ? "Video" : result
    }
}
