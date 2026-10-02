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

        // 2. NSKeyedUnarchiver support
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
        preloadedTeams: [DeveloperTeam] = [],
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> (session: AppleDeveloperSession, teams: [DeveloperTeam]) {
        let (session, _) = makeSession(cookies: cookies)
        logCookieSummary(cookies: cookies, onLog: onLog)

        var devSession = try await fetchOlympusSession(session: session, cookies: cookies, appleId: "Apple Developer Account")
        var teams = try await fetchTeams(session: session, cookies: cookies, onLog: onLog)

        // Merge any preloaded teams discovered in-page by WebKit
        if !preloadedTeams.isEmpty {
            onLog?(LogMessage(level: .info, message: "[Portal] Merging \(preloadedTeams.count) team(s) from WebKit: \(preloadedTeams.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))"))
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

        onLog?(LogMessage(level: .success, message: "[Portal] WebKit session active for \(devSession.userFullName) with \(teams.count) team(s)."))
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

    // MARK: - Portal Network Helper & Logging

    public struct PortalHTTPResult: @unchecked Sendable {
        public let data: Data
        public let response: HTTPURLResponse
        public let json: [String: Any]?
        public let stringBody: String
    }

    public func makeSession(cookies: [HTTPCookie]) -> (session: URLSession, cookies: [HTTPCookie]) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        if let storage = config.httpCookieStorage {
            for c in cookies {
                storage.setCookie(c)
            }
        }
        let urlSession = URLSession(configuration: config)
        return (urlSession, cookies)
    }

    public func makeSession(from session: AppleDeveloperSession) -> (session: URLSession, cookies: [HTTPCookie]) {
        let cookies = extractCookies(from: session)
        return makeSession(cookies: cookies)
    }

    public func makeSession(from session: AppleDeveloperSession) -> URLSession {
        let pair: (URLSession, [HTTPCookie]) = makeSession(from: session)
        return pair.0
    }

    public func extractCookies(from session: AppleDeveloperSession) -> [HTTPCookie] {
        guard let data = session.cookiesData else { return [] }
        return AppleAuthService.decodeCookies(from: data)
    }

    public func logCookieSummary(cookies: [HTTPCookie], onLog: (@Sendable (LogMessage) -> Void)?) {
        guard let onLog = onLog else { return }
        if cookies.isEmpty {
            onLog(LogMessage(level: .warning, message: "[Portal] WARNING: Zero cookies found in session! Requests may fail with HTTP 302/401."))
            return
        }
        let names = cookies.map { c in
            let isExpired = c.expiresDate.map { $0 < Date() } ?? false
            return "\(c.name)\(isExpired ? "(EXPIRED)" : "")"
        }.joined(separator: ", ")
        onLog(LogMessage(level: .verbose, message: "[Portal] Active cookies (\(cookies.count)): \(names)"))
    }

    public func makePortalRequest(
        url: URL,
        method: String = "POST",
        bodyParams: [String: String]? = nil,
        cookies: [HTTPCookie] = [],
        urlSession: URLSession? = nil
    ) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("https://developer.apple.com/account/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        if !cookies.isEmpty {
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        if let params = bodyParams {
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~,"))
            let bodyString = params.map { key, value in
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encodedValue)"
            }.joined(separator: "&")
            req.httpBody = bodyString.data(using: .utf8)
        }

        return req
    }

    public func parsePortalResponse(_ data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            return plist
        }
        return nil
    }

    public func executePortalRequest(
        _ req: URLRequest,
        session: URLSession,
        operationName: String,
        onLog: (@Sendable (LogMessage) -> Void)?
    ) async throws -> PortalHTTPResult {
        let method = req.httpMethod ?? "GET"
        let urlStr = req.url?.absoluteString ?? ""
        onLog?(LogMessage(level: .info, message: "[Portal] --> \(method) \(urlStr)"))

        if let body = req.httpBody, let bodyStr = String(data: body, encoding: .utf8) {
            onLog?(LogMessage(level: .verbose, message: "[Portal] Body: \(bodyStr)"))
        }

        if let cookieHdr = req.value(forHTTPHeaderField: "Cookie") {
            let hasMyac = cookieHdr.contains("myacinfo")
            let hasDsosession = cookieHdr.contains("dsosession")
            let hasItspod = cookieHdr.contains("itspod")
            onLog?(LogMessage(level: .verbose, message: "[Portal] Cookie Header: myacinfo=\(hasMyac), dsosession=\(hasDsosession), itspod=\(hasItspod) (chars: \(cookieHdr.count))"))
        } else {
            onLog?(LogMessage(level: .warning, message: "[Portal] Warning: Request has no Cookie header!"))
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AppleDeveloperError.apiError("Invalid HTTP response for \(operationName)")
        }

        onLog?(LogMessage(level: .info, message: "[Portal] <-- HTTP \(http.statusCode) for \(operationName) (\(data.count) bytes)"))

        if let location = http.value(forHTTPHeaderField: "Location") {
            onLog?(LogMessage(level: .warning, message: "[Portal] Redirect Location: \(location)"))
            if location.contains("signin") || location.contains("auth") {
                onLog?(LogMessage(level: .error, message: "[Portal] Apple redirected to sign-in page. Your session has expired."))
            }
        }

        let stringBody = String(data: data, encoding: .utf8) ?? ""
        let preview = String(stringBody.prefix(350)).replacingOccurrences(of: "\n", with: " ")
        onLog?(LogMessage(level: .verbose, message: "[Portal] Payload Preview: \(preview)"))

        let json = parsePortalResponse(data)
        if let json = json {
            let resultCode = json["resultCode"] as? Int
            let userString = json["userString"] as? String
            let keys = json.keys.joined(separator: ", ")
            onLog?(LogMessage(level: .verbose, message: "[Portal] JSON keys: [\(keys)], resultCode: \(resultCode.map(String.init) ?? "none"), userString: \(userString ?? "none")"))
            if let rc = resultCode, rc != 0 {
                let errText = userString ?? "Error code \(rc)"
                onLog?(LogMessage(level: .error, message: "[Portal] Apple Server returned resultCode \(rc): \(errText)"))
            }
        } else if stringBody.contains("<html") {
            if !operationName.contains("selectTeam") && !operationName.contains("login") {
                onLog?(LogMessage(level: .warning, message: "[Portal] Apple returned HTML instead of JSON for \(operationName). Interactive session or redirect occurred."))
            }
        }

        return PortalHTTPResult(data: data, response: http, json: json, stringBody: stringBody)
    }

    public func fetchDeveloperPortalTeams(
        session: URLSession,
        cookies: [HTTPCookie],
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async -> [DeveloperTeam] {
        let endpointUrls = [
            "https://developer.apple.com/services-account/QH65B2/account/listTeams.action",
            "https://developerservices2.apple.com/services/QH65B2/listTeams.action"
        ]

        for urlString in endpointUrls {
            guard let url = URL(string: urlString) else { continue }
            let request = makePortalRequest(url: url, method: "POST", cookies: cookies)

            do {
                let res = try await executePortalRequest(request, session: session, operationName: "listTeams.action", onLog: onLog)
                guard res.response.statusCode == 200, let json = res.json else {
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
                    onLog?(LogMessage(level: .success, message: "[Portal] Discovered \(result.count) team(s) from \(urlString): \(result.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))"))
                    return result
                }
            } catch {
                onLog?(LogMessage(level: .verbose, message: "[Portal] Error querying \(urlString): \(error.localizedDescription)"))
                continue
            }
        }

        return []
    }

    public func fetchOlympusTeams(
        session: URLSession,
        cookies: [HTTPCookie],
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async -> [DeveloperTeam] {
        let url = olympusBase.appendingPathComponent("session")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("olympus-ui", forHTTPHeaderField: "X-Requested-With")

        if !cookies.isEmpty {
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        do {
            let res = try await executePortalRequest(request, session: session, operationName: "olympus/session (teams)", onLog: onLog)
            guard res.response.statusCode < 400, let json = res.json,
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
            if !list.isEmpty {
                onLog?(LogMessage(level: .success, message: "[Portal] Discovered \(list.count) team(s) from Olympus: \(list.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))"))
            }
            return list
        } catch {
            onLog?(LogMessage(level: .verbose, message: "[Portal] Olympus teams lookup failed: \(error.localizedDescription)"))
            return []
        }
    }

    public func fetchTeams(
        session: URLSession,
        cookies: [HTTPCookie],
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> [DeveloperTeam] {
        async let portalTeams = fetchDeveloperPortalTeams(session: session, cookies: cookies, onLog: onLog)
        async let olympusTeams = fetchOlympusTeams(session: session, cookies: cookies, onLog: onLog)

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
        let (urlSession, cookieList) = makeSession(from: session)
        logCookieSummary(cookies: cookieList, onLog: onLog)

        // Set active team on Olympus if available
        let switchURL = olympusBase.appendingPathComponent("session")
        var switchReq = URLRequest(url: switchURL)
        switchReq.httpMethod = "POST"
        switchReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cookieList.isEmpty {
            let cookieHeader = cookieList.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            switchReq.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let switchBody = ["teamId": team.id]
        switchReq.httpBody = try? JSONSerialization.data(withJSONObject: switchBody)
        _ = try? await urlSession.data(for: switchReq)

        // Select team on Developer Portal
        await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: cookieList, onLog: onLog)

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
        onLog?(LogMessage(level: .info, message: "Inspecting local Keychain identities (\(localIdentities.count) found)..."))
        for id in localIdentities {
            onLog?(LogMessage(level: .verbose, message: "  Local Identity: '\(id.name)', Team ID: '\(id.teamId ?? "nil")', Team Name: '\(id.teamName ?? "nil")'"))
        }

        let matchingLocal = localIdentities.first { id in
            if let tId = id.teamId, tId.caseInsensitiveCompare(team.id) == .orderedSame {
                return true
            }
            if id.name.localizedCaseInsensitiveContains(team.id) {
                return true
            }
            if let tName = id.teamName, !tName.isEmpty,
               team.name.localizedCaseInsensitiveContains(tName) || tName.localizedCaseInsensitiveContains(team.name) {
                return true
            }
            if id.name.localizedCaseInsensitiveContains(team.name) {
                return true
            }
            return false
        }

        var certResult: CertPackage? = nil
        if let local = matchingLocal {
            onLog?(LogMessage(level: .info, message: "Discovered active Keychain identity '\(local.name)' matching team '\(team.name)'!"))
            onLog?(LogMessage(level: .info, message: "Exporting matching local certificate to bypass Apple team limits..."))
            let pwd = "SignetLocalPass\(Int.random(in: 100000...999999))"
            do {
                let p12Data = try exportKeychainIdentity(identityName: local.name, password: pwd)
                // Find matching certificateId on portal if possible
                let portalCerts = (try? await fetchPortalCertificates(session: session, team: team, onLog: onLog)) ?? []
                let matchingCert = portalCerts.first(where: {
                    $0.isIssued && (local.name.contains($0.name) || $0.name.contains(local.name) || ($0.ownerName != nil && local.name.contains($0.ownerName!)))
                }) ?? portalCerts.first(where: { $0.isIssued })
                let cId = matchingCert?.id ?? ""
                certResult = CertPackage(certId: cId, p12Data: p12Data, password: pwd)
                onLog?(LogMessage(level: .success, message: "Successfully prepared local developer identity for code signing."))
            } catch {
                onLog?(LogMessage(level: .warning, message: "Could not export local identity from Keychain: \(error.localizedDescription). Falling back to fresh certificate request..."))
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

        if let res = try? await executePortalRequest(req, session: urlSession, operationName: "registerDevice (addDevices)", onLog: onLog),
           let json = res.json,
           let devices = json["devices"] as? [[String: Any]], let first = devices.first,
           let id = (first["deviceId"] as? String) ?? (first["id"] as? String) {
            onLog?(LogMessage(level: .success, message: "Device registered in team '\(team.name)': \(device.displayName) (ID: \(id))"))
            return id
        }

        // Check if device is already registered in team
        let listURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/device/listDevices.action")!
        let listReq = makePortalRequest(url: listURL, method: "POST", bodyParams: ["teamId": team.id, "pageSize": "500"], cookies: cookies)
        if let listRes = try? await executePortalRequest(listReq, session: urlSession, operationName: "listDevices (check existing)", onLog: onLog),
           let json = listRes.json,
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

            if let res = try? await executePortalRequest(req, session: urlSession, operationName: "submitCertificateRequest (\(certType))", onLog: onLog),
               let json = res.json {

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
                    if let dlRes = try? await executePortalRequest(dlReq, session: urlSession, operationName: "downloadCertificateContent", onLog: onLog),
                       dlRes.response.statusCode == 200, !dlRes.data.isEmpty {
                        rawCerData = dlRes.data
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
                "pageNumber": "1",
                "pageSize": "500",
                "sort": "certRequestStatusCode=asc"
            ]
            let listReq = makePortalRequest(url: listURL, method: "POST", bodyParams: listParams, cookies: cookies)

            if let listRes = try? await executePortalRequest(listReq, session: urlSession, operationName: "listCertRequests (auto-revoke check)", onLog: onLog),
               let json = listRes.json,
               let certs = (json["certRequests"] as? [[String: Any]]) ?? (json["certificates"] as? [[String: Any]]) {

                let activeCerts = certs.filter {
                    ($0["statusString"] as? String) == "Issued" ||
                    ($0["canDownload"] as? Bool) == true
                }

                if autoRevokeIfLimitReached && !activeCerts.isEmpty {
                    let candidate = activeCerts.first(where: {
                        (($0["name"] as? String) ?? "").localizedCaseInsensitiveContains("Signet")
                    }) ?? activeCerts.last!

                    let candId = (candidate["certificateId"] as? String) ?? (candidate["certRequestId"] as? String) ?? ""
                    let candType = (candidate["certificateTypeDisplayId"] as? String) ?? (candidate["type"] as? String) ?? "83Q87W3TGH"
                    let candName = (candidate["name"] as? String) ?? "Apple Development"

                    onLog?(LogMessage(level: .warning, message: "Team certificate limit reached on Apple Developer Portal. Automatically revoking '\(candName)' (ID: \(candId)) to make room for Signet keypair (matching Sideloadly behavior)..."))

                    let revoked = (try? await revokePortalCertificate(urlSession: urlSession, team: team, certificateId: candId, type: candType, cookies: cookies, onLog: onLog)) ?? false
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

                            if let rRes = try? await executePortalRequest(req, session: urlSession, operationName: "submitCertificateRequest retry (\(certType))", onLog: onLog),
                               let rJson = rRes.json {

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
                                    if let dlRes = try? await executePortalRequest(dlReq, session: urlSession, operationName: "downloadCertificateContent retry", onLog: onLog),
                                       dlRes.response.statusCode == 200, !dlRes.data.isEmpty {
                                        rawCerData = dlRes.data
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

        if let xcRes = try? await executePortalRequest(xcodeReq, session: urlSession, operationName: "listProvisioningProfiles (Xcode)", onLog: onLog),
           xcRes.response.statusCode == 200,
           let plist = try? PropertyListSerialization.propertyList(from: xcRes.data, options: [], format: nil) as? [String: Any],
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
        let listAppParams = ["teamId": team.id, "pageNumber": "1", "pageSize": "500", "sort": "name=asc"]
        let listAppReq = makePortalRequest(url: listAppIdsURL, method: "POST", bodyParams: listAppParams, cookies: cookies)

        var appIdId = ""
        if let appRes = try? await executePortalRequest(listAppReq, session: urlSession, operationName: "listAppIds (Profile Creation)", onLog: onLog),
           let json = appRes.json,
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
            if let addRes = try? await executePortalRequest(addAppReq, session: urlSession, operationName: "addAppId (Wildcard)", onLog: onLog),
               let json = addRes.json,
               let appObj = json["appId"] as? [String: Any] {
                appIdId = (appObj["appIdId"] as? String) ?? (appObj["id"] as? String) ?? ""
            }
        }

        // 3. Create or download Provisioning Profile via Developer Portal
        var targetCertId = certId
        if targetCertId.isEmpty || targetCertId == "LOCAL_CERT" {
            let listURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/certificate/listCertRequests.action")!
            let certParams = [
                "teamId": team.id,
                "pageNumber": "1",
                "pageSize": "100",
                "sort": "certRequestStatusCode=asc",
                "types": "5QPB9NHCEQ,R5DG2F3R6A,83Q87W3TGH,B73J52Q545,LH4T963KP2,92Y3FF6462"
            ]
            let req = makePortalRequest(url: listURL, method: "POST", bodyParams: certParams, cookies: cookies, urlSession: urlSession)
            if let res = try? await executePortalRequest(req, session: urlSession, operationName: "listCertRequests (for Profile)", onLog: onLog),
               res.response.statusCode == 200, let json = res.json,
               let certs = (json["certRequests"] as? [[String: Any]]) ?? (json["certificates"] as? [[String: Any]]) {
                for c in certs {
                    if let cid = (c["certificateId"] as? String) ?? (c["certRequestId"] as? String), !cid.isEmpty {
                        targetCertId = cid
                        onLog?(LogMessage(level: .info, message: "Associated provisioning profile with active portal certificate: \(cid)"))
                        break
                    }
                }
            }
        }

        let profName = "Signet Wildcard \(Int.random(in: 100...999))"
        let createProfURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/profile/createProvisioningProfile.action")!
        var createParams: [String: String] = [
            "teamId": team.id,
            "provisioningProfileName": profName,
            "distributionType": "limited"
        ]
        if !targetCertId.isEmpty && targetCertId != "LOCAL_CERT" {
            createParams["certificateIds"] = targetCertId
        }
        if !appIdId.isEmpty {
            createParams["appIdId"] = appIdId
        }
        if let dId = deviceId {
            createParams["deviceIds"] = dId
        }

        let createProfReq = makePortalRequest(url: createProfURL, method: "POST", bodyParams: createParams, cookies: cookies)

        var profileId = ""
        if let cRes = try? await executePortalRequest(createProfReq, session: urlSession, operationName: "createProvisioningProfile", onLog: onLog),
           let json = cRes.json,
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
            if let dlRes = try? await executePortalRequest(dlReq, session: urlSession, operationName: "downloadProfileContent", onLog: onLog),
               dlRes.response.statusCode == 200, !dlRes.data.isEmpty {
                onLog?(LogMessage(level: .success, message: "Downloaded profile: \(profName)"))
                return dlRes.data
            }
        }

        // 5. Fallback: check existing profiles on portal
        let listProfURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/profile/listProvisioningProfiles.action")!
        let listProfParams = ["teamId": team.id, "pageNumber": "1", "pageSize": "500"]
        let listProfReq = makePortalRequest(url: listProfURL, method: "POST", bodyParams: listProfParams, cookies: cookies)
        if let lRes = try? await executePortalRequest(listProfReq, session: urlSession, operationName: "listProvisioningProfiles", onLog: onLog),
           let json = lRes.json,
           let profiles = json["provisioningProfiles"] as? [[String: Any]] {
            for prof in profiles {
                if let pId = prof["provisioningProfileId"] as? String {
                    let dlURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/profile/downloadProfileContent?teamId=\(team.id)&provisioningProfileId=\(pId)")!
                    let dlReq = makePortalRequest(url: dlURL, method: "GET", cookies: cookies)
                    if let dlRes = try? await executePortalRequest(dlReq, session: urlSession, operationName: "downloadProfileContent (existing)", onLog: onLog),
                       dlRes.response.statusCode == 200, !dlRes.data.isEmpty {
                        onLog?(LogMessage(level: .info, message: "Downloaded active team profile."))
                        return dlRes.data
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

    public func mergeCookies(_ existing: [HTTPCookie], newCookies: [HTTPCookie]) -> [HTTPCookie] {
        var map: [String: HTTPCookie] = [:]
        for c in existing {
            map[c.name] = c
        }
        for c in newCookies {
            map[c.name] = c
        }
        return Array(map.values)
    }

    private func makeXcodePlistRequest(
        url: URL,
        params: [String: Any],
        cookies: [HTTPCookie]
    ) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        req.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        req.setValue("Xcode", forHTTPHeaderField: "User-Agent")
        if !cookies.isEmpty {
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        req.httpBody = try? PropertyListSerialization.data(fromPropertyList: params, format: .xml, options: 0)
        return req
    }

    @discardableResult
    public func selectPortalTeam(
        urlSession: URLSession,
        teamId: String,
        cookies: [HTTPCookie],
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async -> [HTTPCookie] {
        var currentCookies = cookies
        onLog?(LogMessage(level: .info, message: "[Portal] Selecting developer team: \(teamId)"))

        // 1. GET account selectTeam (official web endpoint, switches account team session)
        let getURL = URL(string: "https://developer.apple.com/account/selectTeam.action?teamId=\(teamId)")!
        let getReq = makePortalRequest(url: getURL, method: "GET", cookies: currentCookies, urlSession: urlSession)
        if let res = try? await executePortalRequest(getReq, session: urlSession, operationName: "account/selectTeam.action", onLog: onLog) {
            if let headerFields = res.response.allHeaderFields as? [String: String], let respURL = res.response.url {
                let respCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: respURL)
                currentCookies = mergeCookies(currentCookies, newCookies: respCookies)
            }
        }

        // 2. Olympus session switcher (only if App Store Connect / Olympus session cookie is present)
        if currentCookies.contains(where: { $0.name.lowercased().contains("olympus") || $0.name == "itspod" }) {
            let switchURL = olympusBase.appendingPathComponent("session")
            var switchReq = URLRequest(url: switchURL)
            switchReq.httpMethod = "POST"
            switchReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            switchReq.setValue("application/json", forHTTPHeaderField: "Accept")
            let cookieHeader = currentCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            switchReq.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            let switchBody = ["teamId": teamId]
            switchReq.httpBody = try? JSONSerialization.data(withJSONObject: switchBody)
            if let res = try? await executePortalRequest(switchReq, session: urlSession, operationName: "olympus/session (switch team)", onLog: onLog) {
                if let headerFields = res.response.allHeaderFields as? [String: String], let respURL = res.response.url {
                    let respCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: respURL)
                    currentCookies = mergeCookies(currentCookies, newCookies: respCookies)
                }
            }
        }

        onLog?(LogMessage(level: .success, message: "[Portal] Team selection for \(teamId) completed."))
        return currentCookies
    }

    // Devices
    public func fetchPortalDevices(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> [PortalDevice] {
        let (urlSession, initialCookies) = makeSession(from: session)
        logCookieSummary(cookies: initialCookies, onLog: onLog)
        let cookies = await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: initialCookies, onLog: onLog)

        onLog?(LogMessage(level: .info, message: "[Portal] Querying registered devices for team \(team.name) (\(team.id))..."))

        let listURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/device/listDevices.action")!
        let params: [String: String] = [
            "teamId": team.id,
            "pageNumber": "1",
            "pageSize": "500",
            "sort": "name=asc"
        ]
        let req = makePortalRequest(url: listURL, method: "POST", bodyParams: params, cookies: cookies, urlSession: urlSession)

        do {
            let res = try await executePortalRequest(req, session: urlSession, operationName: "listDevices.action", onLog: onLog)
            if res.response.statusCode == 200, let dict = res.json, let devices = dict["devices"] as? [[String: Any]], !devices.isEmpty {
                let parsed = parseDevices(devices)
                onLog?(LogMessage(level: .success, message: "[Portal] Found \(parsed.count) device(s) via developer portal."))
                return parsed
            }
        } catch {
            onLog?(LogMessage(level: .warning, message: "[Portal] listDevices failed: \(error.localizedDescription)"))
        }

        // Fallback to Xcode endpoint
        onLog?(LogMessage(level: .info, message: "[Portal] Trying Xcode listDevices endpoint fallback..."))
        let xcURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/ios/listDevices.action")!
        let xcReq = makeXcodePlistRequest(url: xcURL, params: ["teamId": team.id, "pageSize": 500, "pageNumber": 1], cookies: cookies)
        do {
            let res = try await executePortalRequest(xcReq, session: urlSession, operationName: "developerservices2/listDevices.action", onLog: onLog)
            if res.response.statusCode == 200, let dict = res.json, let devices = dict["devices"] as? [[String: Any]] {
                let parsed = parseDevices(devices)
                onLog?(LogMessage(level: .success, message: "[Portal] Found \(parsed.count) device(s) via Xcode endpoint."))
                return parsed
            }
        } catch {
            onLog?(LogMessage(level: .error, message: "[Portal] Xcode listDevices failed: \(error.localizedDescription)"))
        }

        onLog?(LogMessage(level: .info, message: "[Portal] No registered devices found for team \(team.id)."))
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
        deviceId: String,
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> Bool {
        let (urlSession, initialCookies) = makeSession(from: session)
        let cookies = await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: initialCookies, onLog: onLog)

        onLog?(LogMessage(level: .info, message: "[Portal] Deleting device ID \(deviceId) for team \(team.name)..."))

        let deleteURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/device/deleteDevice.action")!
        let req = makePortalRequest(url: deleteURL, method: "POST", bodyParams: ["teamId": team.id, "deviceId": deviceId], cookies: cookies, urlSession: urlSession)

        if let res = try? await executePortalRequest(req, session: urlSession, operationName: "deleteDevice.action", onLog: onLog),
           res.response.statusCode == 200,
           let json = res.json,
           let code = json["resultCode"] as? Int, code == 0 {
            onLog?(LogMessage(level: .success, message: "[Portal] Device \(deviceId) deleted successfully."))
            return true
        }

        onLog?(LogMessage(level: .info, message: "[Portal] deleteDevice.action failed or unsupported, trying disableDevice.action..."))
        let disableURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/device/disableDevice.action")!
        let disableReq = makePortalRequest(url: disableURL, method: "POST", bodyParams: ["teamId": team.id, "deviceId": deviceId], cookies: cookies, urlSession: urlSession)
        if let res = try? await executePortalRequest(disableReq, session: urlSession, operationName: "disableDevice.action", onLog: onLog),
           res.response.statusCode == 200,
           let json = res.json,
           let code = json["resultCode"] as? Int, code == 0 {
            onLog?(LogMessage(level: .success, message: "[Portal] Device \(deviceId) disabled successfully."))
            return true
        }

        onLog?(LogMessage(level: .error, message: "[Portal] Could not delete or disable device \(deviceId). Apple restricts removing active devices during membership year."))
        return false
    }

    public func registerPortalDeviceManual(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        name: String,
        udid: String,
        deviceClass: String = "iphone",
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> PortalDevice {
        let (urlSession, initialCookies) = makeSession(from: session)
        let cookies = await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: initialCookies, onLog: onLog)

        onLog?(LogMessage(level: .info, message: "[Portal] Registering device '\(name)' (\(udid), class: \(deviceClass)) for team \(team.name)..."))

        let addURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/device/addDevices.action")!
        let params: [String: String] = [
            "teamId": team.id,
            "deviceClasses": deviceClass,
            "deviceNumbers": udid,
            "deviceNames": name,
            "register": "single"
        ]
        let req = makePortalRequest(url: addURL, method: "POST", bodyParams: params, cookies: cookies, urlSession: urlSession)
        let res = try await executePortalRequest(req, session: urlSession, operationName: "addDevices.action", onLog: onLog)

        guard res.response.statusCode == 200, let json = res.json else {
            throw AppleDeveloperError.apiError("Failed to register device with Apple Developer Portal (HTTP \(res.response.statusCode)).")
        }

        if let devices = json["devices"] as? [[String: Any]], let first = devices.first,
           let id = (first["deviceId"] as? String) ?? (first["id"] as? String) {
            onLog?(LogMessage(level: .success, message: "[Portal] Registered device successfully: ID=\(id), Name=\(name)"))
            return PortalDevice(id: id, name: name, udid: udid, deviceClass: deviceClass, model: first["model"] as? String, status: "Y")
        }

        if let userStr = json["userString"] as? String {
            onLog?(LogMessage(level: .error, message: "[Portal] Registration rejected: \(userStr)"))
            throw AppleDeveloperError.apiError(userStr)
        }

        throw AppleDeveloperError.apiError("Could not register device in team.")
    }

    // Certificates
    public func fetchPortalCertificates(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> [PortalCertificate] {
        let (urlSession, initialCookies) = makeSession(from: session)
        logCookieSummary(cookies: initialCookies, onLog: onLog)
        let cookies = await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: initialCookies, onLog: onLog)

        onLog?(LogMessage(level: .info, message: "[Portal] Querying certificates for team \(team.name) (\(team.id))..."))

        var accumulatedCerts: [PortalCertificate] = []
        var seenIds = Set<String>()

        // 1. Primary: Modern Apple Developer Portal REST API (developer.apple.com/services-account/v1/certificates)
        // Returns ALL certificates (Development, Distribution, iOS, macOS, Developer ID) in standard JSON:API format
        let v1Urls = [
            "https://developer.apple.com/services-account/v1/certificates",
            "https://appstoreconnect.apple.com/iris/v1/certificates"
        ]

        for urlString in v1Urls {
            guard let url = URL(string: urlString) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/vnd.api+json, application/json", forHTTPHeaderField: "Accept")
            req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            req.setValue(team.id, forHTTPHeaderField: "X-Apple-Developer-Team-Id")
            req.setValue(team.id, forHTTPHeaderField: "X-Apple-Team-Id")
            if !cookies.isEmpty {
                let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }

            do {
                let res = try await executePortalRequest(req, session: urlSession, operationName: "v1/certificates (\(url.host ?? ""))", onLog: onLog)
                if res.response.statusCode == 200, let dict = res.json, let dataArr = dict["data"] as? [[String: Any]], !dataArr.isEmpty {
                    let parsedV1 = parseCertsFromV1Response(dict)
                    if !parsedV1.isEmpty {
                        onLog?(LogMessage(level: .success, message: "[Portal] Discovered \(parsedV1.count) certificate(s) via modern REST API (\(url.host ?? ""))."))
                        for c in parsedV1 {
                            if !seenIds.contains(c.id) {
                                seenIds.insert(c.id)
                                accumulatedCerts.append(c)
                            }
                        }
                        return accumulatedCerts
                    }
                }
            } catch {
                onLog?(LogMessage(level: .verbose, message: "[Portal] Modern API \(urlString) failed: \(error.localizedDescription)"))
            }
        }

        // 2. Query targeted certificate types individually to prevent Apache Struts enum validation errors (resultCode 25)
        var legacyRawCerts: [[String: Any]] = []

        let targetIosTypes: [(code: String, label: String)] = [
            ("WXV89964HE", "Apple Distribution"),
            ("R58UK2EWSO", "iOS Distribution"),
            ("R5DG2F3R6A", "iOS Distribution (Classic)"),
            ("9RQEK7MSXA", "iOS In-House Distribution"),
            ("83Q87W3TGH", "Apple Development"),
            ("5QPB9NHCEI", "iOS Development"),
            ("5QPB9NHCEQ", "iOS Development (Extended)")
        ]

        let iosListURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/certificate/listCertRequests.action")!

        // 2a. Try listing all certificates without types filter first
        let allParams = [
            "teamId": team.id,
            "pageNumber": "1",
            "pageSize": "500",
            "sort": "certRequestStatusCode=asc"
        ]
        let allReq = makePortalRequest(url: iosListURL, method: "POST", bodyParams: allParams, cookies: cookies, urlSession: urlSession)
        if let res = try? await executePortalRequest(allReq, session: urlSession, operationName: "ios/listCertRequests.action (all)", onLog: onLog),
           res.response.statusCode == 200, let dict = res.json,
           let certs = (dict["certRequests"] as? [[String: Any]]) ?? (dict["certificates"] as? [[String: Any]]), !certs.isEmpty {
            for c in certs {
                let cId = (c["certificateId"] as? String) ?? (c["certRequestId"] as? String) ?? ""
                if !cId.isEmpty && !legacyRawCerts.contains(where: { (($0["certificateId"] as? String) ?? ($0["certRequestId"] as? String)) == cId }) {
                    legacyRawCerts.append(c)
                }
            }
            onLog?(LogMessage(level: .info, message: "[Portal] iOS cert endpoint (all) returned \(certs.count) certificate(s)."))
        }

        // 2b. Query each specific iOS & Universal certificate type individually
        for item in targetIosTypes {
            let params = [
                "teamId": team.id,
                "pageNumber": "1",
                "pageSize": "500",
                "sort": "certRequestStatusCode=asc",
                "types": item.code
            ]
            let req = makePortalRequest(url: iosListURL, method: "POST", bodyParams: params, cookies: cookies, urlSession: urlSession)
            if let res = try? await executePortalRequest(req, session: urlSession, operationName: "ios/listCertRequests.action (\(item.label))", onLog: onLog),
               res.response.statusCode == 200, let dict = res.json,
               let certs = (dict["certRequests"] as? [[String: Any]]) ?? (dict["certificates"] as? [[String: Any]]), !certs.isEmpty {
                var added = 0
                for c in certs {
                    let cId = (c["certificateId"] as? String) ?? (c["certRequestId"] as? String) ?? ""
                    if !cId.isEmpty && !legacyRawCerts.contains(where: { (($0["certificateId"] as? String) ?? ($0["certRequestId"] as? String)) == cId }) {
                        legacyRawCerts.append(c)
                        added += 1
                    }
                }
                if added > 0 {
                    onLog?(LogMessage(level: .info, message: "[Portal] Retrieved \(added) \(item.label) certificate(s)."))
                }
            }
        }

        // 3. Legacy Mac endpoint with individual safe Mac types (Mac Development, Mac App Distribution, Developer ID)
        let targetMacTypes: [(code: String, label: String)] = [
            ("W0EURJRMC5", "Developer ID Application"),
            ("HXZEUKP0FP", "Mac App Distribution"),
            ("2PQI8IDXNH", "Mac Installer Distribution"),
            ("749Y1QAGU7", "Mac Development"),
            ("DIVN2GW3XT", "Developer ID Application (Universal)"),
            ("OYVN2GW35E", "Developer ID Installer")
        ]

        let macListURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/mac/certificate/listCertRequests.action")!
        for item in targetMacTypes {
            let macParams = [
                "teamId": team.id,
                "pageNumber": "1",
                "pageSize": "500",
                "sort": "certRequestStatusCode=asc",
                "types": item.code
            ]
            let macReq = makePortalRequest(url: macListURL, method: "POST", bodyParams: macParams, cookies: cookies, urlSession: urlSession)
            if let res = try? await executePortalRequest(macReq, session: urlSession, operationName: "mac/listCertRequests.action (\(item.label))", onLog: onLog),
               res.response.statusCode == 200, let dict = res.json,
               let certs = (dict["certRequests"] as? [[String: Any]]) ?? (dict["certificates"] as? [[String: Any]]), !certs.isEmpty {
                var added = 0
                for c in certs {
                    let cId = (c["certificateId"] as? String) ?? (c["certRequestId"] as? String) ?? ""
                    if !cId.isEmpty && !legacyRawCerts.contains(where: { (($0["certificateId"] as? String) ?? ($0["certRequestId"] as? String)) == cId }) {
                        legacyRawCerts.append(c)
                        added += 1
                    }
                }
                if added > 0 {
                    onLog?(LogMessage(level: .info, message: "[Portal] Mac endpoint returned \(added) \(item.label) certificate(s)."))
                }
            }
        }

        // 4. Xcode developer services endpoints (always query to guarantee coverage)
        onLog?(LogMessage(level: .info, message: "[Portal] Checking Xcode developer services endpoints..."))

        // 4a. Development certs
        let xcURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/ios/listAllDevelopmentCerts.action")!
        let xcReq = makeXcodePlistRequest(url: xcURL, params: ["teamId": team.id], cookies: cookies)
        if let res = try? await executePortalRequest(xcReq, session: urlSession, operationName: "developerservices2/listAllDevelopmentCerts.action", onLog: onLog),
           res.response.statusCode == 200, let dict = res.json,
           let certs = (dict["certRequests"] as? [[String: Any]]) ?? (dict["certificates"] as? [[String: Any]]), !certs.isEmpty {
            var added = 0
            for c in certs {
                let cId = (c["certificateId"] as? String) ?? (c["certRequestId"] as? String) ?? ""
                if !cId.isEmpty && !legacyRawCerts.contains(where: { (($0["certificateId"] as? String) ?? ($0["certRequestId"] as? String)) == cId }) {
                    legacyRawCerts.append(c)
                    added += 1
                }
            }
            if added > 0 {
                onLog?(LogMessage(level: .info, message: "[Portal] Xcode development endpoint returned \(added) certificate(s)."))
            }
        }

        // 4b. Xcode distribution cert requests
        for item in targetIosTypes.filter({ $0.label.contains("Distribution") }) {
            let xcListURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/ios/listCertRequests.action")!
            let xcListReq = makeXcodePlistRequest(url: xcListURL, params: ["teamId": team.id, "types": item.code], cookies: cookies)
            if let resList = try? await executePortalRequest(xcListReq, session: urlSession, operationName: "developerservices2/listCertRequests.action (\(item.label))", onLog: onLog),
               resList.response.statusCode == 200, let dictList = resList.json,
               let certsList = (dictList["certRequests"] as? [[String: Any]]) ?? (dictList["certificates"] as? [[String: Any]]), !certsList.isEmpty {
                var added = 0
                for c in certsList {
                    let cId = (c["certificateId"] as? String) ?? (c["certRequestId"] as? String) ?? ""
                    if !cId.isEmpty && !legacyRawCerts.contains(where: { (($0["certificateId"] as? String) ?? ($0["certRequestId"] as? String)) == cId }) {
                        legacyRawCerts.append(c)
                        added += 1
                    }
                }
                if added > 0 {
                    onLog?(LogMessage(level: .info, message: "[Portal] Xcode services returned \(added) \(item.label) certificate(s)."))
                }
            }
        }

        let parsedLegacy = parseCerts(legacyRawCerts)
        for c in parsedLegacy {
            if !seenIds.contains(c.id) {
                seenIds.insert(c.id)
                accumulatedCerts.append(c)
            }
        }

        onLog?(LogMessage(level: .success, message: "[Portal] Total parsed certificates for team: \(accumulatedCerts.count) (Distribution: \(accumulatedCerts.filter { $0.isDistribution }.count), Development: \(accumulatedCerts.filter { !$0.isDistribution }.count))"))
        return accumulatedCerts
    }

    private func parseCertsFromV1Response(_ dict: [String: Any]) -> [PortalCertificate] {
        guard let dataArr = dict["data"] as? [[String: Any]] else { return [] }
        var result: [PortalCertificate] = []

        for item in dataArr {
            let id = (item["id"] as? String) ?? ""
            guard !id.isEmpty else { continue }
            let attrs = (item["attributes"] as? [String: Any]) ?? [:]

            let rawCertType = (attrs["certificateType"] as? String) ?? "DEVELOPMENT"
            let name = (attrs["name"] as? String) ?? (attrs["displayName"] as? String) ?? "Apple Certificate"
            let exp = attrs["expirationDate"] as? String
            let displayName = attrs["displayName"] as? String

            let (typeId, typeDisplayName) = mapV1CertificateType(rawCertType)
            let isDist = rawCertType.contains("DISTRIBUTION") || rawCertType.contains("PRODUCTION") || typeDisplayName.contains("Distribution")

            let ownerType: String
            if let ot = attrs["ownerType"] as? String {
                ownerType = ot
            } else if isDist {
                ownerType = "team"
            } else {
                ownerType = "personal"
            }

            result.append(PortalCertificate(
                id: id,
                name: name,
                type: typeId,
                typeDisplayName: typeDisplayName,
                status: "Issued",
                expirationDate: exp,
                canDownload: true,
                canRevoke: true,
                ownerName: displayName ?? name,
                ownerType: ownerType
            ))
        }

        return result
    }

    private func mapV1CertificateType(_ certType: String) -> (id: String, displayName: String) {
        switch certType.uppercased() {
        case "DEVELOPMENT":
            return ("83Q87W3TGH", "Apple Development")
        case "DISTRIBUTION":
            return ("WXV89964HE", "Apple Distribution")
        case "IOS_DEVELOPMENT":
            return ("5QPB9NHCEI", "iOS Development")
        case "IOS_DISTRIBUTION":
            return ("R5DG2F3R6A", "iOS Distribution")
        case "MAC_APP_DEVELOPMENT":
            return ("749Y1QAGU7", "Mac Development")
        case "MAC_APP_DISTRIBUTION":
            return ("HXZEUKP0FP", "Mac App Distribution")
        case "MAC_INSTALLER_DISTRIBUTION":
            return ("2PQI8IDXNH", "Mac Installer Distribution")
        case "DEVELOPER_ID_APPLICATION", "DEVELOPER_ID_APPLICATION_G2":
            return ("W0EURJRMC5", "Developer ID Application")
        case "DEVELOPER_ID_INSTALLER":
            return ("OYVN2GW35E", "Developer ID Installer")
        case "PASSBOOK_AGENT":
            return ("Y3B2F3TYSI", "Passbook Certificate")
        case "WEBSITE_PUSH":
            return ("3T2ZP62QW8", "Website Push Certificate")
        default:
            let cleaned = certType.replacingOccurrences(of: "_", with: " ").capitalized
            return ("83Q87W3TGH", cleaned)
        }
    }

    private func parseCerts(_ certs: [[String: Any]]) -> [PortalCertificate] {
        var result: [PortalCertificate] = []
        var seenIds = Set<String>()

        for raw in certs {
            var c = raw
            if let nested = raw["certificateType"] as? [String: Any] {
                for (k, v) in nested {
                    if c[k] == nil {
                        c[k] = v
                    }
                }
            }

            let id = (c["certificateId"] as? String) ?? (c["certRequestId"] as? String) ?? ""
            guard !id.isEmpty, !seenIds.contains(id) else { continue }
            seenIds.insert(id)

            let type = (c["certificateTypeDisplayId"] as? String) ?? (c["type"] as? String) ?? "83Q87W3TGH"

            // Compute human readable type display name
            let typeDisplayName: String
            if let explicitName = c["typeDisplayName"] as? String, !explicitName.isEmpty {
                typeDisplayName = explicitName
            } else if let certTypeName = c["name"] as? String, (certTypeName.contains("Distribution") || certTypeName.contains("Development")) && !certTypeName.contains(":") {
                typeDisplayName = certTypeName
            } else {
                switch type {
                case "83Q87W3TGH": typeDisplayName = "Apple Development"
                case "WXV89964HE": typeDisplayName = "Apple Distribution"
                case "5QPB9NHCEI", "5QPB9NHCEQ": typeDisplayName = "iOS Development"
                case "R58UK2EWSO", "R5DG2F3R6A": typeDisplayName = "iOS Distribution"
                case "9RQEK7MSXA": typeDisplayName = "iOS Distribution (In-House)"
                case "749Y1QAGU7": typeDisplayName = "Mac Development"
                case "HXZEUKP0FP": typeDisplayName = "Mac App Distribution"
                case "2PQI8IDXNH": typeDisplayName = "Mac Installer Distribution"
                case "W0EURJRMC5", "DIVN2GW3XT": typeDisplayName = "Developer ID Application"
                case "OYVN2GW35E": typeDisplayName = "Developer ID Installer"
                case "JKG5JZ54H7": typeDisplayName = "Apple Push Notification (Dev)"
                case "UPV3DW712I": typeDisplayName = "Apple Push Notification (Prod)"
                case "Y3B2F3TYSI": typeDisplayName = "Passbook Certificate"
                case "3T2ZP62QW8": typeDisplayName = "Website Push Certificate"
                case "E5D663CMZW": typeDisplayName = "VoIP Push Certificate"
                default:
                    if let rawName = c["name"] as? String, rawName.contains(":") {
                        typeDisplayName = rawName.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces) ?? "Apple Certificate"
                    } else {
                        typeDisplayName = "Apple Certificate"
                    }
                }
            }

            let name = (c["name"] as? String) ?? (c["ownerName"] as? String) ?? typeDisplayName
            let status = (c["statusString"] as? String) ?? (c["status"] as? String) ?? "Issued"
            let exp = c["expirationDate"] as? String
            let canDl = (c["canDownload"] as? Bool) ?? true
            let canRev = (c["canRevoke"] as? Bool) ?? true
            let owner = (c["ownerName"] as? String) ?? (c["name"] as? String)
            let ownerType = c["ownerType"] as? String

            result.append(PortalCertificate(
                id: id,
                name: name,
                type: type,
                typeDisplayName: typeDisplayName,
                status: status,
                expirationDate: exp,
                canDownload: canDl,
                canRevoke: canRev,
                ownerName: owner,
                ownerType: ownerType
            ))
        }
        return result
    }

    public func revokePortalCertificate(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        certificateId: String,
        type: String,
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> Bool {
        let (urlSession, initialCookies) = makeSession(from: session)
        let cookies = await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: initialCookies, onLog: onLog)
        return try await revokePortalCertificate(urlSession: urlSession, team: team, certificateId: certificateId, type: type, cookies: cookies, onLog: onLog)
    }

    public func revokePortalCertificate(
        urlSession: URLSession,
        team: DeveloperTeam,
        certificateId: String,
        type: String,
        cookies: [HTTPCookie],
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> Bool {
        onLog?(LogMessage(level: .info, message: "[Portal] Revoking certificate \(certificateId) (type: \(type)) for team \(team.name)..."))

        // 1. Try modern v1 REST API DELETE first
        let v1URL = URL(string: "https://developer.apple.com/services-account/v1/certificates/\(certificateId)")!
        var v1Req = URLRequest(url: v1URL)
        v1Req.httpMethod = "DELETE"
        v1Req.setValue("application/vnd.api+json, application/json", forHTTPHeaderField: "Accept")
        v1Req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if !cookies.isEmpty {
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            v1Req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let v1Res = try? await executePortalRequest(v1Req, session: urlSession, operationName: "v1/certificates/\(certificateId) (DELETE)", onLog: onLog),
           (v1Res.response.statusCode == 200 || v1Res.response.statusCode == 204) {
            onLog?(LogMessage(level: .success, message: "[Portal] Successfully revoked certificate \(certificateId) via modern REST API."))
            return true
        }

        // 2. Try legacy iOS endpoint
        let revokeURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/certificate/revokeCertificate.action")!
        let params = [
            "teamId": team.id,
            "certificateId": certificateId,
            "type": type
        ]
        let req = makePortalRequest(url: revokeURL, method: "POST", bodyParams: params, cookies: cookies, urlSession: urlSession)
        let res = try await executePortalRequest(req, session: urlSession, operationName: "revokeCertificate.action", onLog: onLog)
        if res.response.statusCode == 200, let json = res.json {
            let code = (json["resultCode"] as? Int) ?? -1
            if code == 0 {
                onLog?(LogMessage(level: .success, message: "[Portal] Successfully revoked certificate \(certificateId)"))
                return true
            }
        }

        // 3. Try legacy Mac endpoint
        let macRevokeURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/mac/certificate/revokeCertificate.action")!
        let macReq = makePortalRequest(url: macRevokeURL, method: "POST", bodyParams: params, cookies: cookies, urlSession: urlSession)
        if let macRes = try? await executePortalRequest(macReq, session: urlSession, operationName: "mac/revokeCertificate.action", onLog: onLog),
           macRes.response.statusCode == 200, let json = macRes.json,
           ((json["resultCode"] as? Int) ?? -1) == 0 {
            onLog?(LogMessage(level: .success, message: "[Portal] Successfully revoked Mac certificate \(certificateId)"))
            return true
        }

        onLog?(LogMessage(level: .error, message: "[Portal] Revoke request failed for certificate \(certificateId)"))
        return false
    }

    public func downloadPortalCertificate(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        certificateId: String,
        type: String,
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> Data {
        let (urlSession, initialCookies) = makeSession(from: session)
        let cookies = await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: initialCookies, onLog: onLog)

        onLog?(LogMessage(level: .info, message: "[Portal] Downloading certificate \(certificateId)..."))

        // 1. Try modern v1 REST API endpoint first
        let v1URL = URL(string: "https://developer.apple.com/services-account/v1/certificates/\(certificateId)")!
        var v1Req = URLRequest(url: v1URL)
        v1Req.httpMethod = "GET"
        v1Req.setValue("application/vnd.api+json, application/json", forHTTPHeaderField: "Accept")
        v1Req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if !cookies.isEmpty {
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            v1Req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let v1Res = try? await executePortalRequest(v1Req, session: urlSession, operationName: "v1/certificates/\(certificateId)", onLog: onLog),
           v1Res.response.statusCode == 200, let json = v1Res.json,
           let dataObj = json["data"] as? [String: Any],
           let attrs = dataObj["attributes"] as? [String: Any],
           let contentStr = attrs["certificateContent"] as? String {
            if let derData = Data(base64Encoded: contentStr) {
                onLog?(LogMessage(level: .success, message: "[Portal] Downloaded certificate via modern REST API: \(derData.count) bytes"))
                return derData
            } else if let utfData = contentStr.data(using: .utf8) {
                return utfData
            }
        }

        // 2. Try legacy iOS download endpoint
        let dlURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/certificate/downloadCertificateContent.action?teamId=\(team.id)&certificateId=\(certificateId)&type=\(type)")!
        let req = makePortalRequest(url: dlURL, method: "GET", cookies: cookies, urlSession: urlSession)
        if let res = try? await executePortalRequest(req, session: urlSession, operationName: "downloadCertificateContent.action", onLog: onLog),
           res.response.statusCode == 200, !res.data.isEmpty {
            onLog?(LogMessage(level: .success, message: "[Portal] Downloaded certificate: \(res.data.count) bytes"))
            return res.data
        }

        // 3. Try legacy Mac download endpoint
        let macDlURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/mac/certificate/downloadCertificateContent.action?teamId=\(team.id)&certificateId=\(certificateId)&type=\(type)")!
        let macReq = makePortalRequest(url: macDlURL, method: "GET", cookies: cookies, urlSession: urlSession)
        if let res = try? await executePortalRequest(macReq, session: urlSession, operationName: "mac/downloadCertificateContent.action", onLog: onLog),
           res.response.statusCode == 200, !res.data.isEmpty {
            onLog?(LogMessage(level: .success, message: "[Portal] Downloaded Mac certificate: \(res.data.count) bytes"))
            return res.data
        }

        throw AppleDeveloperError.apiError("Failed to download certificate from Apple Developer Portal.")
    }

    public func fetchTeamWildcardProfile(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async -> Data? {
        let (urlSession, initialCookies) = makeSession(from: session)
        let cookies = await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: initialCookies, onLog: onLog)

        onLog?(LogMessage(level: .info, message: "[Portal] Querying provisioning profiles for team \(team.name)..."))
        let xcodeURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/ios/listProvisioningProfiles.action")!
        let xcodeParams = [
            "teamId": team.id,
            "includeInactiveProfiles": "true",
            "includeExpiredProfiles": "false",
            "onlyCountLists": "true"
        ]
        let xcodeReq = makePortalRequest(url: xcodeURL, method: "POST", bodyParams: xcodeParams, cookies: cookies, urlSession: urlSession)

        do {
            let res = try await executePortalRequest(xcodeReq, session: urlSession, operationName: "listProvisioningProfiles.action", onLog: onLog)
            if res.response.statusCode == 200,
               let plist = try? PropertyListSerialization.propertyList(from: res.data, options: [], format: nil) as? [String: Any],
               let profiles = plist["provisioningProfiles"] as? [[String: Any]] {

                onLog?(LogMessage(level: .info, message: "[Portal] Received \(profiles.count) provisioning profile(s) from Apple."))
                for prof in profiles {
                    if let encodedData = prof["encodedProfile"] as? Data {
                        return encodedData
                    } else if let b64Str = prof["encodedProfile"] as? String, let decoded = Data(base64Encoded: b64Str) {
                        return decoded
                    }
                }
            }
        } catch {
            onLog?(LogMessage(level: .warning, message: "[Portal] Failed to fetch provisioning profiles: \(error.localizedDescription)"))
        }
        return nil
    }

    // App IDs
    public func fetchPortalAppIds(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> [PortalAppId] {
        let (urlSession, initialCookies) = makeSession(from: session)
        logCookieSummary(cookies: initialCookies, onLog: onLog)
        let cookies = await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: initialCookies, onLog: onLog)

        onLog?(LogMessage(level: .info, message: "[Portal] Querying App IDs for team \(team.name) (\(team.id))..."))

        let listURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/identifiers/listAppIds.action")!
        let params: [String: String] = [
            "teamId": team.id,
            "pageNumber": "1",
            "pageSize": "500",
            "sort": "name=asc"
        ]
        let req = makePortalRequest(url: listURL, method: "POST", bodyParams: params, cookies: cookies, urlSession: urlSession)
        do {
            let res = try await executePortalRequest(req, session: urlSession, operationName: "listAppIds.action", onLog: onLog)
            if res.response.statusCode == 200, let dict = res.json,
               let appIds = dict["appIds"] as? [[String: Any]], !appIds.isEmpty {
                let parsed = parseAppIds(appIds, teamId: team.id)
                onLog?(LogMessage(level: .success, message: "[Portal] Found \(parsed.count) App ID(s) via developer portal."))
                return parsed
            }
        } catch {
            onLog?(LogMessage(level: .warning, message: "[Portal] listAppIds failed: \(error.localizedDescription)"))
        }

        // Fallback to Xcode endpoint
        onLog?(LogMessage(level: .info, message: "[Portal] Trying Xcode listAppIds endpoint fallback..."))
        let xcURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/ios/listAppIds.action")!
        let xcReq = makeXcodePlistRequest(url: xcURL, params: ["teamId": team.id, "pageSize": 500, "pageNumber": 1], cookies: cookies)
        do {
            let res = try await executePortalRequest(xcReq, session: urlSession, operationName: "developerservices2/listAppIds.action", onLog: onLog)
            if res.response.statusCode == 200, let dict = res.json,
               let appIds = dict["appIds"] as? [[String: Any]] {
                let parsed = parseAppIds(appIds, teamId: team.id)
                onLog?(LogMessage(level: .success, message: "[Portal] Found \(parsed.count) App ID(s) via Xcode endpoint."))
                return parsed
            }
        } catch {
            onLog?(LogMessage(level: .error, message: "[Portal] Xcode listAppIds failed: \(error.localizedDescription)"))
        }

        onLog?(LogMessage(level: .info, message: "[Portal] No App IDs found for team \(team.id)."))
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
        appIdId: String,
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> Bool {
        let (urlSession, initialCookies) = makeSession(from: session)
        let cookies = await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: initialCookies, onLog: onLog)

        onLog?(LogMessage(level: .info, message: "[Portal] Deleting App ID \(appIdId) for team \(team.name)..."))

        let deleteURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/identifiers/deleteAppId.action")!
        let req = makePortalRequest(url: deleteURL, method: "POST", bodyParams: ["teamId": team.id, "appIdId": appIdId], cookies: cookies, urlSession: urlSession)
        let res = try await executePortalRequest(req, session: urlSession, operationName: "deleteAppId.action", onLog: onLog)

        guard res.response.statusCode == 200, let json = res.json else {
            onLog?(LogMessage(level: .error, message: "[Portal] deleteAppId request failed with HTTP \(res.response.statusCode)"))
            return false
        }
        let code = (json["resultCode"] as? Int) ?? -1
        let success = code == 0
        if success {
            onLog?(LogMessage(level: .success, message: "[Portal] Successfully deleted App ID \(appIdId)"))
        } else {
            let msg = (json["userString"] as? String) ?? "resultCode \(code)"
            onLog?(LogMessage(level: .error, message: "[Portal] Apple rejected App ID deletion: \(msg)"))
        }
        return success
    }

    public func createPortalAppId(
        session: AppleDeveloperSession,
        team: DeveloperTeam,
        name: String,
        identifier: String,
        onLog: (@Sendable (LogMessage) -> Void)? = nil
    ) async throws -> PortalAppId {
        let (urlSession, initialCookies) = makeSession(from: session)
        let cookies = await selectPortalTeam(urlSession: urlSession, teamId: team.id, cookies: initialCookies, onLog: onLog)

        onLog?(LogMessage(level: .info, message: "[Portal] Creating App ID '\(identifier)' (\(name)) for team \(team.name)..."))

        let addURL = URL(string: "https://developer.apple.com/services-account/QH65B2/account/ios/identifiers/addAppId.action")!
        let type = identifier.contains("*") ? "wildcard" : "explicit"
        let params = [
            "teamId": team.id,
            "name": name,
            "identifier": identifier,
            "type": type
        ]
        let req = makePortalRequest(url: addURL, method: "POST", bodyParams: params, cookies: cookies, urlSession: urlSession)
        let res = try await executePortalRequest(req, session: urlSession, operationName: "addAppId.action", onLog: onLog)

        guard res.response.statusCode == 200, let json = res.json else {
            throw AppleDeveloperError.apiError("Failed to register App ID (HTTP \(res.response.statusCode)).")
        }

        if let appId = json["appId"] as? [String: Any],
           let id = (appId["appIdId"] as? String) ?? (appId["id"] as? String) {
            onLog?(LogMessage(level: .success, message: "[Portal] App ID '\(identifier)' created with ID \(id)."))
            return PortalAppId(id: id, name: name, identifier: identifier, prefix: team.id, isWildcard: identifier.contains("*"))
        }

        if let userStr = json["userString"] as? String {
            onLog?(LogMessage(level: .error, message: "[Portal] Apple rejected App ID creation: \(userStr)"))
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
