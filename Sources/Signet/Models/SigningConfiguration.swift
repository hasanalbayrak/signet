import Foundation

public struct SigningConfiguration: Hashable {
    public var ipaURL: URL?
    public var outputURL: URL?
    public var customBundleId: String = ""
    public var customDisplayName: String = ""
    public var customVersion: String = ""
    public var customEntitlementsURL: URL?
    public var customEntitlementsContent: String?
    public var injectedDylibs: [URL] = []
    public var removeExtensions: Bool = true
    public var enableFileSharing: Bool = true
    public var enableDocumentBrowser: Bool = true
    public var forceResign: Bool = true
    public var removeUISupportedDevices: Bool = true
    public var compressionLevel: Int = 1

    public init(
        ipaURL: URL? = nil,
        outputURL: URL? = nil,
        customBundleId: String = "",
        customDisplayName: String = "",
        customVersion: String = "",
        customEntitlementsURL: URL? = nil,
        customEntitlementsContent: String? = nil,
        injectedDylibs: [URL] = [],
        removeExtensions: Bool = true,
        enableFileSharing: Bool = true,
        enableDocumentBrowser: Bool = true,
        forceResign: Bool = true,
        removeUISupportedDevices: Bool = true,
        compressionLevel: Int = 1
    ) {
        self.ipaURL = ipaURL
        self.outputURL = outputURL
        self.customBundleId = customBundleId
        self.customDisplayName = customDisplayName
        self.customVersion = customVersion
        self.customEntitlementsURL = customEntitlementsURL
        self.customEntitlementsContent = customEntitlementsContent
        self.injectedDylibs = injectedDylibs
        self.removeExtensions = removeExtensions
        self.enableFileSharing = enableFileSharing
        self.enableDocumentBrowser = enableDocumentBrowser
        self.forceResign = forceResign
        self.removeUISupportedDevices = removeUISupportedDevices
        self.compressionLevel = compressionLevel
    }

    public var hasCustomEntitlements: Bool {
        customEntitlementsURL != nil || (customEntitlementsContent != nil && !customEntitlementsContent!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
