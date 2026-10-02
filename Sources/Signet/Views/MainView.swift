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
                VStack(spacing: 16) {
                    // Module A: Certificate & Profile Status
                    CertificateStatusCard(appState: appState)

                    // Module C: IPA Drop Target
                    IPADropZoneView(appState: appState)

                    // Module C: Customization & Tweaks
                    CustomizationOptionsView(appState: appState)

                    // Live Process Log Console
                    LogConsoleView(appState: appState)
                }
                .padding(18)
            }

            Divider()

            // Module D: Action & Deployment Footer
            ActionFooterView(appState: appState)
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 700, idealHeight: 780)
        .sheet(isPresented: $appState.showSettingsSheet) {
            SettingsView(appState: appState)
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
        HStack(spacing: 14) {
            // App Branding
            HStack(spacing: 8) {
                ZStack {
                    LinearGradient(
                        colors: [Color.blue, Color.indigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    Image(systemName: "signature")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text("Signet")
                        .font(.system(size: 14, weight: .bold))
                    Text("iOS Sideloading")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Module B: Device Picker Dropdown
            DevicePickerView(appState: appState)

            // Settings Button
            Button {
                appState.showSettingsSheet = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .padding(6)
            .background(Circle().fill(Color.secondary.opacity(0.12)))
            .help("Signet Preferences & Certificates")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
