import SwiftUI

/// Search: words and filters (in a room, from someone, with me, has a link, has a file, in a thread),
/// newest or oldest first, with recent searches while the box is empty. Picking a match opens its
/// room at it.
struct SearchSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var search = Search()
    @State private var sort = "newest"
    @State private var results: SearchResults?
    @State private var matches: [SearchMatch] = []
    @State private var next: Int?
    @State private var recent: [Search] = []
    @State private var error: String?
    @State private var working = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search messages", text: $search.q)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { run(recording: true) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            filters
            Divider()
            content
        }
        .padding(16)
        .sheetFrame(width: 640, height: 600)
        .onAppear { fieldFocused = true }
        .task {
            // An empty search answers only the recent ones.
            if let answer = try? await state.api?.search(Search()) { recent = answer.recent }
        }
        .onChange(of: filterKey) { _, _ in if search.isSearchable { run(recording: false) } }
    }

    private var filterKey: String { "\(search.in ?? "")|\(search.from ?? "")|\(flag(search.withMe))\(flag(search.hasLink))\(flag(search.hasFile))\(flag(search.inThread))|\(sort)" }
    private func flag(_ value: Bool?) -> String { value == true ? "1" : "0" }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker("In", selection: $search.in) {
                Text("Anywhere").tag(String?.none)
                ForEach(state.starredRooms + state.sortedSharedRooms + state.directs) { room in
                    Text(room.isDirect ? state.title(of: room) : "#\(state.title(of: room))").tag(String?.some(room.id))
                }
            }
            .frame(maxWidth: 170)
            Picker("From", selection: $search.from) {
                Text("Anyone").tag(String?.none)
                ForEach(state.directory) { Text($0.name).tag(String?.some($0.id)) }
            }
            .frame(maxWidth: 170)
            Menu("More") {
                Toggle("Mentions me", isOn: toggle(\.withMe))
                Toggle("Has a link", isOn: toggle(\.hasLink))
                Toggle("Has a file", isOn: toggle(\.hasFile))
                Toggle("In a thread", isOn: toggle(\.inThread))
            }
            .fixedSize()
            Spacer()
            Picker("", selection: $sort) {
                Text("Newest").tag("newest")
                Text("Oldest").tag("oldest")
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .labelsHidden()
        .controlSize(.small)
    }

    private func toggle(_ key: WritableKeyPath<Search, Bool?>) -> Binding<Bool> {
        Binding(get: { search[keyPath: key] == true }, set: { search[keyPath: key] = $0 ? true : nil })
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            Text(error).foregroundStyle(.red)
            Spacer()
        } else if results == nil {
            recentList
        } else if matches.isEmpty && !working {
            Text("Nothing matches.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(matches, id: \.message.id) { match in
                    Button { open(match.message) } label: { MatchRow(match: match, roomName: roomName(match.message.roomId)) }
                        .buttonStyle(.plain)
                }
                if let next {
                    Button(working ? "Loading…" : "More results") { more(next) }
                        .linkButton().frame(maxWidth: .infinity)
                        .onAppear { more(next) }
                }
            }
            .listStyle(.plain)
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if recent.isEmpty {
                Text("Search every message in your rooms and DMs.").foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Recent searches").font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { Task { try? await state.api?.clearRecentSearches(); recent = [] } }
                        .linkButton().font(.caption)
                }
                ForEach(recent, id: \.self) { past in
                    Button { search = past; run(recording: true) } label: {
                        Label(describe(past), systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
    }

    private func describe(_ s: Search) -> String {
        var parts: [String] = []
        if !s.q.isEmpty { parts.append(s.q) }
        if let room = s.in { parts.append("in \(roomName(room))") }
        if let from = s.from { parts.append("from \(state.name(of: from) ?? "someone")") }
        if s.withMe == true { parts.append("mentioning me") }
        if s.hasLink == true { parts.append("with a link") }
        if s.hasFile == true { parts.append("with a file") }
        if s.inThread == true { parts.append("in threads") }
        return parts.joined(separator: " ")
    }

    private func roomName(_ id: String) -> String {
        if let room = state.room(id) ?? results?.rooms.first(where: { $0.id == id }) {
            return room.isDirect ? state.title(of: room) : "#\(state.title(of: room))"
        }
        return "a room"
    }

    private func run(recording: Bool) {
        guard search.isSearchable, let api = state.api else { return }
        working = true
        error = nil
        let current = search, order = sort
        Task {
            defer { working = false }
            do {
                let answer = recording ? try await api.recordSearch(current, sort: order) : try await api.search(current, sort: order)
                guard current == search, order == sort else { return }
                results = answer
                matches = answer.matches
                next = answer.next
                recent = answer.recent
            } catch { self.error = error.localizedDescription }
        }
    }

    private func more(_ cursor: Int) {
        guard !working, let api = state.api else { return }
        working = true
        Task {
            defer { working = false }
            if let answer = try? await api.search(search, sort: sort, cursor: cursor) {
                let known = Set(matches.map(\.message.id))
                matches += answer.matches.filter { !known.contains($0.message.id) }
                next = answer.next
            }
        }
    }

    private func open(_ message: Message) {
        dismiss()
        state.open(roomId: message.roomId, messageId: message.parentId == nil ? message.id : nil, threadParentId: message.parentId)
    }
}

private struct MatchRow: View {
    @Environment(AppState.self) private var state
    let match: SearchMatch
    let roomName: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(userId: match.message.creator.id, name: match.message.creator.name, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(match.message.creator.name).fontWeight(.semibold)
                    Text(roomName).font(.caption).foregroundStyle(.secondary)
                    if match.message.parentId != nil { Badge("Thread") }
                    Spacer()
                    Text(match.message.createdDate, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(marked).lineLimit(3)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The message's text with the matched words marked, as the web app's search marks them.
    private var marked: AttributedString {
        let text = match.message.attachment.map { "📎 \($0.name)" } ?? match.message.plainText
        var shown = AttributedString(text)
        let lower = text.lowercased()
        for word in match.words where !word.isEmpty {
            var from = lower.startIndex
            while let range = lower.range(of: word.lowercased(), range: from..<lower.endIndex) {
                if let a = AttributedString.Index(range.lowerBound, within: shown), let b = AttributedString.Index(range.upperBound, within: shown) {
                    shown[a..<b].backgroundColor = Brand.accent.opacity(0.3)
                    shown[a..<b].font = .body.bold()
                }
                from = range.upperBound
            }
        }
        return shown
    }
}
