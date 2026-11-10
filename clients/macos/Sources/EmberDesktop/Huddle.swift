import AVFoundation
import Foundation
import Observation
import WebKit

struct HuddlePerson: Codable, Hashable, Identifiable {
    let user: User
    let muted: Bool
    let audio: Bool
    var id: String { user.id }
}

/// The huddle this app is in, if any: its room, who's in it, and whether it's connected and muted.
/// The call itself runs in a hidden web view (`huddleEngineHTML`) loaded at the Ember's own origin,
/// so its socket passes the Worker's same-origin check and carries the session cookie.
@MainActor
@Observable
final class HuddleController: NSObject, WKScriptMessageHandler, WKUIDelegate {
    private(set) var roomId: String?
    private(set) var connected = false
    private(set) var people: [HuddlePerson] = []
    private(set) var muted = false
    private(set) var hasMicrophone = true
    var ended: String?
    /// What the engine has said, newest last, for diagnosing a huddle that won't connect.
    private(set) var log: [String] = []

    @ObservationIgnored private var web: WKWebView?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var queued: [String] = []
    @ObservationIgnored private var server: URL?

    var isInHuddle: Bool { roomId != nil }

    func join(roomId: String, api: APIClient, muted: Bool = false) {
        ended = nil
        self.roomId = roomId
        self.muted = muted
        connected = false
        people = []
        // Ask for the microphone before WebKit does, so macOS shows its prompt for the app.
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        prepare(server: api.server)
        let base = api.server.absoluteString.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        run("joinHuddle(\(json(base)), \(json(roomId)), \(muted))")
    }

    func leave() {
        run("leaveHuddle()")
        reset()
    }

    func setMuted(_ muted: Bool) {
        run("setHuddleMuted(\(muted))")
    }

    private func reset() {
        roomId = nil
        connected = false
        people = []
    }

    private func json(_ s: String) -> String {
        String(decoding: try! JSONEncoder().encode(s), as: UTF8.self)
    }

    private func prepare(server: URL) {
        guard web == nil || self.server != server else { return }
        self.server = server
        ready = false
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "huddle")
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // The engine's view is never in a window, and WebKit would otherwise suspend its timers and
        // sockets as it does a hidden tab's, dropping the call.
        configuration.preferences.inactiveSchedulingPolicy = .none
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        web.uiDelegate = self
        self.web = web
        let cookies = HTTPCookieStorage.shared.cookies(for: server) ?? []
        Task {
            for cookie in cookies { await configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
            web.loadHTMLString(huddleEngineHTML, baseURL: server)
        }
    }

    private func run(_ script: String) {
        guard ready, let web else { queued.append(script); return }
        web.evaluateJavaScript(script) { _, _ in }
    }

    // MARK: WKUIDelegate

    /// The engine's page is our own, so it may use the microphone the app was granted.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    // MARK: WKScriptMessageHandler

    private struct EngineState: Decodable {
        let connected: Bool
        let people: [HuddlePerson]
        let muted: Bool
        let microphone: Bool
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        log.append("\(type) \(body["message"] ?? body["error"] ?? "")")
        if log.count > 50 { log.removeFirst() }
        switch type {
        case "ready":
            ready = true
            let scripts = queued
            queued = []
            for script in scripts { web?.evaluateJavaScript(script) { _, _ in } }
        case "state":
            guard let huddle = body["huddle"], let data = try? JSONSerialization.data(withJSONObject: huddle),
                  let state = try? JSONDecoder().decode(EngineState.self, from: data), roomId != nil else { return }
            connected = state.connected
            people = state.people
            muted = state.muted
            hasMicrophone = state.microphone
        case "ended":
            ended = body["message"] as? String
            reset()
        case "microphone":
            hasMicrophone = false
        default:
            break
        }
    }
}
