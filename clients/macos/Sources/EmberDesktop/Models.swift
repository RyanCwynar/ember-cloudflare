import Foundation

// Swift mirrors of the types in packages/protocol/src/index.ts. Only the fields the desktop client
// uses are declared; JSONDecoder ignores the rest, so the server can add fields without breaking us.

struct User: Codable, Hashable, Identifiable {
    let id: String
    let name: String
}

struct Me: Codable, Hashable {
    let id: String
    let name: String
    let administrator: Bool
}

struct DirectoryUser: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let bio: String?
    let role: String
    let status: String
    let avatarUrl: String
    let agent: Bool?
}

struct Directory: Codable {
    let users: [DirectoryUser]
}

/// A room as the sidebar lists it. The protocol's `Room` is a union of `SharedRoom` (open/closed, with a
/// name and icon) and `DirectRoom` (direct, named by its members); one struct with optionals covers both.
struct Room: Codable, Hashable, Identifiable {
    let id: String
    let kind: String
    var name: String?
    var icon: String?
    var members: [User]?
    var activeAt: String?
    var unread: Bool
    var involvement: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, name, icon, members, activeAt, unread, involvement
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        members = try c.decodeIfPresent([User].self, forKey: .members)
        activeAt = try c.decodeIfPresent(String.self, forKey: .activeAt)
        // `room.saved` sends a plain Room, which has no unread mark: a room new to someone starts read.
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        involvement = try c.decodeIfPresent(String.self, forKey: .involvement)
    }

    var isDirect: Bool { kind == "direct" }

    /// A DM is named after everyone in it but whoever's reading.
    func title(me: String?) -> String {
        if let name { return name }
        let others = (members ?? []).filter { $0.id != me }.map(\.name)
        return others.isEmpty ? "Just you" : others.joined(separator: ", ")
    }

    /// Hidden rooms ("invisible") stay openable but the sidebar leaves them out.
    var isHidden: Bool { involvement == "invisible" }
}

struct Favorites: Codable, Hashable {
    let rooms: [String]
    let version: Int
}

struct Sidebar: Codable {
    let rooms: [Room]
    let favorites: Favorites
    let sharedOrder: [String]
}

struct Boost: Codable, Hashable, Identifiable {
    let id: String
    let messageId: String
    let booster: User
    let content: String
    let createdAt: String
}

struct StoredFile: Codable, Hashable {
    let id: String
    let name: String
    let contentType: String
    let byteSize: Int
    let width: Int?
    let height: Int?
    let url: String
    let downloadUrl: String
    let previewUrl: String?

    var isImage: Bool { contentType.hasPrefix("image/") }
}

struct ThreadSummary: Codable, Hashable {
    let count: Int
    let latestAt: String
    let people: [User]
}

struct Message: Codable, Hashable, Identifiable {
    let id: String
    let clientMessageId: String
    let roomId: String
    let creator: User
    let body: String
    let plainText: String
    let mentions: [User]
    let createdAt: String
    let updatedAt: String
    let editedAt: String?
    var boosts: [Boost]
    let attachment: StoredFile?
    let parentId: String?
    let alsoSent: Bool?
    let parentText: String?
    let thread: ThreadSummary?
    let deleted: Bool?

    /// Mirrors `isInRoom`: every message but a reply sent only to its thread.
    var isInRoom: Bool { parentId == nil || alsoSent == true }

    var createdDate: Date { EmberDate.parse(createdAt) ?? .distantPast }
}

struct RoomPerson: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let member: Bool
}

struct NewRoomForm: Codable {
    let people: [User]
}

struct RoomSettings: Codable {
    let room: Room
    let canAdminister: Bool
    let people: [RoomPerson]
}

struct RoomAnswer: Codable {
    let room: Room
}

struct FavoritesAnswer: Codable {
    let favorites: Favorites
}

struct InvolvementAnswer: Codable {
    let involvement: String
}

struct Person: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let bio: String?
    let role: String
    let status: String
    let avatarUrl: String
    let agent: Bool?
    let emailAddress: String?
}

struct PersonAnswer: Codable {
    let person: Person
}

struct Profile: Codable, Hashable {
    let name: String
    let emailAddress: String?
    let bio: String?
    let avatarUrl: String
    let avatar: Bool
    let password: Bool
}

struct ProfileAnswer: Codable {
    let profile: Profile
}

/// Notification levels (`INVOLVEMENTS`), as a room's bell offers them.
enum Involvement: String, CaseIterable, Identifiable {
    case everything, mentions, nothing, invisible
    var id: String { rawValue }
    var label: String {
        switch self {
        case .everything: "All messages"
        case .mentions: "Only @mentions"
        case .nothing: "Nothing"
        case .invisible: "Nothing, and hide it"
        }
    }
    var symbol: String {
        switch self {
        case .everything: "bell.fill"
        case .mentions: "at"
        case .nothing: "bell.slash"
        case .invisible: "eye.slash"
        }
    }
}

/// A search, with its filters (`Search` in packages/protocol/src/search.ts).
struct Search: Codable, Hashable {
    var q: String = ""
    var `in`: String?
    var from: String?
    var withMe: Bool?
    var hasLink: Bool?
    var hasFile: Bool?
    var inThread: Bool?

    var isSearchable: Bool {
        !q.trimmingCharacters(in: .whitespaces).isEmpty || `in` != nil || from != nil
            || withMe == true || hasLink == true || hasFile == true || inThread == true
    }

    /// The query `searchQuery` writes.
    func query(sort: String, cursor: Int?) -> String {
        var items = [URLQueryItem(name: "q", value: q)]
        if let `in` { items.append(URLQueryItem(name: "in", value: `in`)) }
        if let from { items.append(URLQueryItem(name: "from", value: from)) }
        if withMe == true { items.append(URLQueryItem(name: "with", value: "me")) }
        if hasLink == true { items.append(URLQueryItem(name: "has", value: "link")) }
        if hasFile == true { items.append(URLQueryItem(name: "has", value: "file")) }
        if inThread == true { items.append(URLQueryItem(name: "is", value: "thread")) }
        if sort != "newest" { items.append(URLQueryItem(name: "sort", value: sort)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: String(cursor))) }
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery ?? ""
    }
}

struct SearchMatch: Codable, Hashable {
    let message: Message
    let words: [String]
}

struct SearchResults: Codable {
    let search: Search?
    let matches: [SearchMatch]
    let next: Int?
    let rooms: [Room]
    let recent: [Search]
}

/// What `/api/session` and `/api/me` answer.
struct UserAnswer: Codable {
    let user: Me
}

/// Every `/api/*` failure answers `{ "error": "..." }`.
struct ProblemAnswer: Codable {
    let error: String
}

enum EmberDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole = ISO8601DateFormatter()

    static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? whole.date(from: string)
    }
}

/// The reactions the web app offers (`REACTIONS` in the protocol).
let quickReactions = ["👍", "👏", "👋", "💪", "❤️", "😂", "🎉", "🔥"]
