import Foundation

public struct IPAMetadata: Identifiable, Hashable {
    public var id: String { fileURL.path }
    public let fileURL: URL
    public let fileName: String
    public let fileSize: Int64
    public var bundleIdentifier: String?
    public var displayName: String?
    public var version: String?
    public var buildNumber: String?
    public var minimumOSVersion: String?
    public var executableName: String?
    public var packageDetails: IPAPackageDetails?
    public var entitlements: IPAEntitlements?

    public init(
        fileURL: URL,
        fileName: String,
        fileSize: Int64,
        bundleIdentifier: String? = nil,
        displayName: String? = nil,
        version: String? = nil,
        buildNumber: String? = nil,
        minimumOSVersion: String? = nil,
        executableName: String? = nil,
        packageDetails: IPAPackageDetails? = nil,
        entitlements: IPAEntitlements? = nil
    ) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.fileSize = fileSize
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.version = version
        self.buildNumber = buildNumber
        self.minimumOSVersion = minimumOSVersion
        self.executableName = executableName
        self.packageDetails = packageDetails
        self.entitlements = entitlements
    }

    public var formattedSize: String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: fileSize)
    }
}
