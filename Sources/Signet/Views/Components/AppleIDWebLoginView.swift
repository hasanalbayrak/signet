import SwiftUI
import WebKit

public struct AppleIDWebLoginView: View {
    @ObservedObject var appState: SignetAppState
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading: Bool = true
    @State private var webView: WKWebView?

    public init(appState: SignetAppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(Color.green)
                        Text("Sign In with Apple")
                            .font(.system(size: 14, weight: .bold))
                    }
                    Text("Official Apple Developer authentication with Passkey, Touch ID & 2FA support")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    webView?.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Reload page")

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // WebKit WebView
            AppleWebViewRepresentable(
                isLoading: $isLoading,
                onWebViewCreated: { wv in
                    self.webView = wv
                },
                onAuthenticationComplete: { cookies, discoveredTeams in
                    Task { @MainActor in
                        appState.handleWebLoginSuccess(cookies: cookies, preloadedTeams: discoveredTeams)
                        dismiss()
                    }
                }
            )
        }
        .frame(minWidth: 540, idealWidth: 600, minHeight: 620, idealHeight: 680)
    }
}

private struct AppleWebViewRepresentable: NSViewRepresentable {
    @Binding var isLoading: Bool
    let onWebViewCreated: (WKWebView) -> Void
    let onAuthenticationComplete: ([HTTPCookie], [DeveloperTeam]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // Fresh session each time, or default
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        onWebViewCreated(webView)

        let loginURL = URL(string: "https://developer.apple.com/account/")!
        let request = URLRequest(url: loginURL)
        webView.load(request)

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: AppleWebViewRepresentable
        weak var webView: WKWebView?
        private var checkTimer: Timer?
        private var hasCompleted: Bool = false

        init(parent: AppleWebViewRepresentable) {
            self.parent = parent
            super.init()
            startCookiePolling()
        }

        deinit {
            checkTimer?.invalidate()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
            checkCookies()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        private func startCookiePolling() {
            checkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkCookies()
            }
        }

        private func checkCookies() {
            guard !hasCompleted, let wv = webView else { return }

            wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.hasCompleted else { return }

                let currentURL = wv.url?.absoluteString ?? ""
                let isAccountURL = (currentURL.contains("developer.apple.com/account") ||
                                    currentURL.contains("developer.apple.com/services-account")) &&
                                   !currentURL.contains("signin") &&
                                   !currentURL.contains("auth") &&
                                   !currentURL.contains("login")

                if isAccountURL {
                    if let myacinfo = cookies.first(where: { $0.name == "myacinfo" }), !myacinfo.value.isEmpty {
                        self.hasCompleted = true
                        self.checkTimer?.invalidate()

                        let fetchScript = """
                        (async function() {
                            try {
                                let resp = await fetch('/services-account/QH65B2/account/listTeams.action', {
                                    method: 'POST',
                                    credentials: 'include',
                                    headers: {
                                        'Accept': 'application/json, text/javascript, */*',
                                        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
                                        'X-Requested-With': 'XMLHttpRequest'
                                    }
                                });
                                if (resp.ok) {
                                    let data = await resp.json();
                                    if (data && data.teams) {
                                        return JSON.stringify(data.teams);
                                    }
                                }
                            } catch(e) {}
                            return "[]";
                        })()
                        """

                        wv.evaluateJavaScript(fetchScript) { [weak self] result, _ in
                            guard let self = self else { return }
                            var discoveredTeams: [DeveloperTeam] = []
                            if let jsonStr = result as? String,
                               let data = jsonStr.data(using: .utf8),
                               let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                                for item in array {
                                    let id = (item["teamId"] as? String) ?? (item["id"] as? String) ?? ""
                                    let name = (item["name"] as? String) ?? (item["teamName"] as? String) ?? "Apple Developer Team"
                                    let type = (item["type"] as? String) ?? "Company/Organization"
                                    let status = (item["status"] as? String) ?? "active"
                                    if !id.isEmpty {
                                        discoveredTeams.append(DeveloperTeam(id: id, name: name, type: type, status: status))
                                    }
                                }
                            }

                            DispatchQueue.main.async {
                                self.parent.onAuthenticationComplete(cookies, discoveredTeams)
                            }
                        }
                    }
                }
            }
        }
    }
}
