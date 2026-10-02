import SwiftUI

public struct CertificateStatusCard: View {
    @ObservedObject var appState: SignetAppState

    public init(appState: SignetAppState) {
        self.appState = appState
    }

    public var body: some View {
        HStack(spacing: 16) {
            // Certificate Icon
            ZStack {
                Circle()
                    .fill(appState.certificate != nil ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: appState.certificate != nil ? "checkmark.seal.fill" : "lock.badge.clock.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(appState.certificate != nil ? Color.green : Color.orange)
            }

            // Information block
            VStack(alignment: .leading, spacing: 4) {
                if let cert = appState.certificate {
                    HStack(spacing: 8) {
                        Text(cert.teamName)
                            .font(.system(size: 14, weight: .bold))

                        Text("(\(cert.teamId))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)

                        // Validity pill
                        Text(cert.validityStatusText)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(cert.isExpired ? Color.red.opacity(0.15) : (cert.isExpiringSoon ? Color.orange.opacity(0.2) : Color.green.opacity(0.15)))
                            .foregroundStyle(cert.isExpired ? Color.red : (cert.isExpiringSoon ? Color.orange : Color.green))
                            .clipShape(Capsule())
                    }

                    if let profile = appState.profile {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.badge.gearshape")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                            Text(profile.name)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            if profile.isWildcard {
                                Text("Wildcard (*)")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.15))
                                    .foregroundStyle(Color.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    } else {
                        Text("No Provisioning Profile loaded")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("No Developer Certificate Configured")
                        .font(.system(size: 13, weight: .semibold))

                    Text("Import your .p12 certificate and .mobileprovision to enable 365-day signing.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Settings/Manage Action Button
            HStack(spacing: 6) {
                if appState.certificate != nil {
                    Button {
                        appState.promptForCertificatePassword(message: "Update password for \(appState.certificate?.commonName ?? "Certificate"):")
                    } label: {
                        Image(systemName: "key.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Change or Re-enter Certificate Password")
                }

                Button {
                    appState.showSettingsSheet = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: appState.certificate != nil ? "gearshape" : "plus.circle.fill")
                        Text(appState.certificate != nil ? "Manage" : "Configure")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
