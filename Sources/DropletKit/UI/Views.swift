import Cocoa
import Combine
import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct DropletShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        guard w > 1, h > 1 else { return Path() }

        let y0 = h * 0.60      // top of the round belly
        let r = w * 0.5        // belly radius
        let k = 0.5523 * r     // cubic-circle approximation constant

        var p = Path()
        p.move(to: CGPoint(x: w * 0.5, y: 0))
        p.addQuadCurve(to: CGPoint(x: 0, y: y0),
                       control: CGPoint(x: w * 0.06, y: h * 0.26))
        p.addCurve(to: CGPoint(x: w * 0.5, y: y0 + r),
                   control1: CGPoint(x: 0, y: y0 + k),
                   control2: CGPoint(x: w * 0.5 - k, y: y0 + r))
        p.addCurve(to: CGPoint(x: w, y: y0),
                   control1: CGPoint(x: w * 0.5 + k, y: y0 + r),
                   control2: CGPoint(x: w, y: y0 + k))
        p.addQuadCurve(to: CGPoint(x: w * 0.5, y: 0),
                       control: CGPoint(x: w * 0.94, y: h * 0.26))
        p.closeSubpath()
        return p
    }
}

struct DropletHeader: View {
    @DropletReducedMotion private var reduceMotion
    @State private var droppedIn = false
    @State private var ripple = false
    @State private var bob = false

    var body: some View {
        ZStack {
            // ripple rings expanding after the drop lands
            if !reduceMotion {
            Circle()
                .stroke(Color.cyan.opacity(ripple ? 0 : 0.55), lineWidth: 2)
                .frame(width: 34, height: 34)
                .scaleEffect(ripple ? 3.2 : 0.7)
                .animation(.easeOut(duration: 0.9).delay(0.35), value: ripple)

            Circle()
                .stroke(Color.blue.opacity(ripple ? 0 : 0.40), lineWidth: 1.5)
                .frame(width: 34, height: 34)
                .scaleEffect(ripple ? 2.4 : 0.7)
                .animation(.easeOut(duration: 0.9).delay(0.50), value: ripple)
            }

            // the droplet itself: falls in with a springy bounce, then floats
            DropletShape()
                .fill(
                    LinearGradient(colors: [.cyan, .blue, .indigo],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 44, height: 56)
                .overlay(
                    Ellipse()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 9, height: 15)
                        .blur(radius: 1.5)
                        .offset(x: -10, y: 10)
                )
                .shadow(color: .blue.opacity(0.5), radius: 12, y: 5)
                .scaleEffect(reduceMotion || droppedIn ? 1 : 0.8, anchor: .bottom)
                .offset(y: reduceMotion || droppedIn ? 0 : -90)
                .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.6).delay(0.05), value: droppedIn)
                .offset(y: reduceMotion ? 0 : bob ? -3.5 : 3.5)
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.8).repeatForever(autoreverses: true).delay(1.0), value: bob)
        }
        .frame(height: 96)
        .clipped()
        .accessibilityHidden(true)
        .padding(.top, 14)
        .onAppear {
            droppedIn = true
            ripple = true
            bob = true
        }
    }
}

struct PressableButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @DropletReducedMotion private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                Capsule().stroke(Color.accentColor, lineWidth: isFocused ? 3 : 0)
                    .padding(-4)
            }
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Main bubble UI

struct MainView: View {
    @DropletReducedMotion private var reduceMotion
    @ObservedObject var manager: DownloadManager
    var onOpenDownloads: () -> Void
    var onBrowserLogin: () -> Void
    var onQuit: () -> Void
    var onClose: () -> Void
    var onSettings: () -> Void = {}
    var onOpenSavedFile: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            DropletHeader()

            Text("Droplet")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .padding(.top, 2)

            Text("Clipboard → MP4 in \(manager.downloadsFolder.lastPathComponent)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(manager.downloadsFolder.path)
                .padding(.top, 1)

            ScrollView {
                Group {
                    switch manager.phase {
                    case .idle: idleView
                    case .downloading: downloadingView
                    case .done: doneView
                    case .failed(let message): failedView(message)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 14)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .frame(maxHeight: .infinity, alignment: .top)

            footer
        }
        .frame(width: 320, height: 420)
        .background(VisualEffectView())
        .transaction { if reduceMotion { $0.animation = nil } }
        .id(manager.session)   // replays the droplet animation every time
    }

    // MARK: idle

    @ViewBuilder
    private var linkPreview: some View {
        if let url = manager.clipboardURL {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.host() ?? url.absoluteString)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(url.path.isEmpty ? "/" : url.path)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quinary))
        } else {
            HStack(spacing: 6) {
                Image(systemName: "clipboard")
                    .font(.system(size: 10, weight: .semibold))
                Text("Copy a video link — it shows up here")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        }
    }

    private var idleView: some View {
        VStack(spacing: 14) {
            linkPreview
            if let remaining = manager.trialRemaining {
                Button(remaining == 0 ? "Free trial complete · Details" : "\(remaining) of 3 free downloads left", action: onSettings)
                    .font(.system(size: 11, weight: .medium)).buttonStyle(.link)
            }
            if let problem = manager.trialProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }

            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    manager.startDownload()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 14, weight: .bold))
                    Text(manager.clipboardURL == nil ? "Grab Link from Clipboard" : "Download")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    Capsule().fill(
                        LinearGradient(colors: [Color(red: 0.06, green: 0.38, blue: 0.72), .indigo],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                )
                .shadow(color: .blue.opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(PressableButtonStyle())
            .keyboardShortcut(.defaultAction)
            .help("Download the video link copied to your clipboard")

            // Quit closes the app and cleans up its owned work only.
            Button {
                onQuit()
            } label: {
                Label("Quit Droplet — stop everything", systemImage: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(.quinary))
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, 2)
        }
    }

    // MARK: downloading

    private var downloadingView: some View {
        VStack(spacing: 14) {
            Text(manager.title.isEmpty ? "Fetching video…" : manager.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .help(manager.title)
                .padding(.horizontal, 4)

            if manager.progressKnown {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quinary)
                        Capsule()
                            .fill(LinearGradient(colors: [.cyan, .blue, .indigo],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(10, geo.size.width * manager.progress))
                    }
                }
                .frame(height: 9)
                .animation(.linear(duration: 0.25), value: manager.progress)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(Int(manager.progress * 100)) percent")
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(height: 9)
            }

            HStack(spacing: 10) {
                Text(manager.stage.rawValue + (manager.progressKnown ? " · \(Int(manager.progress * 100))%" : ""))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Button {
                    manager.cancel()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(".", modifiers: .command)
                .help("Cancel this download (Command-period)")
            }

            if !manager.retryNote.isEmpty {
                Text(manager.retryNote)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 4)
    }

    // MARK: done

    private var doneView: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.green, .teal],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(.white)
            }
            .shadow(color: .green.opacity(0.45), radius: 12, y: 4)
            .transition(.scale(scale: 0.4).combined(with: .opacity))

            Text("Video saved")
                .font(.system(size: 15, weight: .bold))
            Text(manager.result?.fileURL.deletingLastPathComponent().lastPathComponent ?? manager.downloadsFolder.lastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(manager.result?.fileURL.path ?? manager.downloadsFolder.path)

            if !manager.title.isEmpty {
                Text(manager.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .help(manager.title)
                    .padding(.horizontal, 6)
            }

            Button {
                onOpenDownloads()
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.link)
            if let problem = manager.trialProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            Button("New download") { manager.useNewClipboardLink() }
                .buttonStyle(.link)
            Button("Open video", action: onOpenSavedFile)
                .buttonStyle(.link)
                .disabled(manager.result == nil)
            Button("Done", action: onClose)
                .buttonStyle(.bordered)
                .keyboardShortcut(.defaultAction)
                .help("Close this window; the saved video stays in your download folder")
        }
    }

    // MARK: failed

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 2)
            Button {
                withAnimation { manager.retryFromFailure() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(
                        Capsule().fill(
                            LinearGradient(colors: [Color(red: 0.68, green: 0.22, blue: 0.07), Color(red: 0.68, green: 0.12, blue: 0.16)],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                    )
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!manager.canRetry)
            .keyboardShortcut(.defaultAction)
            Button("Use new clipboard link") { manager.useNewClipboardLink() }
                .font(.system(size: 11))
                .buttonStyle(.link)
            if manager.browserLoginURL != nil {
                Button("Use browser login…", action: onBrowserLogin)
                    .font(.system(size: 11))
                    .buttonStyle(.link)
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button {
                onOpenDownloads()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(manager.result == nil ? "Open download folder" : "Show saved file in Finder")
            .accessibilityLabel(manager.result == nil ? "Open download folder" : "Show saved file in Finder")

            Spacer()

            if !manager.updateNote.isEmpty {
                Text(manager.updateNote)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(manager.updateNote)
            } else {
                Text("Video links → MP4")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .help("Settings and About Droplet")
                .accessibilityLabel("Settings and About Droplet")
                .keyboardShortcut(",", modifiers: .command)

            Button {
                manager.updateDownloader()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Update download engine (yt-dlp)")
            .accessibilityLabel("Update download engine")
            .disabled(manager.isUpdating || manager.phase == .downloading)

            Button {
                onQuit()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Quit Droplet")
            .accessibilityLabel("Quit Droplet")
            .keyboardShortcut("q", modifiers: .command)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }
}
