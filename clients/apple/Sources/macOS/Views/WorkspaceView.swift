import SwiftUI

struct WorkspaceView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            List(selection: $state.selectedRoomId) {
                if !state.starredRooms.isEmpty {
                    Section("Starred") { ForEach(state.starredRooms) { RoomRow(room: $0) } }
                }
                Section {
                    ForEach(state.sortedSharedRooms) { RoomRow(room: $0) }
                } header: {
                    SectionHeader(title: "Rooms", help: "New room") { state.sheet = .newRoom }
                }
                Section {
                    ForEach(state.directs) { RoomRow(room: $0) }
                } header: {
                    SectionHeader(title: "Direct messages", help: "New message") { state.sheet = .newDirect }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    HuddleBar()
                    accountBar
                }
            }
        } detail: {
            if let id = state.selectedRoomId, let room = state.room(id), let store = state.store(for: id) {
                RoomView(room: room, store: store)
                    .id(id)
            } else {
                VStack(spacing: 12) {
                    EmberLogo(size: 72).opacity(0.85)
                    Text("Pick a room").font(.title3).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: state.selectedRoomId) { _, _ in state.selectionChanged() }
        .sheet(item: $state.sheet) { WorkspaceSheet(sheet: $0) }
        .background {
            // Option-Up/Down moves between rooms; with Shift, between unread ones.
            Group {
                Button("") { state.selectNeighbor(down: false, unreadOnly: false) }.keyboardShortcut(.upArrow, modifiers: .option)
                Button("") { state.selectNeighbor(down: true, unreadOnly: false) }.keyboardShortcut(.downArrow, modifiers: .option)
                Button("") { state.selectNeighbor(down: false, unreadOnly: true) }.keyboardShortcut(.upArrow, modifiers: [.option, .shift])
                Button("") { state.selectNeighbor(down: true, unreadOnly: true) }.keyboardShortcut(.downArrow, modifiers: [.option, .shift])
            }
            .hidden()
        }
    }

    @ViewBuilder
    private var accountBar: some View {
        if let me = state.me {
            HStack(spacing: 8) {
                Button { state.sheet = .profile } label: {
                    HStack(spacing: 8) {
                        Avatar(userId: me.id, name: me.name, size: 24)
                        Text(me.name).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button { state.sheet = .search } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Search (⌘F)")
                Button { state.sheet = .people } label: { Image(systemName: "person.2") }
                    .buttonStyle(.borderless).help("People")
                Menu {
                    Button("Your Profile…") { state.sheet = .profile }
                    Button("People…") { state.sheet = .people }
                    Button("Search…") { state.sheet = .search }
                    Divider()
                    Button("Workspace Settings…") { state.sheet = .web(path: "/account/edit", title: "Workspace settings") }
                    if me.administrator {
                        Button("Custom Styles…") { state.sheet = .web(path: "/account/custom_styles/edit", title: "Custom styles") }
                        Button("Chat Bots…") { state.sheet = .web(path: "/account/bots", title: "Chat bots") }
                        Button("New AI Agent…") { state.sheet = .web(path: "/account/agents/new", title: "New agent") }
                    }
                    Divider()
                    Button("Reload") { Task { await state.reloadSidebar(); await state.reloadDirectory() } }
                    Button("Sign Out") { Task { await state.signOut() } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(10)
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: action) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help(help)
        }
    }
}

struct RoomRow: View {
    @Environment(AppState.self) private var state
    let room: Room

    var body: some View {
        HStack(spacing: 6) {
            if room.isDirect, let other = room.members?.first(where: { $0.id != state.me?.id }) ?? room.members?.first {
                Avatar(userId: other.id, name: other.name, size: 18)
            } else {
                Image(systemName: room.kind == "closed" ? "lock" : "number")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            Text(state.title(of: room))
                .fontWeight(room.unread ? .bold : .regular)
                .lineLimit(1)
            Spacer()
            if let live = state.liveHuddles[room.id], !live.userIds.isEmpty {
                Image(systemName: "headphones").font(.caption).foregroundStyle(.green).help("\(live.userIds.count) in a huddle")
            }
            if room.involvement == "nothing" {
                Image(systemName: "bell.slash").font(.caption).foregroundStyle(.tertiary)
            }
            if room.unread {
                Circle().fill(Brand.accent).frame(width: 7, height: 7)
            }
        }
        .tag(room.id)
        .contextMenu { RoomMenu(room: room) }
    }
}

