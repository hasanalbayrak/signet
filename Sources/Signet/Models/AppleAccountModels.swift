import Foundation

public struct DeveloperTeam: Identifiable, Hashable, Codable {
    public var id: String
    public let name: String
    public let type: String
    public let status: String

    public init(id: String, name: String, type: String = "Individual", status: String = "Active") {
        self.id = id
        self.name = name
        self.type = type
        self.status = status
    }

    public var displayTitle: String {
        return "\(name) (\(id))"
    }
}

public struct AppStoreConnectCredentials: Codable, Hashable {
    public var keyId: String
    public var issuerId: String
    public var privateKeyPem: String
    public var teamId: String?
    public var teamName: String?

    public init(
        keyId: String,
        issuerId: String,
        privateKeyPem: String,
        teamId: String? = nil,
        teamName: String? = nil
    ) {
        self.keyId = keyId
        self.issuerId = issuerId
        self.privateKeyPem = privateKeyPem
        self.teamId = teamId
        self.teamName = teamName
    }

    public var isValid: Bool {
        return !keyId.trimmingCharacters(in: .whitespaces).isEmpty &&
               !issuerId.trimmingCharacters(in: .whitespaces).isEmpty &&
               !privateKeyPem.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

public enum AutoProvisioningStep: Equatable {
    case idle
    case authenticating
    case fetchingTeams
    case registeringDevice(deviceName: String)
    case creatingCertificate
    case creatingProfile
    case finalizing
    case success(message: String)
    case failed(error: String)

    public var message: String {
        switch self {
        case .idle:
            return "Ready to auto-provision."
        case .authenticating:
            return "Authenticating with Apple Developer API..."
        case .fetchingTeams:
            return "Fetching developer teams..."
        case .registeringDevice(let name):
            return "Registering '\(name)' with Apple Developer Portal..."
        case .creatingCertificate:
            return "Generating keypair and requesting Development Certificate..."
        case .creatingProfile:
            return "Generating Wildcard Provisioning Profile..."
        case .finalizing:
            return "Packaging .p12 and storing credentials into Keychain..."
        case .success(let msg):
            return msg
        case .failed(let err):
            return "Failed: \(err)"
        }
    }

    public var isBusy: Bool {
        switch self {
        case .authenticating, .fetchingTeams, .registeringDevice, .creatingCertificate, .creatingProfile, .finalizing:
            return true
        default:
            return false
        }
    }
}
