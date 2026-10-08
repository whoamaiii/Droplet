import Foundation
import Security

/// The updated engine's SHA-256 in the login keychain, readable without a
/// prompt only by this app (see KeychainLicenseStore for why no
/// data-protection attributes are used).
struct KeychainEngineFingerprintStore: EngineFingerprintStore {
    let service: String
    private let account = "updated-yt-dlp-sha256"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func load() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 64 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ digest: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(digest.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            attributes.forEach { addition[$0.key] = $0.value }
            let added = SecItemAdd(addition as CFDictionary, nil)
            guard added == errSecSuccess else { throw LicenseError.secureStorage(added) }
        } else if status != errSecSuccess { throw LicenseError.secureStorage(status) }
    }
}
