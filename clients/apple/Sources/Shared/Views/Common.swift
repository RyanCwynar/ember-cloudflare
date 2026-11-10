import SwiftUI

/// What a room offers in its right-click menu and its header: star, notifications, settings, leave.
struct RoomMenu: View {
    @Environment(AppState.self) private var state
    let room: Room

    var body: some View {
        Button(state.isStarred(room.id) ? "Unstar" : "Star") { Task { await state.toggleStar(room.id) } }
        Menu("Notifications") {
            ForEach(Involvement.allCases) { level in
                Button { Task { await state.setInvolvement(room.id, level) } } label: {
                    if room.involvement == level.rawValue { Label(level.label, systemImage: "checkmark") } else { Text(level.label) }
                }
            }
        }
        Divider()
        Button(room.isDirect ? "Details…" : "Settings…") { state.sheet = .roomSettings(room.id) }
        if room.kind == "closed" {
            Button("Leave Room") { Task { try? await state.leaveRoom(room.id) } }
        }
    }
}

struct Avatar: View {
    @Environment(AppState.self) private var state
    let userId: String
    let name: String
    let size: CGFloat

    var body: some View {
        AsyncImage(url: state.avatarURL(for: userId)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.25)
                    Text(initials).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}
