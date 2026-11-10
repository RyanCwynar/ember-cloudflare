import SwiftUI

/// The message composer for a room or a thread. Return sends; Shift- or Option-Return adds a line.
/// Typing "@" and a few letters offers people to mention, picked with the arrows and Return or Tab.
struct Composer: View {
    @Environment(AppState.self) private var state
    @Binding var draft: Draft
    let placeholder: String
    var disabled = false
    var onChange: (String) -> Void = { _ in }
    /// Takes files picked, pasted or dropped on the composer; nil hides the paperclip.
    var onAttach: (([URL]) -> Void)?
    let onSend: () -> Void

    @FocusState private var focused: Bool
    @State private var highlighted = 0
    @State private var choosingFiles = false
    @State private var pasteMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !suggestions.isEmpty { suggestionList }
            HStack(alignment: .bottom, spacing: 8) {
                if onAttach != nil {
                    Button { choosingFiles = true } label: { Image(systemName: "paperclip") }
                        .buttonStyle(.borderless)
                        .disabled(disabled)
                        .help("Attach files")
                }
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
        .onAppear { focused = true; watchPaste() }
        .onDisappear { if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) } }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result, !urls.isEmpty { onAttach?(urls) }
        }
    }

    /// ⌘V with a picture or files on the pasteboard, and no text, attaches them; text pastes as usual.
    private func watchPaste() {
        guard onAttach != nil, pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard focused, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v" else { return event }
            let board = NSPasteboard.general
            if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
                onAttach?(files)
                return nil
            }
            if board.string(forType: .string) == nil, let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]), let file = Uploads.temporaryFile(png) {
                onAttach?([file])
                return nil
            }
            return event
        }
    }

    private func send() {
        guard !draft.isBlank else { return }
        onSend()
    }

    // MARK: Mentions

    private var suggestions: [DirectoryUser] { MentionSuggestions.people(for: draft.text, from: state.mentionable) }

    private func pick(_ person: DirectoryUser) {
        draft.pick(person)
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
