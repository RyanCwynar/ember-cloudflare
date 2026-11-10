import Foundation
import Observation

/// One room's timeline, kept by its socket (`/api/rooms/:id/socket`), and the thread open beside it.
///
/// The room numbers its changes (`seq`); on reconnect the store names the latest it saw (`since`) and
/// the room answers with only what changed (`resumed`). Messages sent while the socket was down stay
/// pending and are checked with `message.check` once it's back.
///
/// Replies sent only to a thread reach this socket only while that thread is open (`thread.open`), so
/// the open thread is named again whenever the socket reconnects.
@MainActor
@Observable
final class RoomStore {
    let roomId: String
    private let api: APIClient
    private let myId: String

    private(set) var messages: [Message] = []
    private(set) var pending: [PendingMessage] = []
    private(set) var present: [User] = []
    private(set) var typing: [User] = []
    private(set) var hasMore = false
    /// Whether the timeline shows an older page (after a jump) with newer messages left out.
    private(set) var hasNewer = false
    /// The message a jump landed on, which the timeline scrolls to and marks.
    private(set) var highlightedId: String?
    private var pendingJump: String??
    private(set) var loadingHistory = false
    private(set) var connected = false
    private(set) var gone = false
    var lastError: String?
    var visible = true

    // The open thread.
    private(set) var openThreadId: String?
    private(set) var threadParent: Message?
    private(set) var threadReplies: [Message] = []
    private(set) var threadHasMore = false
    private(set) var threadLoading = false
    private(set) var threadTyping = false

    private var seq: Int?
    private var socket: Socket?
    private var typingTimers: [String: Timer] = [:]
    private var typingSent = false
    private var typingStopTimer: Timer?

    struct PendingMessage: Identifiable, Hashable {
        let id: String  // clientMessageId
        let text: String
        let body: String
        let parentId: String?
        let alsoSend: Bool
        var failed: String?

        var showsInRoom: Bool { parentId == nil || alsoSend }
    }

    init(roomId: String, api: APIClient, myId: String) {
        self.roomId = roomId
        self.api = api
        self.myId = myId
    }

    func connect() {
        let socket = Socket(
            session: api.session,
            makeRequest: { [weak self] in self?.socketRequest() },
            onText: { [weak self] text in self?.handle(text) },
            onClose: { [weak self] code in
                guard code != EmberCloseCode.notFound, code != EmberCloseCode.revoked else {
                    self?.gone = true
                    return false
                }
                return true
            })
        socket.onStateChange = { [weak self] state in
            guard let self else { return }
            self.connected = state == .open
            guard state == .open else { return }
            if !self.pending.isEmpty { self.send(.messageCheck(clientMessageIds: self.pending.map(\.id))) }
            if let thread = self.openThreadId { self.send(.threadOpen(parentId: thread)) }
            if let jump = self.pendingJump { self.pendingJump = nil; self.jump(to: jump) }
        }
        self.socket = socket
        socket.connect()
    }

    func close() {
        socket?.close()
    }

    private func socketRequest() -> URLRequest? {
        var query = "visible=\(visible ? 1 : 0)&protocol=\(roomProtocol)"
        if let seq { query += "&since=\(seq)" }
        return api.socketRequest("/api/rooms/\(roomId)/socket", query: query)
    }

    private func send(_ frame: RoomClientFrame) {
        socket?.send(frame.text)
    }

    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        send(.presenceVisible(visible))
    }

    // MARK: Uploads

    struct UploadItem: Identifiable, Hashable {
        let id: String  // the file message's clientMessageId
        let url: URL
        let parentId: String?
        let alsoSend: Bool
        var progress: Double = 0
        var failed: String?
        var name: String { url.lastPathComponent }
    }

    private(set) var uploads: [UploadItem] = []
    var roomUploads: [UploadItem] { uploads.filter { $0.parentId == nil } }
    var threadUploads: [UploadItem] { uploads.filter { $0.parentId != nil && $0.parentId == openThreadId } }

    /// Uploads files to the room, or with `parentId` to that thread, each as its own file message.
    func upload(_ urls: [URL], parentId: String? = nil, alsoSend: Bool = false) {
        for url in urls {
            let item = UploadItem(id: UUID().uuidString.lowercased(), url: url, parentId: parentId, alsoSend: alsoSend)
            uploads.append(item)
            run(item)
        }
    }

    func retryUpload(_ id: String) {
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
        uploads[index].failed = nil
        uploads[index].progress = 0
        run(uploads[index])
    }

    func discardUpload(_ id: String) {
        uploads.removeAll { $0.id == id }
    }

    private func run(_ item: UploadItem) {
        Task {
            // Files picked in an open panel are security-scoped; dropped and pasted ones aren't.
            let scoped = item.url.startAccessingSecurityScopedResource()
            defer { if scoped { item.url.stopAccessingSecurityScopedResource() } }
            do {
                let message = try await Uploads.upload(
                    item.url, to: roomId, api: api, clientMessageId: item.id, parentId: item.parentId, alsoSend: item.alsoSend,
                    progress: { [weak self] value in
                        if let index = self?.uploads.firstIndex(where: { $0.id == item.id }) { self?.uploads[index].progress = value }
                    })
                apply(message)
                uploads.removeAll { $0.id == item.id }
            } catch {
                if let index = uploads.firstIndex(where: { $0.id == item.id }) { uploads[index].failed = error.localizedDescription }
            }
        }
    }

    var roomPending: [PendingMessage] { pending.filter(\.showsInRoom).filter { $0.parentId == nil } }
    var threadPending: [PendingMessage] { pending.filter { $0.parentId != nil && $0.parentId == openThreadId } }

    // MARK: Actions

    /// Sends what the composer holds, as markup, to the room or, with `parentId`, to that thread.
    func sendMessage(_ text: String, mentions: [ComposerMarkup.Mention] = [], parentId: String? = nil, alsoSend: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = UUID().uuidString.lowercased()
        let body = ComposerMarkup.markup(from: trimmed, mentions: mentions)
        pending.append(PendingMessage(id: id, text: trimmed, body: body, parentId: parentId, alsoSend: alsoSend))
        stopTyping()
        send(.messageCreate(clientMessageId: id, body: body, parentId: parentId, alsoSend: alsoSend))
    }

    func retry(_ pendingId: String) {
        guard let index = pending.firstIndex(where: { $0.id == pendingId }) else { return }
        pending[index].failed = nil
        let p = pending[index]
        send(.messageCreate(clientMessageId: p.id, body: p.body, parentId: p.parentId, alsoSend: p.alsoSend))
    }

    func discard(_ pendingId: String) {
        pending.removeAll { $0.id == pendingId }
    }

    func edit(_ message: Message, to text: String, mentions: [ComposerMarkup.Mention]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(.messageUpdate(messageId: message.id, body: ComposerMarkup.markup(from: trimmed, mentions: mentions)))
    }

    func delete(_ message: Message) {
        send(.messageDelete(messageId: message.id))
    }

    /// Adds `content` as my boost, or takes mine away if I've already boosted with it.
    func toggleBoost(_ content: String, on message: Message) {
        if let mine = message.boosts.first(where: { $0.content == content && $0.booster.id == myId }) {
            send(.boostDelete(boostId: mine.id))
        } else {
            send(.boostCreate(messageId: message.id, content: content))
        }
    }

    /// Shows the page around a message, as its permalink does, or the newest page with nil.
    func jump(to messageId: String?) {
        guard connected else { pendingJump = .some(messageId); return }
        if let messageId, messages.contains(where: { $0.id == messageId }), !hasNewer || messageId != messages.last?.id {
            highlightedId = messageId
            return
        }
        loadingHistory = true
        send(.historyAround(messageId: messageId))
    }

    func loadNewer() {
        guard hasNewer, !loadingHistory, let newest = messages.last else { return }
        loadingHistory = true
        send(.historyAfter(after: newest.id))
    }

    func clearHighlight() { highlightedId = nil }

    func loadEarlier() {
        guard hasMore, !loadingHistory, let oldest = messages.first else { return }
        loadingHistory = true
        send(.historyBefore(before: oldest.id))
    }

    /// Called as the composer changes. Sends typing.start once, and typing.stop after 3 quiet seconds.
    func composerChanged(isEmpty: Bool) {
        if isEmpty { stopTyping(); return }
        if !typingSent {
            typingSent = true
            send(.typingStart)
        }
        typingStopTimer?.invalidate()
        typingStopTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopTyping() }
        }
    }

    private func stopTyping() {
        typingStopTimer?.invalidate()
        guard typingSent else { return }
        typingSent = false
        send(.typingStop)
    }

    func isMine(_ message: Message) -> Bool { message.creator.id == myId }

    // MARK: Threads

    func openThread(_ parentId: String) {
        guard parentId != openThreadId else { return }
        if let old = openThreadId { send(.threadClose(parentId: old)) }
        openThreadId = parentId
        threadParent = messages.first { $0.id == parentId }
        threadReplies = []
        threadHasMore = false
        threadLoading = true
        send(.threadOpen(parentId: parentId))
    }

    func closeThread() {
        guard let id = openThreadId else { return }
        send(.threadClose(parentId: id))
        openThreadId = nil
        threadParent = nil
        threadReplies = []
        threadTyping = false
    }

    func loadEarlierReplies() {
        guard let id = openThreadId, threadHasMore, !threadLoading, let oldest = threadReplies.first else { return }
        threadLoading = true
        send(.threadBefore(parentId: id, before: oldest.id))
    }

    // MARK: Frames

    private func handle(_ text: String) {
        let frame: RoomServerFrame
        do {
            frame = try JSONDecoder().decode(RoomServerFrame.self, from: Data(text.utf8))
        } catch {
            lastError = "Couldn't read a frame from the room: \(error.localizedDescription)"
            return
        }
        switch frame {
        case let .welcome(_, present, seq, messages, hasMore):
            self.messages = messages.filter(\.isInRoom)
            self.present = present
            self.seq = seq
            self.hasMore = hasMore
            hasNewer = false
            reconcilePending(messages)
        case let .resumed(changed, deletedIds, present, seq):
            for message in changed { apply(message) }
            messages.removeAll { deletedIds.contains($0.id) }
            threadReplies.removeAll { deletedIds.contains($0.id) }
            self.present = present
            self.seq = seq
            reconcilePending(changed)
        case let .messageCreated(message, seq):
            self.seq = seq
            clearTyping(message.creator.id)
            apply(message)
            pending.removeAll { $0.id == message.clientMessageId }
            uploads.removeAll { $0.id == message.clientMessageId && $0.progress >= 1 }
        case let .messageUpdated(message, seq):
            self.seq = seq
            apply(message)
        case let .messageDeleted(id, seq):
            self.seq = seq
            messages.removeAll { $0.id == id }
            threadReplies.removeAll { $0.id == id }
            if id == openThreadId { closeThread() }
        case let .boostCreated(boost, seq):
            self.seq = seq
            mutate(boost.messageId) { message in
                if !message.boosts.contains(where: { $0.id == boost.id }) { message.boosts.append(boost) }
            }
        case let .boostDeleted(boostId, messageId, seq):
            self.seq = seq
            mutate(messageId) { $0.boosts.removeAll { $0.id == boostId } }
        case let .presenceJoined(user):
            if !present.contains(where: { $0.id == user.id }) { present.append(user) }
        case let .presenceLeft(userId):
            present.removeAll { $0.id == userId }
            clearTyping(userId)
        case let .typing(user, isTyping, threadId):
            guard user.id != myId else { return }
            if let threadId {
                // Only @ember types in threads, as it answers there.
                if threadId == openThreadId { threadTyping = isTyping }
                return
            }
            if isTyping { startTyping(user) } else { clearTyping(user.id) }
        case let .history(_, older, hasMore):
            let known = Set(messages.map(\.id))
            messages = older.filter { $0.isInRoom && !known.contains($0.id) } + messages
            self.hasMore = hasMore
            loadingHistory = false
        case let .historyAfter(_, newer, hasNewer):
            let known = Set(messages.map(\.id))
            messages += newer.filter { $0.isInRoom && !known.contains($0.id) }
            self.hasNewer = hasNewer
            loadingHistory = false
        case let .historyAround(page, hasMore, hasNewer, around):
            messages = page.filter(\.isInRoom)
            self.hasMore = hasMore
            self.hasNewer = hasNewer
            highlightedId = around
            loadingHistory = false
        case let .threadOpened(parentId, parent, replies, hasMore):
            guard parentId == openThreadId else { return }
            threadParent = parent ?? threadParent
            threadReplies = replies
            threadHasMore = hasMore
            threadLoading = false
            reconcilePending(replies)
        case let .threadHistory(parentId, _, older, hasMore):
            guard parentId == openThreadId else { return }
            let known = Set(threadReplies.map(\.id))
            threadReplies = older.filter { !known.contains($0.id) } + threadReplies
            threadHasMore = hasMore
            threadLoading = false
        case let .messageChecked(stored, missing):
            pending.removeAll { stored.contains($0.id) }
            for id in missing { retry(id) }
        case let .error(message, clientMessageId):
            if let clientMessageId, let index = pending.firstIndex(where: { $0.id == clientMessageId }) {
                pending[index].failed = message
            } else {
                lastError = message
            }
            loadingHistory = false
            threadLoading = false
        case .pong, .other:
            break
        }
    }

    /// Puts a new or changed message everywhere it shows: the room's timeline (unless it's a reply sent
    /// only to its thread), the open thread's replies, and the thread's parent.
    private func apply(_ message: Message) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            if message.isInRoom { messages[index] = message } else { messages.remove(at: index) }
        } else if message.isInRoom, !(hasNewer && message.createdDate > (messages.last?.createdDate ?? .distantFuture)) {
            // While an older page shows, newer messages wait for Load newer rather than land after a gap.
            let index = messages.lastIndex { $0.createdDate <= message.createdDate }.map { $0 + 1 } ?? 0
            messages.insert(message, at: index)
        }
        if message.id == openThreadId { threadParent = message }
        if let parentId = message.parentId, parentId == openThreadId {
            if let index = threadReplies.firstIndex(where: { $0.id == message.id }) {
                threadReplies[index] = message
            } else {
                let index = threadReplies.lastIndex { $0.createdDate <= message.createdDate }.map { $0 + 1 } ?? 0
                threadReplies.insert(message, at: index)
            }
        }
    }

    private func mutate(_ id: String, _ change: (inout Message) -> Void) {
        if let i = messages.firstIndex(where: { $0.id == id }) { change(&messages[i]) }
        if let i = threadReplies.firstIndex(where: { $0.id == id }) { change(&threadReplies[i]) }
        if threadParent?.id == id, var parent = threadParent { change(&parent); threadParent = parent }
    }

    private func reconcilePending(_ arrived: [Message]) {
        let stored = Set(arrived.map(\.clientMessageId)).union(messages.map(\.clientMessageId))
        pending.removeAll { stored.contains($0.id) }
    }

    private func startTyping(_ user: User) {
        if !typing.contains(where: { $0.id == user.id }) { typing.append(user) }
        // A typist who goes quiet without a stop (a closed laptop) drops off after 10 seconds.
        typingTimers[user.id]?.invalidate()
        typingTimers[user.id] = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.clearTyping(user.id) }
        }
    }

    private func clearTyping(_ userId: String) {
        typingTimers.removeValue(forKey: userId)?.invalidate()
        typing.removeAll { $0.id == userId }
    }
}
