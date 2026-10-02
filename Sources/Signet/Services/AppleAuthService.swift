import Foundation

public enum AppleAuthError: LocalizedError {
    case invalidCredentials(String)
    case invalid2FACode
    case sessionExpired
    case noTeamsFound
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials(let msg):
            return "Apple ID Sign-In failed: \(msg)"
        case .invalid2FACode:
            return "The 6-digit verification code is incorrect or expired. Please check your Apple devices."
        case .sessionExpired:
            return "Your Apple Developer session has expired. Please sign in again."
        case .noTeamsFound:
            return "No active Apple Developer Program memberships found for this Apple ID."
        case .networkError(let msg):
            return "Apple Server error: \(msg)"
        }
    }
}

public final class AppleAuthService: @unchecked Sendable {
    public static let shared = AppleAuthService()

    private let widgetKey = "21fcde42b235a2281226652077e68d16eb16715476a6b818f20387973f12e229"
    private let idmsaBase = URL(string: "https://idmsa.apple.com/appleauth/auth")!
    private let olympusBase = URL(string: "https://appstoreconnect.apple.com/olympus/v1")!
    private let developerServicesBase = URL(string: "https://api.appstoreconnect.apple.com/v1")!
    private let credentialService = CredentialService.shared

    private init() {}

    // MARK: - Sign In (Step 1)

    public func signIn(appleId: String, password: String) async throws -> AppleAuthResult {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpCookieAcceptPolicy = .always
        sessionConfig.httpShouldSetCookies = true
        let session = URLSession(configuration: sessionConfig)

        let url = idmsaBase.appendingPathComponent("signin")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(widgetKey, forHTTPHeaderField: "X-Apple-Widget-Key")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        let body: [String: Any] = [
            "accountName": appleId.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
            "rememberMe": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppleAuthError.networkError("Invalid response from Apple servers.")
        }

        let cookies = sessionConfig.httpCookieStorage?.cookies(for: url) ?? []
        let scnt = httpResponse.value(forHTTPHeaderField: "scnt")
        let sessionId = httpResponse.value(forHTTPHeaderField: "X-Apple-ID-Session-Id")

        // Status 409 means Two-Factor Authentication is required
        if httpResponse.statusCode == 409 || httpResponse.statusCode == 412 {
            let context = Apple2FAContext(
                appleId: appleId,
                sessionId: sessionId,
                scnt: scnt,
                cookies: cookies,
                codeLength: 6
            )
            return .requires2FA(context: context)
        }

        if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
            // Direct sign-in without 2FA (rare, but supported)
            let devSession = try await fetchOlympusSession(session: session, cookies: cookies, appleId: appleId)
            let teams = try await fetchTeams(session: session, cookies: cookies)
            return .success(session: devSession, teams: teams)
        }

        // Parse error message
        var errorMessage = "Invalid Apple ID or password."
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let serviceErrors = json["service_errors"] as? [[String: Any]],
               let first = serviceErrors.first,
               let msg = first["message"] as? String {
                errorMessage = msg
            }
        }
        return .failed(message: errorMessage)
    }

    // MARK: - Verify 2FA (Step 2)

    public func verify2FA(code: String, context: Apple2FAContext) async throws -> (session: AppleDeveloperSession, teams: [DeveloperTeam]) {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpCookieAcceptPolicy = .always
        sessionConfig.httpShouldSetCookies = true
        let session = URLSession(configuration: sessionConfig)

        // Set previous cookies
        for cookie in context.cookies {
            sessionConfig.httpCookieStorage?.setCookie(cookie)
        }

        let url = idmsaBase.appendingPathComponent("verify/trusteddevice/securitycode")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(widgetKey, forHTTPHeaderField: "X-Apple-Widget-Key")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        if let scnt = context.scnt {
            request.setValue(scnt, forHTTPHeaderField: "scnt")
        }
        if let sId = context.sessionId {
            request.setValue(sId, forHTTPHeaderField: "X-Apple-ID-Session-Id")
        }

        let body: [String: Any] = [
            "securityCode": [
                "code": code.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppleAuthError.networkError("Invalid response during 2FA verification.")
        }

        if httpResponse.statusCode == 400 || httpResponse.statusCode == 401 {
            throw AppleAuthError.invalid2FACode
        }

        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            throw AppleAuthError.networkError("2FA verification returned HTTP \(httpResponse.statusCode)")
        }

        // 2FA Succeeded! Extract updated cookies
        let updatedCookies = sessionConfig.httpCookieStorage?.cookies ?? []
        let devSession = try await fetchOlympusSession(session: session, cookies: updatedCookies, appleId: context.appleId)
        let teams = try await fetchTeams(session: session, cookies: updatedCookies)

        return (devSession, teams)
    }

    // MARK: - Olympus Session & Teams Lookup

    public func fetchOlympusSession(
        session: URLSession,
        cookies: [HTTPCookie],
        appleId: String
    ) async throws -> AppleDeveloperSession {
        let url = olympusBase.appendingPathComponent("session")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        for cookie in cookies {
            session.configuration.httpCookieStorage?.setCookie(cookie)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode < 400 else {
            // Fallback session object
            return AppleDeveloperSession(
                appleId: appleId,
                userFullName: appleId,
                sessionToken: nil,
                cookiesData: try? NSKeyedArchiver.archivedData(withRootObject: cookies, requiringSecureCoding: false)
            )
        }

        var fullName = appleId
        var defaultTeamId: String? = nil
        var defaultTeamName: String? = nil

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let user = json["user"] as? [String: Any] {
                let first = user["firstName"] as? String ?? ""
                let last = user["lastName"] as? String ?? ""
                let combined = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
                if !combined.isEmpty {
                    fullName = combined
                }
            }

            if let teamsArr = json["developerTeams"] as? [[String: Any]], let firstTeam = teamsArr.first {
                defaultTeamId = (firstTeam["teamId"] as? String) ?? (firstTeam["id"] as? String)
                defaultTeamName = firstTeam["name"] as? String
            }
        }

        let cookiesData = try? NSKeyedArchiver.archivedData(withRootObject: cookies, requiringSecureCoding: false)

        return AppleDeveloperSession(
            appleId: appleId,
            userFullName: fullName,
            selectedTeamId: defaultTeamId,
            selectedTeamName: defaultTeamName,
            sessionToken: nil,
            cookiesData: cookiesData
        )
    }

    public func fetchTeams(session: URLSession, cookies: [HTTPCookie]) async throws -> [DeveloperTeam] {
        let url = olympusBase.appendingPathComponent("session")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        for cookie in cookies {
            session.configuration.httpCookieStorage?.setCookie(cookie)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode < 400 else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let teamsArr = json["developerTeams"] as? [[String: Any]] else {
            return []
        }

        var list: [DeveloperTeam] = []
        for item in teamsArr {
            let teamId = (item["teamId"] as? String) ?? (item["id"] as? String) ?? ""
            let name = (item["name"] as? String) ?? "Apple Developer Team"
            let type = (item["type"] as? String) ?? "Individual"
            let status = (item["status"] as? String) ?? "Active"

            if !teamId.isEmpty {
                list.append(DeveloperTeam(id: teamId, name: name, type: type, status: status))
            }
        }

        return list
    }

    // MARK: - Auto-Provisioning with Apple ID Session

    public func autoProvisionWithSession(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        targetDevice: Device?,
        onStep: (@Sendable (AutoProvisioningStep) -> Void)? = nil,
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> (cert: CertificateInfo, profile: ProvisioningProfileInfo) {
        onStep?(.authenticating)
        onLog?(LogMessage(level: .info, message: "Activating team session for: \(team.displayTitle)..."))

        // Create ephemeral session with saved cookies
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpCookieAcceptPolicy = .always
        sessionConfig.httpShouldSetCookies = true
        let urlSession = URLSession(configuration: sessionConfig)

        if let data = session.cookiesData,
           let unarchived = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, HTTPCookie.self], from: data) as? [HTTPCookie] {
            for c in unarchived {
                sessionConfig.httpCookieStorage?.setCookie(c)
            }
        }

        // Set active team on Olympus
        let switchURL = olympusBase.appendingPathComponent("session")
        var switchReq = URLRequest(url: switchURL)
        switchReq.httpMethod = "POST"
        switchReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let switchBody = ["teamId": team.id]
        switchReq.httpBody = try? JSONSerialization.data(withJSONObject: switchBody)
        _ = try? await urlSession.data(for: switchReq)

        // 1. Device Registration
        var registeredDeviceId: String? = nil
        if let device = targetDevice, !device.udid.isEmpty {
            onStep?(.registeringDevice(deviceName: device.displayName))
            onLog?(LogMessage(level: .info, message: "Registering '\(device.displayName)' with Apple Developer Portal..."))
            registeredDeviceId = try? await registerDevice(urlSession: urlSession, device: device, onLog: onLog)
        }

        // 2. Certificate Generation
        onStep?(.creatingCertificate)
        onLog?(LogMessage(level: .info, message: "Generating RSA keypair & requesting Development Certificate..."))

        let certResult = try await generateAndRequestCertificate(
            urlSession: urlSession,
            team: team,
            onLog: onLog
        )

        // 3. Profile Generation
        onStep?(.creatingProfile)
        onLog?(LogMessage(level: .info, message: "Generating 365-day Wildcard Provisioning Profile..."))

        let profileData = try await createAndDownloadProfile(
            urlSession: urlSession,
            certId: certResult.certId,
            deviceId: registeredDeviceId,
            onLog: onLog
        )

        // 4. Finalizing
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

    private func registerDevice(urlSession: URLSession, device: Device, onLog: (@Sendable (LogMessage) -> Void)?) async throws -> String? {
        let url = developerServicesBase.appendingPathComponent("devices")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: req)
        if let http = response as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 201) {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let id = dataObj["id"] as? String {
                onLog?(LogMessage(level: .success, message: "Device registered: \(device.displayName)"))
                return id
            }
        }
        return nil
    }

    private struct CertPackage {
        let certId: String
        let p12Data: Data
        let password: String
    }

    private func generateAndRequestCertificate(
        urlSession: URLSession,
        team: DeveloperTeam,
        onLog: (@Sendable (LogMessage) -> Void)?
    ) async throws -> CertPackage {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let keyPath = tempDir.appendingPathComponent("dev_key.pem").path
        let csrPath = tempDir.appendingPathComponent("dev_csr.pem").path
        let certDerPath = tempDir.appendingPathComponent("dev_cert.cer").path
        let certPemPath = tempDir.appendingPathComponent("dev_cert.pem").path
        let p12Path = tempDir.appendingPathComponent("output.p12").path
        let password = "SignetPass\(Int.random(in: 100000...999999))"

        onLog?(LogMessage(level: .verbose, message: "Creating RSA 2048 private key and CSR..."))

        let csrGen = Process()
        csrGen.launchPath = "/usr/bin/openssl"
        csrGen.arguments = ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", keyPath, "-out", csrPath, "-subj", "/CN=Signet Development (\(team.id))"]
        try csrGen.run()
        csrGen.waitUntilExit()

        guard csrGen.terminationStatus == 0,
              let csrContent = try? String(contentsOfFile: csrPath, encoding: .utf8) else {
            throw AppleDeveloperError.opensslExecutionFailed("Could not generate CSR with /usr/bin/openssl")
        }

        // Post CSR to certificates endpoint
        let url = developerServicesBase.appendingPathComponent("certificates")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "data": [
                "type": "certificates",
                "attributes": [
                    "certificateType": "DEVELOPMENT",
                    "csrContent": csrContent
                ]
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: req)
        var certId = UUID().uuidString
        var rawCerData: Data? = nil

        if let http = response as? HTTPURLResponse, http.statusCode < 300 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let id = dataObj["id"] as? String,
               let attr = dataObj["attributes"] as? [String: Any],
               let b64 = attr["certificateContent"] as? String {
                certId = id
                rawCerData = Data(base64Encoded: b64)
            }
        }

        // If certificate limit reached or creation didn't return content, fetch existing
        if rawCerData == nil {
            onLog?(LogMessage(level: .info, message: "Fetching active development certificate from team..."))
            let listURL = developerServicesBase.appendingPathComponent("certificates?filter[certificateType]=DEVELOPMENT")
            var listReq = URLRequest(url: listURL)
            listReq.httpMethod = "GET"
            let (listData, listResp) = try await urlSession.data(for: listReq)
            if let listHttp = listResp as? HTTPURLResponse, listHttp.statusCode < 400,
               let json = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
               let dataArr = json["data"] as? [[String: Any]], let first = dataArr.first,
               let id = first["id"] as? String,
               let attr = first["attributes"] as? [String: Any],
               let b64 = attr["certificateContent"] as? String {
                certId = id
                rawCerData = Data(base64Encoded: b64)
            }
        }

        guard let cerBytes = rawCerData else {
            throw AppleDeveloperError.certificateCreationFailed("Could not obtain certificate content from Apple.")
        }

        try cerBytes.write(to: URL(fileURLWithPath: certDerPath))

        // Convert DER to PEM and package P12
        _ = runOpenssl(["x509", "-inform", "der", "-in", certDerPath, "-out", certPemPath])
        _ = runOpenssl(["pkcs12", "-export", "-out", p12Path, "-inkey", keyPath, "-in", certPemPath, "-password", "pass:\(password)"])

        let p12Data = try Data(contentsOf: URL(fileURLWithPath: p12Path))
        return CertPackage(certId: certId, p12Data: p12Data, password: password)
    }

    private func createAndDownloadProfile(
        urlSession: URLSession,
        certId: String,
        deviceId: String?,
        onLog: (@Sendable (LogMessage) -> Void)?
    ) async throws -> Data {
        let profileName = "Signet Wildcard (\(Int.random(in: 100...999)))"

        // Ensure bundle ID
        let bundleURL = developerServicesBase.appendingPathComponent("bundleIds?limit=20")
        var bundleReq = URLRequest(url: bundleURL)
        bundleReq.httpMethod = "GET"
        let (bundleData, _) = try await urlSession.data(for: bundleReq)

        var bundleIdId = ""
        if let json = try? JSONSerialization.jsonObject(with: bundleData) as? [String: Any],
           let arr = json["data"] as? [[String: Any]], let first = arr.first,
           let id = first["id"] as? String {
            bundleIdId = id
        }

        if bundleIdId.isEmpty {
            // Create wildcard bundle ID
            let createBundleURL = developerServicesBase.appendingPathComponent("bundleIds")
            var cReq = URLRequest(url: createBundleURL)
            cReq.httpMethod = "POST"
            cReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let cBody: [String: Any] = [
                "data": [
                    "type": "bundleIds",
                    "attributes": [
                        "identifier": "com.signet.wildcard.\(Int.random(in: 1000...9999)).*",
                        "name": "Signet Wildcard",
                        "platform": "IOS"
                    ]
                ]
            ]
            cReq.httpBody = try? JSONSerialization.data(withJSONObject: cBody)
            if let (cData, cResp) = try? await urlSession.data(for: cReq),
               let cHttp = cResp as? HTTPURLResponse, cHttp.statusCode < 300,
               let cJson = try? JSONSerialization.jsonObject(with: cData) as? [String: Any],
               let cDataObj = cJson["data"] as? [String: Any],
               let id = cDataObj["id"] as? String {
                bundleIdId = id
            }
        }

        // Create profile
        let profURL = developerServicesBase.appendingPathComponent("profiles")
        var profReq = URLRequest(url: profURL)
        profReq.httpMethod = "POST"
        profReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var devArray: [[String: String]] = []
        if let dId = deviceId {
            devArray.append(["type": "devices", "id": dId])
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
                    "devices": [
                        "data": devArray
                    ]
                ]
            ]
        ]
        profReq.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (profDataResp, profResponse) = try await urlSession.data(for: profReq)
        if let http = profResponse as? HTTPURLResponse, http.statusCode < 300,
           let json = try? JSONSerialization.jsonObject(with: profDataResp) as? [String: Any],
           let dataObj = json["data"] as? [String: Any],
           let attr = dataObj["attributes"] as? [String: Any],
           let b64 = attr["profileContent"] as? String,
           let decoded = Data(base64Encoded: b64) {
            onLog?(LogMessage(level: .success, message: "Profile created: \(profileName)"))
            return decoded
        }

        // Fallback: fetch existing profiles
        let getProfURL = developerServicesBase.appendingPathComponent("profiles?filter[profileType]=IOS_APP_DEVELOPMENT")
        var getReq = URLRequest(url: getProfURL)
        getReq.httpMethod = "GET"
        let (getData, getResp) = try await urlSession.data(for: getReq)
        if let http = getResp as? HTTPURLResponse, http.statusCode < 400,
           let json = try? JSONSerialization.jsonObject(with: getData) as? [String: Any],
           let arr = json["data"] as? [[String: Any]], let first = arr.first,
           let attr = first["attributes"] as? [String: Any],
           let b64 = attr["profileContent"] as? String,
           let decoded = Data(base64Encoded: b64) {
            onLog?(LogMessage(level: .info, message: "Loaded existing Wildcard Profile from Apple."))
            return decoded
        }

        throw AppleDeveloperError.profileCreationFailed("Failed to generate or download Provisioning Profile.")
    }

    private func runOpenssl(_ args: [String]) -> Bool {
        let p = Process()
        p.launchPath = "/usr/bin/openssl"
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
