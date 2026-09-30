import Foundation

struct LicenseInstance: Equatable, Codable {
    let instanceID: String
}

enum LicenseValidation: Equatable {
    case valid
    case rejected
}

protocol LicenseClient {
    func activate(key: String) async throws -> LicenseInstance
    func validate(key: String, instance: LicenseInstance) async throws -> LicenseValidation
    func deactivate(key: String, instance: LicenseInstance) async throws
}

enum LicenseError: Error, Equatable {
    case notConfigured
    case invalidKey
    case invalidResponse
    case unexpectedHTTPStatus(Int)
    case wrongProduct
    case wrongInstance
    case expired
    case rejected
    case secureStorage(Int32)
}

/// No provider/store/product is approved or configured in this build. This
/// client deliberately cannot grant access, even for a plausible-looking key.
struct UnconfiguredLicenseClient: LicenseClient {
    func activate(key: String) async throws -> LicenseInstance { throw LicenseError.notConfigured }
    func validate(key: String, instance: LicenseInstance) async throws -> LicenseValidation { throw LicenseError.notConfigured }
    func deactivate(key: String, instance: LicenseInstance) async throws { throw LicenseError.notConfigured }
}

struct LicenseProduct: Codable, Equatable {
    let providerID: String
    let storeID: String
    let productID: String
    let variantID: String

    var isConfigured: Bool {
        [providerID, storeID, productID, variantID].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// Normalized evidence from an eventual provider adapter. A provider adapter
/// must decode its documented API, rather than trusting checkout return URLs.
struct LicenseEvidence: Equatable {
    let product: LicenseProduct
    let instance: LicenseInstance
    let status: Status
    let expiresAt: Date?
    enum Status { case active, rejected }
}

struct LicenseEvidenceValidator {
    let expectedProduct: LicenseProduct

    func validate(_ evidence: LicenseEvidence, expectedInstance: LicenseInstance?, now: Date) throws -> LicenseValidation {
        guard expectedProduct.isConfigured else { throw LicenseError.notConfigured }
        guard evidence.product == expectedProduct else { throw LicenseError.wrongProduct }
        guard !evidence.instance.instanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LicenseError.invalidResponse
        }
        if let expectedInstance, expectedInstance != evidence.instance { throw LicenseError.wrongInstance }
        guard evidence.status == .active else { return .rejected }
        guard now.timeIntervalSince1970.isFinite else { throw LicenseError.invalidResponse }
        if let expiry = evidence.expiresAt {
            guard expiry.timeIntervalSince1970.isFinite else { throw LicenseError.invalidResponse }
            if expiry <= now { throw LicenseError.expired }
        }
        return .valid
    }

    /// Run before interpreting an API body. Network/HTTP failures must never
    /// become an authoritative rejection or an entitlement.
    static func requireSuccessfulResponse(_ response: HTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw LicenseError.unexpectedHTTPStatus(response.statusCode)
        }
        guard !response.data.isEmpty, response.data.count <= 1_048_576 else { throw LicenseError.invalidResponse }
    }
}

struct StoredLicense: Codable, Equatable {
    let key: String
    let product: LicenseProduct
    let instance: LicenseInstance
    let lastValidatedAt: Date
    let expiresAt: Date?

    func validateStructure() throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.utf8.count <= 4096,
              product.isConfigured, !instance.instanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              lastValidatedAt.timeIntervalSince1970.isFinite else { throw LicenseError.invalidResponse }
        if let expiry = expiresAt, !expiry.timeIntervalSince1970.isFinite { throw LicenseError.invalidResponse }
    }
}

protocol LicenseStore {
    func load() throws -> StoredLicense?
    func save(_ license: StoredLicense) throws
    func remove() throws
}
