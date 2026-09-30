import Cocoa
import SwiftUI

/// A dedicated titled window keeps the explanation and Cancel accessible while
/// choosing a profile. Merely opening or editing this form performs no IO.
@MainActor
enum BrowserLoginPrompt {
    static func window(for url: URL, onConsent: @escaping (BrowserLoginConsent) -> Void,
                       onCancel: @escaping () -> Void) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 490),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Browser login — one download"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:
            BrowserLoginForm(url: url, onConsent: onConsent, onCancel: onCancel))
        window.center()
        return window
    }
}

private struct BrowserLoginForm: View {
    let url: URL
    let onConsent: (BrowserLoginConsent) -> Void
    let onCancel: () -> Void
    @State private var browser: BrowserLoginConsent.Browser = .safari
    @State private var profile = ""
    @State private var error: String?
    @FocusState private var profileFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Use browser login for this download?").font(.headline)
                Text("The engine reads cookies from one browser profile and uses matching cookies for this site's requests. macOS may ask for access.")
                Text("Droplet does not send these cookies or this video URL to a license or support service.")
                Text(url.absoluteString).font(.system(size: 11, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).help(url.absoluteString)
                Picker("Browser", selection: $browser) {
                    ForEach(BrowserLoginConsent.Browser.allCases, id: \.self) { browser in
                        Text(browser.title).tag(browser)
                    }
                }
                if browser != .safari {
                    TextField("Profile name or path (blank = default)", text: $profile)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Browser profile name or path")
                        .focused($profileFocused)
                        .onChange(of: profile) { _, _ in error = nil }
                } else {
                    Text("Safari uses its default profile.").foregroundStyle(.secondary)
                }
                Text("Applies once to the URL above. Cancel stops the download. Your next ordinary download will not use browser login.")
                    .foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
            }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use login once") {
                    do {
                        onConsent(try BrowserLoginConsent(sourceURL: url, browser: browser,
                            profile: browser == .safari ? nil : profile))
                    } catch {
                        profileFocused = true
                        self.error = "Enter a valid profile without colons or control characters. No download has started."
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: browser) { _, _ in error = nil }
        .font(.system(size: 12))
        .padding(24)
        .frame(width: 440, height: 490)
    }
}
