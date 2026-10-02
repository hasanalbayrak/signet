import Foundation

public final class DeviceService: @unchecked Sendable {
    public static let shared = DeviceService()

    private let runner = ProcessRunner()
    private let binaryManager = BinaryManager.shared

    private init() {}

    /// Discovers connected iOS devices using xcrun devicectl and libimobiledevice tools.
    public func discoverDevices() async -> [Device] {
        var devicesByUDID: [String: Device] = [:]

        // 1. Try Apple CoreDevice (devicectl) first (iOS 17+)
        if let devicectlDevices = await fetchDevicesViaDevicectl() {
            for device in devicectlDevices {
                devicesByUDID[device.udid.uppercased()] = device
            }
        }

        // 2. Supplement with libimobiledevice (idevice_id / ideviceinfo)
        let imobileDevices = await fetchDevicesViaLibimobiledevice()
        for device in imobileDevices {
            let key = device.udid.uppercased()
            if let existing = devicesByUDID[key] {
                // Merge if libimobiledevice has more accurate info or confirms connection
                devicesByUDID[key] = Device(
                    udid: existing.udid,
                    name: existing.name.isEmpty ? device.name : existing.name,
                    model: existing.model.isEmpty ? device.model : existing.model,
                    productType: existing.productType.isEmpty ? device.productType : existing.productType,
                    osVersion: existing.osVersion.isEmpty ? device.osVersion : existing.osVersion,
                    connectionType: device.connectionType != .unknown ? device.connectionType : existing.connectionType,
                    isPaired: existing.isPaired || device.isPaired,
                    isAvailable: existing.isAvailable || device.isAvailable,
                    developerModeEnabled: existing.developerModeEnabled ?? device.developerModeEnabled
                )
            } else {
                devicesByUDID[key] = device
            }
        }

        // 3. Include local Apple Silicon Mac if running on arm64
        if let macDevice = getLocalAppleSiliconMac() {
            devicesByUDID[macDevice.udid.uppercased()] = macDevice
        }

        // Return sorted list: available & paired first, then iOS devices, then Mac, then by name
        return devicesByUDID.values.sorted { d1, d2 in
            if d1.isAvailable != d2.isAvailable {
                return d1.isAvailable && !d2.isAvailable
            }
            if (d1.connectionType == .local) != (d2.connectionType == .local) {
                // If an external iOS device is connected and available, prefer it first; otherwise Mac is accessible
                return d2.connectionType == .local
            }
            return d1.displayName.localizedCaseInsensitiveCompare(d2.displayName) == .orderedAscending
        }
    }

    // MARK: - CoreDevice Backend

    private func fetchDevicesViaDevicectl() async -> [Device]? {
        guard let xcrunPath = binaryManager.resolveDevicectl() else { return nil }

        do {
            let result = try await runner.run(
                executablePath: xcrunPath,
                arguments: ["devicectl", "list", "devices", "--json-output", "-"]
            )

            guard result.isSuccess, let data = result.output.data(using: .utf8) else {
                return nil
            }

            return parseDevicectlJSON(data: data)
        } catch {
            return nil
        }
    }

    private func parseDevicectlJSON(data: Data) -> [Device]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultObj = root["result"] as? [String: Any],
              let devicesArray = resultObj["devices"] as? [[String: Any]] else {
            return nil
        }

        var foundDevices: [Device] = []

        for item in devicesArray {
            var udid = ""
            var marketingName = ""
            var productType = ""
            var deviceName = ""
            var osVersion = ""
            var pairingState = ""
            var isAvailable = false
            var devMode: Bool? = nil
            var serialNumber: String? = nil
            var cpuArchitecture: String? = nil
            var buildVersion: String? = nil

            // Read from modern "properties" dict if available
            if let props = item["properties"] as? [String: Any] {
                if let hardware = props["hardware"] as? [String: Any] {
                    udid = hardware["udid"] as? String ?? ""
                    marketingName = hardware["marketingName"] as? String ?? ""
                    productType = hardware["productType"] as? String ?? ""
                    serialNumber = hardware["serialNumber"] as? String
                    cpuArchitecture = hardware["cpuArchitecture"] as? String
                }
                if let software = props["software"] as? [String: Any] {
                    if let osVerDict = software["osVersionNumber"] as? [String: Any] {
                        osVersion = osVerDict["stringValue"] as? String ?? ""
                    }
                    if let osBuildDict = software["osBuildVersion"] as? [String: Any] {
                        buildVersion = osBuildDict["stringValue"] as? String
                    } else if let bStr = software["osBuildVersion"] as? String {
                        buildVersion = bStr
                    }
                }
                if let connection = props["connection"] as? [String: Any] {
                    pairingState = connection["pairingState"] as? String ?? ""
                    let connState = connection["state"] as? String ?? ""
                    isAvailable = connState == "available"
                }
                if let state = props["state"] as? [String: Any] {
                    deviceName = state["name"] as? String ?? ""
                    let bootState = state["bootState"] as? String ?? ""
                    if bootState == "booted" {
                        isAvailable = true
                    }
                    if let devStatus = state["developerModeStatus"] as? [String: Any],
                       let enabled = devStatus["enabled"] as? [String: Any],
                       let mode = enabled["mode"] as? Int {
                        devMode = (mode == 1)
                    }
                }
            }

            // Fallback to top-level/deprecated properties
            if udid.isEmpty, let hw = item["hardwareProperties"] as? [String: Any] {
                udid = hw["udid"] as? String ?? ""
                if marketingName.isEmpty {
                    marketingName = hw["marketingName"] as? String ?? ""
                }
                if productType.isEmpty {
                    productType = hw["productType"] as? String ?? ""
                }
                if serialNumber == nil {
                    serialNumber = hw["serialNumber"] as? String
                }
                if cpuArchitecture == nil {
                    cpuArchitecture = hw["cpuArchitecture"] as? String
                }
            }
            if deviceName.isEmpty, let devProp = item["deviceProperties"] as? [String: Any] {
                deviceName = devProp["name"] as? String ?? ""
                if osVersion.isEmpty {
                    osVersion = devProp["osVersionNumber"] as? String ?? ""
                }
            }
            if pairingState.isEmpty, let connProp = item["connectionProperties"] as? [String: Any] {
                pairingState = connProp["pairingState"] as? String ?? ""
                let tunnel = connProp["tunnelState"] as? String ?? ""
                if tunnel == "available" {
                    isAvailable = true
                }
            }

            // Skip if no valid UDID or if it's a Mac / Simulator
            guard !udid.isEmpty else { continue }
            if productType.lowercased().contains("mac") { continue }

            let isPaired = pairingState.lowercased().contains("paired")

            let device = Device(
                udid: udid,
                name: deviceName.isEmpty ? marketingName : deviceName,
                model: marketingName.isEmpty ? productType : marketingName,
                productType: productType,
                osVersion: osVersion,
                connectionType: .usb, // devicectl handles both USB & Wi-Fi transparently
                isPaired: isPaired,
                isAvailable: isAvailable,
                developerModeEnabled: devMode,
                serialNumber: serialNumber,
                cpuArchitecture: cpuArchitecture,
                buildVersion: buildVersion
            )
            foundDevices.append(device)
        }

        return foundDevices
    }

    // MARK: - Libimobiledevice Backend

    private func fetchDevicesViaLibimobiledevice() async -> [Device] {
        guard let ideviceIdPath = binaryManager.resolveIdeviceId() else { return [] }

        var list: [Device] = []
        do {
            let result = try await runner.run(
                executablePath: ideviceIdPath,
                arguments: ["-l"]
            )

            guard result.isSuccess else { return [] }

            let udids = result.output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for udid in udids {
                let info = await inspectDeviceViaIdeviceInfo(udid: udid)
                list.append(info)
            }
        } catch {
            return []
        }

        return list
    }

    private func inspectDeviceViaIdeviceInfo(udid: String) async -> Device {
        guard let infoPath = binaryManager.resolveIdeviceInfo() else {
            return Device(
                udid: udid,
                name: "iOS Device",
                model: "",
                productType: "",
                osVersion: "",
                connectionType: .usb,
                isPaired: true,
                isAvailable: true
            )
        }

        var name = "iOS Device"
        var model = ""
        var productType = ""
        var osVersion = ""
        var serialNumber: String? = nil
        var cpuArchitecture: String? = nil
        var buildVersion: String? = nil

        if let res = try? await runner.run(executablePath: infoPath, arguments: ["-u", udid, "-k", "DeviceName"]),
           res.isSuccess {
            name = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let res = try? await runner.run(executablePath: infoPath, arguments: ["-u", udid, "-k", "ProductType"]),
           res.isSuccess {
            productType = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
            model = formatProductTypeToModel(productType)
        }

        if let res = try? await runner.run(executablePath: infoPath, arguments: ["-u", udid, "-k", "ProductVersion"]),
           res.isSuccess {
            osVersion = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let res = try? await runner.run(executablePath: infoPath, arguments: ["-u", udid, "-k", "SerialNumber"]),
           res.isSuccess {
            let val = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !val.isEmpty { serialNumber = val }
        }

        if let res = try? await runner.run(executablePath: infoPath, arguments: ["-u", udid, "-k", "CPUArchitecture"]),
           res.isSuccess {
            let val = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !val.isEmpty { cpuArchitecture = val }
        }

        if let res = try? await runner.run(executablePath: infoPath, arguments: ["-u", udid, "-k", "BuildVersion"]),
           res.isSuccess {
            let val = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !val.isEmpty { buildVersion = val }
        }

        return Device(
            udid: udid,
            name: name,
            model: model.isEmpty ? productType : model,
            productType: productType,
            osVersion: osVersion,
            connectionType: .usb,
            isPaired: true,
            isAvailable: true,
            serialNumber: serialNumber,
            cpuArchitecture: cpuArchitecture,
            buildVersion: buildVersion
        )
    }

    private func formatProductTypeToModel(_ type: String) -> String {
        // Quick dictionary mapping for popular devices
        let map: [String: String] = [
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,5": "iPhone 13",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone13,1": "iPhone 12 mini",
            "iPhone12,1": "iPhone 11",
            "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone11,2": "iPhone XS",
            "iPhone11,4": "iPhone XS Max",
            "iPhone11,6": "iPhone XS Max",
            "iPhone11,8": "iPhone XR"
        ]
        return map[type] ?? type
    }

    // MARK: - Apple Silicon Mac Discovery

    public func getLocalAppleSiliconMac() -> Device? {
        #if arch(arm64)
        let isArm64 = true
        #else
        let isArm64 = false
        #endif

        guard isArm64 else { return nil }

        let uuid = getMacHardwareUUID() ?? "MAC-\(Host.current().localizedName ?? "LOCAL")"
        let (model, serial) = getMacHardwareModelAndSerial()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let buildVersion = getMacKernelOSVersion()
        let hostName = Host.current().localizedName ?? "My Mac"

        return Device(
            udid: uuid,
            name: "\(hostName) (Apple Silicon)",
            model: "Apple Silicon Mac (\(model))",
            productType: model,
            osVersion: osVersion,
            connectionType: .local,
            isPaired: true,
            isAvailable: true,
            developerModeEnabled: true,
            serialNumber: serial,
            cpuArchitecture: "arm64",
            buildVersion: buildVersion,
            isAppleSiliconMac: true
        )
    }

    private func getMacHardwareUUID() -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.components(separatedBy: .newlines) {
            if line.contains("IOPlatformUUID") {
                let parts = line.components(separatedBy: "=")
                if parts.count >= 2 {
                    return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"\r\n\t"))
                }
            }
        }
        return nil
    }

    private func getMacHardwareModelAndSerial() -> (model: String, serial: String?) {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var modelChars = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &modelChars, &size, nil, 0)
        let model = String(cString: modelChars)

        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        var serial: String? = nil
        if let output = String(data: data, encoding: .utf8) {
            for line in output.components(separatedBy: .newlines) {
                if line.contains("IOPlatformSerialNumber") {
                    let parts = line.components(separatedBy: "=")
                    if parts.count >= 2 {
                        serial = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"\r\n\t"))
                    }
                }
            }
        }

        return (model.isEmpty ? "Mac" : model, serial)
    }

    private func getMacKernelOSVersion() -> String? {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &chars, &size, nil, 0)
        let str = String(cString: chars)
        return str.isEmpty ? nil : str
    }
}
