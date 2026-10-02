import Foundation

public struct ProvisioningProfileInfo: Identifiable, Hashable, Codable {
    public var id: String { uuid.isEmpty ? name : uuid }
    public let name: String
    public let uuid: String
    public let teamId: String
    public let teamName: String
    public let applicationIdentifier: String
    public let isWildcard: Bool
    public let expirationDate: Date
    public let provisionedDevices: [String]
    public let profilePath: String?

    public init(
        name: String,
        uuid: String,
        teamId: String,
        teamName: String,
        applicationIdentifier: String,
        isWildcard: Bool,
        expirationDate: Date,
        provisionedDevices: [String] = [],
        profilePath: String? = nil
    ) {
        self.name = name
        self.uuid = uuid
        self.teamId = teamId
        self.teamName = teamName
        self.applicationIdentifier = applicationIdentifier
        self.isWildcard = isWildcard
        self.expirationDate = expirationDate
        self.provisionedDevices = provisionedDevices
        self.profilePath = profilePath
    }

    public var daysRemaining: Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: Date(), to: expirationDate)
        return max(0, components.day ?? 0)
    }

    public var isExpired: Bool {
        return Date() > expirationDate
    }

    public var validityStatusText: String {
        if isExpired {
            return "Expired"
        }
        let days = daysRemaining
        return "\(days) days remaining"
    }

    public func matchesDevice(udid: String) -> Bool {
        // Developer/AdHoc profiles list device UDIDs. Enterprise or some distribution profiles might have empty provisionedDevices
        if provisionedDevices.isEmpty {
            return true
        }
        return provisionedDevices.contains { $0.caseInsensitiveCompare(udid) == .orderedSame }
    }
}
