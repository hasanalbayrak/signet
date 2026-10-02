import Foundation

public final class IPAManager: @unchecked Sendable {
    public static let shared = IPAManager()

    private let runner = ProcessRunner()

    private init() {}

    /// Extracts bundle identifier, display name, and version from an IPA package.
    public func inspectIPA(at fileURL: URL) async -> IPAMetadata {
        let fileName = fileURL.lastPathComponent
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        var metadata = IPAMetadata(fileURL: fileURL, fileName: fileName, fileSize: fileSize)

        // Run /usr/bin/unzip -p <fileURL.path> "Payload/*.app/Info.plist"
        let task = Process()
        task.launchPath = "/usr/bin/unzip"
        task.arguments = ["-p", fileURL.path, "Payload/*.app/Info.plist"]

        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                if !data.isEmpty,
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                    metadata.bundleIdentifier = plist["CFBundleIdentifier"] as? String
                    metadata.displayName = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
                    metadata.version = plist["CFBundleShortVersionString"] as? String
                    metadata.minimumOSVersion = plist["MinimumOSVersion"] as? String
                }
            }
        } catch {
            // Non-critical, fallback to basic metadata
        }

        return metadata
    }
}
