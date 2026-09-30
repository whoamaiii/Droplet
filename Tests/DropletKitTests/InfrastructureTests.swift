import Foundation
@testable import DropletKit

private enum StoreError: Error { case locked }

private final class MemoryStore: StateStore {
    var values: [String: Data] = [:]
    var readError: Error?
    var writeError: Error?
    func read(key: String) throws -> Data? {
        if let readError { throw readError }
        return values[key]
    }
    func write(_ data: Data, key: String) throws {
        if let writeError { throw writeError }
        values[key] = data
    }
}

private struct StoredFixture: Codable, Equatable { let count: Int }

private final class FixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path == "/timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let status = request.url!.path == "/unavailable" ? 503 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"fixture\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class InfrastructureTests{
    func testMissingStateAndCorruptStateAreDifferent() throws {
        let store = MemoryStore()
        let repo = JSONStateRepository<StoredFixture>(store: store, key: "fixture")
        expectNil(try repo.load())
        store.values["fixture"] = Data("not valid JSON".utf8)
        expectThrows(try repo.load(), "Corruption must never silently reset a trial")
    }

    func testLockedStoreIsNotMistakenForFreshState() {
        let store = MemoryStore()
        store.readError = StoreError.locked
        let repo = JSONStateRepository<StoredFixture>(store: store, key: "fixture")
        expectThrows(try repo.load())
    }

    func testFailedWritePreservesPreviousState() throws {
        let store = MemoryStore()
        let repo = JSONStateRepository<StoredFixture>(store: store, key: "fixture")
        try repo.save(StoredFixture(count: 2))
        store.writeError = StoreError.locked
        expectThrows(try repo.save(StoredFixture(count: 3)))
        expectEqual(try repo.load(), StoredFixture(count: 2))
    }

    func testStateKeysDoNotOverwriteEachOther() throws {
        let store = MemoryStore()
        let a = JSONStateRepository<StoredFixture>(store: store, key: "a")
        let b = JSONStateRepository<StoredFixture>(store: store, key: "b")
        try a.save(StoredFixture(count: 1))
        try b.save(StoredFixture(count: 3))
        expectEqual(try a.load(), StoredFixture(count: 1))
        expectEqual(try b.load(), StoredFixture(count: 3))
    }

    func testHTTPErrorStatusIsNotSilentlyConvertedToSuccessfulValidation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        let client = URLSessionTransport(configuration: config)
        let response = try await client.send(URLRequest(url: URL(string: "https://fixture.invalid/unavailable")!))
        expectEqual(response.statusCode, 503)
        expectEqual(response.data, Data("{\"fixture\":true}".utf8))
    }

    func testNetworkTimeoutIsPropagatedSeparatelyFromRejection() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        do {
            _ = try await URLSessionTransport(configuration: config).send(URLRequest(url: URL(string: "https://fixture.invalid/timeout")!))
            recordFailure("Expected timeout")
        } catch {
            expectEqual((error as? URLError)?.code, .timedOut)
        }
    }

    func testHTTPTransportRejectsPlaintextBeforeSendingAnything() async {
        do {
            _ = try await URLSessionTransport().send(URLRequest(url: URL(string: "http://fixture.invalid")!))
            recordFailure("Expected insecure URL rejection")
        } catch {
            guard case HTTPTransportError.insecureURL = error else { return recordFailure("Wrong error: \(error)") }
            expectTrue(true, "Plaintext request rejected before URLSession")
        }
    }

    func testRedirectsCannotMoveCredentialsToAnotherOrigin() {
        let source = URL(string: "https://api.example.com/license")!
        expectTrue(HTTPSRedirectPolicy.permits(from: source, to: URL(string: "https://api.example.com:443/v2/license")))
        for target in ["http://api.example.com/license", "https://other.example.com/license", "https://api.example.com:8443/license", "https://user:password@api.example.com/license"] {
            expectFalse(HTTPSRedirectPolicy.permits(from: source, to: URL(string: target)), "Reject \(target)")
        }
    }
}
