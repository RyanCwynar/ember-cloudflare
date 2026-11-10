import SwiftUI

/// The phone's home: rooms, starred first, then the shared order, then DMs, with a room pushed on top
/// when picked. Navigation follows `AppState.selectedRoomId`, so a notification, a search result or a
/// new DM opens its room here too.
struct PhoneWorkspaceView: View {
    @Environment(AppState.self) private var state
    @State private var path: [String] = []

    var body: some View {
        @Bindable var state = state
        NavigationStack(path: $path) {
            List {
                if !state.starredRooms.isEmpty {
                    Section("Starred") { ForEach(state.starredRooms) { PhoneRoomRow(room: $0) } }
                }
                Section("Rooms") { ForEach(state.sortedSharedRooms) { PhoneRoomRow(room: $0) } }
                Section("Direct messages") { ForEach(state.directs) { PhoneRoomRow(room: $0) } }
            }
            .listStyle(.insetGrouped)
            .refreshable { await state.reloadSidebar(); await state.reloadDirectory() }
            .navigationTitle("Ember")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { accountMenu }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { state.sheet = .search } label: { Image(systemName: "magnifyingglass") }
                    Menu {
                        Button { state.sheet = .newDirect } label: { Label("New message", systemImage: "bubble.left") }
                        Button { state.sheet = .newRoom } label: { Label("New room", systemImage: "number") }
                    } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .safeAreaInset(edge: .bottom) { HuddleBar().padding(.bottom, 4) }
            .navigationDestination(for: String.self) { id in
                if let room = state.room(id), let store = state.store(for: id) {
                    PhoneRoomView(room: room, store: store)
                } else {
                    ContentUnavailableView("This room isn't there", systemImage: "questionmark.bubble")
                }
            }
        }
        .onChange(of: path) { _, path in
            if state.selectedRoomId != path.last { state.selectedRoomId = path.last }
        }
        .onChange(of: state.selectedRoomId) { _, id in
            state.selectionChanged()
            if path.last != id { path = id.map { [$0] } ?? [] }
        }
        .onAppear {
            // The shared state picks a first room for the Mac's split view; the phone starts on the list.
            if path.isEmpty { state.selectedRoomId = nil }
        }
        .sheet(item: $state.sheet) { WorkspaceSheet(sheet: $0) }
        .sheet(item: Binding(get: { state.downloadedFile.map(SharedFile.init) }, set: { state.downloadedFile = $0?.url })) { file in
            ShareSheet(items: [file.url])
        }
    }

    private var accountMenu: some View {
        Menu {
            if let me = state.me { Text(me.name) }
            Button { state.sheet = .profile } label: { Label("Your profile", systemImage: "person.crop.circle") }
            Button { state.sheet = .people } label: { Label("People", systemImage: "person.2") }
            Button { state.sheet = .web(path: "/account/edit", title: "Workspace settings") } label: { Label("Workspace settings", systemImage: "gearshape") }
            if state.me?.administrator == true {
                Button { state.sheet = .web(path: "/account/bots", title: "Chat bots") } label: { Label("Chat bots", systemImage: "cpu") }
                Button { state.sheet = .web(path: "/account/agents/new", title: "New agent") } label: { Label("New AI agent", systemImage: "sparkles") }
            }
            Divider()
            Button(role: .destructive) { Task { await state.signOut() } } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
        } label: {
            if let me = state.me { Avatar(userId: me.id, name: me.name, size: 28) } else { Image(systemName: "person.crop.circle") }
        }
    }
}

struct PhoneRoomRow: View {
    @Environment(AppState.self) private var state
    let room: Room

    var body: some View {
        NavigationLink(value: room.id) {
            HStack(spacing: 10) {
                if room.isDirect, let other = room.members?.first(where: { $0.id != state.me?.id }) ?? room.members?.first {
                    Avatar(userId: other.id, name: other.name, size: 28)
                } else {
                    Image(systemName: room.kind == "closed" ? "lock" : "number")
                        .foregroundStyle(.secondary).frame(width: 28)
                }
                Text(state.title(of: room))
                    .fontWeight(room.unread ? .bold : .regular)
                    .lineLimit(1)
                Spacer()
                if let live = state.liveHuddles[room.id], !live.userIds.isEmpty {
                    Image(systemName: "headphones").foregroundStyle(.green)
                }
                if room.involvement == "nothing" {
                    Image(systemName: "bell.slash").font(.caption).foregroundStyle(.tertiary)
                }
                if room.unread { Circle().fill(Brand.accent).frame(width: 9, height: 9) }
            }
        }
        .swipeActions(edge: .leading) {
            Button { Task { await state.toggleStar(room.id) } } label: {
                Label(state.isStarred(room.id) ? "Unstar" : "Star", systemImage: state.isStarred(room.id) ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            let muted = room.involvement == "nothing" || room.involvement == "invisible"
            Button {
                Task { await state.setInvolvement(room.id, muted ? (room.isDirect ? .everything : .mentions) : .nothing) }
            } label: {
                Label(muted ? "Unmute" : "Mute", systemImage: muted ? "bell" : "bell.slash")
            }
            .tint(.indigo)
        }
        .contextMenu { RoomMenu(room: room) }
    }
}

private struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The system share sheet, to save a downloaded file to Files or send it on.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
