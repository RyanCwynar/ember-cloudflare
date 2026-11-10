import SwiftUI
import WebKit

/// One of the web app's pages inside the app, signed in with the app's session: the workspace's
/// administration (settings, custom styles, bots, agents), which changes rarely and has many screens,
/// so it's shown as the web app draws it rather than rebuilt. Links to rooms open natively instead.
struct WebSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let path: String
    let title: String
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                if let url = pageURL {
                    Button("Open in Browser") { NSWorkspace.shared.open(url) }
                }
                Button("Done") { dismiss(); Task { await state.reloadSidebar() } }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if let url = pageURL, let server = state.api?.server {
                EmberWebView(url: url, server: server, loading: $loading) { link in
                    guard state.openInApp(link) else { return false }
                    dismiss()
                    return true
                }
            }
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 640, idealHeight: 780)
    }

    private var pageURL: URL? { state.api.flatMap { URL(string: path, relativeTo: $0.server)?.absoluteURL } }
}

struct EmberWebView: NSViewRepresentable {
    let url: URL
    let server: URL
    @Binding var loading: Bool
    /// Takes a link the page follows; true when the app handled it.
    let openInApp: (URL) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        // The web view keeps its own cookies, so hand it the app's session before loading.
        let cookies = HTTPCookieStorage.shared.cookies(for: server) ?? []
        let store = web.configuration.websiteDataStore.httpCookieStore
        Task { @MainActor in
            for cookie in cookies { await store.setCookie(cookie) }
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: EmberWebView
        init(_ parent: EmberWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, action.navigationType == .linkActivated else { return .allow }
            if url.host != parent.server.host {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return await MainActor.run { parent.openInApp(url) } ? .cancel : .allow
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.loading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.loading = false }
    }
}
