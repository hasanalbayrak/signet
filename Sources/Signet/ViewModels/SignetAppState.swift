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

    // MARK: - Dependencies
    private let credentialService = CredentialService.shared
    private let deviceService = DeviceService.shared
    private let signerService = SignerService.shared
    private let installerService = InstallerService.shared
    private let ipaManager = IPAManager.shared
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

        // 2. Discover devices
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

    public func importP12(from url: URL, password: String) {
        do {
            let cert = try credentialService.importAndSaveP12(from: url, password: password)
            self.certificate = cert
            self.p12Password = password
            appendLog(LogMessage(level: .success, message: "Certificate successfully imported: \(cert.commonName)"))
        } catch {
            showError(error.localizedDescription)
        }
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
        appendLog(LogMessage(level: .info, message: "Cleared saved credentials and certificates."))
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
              !p12Password.isEmpty,
              !pipelineStep.isBusy else {
            return false
        }
        return true
    }

    public func startSigningOnly() {
        guard canStartSigning else { return }
        executePipeline(shouldInstall: false)
    }

    public func startSignAndInstall() {
        guard canStartSigning else { return }
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
                self.showError(error.localizedDescription)
                self.appendLog(LogMessage(level: .error, message: "Pipeline failed: \(error.localizedDescription)"))
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
    }
}
