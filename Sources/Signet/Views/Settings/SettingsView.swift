import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @ObservedObject var appState: SignetAppState
    @Environment(\.dismiss) private var dismiss

    public enum SettingsTab: String, CaseIterable, Identifiable {
        case autoProvision = "Apple Developer Login"
        case manualFiles = "Manual (.p12 / Profile)"
        case engines = "CLI Engines"
        public var id: String { rawValue }
    }

    @State private var selectedTab: SettingsTab = .autoProvision

    // Manual state
    @State private var selectedP12URL: URL?
    @State private var inputPassword: String = ""
    @State private var selectedProfileURL: URL?
    @State private var importErrorMessage: String?

    // Auto-provision state
    @State private var selectedP8URL: URL?
    @State private var p8FileLoaded: Bool = false
    @State private var statusReport: [BinaryManager.BinaryInfo] = []

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
                    Text("Manage signing credentials, Apple Developer Accounts and CLI engines")
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

            // Tab Selector
            Picker("Mode", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    switch selectedTab {
                    case .autoProvision:
                        autoProvisionSection()
                    case .manualFiles:
                        manualFilesSection()
                    case .engines:
                        cliToolsSection()
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 620, height: 620)
        .onAppear {
            self.inputPassword = appState.p12Password
            self.statusReport = appState.binaryManager.getStatusReport()
            if !appState.ascCredentials.privateKeyPem.isEmpty {
                self.p8FileLoaded = true
            }
        }
    }

    // MARK: - Auto-Provisioning (Apple Developer API)

    @ViewBuilder
    private func autoProvisionSection() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Feature Banner
            HStack(spacing: 12) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Zero-Friction Apple Developer Auto-Provisioning")
                        .font(.system(size: 13, weight: .bold))
                    Text("No manual .p12 export, no 2FA interruptions, and no third-party anisette servers. Uses your official App Store Connect API Key to generate 365-day certificates and profiles.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Active Certificate Badge if present
            if let cert = appState.certificate {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.green)
                        .font(.system(size: 18))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active Certificate: \(cert.teamName)")
                            .font(.system(size: 12, weight: .bold))
                        Text("Team ID: \(cert.teamId) • \(cert.validityStatusText)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let prof = appState.profile {
                        Text(prof.isWildcard ? "Wildcard (*)" : "App Specific")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundStyle(Color.blue)
                            .clipShape(Capsule())
                    }
                }
                .padding(10)
                .background(Color.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Step 1: App Store Connect API Credentials
            VStack(alignment: .leading, spacing: 10) {
                Label("App Store Connect API Key", systemImage: "key.horizontal.fill")
                    .font(.system(size: 12, weight: .semibold))

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Key ID:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)

                        TextField("e.g. 2X9R427NDK", text: $appState.ascCredentials.keyId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }

                    GridRow {
                        Text("Issuer ID:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)

                        TextField("e.g. 57246542-96fe-1a63-e053-0824d011072a", text: $appState.ascCredentials.issuerId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }

                    GridRow {
                        Text("Private Key:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)

                        HStack {
                            Button {
                                browseForP8()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.badge.plus")
                                    Text(p8FileLoaded ? "Private Key Loaded (.p8)" : "Select AuthKey_XXXXX.p8 File")
                                }
                                .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)

                            if p8FileLoaded {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.green)
                                    .font(.system(size: 13))
                            }

                            Spacer()
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        appState.fetchAppleDeveloperTeams()
                    } label: {
                        HStack(spacing: 5) {
                            if appState.autoProvisioningStep == .fetchingTeams {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "link")
                            }
                            Text("Connect & Verify Account")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.autoProvisioningStep.isBusy || !appState.ascCredentials.isValid)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Step 2: Team Selection & Auto-Provision Execution
            VStack(alignment: .leading, spacing: 10) {
                Label("Developer Team & Provisioning", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 12, weight: .semibold))

                if !appState.availableTeams.isEmpty {
                    HStack {
                        Text("Select Team:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        Picker("", selection: $appState.selectedTeam) {
                            ForEach(appState.availableTeams) { team in
                                Text(team.displayTitle).tag(Optional(team))
                            }
                        }
                        .pickerStyle(.menu)

                        Spacer()
                    }
                }

                // Target Device Notice
                HStack(spacing: 8) {
                    Image(systemName: appState.selectedDevice?.deviceIconName ?? "iphone")
                        .foregroundStyle(Color.accentColor)

                    if let dev = appState.selectedDevice {
                        Text("Target Device: **\(dev.displayName)** will be auto-registered in Apple Developer Portal.")
                            .font(.system(size: 11))
                    } else {
                        Text("No iOS device currently selected. Will generate profile for all registered team devices.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Auto-Provision Action Button
                VStack(spacing: 8) {
                    Button {
                        appState.startAutoProvisioning()
                    } label: {
                        HStack(spacing: 8) {
                            if appState.autoProvisioningStep.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "bolt.badge.automatic.fill")
                            }
                            Text(appState.autoProvisioningStep.isBusy ? appState.autoProvisioningStep.message : "1-Click Auto Provision (365 Days)")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(appState.autoProvisioningStep.isBusy || !appState.ascCredentials.isValid)

                    if appState.autoProvisioningStep.isBusy {
                        Text(appState.autoProvisioningStep.message)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.top, 4)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Guidance & Documentation
            VStack(alignment: .leading, spacing: 4) {
                Text("How to get your App Store Connect API Key:")
                    .font(.system(size: 11, weight: .bold))
                Text("1. Visit developer.apple.com > **App Store Connect** > **Users and Access** > **Integrations**.\n2. Under **App Store Connect API**, click **Generate API Key** (Role: Developer or Admin).\n3. Copy the **Key ID**, **Issuer ID**, and download the **.p8** file.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Manual Files Section

    @ViewBuilder
    private func manualFilesSection() -> some View {
        VStack(spacing: 16) {
            certificateSection()
            profileSection()
        }
    }

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

    private func browseForP8() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "p8") ?? .data,
            UTType(filenameExtension: "txt") ?? .plainText
        ]
        panel.prompt = "Select .p8 Key"

        if panel.runModal() == .OK, let url = panel.url {
            self.selectedP8URL = url
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                appState.ascCredentials.privateKeyPem = content
                self.p8FileLoaded = true
            }
        }
    }

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
