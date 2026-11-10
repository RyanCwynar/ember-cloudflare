import PhotosUI
import SwiftUI

/// A room on the phone: its timeline, a composer that takes photos and files, and its thread in a sheet.
struct PhoneRoomView: View {
    @Environment(AppState.self) private var state
    let room: Room
    let store: RoomStore

    @State private var draft = Draft()
    @State private var editing: Message?

    var body: some View {
        VStack(spacing: 0) {
            timeline
            PhoneComposer(
                draft: $draft,
                placeholder: room.isDirect ? "Message \(state.title(of: room))" : "Message #\(state.title(of: room))",
                editing: editing != nil,
                typing: typingText,
                disabled: store.gone,
                onChange: { text in if editing == nil { store.composerChanged(isEmpty: text.isEmpty) } },
                onAttach: { store.upload($0) },
                onCancelEdit: { editing = nil; draft = Draft() },
                onSend: submit)
        }
        .navigationTitle(room.isDirect ? state.title(of: room) : "#\(state.title(of: room))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if state.huddlesEnabled || state.liveHuddles[room.id] != nil || state.huddle.roomId == room.id {
                    HuddleButton(room: room)
                }
                Menu {
                    RoomMenu(room: room)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: Binding(get: { store.openThreadId != nil }, set: { if !$0 { store.closeThread() } })) {
            PhoneThreadView(store: store).environment(state)
        }
        .alert("Something went wrong", isPresented: .constant(store.lastError != nil)) {
            Button("OK") { store.lastError = nil }
        } message: { Text(store.lastError ?? "") }
    }

    private var typingText: String? {
        let names = store.typing.map(\.name)
        switch names.count {
        case 0: return nil
        case 1: return "\(names[0]) is typing…"
        case 2: return "\(names[0]) and \(names[1]) are typing…"
        default: return "Several people are typing…"
        }
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.hasMore {
                        Button(store.loadingHistory ? "Loading…" : "Load earlier messages") { store.loadEarlier() }
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .onAppear { store.loadEarlier() }
                    }
                    ForEach(Array(store.messages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(
                            message: message,
                            continued: continues(index),
                            isMine: store.isMine(message),
                            onBoost: { store.toggleBoost($0, on: message) },
                            onReply: { store.openThread(message.parentId ?? message.id) },
                            onEdit: { startEditing(message) },
                            onDelete: { store.delete(message) })
                        .background(store.highlightedId == message.id ? Brand.accent.opacity(0.14) : .clear)
                    }
                    ForEach(store.roomPending) { pending in
                        PendingRow(pending: pending, onRetry: { store.retry(pending.id) }, onDiscard: { store.discard(pending.id) })
                    }
                    ForEach(store.roomUploads) { upload in
                        UploadRow(upload: upload, onRetry: { store.retryUpload(upload.id) }, onDiscard: { store.discardUpload(upload.id) })
                    }
                    if store.hasNewer {
                        Button(store.loadingHistory ? "Loading…" : "Load newer messages") { store.loadNewer() }
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .onAppear { store.loadNewer() }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.last?.id) { _, _ in
                guard !store.hasNewer, store.highlightedId == nil else { return }
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.roomPending.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.highlightedId) { _, id in
                guard let id else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if store.highlightedId == id { withAnimation { store.clearHighlight() } } }
            }
            .overlay(alignment: .bottomTrailing) {
                if store.hasNewer {
                    Button { store.jump(to: nil) } label: { Label("Newest", systemImage: "arrow.down") }
                        .buttonStyle(.borderedProminent).padding(12)
                }
            }
            .overlay(alignment: .top) {
                if !store.connected && !store.gone {
                    Text("Connecting…").font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(.thinMaterial)).padding(.top, 6)
                }
            }
        }
    }

    private func continues(_ index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = store.messages[index - 1], message = store.messages[index]
        return previous.creator.id == message.creator.id
            && message.createdDate.timeIntervalSince(previous.createdDate) < 300
            && message.parentId == nil
    }

    private func startEditing(_ message: Message) {
        let (text, mentions) = ComposerMarkup.editableText(from: message.body) { state.name(of: $0) }
        editing = message
        draft = Draft(text: text, mentions: mentions)
    }

    private func submit() {
        if let editing {
            store.edit(editing, to: draft.text, mentions: draft.liveMentions)
            self.editing = nil
        } else {
            store.sendMessage(draft.text, mentions: draft.liveMentions)
        }
        draft = Draft()
    }
}

/// A thread in a sheet: the message, its replies, and a reply composer.
struct PhoneThreadView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let store: RoomStore

    @State private var draft = Draft()
    @State private var alsoSend = false
    @State private var editing: Message?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if let parent = store.threadParent {
                                row(parent)
                                Divider().padding(.vertical, 6)
                            }
                            if store.threadHasMore {
                                Button(store.threadLoading ? "Loading…" : "Load earlier replies") { store.loadEarlierReplies() }
                                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                            }
                            ForEach(store.threadReplies) { row($0) }
                            ForEach(store.threadPending) { pending in
                                PendingRow(pending: pending, onRetry: { store.retry(pending.id) }, onDiscard: { store.discard(pending.id) })
                            }
                            ForEach(store.threadUploads) { upload in
                                UploadRow(upload: upload, onRetry: { store.retryUpload(upload.id) }, onDiscard: { store.discardUpload(upload.id) })
                            }
                            if store.threadTyping {
                                Text("Ember is answering…").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.vertical, 8)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: store.threadReplies.last?.id) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
                }
                if editing == nil {
                    Toggle("Also send to the room", isOn: $alsoSend).font(.footnote).padding(.horizontal, 16).padding(.top, 6)
                }
                PhoneComposer(
                    draft: $draft, placeholder: "Reply…", editing: editing != nil, typing: nil, disabled: store.gone,
                    onAttach: { urls in if let parent = store.openThreadId { store.upload(urls, parentId: parent, alsoSend: alsoSend) } },
                    onCancelEdit: { editing = nil; draft = Draft() },
                    onSend: submit)
            }
            .navigationTitle("Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDragIndicator(.visible)
    }

    private func row(_ message: Message) -> some View {
        MessageRow(
            message: message, continued: false, isMine: store.isMine(message),
            onBoost: { store.toggleBoost($0, on: message) },
            onReply: nil,
            onEdit: {
                editing = message
                let (text, mentions) = ComposerMarkup.editableText(from: message.body) { state.name(of: $0) }
                draft = Draft(text: text, mentions: mentions)
            },
            onDelete: { store.delete(message) })
    }

    private func submit() {
        if let editing {
            store.edit(editing, to: draft.text, mentions: draft.liveMentions)
            self.editing = nil
        } else if let parent = store.openThreadId {
            store.sendMessage(draft.text, mentions: draft.liveMentions, parentId: parent, alsoSend: alsoSend)
        }
        draft = Draft()
    }
}

/// The phone's composer: text with @mention suggestions above it, a + menu for photos and files, and Send.
struct PhoneComposer: View {
    @Environment(AppState.self) private var state
    @Binding var draft: Draft
    let placeholder: String
    var editing = false
    var typing: String?
    var disabled = false
    var onChange: (String) -> Void = { _ in }
    let onAttach: ([URL]) -> Void
    var onCancelEdit: () -> Void = {}
    let onSend: () -> Void

    @State private var choosingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var choosingFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let suggestions = MentionSuggestions.people(for: draft.text, from: state.mentionable)
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions) { person in
                            Button { draft.pick(person) } label: {
                                HStack(spacing: 6) { Avatar(userId: person.id, name: person.name, size: 22); Text(person.name) }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            if let typing { Text(typing).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
            if editing {
                HStack {
                    Text("Editing message").font(.caption.bold())
                    Spacer()
                    Button("Cancel", action: onCancelEdit).font(.caption)
                }
                .padding(.horizontal, 16)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if !editing {
                    Menu {
                        Button { choosingPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                        Button { choosingFiles = true } label: { Label("Files", systemImage: "folder") }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.secondary)
                    }
                    .disabled(disabled)
                }
                TextField(placeholder, text: $draft.text, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: .secondarySystemBackground)))
                    .disabled(disabled)
                    .onChange(of: draft.text) { _, text in onChange(text) }
                Button(action: { if !draft.isBlank { onSend() } }) {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(draft.isBlank || disabled)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.bar)
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task { onAttach(await files(from: items)) }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result, !urls.isEmpty { onAttach(urls) }
        }
    }

    /// The photos picked, written to temporary files under names that keep their type.
    private func files(from items: [PhotosPickerItem]) async -> [URL] {
        var urls: [URL] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
            if let url = Uploads.temporaryFile(data, name: "Photo \(stamp)\(items.count > 1 ? " \(index + 1)" : "").\(ext)") {
                urls.append(url)
            }
        }
        return urls
    }
}
