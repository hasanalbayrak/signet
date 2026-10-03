import Foundation

public struct CertificateInfo: Identifiable, Hashable, Codable {
    public var id: String { teamId + "_" + commonName }
    public let commonName: String
    public let teamId: String
    public let teamName: String
    public let creationDate: Date?
    public let expirationDate: Date
    public let p12Path: String?

    public init(
        commonName: String,
        teamId: String,
        teamName: String,
        creationDate: Date? = nil,
        expirationDate: Date,
        p12Path: String? = nil
    ) {
        self.commonName = commonName
        self.teamId = teamId
        self.teamName = teamName
        self.creationDate = creationDate
        self.expirationDate = expirationDate
        self.p12Path = p12Path
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
        if days == 1 {
            return "1 day remaining"
        } else {
            return "\(days) days remaining"
        }
    }

    public var isExpiringSoon: Bool {
        return !isExpired && daysRemaining <= 30
    }

    public var cleanDisplayName: String {
        var s = commonName
        if let colonIdx = s.firstIndex(of: ":") {
            s = String(s[s.index(after: colonIdx)...])
        }
        if let parenIdx = s.firstIndex(of: "(") {
            s = String(s[..<parenIdx])
        }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return teamName.isEmpty ? commonName : teamName
    }

    public var isDistribution: Bool {
        commonName.localizedCaseInsensitiveContains("Distribution") ||
        teamName.localizedCaseInsensitiveContains("Distribution")
    }

    public var typeDisplayName: String {
        if isDistribution {
            return "Distribution"
        } else if commonName.localizedCaseInsensitiveContains("Development") {
            return "Development"
        }
        return "Certificate"
    }
}
