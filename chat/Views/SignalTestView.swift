import SwiftUI
import LibSignalClient
import SignalCoreKit

// MARK: - Chat-Test-Harness (zeigt nur entschlüsselte Nachrichten)
final class SignalChatHarness: ObservableObject {

    enum Peer: String, CaseIterable, Identifiable {
        case alice, bob
        var id: String { rawValue }
        var display: String { rawValue.capitalized }
        var other: Peer { self == .alice ? .bob : .alice }
    }

    struct ChatMessage: Identifiable, Equatable {
        let id = UUID()
        let sender: Peer      // Empfänger-Seite (wer zeigt die Blase)
        let text: String      // entschlüsselter Text
        let timestamp: Date
    }

    struct WirePacket: Identifiable {
        let id = UUID()
        let from: Peer
        let to: Peer
        let wire: SignalEngine.CipherWire
        let plainPreview: String   // nur für UI/Debug (nicht angezeigt)
        let ts: Date
    }

    @Published var messages: [ChatMessage] = []
    @Published var queued: [WirePacket] = []   // Transport-Puffer
    @Published var isSetup = false
    @Published var lastError: String?

    // Zwei getrennte Engines simulieren zwei Geräte
    private var aliceEngine = SignalEngine()
    private var bobEngine   = SignalEngine()

    func reset() {
        messages.removeAll()
        queued.removeAll()
        lastError = nil
        isSetup = false
        aliceEngine = SignalEngine()
        bobEngine   = SignalEngine()
    }

    func setupIfNeeded() {
        guard !isSetup else { return }
        do {
            let aliceBundle = try aliceEngine.makeOwnPreKeyBundle(deviceId: 1)
            let bobBundle   = try bobEngine.makeOwnPreKeyBundle(deviceId: 1)

            try aliceEngine.processPeerBundle(bobBundle,  peerId: Peer.bob.rawValue,   deviceId: 1)
            try bobEngine.processPeerBundle(aliceBundle,  peerId: Peer.alice.rawValue, deviceId: 1)

            isSetup = true
            lastError = nil
        } catch {
            lastError = "Setup-Fehler: \(error)"
        }
    }

    // MARK: - Senden & Zustellen

    /// Sofort senden + sofort beim Empfänger entschlüsseln (wie bisher).
    func sendImmediate(text: String, from: Peer) {
        guard isSetup else { lastError = "Bitte zuerst Setup ausführen."; return }
        do {
            let senderEngine   = (from == .alice) ? aliceEngine : bobEngine
            let receiverEngine = (from == .alice) ? bobEngine   : aliceEngine
            let wire = try senderEngine.encryptEnvelope(to: from.other.rawValue,
                                                        inner: ["type": "text", "text": text])
            let dec  = try receiverEngine.decryptEnvelope(from: from.rawValue, wire: wire)
            let rx   = (dec["text"] as? String) ?? "?"
            messages.append(ChatMessage(sender: from.other, text: rx, timestamp: Date()))
            lastError = nil
        } catch let e as SignalError {
            lastError = "SignalError: \(e)"
        } catch {
            lastError = "Unbekannter Fehler: \(error)"
        }
    }

    /// Nur verschlüsseln und in die Transport-Queue legen (keine Zustellung).
    func queueMessage(text: String, from: Peer) {
        guard isSetup else { lastError = "Bitte zuerst Setup ausführen."; return }
        do {
            let senderEngine = (from == .alice) ? aliceEngine : bobEngine
            let wire = try senderEngine.encryptEnvelope(to: from.other.rawValue,
                                                        inner: ["type": "text", "text": text])
            queued.append(WirePacket(from: from, to: from.other, wire: wire,
                                     plainPreview: text, ts: Date()))
            lastError = nil
        } catch let e as SignalError {
            lastError = "SignalError: \(e)"
        } catch {
            lastError = "Unbekannter Fehler: \(error)"
        }
    }

    /// Mehrere Nachrichten hintereinander vom selben Sender in die Queue legen.
    func burst(count: Int, from: Peer, base: String = "Burst") {
        for i in 1...count {
            queueMessage(text: "\(base) \(i)", from: from)
        }
    }

    /// Zustellen aller ausstehenden Pakete an einen Empfänger; optional out-of-order.
    func deliverAll(to recipient: Peer, outOfOrder: Bool = false) {
        guard isSetup else { lastError = "Bitte zuerst Setup ausführen."; return }
        var batch = queued.filter { $0.to == recipient }
        if batch.isEmpty { return }

        if outOfOrder {
            batch.shuffle()
        } else {
            batch.sort { $0.ts < $1.ts } // Zeitordnung
        }

        // Entferne die ausgewählten Pakete aus der Queue
        let ids = Set(batch.map { $0.id })
        queued.removeAll { ids.contains($0.id) }

        // Jetzt beim Empfänger entschlüsseln (Double Ratchet fast-forward greift hier)
        let receiverEngine = (recipient == .alice) ? aliceEngine : bobEngine
        for p in batch {
            do {
                let dec = try receiverEngine.decryptEnvelope(from: p.from.rawValue, wire: p.wire)
                let rx  = (dec["text"] as? String) ?? "?"
                messages.append(ChatMessage(sender: recipient, text: rx, timestamp: Date()))
            } catch let e as SignalError {
                lastError = "SignalError beim Zustellen: \(e)"
                return
            } catch {
                lastError = "Unbekannter Fehler beim Zustellen: \(error)"
                return
            }
        }
        lastError = nil
    }
}

// MARK: - UI
struct SignalTestView: View {
    @StateObject private var harness = SignalChatHarness()
    @State private var inputText: String = ""
    @State private var sender: SignalChatHarness.Peer = .alice

    var body: some View {
        VStack(spacing: 12) {
            header
            controls
            chatList
            inputBar
            errorBar
        }
        .padding()
    }

    // MARK: Header
    private var header: some View {
        HStack {
            Text("🔐 SignalEngine Chat-Test")
                .font(.title2).bold()
            Spacer()
        }
    }

    // MARK: Controls
    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: { harness.setupIfNeeded() }) {
                    Label(harness.isSetup ? "Setup ok" : "Setup (Keyaustausch)",
                          systemImage: harness.isSetup ? "checkmark.seal.fill" : "arrow.2.squarepath")
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(harness.isSetup ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button(role: .destructive, action: { harness.reset() }) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.red.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Spacer()

                Picker("Absender", selection: $sender) {
                    ForEach(SignalChatHarness.Peer.allCases) { p in
                        Text(p.display).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }

            // Burst / Queue Steuerung
            HStack(spacing: 8) {
                Button {
                    harness.burst(count: 5, from: .alice, base: "Alice 📨")
                } label: {
                    Label("Alice Burst ×5 (queue)", systemImage: "tray.and.arrow.up")
                        .padding(8).background(Color.blue.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)

                Button {
                    harness.burst(count: 5, from: .bob, base: "Bob 📨")
                } label: {
                    Label("Bob Burst ×5 (queue)", systemImage: "tray.and.arrow.up")
                        .padding(8).background(Color.green.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)

                Spacer()

                Text("Queue: \(harness.queued.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    harness.deliverAll(to: .alice, outOfOrder: false)
                } label: {
                    Label("→ Zustellen an Alice", systemImage: "tray.and.arrow.down")
                        .padding(8).background(Color.blue.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)

                Button {
                    harness.deliverAll(to: .bob, outOfOrder: false)
                } label: {
                    Label("→ Zustellen an Bob", systemImage: "tray.and.arrow.down")
                        .padding(8).background(Color.green.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)

                Button {
                    harness.deliverAll(to: .alice, outOfOrder: true)
                } label: {
                    Label("↯ Out-of-Order → Alice", systemImage: "arrow.up.arrow.down.square")
                        .padding(8).background(Color.blue.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)

                Button {
                    harness.deliverAll(to: .bob, outOfOrder: true)
                } label: {
                    Label("↯ Out-of-Order → Bob", systemImage: "arrow.up.arrow.down.square")
                        .padding(8).background(Color.green.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        }
    }

    // MARK: Chatliste (nur entschlüsselte Empfänger-Nachrichten)
    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(harness.messages) { m in
                        HStack {
                            if m.sender == .bob { Spacer(minLength: 40) } // Bob rechts
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(m.sender.display)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(m.timestamp, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(m.text) // entschlüsselter Text
                                    .padding(10)
                                    .background(m.sender == .alice ? Color.blue.opacity(0.15) : Color.green.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            if m.sender == .alice { Spacer(minLength: 40) } // Alice links
                        }
                        .id(m.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color.gray.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: harness.messages.count) { _ in
                if let last = harness.messages.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: Eingabe
    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Nachricht eingeben …", text: $inputText)
                .textFieldStyle(.roundedBorder)
            Button {
                let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                harness.setupIfNeeded()
                harness.sendImmediate(text: text, from: sender)
                inputText = ""
            } label: {
                Label("Senden (sofort)", systemImage: "paperplane.fill")
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: Fehleranzeige
    private var errorBar: some View {
        Group {
            if let err = harness.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err).font(.footnote)
                }
                .foregroundStyle(Color.orange)
                .padding(.top, 4)
            }
        }
    }
}
