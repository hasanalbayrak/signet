import SwiftUI

public struct DevicePickerView: View {
    @ObservedObject var appState: SignetAppState
    @State private var showDeviceInfoPopover: Bool = false

    public init(appState: SignetAppState) {
        self.appState = appState
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Icon & Picker Label
            HStack(spacing: 8) {
                Image(systemName: appState.selectedDevice?.deviceIconName ?? "iphone")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(appState.selectedDevice != nil ? Color.accentColor : Color.secondary)

                if appState.devices.isEmpty {
                    Text("No Devices Connected")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Device", selection: $appState.selectedDevice) {
                        ForEach(appState.devices) { device in
                            HStack {
                                Text(device.displayName)
                                if !device.osVersion.isEmpty {
                                    Text("(\(device.connectionType == .local ? device.osVersion : "iOS \(device.osVersion)"))")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(Optional(device))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 160)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )

            // Connection & Developer Mode Status Pills
            if let device = appState.selectedDevice {
                HStack(spacing: 6) {
                    // Availability Dot
                    Circle()
                        .fill(device.isAvailable ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)

                    Text(device.isAvailable ? "Ready" : "Disconnected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(device.isAvailable ? .primary : .secondary)

                    // OS version tag
                    if !device.osVersion.isEmpty {
                        Text(device.connectionType == .local ? device.osVersion : "iOS \(device.osVersion)")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }

                    // Developer mode pill
                    if let devMode = device.developerModeEnabled {
                        HStack(spacing: 3) {
                            Image(systemName: devMode ? "hammer.fill" : "hammer")
                                .font(.system(size: 9))
                            Text(devMode ? "Dev Mode ON" : "Dev Mode OFF")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(devMode ? Color.green.opacity(0.15) : Color.orange.opacity(0.2))
                        .foregroundStyle(devMode ? Color.green : Color.orange)
                        .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            // Selected Device Info Button
            if let device = appState.selectedDevice {
                Button {
                    showDeviceInfoPopover.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(Circle().fill(Color.secondary.opacity(0.12)))
                .help("View detailed hardware and software specifications for \(device.displayName)")
                .popover(isPresented: $showDeviceInfoPopover, arrowEdge: .bottom) {
                    DeviceDetailPopoverView(device: device)
                }
            }

            // Refresh Button
            Button {
                appState.refreshDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(appState.isRefreshingDevices ? 360 : 0))
                    .animation(appState.isRefreshingDevices ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: appState.isRefreshingDevices)
            }
            .buttonStyle(.plain)
            .padding(6)
            .background(Circle().fill(Color.secondary.opacity(0.12)))
            .help("Scan for connected USB / Wi-Fi iOS devices & local Mac")
        }
    }
}

// MARK: - Detailed Device Inspector Popover

public struct DeviceDetailPopoverView: View {
    public let device: Device
    @State private var copiedItem: String? = nil

    public init(device: Device) {
        self.device = device
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 44, height: 44)

                    Image(systemName: device.deviceIconName)
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.system(size: 14, weight: .bold))

                    Text(device.model)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(device.isAvailable ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(device.isAvailable ? "Connected" : "Offline")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(device.isAvailable ? Color.green : Color.orange)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08))
                .clipShape(Capsule())
            }

            Divider()

            // Properties List
            VStack(spacing: 8) {
                infoRow(label: "Product Type", value: device.productType.isEmpty ? "Unknown" : device.productType)

                infoRowWithCopy(label: "UDID / UUID", value: device.udid)

                if let serial = device.serialNumber, !serial.isEmpty {
                    infoRowWithCopy(label: "Serial Number", value: serial)
                }

                if let arch = device.cpuArchitecture, !arch.isEmpty {
                    infoRow(label: "CPU Architecture", value: arch)
                }

                let osDisplay: String = {
                    var str = device.osVersion.isEmpty ? "Unknown" : device.osVersion
                    if let build = device.buildVersion, !build.isEmpty {
                        str += " (Build \(build))"
                    }
                    return str
                }()
                infoRow(label: device.connectionType == .local ? "macOS Version" : "iOS Version", value: osDisplay)

                infoRow(label: "Connection Type", value: device.connectionType.rawValue)

                infoRow(
                    label: "Pairing & Trust",
                    value: device.isPaired ? "Paired & Trusted" : "Trust Required"
                )

                if let devMode = device.developerModeEnabled {
                    infoRow(
                        label: "Developer Mode",
                        value: devMode ? "Enabled" : "Disabled"
                    )
                }

                infoRow(
                    label: "Target Platform",
                    value: device.isAppleSiliconMac ? "Apple Silicon (Direct /Applications)" : "iOS / iPadOS Native"
                )
            }

            if let copied = copiedItem {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                        .font(.system(size: 11))
                    Text("\(copied) copied to clipboard!")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.green)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            Spacer()

            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func infoRowWithCopy(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            Spacer()

            HStack(spacing: 4) {
                Text(value.count > 20 ? "\(value.prefix(8))...\(value.suffix(6))" : value)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copiedItem = label
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if copiedItem == label { copiedItem = nil }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Copy \(label)")
            }
        }
    }
}
