import Foundation

public enum EntitlementSource: String, Sendable, Codable {
    case codeSignature = "Mach-O CodeSignature"
    case provisioningProfile = "Provisioning Profile"
    case xcent = "Embedded .xcent"
    case manualImport = "Imported File"
    case custom = "Custom Editor"

    public var iconName: String {
        switch self {
        case .codeSignature: return "cpu"
        case .provisioningProfile: return "doc.badge.gearshape.fill"
        case .xcent: return "doc.text.fill"
        case .manualImport: return "square.and.arrow.down.fill"
        case .custom: return "pencil.and.outline"
        }
    }
}

public enum EntitlementCategory: String, Sendable, CaseIterable, Identifiable {
    case identity = "Identity & Signing"
    case appGroups = "App Groups"
    case keychain = "Keychain Access"
    case push = "Push & Networking"
    case icloud = "iCloud & Storage"
    case system = "System & Hardware"
    case other = "General Capabilities"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .identity: return "person.badge.shield.checkmark"
        case .appGroups: return "person.3.sequence.fill"
        case .keychain: return "key.fill"
        case .push: return "bell.badge.fill"
        case .icloud: return "icloud.fill"
        case .system: return "cpu"
        case .other: return "puzzlepiece.fill"
        }
    }
}

public struct IPAEntitlementItem: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public let valueDescription: String
    public let category: EntitlementCategory
    public let isBoolean: Bool
    public let isArray: Bool

    public init(key: String, value: Any, category: EntitlementCategory? = nil) {
        self.key = key
        self.category = category ?? IPAEntitlements.categorize(key: key)

        if let boolVal = value as? Bool {
            self.valueDescription = boolVal ? "true" : "false"
            self.isBoolean = true
            self.isArray = false
        } else if let strVal = value as? String {
            self.valueDescription = strVal
            self.isBoolean = false
            self.isArray = false
        } else if let arrVal = value as? [Any] {
            self.valueDescription = arrVal.map { String(describing: $0) }.joined(separator: ", ")
            self.isBoolean = false
            self.isArray = true
        } else if let numVal = value as? NSNumber {
            if CFGetTypeID(numVal) == CFBooleanGetTypeID() {
                self.valueDescription = numVal.boolValue ? "true" : "false"
                self.isBoolean = true
            } else {
                self.valueDescription = numVal.stringValue
                self.isBoolean = false
            }
            self.isArray = false
        } else {
            self.valueDescription = String(describing: value)
            self.isBoolean = false
            self.isArray = false
        }
    }
}

public struct IPAPackageDetails: Sendable, Hashable {
    public var executableName: String?
    public var frameworks: [String] = []
    public var appExtensions: [String] = []
    public var provisioningProfileName: String?
    public var provisioningProfileTeamId: String?
    public var provisioningProfileExpiration: Date?
    public var isWildcardProfile: Bool = false

    public init(
        executableName: String? = nil,
        frameworks: [String] = [],
        appExtensions: [String] = [],
        provisioningProfileName: String? = nil,
        provisioningProfileTeamId: String? = nil,
        provisioningProfileExpiration: Date? = nil,
        isWildcardProfile: Bool = false
    ) {
        self.executableName = executableName
        self.frameworks = frameworks
        self.appExtensions = appExtensions
        self.provisioningProfileName = provisioningProfileName
        self.provisioningProfileTeamId = provisioningProfileTeamId
        self.provisioningProfileExpiration = provisioningProfileExpiration
        self.isWildcardProfile = isWildcardProfile
    }
}

public struct IPAEntitlements: @unchecked Sendable, Hashable {
    public var source: EntitlementSource
    public var dictionary: [String: AnyHashable]
    public var rawXML: String
    public var items: [IPAEntitlementItem]

    public init(
        source: EntitlementSource = .custom,
        dictionary: [String: AnyHashable] = [:],
        rawXML: String = "",
        items: [IPAEntitlementItem] = []
    ) {
        self.source = source
        self.dictionary = dictionary
        self.rawXML = rawXML
        self.items = items.isEmpty ? IPAEntitlements.createItems(from: dictionary) : items
    }

    public var count: Int {
        dictionary.count
    }

    public var isEmpty: Bool {
        dictionary.isEmpty
    }

    public var applicationIdentifier: String? {
        (dictionary["application-identifier"] as? String) ?? (dictionary["com.apple.application-identifier"] as? String)
    }

    public var teamId: String? {
        if let teamId = dictionary["com.apple.developer.team-identifier"] as? String {
            return teamId
        }
        if let appId = applicationIdentifier, let dotIndex = appId.firstIndex(of: ".") {
            return String(appId[..<dotIndex])
        }
        return nil
    }

    public var appGroups: [String] {
        if let groups = dictionary["com.apple.security.application-groups"] as? [String] {
            return groups
        }
        if let groups = dictionary["com.apple.security.application-groups"] as? [AnyHashable] {
            return groups.compactMap { $0 as? String }
        }
        return []
    }

    public var keychainAccessGroups: [String] {
        if let groups = dictionary["keychain-access-groups"] as? [String] {
            return groups
        }
        if let groups = dictionary["keychain-access-groups"] as? [AnyHashable] {
            return groups.compactMap { $0 as? String }
        }
        return []
    }

    public var associatedDomains: [String] {
        if let domains = dictionary["com.apple.developer.associated-domains"] as? [String] {
            return domains
        }
        if let domains = dictionary["com.apple.developer.associated-domains"] as? [AnyHashable] {
            return domains.compactMap { $0 as? String }
        }
        return []
    }

    public var apsEnvironment: String? {
        dictionary["aps-environment"] as? String
    }

    public var getTaskAllow: Bool? {
        if let val = dictionary["get-task-allow"] as? Bool {
            return val
        }
        if let num = dictionary["get-task-allow"] as? NSNumber {
            return num.boolValue
        }
        return nil
    }

    // MARK: - Helpers

    public static func categorize(key: String) -> EntitlementCategory {
        let lower = key.lowercased()
        if lower.contains("application-identifier") || lower.contains("team-identifier") || lower == "get-task-allow" || lower.contains("beta-reports-active") {
            return .identity
        }
        if lower.contains("application-groups") || lower.contains("app-group") {
            return .appGroups
        }
        if lower.contains("keychain") {
            return .keychain
        }
        if lower.contains("aps-environment") || lower.contains("network") || lower.contains("associated-domains") || lower.contains("wifi") || lower.contains("vpn") {
            return .push
        }
        if lower.contains("icloud") || lower.contains("ubiquity") || lower.contains("cloudkit") {
            return .icloud
        }
        if lower.contains("camera") || lower.contains("microphone") || lower.contains("carplay") || lower.contains("bluetooth") || lower.contains("nfc") || lower.contains("health") || lower.contains("homekit") || lower.contains("siri") {
            return .system
        }
        return .other
    }

    public static func createItems(from dictionary: [String: AnyHashable]) -> [IPAEntitlementItem] {
        dictionary.map { key, value in
            IPAEntitlementItem(key: key, value: value)
        }.sorted { $0.key < $1.key }
    }

    /// Parses an XML string into `IPAEntitlements`
    public static func from(xmlString: String, source: EntitlementSource = .custom) -> IPAEntitlements? {
        guard let data = xmlString.data(using: .utf8) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        if let dict = plist as? [String: Any] {
            return from(dictionary: dict, source: source)
        }
        return nil
    }

    /// Creates `IPAEntitlements` from standard dictionary
    public static func from(dictionary: [String: Any], source: EntitlementSource = .custom) -> IPAEntitlements {
        var hashableDict: [String: AnyHashable] = [:]
        for (k, v) in dictionary {
            if let hashableVal = v as? AnyHashable {
                hashableDict[k] = hashableVal
            } else if let arr = v as? [Any] {
                hashableDict[k] = arr.compactMap { $0 as? AnyHashable }
            } else {
                hashableDict[k] = String(describing: v)
            }
        }

        var xmlString = ""
        if let xmlData = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0) {
            xmlString = String(data: xmlData, encoding: .utf8) ?? ""
        }

        let items = createItems(from: hashableDict)
        return IPAEntitlements(source: source, dictionary: hashableDict, rawXML: xmlString, items: items)
    }

    /// Adapts the entitlements for a new target Team ID and optional Bundle ID
    public func adapted(newTeamId: String, newBundleId: String? = nil) -> IPAEntitlements {
        guard !newTeamId.isEmpty else { return self }

        var updated: [String: Any] = [:]
        let oldTeam = self.teamId

        for (key, val) in dictionary {
            var newVal: Any = val

            if key == "com.apple.developer.team-identifier" {
                newVal = newTeamId
            } else if key == "application-identifier" || key == "com.apple.application-identifier" {
                if let oldAppId = val as? String {
                    if let newBundleId = newBundleId, !newBundleId.isEmpty {
                        newVal = "\(newTeamId).\(newBundleId)"
                    } else if let oldTeam = oldTeam, oldAppId.hasPrefix("\(oldTeam).") {
                        let remainder = oldAppId.dropFirst(oldTeam.count + 1)
                        newVal = "\(newTeamId).\(remainder)"
                    } else if let dotIndex = oldAppId.firstIndex(of: ".") {
                        let remainder = oldAppId[oldAppId.index(after: dotIndex)...]
                        newVal = "\(newTeamId).\(remainder)"
                    } else {
                        newVal = "\(newTeamId).\(oldAppId)"
                    }
                }
            } else if key == "keychain-access-groups" {
                if let groups = val as? [String] {
                    newVal = groups.map { group in
                        if let oldTeam = oldTeam, group.hasPrefix("\(oldTeam).") {
                            let remainder = group.dropFirst(oldTeam.count + 1)
                            return "\(newTeamId).\(remainder)"
                        } else if let dotIndex = group.firstIndex(of: ".") {
                            let remainder = group[group.index(after: dotIndex)...]
                            return "\(newTeamId).\(remainder)"
                        }
                        return group
                    }
                }
            }

            updated[key] = newVal
        }

        return IPAEntitlements.from(dictionary: updated, source: .custom)
    }
}
