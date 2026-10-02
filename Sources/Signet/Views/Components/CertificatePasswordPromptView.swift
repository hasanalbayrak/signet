import SwiftUI

public struct CertificatePasswordPromptView: View {
    @ObservedObject var appState: SignetAppState
    @State private var inputPassword: String = ""
    @State private var isPasswordVisible: Bool = false
    @FocusState private var isFieldFocused: Bool

    public init(appState: SignetAppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 50, height: 50)

                Image(systemName: "key.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.orange)
            }

            VStack(spacing: 4) {
                Text("Certificate Password Required")
                    .font(.system(size: 14, weight: .bold))

                Text(appState.passwordPromptMessage.isEmpty ? "Enter the password to unlock your .p12 certificate for signing:" : appState.passwordPromptMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }

            HStack(spacing: 6) {
                Group {
                    if isPasswordVisible {
                        TextField("Password", text: $inputPassword)
                    } else {
                        SecureField("Password", text: $inputPassword)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit {
                    submitPassword()
                }

                Button {
                    isPasswordVisible.toggle()
                } label: {
                    Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isPasswordVisible ? "Hide password" : "Show password")

                if !inputPassword.isEmpty {
                    Button {
                        inputPassword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear password")
                }
            }
            .frame(maxWidth: 290)

            HStack(spacing: 10) {
                Button("Cancel") {
                    appState.showPasswordPrompt = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Unlock & Save") {
                    submitPassword()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(inputPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if appState.passwordPromptMessage.localizedCaseInsensitiveContains("incorrect") || appState.passwordPromptMessage.localizedCaseInsensitiveContains("failed") {
                self.inputPassword = ""
            } else {
                self.inputPassword = appState.p12Password
            }
            self.isFieldFocused = true
        }
    }

    private func submitPassword() {
        appState.updateP12Password(inputPassword)
    }
}
