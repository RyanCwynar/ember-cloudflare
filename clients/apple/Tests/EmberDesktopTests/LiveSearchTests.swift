import XCTest
@testable import EmberDesktop

/// Search and jumping to a message against a running Ember, as `LiveServerTests`.
@MainActor
final class LiveSearchTests: XCTestCase {
    func testSearchFindsAMessageAndJumpingLandsOnIt() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["EMBER_TEST_SERVER"].flatMap(APIClient.serverURL(from:)),
              let email = env["EMBER_TEST_EMAIL"], let password = env["EMBER_TEST_PASSWORD"] else {
            throw XCTSkip("Set EMBER_TEST_SERVER, EMBER_TEST_EMAIL and EMBER_TEST_PASSWORD to run against a live Ember")
        }
        let api = APIClient(server: server)
        let me = try await api.signIn(email: email, password: password)
        let rooms = try await api.sidebar().rooms
        let room = try XCTUnwrap(rooms.first { !$0.isDirect })
        let store = RoomStore(roomId: room.id, api: api, myId: me.id)
        store.connect()
        try await waitUntil { store.connected }

        // A message with a word nothing else has, then more than a page after it.
        let word = "zebra\(Int.random(in: 100_000...999_999))"
        store.sendMessage("find the \(word) here")
        try await waitUntil { store.messages.contains { $0.plainText.contains(word) } }
        let target = try XCTUnwrap(store.messages.first { $0.plainText.contains(word) })
        for n in 1...45 { store.sendMessage("filler \(n) after \(word.suffix(3))") }
        try await waitUntil(timeout: 30) { store.pending.isEmpty }

        // Search finds it, by word and with a filter, and records it as recent.
        var found: SearchResults?
        for _ in 0..<50 {
            found = try await api.search(Search(q: word))
            if found?.matches.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(found?.matches.first?.message.id, target.id)
        XCTAssertEqual(found?.matches.first?.words.map { $0.lowercased() }, [word])
        let inRoom = try await api.search(Search(q: word, in: room.id, from: me.id))
        XCTAssertEqual(inRoom.matches.count, 1)
        let recorded = try await api.recordSearch(Search(q: word))
        XCTAssertTrue(recorded.recent.contains { $0.q == word })
        try await api.clearRecentSearches()

        store.close()

        // A fresh look at the room has only the newest page, without it. Jumping fetches the page around
        // it, with newer messages left to load, and Jump to newest brings them back.
        let fresh = RoomStore(roomId: room.id, api: api, myId: me.id)
        fresh.connect()
        try await waitUntil { fresh.connected && !fresh.messages.isEmpty }
        XCTAssertFalse(fresh.messages.contains { $0.id == target.id })
        fresh.jump(to: target.id)
        try await waitUntil { fresh.highlightedId == target.id && fresh.hasNewer }
        XCTAssertTrue(fresh.messages.contains { $0.id == target.id })
        fresh.jump(to: nil)
        try await waitUntil { !fresh.hasNewer && fresh.messages.last?.plainText.hasPrefix("filler 45") == true }
        fresh.close()
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
