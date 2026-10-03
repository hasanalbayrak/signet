import Foundation
import AppKit

public enum IPAManagerError: LocalizedError {
    case fileNotFound(String)
    case unzippingFailed(String)
    case entitlementsNotFound
    case invalidEntitlementsData
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "IPA file not found at path: \(path)"
        case .unzippingFailed(let reason):
            return "Failed to inspect IPA archive: \(reason)"
        case .entitlementsNotFound:
            return "No entitlements found in the specified IPA."
        case .invalidEntitlementsData:
            return "Entitlements data could not be parsed as a valid XML property list."
        case .exportFailed(let reason):
            return "Failed to export entitlements: \(reason)"
        }
    }
}

public final class IPAManager: @unchecked Sendable {
    public static let shared = IPAManager()

    private init() {}

    // MARK: - IPA Inspection

    /// Extracts bundle identifier, display name, version, architecture, package details and entitlements from an IPA.
    public func inspectIPA(at fileURL: URL) async -> IPAMetadata {
        let fileName = fileURL.lastPathComponent
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        var metadata = IPAMetadata(fileURL: fileURL, fileName: fileName, fileSize: fileSize)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return metadata
        }

        // 1. Extract Info.plist (Fast & safe, Info.plist is only ~5-20KB)
        let infoPlistData = await runUnzipPipeData(arguments: ["-p", fileURL.path, "Payload/*.app/Info.plist"], timeout: 5.0)
        if !infoPlistData.isEmpty,
           let plist = try? PropertyListSerialization.propertyList(from: infoPlistData, options: [], format: nil) as? [String: Any] {
            metadata.bundleIdentifier = plist["CFBundleIdentifier"] as? String
            metadata.displayName = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            metadata.version = plist["CFBundleShortVersionString"] as? String
            metadata.buildNumber = plist["CFBundleVersion"] as? String
            metadata.minimumOSVersion = plist["MinimumOSVersion"] as? String
            metadata.executableName = plist["CFBundleExecutable"] as? String
        }

        // 2. Extract Entitlements (Strategy: mobileprovision -> xcent -> binary)
        if let entitlements = try? await extractEntitlements(from: fileURL, executableName: metadata.executableName) {
            metadata.entitlements = entitlements
        }

        // 3. Package Details (Frameworks, Plugins, Mobileprovision info) - Non-blocking
        let packageDetails = await inspectPackageDetails(at: fileURL, executableName: metadata.executableName)
        metadata.packageDetails = packageDetails

        return metadata
    }

    // MARK: - Package Details Inspection

    /// Gathers framework names, plugins/extensions, and provisioning profile details from the IPA
    public func inspectPackageDetails(at fileURL: URL, executableName: String? = nil) async -> IPAPackageDetails {
        var details = IPAPackageDetails(executableName: executableName)

        // List files inside archive using /usr/bin/unzip -l with deadlock-free pipe draining
        let (_, stdoutData, _) = await runProcessCaptureData(
            executable: "/usr/bin/unzip",
            arguments: ["-l", fileURL.path],
            timeoutSeconds: 8.0
        )

        var frameworkNames = Set<String>()
        var extensionNames = Set<String>()

        if let output = String(data: stdoutData, encoding: .utf8) {
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let lastComponent = trimmed.components(separatedBy: .whitespaces).last else { continue }

                if lastComponent.contains(".framework/") {
                    let parts = lastComponent.components(separatedBy: "/")
                    if let fw = parts.first(where: { $0.hasSuffix(".framework") }) {
                        frameworkNames.insert(fw)
                    }
                } else if lastComponent.hasSuffix(".dylib") {
                    let dylib = URL(fileURLWithPath: lastComponent).lastPathComponent
                    frameworkNames.insert(dylib)
                } else if lastComponent.contains(".appex/") || lastComponent.hasSuffix(".appex") {
                    let parts = lastComponent.components(separatedBy: "/")
                    if let ext = parts.first(where: { $0.hasSuffix(".appex") }) {
                        extensionNames.insert(ext)
                    }
                }
            }
        }

        details.frameworks = Array(frameworkNames).sorted()
        details.appExtensions = Array(extensionNames).sorted()

        // Inspect embedded.mobileprovision
        if let provData = await readEmbeddedMobileprovisionData(at: fileURL) {
            if let decodedXml = decodeProvisioningProfile(data: provData),
               let plist = try? PropertyListSerialization.propertyList(from: decodedXml, options: [], format: nil) as? [String: Any] {
                details.provisioningProfileName = plist["Name"] as? String
                details.provisioningProfileExpiration = plist["ExpirationDate"] as? Date
                if let teamList = plist["TeamIdentifier"] as? [String], let firstTeam = teamList.first {
                    details.provisioningProfileTeamId = firstTeam
                }
                if let ent = plist["Entitlements"] as? [String: Any],
                   let appId = ent["application-identifier"] as? String {
                    details.isWildcardProfile = appId.hasSuffix("*")
                }
            }
        }

        return details
    }

    // MARK: - Entitlements Extraction

    /// Extracts entitlements using an ultra-fast, multi-strategy pipeline:
    /// Strategy 1: embedded.mobileprovision (Fastest, ~10ms, authoritative Apple-approved profile entitlements)
    /// Strategy 2: Embedded .xcent / .entitlements files in Payload
    /// Strategy 3: Mach-O binary CodeSignature via extracting binary directly to disk (never through pipe) + codesign
    public func extractEntitlements(from ipaURL: URL, executableName: String? = nil) async throws -> IPAEntitlements {
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            throw IPAManagerError.fileNotFound(ipaURL.path)
        }

        // Strategy 1: embedded.mobileprovision (instant, no large binary extraction)
        if let mpEntitlements = await extractEntitlementsFromMobileprovision(ipaURL: ipaURL),
           !mpEntitlements.isEmpty {
            return mpEntitlements
        }

        // Strategy 2: Embedded .xcent / .entitlements file in bundle
        if let xcentEntitlements = await extractEntitlementsFromXcent(ipaURL: ipaURL),
           !xcentEntitlements.isEmpty {
            return xcentEntitlements
        }

        // Strategy 3: Mach-O binary CodeSignature (extracts binary directly to disk without pipe buffer)
        if let csEntitlements = await extractEntitlementsFromCodeSignature(ipaURL: ipaURL, executableName: executableName),
           !csEntitlements.isEmpty {
            return csEntitlements
        }

        throw IPAManagerError.entitlementsNotFound
    }

    /// Strategy 1: Extract entitlements from embedded.mobileprovision (~10ms)
    public func extractEntitlementsFromMobileprovision(ipaURL: URL) async -> IPAEntitlements? {
        guard let provData = await readEmbeddedMobileprovisionData(at: ipaURL) else {
            return nil
        }

        guard let decodedData = decodeProvisioningProfile(data: provData) else {
            return nil
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: decodedData, options: [], format: nil) as? [String: Any],
              let entDict = plist["Entitlements"] as? [String: Any] else {
            return nil
        }

        return IPAEntitlements.from(dictionary: entDict, source: .provisioningProfile)
    }

    /// Strategy 2: Extract from embedded .xcent or .entitlements file
    public func extractEntitlementsFromXcent(ipaURL: URL) async -> IPAEntitlements? {
        let xcentData = await runUnzipPipeData(arguments: ["-p", ipaURL.path, "Payload/*.app/*.xcent"], timeout: 3.0)
        if !xcentData.isEmpty,
           let text = String(data: xcentData, encoding: .utf8),
           let xml = extractXMLSubstring(from: text),
           let ent = IPAEntitlements.from(xmlString: xml, source: .xcent), !ent.isEmpty {
            return ent
        }

        let entData = await runUnzipPipeData(arguments: ["-p", ipaURL.path, "Payload/*.app/*.entitlements"], timeout: 3.0)
        if !entData.isEmpty,
           let text = String(data: entData, encoding: .utf8),
           let xml = extractXMLSubstring(from: text),
           let ent = IPAEntitlements.from(xmlString: xml, source: .xcent), !ent.isEmpty {
            return ent
        }

        return nil
    }

    /// Strategy 3: Extract entitlements from Mach-O CodeSignature.
    /// CRITICAL: Extracts binary directly to disk with `-d <tempDir>` (NEVER pipes 50MB binary through stdout).
    public func extractEntitlementsFromCodeSignature(ipaURL: URL, executableName: String? = nil) async -> IPAEntitlements? {
        var execName = executableName
        if execName == nil {
            let infoPlistData = await runUnzipPipeData(arguments: ["-p", ipaURL.path, "Payload/*.app/Info.plist"], timeout: 3.0)
            if let plist = try? PropertyListSerialization.propertyList(from: infoPlistData, options: [], format: nil) as? [String: Any] {
                execName = plist["CFBundleExecutable"] as? String
            }
        }

        guard let targetExec = execName, !targetExec.isEmpty else { return nil }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Signet_CS_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // 1. Extract ONLY the executable directly onto disk with -q -o ... -d <tempDir>
        // This avoids any stdout pipe buffering and completes in < 0.2 seconds
        let (unzipCode, _, _) = await runProcessCaptureData(
            executable: "/usr/bin/unzip",
            arguments: ["-q", "-o", ipaURL.path, "Payload/*/\(targetExec)", "-d", tempDir.path],
            timeoutSeconds: 8.0
        )

        guard unzipCode == 0 else { return nil }

        // Find the extracted binary inside tempDir
        guard let extractedBinary = findFileNamed(targetExec, in: tempDir) else {
            return nil
        }

        // 2. Run /usr/bin/codesign -d --entitlements - --xml <extractedBinary>
        let (_, csOutData, csErrData) = await runProcessCaptureData(
            executable: "/usr/bin/codesign",
            arguments: ["-d", "--entitlements", "-", "--xml", extractedBinary.path],
            timeoutSeconds: 5.0
        )

        let combined = (String(data: csOutData, encoding: .utf8) ?? "") + "\n" + (String(data: csErrData, encoding: .utf8) ?? "")
        if let xml = extractXMLSubstring(from: combined) {
            if let ent = IPAEntitlements.from(xmlString: xml, source: .codeSignature), !ent.isEmpty {
                return ent
            }
        }

        // 3. Fallback scan of binary header for CSMAGIC_ENTITLEMENTS (0xfade7171)
        if let binaryData = try? Data(contentsOf: extractedBinary, options: .mappedIfSafe),
           let xmlFromScan = scanBinaryForEntitlementsXML(data: binaryData) {
            if let ent = IPAEntitlements.from(xmlString: xmlFromScan, source: .codeSignature), !ent.isEmpty {
                return ent
            }
        }

        return nil
    }

    // MARK: - Export & Import Operations

    /// Exports entitlements to a specified file URL (.entitlements or .plist)
    public func exportEntitlements(_ entitlements: IPAEntitlements, to destinationURL: URL) throws {
        let dir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let xmlContent = entitlements.rawXML
        guard !xmlContent.isEmpty else {
            throw IPAManagerError.exportFailed("Entitlements XML content is empty.")
        }

        try xmlContent.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    /// Imports entitlements from a local .entitlements, .plist, or .xml file
    public func importEntitlements(from fileURL: URL) throws -> IPAEntitlements {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw IPAManagerError.fileNotFound(fileURL.path)
        }

        let data = try Data(contentsOf: fileURL)

        // Try direct XML parse
        if let text = String(data: data, encoding: .utf8),
           let xml = extractXMLSubstring(from: text),
           let ent = IPAEntitlements.from(xmlString: xml, source: .manualImport) {
            return ent
        }

        // Try property list serialization directly
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            // Check if it's a mobileprovision or full plist with "Entitlements" key
            if let subEnt = plist["Entitlements"] as? [String: Any] {
                return IPAEntitlements.from(dictionary: subEnt, source: .manualImport)
            }
            return IPAEntitlements.from(dictionary: plist, source: .manualImport)
        }

        throw IPAManagerError.invalidEntitlementsData
    }

    // MARK: - Private Helpers

    private func readEmbeddedMobileprovisionData(at ipaURL: URL) async -> Data? {
        let data = await runUnzipPipeData(arguments: ["-p", ipaURL.path, "Payload/*.app/embedded.mobileprovision"], timeout: 4.0)
        return data.isEmpty ? nil : data
    }

    private func decodeProvisioningProfile(data: Data) -> Data? {
        // Fast path: Scan for <?xml ... </plist> in the CMS SignedData payload (instant, pure memory)
        if let text = String(data: data, encoding: .isoLatin1),
           let xml = extractXMLSubstring(from: text),
           let utf8Data = xml.data(using: .utf8) {
            return utf8Data
        }

        // Fallback: /usr/bin/security cms -D
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("temp_prov_\(UUID().uuidString).mobileprovision")
        do {
            try data.write(to: tempFile)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            let task = Process()
            task.launchPath = "/usr/bin/security"
            task.arguments = ["cms", "-D", "-i", tempFile.path]

            let stdoutPipe = Pipe()
            task.standardOutput = stdoutPipe
            task.standardError = Pipe()

            var outData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            try task.run()
            task.waitUntilExit()
            group.wait()

            if task.terminationStatus == 0 && !outData.isEmpty {
                return outData
            }
        } catch {
            // Ignored
        }

        return nil
    }

    /// Safely captures stdout from a process using concurrent pipe reading to guarantee NO deadlocks.
    private func runUnzipPipeData(arguments: [String], timeout: Double = 5.0) async -> Data {
        let (_, stdout, _) = await runProcessCaptureData(
            executable: "/usr/bin/unzip",
            arguments: arguments,
            timeoutSeconds: timeout
        )
        return stdout
    }

    /// Drains stdout and stderr concurrently on background dispatch queues so pipes NEVER deadlock.
    private func runProcessCaptureData(
        executable: String,
        arguments: [String],
        timeoutSeconds: Double = 10.0
    ) async -> (exitCode: Int32, stdout: Data, stderr: Data) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.launchPath = executable
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var stdoutData = Data()
                var stderrData = Data()
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
                timer.schedule(deadline: .now() + timeoutSeconds)
                timer.setEventHandler {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                timer.resume()

                do {
                    try process.run()
                    process.waitUntilExit()
                    timer.cancel()
                    group.wait()
                    continuation.resume(returning: (process.terminationStatus, stdoutData, stderrData))
                } catch {
                    timer.cancel()
                    group.wait()
                    continuation.resume(returning: (-1, Data(), Data()))
                }
            }
        }
    }

    private func extractXMLSubstring(from string: String) -> String? {
        guard let startRange = string.range(of: "<?xml") ?? string.range(of: "<plist") else {
            return nil
        }
        guard let endRange = string.range(of: "</plist>", options: .backwards) else {
            return nil
        }

        let xmlSub = String(string[startRange.lowerBound..<endRange.upperBound])
        if xmlSub.hasPrefix("<plist") && !xmlSub.contains("<?xml") {
            return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" + xmlSub
        }
        return xmlSub
    }

    private func scanBinaryForEntitlementsXML(data: Data) -> String? {
        let magic: [UInt8] = [0xfa, 0xde, 0x71, 0x71]
        if let range = data.range(of: Data(magic)) {
            let offset = range.upperBound
            if data.count >= offset + 4 {
                let lengthData = data.subdata(in: offset..<offset + 4)
                let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                let xmlStart = offset + 4
                let xmlEnd = xmlStart + Int(length) - 8
                if data.count >= xmlEnd && xmlEnd > xmlStart {
                    let xmlData = data.subdata(in: xmlStart..<xmlEnd)
                    if let str = String(data: xmlData, encoding: .utf8) {
                        return str
                    }
                }
            }
        }

        guard let xmlStartBytes = "<?xml".data(using: .utf8),
              let plistEndBytes = "</plist>".data(using: .utf8) else { return nil }

        if let startRange = data.range(of: xmlStartBytes),
           let endRange = data.range(of: plistEndBytes, options: .backwards, in: startRange.upperBound..<data.count) {
            let subData = data.subdata(in: startRange.lowerBound..<endRange.upperBound)
            if let str = String(data: subData, encoding: .utf8) {
                return str
            }
        }

        return nil
    }

    private func findFileNamed(_ name: String, in directory: URL) -> URL? {
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == name {
                    return fileURL
                }
            }
        }
        return nil
    }
}
