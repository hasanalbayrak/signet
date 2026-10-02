import Foundation

public struct Device: Identifiable, Hashable, Codable {
    public enum ConnectionType: String, Codable, CaseIterable {
        case usb = "USB"
        case wifi = "Wi-Fi"
        case network = "Network"
        case unknown = "Unknown"

        public var iconName: String {
            switch self {
            case .usb: return "cable.connector"
            case .wifi, .network: return "wifi"
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

    public init(
        udid: String,
        name: String,
        model: String,
        productType: String,
        osVersion: String,
        connectionType: ConnectionType = .usb,
        isPaired: Bool = true,
        isAvailable: Bool = true,
        developerModeEnabled: Bool? = nil
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
    }

    public var displayName: String {
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
