import SwiftUI

public struct LogConsoleView: View {
    @ObservedObject var appState: SignetAppState

    public init(appState: SignetAppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Console Toolbar
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text("Process Console")
                        .font(.system(size: 12, weight: .semibold))

                    Text("(\(appState.logs.count) lines)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Auto-scroll toggle
                Toggle(isOn: $appState.autoScrollLogs) {
                    Text("Auto-scroll")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)

                // Copy Button
                Button {
                    appState.copyLogsToClipboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Copy logs to clipboard")

                // Clear Button
                Button {
                    appState.clearLogs()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Clear console logs")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))

            Divider()

            // Log Content
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(appState.logs) { log in
                            HStack(alignment: .top, spacing: 8) {
                                Text(log.formattedTime)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary.opacity(0.7))

                                Text(log.level.prefix)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(levelColor(log.level))

                                Text(log.message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(log.level == .error ? Color.red : (log.level == .success ? Color.green : Color.primary))
                                    .textSelection(.enabled)
                            }
                            .id(log.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                .onChange(of: appState.logs.count) { _, _ in
                    if appState.autoScrollLogs, let last = appState.logs.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(minHeight: 140, maxHeight: 220)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func levelColor(_ level: LogMessage.Level) -> Color {
        switch level {
        case .verbose: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}
