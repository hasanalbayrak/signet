import SwiftUI
import UniformTypeIdentifiers

public struct IPADropZoneView: View {
    @ObservedObject var appState: SignetAppState
    @State private var isTargeted: Bool = false

    public init(appState: SignetAppState) {
        self.appState = appState
    }

    public var body: some View {
        Group {
            if let ipa = appState.selectedIPA {
                loadedStateView(ipa: ipa)
            } else {
                emptyDropTargetView()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Empty Drop Target

    @ViewBuilder
    private func emptyDropTargetView() -> some View {
        Button {
            browseForIPA()
        } label: {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isTargeted ? Color.accentColor.opacity(0.2) : Color.accentColor.opacity(0.08))
                        .frame(width: 60, height: 60)

                    Image(systemName: isTargeted ? "arrow.down.app.fill" : "arrow.down.doc")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: 4) {
                    Text("Drop your .ipa file here")
                        .font(.system(size: 15, weight: .semibold))

                    Text("or click anywhere to browse from Finder")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Text("Supports standard iOS IPAs, Decrypted binaries & Modded packages")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.05) : Color(nsColor: .controlBackgroundColor).opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [8, 6])
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loaded IPA Card

    @ViewBuilder
    private func loadedStateView(ipa: URL) -> some View {
        HStack(spacing: 16) {
            // App Icon Placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.7), Color.purple.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)

                Image(systemName: "app.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
            }

            // Info details
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(appState.ipaMetadata?.displayName ?? ipa.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 15, weight: .bold))

                    if let ver = appState.ipaMetadata?.version {
                        Text("v\(ver)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if appState.isInspectingIPA {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }

                HStack(spacing: 10) {
                    if let bid = appState.ipaMetadata?.bundleIdentifier {
                        Text(bid)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if let meta = appState.ipaMetadata {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(meta.formattedSize)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(ipa.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Change / Remove actions
            HStack(spacing: 8) {
                Button {
                    appState.showIPAManagerSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "shippingbox.fill")
                        Text("Manage & Entitlements")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open in IPA Manager to inspect package and export entitlements")

                Button {
                    browseForIPA()
                } label: {
                    Text("Replace")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    appState.clearIPA()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove IPA")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Drop & File Picker Helpers

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            if url.pathExtension.lowercased() == "ipa" {
                Task { @MainActor in
                    self.appState.setIPA(url: url)
                }
            }
        }
        return true
    }

    private func browseForIPA() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "ipa") ?? .data
        ]
        panel.prompt = "Select IPA"
        panel.message = "Choose an iOS App (.ipa) to sign"

        if panel.runModal() == .OK, let url = panel.url {
            appState.setIPA(url: url)
        }
    }
}
