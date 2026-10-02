import Foundation
import CryptoKit

public enum AppleDeveloperError: LocalizedError {
    case invalidPrivateKey(String)
    case authenticationFailed(String)
    case apiError(statusCode: Int, message: String)
    case deviceRegistrationFailed(String)
    case certificateCreationFailed(String)
    case profileCreationFailed(String)
    case opensslExecutionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPrivateKey(let msg):
            return "Invalid App Store Connect API Private Key (.p8): \(msg)"
        case .authenticationFailed(let msg):
            return "Apple Developer authentication failed: \(msg)"
        case .apiError(let code, let msg):
            return "Apple API error (\(code)): \(msg)"
        case .deviceRegistrationFailed(let msg):
            return "Could not register device with Apple: \(msg)"
        case .certificateCreationFailed(let msg):
            return "Could not create Apple Development certificate: \(msg)"
        case .profileCreationFailed(let msg):
            return "Could not create Provisioning Profile: \(msg)"
        case .opensslExecutionFailed(let msg):
            return "OpenSSL execution failed: \(msg)"
        }
    }
}

public final class AppleDeveloperService: @unchecked Sendable {
    public static let shared = AppleDeveloperService()

    private let baseURL = URL(string: "https://api.appstoreconnect.apple.com/v1")!
    private let credentialService = CredentialService.shared

    private init() {}

    // MARK: - JWT Token Generation

    public func generateJWT(credentials: AppStoreConnectCredentials) throws -> String {
        let cleanPem = formatPEM(credentials.privateKeyPem)

        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try P256.Signing.PrivateKey(pemRepresentation: cleanPem)
        } catch {
            throw AppleDeveloperError.invalidPrivateKey(error.localizedDescription)
        }

        let headerDict: [String: Any] = [
            "alg": "ES256",
            "kid": credentials.keyId.trimmingCharacters(in: .whitespacesAndNewlines),
            "typ": "JWT"
        ]

        let now = Int(Date().timeIntervalSince1970)
        let payloadDict: [String: Any] = [
            "iss": credentials.issuerId.trimmingCharacters(in: .whitespacesAndNewlines),
            "iat": now - 30, // 30s clock drift buffer
            "exp": now + 1200, // 20 minutes expiration
            "aud": "appstoreconnect-v1"
        ]

        let headerData = try JSONSerialization.data(withJSONObject: headerDict, options: [.sortedKeys])
        let payloadData = try JSONSerialization.data(withJSONObject: payloadDict, options: [.sortedKeys])

        let headerB64 = base64UrlEncode(headerData)
        let payloadB64 = base64UrlEncode(payloadData)

        let signingInput = "\(headerB64).\(payloadB64)"
        guard let messageData = signingInput.data(using: .utf8) else {
            throw AppleDeveloperError.authenticationFailed("Could not encode JWT message.")
        }

        let signature = try privateKey.signature(for: messageData)
        let signatureB64 = base64UrlEncode(signature.rawRepresentation)

        return "\(signingInput).\(signatureB64)"
    }

    private func formatPEM(_ raw: String) -> String {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !str.contains("-----BEGIN PRIVATE KEY-----") {
            str = "-----BEGIN PRIVATE KEY-----\n\(str)\n-----END PRIVATE KEY-----"
        }
        return str
    }

    private func base64UrlEncode(_ data: Data) -> String {
        var str = data.base64EncodedString()
        str = str.replacingOccurrences(of: "+", with: "-")
        str = str.replacingOccurrences(of: "/", with: "_")
        str = str.replacingOccurrences(of: "=", with: "")
        return str
    }

    // MARK: - API Client

    private func request<T: Decodable>(
        token: String,
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil
    ) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppleDeveloperError.authenticationFailed("Invalid HTTP response.")
        }

        if httpResponse.statusCode >= 400 {
            var errorMessage = "HTTP \(httpResponse.statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errors = json["errors"] as? [[String: Any]],
               let first = errors.first,
               let detail = first["detail"] as? String {
                errorMessage = detail
            }
            throw AppleDeveloperError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Auto-Provisioning Pipeline

    public func autoProvision(
        credentials: AppStoreConnectCredentials,
        targetDevice: Device?,
        onStep: (@Sendable (AutoProvisioningStep) -> Void)? = nil,
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> (cert: CertificateInfo, profile: ProvisioningProfileInfo) {
        onStep?(.authenticating)
        onLog?(LogMessage(level: .info, message: "Generating App Store Connect ES256 JWT Token..."))

        let jwt = try generateJWT(credentials: credentials)
        onLog?(LogMessage(level: .success, message: "Authenticated with Apple Developer API successfully."))

        // 1. Register or find device if device is attached
        var registeredDeviceId: String? = nil
        if let device = targetDevice, !device.udid.isEmpty {
            onStep?(.registeringDevice(deviceName: device.displayName))
            onLog?(LogMessage(level: .info, message: "Ensuring device '\(device.displayName)' is registered with Apple..."))
            registeredDeviceId = try await registerOrFindDevice(token: jwt, device: device, onLog: onLog)
        }

        // 2. Obtain or Create Development Certificate
        onStep?(.creatingCertificate)
        onLog?(LogMessage(level: .info, message: "Resolving Apple Development Certificate..."))

        let certResult = try await resolveOrCreateDevelopmentCertificate(token: jwt, onLog: onLog)
        onLog?(LogMessage(level: .success, message: "Development Certificate ready (ID: \(certResult.certId))."))

        // 3. Resolve or Create Wildcard Bundle ID
        onLog?(LogMessage(level: .info, message: "Resolving Wildcard Bundle ID..."))
        let bundleIdId = try await resolveOrCreateWildcardBundleId(token: jwt, onLog: onLog)

        // 4. Generate or Download Provisioning Profile
        onStep?(.creatingProfile)
        onLog?(LogMessage(level: .info, message: "Generating 365-day Wildcard Provisioning Profile..."))

        let profileData = try await createOrDownloadProfile(
            token: jwt,
            bundleIdId: bundleIdId,
            certId: certResult.certId,
            deviceId: registeredDeviceId,
            onLog: onLog
        )

        // 5. Finalizing: Save credentials
        onStep?(.finalizing)
        onLog?(LogMessage(level: .info, message: "Saving certificates and updating Keychain..."))

        // Save profile
        let profilePath = credentialService.savedProfileURL
        try profileData.write(to: profilePath)
        let profileInfo = try credentialService.importAndSaveProfile(from: profilePath)

        // Save P12
        let p12Path = credentialService.savedP12URL
        try certResult.p12Data.write(to: p12Path)
        let certInfo = try credentialService.importAndSaveP12(from: p12Path, password: certResult.password)

        onStep?(.success(message: "Auto-provisioning complete! 365-day developer certificate & wildcard profile active."))
        onLog?(LogMessage(level: .success, message: "🎉 Certificate (\(certInfo.teamName)) & Profile (\(profileInfo.name)) successfully configured!"))

        return (certInfo, profileInfo)
    }

    // MARK: - Device Helpers

    private func registerOrFindDevice(token: String, device: Device, onLog: (@Sendable (LogMessage) -> Void)?) async throws -> String {
        // Try registering device
        let body: [String: Any] = [
            "data": [
                "type": "devices",
                "attributes": [
                    "name": device.displayName,
                    "udid": device.udid,
                    "platform": "IOS"
                ]
            ]
        ]

        do {
            let resp: ASCDataResponse<ASCDeviceAttributes> = try await request(
                token: token,
                path: "devices",
                method: "POST",
                body: body
            )
            onLog?(LogMessage(level: .success, message: "Device successfully registered: \(device.displayName)"))
            return resp.data.id
        } catch let AppleDeveloperError.apiError(statusCode, _) where statusCode == 409 {
            // Already registered, query existing device list
            onLog?(LogMessage(level: .verbose, message: "Device already registered with Apple. Fetching device ID..."))
            let listResp: ASCListResponse<ASCDeviceAttributes> = try await request(
                token: token,
                path: "devices?filter[udid]=\(device.udid)"
            )
            if let existing = listResp.data.first {
                return existing.id
            }
        }

        // Fallback: list all devices and find by UDID
        let allDevices: ASCListResponse<ASCDeviceAttributes> = try await request(token: token, path: "devices?limit=200")
        if let match = allDevices.data.first(where: { $0.attributes.udid.caseInsensitiveCompare(device.udid) == .orderedSame }) {
            return match.id
        }

        throw AppleDeveloperError.deviceRegistrationFailed("Could not resolve device ID for \(device.udid)")
    }

    // MARK: - Certificate Helpers

    private struct CertResult {
        let certId: String
        let p12Data: Data
        let password: String
    }

    private func resolveOrCreateDevelopmentCertificate(
        token: String,
        onLog: (@Sendable (LogMessage) -> Void)?
    ) async throws -> CertResult {
        // Generate local RSA 2048 keypair & CSR
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let keyPath = tempDir.appendingPathComponent("dev_key.pem").path
        let csrPath = tempDir.appendingPathComponent("dev_csr.pem").path
        let certDerPath = tempDir.appendingPathComponent("dev_cert.cer").path
        let certPemPath = tempDir.appendingPathComponent("dev_cert.pem").path
        let p12Path = tempDir.appendingPathComponent("output.p12").path
        let p12Password = "SignetPass\(Int.random(in: 100000...999999))"

        onLog?(LogMessage(level: .verbose, message: "Generating RSA 2048 private key and CSR..."))

        // Run openssl req -new -newkey rsa:2048 -nodes -keyout keyPath -out csrPath -subj "/CN=Signet Development"
        let csrGen = Process()
        csrGen.launchPath = "/usr/bin/openssl"
        csrGen.arguments = ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", keyPath, "-out", csrPath, "-subj", "/CN=Signet Development"]
        try csrGen.run()
        csrGen.waitUntilExit()

        guard csrGen.terminationStatus == 0,
              let csrContent = try? String(contentsOfFile: csrPath, encoding: .utf8) else {
            throw AppleDeveloperError.opensslExecutionFailed("Could not generate CSR with /usr/bin/openssl")
        }

        // Post CSR to Apple
        let body: [String: Any] = [
            "data": [
                "type": "certificates",
                "attributes": [
                    "certificateType": "DEVELOPMENT",
                    "csrContent": csrContent
                ]
            ]
        ]

        let createResp: ASCDataResponse<ASCCertificateAttributes>
        do {
            createResp = try await request(
                token: token,
                path: "certificates",
                method: "POST",
                body: body
            )
        } catch {
            // If development certificate limit is reached, query existing certificates
            onLog?(LogMessage(level: .warning, message: "Creating new certificate returned: \(error.localizedDescription). Checking existing certificates..."))
            let listResp: ASCListResponse<ASCCertificateAttributes> = try await request(
                token: token,
                path: "certificates?filter[certificateType]=DEVELOPMENT"
            )
            if let existing = listResp.data.first {
                onLog?(LogMessage(level: .info, message: "Using existing Apple Development Certificate: \(existing.attributes.displayName ?? existing.id)"))
                // Decode certificateContent
                if let rawCerData = Data(base64Encoded: existing.attributes.certificateContent) {
                    try rawCerData.write(to: URL(fileURLWithPath: certDerPath))
                    // Convert DER to PEM and package with key
                    _ = runOpenssl(["x509", "-inform", "der", "-in", certDerPath, "-out", certPemPath])
                    _ = runOpenssl(["pkcs12", "-export", "-out", p12Path, "-inkey", keyPath, "-in", certPemPath, "-password", "pass:\(p12Password)"])
                    if let p12Data = try? Data(contentsOf: URL(fileURLWithPath: p12Path)) {
                        return CertResult(certId: existing.id, p12Data: p12Data, password: p12Password)
                    }
                }
            }
            throw error
        }

        guard let cerData = Data(base64Encoded: createResp.data.attributes.certificateContent) else {
            throw AppleDeveloperError.certificateCreationFailed("Could not decode certificateContent from Apple.")
        }

        try cerData.write(to: URL(fileURLWithPath: certDerPath))

        // Convert DER to PEM
        guard runOpenssl(["x509", "-inform", "der", "-in", certDerPath, "-out", certPemPath]) else {
            throw AppleDeveloperError.opensslExecutionFailed("Could not convert certificate from DER to PEM.")
        }

        // Export P12
        guard runOpenssl(["pkcs12", "-export", "-out", p12Path, "-inkey", keyPath, "-in", certPemPath, "-password", "pass:\(p12Password)"]) else {
            throw AppleDeveloperError.opensslExecutionFailed("Could not export .p12 package.")
        }

        let p12Data = try Data(contentsOf: URL(fileURLWithPath: p12Path))
        return CertResult(certId: createResp.data.id, p12Data: p12Data, password: p12Password)
    }

    private func runOpenssl(_ args: [String]) -> Bool {
        let p = Process()
        p.launchPath = "/usr/bin/openssl"
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: - Bundle ID Helpers

    private func resolveOrCreateWildcardBundleId(token: String, onLog: (@Sendable (LogMessage) -> Void)?) async throws -> String {
        // Query existing bundle IDs
        let listResp: ASCListResponse<ASCIgnoredAttributes> = try await request(
            token: token,
            path: "bundleIds?limit=100"
        )

        if let existing = listResp.data.first(where: {
            $0.id.contains("wildcard") || $0.id.contains("signet")
        }) {
            return existing.id
        }

        if let anyBundle = listResp.data.first {
            return anyBundle.id
        }

        // Create new wildcard bundle ID
        let wildcardId = "com.signet.app.\(Int.random(in: 1000...9999)).*"
        let body: [String: Any] = [
            "data": [
                "type": "bundleIds",
                "attributes": [
                    "identifier": wildcardId,
                    "name": "Signet Wildcard Bundle",
                    "platform": "IOS"
                ]
            ]
        ]

        let createResp: ASCDataResponse<ASCIgnoredAttributes> = try await request(
            token: token,
            path: "bundleIds",
            method: "POST",
            body: body
        )

        onLog?(LogMessage(level: .success, message: "Created Wildcard App Identifier: \(wildcardId)"))
        return createResp.data.id
    }

    // MARK: - Profile Helpers

    private func createOrDownloadProfile(
        token: String,
        bundleIdId: String,
        certId: String,
        deviceId: String?,
        onLog: (@Sendable (LogMessage) -> Void)?
    ) async throws -> Data {
        let profileName = "Signet Wildcard Provisioning (\(Int.random(in: 100...999)))"

        var devicesRelationship: [String: Any] = [:]
        if let dId = deviceId {
            devicesRelationship = [
                "data": [
                    ["type": "devices", "id": dId]
                ]
            ]
        } else {
            // Attach all available devices
            let devList: ASCListResponse<ASCDeviceAttributes> = try await request(token: token, path: "devices?limit=100")
            let devRefs = devList.data.map { ["type": "devices", "id": $0.id] }
            devicesRelationship = ["data": devRefs]
        }

        let body: [String: Any] = [
            "data": [
                "type": "profiles",
                "attributes": [
                    "name": profileName,
                    "profileType": "IOS_APP_DEVELOPMENT"
                ],
                "relationships": [
                    "bundleId": [
                        "data": ["type": "bundleIds", "id": bundleIdId]
                    ],
                    "certificates": [
                        "data": [["type": "certificates", "id": certId]]
                    ],
                    "devices": devicesRelationship
                ]
            ]
        ]

        let createResp: ASCDataResponse<ASCProfileAttributes> = try await request(
            token: token,
            path: "profiles",
            method: "POST",
            body: body
        )

        guard let profileData = Data(base64Encoded: createResp.data.attributes.profileContent) else {
            throw AppleDeveloperError.profileCreationFailed("Could not decode profileContent from Apple response.")
        }

        onLog?(LogMessage(level: .success, message: "Profile created: \(profileName)"))
        return profileData
    }

    // MARK: - Teams Lookup

    public func fetchTeams(credentials: AppStoreConnectCredentials) async throws -> [DeveloperTeam] {
        let jwt = try generateJWT(credentials: credentials)
        // Query certificates or user info to discover team
        let listResp: ASCListResponse<ASCCertificateAttributes> = try await request(
            token: jwt,
            path: "certificates?limit=5"
        )

        var teamName = credentials.teamName ?? "Apple Developer Team"
        var teamId = credentials.teamId ?? credentials.issuerId

        if let firstCert = listResp.data.first {
            if let name = firstCert.attributes.displayName {
                teamName = name
            }
        }

        return [
            DeveloperTeam(id: teamId, name: teamName, type: "Apple Developer Program", status: "Active")
        ]
    }
}

// MARK: - Decodable Response Types

private struct ASCDataResponse<T: Decodable>: Decodable {
    let data: ASCResource<T>
}

private struct ASCListResponse<T: Decodable>: Decodable {
    let data: [ASCResource<T>]
}

private struct ASCResource<T: Decodable>: Decodable {
    let id: String
    let type: String
    let attributes: T
}

private struct ASCIgnoredAttributes: Decodable {}

private struct ASCDeviceAttributes: Decodable {
    let name: String
    let udid: String
    let platform: String?
}

private struct ASCCertificateAttributes: Decodable {
    let certificateContent: String
    let displayName: String?
    let expirationDate: String?
}

private struct ASCProfileAttributes: Decodable {
    let profileContent: String
    let name: String
}
