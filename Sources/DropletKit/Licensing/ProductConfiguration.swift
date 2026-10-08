import Foundation

/// Store and support details a release build supplies through Info.plist
/// (written by scripts/release.sh from release.env). Empty or invalid values
/// mean "not configured" and never unlock anything.
struct ProductConfiguration: Equatable {
    let licenseProduct: LicenseProduct?
    let checkoutURL: URL?
    let supportURL: URL?
    let websiteURL: URL?
    let privacyURL: URL?

    init(info: [String: Any]) {
        func text(_ key: String) -> String {
            (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func digits(_ key: String) -> String {
            let value = text(key)
            return !value.isEmpty && value.utf8.count <= 32 && value.allSatisfy(\.isASCII) && value.allSatisfy(\.isNumber) ? value : ""
        }
        let product = LicenseProduct(providerID: LemonSqueezyLicenseClient.providerID,
                                     storeID: digits("DropletLicenseStoreID"),
                                     productID: digits("DropletLicenseProductID"),
                                     variantID: digits("DropletLicenseVariantID"))
        licenseProduct = product.isConfigured ? product : nil
        checkoutURL = Self.webURL(text("DropletCheckoutURL"))
        let support = text("DropletSupportURL")
        supportURL = Self.webURL(support) ?? Self.mailURL(support)
        websiteURL = Self.webURL(text("DropletWebsiteURL"))
        privacyURL = Self.webURL(text("DropletPrivacyURL"))
    }

    static var live: ProductConfiguration { ProductConfiguration(info: Bundle.main.infoDictionary ?? [:]) }

    static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func mailURL(_ value: String) -> URL? {
        let address = value.hasPrefix("mailto:") ? String(value.dropFirst(7)) : value
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !address.contains(where: { $0.isWhitespace || "?&/<>\"".contains($0) }) else { return nil }
        return URL(string: "mailto:" + address)
    }
}
