import Foundation
import MultipeerConnectivity

final class PeerLinkService: NSObject, ObservableObject, Identifiable {
    // Identifiable für .sheet(item:)
    let id = UUID()

    private let serviceType = "safechat-e2e" // <= 15 Zeichen, [a-z0-9-]
    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)

    private lazy var advertiser: MCNearbyServiceAdvertiser = {
        let adv = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        adv.delegate = self
        return adv
    }()
    private lazy var browser: MCNearbyServiceBrowser = {
        let br = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        br.delegate = self
        return br
    }()

    @Published var state: MCSessionState = .notConnected
    @Published var lastError: String?
    @Published var receivedHandshake: Data?
    @Published var receivedAck = false
    @Published var peerCode: String?

    /// Achtstelliger Code, wird beim Initialisieren erzeugt
    let myCode: String = (0..<8).map { _ in String(Int.random(in: 0...9)) }.joined()

    private let makePayload: () throws -> Data

    init(makePayload: @escaping () throws -> Data) {
        self.makePayload = makePayload
        super.init()
        session.delegate = self
        // Bewirbt und durchsucht gleichzeitig
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        DispatchQueue.main.async {
            self.peerCode = nil
            self.receivedHandshake = nil
            self.receivedAck = false
            self.state = .notConnected
        }
    }

    func startHandshake() {
        do {
            let data = try makePayload()
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            DispatchQueue.main.async { self.lastError = "Senden fehlgeschlagen: \(error.localizedDescription)" }
        }
    }

    func sendAck() {
        let ack = Data("ACK".utf8)
        do {
            try session.send(ack, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            DispatchQueue.main.async { self.lastError = "ACK senden fehlgeschlagen: \(error.localizedDescription)" }
        }
    }
}

extension PeerLinkService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { self.state = state }

        // Nach Verbindungsaufbau zuerst nur den Code übertragen
        if state == .connected {
            let codeMsg = Data("CODE:\(myCode)".utf8)
            do {
                try session.send(codeMsg, toPeers: session.connectedPeers, with: .reliable)
            } catch {
                DispatchQueue.main.async { self.lastError = "Code senden fehlgeschlagen: \(error.localizedDescription)" }
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let ack = Data("ACK".utf8)
        if data == ack {
            DispatchQueue.main.async { self.receivedAck = true }
            return
        }

        if let str = String(data: data, encoding: .utf8), str.hasPrefix("CODE:") {
            let code = String(str.dropFirst(5))
            DispatchQueue.main.async { self.peerCode = code }
        } else {
            DispatchQueue.main.async { self.receivedHandshake = data }
        }
    }

    // Unbenutzt:
    func session(_: MCSession, didReceive _: InputStream, withName _: String, fromPeer _: MCPeerID) {}
    func session(_: MCSession, didStartReceivingResourceWithName _: String, fromPeer _: MCPeerID, with _: Progress) {}
    func session(_: MCSession, didFinishReceivingResourceWithName _: String, fromPeer _: MCPeerID, at _: URL?, withError _: Error?) {}
    func session(_: MCSession, didReceive certs: [Any]?, fromPeer _: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }
}

extension PeerLinkService: MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    // Wenn ein Peer gefunden wird, Einladung senden (sofern nicht bereits verbunden)
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo _: [String : String]?) {
        guard !session.connectedPeers.contains(peerID) else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }
    func browser(_: MCNearbyServiceBrowser, lostPeer _: MCPeerID) {}

    // Eingehende Einladungen annehmen
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext _: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
    func advertiser(_: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }
    func browser(_: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }
}
