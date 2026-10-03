import SwiftUI

public struct CertificateStatusCard: View {
    @ObservedObject var appState: SignetAppState

    public init(appState: SignetAppState) {
        self.appState = appState
    }

    public var body: some View {
        HStack(spacing: 14) {
            // Certificate Dynamic Icon
            ZStack {
                let isDist = appState.certificate?.isDistribution == true
                let hasCert = appState.certificate != nil
                Circle()
                    .fill(
                        hasCert ?
                            (isDist ? Color.purple.opacity(0.15) : Color.blue.opacity(0.15)) :
                            Color.orange.opacity(0.15)
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: hasCert ? (isDist ? "shippingbox.fill" : "checkmark.seal.fill") : "lock.badge.clock.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        hasCert ?
                            (isDist ? Color.purple : Color.blue) :
                            Color.orange
                    )
            }

            // Information block
            VStack(alignment: .leading, spacing: 3) {
                if let cert = appState.certificate {
                    // Line 1: Cert Name + Badges
                    HStack(spacing: 8) {
                        Text(cert.cleanDisplayName)
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)

                        // Distribution vs Development badge
                        Text(cert.typeDisplayName)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(cert.isDistribution ? Color.purple.opacity(0.15) : Color.blue.opacity(0.15))
                            .foregroundStyle(cert.isDistribution ? Color.purple : Color.blue)
                            .clipShape(Capsule())

                        // Validity pill
                        HStack(spacing: 4) {
                            Circle()
                                .fill(cert.isExpired ? Color.red : (cert.isExpiringSoon ? Color.orange : Color.green))
                                .frame(width: 5, height: 5)
                            Text(cert.validityStatusText)
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(cert.isExpired ? Color.red.opacity(0.15) : (cert.isExpiringSoon ? Color.orange.opacity(0.2) : Color.green.opacity(0.15)))
                        .foregroundStyle(cert.isExpired ? Color.red : (cert.isExpiringSoon ? Color.orange : Color.green))
                        .clipShape(Capsule())
                    }

                    // Line 2: Team Name & Team ID
                    let teamDisplay = appState.selectedTeam?.name ?? cert.teamName
                    let teamIdDisplay = (appState.selectedTeam?.id ?? cert.teamId)
                    HStack(spacing: 6) {
                        Image(systemName: "building.2.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)

                        Text(teamDisplay)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if !teamIdDisplay.isEmpty && teamIdDisplay != "UNKNOWN" {
                            Text("(\(teamIdDisplay))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Line 3: Provisioning Profile
                    if let profile = appState.profile {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.accentColor)

                            Text(profile.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if profile.isWildcard {
                                Text("Wildcard (*)")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.12))
                                    .foregroundStyle(Color.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }

                            Text("• \(profile.validityStatusText)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.orange)
                            Text("No Provisioning Profile Active")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.orange)
                        }
                    }
                } else {
                    Text("No Developer Certificate Configured")
                        .font(.system(size: 13, weight: .semibold))

                    Text("Import your .p12 certificate and .mobileprovision or use 1-Click Apple ID provisioning.")
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
                    .font(.system(size: 11, weight: .medium))
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
