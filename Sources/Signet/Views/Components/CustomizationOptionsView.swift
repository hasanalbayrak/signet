import SwiftUI
import UniformTypeIdentifiers

public struct CustomizationOptionsView: View {
    @ObservedObject var appState: SignetAppState
    @State private var isExpanded: Bool = false

    public init(appState: SignetAppState) {
        self.appState = appState
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                Divider()
                    .padding(.vertical, 4)

                // App Bundle ID & Display Name Grid
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Bundle ID:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .trailing)

                        TextField(
                            appState.ipaMetadata?.bundleIdentifier ?? "e.g. com.developer.customapp",
                            text: $appState.config.customBundleId
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                        if !appState.config.customBundleId.isEmpty {
                            Button {
                                appState.config.customBundleId = ""
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("Reset to original Bundle ID")
                        }
                    }

                    GridRow {
                        Text("App Name:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .trailing)

                        TextField(
                            appState.ipaMetadata?.displayName ?? "Custom App Display Name",
                            text: $appState.config.customDisplayName
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                        if !appState.config.customDisplayName.isEmpty {
                            Button {
                                appState.config.customDisplayName = ""
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("Reset to original Name")
                        }
                    }
                }

                // Dylib / Tweak Injection Section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Tweak & Dylib Injection", systemImage: "syringe")
                            .font(.system(size: 12, weight: .semibold))

                        Spacer()

                        Button {
                            browseForDylib()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("Add .dylib")
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if appState.config.injectedDylibs.isEmpty {
                        Text("No tweaks or external dylibs selected.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(Array(appState.config.injectedDylibs.enumerated()), id: \.element) { index, dylib in
                                HStack {
                                    Image(systemName: "puzzlepiece.extension")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.accentColor)

                                    Text(dylib.lastPathComponent)
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1)

                                    Spacer()

                                    Button {
                                        appState.removeDylib(at: IndexSet(integer: index))
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }

                // Compatibility Toggles
                VStack(alignment: .leading, spacing: 8) {
                    Text("Compatibility & Entitlements")
                        .font(.system(size: 12, weight: .semibold))

                    HStack(spacing: 20) {
                        Toggle("Strip Extensions (-E)", isOn: $appState.config.removeExtensions)
                            .font(.system(size: 11))
                            .help("Removes App Extensions / WatchKit plugins to prevent signature mismatch with wildcard profiles.")

                        Toggle("File Sharing (-S)", isOn: $appState.config.enableFileSharing)
                            .font(.system(size: 11))
                            .help("Enables iTunes File Sharing and Files app document access.")

                        Toggle("Universal Device (-U)", isOn: $appState.config.removeUISupportedDevices)
                            .font(.system(size: 11))
                            .help("Removes UISupportedDevices restriction to allow running on any screen size.")
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)

                Text("Customization Options (Bundle ID, Name & Tweaks)")
                    .font(.system(size: 13, weight: .semibold))

                if !appState.config.injectedDylibs.isEmpty || !appState.config.customBundleId.isEmpty || !appState.config.customDisplayName.isEmpty {
                    Text("Modified")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func browseForDylib() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "dylib") ?? .data,
            UTType(filenameExtension: "framework") ?? .folder
        ]
        panel.prompt = "Select Dylib"
        panel.message = "Choose .dylib tweaks or frameworks to inject into IPA"

        if panel.runModal() == .OK {
            for url in panel.urls {
                appState.addDylib(url: url)
            }
        }
    }
}
