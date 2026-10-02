import Foundation

public struct PortalDevice: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let udid: String
    public let deviceClass: String
    public let model: String?
    public let status: String

    public init(id: String, name: String, udid: String, deviceClass: String = "iphone", model: String? = nil, status: String = "Y") {
        self.id = id
        self.name = name
        self.udid = udid
        self.deviceClass = deviceClass
        self.model = model
        self.status = status
    }

    public var isEnabled: Bool {
        return status.uppercased() == "Y" || status.lowercased() == "active" || status.lowercased() == "c"
    }

    public var displayClassIcon: String {
        switch deviceClass.lowercased() {
        case "ipad":
            return "ipad"
        case "watch":
            return "applewatch"
        case "appletv", "tvos":
            return "appletv"
        default:
            return "iphone"
        }
    }
}

public struct PortalCertificate: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let typeDisplayName: String
    public let status: String
    public let expirationDate: String?
    public let canDownload: Bool
    public let canRevoke: Bool
    public let ownerName: String?

    public init(
        id: String,
        name: String,
        type: String,
        typeDisplayName: String = "Apple Development",
        status: String = "Issued",
        expirationDate: String? = nil,
        canDownload: Bool = true,
        canRevoke: Bool = true,
        ownerName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.typeDisplayName = typeDisplayName
        self.status = status
        self.expirationDate = expirationDate
        self.canDownload = canDownload
        self.canRevoke = canRevoke
        self.ownerName = ownerName
    }

    public var isIssued: Bool {
        return status.lowercased() == "issued" || status.lowercased() == "active"
    }
}

public struct PortalAppId: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let identifier: String
    public let prefix: String
    public let isWildcard: Bool

    public init(id: String, name: String, identifier: String, prefix: String, isWildcard: Bool = false) {
        self.id = id
        self.name = name
        self.identifier = identifier
        self.prefix = prefix
        self.isWildcard = isWildcard || identifier.contains("*")
    }
}

public struct KeychainIdentity: Identifiable, Hashable, Sendable {
    public let id: String // SHA-1 fingerprint
    public let name: String
    public let teamId: String?

    public init(id: String, name: String, teamId: String? = nil) {
        self.id = id
        self.name = name
        self.teamId = teamId
    }
}
