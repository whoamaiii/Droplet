import Foundation

/// A user-approved capability for one explicit download, never persisted or
/// inferred from a failed request. It is bound to the URL shown at consent time.
struct BrowserLoginConsent: Equatable {
    enum Browser: String, CaseIterable {
        case safari, chrome, firefox, brave, edge
        var title: String { rawValue.capitalized }
    }
    enum Failure: Error { case invalidURL, invalidProfile }
    let sourceURL: URL
    let browser: Browser
    let profile: String?

    init(sourceURL: URL, browser: Browser, profile: String? = nil) throws {
        guard DownloadURLPolicy.parse(sourceURL.absoluteString) != nil else { throw Failure.invalidURL }
        let trimmed = profile?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            guard browser != .safari, trimmed.utf8.count <= 1024,
                  !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !trimmed.contains(":") else { throw Failure.invalidProfile }
        }
        self.sourceURL = sourceURL
        self.browser = browser
        self.profile = trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }

    var arguments: [String] {
        ["--no-cookies", "--cookies-from-browser", browser.rawValue + (profile.map { ":" + $0 } ?? "")]
    }
}
