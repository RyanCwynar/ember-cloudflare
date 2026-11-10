import SwiftUI

/// A message's thread, beside the room: the message, its replies, and a composer that can also send
/// the reply to the room.
struct ThreadPanel: View {
    @Environment(AppState.self) private var state
    let store: RoomStore

    @State private var draft = Draft()
    @State private var alsoSend = false
    @State private var editing: Message?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Thread").font(.headline)
                Spacer()
                Button { store.closeThread() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("Close thread (Esc)")
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let parent = store.threadParent {
                            row(parent, continued: false)
                            HStack {
                                Text(replyCount).font(.caption).foregroundStyle(.secondary)
                                VStack { Divider() }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 6)
                        }
                        if store.threadHasMore {
                            Button(store.threadLoading ? "Loading…" : "Load earlier replies") { store.loadEarlierReplies() }
                                .buttonStyle(.link).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        ForEach(Array(store.threadReplies.enumerated()), id: \.element.id) { index, reply in
                            row(reply, continued: index > 0 && store.threadReplies[index - 1].creator.id == reply.creator.id
                                && reply.createdDate.timeIntervalSince(store.threadReplies[index - 1].createdDate) < 300)
                        }
                        ForEach(store.threadPending) { pending in
                            PendingRow(pending: pending, onRetry: { store.retry(pending.id) }, onDiscard: { store.discard(pending.id) })
                        }
                        if store.threadTyping {
                            Text("Ember is answering…").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: store.threadReplies.last?.id) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: store.threadPending.count) { _, _ in proxy.scrollTo("bottom") }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if editing != nil {
                    HStack {
                        Text("Editing reply").font(.caption.bold())
                        Spacer()
                        Button("Cancel") { editing = nil; draft = Draft() }.buttonStyle(.link).font(.caption)
                    }
                }
                Composer(draft: $draft, placeholder: "Reply…", disabled: store.gone, onSend: submit)
                if editing == nil {
                    Toggle("Also send to the room", isOn: $alsoSend).toggleStyle(.checkbox).font(.caption)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 300, idealWidth: 380)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private var replyCount: String {
        let n = max(store.threadReplies.count, store.threadParent?.thread?.count ?? 0)
        return n == 1 ? "1 reply" : "\(n) replies"
    }

    private func row(_ message: Message, continued: Bool) -> some View {
        MessageRow(
            message: message,
            continued: continued,
            isMine: store.isMine(message),
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
