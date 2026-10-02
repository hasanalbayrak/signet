import Foundation

public final class BinaryManager: @unchecked Sendable {
    public static let shared = BinaryManager()

    public struct BinaryInfo {
        public let name: String
        public let path: String?
        public let isAvailable: Bool
        public let version: String?
        public let source: String
    }

    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Binary Lookups

    public func resolveZsign() -> String? {
        // 1. User defaults custom override
        if let customPath = UserDefaults.standard.string(forKey: "custom_zsign_path"),
           isExecutable(at: customPath) {
            return customPath
        }

        // 2. Bundled inside Resources (SPM or Xcode App Bundle)
        if let bundleUrl = Bundle.main.url(forResource: "zsign", withExtension: nil) {
            if isExecutable(at: bundleUrl.path) {
                return bundleUrl.path
            }
        }

        // Check relative to executable location (typical SPM or app Contents/Resources/bin)
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let appResourcesBin = execURL.deletingLastPathComponent().appendingPathComponent("Signet_Signet.resources/Resources/bin/zsign").path
        if isExecutable(at: appResourcesBin) {
            return appResourcesBin
        }

        let directResourcesBin = execURL.deletingLastPathComponent().appendingPathComponent("Resources/bin/zsign").path
        if isExecutable(at: directResourcesBin) {
            return directResourcesBin
        }

        // 3. Application Support directory
        let appSupportBin = getAppSupportBinDirectory().appendingPathComponent("zsign").path
        if isExecutable(at: appSupportBin) {
            return appSupportBin
        }

        // 4. Standard Homebrew and system PATH locations
        let commonPaths = [
            "/opt/homebrew/bin/zsign",
            "/usr/local/bin/zsign",
            "/usr/bin/zsign"
        ]

        for path in commonPaths {
            if isExecutable(at: path) {
                return path
            }
        }

        // 5. Try resolving via `which`
        if let whichPath = findInPath(binaryName: "zsign") {
            return whichPath
        }

        return nil
    }

    public func resolveDevicectl() -> String? {
        if isExecutable(at: "/usr/bin/xcrun") {
            return "/usr/bin/xcrun"
        }
        return findInPath(binaryName: "devicectl")
    }

    public func resolveIdeviceinstaller() -> String? {
        if let customPath = UserDefaults.standard.string(forKey: "custom_ideviceinstaller_path"),
           isExecutable(at: customPath) {
            return customPath
        }

        let commonPaths = [
            "/opt/homebrew/bin/ideviceinstaller",
            "/usr/local/bin/ideviceinstaller"
        ]

        for path in commonPaths {
            if isExecutable(at: path) {
                return path
            }
        }

        return findInPath(binaryName: "ideviceinstaller")
    }

    public func resolveIdeviceInfo() -> String? {
        let commonPaths = [
            "/opt/homebrew/bin/ideviceinfo",
            "/usr/local/bin/ideviceinfo"
        ]
        for path in commonPaths {
            if isExecutable(at: path) {
                return path
            }
        }
        return findInPath(binaryName: "ideviceinfo")
    }

    public func resolveIdeviceId() -> String? {
        let commonPaths = [
            "/opt/homebrew/bin/idevice_id",
            "/usr/local/bin/idevice_id"
        ]
        for path in commonPaths {
            if isExecutable(at: path) {
                return path
            }
        }
        return findInPath(binaryName: "idevice_id")
    }

    // MARK: - Diagnostics

    public func getStatusReport() -> [BinaryInfo] {
        var report: [BinaryInfo] = []

        // zsign
        let zsign = resolveZsign()
        report.append(BinaryInfo(
            name: "zsign (Signing Engine)",
            path: zsign,
            isAvailable: zsign != nil,
            version: zsign != nil ? "1.1.2" : nil,
            source: zsign?.contains("Resources") == true ? "Bundled" : (zsign?.contains("homebrew") == true ? "Homebrew" : "System")
        ))

        // devicectl
        let devicectl = resolveDevicectl()
        report.append(BinaryInfo(
            name: "xcrun devicectl (iOS 17+ CoreDevice)",
            path: devicectl,
            isAvailable: devicectl != nil,
            version: "macOS Developer Tools",
            source: "Apple Xcode / CommandLineTools"
        ))

        // libimobiledevice tools
        let ideviceId = resolveIdeviceId()
        report.append(BinaryInfo(
            name: "idevice_id (Device Discovery)",
            path: ideviceId,
            isAvailable: ideviceId != nil,
            version: nil,
            source: ideviceId != nil ? "Homebrew libimobiledevice" : "Not Found"
        ))

        let ideviceInstaller = resolveIdeviceinstaller()
        report.append(BinaryInfo(
            name: "ideviceinstaller (iOS Deployment)",
            path: ideviceInstaller,
            isAvailable: ideviceInstaller != nil,
            version: nil,
            source: ideviceInstaller != nil ? "Homebrew / System" : "Optional (devicectl fallback available)"
        ))

        return report
    }

    // MARK: - Homebrew Engine Installation

    public func resolveBrew() -> String? {
        let brewPaths = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        for path in brewPaths {
            if isExecutable(at: path) {
                return path
            }
        }
        return findInPath(binaryName: "brew")
    }

    public var isBrewAvailable: Bool {
        return resolveBrew() != nil
    }

    public func installPackage(_ packageName: String, onOutput: @escaping @Sendable (String) -> Void) async throws -> Bool {
        guard let brew = resolveBrew() else {
            throw NSError(domain: "BinaryManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Homebrew is not installed on this system."])
        }

        let task = Process()
        task.launchPath = brew
        task.arguments = ["install", packageName]

        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        var pathEnv = env["PATH"] ?? ""
        if !pathEnv.contains("/opt/homebrew/bin") {
            pathEnv = "/opt/homebrew/bin:/usr/local/bin:" + pathEnv
        }
        env["PATH"] = pathEnv
        task.environment = env

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        let fileHandle = pipe.fileHandleForReading
        fileHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                onOutput(line)
            }
        }

        try task.run()
        task.waitUntilExit()
        fileHandle.readabilityHandler = nil

        return task.terminationStatus == 0
    }

    // MARK: - Helpers

    public func isExecutable(at path: String) -> Bool {
        return fileManager.isExecutableFile(atPath: path)
    }

    public func getAppSupportBinDirectory() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let signetBin = appSupport.appendingPathComponent("Signet/bin", isDirectory: true)
        try? fileManager.createDirectory(at: signetBin, withIntermediateDirectories: true)
        return signetBin
    }

    private func findInPath(binaryName: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = [binaryName]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty, isExecutable(at: path) {
                    return path
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}

