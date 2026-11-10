import SwiftUI
import UniformTypeIdentifiers

/// The sheets over the workspace: new DM, new room, room settings, people, someone's profile, yours.
struct WorkspaceSheet: View {
    @Environment(AppState.self) private var state
    let sheet: AppState.Sheet

    var body: some View {
        switch sheet {
        case .newDirect: NewDirectSheet()
        case .newRoom: NewRoomSheet()
        case .people: PeopleSheet()
        case .profile: ProfileSheet()
        case let .person(id): PersonSheet(userId: id)
        case let .roomSettings(id): RoomSettingsSheet(roomId: id)
        case let .image(file): ImageViewer(file: file)
        case .search: SearchSheet()
        case let .web(path, title): WebSheet(path: path, title: title)
        }
    }
}

/// A sheet's title row, with Cancel/Done.
private struct SheetHeader: View {
    @Environment(\.dismiss) private var dismiss
    let title: String

    var body: some View {
        HStack {
            Text(title).font(.title3.bold())
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }
}

/// People to pick from, searchable, with checkmarks.
private struct PeoplePicker: View {
    let people: [User]
    @Binding var picked: Set<String>
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search people", text: $query).textFieldStyle(.roundedBorder)
            List(filtered) { person in
                Button {
                    if picked.contains(person.id) { picked.remove(person.id) } else { picked.insert(person.id) }
                } label: {
                    HStack {
                        Avatar(userId: person.id, name: person.name, size: 22)
                        Text(person.name)
                        Spacer()
                        if picked.contains(person.id) { Image(systemName: "checkmark").foregroundStyle(Brand.accent) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 220)
        }
    }

    private var filtered: [User] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? people : people.filter { $0.name.lowercased().contains(q) }
    }
}

// MARK: - New DM

struct NewDirectSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "New message")
            Text("Pick one person for a DM, or several for a group DM.").font(.callout).foregroundStyle(.secondary)
            PeoplePicker(people: candidates, picked: $picked)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(working ? "Opening…" : "Open DM") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 420, height: 460)
    }

    private var candidates: [User] {
        state.directory.filter { $0.status == "active" && $0.id != state.me?.id }.map { User(id: $0.id, name: $0.name) }
    }

    private func start() {
        working = true
        Task {
            defer { working = false }
            do {
                try await state.openDirect(with: Array(picked))
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - New room

struct NewRoomSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isPrivate = false
    @State private var people: [User] = []
    @State private var picked: Set<String> = []
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "New room")
            TextField("Name", text: $name, prompt: Text("design-reviews")).textFieldStyle(.roundedBorder)
            Picker("Who's in it", selection: $isPrivate) {
                Text("Everyone").tag(false)
                Text("Only people I pick").tag(true)
            }
            .pickerStyle(.radioGroup)
            if isPrivate { PeoplePicker(people: people, picked: $picked) } else { Spacer(minLength: 0) }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(working ? "Creating…" : "Create room") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 420, height: isPrivate ? 520 : 260)
        .task {
            do { people = try await state.api?.newRoomForm().people.filter { $0.id != state.me?.id } ?? [] }
            catch { self.error = error.localizedDescription }
        }
    }

    private func create() {
        working = true
        Task {
            defer { working = false }
            do {
                try await state.createRoom(name: name.trimmingCharacters(in: .whitespaces), isPrivate: isPrivate, memberIds: Array(picked))
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Room settings

struct RoomSettingsSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let roomId: String

    @State private var settings: RoomSettings?
    @State private var name = ""
    @State private var isPrivate = false
    @State private var picked: Set<String> = []
    @State private var error: String?
    @State private var working = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: title)
            if let settings {
                if settings.room.isDirect {
                    Text("Everyone in this DM:").font(.callout).foregroundStyle(.secondary)
                    ForEach(settings.room.members ?? []) { member in
                        HStack { Avatar(userId: member.id, name: member.name, size: 22); Text(member.name) }
                    }
                    Spacer(minLength: 0)
                } else if settings.canAdminister {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    Picker("Who's in it", selection: $isPrivate) {
                        Text("Everyone").tag(false)
                        Text("Only people I pick").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    if isPrivate {
                        PeoplePicker(people: settings.people.map { User(id: $0.id, name: $0.name) }, picked: $picked)
                    } else {
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("Only its creator and administrators can change this room.").foregroundStyle(.secondary)
                    Text("\(settings.people.filter(\.member).count) people are in it.").font(.callout)
                    Spacer(minLength: 0)
                }
                involvement
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    if settings.canAdminister {
                        Button("Delete…", role: .destructive) { confirmingDelete = true }
                    } else if settings.room.kind == "closed" {
                        Button("Leave room") { leave() }
                    }
                    Spacer()
                    if settings.canAdminister && !settings.room.isDirect {
                        Button(working ? "Saving…" : "Save") { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
                Spacer()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: 440, height: 520)
        .task { await load() }
        .confirmationDialog("Delete this room for everyone?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { delete() }
        } message: {
            Text("Its messages and files go too. This can't be undone.")
        }
    }

    private var title: String {
        guard let room = settings?.room ?? state.room(roomId) else { return "Room settings" }
        return room.isDirect ? state.title(of: room) : "#\(state.title(of: room))"
    }

    private var involvement: some View {
        Picker("Notify me about", selection: Binding(
            get: { Involvement(rawValue: state.room(roomId)?.involvement ?? "mentions") ?? .mentions },
            set: { level in Task { await state.setInvolvement(roomId, level) } })) {
            ForEach(Involvement.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
        }
    }

    private func load() async {
        do {
            let settings = try await state.api?.roomSettings(roomId)
            self.settings = settings
            name = settings?.room.name ?? ""
            isPrivate = settings?.room.kind == "closed"
            picked = Set(settings?.people.filter(\.member).map(\.id) ?? [])
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        working = true
        Task {
            defer { working = false }
            do {
                try await state.changeRoom(roomId, name: name.trimmingCharacters(in: .whitespaces), isPrivate: isPrivate,
                                           memberIds: Array(picked.union([state.me?.id].compactMap { $0 })))
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func delete() {
        Task {
            do { try await state.deleteRoom(roomId); dismiss() } catch { self.error = error.localizedDescription }
        }
    }

    private func leave() {
        Task {
            do { try await state.leaveRoom(roomId); dismiss() } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - People

struct PeopleSheet: View {
    @Environment(AppState.self) private var state
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "People")
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            List(filtered) { person in
                Button { state.sheet = .person(person.id) } label: {
                    HStack(spacing: 10) {
                        Avatar(userId: person.id, name: person.name, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(person.name)
                                if person.agent == true { Badge("Agent") }
                                if person.role == "administrator" { Badge("Admin") }
                                if person.role == "bot" { Badge("Bot") }
                                if person.status != "active" { Badge(person.status.capitalized) }
                            }
                            if let bio = person.bio, !bio.isEmpty { Text(bio).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 440, height: 520)
    }

    private var filtered: [DirectoryUser] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? state.directory : state.directory.filter { $0.name.lowercased().contains(q) }
    }
}

struct Badge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
    }
}

struct PersonSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let userId: String
    @State private var person: Person?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 12) {
            SheetHeader(title: "")
            Avatar(userId: userId, name: shownName, size: 96)
            Text(shownName).font(.title2.bold())
            if let person {
                HStack(spacing: 4) {
                    if person.agent == true { Badge("Agent") }
                    if person.role == "administrator" { Badge("Admin") }
                    if person.role == "bot" { Badge("Bot") }
                    if person.status != "active" { Badge(person.status.capitalized) }
                }
                if let bio = person.bio, !bio.isEmpty { Text(bio).multilineTextAlignment(.center).foregroundStyle(.secondary) }
                if let email = person.emailAddress { Link(email, destination: URL(string: "mailto:\(email)")!).font(.callout) }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            Spacer()
            if userId == state.me?.id {
                Button("Edit profile") { state.sheet = .profile }
            } else if person?.status == "active" && person?.role != "bot" {
                Button("Message") {
                    Task {
                        do { try await state.openDirect(with: [userId]); dismiss() } catch { self.error = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360, height: 420)
        .task {
            do { person = try await state.api?.person(userId) } catch { self.error = error.localizedDescription }
        }
    }

    private var shownName: String { person?.name ?? state.name(of: userId) ?? "" }
}

// MARK: - Your profile

struct ProfileSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var profile: Profile?
    @State private var name = ""
    @State private var bio = ""
    @State private var email = ""
    @State private var newPassword = ""
    @State private var currentPassword = ""
    @State private var error: String?
    @State private var notice: String?
    @State private var working = false
    @State private var choosingPhoto = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "Your profile")
            if profile != nil {
                HStack(spacing: 14) {
                    Avatar(userId: state.me?.id ?? "", name: name, size: 72)
                    VStack(alignment: .leading) {
                        Button("Choose photo…") { choosingPhoto = true }
                        if profile?.avatar == true { Button("Remove photo") { removePhoto() }.buttonStyle(.link) }
                    }
                }
                Form {
                    TextField("Name", text: $name)
                    TextField("About you", text: $bio, prompt: Text("What you do, where you are…"))
                    Section("Sign-in") {
                        TextField("Email", text: $email)
                        SecureField("New password", text: $newPassword)
                        if needsCurrentPassword { SecureField("Current password", text: $currentPassword) }
                    }
                }
                .formStyle(.grouped)
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                if let notice { Text(notice).foregroundStyle(.green).font(.callout) }
                HStack {
                    Spacer()
                    Button(working ? "Saving…" : "Save") { save() }.keyboardShortcut(.defaultAction).disabled(working)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: 460, height: 560)
        .task { await load() }
        .fileImporter(isPresented: $choosingPhoto, allowedContentTypes: [.image]) { result in
            if case let .success(url) = result { uploadPhoto(url) }
        }
    }

    /// Changing the email address or password asks for the current password.
    private var needsCurrentPassword: Bool {
        profile?.password == true && (!newPassword.isEmpty || email != (profile?.emailAddress ?? ""))
    }

    private func load() async {
        do {
            let profile = try await state.api?.profile()
            self.profile = profile
            name = profile?.name ?? ""
            bio = profile?.bio ?? ""
            email = profile?.emailAddress ?? ""
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard let profile, let api = state.api else { return }
        var changes = APIClient.ProfileChanges()
        if name != profile.name { changes.name = name }
        if bio != (profile.bio ?? "") { changes.bio = bio }
        if email != (profile.emailAddress ?? "") { changes.emailAddress = email }
        if !newPassword.isEmpty { changes.password = newPassword }
        if needsCurrentPassword { changes.currentPassword = currentPassword }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let saved = try await api.changeProfile(changes)
                self.profile = saved
                newPassword = ""
                currentPassword = ""
                state.profileChanged(saved)
                notice = "Saved."
            } catch { self.error = error.localizedDescription }
        }
    }

    private func uploadPhoto(_ url: URL) {
        guard let api = state.api else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data), let variant = image.jpegFitting(512) else {
            error = "That file isn't a picture Ember can use."
            return
        }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        Task {
            do {
                let saved = try await api.changeAvatar(file: data, fileName: url.lastPathComponent, contentType: type, variant: variant)
                profile = saved
                state.profileChanged(saved)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func removePhoto() {
        Task {
            do {
                if let saved = try await state.api?.removeAvatar() { profile = saved; state.profileChanged(saved) }
            } catch { self.error = error.localizedDescription }
        }
    }
}
