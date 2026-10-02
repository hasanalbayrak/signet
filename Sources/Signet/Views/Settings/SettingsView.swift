import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @ObservedObject var appState: SignetAppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedP12URL: URL?
    @State private var inputPassword: String = ""
    @State private var selectedProfileURL: URL?
    @State private var statusReport: [BinaryManager.BinaryInfo] = []
    @State private var importErrorMessage: String?

    public init(appState: SignetAppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signet Preferences")
                        .font(.system(size: 16, weight: .bold))
                    Text("Manage signing credentials, provisioning profiles and CLI engines")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Section A: Certificate (.p12)
                    certificateSection()

                    // Section B: Provisioning Profile (.mobileprovision)
                    profileSection()

                    // Section C: System CLI Tools & Engines
                    cliToolsSection()
                }
                .padding(20)
            }
        }
        .frame(width: 580, height: 600)
        .onAppear {
            self.inputPassword = appState.p12Password
            self.statusReport = appState.binaryManager.getStatusReport()
        }
    }

    // MARK: - Certificate Section

    @ViewBuilder
    private func certificateSection() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Apple Developer Certificate (.p12)", systemImage: "key.fill")
                .font(.system(size: 13, weight: .semibold))

            if let cert = appState.certificate {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cert.commonName)
                            .font(.system(size: 13, weight: .semibold))
                        Text("Team: \(cert.teamName) (\(cert.teamId)) • \(cert.validityStatusText)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Replace") {
                        browseForP12()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 10) {
                    HStack {
                        Button {
                            browseForP12()
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text(selectedP12URL?.lastPathComponent ?? "Select .p12 Certificate File")
                            }
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }

                    if selectedP12URL != nil {
                        HStack {
                            SecureField("Enter .p12 Password", text: $inputPassword)
                                .textFieldStyle(.roundedBorder)

                            Button("Import Certificate") {
                                performP12Import()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            if let err = importErrorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Provisioning Profile Section

    @ViewBuilder
    private func profileSection() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Provisioning Profile (.mobileprovision)", systemImage: "doc.text.fill")
                .font(.system(size: 13, weight: .semibold))

            if let prof = appState.profile {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(prof.name)
                                .font(.system(size: 13, weight: .semibold))
                            if prof.isWildcard {
                                Text("Wildcard")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.2))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        Text("App ID: \(prof.applicationIdentifier) • \(prof.validityStatusText)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Replace") {
                        browseForProfile()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                HStack {
                    Button {
                        browseForProfile()
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text("Select .mobileprovision File")
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - CLI Tools Section

    @ViewBuilder
    private func cliToolsSection() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("CLI Engines & Binary Status", systemImage: "gearshape.2.fill")
                .font(.system(size: 13, weight: .semibold))

            VStack(spacing: 8) {
                ForEach(statusReport, id: \.name) { item in
                    HStack {
                        Circle()
                            .fill(item.isAvailable ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(item.path ?? item.source)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Text(item.isAvailable ? (item.version ?? "Available") : "Missing")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(item.isAvailable ? Color.green : Color.secondary)
                    }
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            HStack {
                Spacer()
                Button(role: .destructive) {
                    appState.clearSavedCredentials()
                } label: {
                    Text("Clear All Saved Credentials")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - File Browsers

    private func browseForP12() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "p12") ?? .data,
            UTType(filenameExtension: "pfx") ?? .data
        ]
        panel.prompt = "Select Certificate"

        if panel.runModal() == .OK, let url = panel.url {
            self.selectedP12URL = url
            self.importErrorMessage = nil
        }
    }

    private func browseForProfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "mobileprovision") ?? .data,
            UTType(filenameExtension: "provisionprofile") ?? .data
        ]
        panel.prompt = "Select Profile"

        if panel.runModal() == .OK, let url = panel.url {
            appState.importProfile(from: url)
        }
    }

    private func performP12Import() {
        guard let url = selectedP12URL else { return }
        appState.importP12(from: url, password: inputPassword)
        if appState.certificate != nil {
            self.importErrorMessage = nil
            self.selectedP12URL = nil
        }
    }
}
