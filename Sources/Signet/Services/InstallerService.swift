import Foundation

public enum DeploymentError: LocalizedError {
    case noDeploymentToolAvailable
    case deviceNotConnected(String)
    case developerModeDisabled
    case deviceLocked
    case trustRequired
    case installationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noDeploymentToolAvailable:
            return "No deployment tool found. Please ensure Xcode Command Line Tools ('xcrun devicectl') or 'ideviceinstaller' is installed."
        case .deviceNotConnected(let id):
            return "Device with UDID \(id) is not connected or reachable."
        case .developerModeDisabled:
            return "Developer Mode is DISABLED on this iOS device. On iOS 16+, go to Settings > Privacy & Security > Developer Mode, turn it ON, and restart your device."
        case .deviceLocked:
            return "Device is locked with a passcode. Please unlock your iOS device and try again."
        case .trustRequired:
            return "Host computer is not trusted. Unlock your device and tap 'Trust' on the trust dialog."
        case .installationFailed(let msg):
            return "Installation failed: \(msg)"
        }
    }
}

public final class InstallerService: @unchecked Sendable {
    public static let shared = InstallerService()

    private let runner = ProcessRunner()
    private let binaryManager = BinaryManager.shared

    private init() {}

    public func cancel() async {
        await runner.terminateCurrent()
    }

    public func install(
        ipaURL: URL,
        device: Device,
        onProgress: (@Sendable (Double, String) -> Void)? = nil,
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws {
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            throw DeploymentError.installationFailed("IPA file not found: \(ipaURL.path)")
        }

        onLog?(LogMessage(level: .info, message: "Deploying '\(ipaURL.lastPathComponent)' to \(device.displayName)..."))

        // Handle native installation on Apple Silicon Mac
        if device.connectionType == .local || device.isAppleSiliconMac {
            onLog?(LogMessage(level: .info, message: "Deploying natively to local Apple Silicon Mac (/Applications)..."))
            try await installToLocalMac(
                ipaURL: ipaURL,
                onProgress: onProgress,
                onLog: onLog
            )
            return
        }

        // Check if devicectl is available
        if let xcrun = binaryManager.resolveDevicectl() {
            onLog?(LogMessage(level: .verbose, message: "Using Apple devicectl (CoreDevice) for deployment..."))
            do {
                try await installWithDevicectl(
                    xcrunPath: xcrun,
                    ipaURL: ipaURL,
                    device: device,
                    onProgress: onProgress,
                    onLog: onLog
                )
                return
            } catch {
                onLog?(LogMessage(level: .warning, message: "devicectl failed: \(error.localizedDescription). Trying libimobiledevice fallback..."))
            }
        }

        // Fallback to ideviceinstaller
        if let installer = binaryManager.resolveIdeviceinstaller() {
            onLog?(LogMessage(level: .verbose, message: "Using ideviceinstaller for deployment..."))
            try await installWithIdeviceinstaller(
                installerPath: installer,
                ipaURL: ipaURL,
                device: device,
                onProgress: onProgress,
                onLog: onLog
            )
            return
        }

        throw DeploymentError.noDeploymentToolAvailable
    }

    // MARK: - xcrun devicectl Backend

    private final class SessionState: @unchecked Sendable {
        var capturedError: String = ""
    }

    private func installWithDevicectl(
        xcrunPath: String,
        ipaURL: URL,
        device: Device,
        onProgress: (@Sendable (Double, String) -> Void)?,
        onLog: (@Sendable (LogMessage) -> Void)?
    ) async throws {
        onProgress?(0.1, "Connecting to device via CoreDevice...")

        let state = SessionState()
        let result = try await runner.run(
            executablePath: xcrunPath,
            arguments: ["devicectl", "device", "install", "app", "--device", device.udid, ipaURL.path]
        ) { line in
            let lower = line.lowercased()
            let level = LogMessage.parseLevel(from: line)
            onLog?(LogMessage(level: level, message: line))

            if lower.contains("developer mode is not enabled") || lower.contains("developermodedisabled") {
                state.capturedError = "Developer Mode is disabled on this device."
            } else if lower.contains("passcode") || lower.contains("device is locked") {
                state.capturedError = "Device is locked with passcode."
            } else if lower.contains("transferring") || lower.contains("uploading") {
                onProgress?(0.4, "Transferring app package to device...")
            } else if lower.contains("installing") {
                onProgress?(0.75, "Installing app on device...")
            } else if lower.contains("complete") || lower.contains("installed") {
                onProgress?(1.0, "Installation complete!")
            }
        }

        if state.capturedError.contains("Developer Mode") {
            throw DeploymentError.developerModeDisabled
        } else if state.capturedError.contains("passcode") {
            throw DeploymentError.deviceLocked
        }

        if !result.isSuccess {
            let lastLine = result.output.components(separatedBy: .newlines).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Unknown error"
            throw DeploymentError.installationFailed(lastLine)
        }

        onLog?(LogMessage(level: .success, message: "App installed successfully via CoreDevice!"))
    }

    // MARK: - ideviceinstaller Backend

    private func installWithIdeviceinstaller(
        installerPath: String,
        ipaURL: URL,
        device: Device,
        onProgress: (@Sendable (Double, String) -> Void)?,
        onLog: (@Sendable (LogMessage) -> Void)?
    ) async throws {
        onProgress?(0.1, "Connecting via libimobiledevice...")

        let state = SessionState()
        let result = try await runner.run(
            executablePath: installerPath,
            arguments: ["-u", device.udid, "-i", ipaURL.path]
        ) { line in
            let level = LogMessage.parseLevel(from: line)
            onLog?(LogMessage(level: level, message: line))

            let lower = line.lowercased()
            if lower.contains("could not connect") {
                state.capturedError = "Could not connect to device"
            } else if lower.contains("developer mode") {
                state.capturedError = "Developer Mode disabled"
            }

            // Parse percentages like [ 25%] Extracting...
            if let percent = Self.extractPercent(from: line) {
                onProgress?(Double(percent) / 100.0, line)
            }
        }

        if state.capturedError.contains("Developer Mode") {
            throw DeploymentError.developerModeDisabled
        }

        if !result.isSuccess {
            let lastLine = result.output.components(separatedBy: .newlines).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Unknown error"
            throw DeploymentError.installationFailed(lastLine)
        }

        onLog?(LogMessage(level: .success, message: "App installed successfully via ideviceinstaller!"))
    }

    private static func extractPercent(from line: String) -> Int? {
        // Match patterns like [ 40%] or [100%]
        guard let openBracket = line.firstIndex(of: "["),
              let percentIndex = line.firstIndex(of: "%"),
              openBracket < percentIndex else {
            return nil
        }

        let numStr = line[line.index(after: openBracket)..<percentIndex].trimmingCharacters(in: .whitespaces)
        return Int(numStr)
    }

    // MARK: - Local Mac (Apple Silicon) Installation Backend

    private func installToLocalMac(
        ipaURL: URL,
        onProgress: (@Sendable (Double, String) -> Void)?,
        onLog: (@Sendable (LogMessage) -> Void)?
    ) async throws {
        onProgress?(0.15, "Unpacking iOS app bundle for macOS...")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SignetLocalMac_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Extract IPA using ditto (ditto preserves symlinks and permissions natively on macOS)
        let ditto = Process()
        ditto.launchPath = "/usr/bin/ditto"
        ditto.arguments = ["-xk", ipaURL.path, tempDir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw DeploymentError.installationFailed("Failed to unpack IPA bundle for Mac installation.")
        }

        let payloadDir = tempDir.appendingPathComponent("Payload")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: payloadDir.path),
              let appName = items.first(where: { $0.hasSuffix(".app") }) else {
            throw DeploymentError.installationFailed("Could not locate .app bundle inside IPA Payload.")
        }

        let extractedAppURL = payloadDir.appendingPathComponent(appName)
        onProgress?(0.5, "Moving \(appName) to Applications...")

        // Determine destination: /Applications or ~/Applications
        let globalApps = URL(fileURLWithPath: "/Applications")
        let userApps = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first ?? globalApps

        var targetAppsDir = globalApps
        if !FileManager.default.isWritableFile(atPath: targetAppsDir.path) {
            targetAppsDir = userApps
            try? FileManager.default.createDirectory(at: targetAppsDir, withIntermediateDirectories: true)
        }

        let destAppURL = targetAppsDir.appendingPathComponent(appName)
        if FileManager.default.fileExists(atPath: destAppURL.path) {
            onLog?(LogMessage(level: .info, message: "Replacing existing app at \(destAppURL.path)..."))
            try? FileManager.default.removeItem(at: destAppURL)
        }

        var finalAppURL = destAppURL
        do {
            try FileManager.default.moveItem(at: extractedAppURL, to: destAppURL)
        } catch {
            // Fallback to user applications if permission error
            let fallbackURL = userApps.appendingPathComponent(appName)
            if FileManager.default.fileExists(atPath: fallbackURL.path) {
                try? FileManager.default.removeItem(at: fallbackURL)
            }
            try FileManager.default.moveItem(at: extractedAppURL, to: fallbackURL)
            finalAppURL = fallbackURL
        }

        onProgress?(0.8, "Clearing Apple Quarantine attributes...")
        let xattr = Process()
        xattr.launchPath = "/usr/bin/xattr"
        xattr.arguments = ["-cr", finalAppURL.path]
        try? xattr.run()
        xattr.waitUntilExit()

        onProgress?(1.0, "App installed to \(finalAppURL.lastPathComponent)")
        onLog?(LogMessage(level: .success, message: "Installed successfully to: \(finalAppURL.path)"))

        // Launch app on Mac
        let openProc = Process()
        openProc.launchPath = "/usr/bin/open"
        openProc.arguments = [finalAppURL.path]
        try? openProc.run()
        onLog?(LogMessage(level: .success, message: "Launched '\(finalAppURL.deletingPathExtension().lastPathComponent)' on your Mac!"))
    }
}
