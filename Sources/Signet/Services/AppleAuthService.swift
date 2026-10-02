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

        // Parse JSON error if present from Apple's identity API
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let serviceErrors = json["service_errors"] as? [[String: Any]],
           let first = serviceErrors.first,
           let msg = first["message"] as? String {
            return .failed(message: msg)
        }

        if httpResponse.statusCode == 401 {
            return .failed(message: "Invalid Apple ID or password. Please verify your credentials.")
        }

        if httpResponse.statusCode == 503 || httpResponse.statusCode == 403 {
            return .failed(message: "Apple requires interactive authentication for this account (Akamai Security Challenge). Please use the 'Sign In with Apple (Secure Web Login)' button.")
        }

        if let html = String(data: data, encoding: .utf8), html.contains("<html") {
            return .failed(message: "Apple server returned an interactive challenge (HTTP \(httpResponse.statusCode)). Please use 'Sign In with Apple (Secure Web Login)'.")
        }

        return .failed(message: "Apple ID authentication failed (HTTP \(httpResponse.statusCode)). Please use 'Sign In with Apple (Secure Web Login)'.")
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

    // MARK: - WebKit Cookie Session Handling

    public func handleWebCookies(
        cookies: [HTTPCookie],
        preloadedTeams: [DeveloperTeam] = []
    ) async throws -> (session: AppleDeveloperSession, teams: [DeveloperTeam]) {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpCookieAcceptPolicy = .always
        sessionConfig.httpShouldSetCookies = true
        let session = URLSession(configuration: sessionConfig)

        for cookie in cookies {
            sessionConfig.httpCookieStorage?.setCookie(cookie)
        }

        var devSession = try await fetchOlympusSession(session: session, cookies: cookies, appleId: "Apple Developer Account")
        var teams = try await fetchTeams(session: session, cookies: cookies)

        // Merge any preloaded teams discovered in-page by WebKit
        if !preloadedTeams.isEmpty {
            var seenIds = Set(teams.map { $0.id })
            for t in preloadedTeams {
                if !seenIds.contains(t.id) {
                    seenIds.insert(t.id)
                    teams.append(t)
                }
            }
        }

        // Set default team if not already set
        if devSession.selectedTeamId == nil, let firstTeam = teams.first {
            devSession.selectedTeamId = firstTeam.id
            devSession.selectedTeamName = firstTeam.name
        }

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
        request.setValue("olympus-ui", forHTTPHeaderField: "X-Requested-With")

        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

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
        var userEmail = appleId
        var defaultTeamId: String? = nil
        var defaultTeamName: String? = nil

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let user = json["user"] as? [String: Any] {
                if let email = user["emailAddress"] as? String, !email.isEmpty {
                    userEmail = email
                }
                let first = user["firstName"] as? String ?? ""
                let last = user["lastName"] as? String ?? ""
                let combined = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
                if !combined.isEmpty {
                    fullName = combined
                } else if !userEmail.isEmpty && userEmail != "Apple Developer Account" {
                    fullName = userEmail
                }
            }

            if let teamsArr = json["developerTeams"] as? [[String: Any]], let firstTeam = teamsArr.first {
                defaultTeamId = (firstTeam["teamId"] as? String) ?? (firstTeam["id"] as? String)
                defaultTeamName = firstTeam["name"] as? String
            }
        }

        let cookiesData = try? NSKeyedArchiver.archivedData(withRootObject: cookies, requiringSecureCoding: false)

        return AppleDeveloperSession(
            appleId: userEmail,
            userFullName: fullName,
            selectedTeamId: defaultTeamId,
            selectedTeamName: defaultTeamName,
            sessionToken: nil,
            cookiesData: cookiesData
        )
    }

    public func fetchDeveloperPortalTeams(session: URLSession, cookies: [HTTPCookie]) async -> [DeveloperTeam] {
        let endpointUrls = [
            "https://developer.apple.com/services-account/QH65B2/account/listTeams.action",
            "https://developerservices2.apple.com/services/QH65B2/listTeams.action"
        ]

        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        for urlString in endpointUrls {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue("https://developer.apple.com/account/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

            if !cookieHeader.isEmpty {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }

            for cookie in cookies {
                session.configuration.httpCookieStorage?.setCookie(cookie)
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    continue
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                let teamsRaw = (json["teams"] as? [[String: Any]]) ?? (json["developerTeams"] as? [[String: Any]]) ?? []
                var result: [DeveloperTeam] = []

                for item in teamsRaw {
                    let teamId = (item["teamId"] as? String) ?? (item["id"] as? String) ?? ""
                    let name = (item["name"] as? String) ?? (item["teamName"] as? String) ?? "Apple Developer Team"
                    let type = (item["type"] as? String) ?? "Company/Organization"
                    let status = (item["status"] as? String) ?? "active"

                    if !teamId.isEmpty {
                        result.append(DeveloperTeam(id: teamId, name: name, type: type, status: status))
                    }
                }

                if !result.isEmpty {
                    return result
                }
            } catch {
                continue
            }
        }

        return []
    }

    public func fetchOlympusTeams(session: URLSession, cookies: [HTTPCookie]) async -> [DeveloperTeam] {
        let url = olympusBase.appendingPathComponent("session")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("olympus-ui", forHTTPHeaderField: "X-Requested-With")

        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        for cookie in cookies {
            session.configuration.httpCookieStorage?.setCookie(cookie)
        }

        do {
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
        } catch {
            return []
        }
    }

    public func fetchTeams(session: URLSession, cookies: [HTTPCookie]) async throws -> [DeveloperTeam] {
        async let portalTeams = fetchDeveloperPortalTeams(session: session, cookies: cookies)
        async let olympusTeams = fetchOlympusTeams(session: session, cookies: cookies)

        let pTeams = await portalTeams
        let oTeams = await olympusTeams

        var combined: [DeveloperTeam] = []
        var seenIds = Set<String>()

        // Prioritize Developer Portal teams (company/organization accuracy)
        for t in pTeams {
            if !seenIds.contains(t.id) {
                seenIds.insert(t.id)
                combined.append(t)
            }
        }

        for t in oTeams {
            if !seenIds.contains(t.id) {
                seenIds.insert(t.id)
                combined.append(t)
            }
        }

        return combined
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

        var cookieList: [HTTPCookie] = []
        if let data = session.cookiesData,
           let unarchived = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, HTTPCookie.self], from: data) as? [HTTPCookie] {
            cookieList = unarchived
            for c in unarchived {
                sessionConfig.httpCookieStorage?.setCookie(c)
            }
        }

        // Set active team on Olympus if available
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
            registeredDeviceId = try? await registerDevice(
                urlSession: urlSession,
                device: device,
                team: team,
                cookies: cookieList,
                onLog: onLog
            )
        }

        // 2. Certificate Generation
        onStep?(.creatingCertificate)
        onLog?(LogMessage(level: .info, message: "Generating RSA keypair & requesting Development Certificate..."))

        let certResult = try await generateAndRequestCertificate(
            urlSession: urlSession,
            team: team,
            cookies: cookieList,
            onLog: onLog
        )

        // 3. Profile Generation
        onStep?(.creatingProfile)
        onLog?(LogMessage(level: .info, message: "Generating 365-day Wildcard Provisioning Profile..."))

        let profileData = try await createAndDownloadProfile(
            urlSession: urlSession,
            team: team,
            certId: certResult.certId,
            deviceId: registeredDeviceId,
            cookies: cookieList,
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

    // MARK: - Portal Network Helper

    private func makePortalRequest(
        url: URL,
        method: String = "POST",
        bodyParams: [String: String]? = nil,
        cookies: [HTTPCookie]
    ) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("https://developer.apple.com/account/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !cookieHeader.isEmpty {
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        if let params = bodyParams {
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            let bodyString = params.map { key, value in
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
                return "\(key)=\(encodedValue)"
            }.joined(separator: "&")
            req.httpBody = bodyString.data(using: .utf8)
        }

        return req
    }

    private func registerDevice(
        urlSession: URLSession,
        device: Device,
        team: DeveloperTeam,
        cookies: [HTTPCookie],
        onLog: (@Sendable (LogMessage) -> Void)?
    ) async throws -> String? {
        let addURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/device/addDevices.action")!
        let params: [String: String] = [
            "teamId": team.id,
            "deviceClasses": "iphone",
            "deviceNumbers": device.udid,
            "deviceNames": device.displayName,
            "register": "single"
        ]
        let req = makePortalRequest(url: addURL, method: "POST", bodyParams: params, cookies: cookies)

        if let (data, response) = try? await urlSession.data(for: req),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let devices = json["devices"] as? [[String: Any]], let first = devices.first,
               let id = (first["deviceId"] as? String) ?? (first["id"] as? String) {
                onLog?(LogMessage(level: .success, message: "Device registered in team '\(team.name)': \(device.displayName)"))
                return id
            }
        }

        // Check if device is already registered in team
        let listURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/device/listDevices.action")!
        let listReq = makePortalRequest(url: listURL, method: "POST", bodyParams: ["teamId": team.id, "pageSize": "500"], cookies: cookies)
        if let (listData, listResp) = try? await urlSession.data(for: listReq),
           let listHttp = listResp as? HTTPURLResponse, listHttp.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
           let devices = json["devices"] as? [[String: Any]] {
            if let match = devices.first(where: { ($0["deviceNumber"] as? String) == device.udid }),
               let id = (match["deviceId"] as? String) ?? (match["id"] as? String) {
                onLog?(LogMessage(level: .info, message: "Device already registered in team '\(team.name)' (ID: \(id))."))
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
        cookies: [HTTPCookie],
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

        onLog?(LogMessage(level: .verbose, message: "Generating RSA 2048 private key and CSR for \(team.name)..."))

        let csrGen = Process()
        csrGen.launchPath = "/usr/bin/openssl"
        csrGen.arguments = ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", keyPath, "-out", csrPath, "-subj", "/CN=Signet Development (\(team.id))"]
        try csrGen.run()
        csrGen.waitUntilExit()

        guard csrGen.terminationStatus == 0,
              let csrContent = try? String(contentsOfFile: csrPath, encoding: .utf8) else {
            throw AppleDeveloperError.opensslExecutionFailed("Could not generate CSR with /usr/bin/openssl")
        }

        onLog?(LogMessage(level: .info, message: "Requesting Development Certificate from Apple Developer Portal..."))

        // Certificate types: "83Q87W3TGH" (Apple Development), fallback "5QPB9NHCEI" (iOS Development)
        let certTypes = ["83Q87W3TGH", "5QPB9NHCEI"]
        var certId = ""
        var rawCerData: Data? = nil
        var lastErrorMessage = ""

        for certType in certTypes {
            let submitURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/certificate/submitCertificateRequest.action")!
            let params = [
                "teamId": team.id,
                "type": certType,
                "csrContent": csrContent
            ]
            let req = makePortalRequest(url: submitURL, method: "POST", bodyParams: params, cookies: cookies)

            if let (data, response) = try? await urlSession.data(for: req),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                if let certReq = json["certRequest"] as? [String: Any] {
                    let id = (certReq["certificateId"] as? String) ??
                             ((certReq["certificate"] as? [String: Any])?["certificateId"] as? String) ?? ""
                    if !id.isEmpty {
                        certId = id
                    }
                    if let contentStr = (certReq["certContent"] as? String) ??
                                        ((certReq["certificate"] as? [String: Any])?["certContent"] as? String) {
                        rawCerData = contentStr.data(using: .utf8) ?? Data(base64Encoded: contentStr)
                    }
                }

                // If certificateId exists but certContent wasn't in response, download directly
                if !certId.isEmpty && rawCerData == nil {
                    let dlURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/certificate/downloadCertificateContent.action?teamId=\(team.id)&certificateId=\(certId)&type=\(certType)")!
                    let dlReq = makePortalRequest(url: dlURL, method: "GET", cookies: cookies)
                    if let (dlData, dlResp) = try? await urlSession.data(for: dlReq),
                       let dlHttp = dlResp as? HTTPURLResponse, dlHttp.statusCode == 200, !dlData.isEmpty {
                        rawCerData = dlData
                    }
                }

                if rawCerData != nil {
                    onLog?(LogMessage(level: .success, message: "Development certificate successfully issued: ID \(certId)"))
                    break
                }

                if let userStr = json["userString"] as? String {
                    lastErrorMessage = userStr
                }
            }
        }

        // If creation failed or limit reached, search for existing active certificates in the team
        if rawCerData == nil {
            onLog?(LogMessage(level: .info, message: "Checking for existing certificates in team '\(team.name)'..."))
            let listURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/certificate/listCertRequests.action")!
            let listParams = [
                "teamId": team.id,
                "types": "83Q87W3TGH,5QPB9NHCEI",
                "pageNumber": "1",
                "pageSize": "500",
                "sort": "certRequestStatusCode=asc"
            ]
            let listReq = makePortalRequest(url: listURL, method: "POST", bodyParams: listParams, cookies: cookies)

            if let (listData, listResp) = try? await urlSession.data(for: listReq),
               let listHttp = listResp as? HTTPURLResponse, listHttp.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
               let certs = json["certRequests"] as? [[String: Any]] {

                let activeCerts = certs.filter {
                    ($0["statusString"] as? String) == "Issued" ||
                    ($0["canDownload"] as? Bool) == true
                }

                if let existing = activeCerts.first,
                   let existingId = existing["certificateId"] as? String {
                    let existingType = (existing["certificateTypeDisplayId"] as? String) ?? "83Q87W3TGH"
                    let dlURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/certificate/downloadCertificateContent.action?teamId=\(team.id)&certificateId=\(existingId)&type=\(existingType)")!
                    let dlReq = makePortalRequest(url: dlURL, method: "GET", cookies: cookies)

                    if let (dlData, dlResp) = try? await urlSession.data(for: dlReq),
                       let dlHttp = dlResp as? HTTPURLResponse, dlHttp.statusCode == 200, !dlData.isEmpty {
                        certId = existingId
                        rawCerData = dlData
                        onLog?(LogMessage(level: .info, message: "Retrieved existing certificate from Apple (ID: \(existingId))."))
                    }
                }
            }
        }

        guard let cerBytes = rawCerData, !cerBytes.isEmpty else {
            let detail = lastErrorMessage.isEmpty ? "Could not obtain certificate content from Apple." : lastErrorMessage
            throw AppleDeveloperError.certificateCreationFailed(detail)
        }

        try cerBytes.write(to: URL(fileURLWithPath: certDerPath))

        // Convert DER to PEM
        _ = runOpenssl(["x509", "-inform", "der", "-in", certDerPath, "-out", certPemPath])
        if !FileManager.default.fileExists(atPath: certPemPath) || (try? FileManager.default.attributesOfItem(atPath: certPemPath)[.size] as? Int) == 0 {
            try? cerBytes.write(to: URL(fileURLWithPath: certPemPath))
        }

        let p12Success = runOpenssl(["pkcs12", "-export", "-out", p12Path, "-inkey", keyPath, "-in", certPemPath, "-password", "pass:\(password)"])
        guard p12Success, FileManager.default.fileExists(atPath: p12Path) else {
            throw AppleDeveloperError.certificateCreationFailed("Failed to package certificate and private key into PKCS#12 (.p12). If your team's certificate limit was reached, revoke an unused certificate on developer.apple.com so Signet can generate a fresh matching keypair.")
        }

        let p12Data = try Data(contentsOf: URL(fileURLWithPath: p12Path))
        return CertPackage(certId: certId, p12Data: p12Data, password: password)
    }

    private func createAndDownloadProfile(
        urlSession: URLSession,
        team: DeveloperTeam,
        certId: String,
        deviceId: String?,
        cookies: [HTTPCookie],
        onLog: (@Sendable (LogMessage) -> Void)?
    ) async throws -> Data {
        onLog?(LogMessage(level: .info, message: "Checking for existing Wildcard profiles via Xcode API..."))

        // 1. Try Xcode API for instant profile retrieval (contains base64 encodedProfile)
        let xcodeURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/ios/listProvisioningProfiles.action")!
        let xcodeParams = [
            "teamId": team.id,
            "includeInactiveProfiles": "true",
            "includeExpiredProfiles": "false",
            "onlyCountLists": "true"
        ]
        let xcodeReq = makePortalRequest(url: xcodeURL, method: "POST", bodyParams: xcodeParams, cookies: cookies)

        if let (xcData, xcResp) = try? await urlSession.data(for: xcodeReq),
           let xcHttp = xcResp as? HTTPURLResponse, xcHttp.statusCode == 200,
           let plist = try? PropertyListSerialization.propertyList(from: xcData, options: [], format: nil) as? [String: Any],
           let profiles = plist["provisioningProfiles"] as? [[String: Any]] {

            for prof in profiles {
                if let encodedData = prof["encodedProfile"] as? Data {
                    onLog?(LogMessage(level: .success, message: "Retrieved Wildcard Provisioning Profile via Xcode API!"))
                    return encodedData
                } else if let b64Str = prof["encodedProfile"] as? String, let decoded = Data(base64Encoded: b64Str) {
                    onLog?(LogMessage(level: .success, message: "Retrieved Wildcard Provisioning Profile via Xcode API!"))
                    return decoded
                }
            }
        }

        // 2. Find or create App ID (Bundle ID)
        onLog?(LogMessage(level: .info, message: "Ensuring Wildcard App ID exists on Apple Developer Portal..."))
        let listAppIdsURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/identifiers/listAppIds.action")!
        let listAppReq = makePortalRequest(url: listAppIdsURL, method: "POST", bodyParams: ["teamId": team.id, "pageSize": "500"], cookies: cookies)

        var appIdId = ""
        if let (appData, appResp) = try? await urlSession.data(for: listAppReq),
           let appHttp = appResp as? HTTPURLResponse, appHttp.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: appData) as? [String: Any],
           let appIds = json["appIds"] as? [[String: Any]] {
            if let wildcard = appIds.first(where: {
                ($0["isWildcard"] as? Bool) == true ||
                (($0["identifier"] as? String)?.hasSuffix("*") == true)
            }) {
                appIdId = (wildcard["appIdId"] as? String) ?? (wildcard["id"] as? String) ?? ""
            } else if let firstApp = appIds.first {
                appIdId = (firstApp["appIdId"] as? String) ?? (firstApp["id"] as? String) ?? ""
            }
        }

        // If no wildcard App ID exists, create one
        if appIdId.isEmpty {
            onLog?(LogMessage(level: .info, message: "Registering new Wildcard App ID (*)..."))
            let addAppURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/identifiers/addAppId.action")!
            let addAppParams = [
                "teamId": team.id,
                "name": "Signet Wildcard",
                "type": "wildcard",
                "identifier": "*"
            ]
            let addAppReq = makePortalRequest(url: addAppURL, method: "POST", bodyParams: addAppParams, cookies: cookies)
            if let (addData, addResp) = try? await urlSession.data(for: addAppReq),
               let addHttp = addResp as? HTTPURLResponse, addHttp.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: addData) as? [String: Any],
               let appObj = json["appId"] as? [String: Any] {
                appIdId = (appObj["appIdId"] as? String) ?? (appObj["id"] as? String) ?? ""
            }
        }

        // 3. Create or download Provisioning Profile via Developer Portal
        let profName = "Signet Wildcard \(Int.random(in: 100...999))"
        let createProfURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/profile/createProvisioningProfile.action")!
        var createParams: [String: String] = [
            "teamId": team.id,
            "provisioningProfileName": profName,
            "distributionType": "limited",
            "certificateIds": certId
        ]
        if !appIdId.isEmpty {
            createParams["appIdId"] = appIdId
        }
        if let dId = deviceId {
            createParams["deviceIds"] = dId
        }

        let createProfReq = makePortalRequest(url: createProfURL, method: "POST", bodyParams: createParams, cookies: cookies)

        var profileId = ""
        if let (cData, cResp) = try? await urlSession.data(for: createProfReq),
           let cHttp = cResp as? HTTPURLResponse, cHttp.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: cData) as? [String: Any],
           let profObj = json["provisioningProfile"] as? [String: Any] {
            profileId = (profObj["provisioningProfileId"] as? String) ?? (profObj["id"] as? String) ?? ""
            if let b64 = profObj["encodedProfile"] as? String, let decoded = Data(base64Encoded: b64) {
                onLog?(LogMessage(level: .success, message: "Profile created: \(profName)"))
                return decoded
            }
        }

        // 4. Download profile content if created
        if !profileId.isEmpty {
            let dlURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/profile/downloadProfileContent?teamId=\(team.id)&provisioningProfileId=\(profileId)")!
            let dlReq = makePortalRequest(url: dlURL, method: "GET", cookies: cookies)
            if let (dlData, dlResp) = try? await urlSession.data(for: dlReq),
               let dlHttp = dlResp as? HTTPURLResponse, dlHttp.statusCode == 200, !dlData.isEmpty {
                onLog?(LogMessage(level: .success, message: "Downloaded profile: \(profName)"))
                return dlData
            }
        }

        // 5. Fallback: check existing profiles on portal
        let listProfURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/profile/listProvisioningProfiles.action")!
        let listProfReq = makePortalRequest(url: listProfURL, method: "POST", bodyParams: ["teamId": team.id, "pageSize": "500"], cookies: cookies)
        if let (lData, lResp) = try? await urlSession.data(for: listProfReq),
           let lHttp = lResp as? HTTPURLResponse, lHttp.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: lData) as? [String: Any],
           let profiles = json["provisioningProfiles"] as? [[String: Any]] {
            for prof in profiles {
                if let pId = prof["provisioningProfileId"] as? String {
                    let dlURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/profile/downloadProfileContent?teamId=\(team.id)&provisioningProfileId=\(pId)")!
                    let dlReq = makePortalRequest(url: dlURL, method: "GET", cookies: cookies)
                    if let (dlData, dlResp) = try? await urlSession.data(for: dlReq),
                       let dlHttp = dlResp as? HTTPURLResponse, dlHttp.statusCode == 200, !dlData.isEmpty {
                        onLog?(LogMessage(level: .info, message: "Downloaded active team profile."))
                        return dlData
                    }
                }
            }
        }

        throw AppleDeveloperError.profileCreationFailed("Failed to generate or download Provisioning Profile from Apple Developer Portal.")
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
