import SwiftUI
import ExyteChat
import MultipeerConnectivity

private enum MyMenu: MessageMenuAction {
    case copy, save, delete
    func title() -> String {
        switch self {
        case .copy: "Copy"
        case .delete: "Löschen"
        case .save: "Save"
        }
    }
    func icon() -> Image {
        switch self {
        case .copy: Image(systemName: "doc.on.doc")
        case .delete: Image(systemName: "trash")
        case .save: Image(systemName: "tray.and.arrow.down")
        }
    }
    static func menuItems(for message: ExyteChat.Message) -> [MyMenu] {
        var items: [MyMenu] = [.copy]
        if message.user.isCurrentUser { items.append(contentsOf: [.save, .delete]) }
        return items
    }
}

struct FingerprintPair: Identifiable {
    let id = UUID()
    let mine: String
    let peer: String
    let peerId: String
}

struct ChatDetailView: View {
    let contact: Contact
    let me: MyIdentity

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var socketManager: ChatSocketManager

    // Multipeer
    @State private var linkService: PeerLinkService?
    @State private var ackSent = false
    @State private var pendingFingerprint: FingerprintPair?
    @State private var fingerprintPair: FingerprintPair?

    init(contact: Contact, me: MyIdentity) {
        self.contact = contact
        self.me = me
        let initialRoom = ChatSocketManager.computeRoomId(myId: me.id, peerId: contact.id)
        _socketManager = StateObject(
            wrappedValue: ChatSocketManager(contact: contact, me: me, roomId: initialRoom)
        )
    }

    var body: some View {
        ChatView(messages: socketManager.messages) { draft in
            if !draft.medias.isEmpty {
                Task {
                    for media in draft.medias {
                        if let data = await media.getData() {
                            socketManager.sendImageData(data)
                        }
                    }
                }
            }
            if !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                socketManager.send(draft.text)
            }
        } messageMenuAction: { (action: MyMenu, defaultAction, message) in
            switch action {
            case .copy:   defaultAction(message, .copy)
            case .delete: deleteMessageLocally(message.id)
            case .save:   saveMessageLocally(message)
            }
        }
        .setAvailableInputs([.text, .media])
        .navigationBarBackButtonHidden()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { presentationMode.wrappedValue.dismiss() } label: {
                    Image("backArrow", bundle: .current)
                        .renderingMode(.template)
                        .foregroundStyle(colorScheme == .dark ? .white : .black)
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Text(contact.name)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? .white : .black)
                    .padding(.leading, 10)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { startLink() } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                .help("Verbinden")
            }
        }
        .sheet(item: $linkService, onDismiss: { linkService?.stop(); linkService = nil }) { service in
            LinkStatusView(linkService: service, onHandshake: { data in
                handleHandshakeData(data)
            }, onAck: {
                handleAckReceived()
            })
            .presentationDetents([.height(240)])
        }
        .sheet(item: $fingerprintPair) { pair in
            FingerprintVerifyView(pair: pair)
        }
        .onAppear {
            // Chat-Raum beitreten (WebSocket)
            let roomId = ChatSocketManager.computeRoomId(myId: me.id, peerId: contact.id)
            PushSocket.shared.join(room: roomId)

            // Badge-Zähler zurücksetzen
            NotificationCenter.default.post(name: .didOpenChatRoom, object: contact.id)

            // Gepufferte Nachrichten vom Server holen
            Task {
                do {
                    let pending = try await ChatHTTPClient().fetchPending(me: me.id, roomId: roomId)
                    for (room, b64, ts) in pending where room == roomId {
                        try await socketManager.handleIncoming(b64, timestamp: ts)
                    }
                } catch {
                    print("❌ Fehler beim Laden ausstehender Nachrichten:", error)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceivePush)) { note in
            guard let data = note.object as? Data,
                  let push = try? JSONDecoder().decode(ServerPush.self, from: data)
            else { return }

            // 👇 nur Nachrichten für diesen Raum
            let roomId = ChatSocketManager.computeRoomId(myId: me.id, peerId: contact.id)
            if push.roomId == roomId, let b64 = push.payload {
                Task {
                    try? await socketManager.handleIncoming(b64, timestamp: push.timestamp ?? Date().timeIntervalSince1970*1000)
                }
            }
        }

        .onDisappear {
            let roomId = ChatSocketManager.computeRoomId(myId: me.id, peerId: contact.id)
            PushSocket.shared.leave(room: roomId)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                let room = ChatSocketManager.computeRoomId(myId: me.id, peerId: contact.id)
                PushSocket.shared.join(room: room)

                Task {
                    let pending = try await ChatHTTPClient().fetchPending(me: me.id, roomId: room)
                    for (r, b64, ts) in pending where r == room {
                        try await socketManager.handleIncoming(b64, timestamp: ts)
                    }
                }
            }
        }
    }

    private func startLink() {
        linkService?.stop()
        ackSent = false
        linkService = PeerLinkService { [me] in
            try SignalEngine.shared.makeHandshakeData(myAppId: me.id, deviceId: 1)
        }
    }

    private func handleHandshakeData(_ data: Data) {
        do {
            let (peerId, bundle) = try SignalEngine.shared.parseHandshakeData(data)
            try SignalEngine.shared.processPeerBundle(bundle, peerId: peerId)
            socketManager.linkPeerAfterHandshake(peerId: peerId)

            if let idB64 = bundle["identity"] as? String,
               let idData = Data(base64Encoded: idB64) {
                let peerFP = SignalEngine.shared.fingerprint(from: idData)
                let myFP = SignalEngine.shared.myFingerprint()
                pendingFingerprint = FingerprintPair(mine: myFP, peer: peerFP, peerId: peerId)
            }

            linkService?.sendAck()
            ackSent = true
            if linkService?.receivedAck == true { closeLink() }
        } catch {
            print("❌ Handshake-Verarbeitung fehlgeschlagen:", error.localizedDescription)
        }
    }

    private func handleAckReceived() {
        if ackSent { closeLink() }
    }

    private func closeLink() {
        linkService?.stop()
        linkService = nil
        if let pair = pendingFingerprint {
            fingerprintPair = pair
            pendingFingerprint = nil
        }
    }

    private func saveMessageLocally(_ message: ExyteChat.Message) {
        print("💾 Nachricht gespeichert: \(message.text)")
    }

    private func deleteMessageLocally(_ messageId: String) {
        print("🗑️ Nachricht mit ID \(messageId) gelöscht.")
    }
}

// 🆕 Signal für Badge-Reset in ContactsListView
extension Notification.Name {
    static let didOpenChatRoom = Notification.Name("didOpenChatRoom")
}

struct LinkStatusView: View {
    @ObservedObject var linkService: PeerLinkService
    let onHandshake: (Data) -> Void
    let onAck: () -> Void
    @State private var started = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Verbinden").font(.headline)
            Text("Deine ID: \(linkService.myCode)")
            Text("Peer ID: \(linkService.peerCode ?? "wartet…")")
            Text("Status: \(describe(linkService.state))").font(.subheadline)
            if let err = linkService.lastError {
                Text(err).foregroundStyle(.red).font(.footnote)
            }
            HStack {
                Button("Start") {
                    started = true
                    linkService.startHandshake()
                    if let data = linkService.receivedHandshake { onHandshake(data) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(linkService.peerCode == nil || started)

                Button("Beenden") {
                    linkService.stop()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .onChange(of: linkService.receivedHandshake) { _, data in
            if started, let data { onHandshake(data) }
        }
        .onChange(of: linkService.receivedAck) { _, ok in
            if ok { onAck() }
        }
    }

    private func describe(_ s: MCSessionState) -> String {
        switch s {
        case .notConnected: return "Nicht verbunden"
        case .connecting:   return "Verbindet…"
        case .connected:    return "Verbunden"
        @unknown default:   return "Unbekannt"
        }
    }
}

