import SwiftUI

/// The room header's huddle button: start the room's huddle, join the one going on, or leave it.
struct HuddleButton: View {
    @Environment(AppState.self) private var state
    let room: Room

    var body: some View {
        let here = state.huddle.roomId == room.id
        let others = state.liveHuddles[room.id]?.userIds.count ?? 0
        Button {
            if here { state.huddle.leave() } else { state.joinHuddle(in: room.id) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: here ? "headphones.circle.fill" : "headphones")
                    .foregroundStyle(here || others > 0 ? Color.green : .secondary)
                if others > 0 && !here { Text("\(others)").font(.caption.bold()).foregroundStyle(.green) }
            }
        }
        .help(here ? "Leave huddle" : others > 0 ? "Join huddle" : "Start huddle")
    }
}

/// While in a huddle: its room, who's in it, mute and leave. Sits at the bottom of the sidebar.
struct HuddleBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let huddle = state.huddle
        if let roomId = huddle.roomId {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "headphones").foregroundStyle(.green)
                    Button(roomTitle(roomId)) { state.selectedRoomId = roomId }.buttonStyle(.plain).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    if !huddle.connected { ProgressView().controlSize(.mini) }
                }
                HStack(spacing: -4) {
                    ForEach(huddle.people.prefix(8)) { person in
                        Avatar(userId: person.user.id, name: person.user.name, size: 22)
                            .overlay(alignment: .bottomTrailing) {
                                if person.muted {
                                    Image(systemName: "mic.slash.fill").font(.system(size: 8)).padding(2)
                                        .background(Circle().fill(.red)).foregroundStyle(.white)
                                }
                            }
                            .help(person.user.name + (person.muted ? " (muted)" : ""))
                    }
                }
                HStack {
                    Button { huddle.setMuted(!huddle.muted) } label: {
                        Label(huddle.muted ? "Unmute" : "Mute", systemImage: huddle.muted ? "mic.slash.fill" : "mic.fill")
                    }
                    .disabled(!huddle.hasMicrophone)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    Spacer()
                    Button(role: .destructive) { huddle.leave() } label: { Label("Leave", systemImage: "phone.down.fill") }
                        .tint(.red)
                }
                .controlSize(.small)
                if !huddle.hasMicrophone {
                    Text("No microphone, so you can only listen. Allow Ember in System Settings › Privacy › Microphone.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
            .padding(.horizontal, 8)
        }
    }

    private func roomTitle(_ id: String) -> String {
        guard let room = state.room(id) else { return "Huddle" }
        return room.isDirect ? state.title(of: room) : "#\(state.title(of: room))"
    }
}
