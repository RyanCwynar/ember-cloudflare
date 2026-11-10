import XCTest
@testable import EmberDesktop

/// Uploads against a running Ember, as `LiveServerTests`: a picture with its preview, and a file large
/// enough to take several parts, each read back with the session's cookie.
@MainActor
final class LiveUploadTests: XCTestCase {
    func testUploadsPictureAndMultipartFile() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["EMBER_TEST_SERVER"].flatMap(APIClient.serverURL(from:)),
              let email = env["EMBER_TEST_EMAIL"], let password = env["EMBER_TEST_PASSWORD"] else {
            throw XCTSkip("Set EMBER_TEST_SERVER, EMBER_TEST_EMAIL and EMBER_TEST_PASSWORD to run against a live Ember")
        }
        let api = APIClient(server: server)
        _ = try await api.signIn(email: email, password: password)
        let rooms = try await api.sidebar().rooms
        let room = try XCTUnwrap(rooms.first { !$0.isDirect })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A picture: its message has the file, with a preview the client made.
        let image = NSImage(size: NSSize(width: 1600, height: 900), flipped: false) { rect in
            NSColor.orange.setFill(); rect.fill(); return true
        }
        let pictureURL = dir.appendingPathComponent("sunset.png")
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: pictureURL)
        let picture = try await Uploads.upload(pictureURL, to: room.id, api: api, clientMessageId: UUID().uuidString.lowercased(),
                                               parentId: nil, alsoSend: false, progress: { _ in })
        let pictureFile = try XCTUnwrap(picture.attachment)
        XCTAssertEqual(pictureFile.name, "sunset.png")
        XCTAssertEqual(pictureFile.contentType, "image/png")
        XCTAssertNotNil(pictureFile.previewUrl, "the preview should have been kept")
        try await assertDownloads(pictureFile, equal: try Data(contentsOf: pictureURL), api: api)

        // A file over one part (parts are at least 5 MiB), with recognizable bytes.
        var bytes = Data(count: 12 * 1024 * 1024 + 123)
        bytes.withUnsafeMutableBytes { buffer in for i in 0..<buffer.count { buffer[i] = UInt8(truncatingIfNeeded: i &* 31) } }
        let bigURL = dir.appendingPathComponent("big.bin")
        try bytes.write(to: bigURL)
        var seen: [Double] = []
        let big = try await Uploads.upload(bigURL, to: room.id, api: api, clientMessageId: UUID().uuidString.lowercased(),
                                           parentId: nil, alsoSend: false, progress: { seen.append($0) })
        XCTAssertEqual(big.attachment?.byteSize, bytes.count)
        XCTAssertEqual(seen.last, 1)
        try await assertDownloads(try XCTUnwrap(big.attachment), equal: bytes, api: api)

        // Clean up through the room, as a person would.
        let store = RoomStore(roomId: room.id, api: api, myId: picture.creator.id)
        store.connect()
        let deadline = Date().addingTimeInterval(10)
        while !store.connected, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        store.delete(picture)
        store.delete(big)
        try await Task.sleep(for: .milliseconds(500))
        store.close()
    }

    private func assertDownloads(_ file: StoredFile, equal expected: Data, api: APIClient) async throws {
        let url = try XCTUnwrap(api.absolute(file.downloadUrl))
        let (data, response) = try await api.session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, expected)
    }
}
