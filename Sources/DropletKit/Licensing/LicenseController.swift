import Foundation
import Combine

/// Paid access for one Mac. Policy (launch plan): validate at most once a day,
/// tolerate 30 days without reaching the provider, and only an authoritative
/// provider answer removes a license. Network trouble never does.
@MainActor
final class LicenseController: ObservableObject {
    enum State: Equatable {
        /// This build has no store/product configured; only the trial exists.
        case notConfigured
        case unlicensed
        case licensed(StoredLicense)
        /// The Keychain could not be read. Fails closed to the trial; entering
        /// the key again replaces the unreadable item.
        case unavailable
    }

    @Published private(set) var state: State
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    let checkoutURL: URL?
    private let expectedProduct: LicenseProduct?
    private let client: any LicenseClient
    private let store: any LicenseStore
    private let now: () -> Date

    static let revalidationInterval: TimeInterval = 24 * 60 * 60
    static let offlineGrace: TimeInterval = 30 * 24 * 60 * 60
    /// Tolerated clock difference for a check recorded "in the future".
    static let clockSkew: TimeInterval = 24 * 60 * 60

    init(product: LicenseProduct?, checkoutURL: URL?, client: any LicenseClient,
         store: any LicenseStore, now: @escaping () -> Date = Date.init) {
        self.expectedProduct = product?.isConfigured == true ? product : nil
        self.checkoutURL = checkoutURL
        self.client = client
        self.store = store
        self.now = now
        guard let expected = expectedProduct else { state = .notConfigured; return }
        state = Self.loadState(from: store, expected: expected)
    }

    private static func loadState(from store: any LicenseStore, expected: LicenseProduct) -> State {
        do {
            if let stored = try store.load(), expected.accepts(stored.product) { return .licensed(stored) }
            return .unlicensed
        } catch { return .unavailable }
    }

    static func live(configuration: ProductConfiguration) -> LicenseController {
        LicenseController(product: configuration.licenseProduct, checkoutURL: configuration.checkoutURL,
            client: LemonSqueezyLicenseClient(transport: URLSessionTransport()),
            store: KeychainLicenseStore(service: (Bundle.main.bundleIdentifier ?? "droplet") + ".license"))
    }

    var isConfigured: Bool { state != .notConfigured }

    /// True only while the stored license is within its offline allowance.
    /// A check dated in the future (clock change or edited cache) does not
    /// extend the allowance; it needs a fresh online check.
    var isLicensed: Bool {
        guard case .licensed(let license) = state else { return false }
        let current = now()
        if let expiry = license.expiresAt, expiry <= current { return false }
        let age = current.timeIntervalSince(license.lastValidatedAt)
        return age > -Self.clockSkew && age < Self.offlineGrace
    }

    /// Licensed, but the offline allowance ran out: one successful check restores access.
    var needsOnlineCheck: Bool {
        if case .licensed = state { return !isLicensed }
        return false
    }

    var maskedKey: String? {
        guard case .licensed(let license) = state else { return nil }
        return "••••" + String(license.key.suffix(4))
    }

    func clearMessage() { message = nil }

    func activate(key raw: String) async {
        guard let product = expectedProduct, !isWorking else { return }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleKey(key) else { message = Self.describe(LicenseError.invalidKey); return }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let evidence = try await client.activate(key: key)
            do {
                let result = try LicenseEvidenceValidator(expectedProduct: product)
                    .validate(evidence, expectedInstance: nil, now: now())
                guard result == .valid else { throw LicenseError.rejected(nil) }
            } catch {
                // An activation this Mac cannot use must not count against the key.
                try? await client.deactivate(key: key, instance: evidence.instance)
                throw error
            }
            let license = StoredLicense(key: key, product: evidence.product, instance: evidence.instance,
                                        lastValidatedAt: now(), expiresAt: evidence.expiresAt)
            do { try store.save(license) } catch {
                try? await client.deactivate(key: key, instance: evidence.instance)
                throw error
            }
            state = .licensed(license)
            message = "Thank you! Droplet is activated on this Mac."
        } catch {
            message = Self.describe(error)
        }
    }

    /// Re-validates when a day has passed (or when forced from Settings).
    /// An unreadable Keychain (for example still locked right after login) is
    /// read again first, so a paying customer is not held to the trial.
    func refreshIfDue(force: Bool = false) async {
        guard let product = expectedProduct, !isWorking else { return }
        if state == .unavailable { state = Self.loadState(from: store, expected: product) }
        guard case .licensed(let license) = state else { return }
        let age = now().timeIntervalSince(license.lastValidatedAt)
        guard force || age >= Self.revalidationInterval || age < 0 else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let evidence = try await client.validate(key: license.key, instance: license.instance)
            let result = try LicenseEvidenceValidator(expectedProduct: product)
                .validate(evidence, expectedInstance: license.instance, now: now())
            guard result == .valid else { throw LicenseError.rejected(nil) }
            let refreshed = StoredLicense(key: license.key, product: evidence.product, instance: license.instance,
                                          lastValidatedAt: now(), expiresAt: evidence.expiresAt)
            // A failed cache write only means validating again sooner.
            try? store.save(refreshed)
            state = .licensed(refreshed)
            if force { message = "Your license is active." }
        } catch let error where Self.isAuthoritative(error) {
            try? store.remove()
            state = .unlicensed
            message = "Your license is no longer active on this Mac. " + Self.describe(error)
        } catch {
            if force || needsOnlineCheck { message = Self.describe(error) }
        }
    }

    func deactivate() async {
        guard !isWorking, case .licensed(let license) = state else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.deactivate(key: license.key, instance: license.instance)
        } catch let error where !Self.isAuthoritative(error) {
            message = "Couldn't reach the license server, so this Mac is still activated. Try again when you're online."
            return
        } catch {
            // The provider no longer knows this activation; remove the local copy too.
        }
        do { try store.remove() } catch {
            message = Self.describe(error)
            return
        }
        state = .unlicensed
        message = "This Mac has been deactivated. You can now use your key on another Mac."
    }

    static func isPlausibleKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 256
            && !key.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }

    static func isAuthoritative(_ error: Error) -> Bool {
        switch error as? LicenseError {
        case .rejected?, .wrongProduct?, .wrongInstance?, .expired?: return true
        default: return false
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? LicenseError {
        case .rejected(let reason)?:
            if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty, reason.count <= 200 {
                return "The license server declined this key: \(reason)"
            }
            return "This license key was not accepted."
        case .wrongProduct?: return "This key belongs to a different product."
        case .wrongInstance?: return "This activation no longer matches this Mac."
        case .expired?: return "This license key has expired."
        case .invalidKey?: return "Paste the license key from your purchase email."
        case .secureStorage?: return "Droplet couldn't save your license in the Keychain. Restart your Mac and try again."
        case .notConfigured?: return "Purchasing isn't set up in this build."
        default: return "Couldn't reach the license server. Check your internet connection and try again."
        }
    }
}
