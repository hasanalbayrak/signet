import Foundation

public struct IPAMetadata: Identifiable, Hashable {
    public var id: String { fileURL.path }
    public let fileURL: URL
    public let fileName: String
    public let fileSize: Int64
    public var bundleIdentifier: String?
    public var displayName: String?
    public var version: String?
    public var minimumOSVersion: String?

    public init(
        fileURL: URL,
        fileName: String,
        fileSize: Int64,
        bundleIdentifier: String? = nil,
        displayName: String? = nil,
        version: String? = nil,
        minimumOSVersion: String? = nil
    ) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.fileSize = fileSize
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.version = version
        self.minimumOSVersion = minimumOSVersion
    }

    public var formattedSize: String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: fileSize)
    }
}
