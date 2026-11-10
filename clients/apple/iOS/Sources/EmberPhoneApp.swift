import SwiftUI

@main
struct EmberPhoneApp: App {
    @State private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneRoot()
                .environment(state)
                .tint(Brand.accent)
                .task { await state.start() }
                .onChange(of: scenePhase) { _, phase in
                    // Only the room on screen while the app is in front counts as seen.
                    state.setAppActive(phase == .active)
                    if phase == .active { state.selectionChanged() }
                }
                .onChange(of: state.unreadCount) { _, count in Notifier.shared.setBadge(count) }
                .onAppear { Notifier.shared.openRoom = { id in state.selectedRoomId = id } }
                .alert("Huddle ended", isPresented: Binding(get: { state.huddle.ended != nil }, set: { if !$0 { state.huddle.ended = nil } })) {
                    Button("OK") { state.huddle.ended = nil }
                } message: { Text(state.huddle.ended ?? "") }
        }
    }
}

struct PhoneRoot: View {
    @Environment(AppState.self) private var state

    var body: some View {
        switch state.phase {
        case .starting:
            ProgressView().controlSize(.large)
        case .signedOut:
            PhoneSignInView()
        case .signedIn:
            PhoneWorkspaceView()
        }
    }
}

struct PhoneSignInView: View {
    @Environment(AppState.self) private var state
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        @Bindable var state = state
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        EmberLogo(size: 84).shadow(color: Brand.accent.opacity(0.35), radius: 16)
                        Text("Sign in to Ember").font(.title2.bold())
                        Text("Use the address of your Ember and the account you use on the web.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Server, such as chat.example.com", text: $state.serverText)
                        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Email", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password).onSubmit(signIn)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button(action: signIn) {
                        HStack { Spacer(); if working { ProgressView() } else { Text("Sign in").bold() }; Spacer() }
                    }
                    .disabled(working || email.isEmpty || password.isEmpty || state.serverText.isEmpty)
                }
            }
        }
    }

    private func signIn() {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await state.signIn(email: email, password: password)
                password = ""
            } catch { self.error = error.localizedDescription }
        }
    }
}
