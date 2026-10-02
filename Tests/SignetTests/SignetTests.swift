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
}
