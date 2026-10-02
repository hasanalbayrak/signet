import SwiftUI
import AppKit

public struct ActionFooterView: View {
    @ObservedObject var appState: SignetAppState

    public init(appState: SignetAppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Active Progress Bar (When Busy)
            if appState.pipelineStep.isBusy {
                VStack(spacing: 6) {
                    HStack {
                        ProgressView()
                            .controlSize(.small)

                        Text(appState.pipelineStep.statusTitle)
                            .font(.system(size: 12, weight: .medium))

                        Spacer()

                        Text("\(Int(appState.pipelineStep.progress * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Button("Cancel") {
                            appState.cancelPipeline()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    ProgressView(value: appState.pipelineStep.progress, total: 1.0)
                        .progressViewStyle(.linear)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.1))
                )
            } else if case .completed(let url) = appState.pipelineStep {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)

                    Text("Process completed successfully!")
                        .font(.system(size: 12, weight: .semibold))

                    Spacer()

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.1))
                )
            }

            // Bottom Buttons Bar
            HStack(spacing: 12) {
                // Status hint on the left
                HStack(spacing: 6) {
                    if appState.selectedIPA == nil {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Drop an .ipa file to begin")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if appState.certificate == nil {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Certificate required (click Configure)")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                        Text("Ready to resign")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Sign IPA Only (Export)
                Button {
                    appState.startSigningOnly()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "signature")
                        Text("Sign IPA")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!appState.canStartSigning)
                .help("Signs the IPA package and saves it to ~/Downloads/Signet")

                // Sign & Install (Primary)
                Button {
                    appState.startSignAndInstall()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                        Text("Sign & Install")
                        if let device = appState.selectedDevice {
                            Text("(\(device.displayName))")
                                .font(.system(size: 11, weight: .regular))
                                .opacity(0.85)
                                .lineLimit(1)
                                .frame(maxWidth: 130)
                                .truncationMode(.tail)
                        }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!appState.canStartSigning || appState.selectedDevice == nil)
                .help(appState.selectedDevice != nil ? "Signs the IPA and deploys it to \(appState.selectedDevice!.displayName)" : "Select a target device to sign and install")
            }
        }
    }
}
