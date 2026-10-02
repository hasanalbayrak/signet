import SwiftUI

public struct TargetDeviceCard: View {
    @ObservedObject var appState: SignetAppState
    @State private var showDeviceInfoPopover: Bool = false

    public init(appState: SignetAppState) {
        self.appState = appState
    }

    public var body: some View {
        HStack(spacing: 14) {
            // Device Icon Container
            ZStack {
                Circle()
                    .fill(appState.selectedDevice != nil ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: appState.selectedDevice?.deviceIconName ?? "iphone")
                    .font(.system(size: 20))
                    .foregroundStyle(appState.selectedDevice != nil ? Color.blue : Color.secondary)
            }

            // Center details: Title + Picker
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("TARGET DEVICE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)

                    if let dev = appState.selectedDevice {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(dev.isAvailable ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text(dev.isAvailable ? "Ready" : "Offline")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(dev.isAvailable ? Color.green : Color.orange)
                        }
                    }
                }

                if appState.devices.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No Devices Connected")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Connect your iPhone/iPad via USB or Wi-Fi, or select your Mac.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        Picker("", selection: $appState.selectedDevice) {
                            ForEach(appState.devices) { device in
                                HStack {
                                    Image(systemName: device.deviceIconName)
                                    Text(device.displayName)
                                }
                                .tag(Optional(device))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(minWidth: 180, maxWidth: 280)

                        if let device = appState.selectedDevice, !device.osVersion.isEmpty {
                            Text(device.connectionType == .local ? device.osVersion : "iOS \(device.osVersion)")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }

                        if let devMode = appState.selectedDevice?.developerModeEnabled, devMode {
                            Text("Dev Mode ON")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(Color.green)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            Spacer()

            // Right side: Info popover button + Refresh scan button
            HStack(spacing: 8) {
                if let device = appState.selectedDevice {
                    Button {
                        showDeviceInfoPopover.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                            Text("Specs")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("View hardware specs, UDID, and details for \(device.displayName)")
                    .popover(isPresented: $showDeviceInfoPopover, arrowEdge: .bottom) {
                        DeviceDetailPopoverView(device: device)
                    }
                }

                Button {
                    appState.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .rotationEffect(.degrees(appState.isRefreshingDevices ? 360 : 0))
                        .animation(appState.isRefreshingDevices ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: appState.isRefreshingDevices)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Scan for connected USB / Wi-Fi iOS devices & local Mac")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}
