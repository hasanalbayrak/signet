import Foundation

public struct Apple2FAContext: Sendable {
    public let appleId: String
    public let sessionId: String?
    public let scnt: String?
    public let cookies: [HTTPCookie]
    public let codeLength: Int

    public init(
        appleId: String,
        sessionId: String?,
        scnt: String?,
        cookies: [HTTPCookie],
        codeLength: Int = 6
    ) {
        self.appleId = appleId
        self.sessionId = sessionId
        self.scnt = scnt
        self.cookies = cookies
        self.codeLength = codeLength
    }
}

public struct AppleDeveloperSession: Codable, Hashable, Sendable {
    public let appleId: String
    public let userFullName: String
    public var selectedTeamId: String?
    public var selectedTeamName: String?
    public let sessionToken: String?
    public let cookiesData: Data?

    public init(
        appleId: String,
        userFullName: String,
        selectedTeamId: String? = nil,
        selectedTeamName: String? = nil,
        sessionToken: String? = nil,
        cookiesData: Data? = nil
    ) {
        self.appleId = appleId
        self.userFullName = userFullName
        self.selectedTeamId = selectedTeamId
        self.selectedTeamName = selectedTeamName
        self.sessionToken = sessionToken
        self.cookiesData = cookiesData
    }
}

public enum AppleAuthResult {
    case success(session: AppleDeveloperSession, teams: [DeveloperTeam])
    case requires2FA(context: Apple2FAContext)
    case failed(message: String)
}
