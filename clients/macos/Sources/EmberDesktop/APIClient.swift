import Foundation

enum APIError: LocalizedError {
    case server(status: Int, message: String)
    case notSignedIn
    case invalidServer

    var errorDescription: String? {
        switch self {
        case let .server(_, message): message
        case .notSignedIn: "Not signed in"
        case .invalidServer: "That doesn't look like an Ember address, such as https://chat.example.com"
        }
    }
}

/// Talks to an Ember Worker's `/api/*` routes.
///
/// Ember signs in with an HttpOnly session cookie (`__Host-session_token` over HTTPS), which
/// `HTTPCookieStorage.shared` keeps between launches. The Worker refuses writes and socket upgrades that
/// don't look same-origin (`isCrossSite` / `isSameOriginUpgrade` in apps/worker/src/auth.ts), so every
/// request carries `Origin: <server>` and `Sec-Fetch-Site: same-origin`, as the web app's pages would.
final class APIClient: @unchecked Sendable {
    let server: URL
    let session: URLSession

    init(server: URL) {
        self.server = server
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: config)
    }

    /// The server's origin, `https://host[:port]`, which `Origin` must equal.
    var origin: String {
        var components = URLComponents()
        components.scheme = server.scheme
        components.host = server.host
        components.port = server.port
        return components.string ?? server.absoluteString
    }

    /// Normalizes what someone typed into a server address: adds https:// and drops any path.
    static func serverURL(from typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty,
              components.scheme == "https" || components.scheme == "http" else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func request(_ path: String, method: String = "GET", body: Encodable? = nil) throws -> URLRequest {
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    func send<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET", body: Encodable? = nil) async throws -> T {
        let (data, response) = try await session.data(for: try request(path, method: method, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 && path != "/api/session" { throw APIError.notSignedIn }
            let message = (try? JSONDecoder().decode(ProblemAnswer.self, from: data))?.error
                ?? "The server answered \(status)."
            throw APIError.server(status: status, message: message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func sendIgnoringBody(_ path: String, method: String, body: Encodable? = nil) async throws {
        let (data, response) = try await session.data(for: try request(path, method: method, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ProblemAnswer.self, from: data))?.error ?? "The server answered \(status)."
            throw APIError.server(status: status, message: message)
        }
    }

    // MARK: Routes

    struct PasswordSignIn: Encodable {
        let emailAddress: String
        let password: String
    }

    func signIn(email: String, password: String) async throws -> Me {
        try await send(UserAnswer.self, "/api/session", method: "POST", body: PasswordSignIn(emailAddress: email, password: password)).user
    }

    func me() async throws -> Me {
        try await send(UserAnswer.self, "/api/me").user
    }

    func signOut() async {
        try? await sendIgnoringBody("/api/session", method: "DELETE")
        for cookie in HTTPCookieStorage.shared.cookies(for: server) ?? [] {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    func sidebar() async throws -> Sidebar {
        try await send(Sidebar.self, "/api/sidebar")
    }

    func directory() async throws -> Directory {
        try await send(Directory.self, "/api/users")
    }

    // MARK: Rooms and DMs

    private struct NewRoom: Encodable {
        let name: String
        let kind: String
        let memberIds: [String]?
    }

    func newRoomForm() async throws -> NewRoomForm {
        try await send(NewRoomForm.self, "/api/rooms/new")
    }

    func createRoom(name: String, isPrivate: Bool, memberIds: [String]) async throws -> Room {
        let body = NewRoom(name: name, kind: isPrivate ? "closed" : "open", memberIds: isPrivate ? memberIds : nil)
        return try await send(RoomAnswer.self, "/api/rooms", method: "POST", body: body).room
    }

    private struct NewDirect: Encodable { let userIds: [String] }

    /// Starts a DM with these people, or answers the one that already has exactly them.
    func startDirect(with userIds: [String]) async throws -> Room {
        try await send(RoomAnswer.self, "/api/directs", method: "POST", body: NewDirect(userIds: userIds)).room
    }

    func roomSettings(_ roomId: String) async throws -> RoomSettings {
        try await send(RoomSettings.self, "/api/rooms/\(roomId)/settings")
    }

    private struct RoomChanges: Encodable {
        let name: String?
        let kind: String?
        let memberIds: [String]?
    }

    func changeRoom(_ roomId: String, name: String?, isPrivate: Bool?, memberIds: [String]?) async throws -> Room {
        let kind = isPrivate.map { $0 ? "closed" : "open" }
        let body = RoomChanges(name: name, kind: kind, memberIds: isPrivate == true ? memberIds : nil)
        return try await send(RoomAnswer.self, "/api/rooms/\(roomId)", method: "PATCH", body: body).room
    }

    func deleteRoom(_ roomId: String) async throws {
        try await sendIgnoringBody("/api/rooms/\(roomId)", method: "DELETE")
    }

    func leaveRoom(_ roomId: String) async throws {
        try await sendIgnoringBody("/api/rooms/\(roomId)/membership", method: "DELETE")
    }

    private struct FavoriteChange: Encodable { let favorite: Bool }

    func setFavorite(_ roomId: String, _ favorite: Bool) async throws -> Favorites {
        try await send(FavoritesAnswer.self, "/api/rooms/\(roomId)/favorite", method: "PUT", body: FavoriteChange(favorite: favorite)).favorites
    }

    private struct InvolvementChange: Encodable { let involvement: String }

    func setInvolvement(_ roomId: String, _ involvement: Involvement) async throws -> String {
        try await send(InvolvementAnswer.self, "/api/rooms/\(roomId)/involvement", method: "PUT", body: InvolvementChange(involvement: involvement.rawValue)).involvement
    }

    // MARK: People and profile

    func person(_ userId: String) async throws -> Person {
        try await send(PersonAnswer.self, "/api/users/\(userId)").person
    }

    func profile() async throws -> Profile {
        try await send(ProfileAnswer.self, "/api/users/me/profile").profile
    }

    struct ProfileChanges: Encodable {
        var name: String?
        var emailAddress: String?
        var password: String?
        var bio: String?
        var currentPassword: String?
    }

    func changeProfile(_ changes: ProfileChanges) async throws -> Profile {
        try await send(ProfileAnswer.self, "/api/users/me/profile", method: "PATCH", body: changes).profile
    }

    /// Uploads a picture as your avatar: the file as `avatar`, and a JPEG within 512×512 as `variant`,
    /// which is what the web app makes in the browser before sending.
    func changeAvatar(file: Data, fileName: String, contentType: String, variant: Data) async throws -> Profile {
        let boundary = "ember-\(UUID().uuidString)"
        var body = Data()
        func part(_ name: String, _ filename: String, _ type: String, _ data: Data) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        part("avatar", fileName, contentType, file)
        part("variant", "variant.jpg", "image/jpeg", variant)
        body.append(Data("--\(boundary)--\r\n".utf8))
        var request = try request("/api/users/me/avatar", method: "PUT")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ProblemAnswer.self, from: data))?.error ?? "The server answered \(status)."
            throw APIError.server(status: status, message: message)
        }
        return try JSONDecoder().decode(ProfileAnswer.self, from: data).profile
    }

    func removeAvatar() async throws -> Profile {
        try await send(ProfileAnswer.self, "/api/users/me/avatar", method: "DELETE").profile
    }

    // MARK: Search

    func search(_ search: Search, sort: String = "newest", cursor: Int? = nil) async throws -> SearchResults {
        var request = try request("/api/searches")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = search.query(sort: sort, cursor: cursor)
        request.url = components.url
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode(ProblemAnswer.self, from: data))?.error ?? "The server answered \(status)."
            throw APIError.server(status: status, message: message)
        }
        return try JSONDecoder().decode(SearchResults.self, from: data)
    }

    private struct RecordedSearch: Encodable {
        let search: Search
        let sort: String
        func encode(to encoder: Encoder) throws {
            try search.encode(to: encoder)
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(sort, forKey: .sort)
        }
        enum Key: String, CodingKey { case sort }
    }

    /// Saves a search among your recent ones and answers its first page.
    func recordSearch(_ search: Search, sort: String = "newest") async throws -> SearchResults {
        try await send(SearchResults.self, "/api/searches", method: "POST", body: RecordedSearch(search: search, sort: sort))
    }

    func clearRecentSearches() async throws {
        try await sendIgnoringBody("/api/searches", method: "DELETE")
    }

    // MARK: Sockets

    /// A WebSocket upgrade request for `path`, carrying the session cookie and the same-origin headers.
    func socketRequest(_ path: String, query: String = "") -> URLRequest? {
        guard var components = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = server.scheme == "http" ? "ws" : "wss"
        if !query.isEmpty { components.percentEncodedQuery = query }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        // Attach the cookie by hand: a ws(s):// URL doesn't match the https:// cookie's domain lookup in
        // every macOS release, and the Worker refuses an upgrade without it.
        let cookies = HTTPCookieStorage.shared.cookies(for: server) ?? []
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// An absolute URL for a path the server hands out, such as an avatar's or a file's.
    func absolute(_ path: String) -> URL? {
        URL(string: path, relativeTo: server)?.absoluteURL
    }
}
