import Foundation
import Security
import LocalAuthentication

/// Local cache is not a signed offline entitlement. Missing, unreadable and
/// corrupt credentials remain distinct, so a storage failure cannot reset trial
/// usage or silently grant paid access. No administrative API secret is stored.
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

    private var silentContext: LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    func load() throws -> StoredLicense? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        // Background startup must never open an authentication prompt.
        request[kSecUseAuthenticationContext as String] = silentContext
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
        var updateQuery = query
        updateQuery[kSecUseAuthenticationContext as String] = silentContext
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            attributes.forEach { addition[$0.key] = $0.value }
            let added = SecItemAdd(addition as CFDictionary, nil)
            guard added == errSecSuccess else { throw LicenseError.secureStorage(added) }
        } else if status != errSecSuccess { throw LicenseError.secureStorage(status) }
    }

    func remove() throws {
        var request = query
        request[kSecUseAuthenticationContext as String] = silentContext
        let status = SecItemDelete(request as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LicenseError.secureStorage(status) }
    }
}
