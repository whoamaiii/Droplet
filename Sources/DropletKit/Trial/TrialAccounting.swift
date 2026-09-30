import Foundation

@MainActor
protocol TrialAccounting {
    var remaining: Int { get }
    func reserve(jobID: UUID) throws
    func preparePublication(jobID: UUID, stagedFile: URL, destination: URL) throws
    func complete(jobID: UUID, result: DownloadResult) throws
    func release(jobID: UUID) throws
}

/// A publication witness is persisted before link(2). Recovery checks the
/// destination for that exact device/inode, never a title or an old download.
@MainActor
final class PersistentTrialAccounting: TrialAccounting {
    enum Failure: Error { case exhausted, invalidState, missingReservation }
    private struct Witness: Codable {
        let destination: URL
        let device: UInt64
        let inode: UInt64
    }
    private struct State: Codable {
        var version = 1
        var completed: Set<UUID> = []
        var pending: [UUID: Witness?] = [:]
    }
    private let repository: JSONStateRepository<State>
    private var state: State
    var remaining: Int { max(0, 3 - state.completed.count) }

    init(store: any StateStore) throws {
        repository = JSONStateRepository(store: store, key: "trial-v1")
        state = try repository.load() ?? State()
        guard state.version == 1, state.completed.count <= 3,
              state.pending.count <= 1, state.completed.isDisjoint(with: state.pending.keys) else { throw Failure.invalidState }
        // A reservation without a witness never reached publication.
        for (job, witness) in state.pending {
            if let witness, try Self.wasPublished(witness) { state.completed.insert(job) }
        }
        state.pending.removeAll()
        guard state.completed.count <= 3 else { throw Failure.invalidState }
        try repository.save(state)
    }

    func reserve(jobID: UUID) throws {
        guard remaining > 0, state.pending.isEmpty else { throw Failure.exhausted }
        var next = state
        next.pending.updateValue(nil, forKey: jobID)
        try save(next)
    }

    func preparePublication(jobID: UUID, stagedFile: URL, destination: URL) throws {
        guard state.pending.keys.contains(jobID) else { throw Failure.missingReservation }
        let attrs = try FileManager.default.attributesOfItem(atPath: stagedFile.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let inode = attrs[.systemFileNumber] as? NSNumber,
              let device = attrs[.systemNumber] as? NSNumber else { throw Failure.invalidState }
        var next = state
        next.pending[jobID] = Witness(destination: destination, device: device.uint64Value, inode: inode.uint64Value)
        try save(next)
    }

    func complete(jobID: UUID, result: DownloadResult) throws {
        if state.completed.contains(jobID) { return }
        guard state.pending.keys.contains(jobID) else { throw Failure.missingReservation }
        var next = state
        if result.isNewFile { next.completed.insert(jobID) }
        next.pending.removeValue(forKey: jobID)
        try save(next)
    }

    func release(jobID: UUID) throws {
        guard let entry = state.pending.first(where: { $0.key == jobID }) else { return }
        var next = state
        if let witness = entry.value, try Self.wasPublished(witness) { next.completed.insert(jobID) }
        next.pending.removeValue(forKey: jobID)
        try save(next)
    }

    private func save(_ next: State) throws {
        try repository.save(next)
        state = next
    }

    private static func wasPublished(_ witness: Witness) throws -> Bool {
        let files = try FileManager.default.contentsOfDirectory(at: witness.destination,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for file in files {
            let attrs: [FileAttributeKey: Any]
            do { attrs = try FileManager.default.attributesOfItem(atPath: file.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { continue }
            if attrs[.type] as? FileAttributeType == .typeRegular,
               (attrs[.systemNumber] as? NSNumber)?.uint64Value == witness.device,
               (attrs[.systemFileNumber] as? NSNumber)?.uint64Value == witness.inode { return true }
        }
        return false
    }
}

/// Atomic replacement prevents partial JSON after a crash. A damaged or
/// inaccessible existing file throws and cannot silently restart the quota.
struct TrialFileStore: StateStore {
    let directory: URL
    static var live: TrialFileStore {
        TrialFileStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Droplet", isDirectory: true))
    }
    func read(key: String) throws -> Data? {
        let file = directory.appendingPathComponent(key + ".json")
        do { return try Data(contentsOf: file) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }
    func write(_ data: Data, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: directory.appendingPathComponent(key + ".json"), options: [.atomic])
    }
}
