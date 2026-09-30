import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: DownloadManager
    var onChooseFolder: () -> Void
    var onClose: () -> Void
    var onWelcome: () -> Void
    let version: String

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
                    Text("Trial and license").font(.headline)
                    trialStatus
                    Text("Purchasing and activation are not available in this local build. A payment receipt or pasted key cannot unlock it yet.")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    Text("Help and privacy").font(.headline)
                    Text("Copy a video link you have permission to download, open the droplet, and choose Download. Cancel stops the current job; closing the bubble lets it continue.")
                    Text("If saving fails, check folder access and free disk space. Choose a new folder if the original was moved or disconnected. Site compatibility can change.")
                    Text("Browser login is optional and approved for one download. Droplet does not send your video links or browser cookies to a license or support service.")
                    Text("This development build requires local yt-dlp and FFmpeg. Public signing, a bundled engine and a support contact must be configured before customer distribution.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(24)
            }
            Divider()
            HStack { Spacer(); Button("Done", action: onClose).keyboardShortcut(.defaultAction) }
                .padding(16)
        }
        .frame(width: 450, height: 560)
    }

    @ViewBuilder private var trialStatus: some View {
        if let problem = manager.trialProblem {
            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        } else if let remaining = manager.trialRemaining {
            Label(remaining == 0 ? "Your three free downloads have been used." : "\(remaining) of 3 free downloads remaining", systemImage: "gift")
            Text("Only a new, verified saved video counts. Failed or cancelled attempts do not use a download. The count is kept when you reopen or update the app.")
                .foregroundStyle(.secondary)
        } else {
            Text("Isolated development session — no trial quota is attached.").foregroundStyle(.secondary)
        }
    }
}

struct WelcomeView: View {
    var onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("A little drop in your menu bar", systemImage: "drop.fill").font(.title2.bold())
            Text("Copy a video link you have permission to download. Look for the droplet at the top of your screen, click it, and choose Download.")
            Label("Videos save as MP4. Choose your save folder in Settings.", systemImage: "folder")
            Label("macOS may ask for folder access. Allow it to save there, or select another folder.", systemImage: "hand.raised")
            Label("Try three successfully saved videos without an account. Failed and cancelled downloads do not count.", systemImage: "gift")
            Label("Browser login is optional and approved separately for each download.", systemImage: "person.crop.circle")
            Text("This is a local development build. Purchasing and license activation are not available yet.")
                .font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Got it", action: onContinue).keyboardShortcut(.defaultAction) }
        }
        .padding(28).frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
    }
}
