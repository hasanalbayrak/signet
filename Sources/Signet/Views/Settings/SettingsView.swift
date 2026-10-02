import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @ObservedObject var appState: SignetAppState
    @Environment(\.dismiss) private var dismiss

    public enum SettingsTab: String, CaseIterable, Identifiable {
        case appleID = "Apple ID (Direct + 2FA)"
        case apiKey = "API Key (.p8)"
        case manualFiles = "Manual (.p12 / Profile)"
        case engines = "CLI Engines"
        public var id: String { rawValue }
    }

    @State private var selectedTab: SettingsTab = .appleID

    // Manual state
    @State private var selectedP12URL: URL?
    @State private var inputPassword: String = ""
    @State private var selectedProfileURL: URL?
    @State private var importErrorMessage: String?

    // API Key state
    @State private var selectedP8URL: URL?
    @State private var p8FileLoaded: Bool = false
    @State private var statusReport: [BinaryManager.BinaryInfo] = []

    @FocusState private var is2FAFieldFocused: Bool

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
                    case .appleID:
                        appleIDSection()
                    case .apiKey:
                        apiKeySection()
                    case .manualFiles:
                        manualFilesSection()
                    case .engines:
                        cliToolsSection()
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 640, height: 640)
        .onAppear {
            self.inputPassword = appState.p12Password
            self.statusReport = appState.binaryManager.getStatusReport()
            if !appState.ascCredentials.privateKeyPem.isEmpty {
                self.p8FileLoaded = true
            }
            if appState.currentDeveloperSession != nil {
                self.selectedTab = .appleID
            }
        }
    }

    // MARK: - Direct Apple ID + 2FA Section

    @ViewBuilder
    private func appleIDSection() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Feature Banner
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Direct Apple ID Sign-In with 2FA")
                        .font(.system(size: 13, weight: .bold))
                    Text("Log in with your Apple ID, enter the 2FA code sent to your devices, and select your developer team. Signet handles certificate and profile creation automatically.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if appState.isAwaiting2FA {
                // 2FA Challenge Box
                twoFactorChallengeView()
            } else if let session = appState.currentDeveloperSession {
                // Authenticated State
                authenticatedAppleIDView(session: session)
            } else {
                // Login Form
                appleIDLoginFormView()
            }
        }
    }

    @ViewBuilder
    private func twoFactorChallengeView() -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 56, height: 56)

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.orange)
            }

            VStack(spacing: 4) {
                Text("Two-Factor Authentication")
                    .font(.system(size: 15, weight: .bold))

                Text("A verification code was sent to your Apple devices for **\(appState.appleIDEmail)**. Enter the 6-digit code below:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            HStack(spacing: 12) {
                TextField("••••••", text: $appState.twoFactorCode)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 180)
                    .textFieldStyle(.roundedBorder)
                    .focused($is2FAFieldFocused)
                    .onSubmit {
                        appState.submitTwoFactorCode()
                    }
                    .onAppear {
                        is2FAFieldFocused = true
                    }
            }

            HStack(spacing: 14) {
                Button("Cancel") {
                    appState.cancelTwoFactor()
                }
                .buttonStyle(.bordered)

                Button {
                    appState.submitTwoFactorCode()
                } label: {
                    HStack(spacing: 6) {
                        if appState.isAppleIDSigningIn {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Verify Code")
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines).count < 6 || appState.isAppleIDSigningIn)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func authenticatedAppleIDView(session: AppleDeveloperSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Account Badge
            HStack {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "person.fill.checkmark")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.green)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.userFullName)
                        .font(.system(size: 13, weight: .bold))
                    Text(session.appleId)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Sign Out") {
                    appState.signOutAppleID()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Team Picker
            VStack(alignment: .leading, spacing: 8) {
                Label("Developer Team", systemImage: "person.3.fill")
                    .font(.system(size: 12, weight: .semibold))

                if !appState.availableTeams.isEmpty {
                    Picker("Select Team:", selection: $appState.selectedTeam) {
                        ForEach(appState.availableTeams) { team in
                            Text(team.displayTitle).tag(Optional(team))
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    Text("No developer teams discovered. Ensure your Apple ID has an active Developer Program membership.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Target Device Notification
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
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // 1-Click Provisioning Button
            VStack(spacing: 8) {
                Button {
                    appState.startAutoProvisioningWithAppleID()
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
                .disabled(appState.autoProvisioningStep.isBusy || appState.selectedTeam == nil)

                if appState.autoProvisioningStep.isBusy {
                    Text(appState.autoProvisioningStep.message)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func appleIDLoginFormView() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Apple ID:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)

                    TextField("name@example.com", text: $appState.appleIDEmail)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                GridRow {
                    Text("Password:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)

                    SecureField("Apple ID Password", text: $appState.appleIDPassword)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit {
                            appState.signInWithAppleID()
                        }
                }
            }

            HStack {
                Spacer()

                Button {
                    appState.signInWithAppleID()
                } label: {
                    HStack(spacing: 6) {
                        if appState.isAppleIDSigningIn {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        Text("Sign In with Apple ID")
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.appleIDEmail.isEmpty || appState.appleIDPassword.isEmpty || appState.isAppleIDSigningIn)
            }

            Text("🔒 Direct communication with official Apple Identity servers (`idmsa.apple.com`). Your credentials and session are protected locally inside macOS Keychain.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - App Store Connect API Key Section

    @ViewBuilder
    private func apiKeySection() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text("App Store Connect API Key")
                        .font(.system(size: 13, weight: .bold))
                    Text("Permanent, automated access with no passwords or 2FA prompts. Perfect for team and individual developer setups.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 10) {
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
                            Text("Connect & Verify API Key")
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

            // API Key Provision Action
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
                        Text(appState.autoProvisioningStep.isBusy ? appState.autoProvisioningStep.message : "1-Click Auto Provision via API Key")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(appState.autoProvisioningStep.isBusy || !appState.ascCredentials.isValid)
            }
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
