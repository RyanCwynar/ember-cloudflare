import XCTest
@testable import EmberDesktop

/// The huddle engine's web view reaches the room's huddle socket with the app's session. Without
/// huddles set up (no Cloudflare Realtime app), the Worker lets the socket in and closes it with
/// `HuddleCloseCode.Off`, which only a signed-in, same-origin upgrade gets that far to hear; a refused
/// upgrade would just keep reconnecting.
@MainActor
final class LiveHuddleTests: XCTestCase {
    func testHuddleEngineReachesTheHuddleSocket() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["EMBER_TEST_SERVER"].flatMap(APIClient.serverURL(from:)),
              let email = env["EMBER_TEST_EMAIL"], let password = env["EMBER_TEST_PASSWORD"] else {
            throw XCTSkip("Set EMBER_TEST_SERVER, EMBER_TEST_EMAIL and EMBER_TEST_PASSWORD to run against a live Ember")
        }
        let api = APIClient(server: server)
        _ = try await api.signIn(email: email, password: password)
        let rooms = try await api.sidebar().rooms
        let room = try XCTUnwrap(rooms.first { !$0.isDirect })

        let huddle = HuddleController()
        huddle.join(roomId: room.id, api: api, muted: true)
        let deadline = Date().addingTimeInterval(25)
        while huddle.ended == nil && !huddle.connected && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if huddle.connected {
            // Huddles are set up on this server: we're in, so leave cleanly.
            XCTAssertTrue(huddle.people.contains { $0.muted })
            huddle.leave()
        } else {
            XCTAssertEqual(huddle.ended, "Huddles have been turned off.")
        }
    }
}
