import AppKit
import Foundation
import Observation

/// The signed-in workspace: who's signed in, their rooms, the people directory, and the workspace socket
/// (`/api/socket`) that keeps the sidebar current.
@MainActor
@Observable
final class AppState {
    enum Phase: Equatable { case starting, signedOut, signedIn }

    private static let serverKey = "EmberServerURL"

    var phase: Phase = .starting
    var serverText: String = UserDefaults.standard.string(forKey: AppState.serverKey) ?? ""
    private(set) var api: APIClient?
    private(set) var me: Me?
    private(set) var rooms: [Room] = []
    private(set) var favorites: [String] = []
    private(set) var sharedOrder: [String] = []
    private(set) var people: [String: DirectoryUser] = [:]
    var selectedRoomId: String?
    var appIsActive = true
    var connectionProblem: String?

    /// The sheet over the workspace, if one is open.
    var sheet: Sheet?

    enum Sheet: Identifiable, Hashable {
        case newDirect, newRoom, people, profile, search
        case person(String)
        case image(StoredFile)
        case web(path: String, title: String)
        case roomSettings(String)

        var id: String {
            switch self {
            case .newDirect: "newDirect"
            case .newRoom: "newRoom"
            case .people: "people"
            case .profile: "profile"
            case .search: "search"
            case let .person(id): "person-\(id)"
            case let .roomSettings(id): "room-\(id)"
            case let .image(file): "image-\(file.id)"
            case let .web(path, _): "web-\(path)"
            }
        }
    }

    private var workspaceSocket: Socket?
    /// Rendered bodies by message id and update time, since parsing markup on every redraw adds up.
    @ObservationIgnored private var renderedBodies: [String: [RichBlock]] = [:]
    private var roomStores: [String: RoomStore] = [:]

    // MARK: Signing in

    func start() async {
        guard let url = APIClient.serverURL(from: serverText) else { phase = .signedOut; return }
        let api = APIClient(server: url)
        do {
            me = try await api.me()
            self.api = api
            await enterWorkspace()
        } catch {
            phase = .signedOut
        }
    }

    func signIn(email: String, password: String) async throws {
        guard let url = APIClient.serverURL(from: serverText) else { throw APIError.invalidServer }
        let api = APIClient(server: url)
        me = try await api.signIn(email: email, password: password)
        self.api = api
        serverText = url.absoluteString
        UserDefaults.standard.set(serverText, forKey: AppState.serverKey)
        await enterWorkspace()
    }

    func signOut() async {
        workspaceSocket?.close()
        roomStores.values.forEach { $0.close() }
        roomStores = [:]
        await api?.signOut()
        me = nil
        rooms = []
        selectedRoomId = nil
        phase = .signedOut
    }

    private func enterWorkspace() async {
        phase = .signedIn
        await reloadSidebar()
        await reloadDirectory()
        if selectedRoomId == nil { selectedRoomId = sortedSharedRooms.first?.id ?? directs.first?.id }
        connectWorkspaceSocket()
        Notifier.shared.requestPermission()
    }

    // MARK: Sidebar

    func reloadSidebar() async {
        guard let api else { return }
        do {
            let sidebar = try await api.sidebar()
            rooms = sidebar.rooms
            favorites = sidebar.favorites.rooms
            sharedOrder = sidebar.sharedOrder
        } catch APIError.notSignedIn {
            await signOut()
        } catch {
            connectionProblem = error.localizedDescription
        }
    }

    func reloadDirectory() async {
        guard let api, let directory = try? await api.directory() else { return }
        people = Dictionary(directory.users.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var visibleRooms: [Room] { rooms.filter { !$0.isHidden } }

    var starredRooms: [Room] {
        favorites.compactMap { id in visibleRooms.first { $0.id == id } }
    }

    /// Shared rooms not starred: the workspace's shared order first, then the rest in the order they were made.
    var sortedSharedRooms: [Room] {
        let shared = visibleRooms.filter { !$0.isDirect && !favorites.contains($0.id) }
        let ranked = sharedOrder.compactMap { id in shared.first { $0.id == id } }
        return ranked + shared.filter { !sharedOrder.contains($0.id) }
    }

    /// DMs not starred, latest activity first.
    var directs: [Room] {
        visibleRooms
            .filter { $0.isDirect && !favorites.contains($0.id) }
            .sorted { ($0.activeAt ?? "") > ($1.activeAt ?? "") }
    }

    func room(_ id: String) -> Room? { rooms.first { $0.id == id } }

    func title(of room: Room) -> String { room.title(me: me?.id) }

    func name(of userId: String) -> String? { people[userId]?.name }

    /// The people an @mention can name: everyone active but me.
    var mentionable: [DirectoryUser] {
        people.values.filter { $0.status == "active" && $0.id != me?.id }
    }

    func blocks(for message: Message) -> [RichBlock] {
        let key = "\(message.id)@\(message.updatedAt)"
        if let cached = renderedBodies[key] { return cached }
        let known = Dictionary(message.mentions.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let renderer = RichTextRenderer(name: { [people] id in people[id]?.name ?? known[id] }, server: api?.server)
        let blocks = renderer.blocks(message.body)
        renderedBodies[key] = blocks
        return blocks
    }

    func showPerson(_ userId: String) { sheet = .person(userId) }

    // MARK: Permalinks

    /// A message's address, as the web app's Copy link gives it.
    func permalink(for message: Message) -> URL? {
        let path = message.parentId.map { "/rooms/\(message.roomId)/threads/\($0)/@\(message.id)" } ?? "/rooms/\(message.roomId)/@\(message.id)"
        return api.flatMap { URL(string: path, relativeTo: $0.server)?.absoluteURL }
    }

    /// Opens a room at a message, and its thread for a reply.
    func open(roomId: String, messageId: String?, threadParentId: String? = nil) {
        guard room(roomId) != nil else { connectionProblem = "That room isn't one of yours."; return }
        selectedRoomId = roomId
        guard let store = store(for: roomId) else { return }
        if let threadParentId {
            store.jump(to: threadParentId)
            store.openThread(threadParentId)
        } else {
            store.jump(to: messageId)
        }
    }

    /// Opens a link to this Ember in the app: a room, a message's permalink, or a thread. Answers false
    /// for anything else, which opens in the browser.
    func openInApp(_ url: URL) -> Bool {
        guard let server = api?.server, url.host == server.host, url.port == server.port else { return false }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "rooms" else { return false }
        let roomId = parts[1]
        if parts.count >= 4, parts[2] == "threads" {
            open(roomId: roomId, messageId: nil, threadParentId: parts[3])
        } else if parts.count >= 4, parts[2] == "messages" {
            open(roomId: roomId, messageId: parts[3])
        } else if parts.count >= 3, parts[2].hasPrefix("@") {
            open(roomId: roomId, messageId: String(parts[2].dropFirst()))
        } else {
            open(roomId: roomId, messageId: nil)
        }
        return true
    }

    /// Downloads a file with the session's cookie to Downloads, then shows it in Finder.
    func download(_ file: StoredFile) {
        guard let api, let url = api.absolute(file.downloadUrl) else { return }
        Task {
            do {
                let (temporary, response) = try await api.session.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.server(status: 0, message: "Couldn't download \(file.name).") }
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                var target = downloads.appendingPathComponent(file.name)
                var n = 1
                while FileManager.default.fileExists(atPath: target.path) {
                    n += 1
                    let base = (file.name as NSString).deletingPathExtension, ext = (file.name as NSString).pathExtension
                    target = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                }
                try FileManager.default.moveItem(at: temporary, to: target)
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch {
                connectionProblem = error.localizedDescription
            }
        }
    }

    /// Everyone in the directory, active people first, by name.
    var directory: [DirectoryUser] {
        people.values.sorted { a, b in
            (a.status == "active") != (b.status == "active") ? a.status == "active" : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Room actions

    /// Adds a room the server just answered with, unless the workspace socket got there first.
    private func adopt(_ room: Room) {
        if let index = rooms.firstIndex(where: { $0.id == room.id }) {
            var kept = room
            kept.unread = rooms[index].unread
            kept.involvement = rooms[index].involvement ?? room.involvement
            rooms[index] = kept
        } else {
            var added = room
            added.involvement = added.involvement ?? (room.isDirect ? "everything" : "mentions")
            rooms.append(added)
        }
    }

    /// Opens the DM with exactly these people, starting it if there isn't one.
    func openDirect(with userIds: [String]) async throws {
        guard let api else { return }
        let room = try await api.startDirect(with: userIds)
        adopt(room)
        selectedRoomId = room.id
    }

    func createRoom(name: String, isPrivate: Bool, memberIds: [String]) async throws {
        guard let api else { return }
        let room = try await api.createRoom(name: name, isPrivate: isPrivate, memberIds: memberIds)
        adopt(room)
        selectedRoomId = room.id
    }

    func changeRoom(_ roomId: String, name: String?, isPrivate: Bool?, memberIds: [String]?) async throws {
        guard let api else { return }
        adopt(try await api.changeRoom(roomId, name: name, isPrivate: isPrivate, memberIds: memberIds))
    }

    func deleteRoom(_ roomId: String) async throws {
        try await api?.deleteRoom(roomId)
        forget(roomId)
    }

    func leaveRoom(_ roomId: String) async throws {
        try await api?.leaveRoom(roomId)
        forget(roomId)
    }

    private func forget(_ roomId: String) {
        rooms.removeAll { $0.id == roomId }
        roomStores.removeValue(forKey: roomId)?.close()
        if selectedRoomId == roomId { selectedRoomId = sortedSharedRooms.first?.id }
    }

    func isStarred(_ roomId: String) -> Bool { favorites.contains(roomId) }

    func toggleStar(_ roomId: String) async {
        guard let api else { return }
        do { favorites = try await api.setFavorite(roomId, !isStarred(roomId)).rooms } catch { connectionProblem = error.localizedDescription }
    }

    func setInvolvement(_ roomId: String, _ involvement: Involvement) async {
        guard let api else { return }
        do {
            let saved = try await api.setInvolvement(roomId, involvement)
            if let index = rooms.firstIndex(where: { $0.id == roomId }) { rooms[index].involvement = saved }
        } catch {
            connectionProblem = error.localizedDescription
        }
    }

    /// Picks the next room up or down the sidebar, or the next unread one.
    func selectNeighbor(down: Bool, unreadOnly: Bool) {
        let order = (starredRooms + sortedSharedRooms + directs).map(\.id)
        guard !order.isEmpty else { return }
        let current = selectedRoomId.flatMap { order.firstIndex(of: $0) } ?? (down ? -1 : order.count)
        var index = current
        while true {
            index += down ? 1 : -1
            guard order.indices.contains(index) else { return }
            if !unreadOnly || room(order[index])?.unread == true { selectedRoomId = order[index]; return }
        }
    }

    func profileChanged(_ profile: Profile) {
        if let me { self.me = Me(id: me.id, name: profile.name, administrator: me.administrator) }
        Task { await reloadDirectory() }
    }

    func avatarURL(for userId: String) -> URL? {
        guard let path = people[userId]?.avatarUrl else { return nil }
        return api?.absolute(path)
    }

    // MARK: Rooms

    func store(for roomId: String) -> RoomStore? {
        guard let api, let me else { return nil }
        if let store = roomStores[roomId] { return store }
        let store = RoomStore(roomId: roomId, api: api, myId: me.id)
        store.visible = appIsActive
        roomStores[roomId] = store
        store.connect()
        return store
    }

    func setAppActive(_ active: Bool) {
        appIsActive = active
        // Only the room on screen counts as seen; that's what clears its unread mark on the server.
        for (id, store) in roomStores { store.setVisible(active && id == selectedRoomId) }
    }

    func selectionChanged() {
        setAppActive(appIsActive)
        if let id = selectedRoomId, let index = rooms.firstIndex(where: { $0.id == id }), appIsActive {
            rooms[index].unread = false
        }
    }

    var unreadCount: Int { visibleRooms.filter(\.unread).count }

    // MARK: Workspace socket

    private func connectWorkspaceSocket() {
        guard let api else { return }
        workspaceSocket?.close()
        let socket = Socket(
            session: api.session,
            makeRequest: { api.socketRequest("/api/socket") },
            onText: { [weak self] text in self?.handleWorkspace(text) },
            onClose: { [weak self] code in
                if code == EmberCloseCode.revoked {
                    Task { await self?.signOut() }
                    return false
                }
                return true
            })
        socket.onStateChange = { [weak self] state in
            guard let self else { return }
            self.connectionProblem = state == .open ? nil : self.connectionProblem
            // Anything missed while the socket was down comes back with a fresh sidebar.
            if state == .open { Task { await self.reloadSidebar() } }
        }
        workspaceSocket = socket
        socket.connect()
    }

    private func handleWorkspace(_ text: String) {
        guard let frame = try? JSONDecoder().decode(WorkspaceServerFrame.self, from: Data(text.utf8)) else { return }
        switch frame {
        case let .welcome(you):
            me = you
        case let .roomUnread(id):
            guard let index = rooms.firstIndex(where: { $0.id == id }) else { return }
            let onScreen = id == selectedRoomId && appIsActive
            if !onScreen {
                rooms[index].unread = true
                notifyUnread(rooms[index])
            }
        case let .roomRead(id):
            if let index = rooms.firstIndex(where: { $0.id == id }) { rooms[index].unread = false }
        case let .userUpdated(user):
            people[user.id] = user
        case let .roomSaved(room):
            if let index = rooms.firstIndex(where: { $0.id == room.id }) {
                var updated = room
                updated.unread = rooms[index].unread
                updated.involvement = rooms[index].involvement
                rooms[index] = updated
            } else {
                rooms.append(room)
            }
        case let .roomGone(id):
            rooms.removeAll { $0.id == id }
            roomStores.removeValue(forKey: id)?.close()
            if selectedRoomId == id { selectedRoomId = nil }
        case let .roomActive(id, at):
            if let index = rooms.firstIndex(where: { $0.id == id }), (rooms[index].activeAt ?? "") < at {
                rooms[index].activeAt = at
            }
        case let .favoritesChanged(favorites):
            self.favorites = favorites.rooms
        case let .roomInvolvement(id, involvement):
            if let index = rooms.firstIndex(where: { $0.id == id }) { rooms[index].involvement = involvement }
        case .roomsReordered:
            Task { await reloadSidebar() }
        case let .error(message):
            connectionProblem = message
        case .pong, .other:
            break
        }
    }

    /// The workspace socket says only that a room has something unread, not what, so the notification
    /// names the room. Rooms set to "nothing" or hidden stay quiet, as the web app's push does.
    private func notifyUnread(_ room: Room) {
        guard !appIsActive, room.involvement != "nothing", room.involvement != "invisible" else { return }
        let title = room.isDirect ? title(of: room) : "#\(title(of: room))"
        Notifier.shared.post(title: title, body: room.isDirect ? "New direct message" : "New message", roomId: room.id)
    }
}
