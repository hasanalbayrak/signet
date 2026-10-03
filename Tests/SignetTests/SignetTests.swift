import XCTest
import CryptoKit
@testable import Signet

final class SignetTests: XCTestCase {
    func testDeviceModelFormatting() {
        let device = Device(
            udid: "00008140-001C59C901FB001C",
            name: "Hasan iPhone’u",
            model: "iPhone 16 Pro",
            productType: "iPhone17,1",
            osVersion: "18.2",
            connectionType: .usb,
            isPaired: true,
            isAvailable: true,
            developerModeEnabled: true
        )

        XCTAssertEqual(device.displayName, "Hasan iPhone’u")
        XCTAssertEqual(device.shortUDID, "000081...001C")
        XCTAssertEqual(device.deviceIconName, "iphone")
        XCTAssertTrue(device.statusDescription.contains("iOS 18.2"))
    }

    func testCertificateValidityCalculations() {
        let oneYearFromNow = Date().addingTimeInterval(365 * 86400)
        let cert = CertificateInfo(
            commonName: "Apple Development: Test User (ABC1234XYZ)",
            teamId: "ABC1234XYZ",
            teamName: "Test User",
            creationDate: Date(),
            expirationDate: oneYearFromNow
        )

        XCTAssertFalse(cert.isExpired)
        XCTAssertGreaterThanOrEqual(cert.daysRemaining, 364)
        XCTAssertFalse(cert.isExpiringSoon)
        XCTAssertTrue(cert.validityStatusText.contains("remaining"))

        let expiredDate = Date().addingTimeInterval(-86400)
        let expiredCert = CertificateInfo(
            commonName: "Apple Development: Expired",
            teamId: "ABC1234XYZ",
            teamName: "Expired User",
            expirationDate: expiredDate
        )

        XCTAssertTrue(expiredCert.isExpired)
        XCTAssertEqual(expiredCert.daysRemaining, 0)
        XCTAssertEqual(expiredCert.validityStatusText, "Expired")
    }

    func testProvisioningProfileWildcardAndDevices() {
        let profile = ProvisioningProfileInfo(
            name: "iOS Team Provisioning Profile: *",
            uuid: "12345678-ABCD-EF01-2345-6789ABCDEF01",
            teamId: "ABC1234XYZ",
            teamName: "Test Team",
            applicationIdentifier: "ABC1234XYZ.*",
            isWildcard: true,
            expirationDate: Date().addingTimeInterval(365 * 86400),
            provisionedDevices: ["00008140-001C59C901FB001C"]
        )

        XCTAssertTrue(profile.isWildcard)
        XCTAssertTrue(profile.matchesDevice(udid: "00008140-001C59C901FB001C"))
        XCTAssertFalse(profile.matchesDevice(udid: "00000000-0000000000000000"))
    }

    func testProcessRunnerStreaming() async throws {
        final class Box: @unchecked Sendable {
            var lines: [String] = []
        }
        let box = Box()
        let runner = ProcessRunner()

        let result = try await runner.run(
            executablePath: "/bin/echo",
            arguments: ["Hello Signet Native"]
        ) { line in
            box.lines.append(line)
        }

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Hello Signet Native"))
        XCTAssertFalse(box.lines.isEmpty)
    }

    func testBinaryManagerReport() {
        let report = BinaryManager.shared.getStatusReport()
        XCTAssertFalse(report.isEmpty)

        // At least zsign should be discovered in Resources or path
        let zsignInfo = report.first { $0.name.contains("zsign") }
        XCTAssertNotNil(zsignInfo)
    }

    func testAppStoreConnectJWTSigning() throws {
        // Generate a test P256 key
        let testKey = CryptoKit.P256.Signing.PrivateKey()
        let pemString = testKey.pemRepresentation

        let creds = AppStoreConnectCredentials(
            keyId: "TESTKEY123",
            issuerId: "57246542-96fe-1a63-e053-0824d011072a",
            privateKeyPem: pemString
        )

        XCTAssertTrue(creds.isValid)

        let jwt = try AppleDeveloperService.shared.generateJWT(credentials: creds)
        let parts = jwt.components(separatedBy: ".")
        XCTAssertEqual(parts.count, 3, "JWT must consist of header, payload, and signature")

        // Validate Header contains ES256 and kid
        var headerB64 = parts[0]
        while headerB64.count % 4 != 0 { headerB64.append("=") }
        let headerData = try XCTUnwrap(Data(base64Encoded: headerB64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")))
        let headerJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: headerData) as? [String: Any])
        XCTAssertEqual(headerJSON["alg"] as? String, "ES256")
        XCTAssertEqual(headerJSON["kid"] as? String, "TESTKEY123")

        // Validate Payload contains issuer and audience
        var payloadB64 = parts[1]
        while payloadB64.count % 4 != 0 { payloadB64.append("=") }
        let payloadData = try XCTUnwrap(Data(base64Encoded: payloadB64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")))
        let payloadJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        XCTAssertEqual(payloadJSON["iss"] as? String, "57246542-96fe-1a63-e053-0824d011072a")
        XCTAssertEqual(payloadJSON["aud"] as? String, "appstoreconnect-v1")
    }

    func testDeveloperTeamDisplay() {
        let team = DeveloperTeam(id: "ABC1234XYZ", name: "Hasan Albayrak", type: "Individual")
        XCTAssertEqual(team.displayTitle, "Hasan Albayrak (ABC1234XYZ)")
    }

    func testAppleDeveloperSessionPersistence() throws {
        let session = AppleDeveloperSession(
            appleId: "developer@example.com",
            userFullName: "Hasan Albayrak",
            selectedTeamId: "ABC1234XYZ",
            selectedTeamName: "Hasan Team",
            sessionToken: "test_token_123"
        )

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AppleDeveloperSession.self, from: encoded)

        XCTAssertEqual(decoded.appleId, "developer@example.com")
        XCTAssertEqual(decoded.userFullName, "Hasan Albayrak")
        XCTAssertEqual(decoded.selectedTeamId, "ABC1234XYZ")
        XCTAssertEqual(decoded.selectedTeamName, "Hasan Team")
        XCTAssertEqual(decoded.sessionToken, "test_token_123")
    }

    func testDeveloperMultipleTeamsParsingAndPersistence() throws {
        let teams = [
            DeveloperTeam(id: "COMP1234AA", name: "Company One Ltd", type: "Company/Organization", status: "active"),
            DeveloperTeam(id: "COMP5678BB", name: "Company Two Inc", type: "Company/Organization", status: "active")
        ]

        XCTAssertEqual(teams.count, 2)
        XCTAssertEqual(teams[0].displayTitle, "Company One Ltd (COMP1234AA)")
        XCTAssertEqual(teams[1].displayTitle, "Company Two Inc (COMP5678BB)")

        let data = try JSONEncoder().encode(teams)
        let decoded = try JSONDecoder().decode([DeveloperTeam].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].id, "COMP1234AA")
        XCTAssertEqual(decoded[1].id, "COMP5678BB")
        XCTAssertEqual(decoded[0].type, "Company/Organization")
        XCTAssertEqual(decoded[1].type, "Company/Organization")
    }

    func testPortalModels() {
        // Device
        let device = PortalDevice(id: "D123", name: "iPhone 15 Pro", udid: "00008110-123456", deviceClass: "iphone", model: "A3101", status: "Y")
        XCTAssertEqual(device.id, "D123")
        XCTAssertTrue(device.isEnabled)
        XCTAssertEqual(device.displayClassIcon, "iphone")

        let ipad = PortalDevice(id: "D456", name: "iPad Pro", udid: "00008120-654321", deviceClass: "ipad", status: "Disabled")
        XCTAssertFalse(ipad.isEnabled)
        XCTAssertEqual(ipad.displayClassIcon, "ipad")

        // Certificate
        let cert = PortalCertificate(
            id: "C789",
            name: "Signet Development",
            type: "83Q87W3TGH",
            typeDisplayName: "Apple Development",
            status: "Issued",
            expirationDate: "2027-10-02"
        )
        XCTAssertEqual(cert.id, "C789")
        XCTAssertTrue(cert.isIssued)

        // App ID
        let wildcardAppId = PortalAppId(id: "A111", name: "Signet Wildcard", identifier: "*", prefix: "ABC1234XYZ")
        XCTAssertTrue(wildcardAppId.isWildcard)

        let explicitAppId = PortalAppId(id: "A222", name: "App Explicit", identifier: "com.example.app", prefix: "ABC1234XYZ")
        XCTAssertFalse(explicitAppId.isWildcard)
    }

    func testHomebrewResolution() {
        let brewAvailable = BinaryManager.shared.isBrewAvailable
        if brewAvailable {
            XCTAssertNotNil(BinaryManager.shared.resolveBrew())
        }
    }

    func testCookieEncodingAndDecoding() {
        guard let cookie = HTTPCookie(properties: [
            .name: "my_cookie",
            .value: "secret_value_123",
            .domain: ".apple.com",
            .path: "/"
        ]) else {
            XCTFail("Failed to create test HTTPCookie")
            return
        }

        let encoded = AppleAuthService.encodeCookies([cookie])
        XCTAssertNotNil(encoded)

        let decoded = AppleAuthService.decodeCookies(from: encoded!)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.name, "my_cookie")
        XCTAssertEqual(decoded.first?.value, "secret_value_123")
        XCTAssertEqual(decoded.first?.domain, ".apple.com")
        XCTAssertEqual(decoded.first?.path, "/")
    }

    func testKeychainIdentityWithTeamDetails() {
        let identity = KeychainIdentity(
            id: "5F38A812A2120AF6C79E9AA236A2DCA303C6A1CF",
            name: "Apple Development: Hasan Huseyin Albayrak (262LJ4XX94)",
            teamId: "7Q6TQV2UKJ",
            teamName: "WAGONN BILGI TEKNOLOJILERI VE DANISMANLIK LIMITED SIRKETI"
        )

        XCTAssertEqual(identity.id, "5F38A812A2120AF6C79E9AA236A2DCA303C6A1CF")
        XCTAssertEqual(identity.teamId, "7Q6TQV2UKJ")
        XCTAssertEqual(identity.teamName, "WAGONN BILGI TEKNOLOJILERI VE DANISMANLIK LIMITED SIRKETI")
    }

    func testAppleSiliconMacDeviceModel() {
        let mac = Device(
            udid: "80ED4E57-035D-5BD1-84F5-6B9B879A9BA0",
            name: "Hasan MacBook Pro",
            model: "Apple Silicon Mac (Mac14,6)",
            productType: "Mac14,6",
            osVersion: "macOS 15.3.1",
            connectionType: .local,
            isPaired: true,
            isAvailable: true,
            developerModeEnabled: true,
            serialNumber: "GV9X0G54X2",
            cpuArchitecture: "arm64",
            buildVersion: "24D60",
            isAppleSiliconMac: true
        )

        XCTAssertEqual(mac.displayName, "Hasan MacBook Pro (Mac)")
        XCTAssertEqual(mac.deviceIconName, "macbook")
        XCTAssertEqual(mac.connectionType, .local)
        XCTAssertTrue(mac.isAppleSiliconMac)
        XCTAssertEqual(mac.serialNumber, "GV9X0G54X2")
        XCTAssertEqual(mac.cpuArchitecture, "arm64")
        XCTAssertEqual(mac.buildVersion, "24D60")
        XCTAssertTrue(mac.statusDescription.contains("Apple Silicon"))
    }

    func testAppleSiliconMacDiscovery() {
        let mac = DeviceService.shared.getLocalAppleSiliconMac()
        #if arch(arm64)
        XCTAssertNotNil(mac)
        XCTAssertEqual(mac?.connectionType, .local)
        XCTAssertTrue(mac?.isAppleSiliconMac == true)
        XCTAssertFalse(mac?.udid.isEmpty ?? true)
        #else
        XCTAssertNil(mac)
        #endif
    }

    func testPortalCertificateDistributionAndTeamScopes() {
        let distCert = PortalCertificate(
            id: "CERT_DIST_1",
            name: "Apple Distribution: Example Company (XYZ)",
            type: "WXV89964HE",
            typeDisplayName: "Apple Distribution",
            status: "Issued",
            ownerName: "Example Company",
            ownerType: "team"
        )
        XCTAssertTrue(distCert.isDistribution)
        XCTAssertTrue(distCert.isTeamScoped)

        let devCert = PortalCertificate(
            id: "CERT_DEV_1",
            name: "Apple Development: Hasan Albayrak (123)",
            type: "83Q87W3TGH",
            typeDisplayName: "Apple Development",
            status: "Issued",
            ownerName: "Hasan Albayrak",
            ownerType: "personal"
        )
        XCTAssertFalse(devCert.isDistribution)
        XCTAssertFalse(devCert.isTeamScoped)

        let iosDistCert = PortalCertificate(
            id: "CERT_IOS_DIST",
            name: "iPhone Distribution: Team Corp",
            type: "R5DG2F3R6A",
            typeDisplayName: "iOS Distribution",
            status: "Issued",
            ownerName: "Team Corp",
            ownerType: "team"
        )
        XCTAssertTrue(iosDistCert.isDistribution)
        XCTAssertTrue(iosDistCert.isTeamScoped)

        let storeDistCert = PortalCertificate(
            id: "CERT_STORE_DIST",
            name: "iOS Distribution: Team Store",
            type: "R58UK2EWSO",
            typeDisplayName: "iOS Distribution",
            status: "Issued",
            ownerName: "Team Store",
            ownerType: "team"
        )
        XCTAssertTrue(storeDistCert.isDistribution)
        XCTAssertTrue(storeDistCert.isTeamScoped)

        let inHouseCert = PortalCertificate(
            id: "CERT_INHOUSE",
            name: "Enterprise Distribution: Team Corp",
            type: "9RQEK7MSXA",
            typeDisplayName: "iOS Distribution (In-House)",
            status: "Issued",
            ownerName: "Team Corp",
            ownerType: "team"
        )
        XCTAssertTrue(inHouseCert.isDistribution)
        XCTAssertTrue(inHouseCert.isTeamScoped)
    }

    func testIPAEntitlementsCreationAndCategorization() {
        let dict: [String: Any] = [
            "application-identifier": "TEAM123456.com.example.MyApp",
            "get-task-allow": true,
            "keychain-access-groups": ["TEAM123456.com.example.MyApp", "TEAM123456.shared"],
            "com.apple.developer.associated-domains": ["applinks:example.com"],
            "com.apple.security.application-groups": ["group.com.example.myapp"],
            "aps-environment": "development"
        ]

        let entitlements = IPAEntitlements.from(dictionary: dict, source: .codeSignature)
        XCTAssertEqual(entitlements.count, 6)
        XCTAssertEqual(entitlements.applicationIdentifier, "TEAM123456.com.example.MyApp")
        XCTAssertEqual(entitlements.teamId, "TEAM123456")
        XCTAssertEqual(entitlements.getTaskAllow, true)
        XCTAssertEqual(entitlements.keychainAccessGroups.count, 2)
        XCTAssertEqual(entitlements.appGroups, ["group.com.example.myapp"])
        XCTAssertEqual(entitlements.associatedDomains, ["applinks:example.com"])
        XCTAssertEqual(entitlements.apsEnvironment, "development")

        // Verify XML generation
        XCTAssertTrue(entitlements.rawXML.contains("<plist"))
        XCTAssertTrue(entitlements.rawXML.contains("TEAM123456.com.example.MyApp"))

        // Verify Categories
        let items = entitlements.items
        let identityItem = items.first { $0.key == "application-identifier" }
        XCTAssertEqual(identityItem?.category, .identity)

        let appGroupItem = items.first { $0.key == "com.apple.security.application-groups" }
        XCTAssertEqual(appGroupItem?.category, .appGroups)

        let keychainItem = items.first { $0.key == "keychain-access-groups" }
        XCTAssertEqual(keychainItem?.category, .keychain)

        let pushItem = items.first { $0.key == "aps-environment" }
        XCTAssertEqual(pushItem?.category, .push)
    }

    func testIPAEntitlementsAdaptation() {
        let dict: [String: Any] = [
            "application-identifier": "OLDTEAM123.com.source.app",
            "com.apple.developer.team-identifier": "OLDTEAM123",
            "keychain-access-groups": ["OLDTEAM123.com.source.app", "OLDTEAM123.sharedKey"],
            "com.apple.security.application-groups": ["group.com.source.app"],
            "get-task-allow": true
        ]

        let sourceEnt = IPAEntitlements.from(dictionary: dict, source: .codeSignature)
        let adapted = sourceEnt.adapted(newTeamId: "NEWTEAM456", newBundleId: "com.target.custom")

        XCTAssertEqual(adapted.teamId, "NEWTEAM456")
        XCTAssertEqual(adapted.applicationIdentifier, "NEWTEAM456.com.target.custom")
        XCTAssertEqual(adapted.dictionary["com.apple.developer.team-identifier"] as? String, "NEWTEAM456")

        let newKeychain = adapted.keychainAccessGroups
        XCTAssertEqual(newKeychain.count, 2)
        XCTAssertEqual(newKeychain[0], "NEWTEAM456.com.source.app")
        XCTAssertEqual(newKeychain[1], "NEWTEAM456.sharedKey")

        // Other capabilities preserved
        XCTAssertEqual(adapted.appGroups, ["group.com.source.app"])
        XCTAssertEqual(adapted.getTaskAllow, true)
    }

    func testExportAndImportEntitlementsFile() throws {
        let dict: [String: Any] = [
            "application-identifier": "ABC999XYZ.com.export.test",
            "get-task-allow": false,
            "com.apple.developer.associated-domains": ["applinks:test.org"]
        ]

        let entitlements = IPAEntitlements.from(dictionary: dict, source: .provisioningProfile)

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("exported_test_\(UUID().uuidString).entitlements")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        try IPAManager.shared.exportEntitlements(entitlements, to: tempFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path))

        let imported = try IPAManager.shared.importEntitlements(from: tempFile)
        XCTAssertEqual(imported.count, 3)
        XCTAssertEqual(imported.applicationIdentifier, "ABC999XYZ.com.export.test")
        XCTAssertEqual(imported.getTaskAllow, false)
        XCTAssertEqual(imported.associatedDomains, ["applinks:test.org"])
    }

    func testSigningConfigurationEntitlementsFlag() {
        var config = SigningConfiguration()
        XCTAssertFalse(config.hasCustomEntitlements)

        let testURL = URL(fileURLWithPath: "/tmp/custom.entitlements")
        config.customEntitlementsURL = testURL
        XCTAssertTrue(config.hasCustomEntitlements)

        config.customEntitlementsURL = nil
        config.customEntitlementsContent = "<plist><dict></dict></plist>"
        XCTAssertTrue(config.hasCustomEntitlements)
    }

    func testMockIPAEntitlementsExtraction() async throws {
        // Create a temporary mock IPA zip file with Payload/MockApp.app/Info.plist and embedded .xcent
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MockIPABuild_\(UUID().uuidString)")
        let appDir = tempDir.appendingPathComponent("Payload/MockApp.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": "com.mock.app",
            "CFBundleDisplayName": "Mock App",
            "CFBundleShortVersionString": "2.0.1",
            "CFBundleVersion": "42",
            "CFBundleExecutable": "MockApp"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try infoData.write(to: appDir.appendingPathComponent("Info.plist"))

        let mockEntitlements: [String: Any] = [
            "application-identifier": "MOCKTEAM99.com.mock.app",
            "com.apple.security.application-groups": ["group.mock.shared"],
            "get-task-allow": true
        ]
        let xcentData = try PropertyListSerialization.data(fromPropertyList: mockEntitlements, format: .xml, options: 0)
        try xcentData.write(to: appDir.appendingPathComponent("MockApp.xcent"))

        // Create zip archive (.ipa) using /usr/bin/zip
        let ipaURL = FileManager.default.temporaryDirectory.appendingPathComponent("MockApp_\(UUID().uuidString).ipa")
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: ipaURL)
        }

        let zipTask = Process()
        zipTask.currentDirectoryURL = tempDir
        zipTask.launchPath = "/usr/bin/zip"
        zipTask.arguments = ["-q", "-r", ipaURL.path, "Payload"]
        try zipTask.run()
        zipTask.waitUntilExit()
        XCTAssertEqual(zipTask.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ipaURL.path))

        // Inspect IPA and extract entitlements
        let metadata = await IPAManager.shared.inspectIPA(at: ipaURL)
        XCTAssertEqual(metadata.displayName, "Mock App")
        XCTAssertEqual(metadata.bundleIdentifier, "com.mock.app")
        XCTAssertEqual(metadata.version, "2.0.1")
        XCTAssertEqual(metadata.buildNumber, "42")
        XCTAssertEqual(metadata.executableName, "MockApp")

        let extractedEnt = try await IPAManager.shared.extractEntitlements(from: ipaURL)
        XCTAssertEqual(extractedEnt.applicationIdentifier, "MOCKTEAM99.com.mock.app")
        XCTAssertEqual(extractedEnt.teamId, "MOCKTEAM99")
        XCTAssertEqual(extractedEnt.appGroups, ["group.mock.shared"])
        XCTAssertEqual(extractedEnt.getTaskAllow, true)
    }
}

