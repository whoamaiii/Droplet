import Foundation
import Security

/// Local cache is not a signed offline entitlement. Missing, unreadable and
/// corrupt credentials remain distinct, so a storage failure cannot reset trial
/// usage or silently grant paid access. No administrative API secret is stored.
///
/// The item lives in the login (file-based) keychain, which a non-sandboxed
/// Developer ID app uses without extra entitlements. Its access list trusts
/// this app's designated requirement, so later releases signed by the same
/// team read it without a prompt. Data-protection-only attributes and
/// authentication contexts are deliberately not used: they do not apply to
/// this keychain and must not redirect queries to a different one.
struct KeychainLicenseStore: LicenseStore {
    private let service: String
    private let account: String

    init(service: String = "com.quentin.droplet.license", account: String = "current-license") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> StoredLicense? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LicenseError.secureStorage(status) }
        guard let data = result as? Data, data.count <= 16_384,
              let stored = try? JSONDecoder().decode(StoredLicense.self, from: data) else {
            throw LicenseError.invalidResponse
        }
        try stored.validateStructure()
        return stored
    }

    func save(_ license: StoredLicense) throws {
        try license.validateStructure()
        let data = try JSONEncoder().encode(license)
        guard data.count <= 16_384 else { throw LicenseError.invalidResponse }
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            attributes.forEach { addition[$0.key] = $0.value }
            let added = SecItemAdd(addition as CFDictionary, nil)
            guard added == errSecSuccess else { throw LicenseError.secureStorage(added) }
        } else if status != errSecSuccess { throw LicenseError.secureStorage(status) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LicenseError.secureStorage(status) }
    }
}
