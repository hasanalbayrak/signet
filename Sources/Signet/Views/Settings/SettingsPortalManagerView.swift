import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension SettingsView {

    // MARK: - Portal Manager Root Section

    @ViewBuilder
    func portalManagerSection() -> some View {
        if appState.currentDeveloperSession == nil {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 64, height: 64)
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: 4) {
                    Text("Apple ID Session Required")
                        .font(.system(size: 15, weight: .bold))
                    Text("Please sign in with your Apple Developer Account in the Apple ID tab to manage registered devices, certificates, and bundle IDs directly.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                Button {
                    selectedTab = .appleID
                } label: {
                    Text("Go to Apple ID Sign-In")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if let team = appState.selectedTeam {
            VStack(alignment: .leading, spacing: 14) {
                // Header & Action Bar
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Developer Portal Manager")
                            .font(.system(size: 14, weight: .bold))
                        Text("Connected as: **\(appState.currentDeveloperSession?.userFullName ?? "")** • Team: **\(team.name)** (`\(team.id)`)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if appState.isPortalLoading {
                        ProgressView().controlSize(.mini)
                    }

                    Button {
                        appState.loadPortalData()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh All")
                        }
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Status Message Toast
                if let statusMsg = appState.portalStatusMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                        Text(statusMsg)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button {
                            appState.portalStatusMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Sub-category Picker
                Picker("Category", selection: $selectedPortalSubTab) {
                    ForEach(PortalSubTab.allCases) { sub in
                        Text(sub.rawValue).tag(sub)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 2)

                // Sub-Views
                switch selectedPortalSubTab {
                case .devices:
                    portalDevicesSubView()
                case .certificates:
                    portalCertificatesSubView()
                case .appIds:
                    portalAppIdsSubView()
                }
            }
            .onAppear {
                if appState.portalDevices.isEmpty && appState.portalCertificates.isEmpty {
                    appState.loadPortalData()
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "person.2.slash.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("No Developer Team Selected")
                    .font(.system(size: 14, weight: .bold))
                Text("Select your developer team in the Apple ID tab to view portal assets.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    // MARK: - Devices SubView

    @ViewBuilder
    private func portalDevicesSubView() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Registered iOS Devices (\(appState.portalDevices.count))", systemImage: "iphone")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button {
                    self.newDeviceName = appState.selectedDevice?.displayName ?? ""
                    self.newDeviceUDID = appState.selectedDevice?.udid ?? ""
                    self.showAddDeviceSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Register Device")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    appState.refreshPortalDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if appState.portalDevices.isEmpty {
                VStack(spacing: 8) {
                    Text(appState.isPortalLoading ? "Loading registered devices..." : "No devices registered in this team yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if let connected = appState.selectedDevice {
                        Button("Register Connected Device '\(connected.displayName)'") {
                            self.newDeviceName = connected.displayName
                            self.newDeviceUDID = connected.udid
                            self.showAddDeviceSheet = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 6) {
                    ForEach(appState.portalDevices) { device in
                        HStack(spacing: 12) {
                            Image(systemName: device.displayClassIcon)
                                .font(.system(size: 18))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(device.name)
                                        .font(.system(size: 12, weight: .semibold))
                                    if let model = device.model, !model.isEmpty {
                                        Text("(\(model))")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                HStack(spacing: 4) {
                                    Text(device.udid)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)

                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(device.udid, forType: .string)
                                        appState.portalStatusMessage = "Copied UDID: \(device.udid)"
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Spacer()

                            // Status badge
                            Text(device.isEnabled ? "Active" : "Disabled")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(device.isEnabled ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                                .foregroundStyle(device.isEnabled ? Color.green : Color.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            // Delete button
                            Button(role: .destructive) {
                                self.devicePendingDeletion = device
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove device from Apple Developer Portal")
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove Device?",
            isPresented: Binding(
                get: { devicePendingDeletion != nil },
                set: { if !$0 { devicePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove '\(devicePendingDeletion?.name ?? "")'", role: .destructive) {
                if let dev = devicePendingDeletion {
                    appState.deletePortalDevice(id: dev.id)
                }
                devicePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                devicePendingDeletion = nil
            }
        } message: {
            Text("Are you sure you want to remove \(devicePendingDeletion?.name ?? "this device") (\(devicePendingDeletion?.udid ?? "")) from Apple Developer Portal?")
        }
    }

    // MARK: - Certificates SubView

    @ViewBuilder
    private func portalCertificatesSubView() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Explanatory note
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color.blue)
                    .font(.system(size: 14))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Certificate Limits & Sideloading")
                        .font(.system(size: 11, weight: .bold))
                    Text("Apple only stores the public (.cer) certificate, not the private key. To sign apps, Signet requires a matching private key. If your team's limit is reached, revoke an unused certificate below so Signet can issue a new matching keypair.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Label("Registered Certificates (\(appState.portalCertificates.count))", systemImage: "key.fill")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button {
                    appState.refreshPortalCertificates()
                    appState.refreshKeychainIdentities()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if appState.portalCertificates.isEmpty {
                Text(appState.isPortalLoading ? "Loading certificates..." : "No active certificates found in this team.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 6) {
                    ForEach(appState.portalCertificates) { cert in
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Color.green)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(cert.name)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("(\(cert.typeDisplayName))")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 8) {
                                    Text("ID: `\(cert.id)`")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)

                                    if let exp = cert.expirationDate {
                                        Text("• Exp: \(exp.prefix(10))")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Spacer()

                            // Status badge
                            Text(cert.status)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(cert.isIssued ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                                .foregroundStyle(cert.isIssued ? Color.green : Color.red)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            // Download .cer
                            Button {
                                downloadCerFile(cert: cert)
                            } label: {
                                Image(systemName: "arrow.down.doc")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Download Apple Public Certificate (.cer)")

                            // Revoke
                            Button(role: .destructive) {
                                self.certPendingRevocation = cert
                            } label: {
                                Image(systemName: "xmark.seal")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.red)
                            }
                            .buttonStyle(.plain)
                            .help("Revoke certificate on Apple Developer Portal")
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            // Local Keychain Identities
            if !appState.keychainIdentities.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Local Keychain Identities (Found on this Mac)", systemImage: "macbook.and.iphone")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                    }

                    ForEach(appState.keychainIdentities) { identity in
                        let isCurrentTeam = (identity.teamId != nil && identity.teamId == appState.selectedTeam?.id) ||
                                            (identity.teamName != nil && appState.selectedTeam != nil && (appState.selectedTeam!.name.localizedCaseInsensitiveContains(identity.teamName!) || identity.teamName!.localizedCaseInsensitiveContains(appState.selectedTeam!.name)))
                        HStack(spacing: 12) {
                            Image(systemName: "signature")
                                .font(.system(size: 16))
                                .foregroundStyle(isCurrentTeam ? Color.blue : Color.secondary)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(identity.name)
                                        .font(.system(size: 11, weight: .semibold))
                                    if isCurrentTeam {
                                        Text("Matches Active Team")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.blue.opacity(0.15))
                                            .foregroundStyle(Color.blue)
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                }

                                HStack(spacing: 6) {
                                    if let tId = identity.teamId {
                                        Text("Team ID: `\(tId)`")
                                            .font(.system(size: 9, design: .monospaced))
                                    }
                                    if let tName = identity.teamName {
                                        Text("• \(tName)")
                                            .font(.system(size: 9))
                                    }
                                    Text("• Hash: \(identity.id.prefix(8))...")
                                        .font(.system(size: 9, design: .monospaced))
                                }
                                .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                appState.useLocalKeychainIdentity(identity)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.seal.fill")
                                    Text("Use This Certificate")
                                }
                                .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(isCurrentTeam ? Color.accentColor : Color.secondary)
                        }
                        .padding(10)
                        .background(isCurrentTeam ? Color.blue.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.top, 8)
            }
        }
        .confirmationDialog(
            "Revoke Certificate?",
            isPresented: Binding(
                get: { certPendingRevocation != nil },
                set: { if !$0 { certPendingRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke '\(certPendingRevocation?.name ?? "")'", role: .destructive) {
                if let c = certPendingRevocation {
                    appState.revokePortalCertificate(id: c.id, type: c.type)
                }
                certPendingRevocation = nil
            }
            Button("Cancel", role: .cancel) {
                certPendingRevocation = nil
            }
        } message: {
            Text("Revoking this certificate on Apple Developer Portal will free a slot for Signet to generate a new keypair. Existing apps signed with this certificate might require re-signing.")
        }
    }

    // MARK: - App IDs SubView

    @ViewBuilder
    private func portalAppIdsSubView() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Registered App IDs / Bundle Identifiers (\(appState.portalAppIds.count))", systemImage: "shippingbox.fill")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button {
                    appState.createPortalAppId(name: "Signet Wildcard", identifier: "*")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "star.circle.fill")
                        Text("Add Wildcard (*)")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    self.newAppIdName = ""
                    self.newAppIdIdentifier = "*"
                    self.showAddAppIdSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New App ID")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    appState.refreshPortalAppIds()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if appState.portalAppIds.isEmpty {
                Text(appState.isPortalLoading ? "Loading App IDs..." : "No App IDs found.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 6) {
                    ForEach(appState.portalAppIds) { appId in
                        HStack(spacing: 12) {
                            Image(systemName: appId.isWildcard ? "star.circle.fill" : "app.badge.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(appId.isWildcard ? Color.blue : Color.accentColor)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(appId.name)
                                        .font(.system(size: 12, weight: .semibold))
                                    if appId.isWildcard {
                                        Text("Wildcard")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.blue.opacity(0.2))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                }

                                Text("ID: `\(appId.identifier)` • Prefix: `\(appId.prefix)`")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            // Delete App ID
                            Button(role: .destructive) {
                                self.appIdPendingDeletion = appId
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.red)
                            }
                            .buttonStyle(.plain)
                            .help("Delete App ID from Apple Developer Portal")
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete App ID?",
            isPresented: Binding(
                get: { appIdPendingDeletion != nil },
                set: { if !$0 { appIdPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete '\(appIdPendingDeletion?.name ?? "")'", role: .destructive) {
                if let a = appIdPendingDeletion {
                    appState.deletePortalAppId(id: a.id)
                }
                appIdPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                appIdPendingDeletion = nil
            }
        } message: {
            Text("Are you sure you want to delete App ID '\(appIdPendingDeletion?.identifier ?? "")' from Apple Developer Portal?")
        }
    }

    // MARK: - Modals

    @ViewBuilder
    func registerDeviceModalView() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Register iOS Device")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button("Close") {
                    showAddDeviceSheet = false
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 10) {
                if let connected = appState.selectedDevice {
                    Button {
                        self.newDeviceName = connected.displayName
                        self.newDeviceUDID = connected.udid
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                            Text("Use Connected Device: \(connected.displayName)")
                        }
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Device Name:")
                        .font(.system(size: 11, weight: .semibold))
                    TextField("e.g. My iPhone 15 Pro", text: $newDeviceName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Device UDID:")
                        .font(.system(size: 11, weight: .semibold))
                    TextField("00008110-00123456789...", text: $newDeviceUDID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Device Class:")
                        .font(.system(size: 11, weight: .semibold))
                    Picker("Class", selection: $newDeviceClass) {
                        Text("iPhone").tag("iphone")
                        Text("iPad").tag("ipad")
                    }
                    .pickerStyle(.segmented)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showAddDeviceSheet = false
                }
                .buttonStyle(.bordered)

                Button("Register") {
                    appState.registerPortalDevice(name: newDeviceName, udid: newDeviceUDID, deviceClass: newDeviceClass)
                    showAddDeviceSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newDeviceName.isEmpty || newDeviceUDID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder
    func registerAppIdModalView() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Register App ID / Bundle Identifier")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button("Close") {
                    showAddAppIdSheet = false
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name / Description:")
                        .font(.system(size: 11, weight: .semibold))
                    TextField("e.g. Signet Wildcard", text: $newAppIdName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Bundle Identifier:")
                        .font(.system(size: 11, weight: .semibold))
                    TextField("* or com.company.*", text: $newAppIdIdentifier)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Text("Use `*` for a Wildcard profile that can sign any iOS application.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showAddAppIdSheet = false
                }
                .buttonStyle(.bordered)

                Button("Register App ID") {
                    appState.createPortalAppId(name: newAppIdName, identifier: newAppIdIdentifier)
                    showAddAppIdSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newAppIdName.isEmpty || newAppIdIdentifier.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - Helpers

    private func downloadCerFile(cert: PortalCertificate) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cer") ?? .data]
        panel.nameFieldStringValue = "\(cert.name.replacingOccurrences(of: " ", with: "_")).cer"
        panel.prompt = "Save Certificate"

        if panel.runModal() == .OK, let targetURL = panel.url {
            appState.downloadPortalCertificate(id: cert.id, type: cert.type, destinationURL: targetURL)
        }
    }
}
