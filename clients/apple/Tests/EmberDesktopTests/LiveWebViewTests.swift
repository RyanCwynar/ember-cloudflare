import WebKit
import XCTest
@testable import EmberDesktop

/// The admin pages' web view gets the app's session: loading `/api/me` in it answers who's signed in.
@MainActor
final class LiveWebViewTests: XCTestCase {
    final class Loaded: NSObject, WKNavigationDelegate {
        var finished: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?.resume(); finished = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished?.resume(); finished = nil }
    }

    func testWebViewIsSignedInWithTheAppsSession() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["EMBER_TEST_SERVER"].flatMap(APIClient.serverURL(from:)),
              let email = env["EMBER_TEST_EMAIL"], let password = env["EMBER_TEST_PASSWORD"] else {
            throw XCTSkip("Set EMBER_TEST_SERVER, EMBER_TEST_EMAIL and EMBER_TEST_PASSWORD to run against a live Ember")
        }
        let api = APIClient(server: server)
        let me = try await api.signIn(email: email, password: password)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let delegate = Loaded()
        web.navigationDelegate = delegate
        for cookie in HTTPCookieStorage.shared.cookies(for: server) ?? [] {
            await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        await withCheckedContinuation { continuation in
            delegate.finished = continuation
            web.load(URLRequest(url: server.appendingPathComponent("/api/me")))
        }
        let text = try await web.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertTrue(text?.contains(me.id) == true, "expected /api/me to answer the signed-in user, got \(text ?? "nothing")")
    }
}
