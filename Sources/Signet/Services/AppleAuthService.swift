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

    // MARK: - Cookie Encoding / Decoding Helpers

    public static func encodeCookies(_ cookies: [HTTPCookie]) -> Data? {
        var rawList: [[String: String]] = []
        for c in cookies {
            var dict: [String: String] = [:]
            dict["name"] = c.name
            dict["value"] = c.value
            dict["domain"] = c.domain
            dict["path"] = c.path
            if let exp = c.expiresDate {
                dict["expires"] = String(exp.timeIntervalSince1970)
            }
            dict["isSecure"] = c.isSecure ? "true" : "false"
            rawList.append(dict)
        }
        return try? JSONSerialization.data(withJSONObject: rawList, options: [])
    }

    public static func decodeCookies(from data: Data) -> [HTTPCookie] {
        // 1. Try modern JSON deserialization
        if let rawList = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] {
            var cookies: [HTTPCookie] = []
            for dict in rawList {
                guard let name = dict["name"], let value = dict["value"],
                      let domain = dict["domain"], let path = dict["path"] else { continue }
                var props: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: domain,
                    .path: path
                ]
                if let expStr = dict["expires"], let expTime = Double(expStr) {
                    props[.expires] = Date(timeIntervalSince1970: expTime)
                }
                if dict["isSecure"] == "true" {
                    props[.secure] = true
                }
                if let cookie = HTTPCookie(properties: props) {
                    cookies.append(cookie)
                }
            }
            if !cookies.isEmpty {
                return cookies
            }
        }

        // 2. Legacy NSKeyedUnarchiver support
        if let unarchived = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? [HTTPCookie] {
            return unarchived
        }
        if let unarchived = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, HTTPCookie.self], from: data) as? [HTTPCookie] {
            return unarchived
        }

        return []
    }


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
                cookiesData: AppleAuthService.encodeCookies(cookies)
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

        let cookiesData = AppleAuthService.encodeCookies(cookies)

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
        autoRevokeIfLimitReached: Bool = true,
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
        if let data = session.cookiesData {
            cookieList = AppleAuthService.decodeCookies(from: data)
            for c in cookieList {
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

        // Select team on Developer Portal
        await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: cookieList)

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

        // 2. Certificate Resolution (Local Keychain Check First, then Portal Request)
        onStep?(.creatingCertificate)

        let localIdentities = findLocalKeychainIdentities()
        let matchingLocal = localIdentities.first { id in
            if let tId = id.teamId, tId.caseInsensitiveCompare(team.id) == .orderedSame {
                return true
            }
            if let tName = id.teamName, !tName.isEmpty,
               team.name.localizedCaseInsensitiveContains(tName) || tName.localizedCaseInsensitiveContains(team.name) {
                return true
            }
            return false
        }

        var certResult: CertPackage? = nil
        if let local = matchingLocal {
            onLog?(LogMessage(level: .info, message: "Discovered active Keychain identity '\(local.name)' matching team '\(team.name)'!"))
            onLog?(LogMessage(level: .info, message: "Exporting matching local certificate to bypass Apple team limits..."))
            let pwd = "SignetLocalPass\(Int.random(in: 100000...999999))"
            if let p12Data = try? exportKeychainIdentity(identityName: local.name, password: pwd) {
                // Find matching certificateId on portal if possible
                let portalCerts = (try? await fetchPortalCertificates(session: session, team: team)) ?? []
                let matchingCert = portalCerts.first(where: {
                    $0.isIssued && (local.name.contains($0.name) || $0.name.contains(local.name) || ($0.ownerName != nil && local.name.contains($0.ownerName!)))
                }) ?? portalCerts.first(where: { $0.isIssued })
                let cId = matchingCert?.id ?? "LOCAL_CERT"
                certResult = CertPackage(certId: cId, p12Data: p12Data, password: pwd)
                onLog?(LogMessage(level: .success, message: "Successfully prepared local developer identity for code signing."))
            } else {
                onLog?(LogMessage(level: .warning, message: "Could not export local identity from Keychain. Falling back to fresh certificate request..."))
            }
        }

        if certResult == nil {
            onLog?(LogMessage(level: .info, message: "Generating RSA keypair & requesting Development Certificate from Apple..."))
            certResult = try await generateAndRequestCertificate(
                urlSession: urlSession,
                team: team,
                cookies: cookieList,
                autoRevokeIfLimitReached: autoRevokeIfLimitReached,
                onLog: onLog
            )
        }

        guard let resolvedCert = certResult else {
            throw AppleDeveloperError.certificateCreationFailed("Could not obtain or export a valid Apple Development certificate.")
        }

        // 3. Profile Generation
        onStep?(.creatingProfile)
        onLog?(LogMessage(level: .info, message: "Generating or downloading 365-day Wildcard Provisioning Profile..."))

        let profileData = try await createAndDownloadProfile(
            urlSession: urlSession,
            team: team,
            certId: resolvedCert.certId,
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
        try resolvedCert.p12Data.write(to: p12Path)
        let certInfo = try credentialService.importAndSaveP12(from: p12Path, password: resolvedCert.password)

        onStep?(.success(message: "Auto-provisioning complete! 365-day developer certificate & wildcard profile active."))
        onLog?(LogMessage(level: .success, message: "Certificate (\(certInfo.teamName)) & Profile (\(profileInfo.name)) successfully configured!"))

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
        autoRevokeIfLimitReached: Bool = true,
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
            onLog?(LogMessage(level: .info, message: "Checking certificates in team '\(team.name)' (\(lastErrorMessage.isEmpty ? "No certificate returned" : lastErrorMessage))..."))

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

                if autoRevokeIfLimitReached && !activeCerts.isEmpty {
                    // Sideloadly behavior: prioritize revoking previous Signet cert or oldest dev cert
                    let candidate = activeCerts.first(where: {
                        (($0["name"] as? String) ?? "").localizedCaseInsensitiveContains("Signet")
                    }) ?? activeCerts.last!

                    let candId = (candidate["certificateId"] as? String) ?? (candidate["certRequestId"] as? String) ?? ""
                    let candType = (candidate["certificateTypeDisplayId"] as? String) ?? "83Q87W3TGH"
                    let candName = (candidate["name"] as? String) ?? "Apple Development"

                    onLog?(LogMessage(level: .warning, message: "Team certificate limit reached on Apple Developer Portal. Automatically revoking '\(candName)' (ID: \(candId)) to make room for Signet keypair (matching Sideloadly behavior)..."))

                    let revoked = (try? await revokePortalCertificate(urlSession: urlSession, team: team, certificateId: candId, type: candType, cookies: cookies)) ?? false
                    if revoked {
                        onLog?(LogMessage(level: .success, message: "Revocation complete. Requesting fresh certificate with new keypair..."))
                        try? await Task.sleep(nanoseconds: 1_200_000_000)

                        for certType in certTypes {
                            let submitURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/certificate/submitCertificateRequest.action")!
                            let params = [
                                "teamId": team.id,
                                "type": certType,
                                "csrContent": csrContent
                            ]
                            let req = makePortalRequest(url: submitURL, method: "POST", bodyParams: params, cookies: cookies)

                            if let (rData, rResp) = try? await urlSession.data(for: req),
                               let rHttp = rResp as? HTTPURLResponse, rHttp.statusCode == 200,
                               let rJson = try? JSONSerialization.jsonObject(with: rData) as? [String: Any] {

                                if let certReq = rJson["certRequest"] as? [String: Any] {
                                    let id = (certReq["certificateId"] as? String) ??
                                             ((certReq["certificate"] as? [String: Any])?["certificateId"] as? String) ?? ""
                                    if !id.isEmpty { certId = id }

                                    if let contentStr = (certReq["certContent"] as? String) ??
                                                        ((certReq["certificate"] as? [String: Any])?["certContent"] as? String) {
                                        rawCerData = contentStr.data(using: .utf8) ?? Data(base64Encoded: contentStr)
                                    }
                                }

                                if !certId.isEmpty && rawCerData == nil {
                                    let dlURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/certificate/downloadCertificateContent.action?teamId=\(team.id)&certificateId=\(certId)&type=\(certType)")!
                                    let dlReq = makePortalRequest(url: dlURL, method: "GET", cookies: cookies)
                                    if let (dlData, dlResp) = try? await urlSession.data(for: dlReq),
                                       let dlHttp = dlResp as? HTTPURLResponse, dlHttp.statusCode == 200, !dlData.isEmpty {
                                        rawCerData = dlData
                                    }
                                }

                                if rawCerData != nil {
                                    onLog?(LogMessage(level: .success, message: "Fresh Development certificate issued: ID \(certId)"))
                                    break
                                }
                            }
                        }
                    }
                }
            }
        }

        guard let cerBytes = rawCerData, !cerBytes.isEmpty else {
            let detail = lastErrorMessage.isEmpty ? "Could not obtain matching certificate from Apple. If your team's limit was reached, use the Portal Manager tab to revoke an unused certificate." : lastErrorMessage
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
            throw AppleDeveloperError.certificateCreationFailed("Failed to package certificate and private key into PKCS#12 (.p12). If your team's certificate limit was reached, revoke an unused certificate on developer.apple.com or in Portal Manager.")
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

    // MARK: - Portal Management APIs

    public func makeSession(from session: AppleDeveloperSession) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let urlSession = URLSession(configuration: config)
        for c in extractCookies(from: session) {
            config.httpCookieStorage?.setCookie(c)
        }
        return urlSession
    }

    public func extractCookies(from session: AppleDeveloperSession) -> [HTTPCookie] {
        guard let data = session.cookiesData else { return [] }
        return AppleAuthService.decodeCookies(from: data)
    }

    private func selectPortalTeam(
        urlSession: URLSession,
        teamId: String,
        cookies: [HTTPCookie]
    ) async {
        let selectURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/selectTeam.action")!
        let req = makePortalRequest(url: selectURL, method: "POST", bodyParams: ["teamId": teamId], cookies: cookies)
        _ = try? await urlSession.data(for: req)
    }

    private func parsePortalResponse(_ data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            return plist
        }
        return nil
    }

    // Devices
    public func fetchPortalDevices(
        session: AppleDeveloperSession,
        team: DeveloperTeam
    ) async throws -> [PortalDevice] {
        let urlSession = makeSession(from: session)
        let cookies = extractCookies(from: session)
        await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: cookies)

        let listURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/device/listDevices.action")!
        let req = makePortalRequest(url: listURL, method: "POST", bodyParams: ["teamId": team.id, "pageSize": "500"], cookies: cookies)

        if let (data, response) = try? await urlSession.data(for: req),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let dict = parsePortalResponse(data),
           let devices = dict["devices"] as? [[String: Any]], !devices.isEmpty {
            return parseDevices(devices)
        }

        // Fallback to Xcode endpoint
        let xcURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/ios/listDevices.action")!
        let xcReq = makePortalRequest(url: xcURL, method: "POST", bodyParams: ["teamId": team.id, "pageSize": "500"], cookies: cookies)
        if let (data, response) = try? await urlSession.data(for: xcReq),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let dict = parsePortalResponse(data),
           let devices = dict["devices"] as? [[String: Any]] {
            return parseDevices(devices)
        }

        return []
    }

    private func parseDevices(_ devices: [[String: Any]]) -> [PortalDevice] {
        var result: [PortalDevice] = []
        for d in devices {
            let id = (d["deviceId"] as? String) ?? (d["id"] as? String) ?? ""
            let name = (d["name"] as? String) ?? "Unnamed Device"
            let udid = (d["deviceNumber"] as? String) ?? ""
            let dClass = (d["deviceClass"] as? String) ?? "iphone"
            let model = d["model"] as? String
            let status = (d["status"] as? String) ?? "Y"
            if !id.isEmpty && !udid.isEmpty {
                result.append(PortalDevice(id: id, name: name, udid: udid, deviceClass: dClass, model: model, status: status))
            }
        }
        return result
    }

    public func deletePortalDevice(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        deviceId: String
    ) async throws -> Bool {
        let urlSession = makeSession(from: session)
        let cookies = extractCookies(from: session)
        await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: cookies)

        let deleteURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/device/deleteDevice.action")!
        let req = makePortalRequest(url: deleteURL, method: "POST", bodyParams: ["teamId": team.id, "deviceId": deviceId], cookies: cookies)

        if let (data, response) = try? await urlSession.data(for: req),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let json = parsePortalResponse(data),
           let code = json["resultCode"] as? Int, code == 0 {
            return true
        }

        let disableURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/device/disableDevice.action")!
        let disableReq = makePortalRequest(url: disableURL, method: "POST", bodyParams: ["teamId": team.id, "deviceId": deviceId], cookies: cookies)
        if let (data, response) = try? await urlSession.data(for: disableReq),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let json = parsePortalResponse(data),
           let code = json["resultCode"] as? Int, code == 0 {
            return true
        }

        return false
    }

    public func registerPortalDeviceManual(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        name: String,
        udid: String,
        deviceClass: String = "iphone"
    ) async throws -> PortalDevice {
        let urlSession = makeSession(from: session)
        let cookies = extractCookies(from: session)
        await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: cookies)

        let addURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/device/addDevices.action")!
        let params: [String: String] = [
            "teamId": team.id,
            "deviceClasses": deviceClass,
            "deviceNumbers": udid,
            "deviceNames": name,
            "register": "single"
        ]
        let req = makePortalRequest(url: addURL, method: "POST", bodyParams: params, cookies: cookies)
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = parsePortalResponse(data) else {
            throw AppleDeveloperError.apiError("Failed to register device with Apple Developer Portal.")
        }

        if let devices = json["devices"] as? [[String: Any]], let first = devices.first,
           let id = (first["deviceId"] as? String) ?? (first["id"] as? String) {
            return PortalDevice(id: id, name: name, udid: udid, deviceClass: deviceClass, model: first["model"] as? String, status: "Y")
        }

        if let userStr = json["userString"] as? String {
            throw AppleDeveloperError.apiError(userStr)
        }

        throw AppleDeveloperError.apiError("Could not register device in team.")
    }

    // Certificates
    public func fetchPortalCertificates(
        session: AppleDeveloperSession,
        team: DeveloperTeam
    ) async throws -> [PortalCertificate] {
        let urlSession = makeSession(from: session)
        let cookies = extractCookies(from: session)
        await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: cookies)

        let listURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/certificate/listCertRequests.action")!
        let params = [
            "teamId": team.id,
            "types": "83Q87W3TGH,5QPB9NHCEI,R851327ND5,99Q9982463",
            "pageNumber": "1",
            "pageSize": "500",
            "sort": "certRequestStatusCode=asc"
        ]
        let req = makePortalRequest(url: listURL, method: "POST", bodyParams: params, cookies: cookies)
        if let (data, response) = try? await urlSession.data(for: req),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let dict = parsePortalResponse(data),
           let certs = (dict["certRequests"] as? [[String: Any]]) ?? (dict["certificates"] as? [[String: Any]]), !certs.isEmpty {
            return parseCerts(certs)
        }

        // Fallback to Xcode endpoint
        let xcURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/ios/listAllDevelopmentCerts.action")!
        let xcReq = makePortalRequest(url: xcURL, method: "POST", bodyParams: ["teamId": team.id], cookies: cookies)
        if let (data, response) = try? await urlSession.data(for: xcReq),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let dict = parsePortalResponse(data),
           let certs = (dict["certRequests"] as? [[String: Any]]) ?? (dict["certificates"] as? [[String: Any]]) {
            return parseCerts(certs)
        }

        return []
    }

    private func parseCerts(_ certs: [[String: Any]]) -> [PortalCertificate] {
        var result: [PortalCertificate] = []
        for c in certs {
            let id = (c["certificateId"] as? String) ?? (c["certRequestId"] as? String) ?? ""
            let name = (c["name"] as? String) ?? (c["ownerName"] as? String) ?? "Apple Development"
            let type = (c["certificateTypeDisplayId"] as? String) ?? (c["type"] as? String) ?? "83Q87W3TGH"
            let typeDisplayName = (c["typeDisplayName"] as? String) ?? "Apple Development"
            let status = (c["statusString"] as? String) ?? "Issued"
            let exp = c["expirationDate"] as? String
            let canDl = (c["canDownload"] as? Bool) ?? true
            let canRev = (c["canRevoke"] as? Bool) ?? true
            let owner = c["ownerName"] as? String
            if !id.isEmpty {
                result.append(PortalCertificate(
                    id: id,
                    name: name,
                    type: type,
                    typeDisplayName: typeDisplayName,
                    status: status,
                    expirationDate: exp,
                    canDownload: canDl,
                    canRevoke: canRev,
                    ownerName: owner
                ))
            }
        }
        return result
    }

    public func revokePortalCertificate(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        certificateId: String,
        type: String
    ) async throws -> Bool {
        let urlSession = makeSession(from: session)
        let cookies = extractCookies(from: session)
        return try await revokePortalCertificate(urlSession: urlSession, team: team, certificateId: certificateId, type: type, cookies: cookies)
    }

    public func revokePortalCertificate(
        urlSession: URLSession,
        team: DeveloperTeam,
        certificateId: String,
        type: String,
        cookies: [HTTPCookie]
    ) async throws -> Bool {
        await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: cookies)
        let revokeURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/certificate/revokeCertificate.action")!
        let params = [
            "teamId": team.id,
            "certificateId": certificateId,
            "type": type
        ]
        let req = makePortalRequest(url: revokeURL, method: "POST", bodyParams: params, cookies: cookies)
        guard let (data, response) = try? await urlSession.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = parsePortalResponse(data) else {
            return false
        }
        let code = (json["resultCode"] as? Int) ?? -1
        return code == 0
    }

    public func downloadPortalCertificate(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        certificateId: String,
        type: String
    ) async throws -> Data {
        let urlSession = makeSession(from: session)
        let cookies = extractCookies(from: session)
        await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: cookies)
        let dlURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/certificate/downloadCertificateContent.action?teamId=\(team.id)&certificateId=\(certificateId)&type=\(type)")!
        let req = makePortalRequest(url: dlURL, method: "GET", cookies: cookies)
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            throw AppleDeveloperError.apiError("Failed to download certificate from Apple Developer Portal.")
        }
        return data
    }

    public func fetchTeamWildcardProfile(
        session: AppleDeveloperSession,
        team: DeveloperTeam
    ) async -> Data? {
        let urlSession = makeSession(from: session)
        let cookies = extractCookies(from: session)
        await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: cookies)

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
                    return encodedData
                } else if let b64Str = prof["encodedProfile"] as? String, let decoded = Data(base64Encoded: b64Str) {
                    return decoded
                }
            }
        }
        return nil
    }

    // App IDs
    public func fetchPortalAppIds(
        session: AppleDeveloperSession,
        team: DeveloperTeam
    ) async throws -> [PortalAppId] {
        let urlSession = makeSession(from: session)
        let cookies = extractCookies(from: session)
        await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: cookies)

        let listURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/identifiers/listAppIds.action")!
        let req = makePortalRequest(url: listURL, method: "POST", bodyParams: ["teamId": team.id, "pageSize": "500"], cookies: cookies)
        if let (data, response) = try? await urlSession.data(for: req),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let dict = parsePortalResponse(data),
           let appIds = dict["appIds"] as? [[String: Any]], !appIds.isEmpty {
            return parseAppIds(appIds, teamId: team.id)
        }

        // Fallback to Xcode endpoint
        let xcURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/ios/listAppIds.action")!
        let xcReq = makePortalRequest(url: xcURL, method: "POST", bodyParams: ["teamId": team.id, "pageSize": "500"], cookies: cookies)
        if let (data, response) = try? await urlSession.data(for: xcReq),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let dict = parsePortalResponse(data),
           let appIds = dict["appIds"] as? [[String: Any]] {
            return parseAppIds(appIds, teamId: team.id)
        }

        return []
    }

    private func parseAppIds(_ appIds: [[String: Any]], teamId: String) -> [PortalAppId] {
        var result: [PortalAppId] = []
        for a in appIds {
            let id = (a["appIdId"] as? String) ?? (a["id"] as? String) ?? ""
            let name = (a["name"] as? String) ?? "Unnamed App ID"
            let identifier = (a["identifier"] as? String) ?? ""
            let prefix = (a["prefix"] as? String) ?? teamId
            let isWildcard = (a["isWildcard"] as? Bool) ?? (identifier.contains("*"))
            if !id.isEmpty && !identifier.isEmpty {
                result.append(PortalAppId(id: id, name: name, identifier: identifier, prefix: prefix, isWildcard: isWildcard))
            }
        }
        return result
    }

    public func deletePortalAppId(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        appIdId: String
    ) async throws -> Bool {
        let urlSession = makeSession(from: session)
        let cookies = extractCookies(from: session)
        await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: cookies)

        let deleteURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/identifiers/deleteAppId.action")!
        let req = makePortalRequest(url: deleteURL, method: "POST", bodyParams: ["teamId": team.id, "appIdId": appIdId], cookies: cookies)
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = parsePortalResponse(data),
              let code = json["resultCode"] as? Int else {
            return false
        }
        return code == 0
    }

    public func createPortalAppId(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        name: String,
        identifier: String
    ) async throws -> PortalAppId {
        let urlSession = makeSession(from: session)
        let cookies = extractCookies(from: session)
        await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: cookies)

        let addURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/identifiers/addAppId.action")!
        let type = identifier.contains("*") ? "wildcard" : "explicit"
        let params = [
            "teamId": team.id,
            "name": name,
            "identifier": identifier,
            "type": type
        ]
        let req = makePortalRequest(url: addURL, method: "POST", bodyParams: params, cookies: cookies)
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = parsePortalResponse(data) else {
            throw AppleDeveloperError.apiError("Failed to register App ID.")
        }

        if let appId = json["appId"] as? [String: Any],
           let id = (appId["appIdId"] as? String) ?? (appId["id"] as? String) {
            return PortalAppId(id: id, name: name, identifier: identifier, prefix: team.id, isWildcard: identifier.contains("*"))
        }

        if let userStr = json["userString"] as? String {
            throw AppleDeveloperError.apiError(userStr)
        }

        throw AppleDeveloperError.apiError("Could not create App ID in team.")
    }

    // MARK: - Keychain & Local Identity Export

    private func getCertificateSubjectDetails(forCommonName commonName: String) -> (teamId: String?, teamName: String?)? {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = [
            "-c",
            "/usr/bin/security find-certificate -c \"\(commonName)\" -p 2>/dev/null | /usr/bin/openssl x509 -subject -noout 2>/dev/null"
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return nil }

            var teamId: String? = nil
            var teamName: String? = nil

            let parts = output.components(separatedBy: "/")
            for part in parts {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("OU=") {
                    let val = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty { teamId = val }
                } else if trimmed.hasPrefix("O=") {
                    let val = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty { teamName = val }
                }
            }
            return (teamId, teamName)
        } catch {
            return nil
        }
    }

    public func findLocalKeychainIdentities() -> [KeychainIdentity] {
        let task = Process()
        task.launchPath = "/usr/bin/security"
        task.arguments = ["find-identity", "-p", "codesigning", "-v"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }

            var identities: [KeychainIdentity] = []
            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let quoteStart = trimmed.firstIndex(of: "\""),
                      let quoteEnd = trimmed.lastIndex(of: "\""),
                      quoteStart < quoteEnd else { continue }

                let name = String(trimmed[trimmed.index(after: quoteStart)..<quoteEnd])
                let prefix = trimmed[..<quoteStart].trimmingCharacters(in: .whitespaces)
                let parts = prefix.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                let fingerprint = parts.count >= 2 ? parts[1] : (parts.first ?? "")

                var teamId: String? = nil
                var teamName: String? = nil

                if let details = getCertificateSubjectDetails(forCommonName: name) {
                    teamId = details.teamId
                    teamName = details.teamName
                }

                if teamId == nil, let openParen = name.lastIndex(of: "("), let closeParen = name.lastIndex(of: ")"), openParen < closeParen {
                    teamId = String(name[name.index(after: openParen)..<closeParen])
                }

                identities.append(KeychainIdentity(id: fingerprint, name: name, teamId: teamId, teamName: teamName))
            }
            return identities
        } catch {
            return []
        }
    }

    public func exportKeychainIdentity(
        identityName: String,
        password: String
    ) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let list = result as? [SecIdentity] else {
            throw AppleDeveloperError.certificateCreationFailed("Could not access macOS Keychain identities (status \(status)).")
        }

        var matchedIdentity: SecIdentity?
        for identity in list {
            var cert: SecCertificate?
            SecIdentityCopyCertificate(identity, &cert)
            guard let cert = cert else { continue }
            var commonName: CFString?
            SecCertificateCopyCommonName(cert, &commonName)
            let name = commonName as String? ?? ""
            if name == identityName || name.contains(identityName) || identityName.contains(name) {
                matchedIdentity = identity
                break
            }
        }

        guard let identityToExport = matchedIdentity else {
            throw AppleDeveloperError.certificateCreationFailed("Could not find identity '\(identityName)' in macOS Keychain.")
        }

        var exportData: CFData?
        var keyParams = SecItemImportExportKeyParameters()
        keyParams.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        let pass = password as CFString
        keyParams.passphrase = Unmanaged.passRetained(pass)

        let expStatus = SecItemExport(identityToExport, .formatPKCS12, [], &keyParams, &exportData)
        guard expStatus == errSecSuccess, let data = exportData as Data?, !data.isEmpty else {
            throw AppleDeveloperError.certificateCreationFailed("Keychain export returned error \(expStatus). Please allow keychain access when prompted.")
        }

        return data
    }
}
