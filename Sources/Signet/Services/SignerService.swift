import Foundation

public enum SigningError: LocalizedError {
    case zsignBinaryNotFound
    case inputFileNotFound(String)
    case outputCreationFailed
    case invalidCertificatePassword(String)
    case signingFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .zsignBinaryNotFound:
            return "Signing engine (zsign) was not found. Please ensure it is bundled or install it via Homebrew."
        case .inputFileNotFound(let path):
            return "Input IPA file not found at: \(path)"
        case .outputCreationFailed:
            return "Could not create destination output directory."
        case .invalidCertificatePassword(let msg):
            return "Invalid certificate password: \(msg)"
        case .signingFailed(let reason):
            return "Signing failed: \(reason)"
        case .cancelled:
            return "Signing was cancelled by user."
        }
    }
}

public final class SignerService: @unchecked Sendable {
    public static let shared = SignerService()

    private let runner = ProcessRunner()
    private let binaryManager = BinaryManager.shared

    private init() {}

    public func cancel() async {
        await runner.terminateCurrent()
    }

    /// Executes IPA signing with the provided certificate and configuration.
    public func sign(
        inputIPA: URL,
        outputIPA: URL,
        p12Path: String,
        p12Password: String,
        profilePath: String,
        config: SigningConfiguration,
        onProgress: (@Sendable (Double, String) -> Void)? = nil,
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> URL {
        guard let zsignPath = binaryManager.resolveZsign() else {
            throw SigningError.zsignBinaryNotFound
        }

        guard FileManager.default.fileExists(atPath: inputIPA.path) else {
            throw SigningError.inputFileNotFound(inputIPA.path)
        }

        // Ensure output directory exists
        let outputDir = outputIPA.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        onLog?(LogMessage(level: .info, message: "Starting signing pipeline with zsign..."))
        onLog?(LogMessage(level: .info, message: "Engine: \(zsignPath)"))
        onLog?(LogMessage(level: .info, message: "Input: \(inputIPA.lastPathComponent)"))
        onLog?(LogMessage(level: .info, message: "Output: \(outputIPA.lastPathComponent)"))

        onProgress?(0.1, "Preparing signing arguments...")

        var arguments: [String] = [
            "-k", p12Path,
            "-p", p12Password,
            "-m", profilePath,
            "-o", outputIPA.path
        ]

        if !config.customBundleId.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments.append(contentsOf: ["-b", config.customBundleId.trimmingCharacters(in: .whitespaces)])
            onLog?(LogMessage(level: .info, message: "Override Bundle ID: \(config.customBundleId)"))
        }

        if !config.customDisplayName.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments.append(contentsOf: ["-n", config.customDisplayName.trimmingCharacters(in: .whitespaces)])
            onLog?(LogMessage(level: .info, message: "Override App Name: \(config.customDisplayName)"))
        }

        if !config.customVersion.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments.append(contentsOf: ["-r", config.customVersion.trimmingCharacters(in: .whitespaces)])
            onLog?(LogMessage(level: .info, message: "Override Version: \(config.customVersion)"))
        }

        for dylib in config.injectedDylibs {
            if FileManager.default.fileExists(atPath: dylib.path) {
                arguments.append(contentsOf: ["-l", dylib.path])
                onLog?(LogMessage(level: .info, message: "Injecting tweak / dylib: \(dylib.lastPathComponent)"))
            }
        }

        if config.removeExtensions {
            arguments.append("-E")
            onLog?(LogMessage(level: .verbose, message: "Stripping App Extensions (-E)"))
        }

        if config.enableFileSharing || config.enableDocumentBrowser {
            arguments.append("-S")
            onLog?(LogMessage(level: .verbose, message: "Enabling File Sharing & Document Browser (-S)"))
        }

        if config.removeUISupportedDevices {
            arguments.append("-U")
            onLog?(LogMessage(level: .verbose, message: "Removing UISupportedDevices restriction (-U)"))
        }

        if config.forceResign {
            arguments.append("-f")
        }

        var temporaryEntitlementsURL: URL? = nil
        if let entURL = config.customEntitlementsURL, FileManager.default.fileExists(atPath: entURL.path) {
            arguments.append(contentsOf: ["-e", entURL.path])
            onLog?(LogMessage(level: .info, message: "Applied custom entitlements (-e): \(entURL.lastPathComponent)"))
        } else if let content = config.customEntitlementsContent, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SignetEntitlements", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempEntURL = tempDir.appendingPathComponent("injected_entitlements_\(UUID().uuidString).plist")
            if (try? content.write(to: tempEntURL, atomically: true, encoding: .utf8)) != nil {
                temporaryEntitlementsURL = tempEntURL
                arguments.append(contentsOf: ["-e", tempEntURL.path])
                onLog?(LogMessage(level: .info, message: "Applied custom imported entitlements (-e)"))
            }
        }
        defer {
            if let temp = temporaryEntitlementsURL {
                try? FileManager.default.removeItem(at: temp)
            }
        }

        arguments.append(contentsOf: ["-z", "\(config.compressionLevel)"])
        arguments.append(inputIPA.path)

        onProgress?(0.2, "Executing zsign...")

        let state = SigningSessionState()

        let result = try await runner.run(
            executablePath: zsignPath,
            arguments: arguments
        ) { [weak self] line in
            self?.handleZsignOutputLine(
                line: line,
                state: state,
                onProgress: onProgress,
                onLog: onLog
            )
        }

        if result.isSuccess && FileManager.default.fileExists(atPath: outputIPA.path) {
            onProgress?(1.0, "Signing completed successfully!")
            onLog?(LogMessage(level: .success, message: "IPA successfully signed: \(outputIPA.path)"))
            return outputIPA
        } else {
            let reason = state.lastErrorLine.isEmpty ? (result.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).last ?? "Process exited with code \(result.exitCode)") : state.lastErrorLine
            onLog?(LogMessage(level: .error, message: "Signing failed: \(reason)"))
            let lower = reason.lowercased()
            if lower.contains("password") || lower.contains("pkcs12") || lower.contains("mac verify") || lower.contains("bad decrypt") || lower.contains("cant parse") || lower.contains("can't parse") || lower.contains("unsupported") || lower.contains("load certificate") || lower.contains("digital envelope") {
                throw SigningError.invalidCertificatePassword(reason)
            }
            throw SigningError.signingFailed(reason)
        }
    }

    private final class SigningSessionState: @unchecked Sendable {
        var lastErrorLine: String = ""
        var isSuccess: Bool = false
    }

    private func handleZsignOutputLine(
        line: String,
        state: SigningSessionState,
        onProgress: (@Sendable (Double, String) -> Void)?,
        onLog: (@Sendable (LogMessage) -> Void)?
    ) {
        let level = LogMessage.parseLevel(from: line)
        if level == .error {
            state.lastErrorLine = line
        }

        let lower = line.lowercased()
        if lower.contains("signed ok") || lower.contains("build ok") {
            state.isSuccess = true
            onProgress?(0.95, "Finishing IPA packaging...")
        } else if lower.contains("packing") || lower.contains("compress") {
            onProgress?(0.75, "Packing signed IPA...")
        } else if lower.contains("signing") || lower.contains("sign:") {
            onProgress?(0.50, "Signing Mach-O binaries & frameworks...")
        } else if lower.contains("parsing") || lower.contains("extracting") || lower.contains("unzip") {
            onProgress?(0.30, "Extracting IPA contents...")
        }

        onLog?(LogMessage(level: level, message: line))
    }
}
