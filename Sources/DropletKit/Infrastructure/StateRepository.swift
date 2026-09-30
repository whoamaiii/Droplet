import Foundation

/// Implementations atomically replace one value or throw. An unavailable store
/// must throw rather than pretending to contain a fresh trial.
protocol StateStore {
    func read(key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
}

struct JSONStateRepository<Value: Codable> {
    let store: any StateStore
    let key: String

    func load() throws -> Value? {
        guard let data = try store.read(key: key) else { return nil }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        try store.write(data, key: key)
    }
}
