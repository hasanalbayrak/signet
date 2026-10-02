import Foundation
import SwiftUI
import AppKit

@MainActor
public final class SignetAppState: ObservableObject {
    // MARK: - Published Properties

    // Devices
    @Published public var devices: [Device] = []
    @Published public var selectedDevice: Device?
    @Published public var isRefreshingDevices: Bool = false

    // Credentials
    @Published public var certificate: CertificateInfo?
    @Published public var profile: ProvisioningProfileInfo?
    @Published public var p12Password: String = ""

    // IPA & Metadata
    @Published public var selectedIPA: URL?
    @Published public var ipaMetadata: IPAMetadata?
    @Published public var isInspectingIPA: Bool = false

    // Signing Customization
    @Published public var config = SigningConfiguration()

    // Pipeline Execution
    @Published public var pipelineStep: PipelineStep = .idle
    @Published public var lastSignedIPAURL: URL?

    // Logs
    @Published public var logs: [LogMessage] = []
    @Published public var autoScrollLogs: Bool = true

    // UI State
    @Published public var showSettingsSheet: Bool = false
    @Published public var showErrorAlert: Bool = false
    @Published public var alertErrorMessage: String = ""
    @Published public var showPasswordPrompt: Bool = false
    @Published public var passwordPromptMessage: String = ""

    // Apple Developer Auto-Provisioning (API Key & Apple ID)
    @Published public var ascCredentials = AppStoreConnectCredentials(keyId: "", issuerId: "", privateKeyPem: "")
    @Published public var availableTeams: [DeveloperTeam] = []
    @Published public var selectedTeam: DeveloperTeam? {
        didSet {
            guard let team = selectedTeam else { return }
            if currentDeveloperSession?.selectedTeamId != team.id {
                currentDeveloperSession?.selectedTeamId = team.id
                currentDeveloperSession?.selectedTeamName = team.name
                if let session = currentDeveloperSession {
                    saveAppleDeveloperSession(session)
                }
            }
            loadPortalData()
        }
    }
    @Published public var autoProvisioningStep: AutoProvisioningStep = .idle

    // Direct Apple ID & 2FA State
    @Published public var appleIDEmail: String = ""
    @Published public var appleIDPassword: String = ""
    @Published public var isAwaiting2FA: Bool = false
    @Published public var twoFactorCode: String = ""
    @Published public var twoFactorContext: Apple2FAContext? = nil
    @Published public var currentDeveloperSession: AppleDeveloperSession? = nil
    @Published public var isAppleIDSigningIn: Bool = false
    @Published public var showAppleWebLoginSheet: Bool = false
    @Published public var settingsInlineErrorMessage: String? = nil

    // Portal Management
    @Published public var portalDevices: [PortalDevice] = []
    @Published public var portalCertificates: [PortalCertificate] = []
    @Published public var portalAppIds: [PortalAppId] = []
    @Published public var keychainIdentities: [KeychainIdentity] = []
    @Published public var isPortalLoading: Bool = false
    @Published public var portalStatusMessage: String? = nil
    @Published public var autoRevokeOldCertsOnLimit: Bool = true

    // CLI Engine Management
    @Published public var isInstallingEngine: Bool = false
    @Published public var engineInstallLog: String = ""

    // MARK: - Dependencies
    private let credentialService = CredentialService.shared
    private let deviceService = DeviceService.shared
    private let signerService = SignerService.shared
    private let installerService = InstallerService.shared
    private let ipaManager = IPAManager.shared
    private let appleDeveloperService = AppleDeveloperService.shared
    private let appleAuthService = AppleAuthService.shared
    public let binaryManager = BinaryManager.shared

    private var devicePollTask: Task<Void, Never>?

    public init() {
        loadInitialState()
    }

    deinit {
        devicePollTask?.cancel()
    }

    // MARK: - Initial Setup

    private func loadInitialState() {
        appendLog(LogMessage(level: .info, message: "Welcome to Signet — Native macOS Sideloading Tool."))

        // 1. Load cached credentials
        let saved = credentialService.loadSavedCredentials()
        if let cert = saved.cert {
            self.certificate = cert
            if let pwd = credentialService.loadPasswordFromKeychain() {
                self.p12Password = pwd
            }
            appendLog(LogMessage(level: .info, message: "Loaded developer certificate: \(cert.teamName) (\(cert.validityStatusText))"))
        }

        if let prof = saved.profile {
            self.profile = prof
            appendLog(LogMessage(level: .info, message: "Loaded provisioning profile: \(prof.name) (\(prof.isWildcard ? "Wildcard" : "App Specific"))"))
        }

        // 2. Load saved Apple Developer API credentials & Apple ID session
        loadAscCredentials()
        loadSavedAppleIDSession()

        // 3. Discover devices
        refreshDevices()

        // 3. Check binary availability
        let report = binaryManager.getStatusReport()
        for item in report {
            if item.isAvailable {
                appendLog(LogMessage(level: .verbose, message: "Found \(item.name): \(item.path ?? "")"))
            } else {
                appendLog(LogMessage(level: .warning, message: "Missing \(item.name): \(item.source)"))
            }
        }
    }

    // MARK: - Device Operations

    public func refreshDevices() {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true

        Task {
            let found = await deviceService.discoverDevices()
            self.devices = found

            // Preserve existing selection if still connected, otherwise pick first available
            if let current = selectedDevice, let updated = found.first(where: { $0.udid == current.udid }) {
                self.selectedDevice = updated
            } else {
                self.selectedDevice = found.first(where: { $0.isAvailable }) ?? found.first
            }

            self.isRefreshingDevices = false

            if found.isEmpty {
                self.appendLog(LogMessage(level: .info, message: "No iOS devices connected. Connect via USB or ensure Wi-Fi sync is enabled."))
            } else {
                self.appendLog(LogMessage(level: .success, message: "Discovered \(found.count) iOS device(s)."))
            }
        }
    }

    // MARK: - Credential Operations

    public func importP12(from url: URL, password: String) throws {
        let cert = try credentialService.importAndSaveP12(from: url, password: password)
        self.certificate = cert
        self.p12Password = password
        self.showPasswordPrompt = false
        appendLog(LogMessage(level: .success, message: "Certificate successfully imported: \(cert.commonName)"))
    }

    public func promptForCertificatePassword(message: String? = nil) {
        self.passwordPromptMessage = message ?? "Please enter the password for your .p12 certificate:"
        self.showPasswordPrompt = true
    }

    public func updateP12Password(_ newPassword: String) {
        self.p12Password = newPassword
        do {
            try credentialService.savePasswordToKeychain(newPassword)
            appendLog(LogMessage(level: .success, message: "Certificate password updated in Keychain."))
        } catch {
            appendLog(LogMessage(level: .warning, message: "Could not save password to Keychain: \(error.localizedDescription)"))
        }

        // Re-validate against saved .p12 if present
        let p12Path = credentialService.savedP12URL
        if FileManager.default.fileExists(atPath: p12Path.path) {
            do {
                let cert = try credentialService.importAndSaveP12(from: p12Path, password: newPassword)
                self.certificate = cert
                self.showPasswordPrompt = false
                appendLog(LogMessage(level: .success, message: "Certificate validated successfully with new password: \(cert.commonName)"))
            } catch {
                appendLog(LogMessage(level: .error, message: "Password validation failed: \(error.localizedDescription)"))
                self.showError("The entered password could not unlock the certificate. Please verify your password.")
            }
        } else {
            self.showPasswordPrompt = false
        }
    }

    public func removeActiveCertificate() {
        credentialService.deletePasswordFromKeychain()
        try? FileManager.default.removeItem(at: credentialService.savedP12URL)
        UserDefaults.standard.removeObject(forKey: "saved_p12_path")
        self.certificate = nil
        self.p12Password = ""
        self.showPasswordPrompt = false
        appendLog(LogMessage(level: .info, message: "Active certificate removed."))
    }

    public func importProfile(from url: URL) {
        do {
            let prof = try credentialService.importAndSaveProfile(from: url)
            self.profile = prof
            appendLog(LogMessage(level: .success, message: "Provisioning profile imported: \(prof.name)"))
        } catch {
            showError(error.localizedDescription)
        }
    }

    public func clearSavedCredentials() {
        credentialService.deletePasswordFromKeychain()
        UserDefaults.standard.removeObject(forKey: "saved_p12_path")
        UserDefaults.standard.removeObject(forKey: "saved_profile_path")
        certificate = nil
        profile = nil
        p12Password = ""
        showPasswordPrompt = false
        appendLog(LogMessage(level: .info, message: "Cleared saved credentials and certificates."))
    }

    // MARK: - Apple Developer Auto-Provisioning

    public func saveAscCredentials() {
        UserDefaults.standard.set(ascCredentials.keyId, forKey: "asc_key_id")
        UserDefaults.standard.set(ascCredentials.issuerId, forKey: "asc_issuer_id")
        UserDefaults.standard.set(ascCredentials.teamId, forKey: "asc_team_id")
        UserDefaults.standard.set(ascCredentials.teamName, forKey: "asc_team_name")
        if !ascCredentials.privateKeyPem.isEmpty {
            try? credentialService.savePasswordToKeychain(ascCredentials.privateKeyPem, account: "asc_private_key_p8")
        }
    }

    public func loadAscCredentials() {
        let keyId = UserDefaults.standard.string(forKey: "asc_key_id") ?? ""
        let issuerId = UserDefaults.standard.string(forKey: "asc_issuer_id") ?? ""
        let teamId = UserDefaults.standard.string(forKey: "asc_team_id")
        let teamName = UserDefaults.standard.string(forKey: "asc_team_name")
        let privateKey = credentialService.loadPasswordFromKeychain(account: "asc_private_key_p8") ?? ""

        self.ascCredentials = AppStoreConnectCredentials(
            keyId: keyId,
            issuerId: issuerId,
            privateKeyPem: privateKey,
            teamId: teamId,
            teamName: teamName
        )

        if let tId = teamId, !tId.isEmpty {
            self.availableTeams = [
                DeveloperTeam(id: tId, name: teamName ?? "Apple Developer Team")
            ]
            self.selectedTeam = self.availableTeams.first
        }
    }

    public func fetchAppleDeveloperTeams() {
        guard ascCredentials.isValid else {
            showError("Please provide Key ID, Issuer ID and Private Key (.p8).")
            return
        }

        autoProvisioningStep = .fetchingTeams
        appendLog(LogMessage(level: .info, message: "Validating Apple Developer credentials and querying teams..."))

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let teams = try await self.appleDeveloperService.fetchTeams(credentials: self.ascCredentials)
                self.availableTeams = teams
                self.selectedTeam = teams.first
                self.autoProvisioningStep = .idle
                self.saveAscCredentials()
                self.appendLog(LogMessage(level: .success, message: "Connected to Apple Developer Team: \(teams.first?.displayTitle ?? "Unknown")"))
            } catch {
                self.autoProvisioningStep = .failed(error: error.localizedDescription)
                self.showError("Apple Account connection failed: \(error.localizedDescription)")
                self.appendLog(LogMessage(level: .error, message: "Apple Account error: \(error.localizedDescription)"))
            }
        }
    }

    public func startAutoProvisioning() {
        guard ascCredentials.isValid else {
            showError("App Store Connect API credentials (Key ID, Issuer ID, Private Key) are required.")
            return
        }

        appendLog(LogMessage(level: .info, message: "⚡ Starting 1-Click Apple Auto-Provisioning..."))

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let (cert, prof) = try await self.appleDeveloperService.autoProvision(
                    credentials: self.ascCredentials,
                    targetDevice: self.selectedDevice,
                    onStep: { [weak self] step in
                        Task { @MainActor in
                            self?.autoProvisioningStep = step
                        }
                    },
                    onLog: { [weak self] log in
                        Task { @MainActor in
                            self?.appendLog(log)
                        }
                    }
                )

                self.certificate = cert
                self.profile = prof
                if let pwd = self.credentialService.loadPasswordFromKeychain() {
                    self.p12Password = pwd
                }
                self.saveAscCredentials()
                self.showSettingsSheet = false
                self.appendLog(LogMessage(level: .success, message: "✨ Auto-Provisioning Successful! App is ready to sign."))
            } catch {
                self.autoProvisioningStep = .failed(error: error.localizedDescription)
                self.showError("Auto-provisioning failed: \(error.localizedDescription)")
                self.appendLog(LogMessage(level: .error, message: "Auto-provisioning failed: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Direct Apple ID & 2FA Flow

    public func signInWithAppleID() {
        guard !appleIDEmail.trimmingCharacters(in: .whitespaces).isEmpty,
              !appleIDPassword.isEmpty else {
            showSettingsError("Please enter your Apple ID email and password.")
            return
        }

        settingsInlineErrorMessage = nil
        isAppleIDSigningIn = true
        appendLog(LogMessage(level: .info, message: "Authenticating '\(appleIDEmail)' with Apple ID servers..."))

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let result = try await self.appleAuthService.signIn(
                    appleId: self.appleIDEmail,
                    password: self.appleIDPassword
                )

                self.isAppleIDSigningIn = false
                switch result {
                case .success(let session, let teams):
                    self.currentDeveloperSession = session
                    self.availableTeams = teams
                    self.selectedTeam = teams.first
                    self.isAwaiting2FA = false
                    self.settingsInlineErrorMessage = nil
                    self.saveAppleDeveloperSession(session)
                    self.appendLog(LogMessage(level: .success, message: "Logged in as \(session.userFullName) (\(teams.count) teams found)."))

                case .requires2FA(let context):
                    self.twoFactorContext = context
                    self.isAwaiting2FA = true
                    self.twoFactorCode = ""
                    self.settingsInlineErrorMessage = nil
                    self.appendLog(LogMessage(level: .warning, message: "Two-Factor Authentication required. Check your Apple devices for the 6-digit code."))

                case .failed(let message):
                    self.showSettingsError(message)
                    self.appendLog(LogMessage(level: .error, message: "Sign in failed: \(message)"))
                }
            } catch {
                self.isAppleIDSigningIn = false
                self.showSettingsError(error.localizedDescription)
                self.appendLog(LogMessage(level: .error, message: "Apple ID Error: \(error.localizedDescription)"))
            }
        }
    }

    public func handleWebLoginSuccess(cookies: [HTTPCookie], preloadedTeams: [DeveloperTeam] = []) {
        settingsInlineErrorMessage = nil
        isAppleIDSigningIn = true
        appendLog(LogMessage(level: .info, message: "Processing Apple WebKit login session..."))

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let (session, teams) = try await self.appleAuthService.handleWebCookies(cookies: cookies, preloadedTeams: preloadedTeams)
                self.isAppleIDSigningIn = false
                self.appleIDEmail = session.appleId
                self.currentDeveloperSession = session
                if !teams.isEmpty {
                    self.availableTeams = teams
                    self.selectedTeam = teams.first
                } else if self.selectedTeam == nil, let first = self.availableTeams.first {
                    self.selectedTeam = first
                }
                self.settingsInlineErrorMessage = nil
                self.saveAppleDeveloperSession(session)

                if self.availableTeams.isEmpty {
                    self.appendLog(LogMessage(level: .warning, message: "Logged in as \(session.userFullName), but no developer teams were found. Try clicking 'Refresh Teams'."))
                } else {
                    let teamTitles = self.availableTeams.map { $0.displayTitle }.joined(separator: ", ")
                    self.appendLog(LogMessage(level: .success, message: "Logged in via Apple WebKit as \(session.userFullName) (\(self.availableTeams.count) team(s) active: \(teamTitles))."))
                }
            } catch {
                self.isAppleIDSigningIn = false
                self.showSettingsError("Failed to extract Apple Developer session: \(error.localizedDescription)")
                self.appendLog(LogMessage(level: .error, message: "Apple Session Error: \(error.localizedDescription)"))
            }
        }
    }

    public func submitTwoFactorCode() {
        guard let context = twoFactorContext else { return }
        let code = twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count >= 6 else {
            showSettingsError("Please enter the complete 6-digit verification code.")
            return
        }

        settingsInlineErrorMessage = nil
        isAppleIDSigningIn = true
        appendLog(LogMessage(level: .info, message: "Submitting 2FA verification code to Apple..."))

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let (session, teams) = try await self.appleAuthService.verify2FA(
                    code: code,
                    context: context
                )

                self.isAppleIDSigningIn = false
                self.isAwaiting2FA = false
                self.twoFactorContext = nil
                self.twoFactorCode = ""
                self.currentDeveloperSession = session
                self.availableTeams = teams
                self.selectedTeam = teams.first
                self.settingsInlineErrorMessage = nil
                self.saveAppleDeveloperSession(session)
                self.appendLog(LogMessage(level: .success, message: "2FA Verified! Welcome, \(session.userFullName)."))
            } catch {
                self.isAppleIDSigningIn = false
                self.showSettingsError(error.localizedDescription)
                self.appendLog(LogMessage(level: .error, message: "2FA Verification failed: \(error.localizedDescription)"))
            }
        }
    }

    public func cancelTwoFactor() {
        isAwaiting2FA = false
        twoFactorContext = nil
        twoFactorCode = ""
        isAppleIDSigningIn = false
    }

    public func signOutAppleID() {
        currentDeveloperSession = nil
        appleIDPassword = ""
        availableTeams.removeAll()
        selectedTeam = nil
        credentialService.deletePasswordFromKeychain(account: "apple_developer_session")
        UserDefaults.standard.removeObject(forKey: "apple_id_email")
        UserDefaults.standard.removeObject(forKey: "saved_developer_teams")
        appendLog(LogMessage(level: .info, message: "Signed out of Apple ID."))
    }

    public func startAutoProvisioningWithAppleID() {
        guard let session = currentDeveloperSession else {
            showSettingsError("Please sign in with your Apple ID first.")
            return
        }
        guard let team = selectedTeam else {
            showSettingsError("Please select an Apple Developer Team.")
            return
        }

        settingsInlineErrorMessage = nil
        appendLog(LogMessage(level: .info, message: "⚡ Starting 1-Click Apple ID Auto-Provisioning for \(team.name)..."))

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let (cert, prof) = try await self.appleAuthService.autoProvisionWithSession(
                    session: session,
                    team: team,
                    targetDevice: self.selectedDevice,
                    autoRevokeIfLimitReached: self.autoRevokeOldCertsOnLimit,
                    onStep: { [weak self] step in
                        Task { @MainActor in
                            self?.autoProvisioningStep = step
                        }
                    },
                    onLog: { [weak self] log in
                        Task { @MainActor in
                            self?.appendLog(log)
                        }
                    }
                )

                self.certificate = cert
                self.profile = prof
                if let pwd = self.credentialService.loadPasswordFromKeychain() {
                    self.p12Password = pwd
                }
                self.showSettingsSheet = false
                self.appendLog(LogMessage(level: .success, message: "✨ Auto-Provisioning Successful! App is ready to sign."))
            } catch {
                self.autoProvisioningStep = .failed(error: error.localizedDescription)
                self.showSettingsError("Auto-provisioning failed: \(error.localizedDescription)")
                self.appendLog(LogMessage(level: .error, message: "Auto-provisioning failed: \(error.localizedDescription)"))
            }
        }
    }

    public func refreshAppleDeveloperTeams() {
        guard let session = currentDeveloperSession else { return }
        appendLog(LogMessage(level: .info, message: "Refreshing Apple Developer teams..."))

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let (urlSession, cookies) = self.appleAuthService.makeSession(from: session)
                let teams = try await self.appleAuthService.fetchTeams(
                    session: urlSession,
                    cookies: cookies,
                    onLog: { [weak self] log in
                        Task { @MainActor in self?.appendLog(log) }
                    }
                )
                if !teams.isEmpty {
                    self.availableTeams = teams
                    if self.selectedTeam == nil || !teams.contains(where: { $0.id == self.selectedTeam?.id }) {
                        self.selectedTeam = teams.first
                    }
                    self.saveAppleDeveloperSession(session)
                    let teamTitles = teams.map { $0.displayTitle }.joined(separator: ", ")
                    self.appendLog(LogMessage(level: .success, message: "Discovered \(teams.count) developer team(s): \(teamTitles)"))
                } else {
                    self.appendLog(LogMessage(level: .warning, message: "No developer teams returned by Apple servers. Preserving cached teams."))
                }
            } catch {
                self.appendLog(LogMessage(level: .error, message: "Failed to refresh teams: \(error.localizedDescription)"))
            }
        }
    }

    private func saveAppleDeveloperSession(_ session: AppleDeveloperSession) {
        UserDefaults.standard.set(session.appleId, forKey: "apple_id_email")
        if let data = try? JSONEncoder().encode(session),
           let str = String(data: data, encoding: .utf8) {
            try? credentialService.savePasswordToKeychain(str, account: "apple_developer_session")
        }
        if !availableTeams.isEmpty, let teamsData = try? JSONEncoder().encode(availableTeams) {
            UserDefaults.standard.set(teamsData, forKey: "saved_developer_teams")
        }
    }

    public func loadSavedAppleIDSession() {
        self.appleIDEmail = UserDefaults.standard.string(forKey: "apple_id_email") ?? ""
        if let jsonStr = credentialService.loadPasswordFromKeychain(account: "apple_developer_session"),
           let data = jsonStr.data(using: .utf8),
           let session = try? JSONDecoder().decode(AppleDeveloperSession.self, from: data) {
            self.currentDeveloperSession = session

            // Load saved teams from cache
            if let teamsData = UserDefaults.standard.data(forKey: "saved_developer_teams"),
               let savedTeams = try? JSONDecoder().decode([DeveloperTeam].self, from: teamsData),
               !savedTeams.isEmpty {
                self.availableTeams = savedTeams
                if let tId = session.selectedTeamId, let match = savedTeams.first(where: { $0.id == tId }) {
                    self.selectedTeam = match
                } else {
                    self.selectedTeam = savedTeams.first
                }
            } else if let tId = session.selectedTeamId {
                self.availableTeams = [
                    DeveloperTeam(id: tId, name: session.selectedTeamName ?? "Apple Developer Team")
                ]
                self.selectedTeam = self.availableTeams.first
            }
        }
    }

    // MARK: - IPA Selection

    public func setIPA(url: URL) {
        self.selectedIPA = url
        self.config.ipaURL = url
        self.isInspectingIPA = true
        appendLog(LogMessage(level: .info, message: "Selected IPA: \(url.lastPathComponent)"))

        Task {
            let meta = await ipaManager.inspectIPA(at: url)
            self.ipaMetadata = meta
            self.isInspectingIPA = false

            if let bid = meta.bundleIdentifier, self.config.customBundleId.isEmpty {
                // If profile is not wildcard and specifies an explicit bundle ID, suggest or preserve
                if let prof = self.profile, !prof.isWildcard, !prof.applicationIdentifier.isEmpty {
                    let profBundle = prof.applicationIdentifier.replacingOccurrences(of: "\(prof.teamId).", with: "")
                    if profBundle != bid {
                        self.config.customBundleId = profBundle
                    }
                }
            }

            if let name = meta.displayName, self.config.customDisplayName.isEmpty {
                self.config.customDisplayName = name
            }

            self.appendLog(LogMessage(level: .info, message: "IPA metadata: \(meta.displayName ?? meta.fileName) | \(meta.bundleIdentifier ?? "No Bundle ID") | \(meta.formattedSize)"))
        }
    }

    public func clearIPA() {
        self.selectedIPA = nil
        self.ipaMetadata = nil
        self.config.ipaURL = nil
        self.config.customBundleId = ""
        self.config.customDisplayName = ""
        self.lastSignedIPAURL = nil
        self.pipelineStep = .idle
    }

    public func addDylib(url: URL) {
        guard !config.injectedDylibs.contains(url) else { return }
        config.injectedDylibs.append(url)
        appendLog(LogMessage(level: .info, message: "Added tweak dylib for injection: \(url.lastPathComponent)"))
    }

    public func removeDylib(at offsets: IndexSet) {
        for idx in offsets {
            let removed = config.injectedDylibs[idx]
            appendLog(LogMessage(level: .verbose, message: "Removed tweak dylib: \(removed.lastPathComponent)"))
        }
        config.injectedDylibs.remove(atOffsets: offsets)
    }

    // MARK: - Signing Pipeline

    public var canStartSigning: Bool {
        guard selectedIPA != nil,
              certificate != nil,
              profile != nil,
              !pipelineStep.isBusy else {
            return false
        }
        return true
    }

    public func startSigningOnly() {
        guard canStartSigning else { return }
        if p12Password.isEmpty {
            promptForCertificatePassword(message: "Please enter the password for your certificate to start signing:")
            return
        }
        executePipeline(shouldInstall: false)
    }

    public func startSignAndInstall() {
        guard canStartSigning else { return }
        if p12Password.isEmpty {
            promptForCertificatePassword(message: "Please enter the password for your certificate to sign and install:")
            return
        }
        guard let device = selectedDevice else {
            showError("Please select a target iOS device to install the app.")
            return
        }

        if !device.isAvailable {
            appendLog(LogMessage(level: .warning, message: "Selected device appears disconnected or unavailable. Proceeding anyway..."))
        }

        executePipeline(shouldInstall: true)
    }

    public func cancelPipeline() {
        Task {
            await signerService.cancel()
            await installerService.cancel()
            self.pipelineStep = .failed(error: "Operation cancelled by user.")
            self.appendLog(LogMessage(level: .warning, message: "User cancelled the ongoing operation."))
        }
    }

    private func executePipeline(shouldInstall: Bool) {
        guard let ipa = selectedIPA,
              let cert = certificate,
              let prof = profile,
              let p12Path = cert.p12Path ?? UserDefaults.standard.string(forKey: "saved_p12_path") ?? credentialService.savedP12URL.path as String?,
              let profilePath = prof.profilePath ?? UserDefaults.standard.string(forKey: "saved_profile_path") ?? credentialService.savedProfileURL.path as String? else {
            showError("Missing certificate or provisioning profile configuration.")
            return
        }

        pipelineStep = .preparing
        appendLog(LogMessage(level: .info, message: "🚀 Pipeline triggered: \(shouldInstall ? "Sign & Install" : "Sign Only")"))

        // Create output path in Downloads/Signet or next to original
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let baseName = ipa.deletingPathExtension().lastPathComponent
        let outputFileName = "\(baseName)_signed.ipa"
        let outputIPA = downloads.appendingPathComponent("Signet/\(outputFileName)")

        Task { [weak self] in
            guard let self = self else { return }
            do {
                // 1. Sign
                self.pipelineStep = .signing(progress: 0.1, detail: "Initializing zsign...")
                let signedResultURL = try await self.signerService.sign(
                    inputIPA: ipa,
                    outputIPA: outputIPA,
                    p12Path: p12Path,
                    p12Password: self.p12Password,
                    profilePath: profilePath,
                    config: self.config,
                    onProgress: { [weak self] progress, detail in
                        Task { @MainActor in
                            self?.pipelineStep = .signing(progress: progress, detail: detail)
                        }
                    },
                    onLog: { [weak self] log in
                        Task { @MainActor in
                            self?.appendLog(log)
                        }
                    }
                )

                self.lastSignedIPAURL = signedResultURL

                // 2. Install if requested
                if shouldInstall, let device = self.selectedDevice {
                    self.pipelineStep = .installing(progress: 0.0, detail: "Transferring to \(device.displayName)...")
                    try await self.installerService.install(
                        ipaURL: signedResultURL,
                        device: device,
                        onProgress: { [weak self] progress, detail in
                            Task { @MainActor in
                                self?.pipelineStep = .installing(progress: progress, detail: detail)
                            }
                        },
                        onLog: { [weak self] log in
                            Task { @MainActor in
                                self?.appendLog(log)
                            }
                        }
                    )

                    self.pipelineStep = .completed(outputURL: signedResultURL)
                    self.appendLog(LogMessage(level: .success, message: "🎉 All done! App installed on \(device.displayName)."))
                } else {
                    self.pipelineStep = .completed(outputURL: signedResultURL)
                    self.appendLog(LogMessage(level: .success, message: "🎉 Signing complete! Output saved to: \(signedResultURL.path)"))
                }
            } catch {
                self.pipelineStep = .failed(error: error.localizedDescription)
                self.appendLog(LogMessage(level: .error, message: "Pipeline failed: \(error.localizedDescription)"))

                if let signingError = error as? SigningError, case .invalidCertificatePassword = signingError {
                    self.credentialService.deletePasswordFromKeychain()
                    self.p12Password = ""
                    self.promptForCertificatePassword(message: "The certificate password was incorrect. Please re-enter the correct password for '\(self.certificate?.commonName ?? "Certificate")':")
                } else {
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Logging & Utilities

    public func appendLog(_ message: LogMessage) {
        logs.append(message)
    }

    public func clearLogs() {
        logs.removeAll()
    }

    public func copyLogsToClipboard() {
        let text = logs.map { "[\($0.formattedTime)] [\($0.level.prefix)] \($0.message)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appendLog(LogMessage(level: .info, message: "Logs copied to clipboard."))
    }

    public func showError(_ message: String) {
        self.alertErrorMessage = message
        self.showErrorAlert = true
        self.settingsInlineErrorMessage = message
    }

    public func showSettingsError(_ message: String) {
        self.settingsInlineErrorMessage = message
    }

    public func clearSettingsError() {
        self.settingsInlineErrorMessage = nil
    }

    // MARK: - Portal Management Operations

    public func loadPortalData() {
        guard let session = currentDeveloperSession else {
            appendLog(LogMessage(level: .info, message: "[Portal] No active Apple Developer session. Sign in to view portal resources."))
            return
        }
        if selectedTeam == nil, let first = availableTeams.first {
            selectedTeam = first
        }
        guard let team = selectedTeam else {
            appendLog(LogMessage(level: .info, message: "[Portal] No developer team selected. Please select a team."))
            return
        }
        appendLog(LogMessage(level: .info, message: "[Portal] Loading portal resources for team: \(team.name) (\(team.id))..."))
        isPortalLoading = true

        Task { [weak self] in
            guard let self = self else { return }
            let (urlSession, cookies) = self.appleAuthService.makeSession(from: session)
            let updatedCookies = await self.appleAuthService.selectPortalTeam(
                urlSession: urlSession,
                teamId: team.id,
                cookies: cookies,
                onLog: { [weak self] log in
                    Task { @MainActor in self?.appendLog(log) }
                }
            )

            if updatedCookies.count != cookies.count {
                var updatedSession = session
                updatedSession.cookiesData = AppleAuthService.encodeCookies(updatedCookies)
                self.currentDeveloperSession = updatedSession
                self.saveAppleDeveloperSession(updatedSession)
            }

            self.refreshPortalDevices()
            self.refreshPortalCertificates()
            self.refreshPortalAppIds()
            self.refreshKeychainIdentities()
        }
    }

    public func refreshPortalDevices() {
        guard let session = currentDeveloperSession, let team = selectedTeam else { return }
        isPortalLoading = true
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let devices = try await self.appleAuthService.fetchPortalDevices(
                    session: session,
                    team: team,
                    onLog: { [weak self] log in
                        Task { @MainActor in self?.appendLog(log) }
                    }
                )
                self.portalDevices = devices
                self.isPortalLoading = false
                self.portalStatusMessage = "Loaded \(devices.count) registered device(s)."
            } catch {
                self.isPortalLoading = false
                self.showSettingsError("Failed to fetch devices: \(error.localizedDescription)")
                self.appendLog(LogMessage(level: .error, message: "[Portal] Fetch devices error: \(error.localizedDescription)"))
            }
        }
    }

    public func deletePortalDevice(id: String) {
        guard let session = currentDeveloperSession, let team = selectedTeam else { return }
        isPortalLoading = true
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let success = try await self.appleAuthService.deletePortalDevice(
                    session: session,
                    team: team,
                    deviceId: id,
                    onLog: { [weak self] log in
                        Task { @MainActor in self?.appendLog(log) }
                    }
                )
                if success {
                    self.portalDevices.removeAll { $0.id == id }
                    self.portalStatusMessage = "Device removed successfully."
                } else {
                    self.showSettingsError("Could not remove device. Apple Developer Portal may restrict removing active devices.")
                }
                self.isPortalLoading = false
            } catch {
                self.isPortalLoading = false
                self.showSettingsError("Failed to delete device: \(error.localizedDescription)")
                self.appendLog(LogMessage(level: .error, message: "[Portal] Delete device error: \(error.localizedDescription)"))
            }
        }
    }

    public func registerPortalDevice(name: String, udid: String, deviceClass: String = "iphone") {
        guard let session = currentDeveloperSession, let team = selectedTeam else { return }
        isPortalLoading = true
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let dev = try await self.appleAuthService.registerPortalDeviceManual(
                    session: session,
                    team: team,
                    name: name,
                    udid: udid,
                    deviceClass: deviceClass,
                    onLog: { [weak self] log in
                        Task { @MainActor in self?.appendLog(log) }
                    }
                )
                self.portalDevices.append(dev)
                self.portalStatusMessage = "Registered device: \(name)"
                self.isPortalLoading = false
            } catch {
                self.isPortalLoading = false
                self.showSettingsError("Failed to register device: \(error.localizedDescription)")
                self.appendLog(LogMessage(level: .error, message: "[Portal] Register device error: \(error.localizedDescription)"))
            }
        }
    }

    public func refreshPortalCertificates() {
        guard let session = currentDeveloperSession, let team = selectedTeam else { return }
        isPortalLoading = true
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let certs = try await self.appleAuthService.fetchPortalCertificates(
                    session: session,
                    team: team,
                    onLog: { [weak self] log in
                        Task { @MainActor in self?.appendLog(log) }
                    }
                )
                self.portalCertificates = certs
                self.isPortalLoading = false
                self.portalStatusMessage = "Loaded \(certs.count) certificate(s)."
            } catch {
                self.isPortalLoading = false
                self.showSettingsError("Failed to fetch certificates: \(error.localizedDescription)")
                self.appendLog(LogMessage(level: .error, message: "[Portal] Fetch certificates error: \(error.localizedDescription)"))
            }
        }
    }

    public func revokePortalCertificate(id: String, type: String) {
        guard let session = currentDeveloperSession, let team = selectedTeam else { return }
        isPortalLoading = true
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let success = try await self.appleAuthService.revokePortalCertificate(
                    session: session,
                    team: team,
                    certificateId: id,
                    type: type,
                    onLog: { [weak self] log in
                        Task { @MainActor in self?.appendLog(log) }
                    }
                )
                if success {
                    self.portalCertificates.removeAll { $0.id == id }
                    self.portalStatusMessage = "Certificate revoked successfully."
                } else {
                    self.showSettingsError("Could not revoke certificate.")
                }
                self.isPortalLoading = false
            } catch {
                self.isPortalLoading = false
                self.showSettingsError("Failed to revoke certificate: \(error.localizedDescription)")
                self.appendLog(LogMessage(level: .error, message: "[Portal] Revoke certificate error: \(error.localizedDescription)"))
            }
        }
    }

    public func downloadPortalCertificate(id: String, type: String, destinationURL: URL) {
        guard let session = currentDeveloperSession, let team = selectedTeam else { return }
        isPortalLoading = true
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let data = try await self.appleAuthService.downloadPortalCertificate(
                    session: session,
                    team: team,
                    certificateId: id,
                    type: type,
                    onLog: { [weak self] log in
                        Task { @MainActor in self?.appendLog(log) }
                    }
                )
                try data.write(to: destinationURL)
                self.portalStatusMessage = "Certificate downloaded to: \(destinationURL.lastPathComponent)"
                self.isPortalLoading = false
            } catch {
                self.isPortalLoading = false
                self.showSettingsError("Failed to download certificate: \(error.localizedDescription)")
                self.appendLog(LogMessage(level: .error, message: "[Portal] Download certificate error: \(error.localizedDescription)"))
            }
        }
    }

    public func refreshPortalAppIds() {
        guard let session = currentDeveloperSession, let team = selectedTeam else { return }
        isPortalLoading = true
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let appIds = try await self.appleAuthService.fetchPortalAppIds(
                    session: session,
                    team: team,
                    onLog: { [weak self] log in
                        Task { @MainActor in self?.appendLog(log) }
                    }
                )
                self.portalAppIds = appIds
                self.isPortalLoading = false
                self.portalStatusMessage = "Loaded \(appIds.count) App ID(s)."
            } catch {
                self.isPortalLoading = false
                self.showSettingsError("Failed to fetch App IDs: \(error.localizedDescription)")
                self.appendLog(LogMessage(level: .error, message: "[Portal] Fetch App IDs error: \(error.localizedDescription)"))
            }
        }
    }

    public func deletePortalAppId(id: String) {
        guard let session = currentDeveloperSession, let team = selectedTeam else { return }
        isPortalLoading = true
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let success = try await self.appleAuthService.deletePortalAppId(
                    session: session,
                    team: team,
                    appIdId: id,
                    onLog: { [weak self] log in
                        Task { @MainActor in self?.appendLog(log) }
                    }
                )
                if success {
                    self.portalAppIds.removeAll { $0.id == id }
                    self.portalStatusMessage = "App ID deleted successfully."
                } else {
                    self.showSettingsError("Could not delete App ID.")
                }
                self.isPortalLoading = false
            } catch {
                self.isPortalLoading = false
                self.showSettingsError("Failed to delete App ID: \(error.localizedDescription)")
                self.appendLog(LogMessage(level: .error, message: "[Portal] Delete App ID error: \(error.localizedDescription)"))
            }
        }
    }

    public func createPortalAppId(name: String, identifier: String) {
        guard let session = currentDeveloperSession, let team = selectedTeam else { return }
        isPortalLoading = true
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let appId = try await self.appleAuthService.createPortalAppId(
                    session: session,
                    team: team,
                    name: name,
                    identifier: identifier,
                    onLog: { [weak self] log in
                        Task { @MainActor in self?.appendLog(log) }
                    }
                )
                self.portalAppIds.append(appId)
                self.portalStatusMessage = "Created App ID '\(identifier)'"
                self.isPortalLoading = false
            } catch {
                self.isPortalLoading = false
                self.showSettingsError("Failed to create App ID: \(error.localizedDescription)")
                self.appendLog(LogMessage(level: .error, message: "[Portal] Create App ID error: \(error.localizedDescription)"))
            }
        }
    }

    public func refreshKeychainIdentities() {
        self.keychainIdentities = appleAuthService.findLocalKeychainIdentities()
    }

    public func useLocalKeychainIdentity(_ identity: KeychainIdentity) {
        appendLog(LogMessage(level: .info, message: "Exporting and applying local Keychain identity '\(identity.name)'..."))
        isPortalLoading = true

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let password = "SignetLocalPass\(Int.random(in: 100000...999999))"
                let p12Data = try self.appleAuthService.exportKeychainIdentity(identityName: identity.name, password: password)

                let p12Path = self.credentialService.savedP12URL
                try p12Data.write(to: p12Path)
                let certInfo = try self.credentialService.importAndSaveP12(from: p12Path, password: password)
                self.certificate = certInfo
                self.p12Password = password

                self.appendLog(LogMessage(level: .success, message: "Active certificate set from Keychain: \(certInfo.teamName) (expires in \(certInfo.daysRemaining) days)"))
                self.portalStatusMessage = "Successfully activated local certificate: \(certInfo.teamName)"

                // If an Apple Developer session is active, try to fetch or create a wildcard profile to match
                if let session = self.currentDeveloperSession, let team = self.selectedTeam {
                    self.appendLog(LogMessage(level: .info, message: "Resolving matching Wildcard Provisioning Profile for team '\(team.name)'..."))
                    if let profData = await self.appleAuthService.fetchTeamWildcardProfile(
                        session: session,
                        team: team,
                        onLog: { [weak self] log in
                            Task { @MainActor in self?.appendLog(log) }
                        }
                    ) {
                        let profPath = self.credentialService.savedProfileURL
                        try profData.write(to: profPath)
                        let profInfo = try self.credentialService.importAndSaveProfile(from: profPath)
                        self.profile = profInfo
                        self.appendLog(LogMessage(level: .success, message: "Configured matching Wildcard Profile: \(profInfo.name)"))
                    }
                }

                self.isPortalLoading = false
            } catch {
                self.isPortalLoading = false
                self.appendLog(LogMessage(level: .error, message: "Failed to apply local identity: \(error.localizedDescription)"))
                self.portalStatusMessage = "Failed to export certificate: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - CLI Engine Homebrew Installation

    public func installCliPackage(packageName: String, onFinished: @escaping () -> Void) {
        guard !isInstallingEngine else { return }
        isInstallingEngine = true
        engineInstallLog = "Starting installation of \(packageName) via Homebrew...\n"
        appendLog(LogMessage(level: .info, message: "Installing CLI engine '\(packageName)' via Homebrew..."))

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let success = try await self.binaryManager.installPackage(packageName) { [weak self] line in
                    Task { @MainActor in
                        self?.engineInstallLog.append(line)
                    }
                }
                self.isInstallingEngine = false
                if success {
                    self.appendLog(LogMessage(level: .success, message: "Successfully installed \(packageName)!"))
                    onFinished()
                } else {
                    self.appendLog(LogMessage(level: .error, message: "Homebrew failed to install \(packageName)."))
                }
            } catch {
                self.isInstallingEngine = false
                self.engineInstallLog.append("\nError: \(error.localizedDescription)\n")
                self.appendLog(LogMessage(level: .error, message: "Installation error: \(error.localizedDescription)"))
            }
        }
    }
}
