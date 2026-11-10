import Foundation

// The WebSocket frames from packages/protocol/src/index.ts (`ServerFrame`, `WorkspaceServerFrame`,
// `ClientFrame`). Server frames are decoded by their `type`; unknown types decode to `.other` so a newer
// server never breaks an older client.

enum RoomServerFrame: Decodable {
    case welcome(you: User, present: [User], seq: Int, messages: [Message], hasMore: Bool)
    case resumed(messages: [Message], deletedIds: [String], present: [User], seq: Int)
    case messageCreated(Message, seq: Int)
    case messageUpdated(Message, seq: Int)
    case messageDeleted(id: String, seq: Int)
    case boostCreated(Boost, seq: Int)
    case boostDeleted(boostId: String, messageId: String, seq: Int)
    case presenceJoined(User)
    case presenceLeft(userId: String)
    case typing(User, typing: Bool, threadId: String?)
    case history(before: String, messages: [Message], hasMore: Bool)
    case historyAfter(after: String, messages: [Message], hasNewer: Bool)
    case historyAround(messages: [Message], hasMore: Bool, hasNewer: Bool, around: String?)
    case messageChecked(stored: [String], missing: [String])
    case threadOpened(parentId: String, parent: Message?, messages: [Message], hasMore: Bool)
    case threadHistory(parentId: String, before: String, messages: [Message], hasMore: Bool)
    case error(message: String, clientMessageId: String?)
    case pong
    case other(String)

    private enum K: String, CodingKey {
        case type, you, present, seq, messages, hasMore, deletedIds, message, messageId, boost, boostId
        case user, userId, typing, threadId, before, stored, missing, clientMessageId, parentId, parent, after, hasNewer, around
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "welcome":
            self = .welcome(
                you: try c.decode(User.self, forKey: .you),
                present: try c.decode([User].self, forKey: .present),
                seq: try c.decode(Int.self, forKey: .seq),
                messages: try c.decode([Message].self, forKey: .messages),
                hasMore: try c.decode(Bool.self, forKey: .hasMore))
        case "resumed":
            self = .resumed(
                messages: try c.decode([Message].self, forKey: .messages),
                deletedIds: try c.decode([String].self, forKey: .deletedIds),
                present: try c.decode([User].self, forKey: .present),
                seq: try c.decode(Int.self, forKey: .seq))
        case "message.created":
            self = .messageCreated(try c.decode(Message.self, forKey: .message), seq: try c.decode(Int.self, forKey: .seq))
        case "message.updated":
            self = .messageUpdated(try c.decode(Message.self, forKey: .message), seq: try c.decode(Int.self, forKey: .seq))
        case "message.deleted":
            self = .messageDeleted(id: try c.decode(String.self, forKey: .messageId), seq: try c.decode(Int.self, forKey: .seq))
        case "boost.created":
            self = .boostCreated(try c.decode(Boost.self, forKey: .boost), seq: try c.decode(Int.self, forKey: .seq))
        case "boost.deleted":
            self = .boostDeleted(
                boostId: try c.decode(String.self, forKey: .boostId),
                messageId: try c.decode(String.self, forKey: .messageId),
                seq: try c.decode(Int.self, forKey: .seq))
        case "presence.joined":
            self = .presenceJoined(try c.decode(User.self, forKey: .user))
        case "presence.left":
            self = .presenceLeft(userId: try c.decode(String.self, forKey: .userId))
        case "typing":
            self = .typing(
                try c.decode(User.self, forKey: .user),
                typing: try c.decode(Bool.self, forKey: .typing),
                threadId: try c.decodeIfPresent(String.self, forKey: .threadId))
        case "history":
            self = .history(
                before: try c.decode(String.self, forKey: .before),
                messages: try c.decode([Message].self, forKey: .messages),
                hasMore: try c.decode(Bool.self, forKey: .hasMore))
        case "history.after":
            self = .historyAfter(
                after: try c.decode(String.self, forKey: .after),
                messages: try c.decode([Message].self, forKey: .messages),
                hasNewer: try c.decode(Bool.self, forKey: .hasNewer))
        case "history.around":
            self = .historyAround(
                messages: try c.decode([Message].self, forKey: .messages),
                hasMore: try c.decode(Bool.self, forKey: .hasMore),
                hasNewer: try c.decode(Bool.self, forKey: .hasNewer),
                around: try c.decodeIfPresent(String.self, forKey: .around))
        case "message.checked":
            self = .messageChecked(stored: try c.decode([String].self, forKey: .stored), missing: try c.decode([String].self, forKey: .missing))
        case "thread.opened":
            self = .threadOpened(
                parentId: try c.decode(String.self, forKey: .parentId),
                parent: try c.decodeIfPresent(Message.self, forKey: .parent),
                messages: try c.decode([Message].self, forKey: .messages),
                hasMore: try c.decode(Bool.self, forKey: .hasMore))
        case "thread.history":
            self = .threadHistory(
                parentId: try c.decode(String.self, forKey: .parentId),
                before: try c.decode(String.self, forKey: .before),
                messages: try c.decode([Message].self, forKey: .messages),
                hasMore: try c.decode(Bool.self, forKey: .hasMore))
        case "error":
            self = .error(message: try c.decode(String.self, forKey: .message), clientMessageId: try c.decodeIfPresent(String.self, forKey: .clientMessageId))
        case "pong":
            self = .pong
        default:
            self = .other(type)
        }
    }
}

enum WorkspaceServerFrame: Decodable {
    case welcome(you: Me)
    case roomUnread(String)
    case roomRead(String)
    case userUpdated(DirectoryUser)
    case roomSaved(Room)
    case roomGone(String)
    case roomActive(String, at: String)
    case favoritesChanged(Favorites)
    case roomInvolvement(String, involvement: String)
    case roomsReordered
    case error(String)
    case pong
    case other(String)

    private enum K: String, CodingKey {
        case type, you, roomId, user, room, at, favorites, involvement, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "welcome": self = .welcome(you: try c.decode(Me.self, forKey: .you))
        case "room.unread": self = .roomUnread(try c.decode(String.self, forKey: .roomId))
        case "room.read": self = .roomRead(try c.decode(String.self, forKey: .roomId))
        case "user.updated": self = .userUpdated(try c.decode(DirectoryUser.self, forKey: .user))
        case "room.saved": self = .roomSaved(try c.decode(Room.self, forKey: .room))
        case "room.gone": self = .roomGone(try c.decode(String.self, forKey: .roomId))
        case "room.active": self = .roomActive(try c.decode(String.self, forKey: .roomId), at: try c.decode(String.self, forKey: .at))
        case "favorites.changed": self = .favoritesChanged(try c.decode(Favorites.self, forKey: .favorites))
        case "room.involvement":
            self = .roomInvolvement(try c.decode(String.self, forKey: .roomId), involvement: try c.decode(String.self, forKey: .involvement))
        case "rooms.reordered": self = .roomsReordered
        case "error": self = .error(try c.decode(String.self, forKey: .message))
        case "pong": self = .pong
        default: self = .other(type)
        }
    }
}

/// What the client sends on a room socket. Encoded by hand to match the protocol's flat objects.
enum RoomClientFrame {
    case messageCreate(clientMessageId: String, body: String, parentId: String? = nil, alsoSend: Bool = false)
    case messageUpdate(messageId: String, body: String)
    case messageDelete(messageId: String)
    case boostCreate(messageId: String, content: String)
    case boostDelete(boostId: String)
    case typingStart
    case typingStop
    case historyBefore(before: String)
    case historyAfter(after: String)
    case historyAround(messageId: String?)
    case messageCheck(clientMessageIds: [String])
    case threadOpen(parentId: String)
    case threadClose(parentId: String)
    case threadBefore(parentId: String, before: String)
    case presenceVisible(Bool)
    case ping

    var json: [String: Any] {
        switch self {
        case let .messageCreate(id, body, parentId, alsoSend):
            var frame: [String: Any] = ["type": "message.create", "clientMessageId": id, "body": body]
            if let parentId {
                frame["parentId"] = parentId
                if alsoSend { frame["alsoSend"] = true }
            }
            return frame
        case let .messageUpdate(id, body): return ["type": "message.update", "messageId": id, "body": body]
        case let .messageDelete(id): return ["type": "message.delete", "messageId": id]
        case let .boostCreate(id, content): return ["type": "boost.create", "messageId": id, "content": content]
        case let .boostDelete(id): return ["type": "boost.delete", "boostId": id]
        case .typingStart: return ["type": "typing.start"]
        case .typingStop: return ["type": "typing.stop"]
        case let .historyBefore(before): return ["type": "history.before", "before": before]
        case let .historyAfter(after): return ["type": "history.after", "after": after]
        case let .historyAround(id):
            var frame: [String: Any] = ["type": "history.around"]
            if let id { frame["messageId"] = id }
            return frame
        case let .messageCheck(ids): return ["type": "message.check", "clientMessageIds": ids]
        case let .threadOpen(id): return ["type": "thread.open", "parentId": id]
        case let .threadClose(id): return ["type": "thread.close", "parentId": id]
        case let .threadBefore(id, before): return ["type": "thread.before", "parentId": id, "before": before]
        case let .presenceVisible(visible): return ["type": "presence.visible", "visible": visible]
        case .ping: return ["type": "ping"]
        }
    }

    var text: String {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Close codes from `CloseCode` in the protocol.
enum EmberCloseCode {
    static let reconnect = 4001
    static let revoked = 4003
    static let notFound = 4004
}

/// The room protocol revision this client speaks (`ROOM_PROTOCOL`). The room refuses messages from an
/// older revision, so bump this only together with the frames above.
let roomProtocol = 4

/// Message markup for plain text, as `bodyFromPlainText` writes it: one `<p>`, lines split by `<br>`,
/// and `&`, `<`, `>` escaped. The room stores this form without parsing it.
func bodyMarkup(fromPlainText text: String) -> String {
    let escaped = text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\u{00A0}", with: "&nbsp;")
        .replacingOccurrences(of: "\r\n", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .joined(separator: "<br>")
    return "<p>\(escaped)</p>"
}
