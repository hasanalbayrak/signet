import Foundation
import Security

public enum CredentialError: LocalizedError {
    case p12NotFound
    case profileNotFound
    case invalidPasswordOrCorruptP12
    case failedToParseProfile(String)
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .p12NotFound:
            return "Certificate (.p12) file was not found at specified path."
        case .profileNotFound:
            return "Provisioning profile (.mobileprovision) was not found at specified path."
        case .invalidPasswordOrCorruptP12:
            return "Invalid .p12 password or corrupted certificate file."
        case .failedToParseProfile(let msg):
            return "Failed to parse provisioning profile: \(msg)"
        case .keychainError(let status):
            return "macOS Keychain error: OSStatus \(status)"
        }
    }
}

public final class CredentialService: @unchecked Sendable {
    public static let shared = CredentialService()

    private let keychainService = "com.signet.macos"
    private let defaultAccount = "developer_certificate_p12"
    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Application Support Paths

    public func getCredentialsDirectory() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let credsDir = appSupport.appendingPathComponent("Signet/credentials", isDirectory: true)
        try? fileManager.createDirectory(at: credsDir, withIntermediateDirectories: true)
        return credsDir
    }

    public var savedP12URL: URL {
        getCredentialsDirectory().appendingPathComponent("signing_cert.p12")
    }

    public var savedProfileURL: URL {
        getCredentialsDirectory().appendingPathComponent("embedded.mobileprovision")
    }

    // MARK: - Keychain Storage

    public func savePasswordToKeychain(_ password: String, account: String? = nil) throws {
        let targetAccount = account ?? defaultAccount
        guard let data = password.data(using: .utf8) else { return }

        // Remove existing item if present
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: targetAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: targetAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.keychainError(status)
        }
    }

    public func loadPasswordFromKeychain(account: String? = nil) -> String? {
        let targetAccount = account ?? defaultAccount
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: targetAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func deletePasswordFromKeychain(account: String? = nil) {
        let targetAccount = account ?? defaultAccount
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: targetAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Certificate Import & Parsing

    public func importAndSaveP12(from sourceURL: URL, password: String) throws -> CertificateInfo {
        let p12Data = try Data(contentsOf: sourceURL)
        let info = try parseP12(data: p12Data, password: password, path: sourceURL.path)

        // Save copy to local app credentials
        let dest = savedP12URL
        if fileManager.fileExists(atPath: dest.path) {
            try? fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: sourceURL, to: dest)

        // Save password in Keychain
        try savePasswordToKeychain(password)

        // Persist path
        UserDefaults.standard.set(dest.path, forKey: "saved_p12_path")

        return info
    }

    public func parseP12(data: Data, password: String, path: String? = nil) throws -> CertificateInfo {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]

        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)

        guard status == errSecSuccess, let items = rawItems as? [[String: Any]], let firstItem = items.first else {
            throw CredentialError.invalidPasswordOrCorruptP12
        }

        var commonName = "Apple Development Certificate"
        var teamId = ""
        var teamName = ""
        var expirationDate = Date().addingTimeInterval(365 * 86400) // fallback 1 year

        if let identity = firstItem[kSecImportItemIdentity as String] {
            var certRef: SecCertificate?
            if SecIdentityCopyCertificate(identity as! SecIdentity, &certRef) == errSecSuccess, let cert = certRef {
                if let summary = SecCertificateCopySubjectSummary(cert) as String? {
                    commonName = summary
                }

                // Extract certificate values (expiration, OU, etc.)
                let keys: [CFString] = [kSecOIDX509V1ValidityNotAfter, kSecOIDSubjectAltName]
                if let values = SecCertificateCopyValues(cert, keys as CFArray, nil) as? [CFString: [String: Any]] {
                    if let validity = values[kSecOIDX509V1ValidityNotAfter],
                       let expNum = validity[kSecPropertyKeyValue as String] as? NSNumber {
                        expirationDate = Date(timeIntervalSinceReferenceDate: expNum.doubleValue)
                    }
                }
            }
        }

        // Parse commonName for Team ID if in standard format: "Apple Development: Name (TEAMID)"
        if let startParen = commonName.lastIndex(of: "("),
           let endParen = commonName.lastIndex(of: ")"),
           startParen < endParen {
            let extracted = String(commonName[commonName.index(after: startParen)..<endParen])
            if extracted.count >= 6 && extracted.count <= 12 {
                teamId = extracted
            }
        }

        // If commonName contains prefix like "Apple Development: Jane Doe"
        if commonName.contains(":") {
            let parts = commonName.components(separatedBy: ":")
            if parts.count > 1 {
                let namePart = parts[1].trimmingCharacters(in: .whitespaces)
                if let paren = namePart.firstIndex(of: "(") {
                    teamName = String(namePart[..<paren]).trimmingCharacters(in: .whitespaces)
                } else {
                    teamName = namePart
                }
            }
        }

        if teamName.isEmpty {
            teamName = commonName
        }

        return CertificateInfo(
            commonName: commonName,
            teamId: teamId.isEmpty ? "UNKNOWN" : teamId,
            teamName: teamName,
            creationDate: nil,
            expirationDate: expirationDate,
            p12Path: path
        )
    }

    // MARK: - Provisioning Profile Import & Parsing

    public func importAndSaveProfile(from sourceURL: URL) throws -> ProvisioningProfileInfo {
        let info = try parseProfile(at: sourceURL)

        let dest = savedProfileURL
        if fileManager.fileExists(atPath: dest.path) {
            try? fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: sourceURL, to: dest)

        UserDefaults.standard.set(dest.path, forKey: "saved_profile_path")
        return info
    }

    public func parseProfile(at fileURL: URL) throws -> ProvisioningProfileInfo {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw CredentialError.profileNotFound
        }

        // First attempt: use macOS native /usr/bin/security cms -D -i <path>
        let task = Process()
        task.launchPath = "/usr/bin/security"
        task.arguments = ["cms", "-D", "-i", fileURL.path]

        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()

        var plistData: Data?

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                plistData = stdout.fileHandleForReading.readDataToEndOfFile()
            }
        } catch {
            // Fallback to manual byte extraction below
        }

        // Fallback: extract XML between <?xml and </plist>
        if plistData == nil || plistData?.isEmpty == true {
            let rawData = try Data(contentsOf: fileURL)
            plistData = extractXMLFromCMSData(rawData)
        }

        guard let validData = plistData, !validData.isEmpty else {
            throw CredentialError.failedToParseProfile("Could not decode CMS wrapper.")
        }

        var propertyListFormat = PropertyListSerialization.PropertyListFormat.xml
        guard let plist = try? PropertyListSerialization.propertyList(
            from: validData,
            options: [],
            format: &propertyListFormat
        ) as? [String: Any] else {
            throw CredentialError.failedToParseProfile("Failed to parse inner plist dictionary.")
        }

        let name = plist["Name"] as? String ?? "Unnamed Profile"
        let uuid = plist["UUID"] as? String ?? UUID().uuidString
        let expirationDate = plist["ExpirationDate"] as? Date ?? Date().addingTimeInterval(365 * 86400)
        let teamName = plist["TeamName"] as? String ?? ""

        var teamId = ""
        if let teamIds = plist["TeamIdentifier"] as? [String], let firstId = teamIds.first {
            teamId = firstId
        }

        var appId = ""
        var isWildcard = false

        if let entitlements = plist["Entitlements"] as? [String: Any] {
            if let fullAppId = entitlements["application-identifier"] as? String {
                appId = fullAppId
                isWildcard = fullAppId.hasSuffix(".*") || fullAppId.contains("*")
            }
        }

        let devices = plist["ProvisionedDevices"] as? [String] ?? []

        return ProvisioningProfileInfo(
            name: name,
            uuid: uuid,
            teamId: teamId,
            teamName: teamName,
            applicationIdentifier: appId,
            isWildcard: isWildcard,
            expirationDate: expirationDate,
            provisionedDevices: devices,
            profilePath: fileURL.path
        )
    }

    private func extractXMLFromCMSData(_ data: Data) -> Data? {
        guard let xmlStart = "<?xml".data(using: .utf8),
              let xmlEnd = "</plist>".data(using: .utf8) else {
            return nil
        }

        guard let startRange = data.range(of: xmlStart),
              let endRange = data.range(of: xmlEnd, options: .backwards, in: startRange.lowerBound..<data.count) else {
            return nil
        }

        let completeRange = startRange.lowerBound..<endRange.upperBound
        return data.subdata(in: completeRange)
    }

    // MARK: - Auto-load on Launch

    public func loadSavedCredentials() -> (cert: CertificateInfo?, profile: ProvisioningProfileInfo?) {
        var certInfo: CertificateInfo?
        var profileInfo: ProvisioningProfileInfo?

        let p12Path = UserDefaults.standard.string(forKey: "saved_p12_path") ?? savedP12URL.path
        if fileManager.fileExists(atPath: p12Path),
           let password = loadPasswordFromKeychain() {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: p12Path)),
               let info = try? parseP12(data: data, password: password, path: p12Path) {
                certInfo = info
            }
        }

        let profilePath = UserDefaults.standard.string(forKey: "saved_profile_path") ?? savedProfileURL.path
        if fileManager.fileExists(atPath: profilePath) {
            if let info = try? parseProfile(at: URL(fileURLWithPath: profilePath)) {
                profileInfo = info
            }
        }

        return (certInfo, profileInfo)
    }
}
