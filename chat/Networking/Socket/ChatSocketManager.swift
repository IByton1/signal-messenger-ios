import Foundation
import ExyteChat
import UIKit

@MainActor
final class ChatSocketManager: ObservableObject {
    @Published var messages: [Message] = []

    private var contact: Contact
    private let me: MyIdentity
    private let crypto = SignalEngine.shared
    private var roomId: String

    init(contact: Contact, me: MyIdentity, roomId: String) {
        self.contact = contact
        self.me = me
        self.roomId = roomId
    }

    static func computeRoomId(myId: String, peerId: String) -> String {
        [myId, peerId].sorted().joined(separator: "|")
    }

    func linkPeerAfterHandshake(peerId: String) {
        updateChatPartner(to: peerId)
        appendSystem("🔒 E2E-Session mit \(peerId) eingerichtet.")
    }

    func updateChatPartner(to newPeerId: String) {
        let oldPeerId = contact.id
        contact.id = newPeerId
        contact.user = User(id: newPeerId, name: contact.user.name,
                            avatarURL: contact.user.avatarURL, isCurrentUser: false)
        contact.isLinked = true

        var list = ContactStore.load()
        if let idx = list.firstIndex(where: { $0.id == oldPeerId }) {
            list[idx] = contact
        } else {
            list.append(contact)
        }
        ContactStore.save(list)

        roomId = Self.computeRoomId(myId: me.id, peerId: newPeerId)
    }

    func send(_ text: String) {
        Task {
            do {
                let inner: [String: Any] = [
                    "sender": me.id,
                    "recipient": contact.id,
                    "type": "text",
                    "text": text
                ]
                let cipher = try crypto.encryptEnvelope(to: contact.id, inner: inner)
                let data = try JSONEncoder().encode(cipher)
                let b64 = data.base64EncodedString()

                try await ChatHTTPClient().sendEncrypted(from: me.id, to: contact.id, payload: b64)
                appendText(sender: me.id, text: text)
            } catch {
                print("❌ Fehler beim Senden:", error)
            }
        }
    }

    func sendImageData(_ data: Data) {
        Task {
            do {
                guard let image = UIImage(data: data),
                      let compressed = image.jpegData(compressionQuality: 0.6) else { return }
                let inner: [String: Any] = [
                    "sender": me.id,
                    "recipient": contact.id,
                    "type": "image",
                    "image": compressed.base64EncodedString()
                ]
                let cipher = try crypto.encryptEnvelope(to: contact.id, inner: inner)
                let encoded = try JSONEncoder().encode(cipher).base64EncodedString()
                try await ChatHTTPClient().sendEncrypted(from: me.id, to: contact.id, payload: encoded)
                appendImage(sender: me.id, imageData: compressed)
            } catch {
                print("❌ Fehler beim Senden:", error)
            }
        }
    }

    func handleIncoming(_ b64: String, timestamp: TimeInterval) async throws {
        let data = Data(base64Encoded: b64)!
        let cipherWire = try JSONDecoder().decode(SignalEngine.CipherWire.self, from: data)
        let inner = try crypto.decryptEnvelope(from: contact.id, wire: cipherWire)

        let senderId = inner["sender"] as? String ?? "?"
        let date = Date(timeIntervalSince1970: timestamp / 1000)

        if let type = inner["type"] as? String, type == "image",
           let b64 = inner["image"] as? String,
           let imgData = Data(base64Encoded: b64) {
            appendImage(sender: senderId, imageData: imgData, date: date)
        } else if let text = inner["text"] as? String {
            appendText(sender: senderId, text: text, date: date)
        }
    }

    private func appendSystem(_ text: String) {
        appendText(sender: me.id, text: text)
    }

    private func appendText(sender: String, text: String, date: Date = Date()) {
        let draft = DraftMessage(text: text, medias: [], giphyMedia: nil, recording: nil,
                                 replyMessage: nil, createdAt: date)
        appendDraft(sender: sender, draft: draft)
    }

    private func appendImage(sender: String, imageData: Data, date: Date = Date()) {
        let filename = UUID().uuidString + ".jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? imageData.write(to: url)
        let attachment = Attachment(id: UUID().uuidString, url: url, type: .image)
        let msg = Message(id: UUID().uuidString,
                          user: user(for: sender),
                          status: .sent,
                          createdAt: date,
                          text: "",
                          attachments: [attachment])
        messages.append(msg)
    }

    private func appendDraft(sender: String, draft: DraftMessage) {
        let swiftUser = user(for: sender)
        Task {
            let msg = await Message.makeMessage(
                id: UUID().uuidString,
                user: swiftUser,
                status: .sent,
                draft: draft
            )
            messages.append(msg)
        }
    }

    private func user(for id: String) -> User {
        if id == me.id {
            return User(id: me.id, name: me.name, avatarURL: nil, isCurrentUser: true)
        }
        return contact.user
    }
}
