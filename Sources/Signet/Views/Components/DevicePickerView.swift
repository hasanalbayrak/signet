import SwiftUI

public struct DevicePickerView: View {
    @ObservedObject var appState: SignetAppState

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
                    Text("No iOS Devices Connected")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Device", selection: $appState.selectedDevice) {
                        ForEach(appState.devices) { device in
                            HStack {
                                Text(device.displayName)
                                if !device.osVersion.isEmpty {
                                    Text("(iOS \(device.osVersion))")
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

                    // iOS version tag
                    if !device.osVersion.isEmpty {
                        Text("iOS \(device.osVersion)")
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
            .help("Scan for connected USB / Wi-Fi iOS devices")
        }
    }
}
