import XCTest
@testable import EmberDesktop

/// Rooms, DMs, stars, notification levels and profiles against a running Ember, as `LiveServerTests`.
/// Signs a second person in with just a name, which `pnpm dev` allows (EMBER_GUEST_SIGN_IN).
final class LiveRoomsTests: XCTestCase {
    private struct GuestSignIn: Encodable { let name: String }

    func testDirectsRoomsStarsInvolvementAndProfile() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["EMBER_TEST_SERVER"].flatMap(APIClient.serverURL(from:)),
              let email = env["EMBER_TEST_EMAIL"], let password = env["EMBER_TEST_PASSWORD"] else {
            throw XCTSkip("Set EMBER_TEST_SERVER, EMBER_TEST_EMAIL and EMBER_TEST_PASSWORD to run against a live Ember")
        }
        // A guest gets their own cookie jar, so the admin's session stays in the shared one.
        let guestConfig = URLSessionConfiguration.ephemeral
        guestConfig.httpCookieStorage = HTTPCookieStorage()
        let guestSession = URLSession(configuration: guestConfig)
        let api = APIClient(server: server)
        var guestRequest = try api.request("/api/session", method: "POST", body: GuestSignIn(name: "Guest \(Int.random(in: 1000...9999))"))
        guestRequest.httpShouldHandleCookies = true
        let (guestData, guestResponse) = try await guestSession.data(for: guestRequest)
        guard (guestResponse as? HTTPURLResponse)?.statusCode == 201 else { throw XCTSkip("Guest sign-in is off on this server") }
        let guest = try JSONDecoder().decode(UserAnswer.self, from: guestData).user

        let me = try await api.signIn(email: email, password: password)

        // DMs: starting one twice answers the same room.
        let dm = try await api.startDirect(with: [guest.id])
        XCTAssertTrue(dm.isDirect)
        XCTAssertEqual(Set(dm.members?.map(\.id) ?? []), [me.id, guest.id])
        let again = try await api.startDirect(with: [guest.id])
        XCTAssertEqual(again.id, dm.id)

        // A private room with the guest, starred, renamed, muted, then deleted.
        let form = try await api.newRoomForm()
        XCTAssertTrue(form.people.contains { $0.id == guest.id })
        let room = try await api.createRoom(name: "desktop-test-\(Int.random(in: 1000...9999))", isPrivate: true, memberIds: [me.id, guest.id])
        XCTAssertEqual(room.kind, "closed")
        let starred = try await api.setFavorite(room.id, true)
        XCTAssertTrue(starred.rooms.contains(room.id))
        let unstarred = try await api.setFavorite(room.id, false)
        XCTAssertFalse(unstarred.rooms.contains(room.id))
        let level = try await api.setInvolvement(room.id, .nothing)
        XCTAssertEqual(level, "nothing")
        let settings = try await api.roomSettings(room.id)
        XCTAssertTrue(settings.canAdminister)
        XCTAssertEqual(Set(settings.people.filter(\.member).map(\.id)), [me.id, guest.id])
        let renamed = try await api.changeRoom(room.id, name: "renamed-\(room.id.suffix(4))", isPrivate: true, memberIds: [me.id])
        XCTAssertEqual(renamed.name, "renamed-\(room.id.suffix(4))")
        try await api.deleteRoom(room.id)
        let sidebar = try await api.sidebar()
        XCTAssertFalse(sidebar.rooms.contains { $0.id == room.id })
        XCTAssertTrue(sidebar.rooms.contains { $0.id == dm.id })

        // People and profile.
        let person = try await api.person(guest.id)
        XCTAssertEqual(person.name, guest.name)
        let profile = try await api.profile()
        let bio = "desktop \(Int.random(in: 1000...9999))"
        let changed = try await api.changeProfile(APIClient.ProfileChanges(bio: bio))
        XCTAssertEqual(changed.bio, bio)
        _ = try await api.changeProfile(APIClient.ProfileChanges(bio: profile.bio ?? ""))

        // An avatar: a generated picture, with its 512px variant.
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.orange.setFill(); rect.fill(); return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let withAvatar = try await api.changeAvatar(file: png, fileName: "a.png", contentType: "image/png", variant: try XCTUnwrap(image.jpegFitting(512)))
        XCTAssertTrue(withAvatar.avatar)
        let without = try await api.removeAvatar()
        XCTAssertFalse(without.avatar)
    }
}
