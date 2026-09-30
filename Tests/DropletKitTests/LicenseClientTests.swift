import Foundation
@testable import DropletKit

struct LicenseClientTests {
    private var product: LicenseProduct {
        LicenseProduct(providerID: "test-provider", storeID: "store", productID: "droplet", variantID: "v1")
    }

    func testEvidenceIsProductInstanceAndExpiryBound() throws {
        let instance = LicenseInstance(instanceID: "this-mac")
        let now = Date(timeIntervalSince1970: 1_000)
        let validator = LicenseEvidenceValidator(expectedProduct: product)
        func evidence(product: LicenseProduct? = nil, instanceID: String = "this-mac",
                      status: LicenseEvidence.Status = .active, expires: Date? = nil) -> LicenseEvidence {
            LicenseEvidence(product: product ?? self.product, instance: LicenseInstance(instanceID: instanceID), status: status, expiresAt: expires)
        }
        expectEqual(try validator.validate(evidence(), expectedInstance: instance, now: now), .valid)
        expectEqual(try validator.validate(evidence(status: .rejected), expectedInstance: instance, now: now), .rejected)
        for wrong in [
            LicenseProduct(providerID: "other", storeID: "store", productID: "droplet", variantID: "v1"),
            LicenseProduct(providerID: "test-provider", storeID: "other", productID: "droplet", variantID: "v1"),
            LicenseProduct(providerID: "test-provider", storeID: "store", productID: "other", variantID: "v1"),
            LicenseProduct(providerID: "test-provider", storeID: "store", productID: "droplet", variantID: "other")
        ] {
            expectThrows(try validator.validate(evidence(product: wrong), expectedInstance: instance, now: now))
        }
        expectThrows(try validator.validate(evidence(instanceID: "other-mac"), expectedInstance: instance, now: now))
        expectThrows(try validator.validate(evidence(instanceID: " "), expectedInstance: nil, now: now))
        expectThrows(try validator.validate(evidence(expires: now), expectedInstance: instance, now: now))
        expectEqual(try validator.validate(evidence(expires: now.addingTimeInterval(1)), expectedInstance: instance, now: now), .valid)
        let empty = LicenseEvidenceValidator(expectedProduct: LicenseProduct(providerID: "", storeID: "", productID: "", variantID: ""))
        expectThrows(try empty.validate(evidence(), expectedInstance: nil, now: now))
    }

    func testHTTPAndPersistedEvidenceFailClosed() throws {
        for code in [301, 401, 403, 429, 500, 503] {
            expectThrows(try LicenseEvidenceValidator.requireSuccessfulResponse(HTTPResponse(data: Data("{}".utf8), statusCode: code)))
        }
        expectThrows(try LicenseEvidenceValidator.requireSuccessfulResponse(HTTPResponse(data: Data(), statusCode: 200)))
        expectThrows(try LicenseEvidenceValidator.requireSuccessfulResponse(HTTPResponse(data: Data(repeating: 0, count: 1_048_577), statusCode: 200)))
        try LicenseEvidenceValidator.requireSuccessfulResponse(HTTPResponse(data: Data("{}".utf8), statusCode: 200))
        let stored = StoredLicense(key: "test-key", product: product, instance: LicenseInstance(instanceID: "mac"), lastValidatedAt: Date(), expiresAt: nil)
        try stored.validateStructure()
        expectEqual(try JSONDecoder().decode(StoredLicense.self, from: JSONEncoder().encode(stored)), stored)
        expectThrows(try StoredLicense(key: " ", product: product, instance: stored.instance, lastValidatedAt: Date(), expiresAt: nil).validateStructure())
        expectThrows(try StoredLicense(key: "key", product: product, instance: LicenseInstance(instanceID: ""), lastValidatedAt: Date(), expiresAt: nil).validateStructure())
    }

    func testUnconfiguredClientNeverGrantsAccess() async {
        let client = UnconfiguredLicenseClient()
        do { _ = try await client.activate(key: "looks-like-a-key"); recordFailure("Unconfigured activation granted access") }
        catch { expectEqual(error as? LicenseError, .notConfigured) }
        do { _ = try await client.validate(key: "key", instance: LicenseInstance(instanceID: "mac")); recordFailure("Unconfigured validation granted access") }
        catch { expectEqual(error as? LicenseError, .notConfigured) }
        do { try await client.deactivate(key: "key", instance: LicenseInstance(instanceID: "mac")); recordFailure("Unconfigured deactivation claimed success") }
        catch { expectEqual(error as? LicenseError, .notConfigured) }
    }
}
