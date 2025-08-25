import SwiftUI
import ExyteChat

struct ContactsListView: View {
    // MARK: – State / Model
    @State private var contacts: [Contact] = ContactStore.load()
    @State private var myIdentity = MyIdentity.loadOrCreate()

    @State private var unreadCounts = [String: Int]()
    private let client = ChatHTTPClient()

    // Chat‑Create / Rename Dialoge
    @State private var showNewChatDialog = false
    @State private var newContactName = ""
    @State private var renamingIndex: Int? = nil
    @State private var newName = ""

    // Einstellungen + Suche
    @State private var showChangePattern = false
    @State private var searchText = ""

    private var filteredContacts: [Contact] {
        contacts.filter { contact in
            searchText.isEmpty || contact.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: – View
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredContacts) { contact in
                            NavigationLink {
                                ChatDetailView(contact: contact, me: myIdentity)
                            } label: {
                                ChatRow(contact: contact,
                                        unreadCount: unreadCounts[contact.id, default: 0])
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Umbennen") {
                                    renamingIndex = contacts.firstIndex { $0.id == contact.id }
                                    newName = contact.name
                                }
                                Button("Löschen", role: .destructive) {
                                    contacts.removeAll { $0.id == contact.id }
                                    ContactStore.save(contacts)
                                }
                            }
                            Divider()
                        }
                    }
                }
                .searchable(text: $searchText, prompt: "Chat‑Namen suchen")

                Button {
                    showNewChatDialog = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24))
                        .padding()
                }
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(Circle())
                .shadow(radius: 4)
                .padding()
            }
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showChangePattern = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(isPresented: $showChangePattern) {
                ChangeUnlockPatternView()
            }
            .alert("Neuen Chat erstellen", isPresented: $showNewChatDialog) {
                TextField("Name", text: $newContactName)
                Button("Abbrechen", role: .cancel) { newContactName = "" }
                Button("Erstellen") { createContact() }
            }
            .alert("Chat umbenennen", isPresented: Binding(
                get: { renamingIndex != nil },
                set: { if !$0 { renamingIndex = nil } }
            )) {
                TextField("Neuer Name", text: $newName)
                Button("Abbrechen", role: .cancel) { renamingIndex = nil }
                Button("Speichern") { saveRename() }
            }
            .onAppear {
                PushSocket.shared.connect(userId: myIdentity.id)
                Task {
                    let counts = try await client.fetchPendingCounts(me: myIdentity.id)
                    // Zähler übernehmen, fehlende mit 0 initialisieren
                    var result = counts
                    for contact in contacts where result[contact.id] == nil {
                        result[contact.id] = 0
                    }

                    unreadCounts = result
                }
            }

            .onReceive(NotificationCenter.default.publisher(for: .didReceivePush)) { note in
                guard let data = note.object as? Data,
                          let event = try? JSONDecoder().decode(PushEvent.self, from: data),
                          event.type == "unread_hint"
                    else { return }

                    unreadCounts[event.peer, default: 0] += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .didOpenChatRoom)) { note in
                if let peerId = note.object as? String {
                    unreadCounts[peerId] = 0
                }
            }
        }
    }

    // MARK: – Helpers
    private func createContact() {
        guard !newContactName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let generatedId = UUID().uuidString
        let user = User(id: generatedId, name: newContactName, avatarURL: nil, isCurrentUser: false)
        let contact = Contact(id: generatedId, name: newContactName, user: user)
        contacts.append(contact)
        ContactStore.save(contacts)
        newContactName = ""
    }

    private func saveRename() {
        guard let idx = renamingIndex else { return }
        let oldUser = contacts[idx].user
        contacts[idx].name = newName
        contacts[idx].user = User(id: oldUser.id, name: newName, avatarURL: oldUser.avatarURL, isCurrentUser: oldUser.isCurrentUser)
        ContactStore.save(contacts)
        renamingIndex = nil
    }

    struct PushEvent: Decodable {
        let type: String
        let roomId: String
        let peer: String
    }
}

// MARK: – Chat‑Row (WhatsApp‑Style)
private struct ChatRow: View {
    let contact: Contact
    var unreadCount: Int

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(Color.gray.opacity(0.4))
                .frame(width: 48, height: 48)

            Text(contact.name)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Group {
                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Circle().fill(Color.accentColor))
                } else {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 24, height: 24)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
        .contentShape(Rectangle())
    }
}
