import Foundation
@testable import DropletKit

final class FakeTransport: HTTPTransport {
    var responses: [Result<HTTPResponse, Error>] = []
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        return try responses.removeFirst().get()
    }
}

final class FakeLicenseClient: LicenseClient {
    var activation: Result<LicenseEvidence, Error> = .failure(URLError(.notConnectedToInternet))
    var validation: Result<LicenseEvidence, Error> = .failure(URLError(.notConnectedToInternet))
    var deactivation: Result<Void, Error> = .success(())
    private(set) var calls: [String] = []
    func activate(key: String) async throws -> LicenseEvidence { calls.append("activate"); return try activation.get() }
    func validate(key: String, instance: LicenseInstance) async throws -> LicenseEvidence { calls.append("validate"); return try validation.get() }
    func deactivate(key: String, instance: LicenseInstance) async throws { calls.append("deactivate"); try deactivation.get() }
}

final class MemoryLicenseStore: LicenseStore {
    var stored: StoredLicense?
    var failSave = false
    var failLoad = false
    func load() throws -> StoredLicense? {
        if failLoad { throw LicenseError.secureStorage(-25308) }
        return stored
    }
    func save(_ license: StoredLicense) throws {
        if failSave { throw LicenseError.secureStorage(-25299) }
        stored = license
    }
    func remove() throws { stored = nil }
}

struct LemonSqueezyLicenseTests {
    static func body(_ flag: String, _ value: Bool, status: String = "active", store: Any = 101, product: Any = 202,
                     variant: Any = 303, instance: String? = "inst-1", expires: String? = nil, error: String? = nil) -> Data {
        let null: Any = NSNull()
        var key: [String: Any] = ["id": 1, "status": status, "key": "KEY", "activation_limit": 2, "activation_usage": 1]
        key["expires_at"] = expires ?? null
        var meta: [String: Any] = ["order_id": 9, "customer_email": "buyer@example.invalid"]
        meta["store_id"] = store
        meta["product_id"] = product
        meta["variant_id"] = variant
        var object: [String: Any] = [flag: value]
        object["error"] = error ?? null
        object["license_key"] = key
        if let instance {
            let record: [String: Any] = ["id": instance, "name": "Droplet for Mac", "created_at": "2026-10-08T10:00:00.000000Z"]
            object["instance"] = record
        } else {
            object["instance"] = null
        }
        object["meta"] = meta
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testRequestsAndEvidence() async throws {
        let transport = FakeTransport()
        let client = LemonSqueezyLicenseClient(transport: transport)
        transport.responses = [.success(HTTPResponse(data: Self.body("activated", true, expires: "2027-01-24T14:15:07.000000Z"), statusCode: 200))]
        let evidence = try await client.activate(key: "AB-12 &=+")
        let request = transport.requests[0]
        expectEqual(request.url?.absoluteString, "https://api.lemonsqueezy.com/v1/licenses/activate")
        expectEqual(request.httpMethod, "POST")
        expectEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        expectEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        expectEqual(String(data: request.httpBody ?? Data(), encoding: .utf8),
                    "instance_name=Droplet%20for%20Mac&license_key=AB-12%20%26%3D%2B")
        expectEqual(evidence.product, LicenseProduct(providerID: "lemonsqueezy", storeID: "101", productID: "202", variantID: "303"))
        expectEqual(evidence.instance, LicenseInstance(instanceID: "inst-1"))
        expectEqual(evidence.status, .active)
        expectEqual(evidence.expiresAt, Date(timeIntervalSince1970: 1_800_800_107))

        transport.responses = [.success(HTTPResponse(data: Self.body("valid", true, store: "101", product: "202", variant: "303"), statusCode: 200))]
        let validated = try await client.validate(key: "KEY", instance: LicenseInstance(instanceID: "inst-1"))
        expectEqual(validated.product.storeID, "101", "String IDs are accepted as well as numbers")
        expectTrue(String(data: transport.requests[1].httpBody!, encoding: .utf8)!.contains("instance_id=inst-1"))
        expectEqual(transport.requests[1].url?.lastPathComponent, "validate")

        transport.responses = [.success(HTTPResponse(data: Self.body("valid", true, status: "disabled"), statusCode: 200))]
        expectEqual(try await client.validate(key: "KEY", instance: LicenseInstance(instanceID: "inst-1")).status, .rejected)
    }

    func testProviderRefusalsVersusTransientFailures() throws {
        func interpret(_ status: Int, _ data: Data, flag: String = "valid") -> Error? {
            do { _ = try LemonSqueezyLicenseClient.interpret(HTTPResponse(data: data, statusCode: status), flag: flag); return nil }
            catch { return error }
        }
        let refused = Self.body("activated", false, instance: nil, error: "This license key has reached the activation limit.")
        expectEqual(interpret(400, refused, flag: "activated") as? LicenseError,
                    .rejected("This license key has reached the activation limit."))
        expectEqual(interpret(404, Self.body("valid", false, error: "license_key not found."), flag: "valid") as? LicenseError,
                    .rejected("license_key not found."))
        expectEqual(interpret(200, Self.body("valid", false, error: "Disabled")) as? LicenseError, .rejected("Disabled"))
        for transient in [408, 429, 500, 502, 503] {
            expectEqual(interpret(transient, Self.body("valid", false, error: "busy")) as? LicenseError,
                        .unexpectedHTTPStatus(transient), "HTTP \(transient) is not a refusal")
        }
        expectEqual(interpret(404, Data("<html>not json</html>".utf8)) as? LicenseError, .unexpectedHTTPStatus(404))
        expectEqual(interpret(200, Data("not json".utf8)) as? LicenseError, .invalidResponse)
        expectEqual(interpret(200, Data()) as? LicenseError, .invalidResponse)
        expectNil(interpret(200, Self.body("valid", true)))
    }

    func testDatesAndFormEncoding() {
        expectEqual(LemonSqueezyLicenseClient.parseDate("2021-01-24T14:15:07.000000Z"), Date(timeIntervalSince1970: 1_611_497_707))
        expectEqual(LemonSqueezyLicenseClient.parseDate("2021-01-24T14:15:07Z"), Date(timeIntervalSince1970: 1_611_497_707))
        expectEqual(LemonSqueezyLicenseClient.parseDate("2021-01-24T16:15:07.5+02:00"), Date(timeIntervalSince1970: 1_611_497_707))
        expectNil(LemonSqueezyLicenseClient.parseDate("yesterday"))
        expectEqual(LemonSqueezyLicenseClient.formEncode(["b": "ø ü", "a": "x/y?z"]), "a=x%2Fy%3Fz&b=%C3%B8%20%C3%BC")
    }

    func testConfigurationRequiresStoreAndProduct() {
        let empty = ProductConfiguration(info: [:])
        expectNil(empty.licenseProduct)
        expectNil(empty.checkoutURL)
        let full = ProductConfiguration(info: [
            "DropletLicenseStoreID": " 101 ", "DropletLicenseProductID": "202", "DropletLicenseVariantID": "",
            "DropletCheckoutURL": "https://droplet.lemonsqueezy.com/buy/abc", "DropletSupportURL": "help@example.com",
            "DropletPrivacyURL": "http://insecure.example.com/privacy", "DropletWebsiteURL": "https://example.com"])
        expectEqual(full.licenseProduct, LicenseProduct(providerID: "lemonsqueezy", storeID: "101", productID: "202", variantID: ""))
        expectEqual(full.checkoutURL?.host, "droplet.lemonsqueezy.com")
        expectEqual(full.supportURL?.absoluteString, "mailto:help@example.com")
        expectNil(full.privacyURL, "Plain HTTP links are refused")
        expectNil(ProductConfiguration(info: ["DropletLicenseStoreID": "abc", "DropletLicenseProductID": "202"]).licenseProduct)
        let anyVariant = full.licenseProduct!
        expectTrue(anyVariant.accepts(LicenseProduct(providerID: "lemonsqueezy", storeID: "101", productID: "202", variantID: "999")))
        expectFalse(anyVariant.accepts(LicenseProduct(providerID: "lemonsqueezy", storeID: "101", productID: "203", variantID: "999")))
    }
}

struct LicenseControllerTests {
    static let product = LicenseProduct(providerID: "lemonsqueezy", storeID: "101", productID: "202", variantID: "")
    static func evidence(product: LicenseProduct = LicenseProduct(providerID: "lemonsqueezy", storeID: "101", productID: "202", variantID: "303"),
                         instance: String = "inst-1", status: LicenseEvidence.Status = .active, expires: Date? = nil) -> LicenseEvidence {
        LicenseEvidence(product: product, instance: LicenseInstance(instanceID: instance), status: status, expiresAt: expires)
    }

    @MainActor
    func testActivationStoresOnlyAMatchingActiveLicense() async {
        var now = Date(timeIntervalSince1970: 2_000_000)
        let client = FakeLicenseClient()
        let store = MemoryLicenseStore()
        let license = LicenseController(product: Self.product, checkoutURL: nil, client: client, store: store, now: { now })
        expectEqual(license.state, .unlicensed)
        await license.activate(key: "   ")
        expectTrue(client.calls.isEmpty, "Blank keys never reach the provider")

        client.activation = .success(Self.evidence(product: LicenseProduct(providerID: "lemonsqueezy", storeID: "101", productID: "999", variantID: "1")))
        await license.activate(key: "KEY-1")
        expectEqual(client.calls, ["activate", "deactivate"], "A key for another product releases its new activation")
        expectFalse(license.isLicensed)
        expectNil(store.stored)

        client.activation = .failure(LicenseError.rejected("This license key has reached the activation limit."))
        await license.activate(key: "KEY-1")
        expectTrue(license.message!.contains("activation limit"))
        expectFalse(license.isLicensed)

        client.activation = .success(Self.evidence())
        store.failSave = true
        await license.activate(key: "KEY-1")
        expectFalse(license.isLicensed, "An activation that cannot be saved is not kept")
        expectEqual(client.calls.suffix(2), ["activate", "deactivate"])

        store.failSave = false
        await license.activate(key: " KEY-1 \n")
        expectTrue(license.isLicensed)
        expectEqual(store.stored?.key, "KEY-1")
        expectEqual(store.stored?.instance, LicenseInstance(instanceID: "inst-1"))
        expectEqual(license.maskedKey, "••••EY-1")

        let reopened = LicenseController(product: Self.product, checkoutURL: nil, client: client, store: store, now: { now })
        expectTrue(reopened.isLicensed, "The license survives a restart")
        now.addTimeInterval(LicenseController.offlineGrace + 1)
        expectFalse(reopened.isLicensed, "Beyond 30 days offline the license needs one successful check")
        expectTrue(reopened.needsOnlineCheck)
    }

    @MainActor
    func testDailyValidationAndOfflineGrace() async {
        var now = Date(timeIntervalSince1970: 3_000_000)
        let client = FakeLicenseClient()
        let store = MemoryLicenseStore()
        store.stored = StoredLicense(key: "KEY", product: Self.evidence().product, instance: LicenseInstance(instanceID: "inst-1"),
                                     lastValidatedAt: now, expiresAt: nil)
        let license = LicenseController(product: Self.product, checkoutURL: nil, client: client, store: store, now: { now })
        await license.refreshIfDue()
        expectTrue(client.calls.isEmpty, "No provider call within a day")

        now.addTimeInterval(LicenseController.revalidationInterval + 1)
        await license.refreshIfDue()
        expectEqual(client.calls, ["validate"])
        expectTrue(license.isLicensed, "A network failure never removes a license")
        expectNotNilLicense(store)

        now.addTimeInterval(TimeInterval(5 * 86_400))
        client.validation = .success(Self.evidence())
        await license.refreshIfDue()
        expectEqual(store.stored?.lastValidatedAt, now)

        now.addTimeInterval(LicenseController.revalidationInterval + 1)
        client.validation = .success(Self.evidence(instance: "another-mac"))
        await license.refreshIfDue()
        expectFalse(license.isLicensed, "An activation that no longer matches this Mac is authoritative")
        expectNil(store.stored)
        expectEqual(license.state, .unlicensed)
    }

    @MainActor
    func testProviderRefusalExpiryAndDeactivation() async {
        let now = Date(timeIntervalSince1970: 4_000_000)
        let client = FakeLicenseClient()
        let store = MemoryLicenseStore()
        func seed() {
            store.stored = StoredLicense(key: "KEY", product: Self.evidence().product, instance: LicenseInstance(instanceID: "inst-1"),
                                         lastValidatedAt: now.addingTimeInterval(TimeInterval(-2 * 86_400)), expiresAt: nil)
        }
        seed()
        var license = LicenseController(product: Self.product, checkoutURL: nil, client: client, store: store, now: { now })
        client.validation = .failure(LicenseError.rejected("license_key not found."))
        await license.refreshIfDue()
        expectFalse(license.isLicensed)
        expectNil(store.stored)

        seed()
        license = LicenseController(product: Self.product, checkoutURL: nil, client: client, store: store, now: { now })
        client.validation = .success(Self.evidence(expires: now.addingTimeInterval(-1)))
        await license.refreshIfDue()
        expectFalse(license.isLicensed, "An expired key is refused")

        seed()
        license = LicenseController(product: Self.product, checkoutURL: nil, client: client, store: store, now: { now })
        client.deactivation = .failure(URLError(.timedOut))
        await license.deactivate()
        expectTrue(license.isLicensed, "Offline deactivation keeps this Mac activated")
        expectNotNilLicense(store)
        client.deactivation = .failure(LicenseError.rejected("instance not found"))
        await license.deactivate()
        expectFalse(license.isLicensed, "An activation the provider no longer has is removed locally")
        seed()
        license = LicenseController(product: Self.product, checkoutURL: nil, client: client, store: store, now: { now })
        client.deactivation = .success(())
        await license.deactivate()
        expectEqual(license.state, .unlicensed)
        expectNil(store.stored)
    }

    @MainActor
    func testUnconfiguredAndUnreadableStatesFailClosed() async {
        let client = FakeLicenseClient()
        let store = MemoryLicenseStore()
        let unconfigured = LicenseController(product: nil, checkoutURL: nil, client: client, store: store)
        expectEqual(unconfigured.state, .notConfigured)
        client.activation = .success(Self.evidence())
        await unconfigured.activate(key: "KEY")
        expectFalse(unconfigured.isLicensed)
        expectTrue(client.calls.isEmpty)

        store.failLoad = true
        let unreadable = LicenseController(product: Self.product, checkoutURL: nil, client: client, store: store)
        expectEqual(unreadable.state, .unavailable)
        expectFalse(unreadable.isLicensed)
        store.failLoad = false
        await unreadable.activate(key: "KEY")
        expectTrue(unreadable.isLicensed, "Entering the key again recovers from an unreadable Keychain item")
    }

    @MainActor
    func testPaidLicenseBypassesTheExhaustedTrial() async throws {
        let trial = try PersistentTrialAccounting(store: LicenseTestTrialStore())
        let result = DownloadResult(sourceURL: URL(string: "https://example.com/video")!,
            identity: VideoIdentity(extractor: "fixture", mediaID: "one"), fileURL: URL(fileURLWithPath: "/tmp/video.mp4"),
            media: VerifiedMedia(byteCount: 1, duration: 1, container: "mp4", videoCodec: "h264", audioCodec: nil), isNewFile: true)
        for _ in 0..<3 { let job = UUID(); try trial.reserve(jobID: job); try trial.complete(jobID: job, result: result) }
        let h = DownloadHarness()
        let manager = DownloadManager(environment: h.environment, trialAccounting: trial)
        manager.purchaseAvailable = true
        manager.startDownload()
        expectEqual(h.processes.count, 0)
        expectTrue(manager.needsLicense, "The exhausted trial offers purchase instead of retry")
        if case .failed(let message) = manager.phase { expectTrue(message.contains("Buy Droplet")) }
        else { recordFailure("Exhausted trial started a download") }

        var licensed = true
        manager.isLicensed = { licensed }
        expectFalse(manager.needsLicense)
        manager.retryFromFailure()
        expectEqual(h.processes.count, 1, "A paid license starts downloads after the trial")
        expectEqual(trial.remaining, 0)
        manager.cancel()
        h.clock.runCleanup()
        licensed = false
        manager.startDownload()
        expectEqual(h.processes.count, 1, "Losing the license restores the trial gate")
    }

    @MainActor
    func testReviewFixesForRetryClockAndPurchaseOffer() async throws {
        var now = Date(timeIntervalSince1970: 5_000_000)
        let client = FakeLicenseClient()
        let store = MemoryLicenseStore()
        store.stored = StoredLicense(key: "KEY", product: Self.evidence().product, instance: LicenseInstance(instanceID: "inst-1"),
                                     lastValidatedAt: now, expiresAt: nil)
        store.failLoad = true
        let license = LicenseController(product: Self.product, checkoutURL: nil, client: client, store: store, now: { now })
        expectEqual(license.state, .unavailable)
        store.failLoad = false
        await license.refreshIfDue()
        expectTrue(license.isLicensed, "A Keychain that was locked at launch is read again")
        expectTrue(client.calls.isEmpty, "Re-reading the Keychain does not create a new activation")

        store.stored = StoredLicense(key: "KEY", product: Self.evidence().product, instance: LicenseInstance(instanceID: "inst-1"),
                                     lastValidatedAt: now.addingTimeInterval(TimeInterval(400 * 86_400)), expiresAt: nil)
        let future = LicenseController(product: Self.product, checkoutURL: nil, client: client, store: store, now: { now })
        expectFalse(future.isLicensed, "A check dated far in the future does not extend the offline allowance")
        expectTrue(future.needsOnlineCheck)
        now.addTimeInterval(60)
        client.validation = .success(Self.evidence())
        await future.refreshIfDue()
        expectTrue(future.isLicensed, "One successful check restores access")

        let h = DownloadHarness()
        let trial = try PersistentTrialAccounting(store: LicenseTestTrialStore())
        let result = DownloadResult(sourceURL: URL(string: "https://example.com/video")!,
            identity: VideoIdentity(extractor: "fixture", mediaID: "one"), fileURL: URL(fileURLWithPath: "/tmp/video.mp4"),
            media: VerifiedMedia(byteCount: 1, duration: 1, container: "mp4", videoCodec: "h264", audioCodec: nil), isNewFile: true)
        for _ in 0..<3 { let job = UUID(); try trial.reserve(jobID: job); try trial.complete(jobID: job, result: result) }
        let manager = DownloadManager(environment: h.environment, trialAccounting: trial)
        manager.purchaseAvailable = true
        manager.useNewClipboardLink()
        h.clipboard = URL(string: "ftp://example.com/not-a-video")!
        manager.useNewClipboardLink()
        if case .failed = manager.phase {} else { recordFailure("Expected an invalid-link failure") }
        expectFalse(manager.needsLicense, "Only the trial-limit failure offers a purchase")
    }

    func testUnusableActivationIsReleased() async {
        let transport = FakeTransport()
        let client = LemonSqueezyLicenseClient(transport: transport)
        var body = try! JSONSerialization.jsonObject(with: LemonSqueezyLicenseTests.body("activated", true)) as! [String: Any]
        body["meta"] = NSNull()
        transport.responses = [.success(HTTPResponse(data: try! JSONSerialization.data(withJSONObject: body), statusCode: 200)),
                               .success(HTTPResponse(data: LemonSqueezyLicenseTests.body("deactivated", true), statusCode: 200))]
        do { _ = try await client.activate(key: "KEY"); recordFailure("An unparseable activation was accepted") }
        catch { expectEqual(error as? LicenseError, .invalidResponse) }
        expectEqual(transport.requests.map { $0.url?.lastPathComponent }, ["activate", "deactivate"])
        expectTrue(String(data: transport.requests[1].httpBody!, encoding: .utf8)!.contains("instance_id=inst-1"))
    }

    private func expectNotNilLicense(_ store: MemoryLicenseStore, file: StaticString = #filePath, line: UInt = #line) {
        Checks.check(store.stored != nil, "Expected a stored license", file: file, line: line)
    }
}

private final class LicenseTestTrialStore: StateStore {
    var data: Data?
    func read(key: String) throws -> Data? { data }
    func write(_ data: Data, key: String) throws { self.data = data }
}
