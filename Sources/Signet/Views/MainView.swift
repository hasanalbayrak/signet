import SwiftUI

public struct MainView: View {
    @StateObject private var appState = SignetAppState()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Modern Liquid Glass Top Navigation Bar
            topBarView()

            Divider()

            // Main Content Area
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 14) {
                    // Module 1: Certificate & Profile Status
                    CertificateStatusCard(appState: appState)

                    // Module 2: Target Destination Device
                    TargetDeviceCard(appState: appState)

                    // Module 3: IPA Drop Target
                    IPADropZoneView(appState: appState)

                    // Module 4: Customization & Tweaks
                    CustomizationOptionsView(appState: appState)

                    // Module 5: Live Process Log Console
                    LogConsoleView(appState: appState)
                }
                .padding(16)
            }

            Divider()

            // Module D: Action & Deployment Footer
            ActionFooterView(appState: appState)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
        }
        .frame(minWidth: 540, idealWidth: 640, maxWidth: 900, minHeight: 640, idealHeight: 760)
        .sheet(isPresented: $appState.showSettingsSheet) {
            SettingsView(appState: appState)
        }
        .sheet(isPresented: $appState.showPasswordPrompt) {
            CertificatePasswordPromptView(appState: appState)
        }
        .alert("Signet Error", isPresented: $appState.showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.alertErrorMessage)
        }
    }

    // MARK: - Top Navigation Bar

    @ViewBuilder
    private func topBarView() -> some View {
        HStack(spacing: 12) {
            // App Branding
            HStack(spacing: 8) {
                ZStack {
                    LinearGradient(
                        colors: [Color.blue, Color.indigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Image(systemName: "signature")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text("Signet")
                            .font(.system(size: 13, weight: .bold))

                        Text("v1.2")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Text("iOS Sideloading & Signing")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Account status badge / button
            if let team = appState.selectedTeam {
                Button {
                    appState.showSettingsSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(team.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .frame(maxWidth: 220)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Active Team: \(team.name) (\(team.id)). Click to manage.")
            } else if let session = appState.currentDeveloperSession {
                Button {
                    appState.showSettingsSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(session.appleId)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    appState.showSettingsSheet = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 11))
                        Text("Apple ID")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            // Settings Button
            Button {
                appState.showSettingsSheet = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .padding(6)
            .background(Circle().fill(Color.secondary.opacity(0.12)))
            .help("Signet Preferences & Certificates")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 42)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
