import SwiftUI

struct RoomView: View {
    @Environment(AppState.self) private var state
    let room: Room
    let store: RoomStore

    @State private var draft = Draft()
    @State private var editing: Message?
    @State private var dropTargeted = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                timeline
                Divider()
                composer
            }
            .frame(minWidth: 380)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty, !store.gone else { return false }
                store.upload(files)
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10).stroke(Brand.accent, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .background(Brand.accent.opacity(0.06))
                        .overlay(Text("Drop to upload to \(room.isDirect ? state.title(of: room) : "#" + state.title(of: room))").font(.title3.bold()))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            if store.openThreadId != nil {
                ThreadPanel(store: store)
            }
        }
        .navigationTitle(room.isDirect ? state.title(of: room) : "#\(state.title(of: room))")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await state.toggleStar(room.id) } } label: {
                    Image(systemName: state.isStarred(room.id) ? "star.fill" : "star")
                        .foregroundStyle(state.isStarred(room.id) ? Brand.accent : .secondary)
                }
                .help(state.isStarred(room.id) ? "Unstar" : "Star")
                Menu {
                    ForEach(Involvement.allCases) { level in
                        Button { Task { await state.setInvolvement(room.id, level) } } label: {
                            if currentInvolvement == level { Label(level.label, systemImage: "checkmark") } else { Text(level.label) }
                        }
                    }
                } label: {
                    Image(systemName: currentInvolvement.symbol)
                }
                .help("Notifications: \(currentInvolvement.label)")
                Button { state.sheet = .roomSettings(room.id) } label: { Image(systemName: room.isDirect ? "info.circle" : "gearshape") }
                    .help(room.isDirect ? "Details" : "Room settings")
            }
        }
        .alert("Something went wrong", isPresented: .constant(store.lastError != nil)) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var currentInvolvement: Involvement {
        Involvement(rawValue: state.room(room.id)?.involvement ?? "") ?? (room.isDirect ? .everything : .mentions)
    }

    private var subtitle: String {
        if store.gone { return "You're no longer in this room" }
        if !store.connected { return "Connecting…" }
        return store.present.isEmpty ? "" : "\(store.present.count) here"
    }

    // MARK: Timeline

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.hasMore {
                        Button(store.loadingHistory ? "Loading…" : "Load earlier messages") { store.loadEarlier() }
                            .buttonStyle(.link)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
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
                    }
                    ForEach(store.roomPending) { pending in
                        PendingRow(pending: pending, onRetry: { store.retry(pending.id) }, onDiscard: { store.discard(pending.id) })
                    }
                    ForEach(store.roomUploads) { upload in
                        UploadRow(upload: upload, onRetry: { store.retryUpload(upload.id) }, onDiscard: { store.discardUpload(upload.id) })
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.messages.last?.id) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: store.roomPending.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// A message by the same person within five minutes of the last one skips its name and avatar.
    private func continues(_ index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = store.messages[index - 1], message = store.messages[index]
        return previous.creator.id == message.creator.id
            && message.createdDate.timeIntervalSince(previous.createdDate) < 300
            && message.parentId == nil
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !store.typing.isEmpty {
                Text(typingText).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            if editing != nil {
                HStack {
                    Text("Editing message").font(.caption.bold())
                    Spacer()
                    Button("Cancel") { editing = nil; draft = Draft() }.buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, 4)
            }
            Composer(draft: $draft, placeholder: placeholder, disabled: store.gone,
                     onChange: { text in if editing == nil { store.composerChanged(isEmpty: text.isEmpty) } },
                     onAttach: editing == nil ? { store.upload($0) } : nil,
                     onSend: submit)
                .id(editing?.id ?? "new")
        }
        .padding(12)
    }

    private var placeholder: String {
        room.isDirect ? "Message \(state.title(of: room))" : "Message #\(state.title(of: room))"
    }

    private var typingText: String {
        let names = store.typing.map(\.name)
        switch names.count {
        case 1: return "\(names[0]) is typing…"
        case 2: return "\(names[0]) and \(names[1]) are typing…"
        default: return "Several people are typing…"
        }
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
