import Foundation
import Darwin

/// Kernel lock held for the lifetime of the menu-bar owner. The file is never
/// unlinked: deleting a locked inode would allow a second independent owner.
final class SingleInstanceLock {
    enum Result: Equatable { case acquired, occupied, failed(Int32) }
    private var descriptor: Int32 = -1
    deinit { if descriptor >= 0 { close(descriptor) } }

    func acquire(at url: URL) -> Result {
        if descriptor >= 0 { return .acquired }
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return .failed(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            close(fd)
            return .failed(EACCES)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(fd)
            return reason == EWOULDBLOCK ? .occupied : .failed(reason)
        }
        descriptor = fd
        return .acquired
    }

    static func runtimeURL(bundleID: String) throws -> URL {
        guard !bundleID.isEmpty, bundleID.utf8.count < 200,
              bundleID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Droplet/RuntimeLocks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR else {
            throw CocoaError(.fileReadNoPermission)
        }
        return directory.appendingPathComponent(bundleID + ".lock")
    }
}

/// Persistent state belongs only to the lock owner. Dormant contenders must
/// neither recover another owner's journal nor cache a stale quota snapshot.
@MainActor
final class OwnershipBoundResource<Value> {
    private(set) var value: Value?
    func initialize(ownership: SingleInstanceLock.Result, factory: () -> Value) {
        guard ownership == .acquired, value == nil else { return }
        value = factory()
    }
}
