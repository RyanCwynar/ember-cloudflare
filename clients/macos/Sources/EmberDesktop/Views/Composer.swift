import SwiftUI

/// What the composer holds: text with light Markdown, and the people its @mentions name.
struct Draft: Equatable {
    var text = ""
    var mentions: [ComposerMarkup.Mention] = []

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The mentions still in the text, since deleting "@Name" by hand should drop it.
    var liveMentions: [ComposerMarkup.Mention] { mentions.filter { text.contains("@\($0.name)") } }
}

/// The message composer for a room or a thread. Return sends; Shift- or Option-Return adds a line.
/// Typing "@" and a few letters offers people to mention, picked with the arrows and Return or Tab.
struct Composer: View {
    @Environment(AppState.self) private var state
    @Binding var draft: Draft
    let placeholder: String
    var disabled = false
    var onChange: (String) -> Void = { _ in }
    let onSend: () -> Void

    @FocusState private var focused: Bool
    @State private var highlighted = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !suggestions.isEmpty { suggestionList }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $draft.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .focused($focused)
                    .disabled(disabled)
                    .onKeyPress(.return, phases: .down) { press in
                        if !suggestions.isEmpty { pick(suggestions[min(highlighted, suggestions.count - 1)]); return .handled }
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                        send()
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        guard !suggestions.isEmpty else { return .ignored }
                        pick(suggestions[min(highlighted, suggestions.count - 1)])
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !suggestions.isEmpty else { return .ignored }
                        highlighted = max(0, highlighted - 1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !suggestions.isEmpty else { return .ignored }
                        highlighted = min(suggestions.count - 1, highlighted + 1)
                        return .handled
                    }
                    .onChange(of: draft.text) { _, text in
                        highlighted = 0
                        onChange(text)
                    }
                Button(action: send) { Image(systemName: "paperplane.fill") }
                    .buttonStyle(.borderless)
                    .disabled(draft.isBlank || disabled)
                    .help("Send (Return)")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? Brand.accent.opacity(0.6) : Color.secondary.opacity(0.3)))
        }
        .onAppear { focused = true }
    }

    private func send() {
        guard !draft.isBlank else { return }
        onSend()
    }

    // MARK: Mentions

    /// The "@query" being typed at the end of the text, if any.
    private var mentionQuery: String? {
        guard let at = draft.text.lastIndex(of: "@") else { return nil }
        if at > draft.text.startIndex {
            let before = draft.text[draft.text.index(before: at)]
            guard before.isWhitespace || before.isPunctuation else { return nil }
        }
        let query = draft.text[draft.text.index(after: at)...]
        guard query.count <= 30, !query.contains("\n"), query.split(separator: " ").count <= 2 else { return nil }
        return String(query)
    }

    private var suggestions: [DirectoryUser] {
        guard let query = mentionQuery else { return [] }
        let q = query.lowercased()
        return state.mentionable
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
            .sorted { a, b in
                let ap = a.name.lowercased().hasPrefix(q), bp = b.name.lowercased().hasPrefix(q)
                return ap != bp ? ap : a.name < b.name
            }
            .prefix(6)
            .map { $0 }
    }

    private func pick(_ person: DirectoryUser) {
        guard let at = draft.text.lastIndex(of: "@") else { return }
        draft.text = String(draft.text[..<at]) + "@\(person.name) "
        if !draft.mentions.contains(where: { $0.id == person.id }) {
            draft.mentions.append(ComposerMarkup.Mention(id: person.id, name: person.name))
        }
        highlighted = 0
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, person in
                Button { pick(person) } label: {
                    HStack(spacing: 8) {
                        Avatar(userId: person.id, name: person.name, size: 20)
                        Text(person.name)
                        if person.agent == true {
                            Text("Agent").font(.caption2.bold()).padding(.horizontal, 4)
                                .background(Capsule().fill(Color.secondary.opacity(0.2)))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(index == highlighted ? Brand.accent.opacity(0.18) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)).shadow(radius: 2))
        .frame(maxWidth: 320)
    }
}
