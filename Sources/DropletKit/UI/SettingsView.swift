import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: DownloadManager
    @ObservedObject var license: LicenseController
    @ObservedObject var loginItem: LoginItemController
    let links: ProductConfiguration
    var onChooseFolder: () -> Void
    var onClose: () -> Void
    var onWelcome: () -> Void
    var onBuy: () -> Void
    var onOpenLink: (URL) -> Void
    var onThirdPartyNotices: () -> Void
    let version: String
    @State private var keyInput = ""
    @State private var confirmDeactivate = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Droplet", systemImage: "drop.fill").font(.title2.bold())
                    Text("Version \(version)").foregroundStyle(.secondary)
                    Button("Getting started", action: onWelcome)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Save videos to").font(.headline)
                        Text(manager.downloadsFolder.path).textSelection(.enabled)
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        if let problem = manager.destinationProblem {
                            Label(problem, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.red)
                        }
                        Button("Choose folder…", action: onChooseFolder)
                            .disabled(manager.phase == .downloading)
                        if manager.phase == .downloading {
                            Text("You can change the folder when this download finishes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Open Droplet at login", isOn: Binding(
                            get: { loginItem.isEnabled || loginItem.needsApproval },
                            set: { loginItem.setEnabled($0) }))
                        if loginItem.needsApproval {
                            Text("Allow Droplet in System Settings → General → Login Items.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Open Login Items…") { loginItem.openSystemSettings() }
                        }
                        if let message = loginItem.message {
                            Text(message).font(.caption).foregroundStyle(.red)
                        }
                    }
                    Divider()
                    licenseSection
                    Divider()
                    Text("Help and privacy").font(.headline)
                    Text("Copy a link to a video you have the right to download, open the droplet, and choose Download. Cancel stops the current job; closing the bubble lets it continue.")
                    Text("If saving fails, check folder access and free disk space. Choose a new folder if the original was moved or disconnected. Sites change often: use the update button in the bubble if downloads from a site stop working.")
                    Text("Browser login is optional and approved for one download. Droplet has no tracking or analytics. Activating a license sends only your license key to the payment provider; video links and browser cookies are never sent anywhere except the video site itself.")
                    if !manager.engineIsBundled {
                        Text("Development build: uses Homebrew yt-dlp and FFmpeg.")
                            .foregroundStyle(.secondary)
                    }
                    linkRow
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(24)
            }
            Divider()
            HStack { Spacer(); Button("Done", action: onClose).keyboardShortcut(.defaultAction) }
                .padding(16)
        }
        .frame(width: 450, height: 600)
        .onAppear { loginItem.refresh() }
        .confirmationDialog("Deactivate Droplet on this Mac?", isPresented: $confirmDeactivate) {
            Button("Deactivate", role: .destructive) { Task { await license.deactivate() } }
        } message: {
            Text("Your key stays valid and can be activated on another Mac.")
        }
    }

    // MARK: license

    @ViewBuilder private var licenseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("License").font(.headline)
            switch license.state {
            case .licensed:
                Label("Droplet is activated on this Mac", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let masked = license.maskedKey {
                    Text("License key \(masked)").foregroundStyle(.secondary)
                }
                if license.needsOnlineCheck {
                    Text("Droplet hasn't been able to confirm your license for 30 days. Connect to the internet and choose Check license.")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Check license") { Task { await license.refreshIfDue(force: true) } }
                    Button("Deactivate this Mac…") { confirmDeactivate = true }
                }
                .disabled(license.isWorking)
            case .notConfigured:
                trialStatus
                Text("Purchasing isn't set up in this build.").foregroundStyle(.secondary)
            case .unlicensed, .unavailable:
                trialStatus
                if license.state == .unavailable {
                    Text("Droplet couldn't read a saved license. If you bought Droplet, enter your key again.")
                        .foregroundStyle(.orange)
                }
                if license.checkoutURL != nil {
                    Button("Buy Droplet…", action: onBuy)
                }
                HStack {
                    TextField("License key", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("License key")
                        .onSubmit(activate)
                    Button("Activate", action: activate)
                        .disabled(license.isWorking || keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Your key is in the purchase email. One key activates Droplet on your Macs up to the limit shown at checkout.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if license.isWorking {
                ProgressView().controlSize(.small)
            }
            if let message = license.message {
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func activate() {
        let key = keyInput
        Task {
            await license.activate(key: key)
            if license.isLicensed { keyInput = "" }
        }
    }

    @ViewBuilder private var trialStatus: some View {
        if let problem = manager.trialProblem {
            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        } else if let remaining = manager.trialRemaining {
            Label(remaining == 0 ? "Your three free downloads have been used." : "\(remaining) of 3 free downloads remaining", systemImage: "gift")
            Text("Only a new, verified saved video counts. Failed or cancelled attempts do not use a download.")
                .foregroundStyle(.secondary)
        } else {
            Text("Isolated development session — no trial quota is attached.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var linkRow: some View {
        HStack(spacing: 14) {
            if let url = links.websiteURL { Button("Website") { onOpenLink(url) }.buttonStyle(.link) }
            if let url = links.supportURL { Button("Support") { onOpenLink(url) }.buttonStyle(.link) }
            if let url = links.privacyURL { Button("Privacy") { onOpenLink(url) }.buttonStyle(.link) }
            Button("Third-party licenses", action: onThirdPartyNotices).buttonStyle(.link)
        }
    }
}

struct WelcomeView: View {
    var purchaseAvailable: Bool
    var onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("A little drop in your menu bar", systemImage: "drop.fill").font(.title2.bold())
            Text("Copy a link to a video you have the right to download. Look for the droplet at the top of your screen, click it, and choose Download.")
            Label("Videos save as MP4. Choose your save folder in Settings.", systemImage: "folder")
            Label("macOS may ask for folder access. Allow it to save there, or select another folder.", systemImage: "hand.raised")
            Label("Try three successfully saved videos without an account. Failed and cancelled downloads do not count.", systemImage: "gift")
            Label("Browser login is optional and approved separately for each download.", systemImage: "person.crop.circle")
            Text(purchaseAvailable
                 ? "After the free downloads, buy Droplet once and enter your license key in Settings."
                 : "Purchasing and license activation are not available in this build.")
                .font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Got it", action: onContinue).keyboardShortcut(.defaultAction) }
        }
        .padding(28).frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
    }
}
