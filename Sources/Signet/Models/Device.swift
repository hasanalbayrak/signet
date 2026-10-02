import Foundation

public struct Device: Identifiable, Hashable, Codable {
    public enum ConnectionType: String, Codable, CaseIterable {
        case usb = "USB"
        case wifi = "Wi-Fi"
        case network = "Network"
        case local = "Mac"
        case unknown = "Unknown"

        public var iconName: String {
            switch self {
            case .usb: return "cable.connector"
            case .wifi, .network: return "wifi"
            case .local: return "macbook"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    public var id: String { udid }
    public let udid: String
    public let name: String
    public let model: String
    public let productType: String
    public let osVersion: String
    public let connectionType: ConnectionType
    public let isPaired: Bool
    public let isAvailable: Bool
    public let developerModeEnabled: Bool?
    public let serialNumber: String?
    public let cpuArchitecture: String?
    public let buildVersion: String?
    public let batteryLevel: Int?
    public let isAppleSiliconMac: Bool

    public init(
        udid: String,
        name: String,
        model: String,
        productType: String,
        osVersion: String,
        connectionType: ConnectionType = .usb,
        isPaired: Bool = true,
        isAvailable: Bool = true,
        developerModeEnabled: Bool? = nil,
        serialNumber: String? = nil,
        cpuArchitecture: String? = nil,
        buildVersion: String? = nil,
        batteryLevel: Int? = nil,
        isAppleSiliconMac: Bool = false
    ) {
        self.udid = udid
        self.name = name
        self.model = model
        self.productType = productType
        self.osVersion = osVersion
        self.connectionType = connectionType
        self.isPaired = isPaired
        self.isAvailable = isAvailable
        self.developerModeEnabled = developerModeEnabled
        self.serialNumber = serialNumber
        self.cpuArchitecture = cpuArchitecture
        self.buildVersion = buildVersion
        self.batteryLevel = batteryLevel
        self.isAppleSiliconMac = isAppleSiliconMac
    }

    public var displayName: String {
        if isAppleSiliconMac || connectionType == .local {
            return name.isEmpty ? "My Mac (Apple Silicon)" : "\(name) (Mac)"
        }
        if name.isEmpty {
            return model.isEmpty ? "iOS Device (\(shortUDID))" : "\(model) (\(shortUDID))"
        }
        return name
    }

    public var shortUDID: String {
        if udid.count > 12 {
            return "\(udid.prefix(6))...\(udid.suffix(4))"
        }
        return udid
    }

    public var deviceIconName: String {
        if isAppleSiliconMac || connectionType == .local {
            return "macbook"
        }
        let lower = (model + productType).lowercased()
        if lower.contains("ipad") {
            return "ipad"
        } else if lower.contains("watch") {
            return "applewatch"
        } else if lower.contains("appletv") {
            return "appletv"
        } else if lower.contains("vision") {
            return "visionpro"
        }
        return "iphone"
    }

    public var statusDescription: String {
        if isAppleSiliconMac || connectionType == .local {
            return "\(osVersion) • Apple Silicon • Native"
        }
        var parts: [String] = []
        if !osVersion.isEmpty {
            parts.append("iOS \(osVersion)")
        }
        if !model.isEmpty && model != name {
            parts.append(model)
        }
        parts.append(connectionType.rawValue)
        return parts.joined(separator: " • ")
    }
}
