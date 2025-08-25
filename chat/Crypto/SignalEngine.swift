import Foundation
import LibSignalClient
import SignalCoreKit
import CryptoKit

final class SignalEngine {

    static let shared = SignalEngine()

    private let ctx = PersistentSignalProtocolStore.Context()
    private let store: PersistentSignalProtocolStore
    private let myIdentity: IdentityKeyPair
    private let myRegId: UInt32

    init() {
        // Identity + RegistrationId laden/erzeugen (Keychain)
        do {
            let identity = try IdentityKeyPair.loadOrGenerateFromKeychain()
            let regId    = try UInt32.loadOrGenerateRegistrationId()

            // Persistenter Store (SQLCipher/GRDB)
            self.store      = try PersistentSignalProtocolStore(identity: identity,
                                                                registrationId: regId)
            try store.ensureSignedPreKey(context: ctx) // Sicherheits-Check

            self.myIdentity = identity
            self.myRegId    = regId

            // Genug PreKeys + Kyber-PreKey sicherstellen
            try store.ensurePreKeyBatch(context: ctx)
            try store.ensureKyberPreKey(context: ctx)
            try store.ensureSignedPreKeyRotation(context: ctx)
        } catch {
            fatalError("SignalEngine init failed: \(error)")
        }
    }
    
    public var protocolStore: PersistentSignalProtocolStore {
        return store
    }

    // MARK: - Öffentliche Bundles (für Handshake/Link)

    func makeOwnPreKeyBundle(deviceId: Int32 = 1) throws -> [String: Any] {
        let (preKeyId, preKeyRecord) = try store.reserveNextPreKey(context: ctx)

        let spkId: UInt32 = {
            // heuristisch: nimm den höchsten existierenden, sonst 1
            for i in (1...1024).reversed() {
                if (try? store.loadSignedPreKey(id: UInt32(i), context: ctx)) != nil {
                    return UInt32(i)
                }
            }
            return 1
        }()

        let signedPreKey = try store.loadSignedPreKey(id: spkId, context: ctx)
        let preKeyPub    = try preKeyRecord.publicKey()
        let spkPub       = try signedPreKey.publicKey()
        let identityPub  = myIdentity.publicKey

        // PQ (Kyber) als optionales Add-on
        let kyber = try store.nextUnusedKyberPreKey(context: ctx)
        let kyberPub = try kyber.1.publicKey()
        let kyberSig = kyber.1.signature

        return [
            "registrationId": myRegId,
            "deviceId": deviceId,
            "preKeyId": preKeyId, // reservierte ID
            "preKey": preKeyPub.serialize().base64EncodedString(),
            "signedPreKeyId": spkId,
            "signedPreKey": spkPub.serialize().base64EncodedString(),
            "signedPreKeySignature": signedPreKey.signature.base64EncodedString(),
            "identity": identityPub.serialize().base64EncodedString(),
            "kyberPreKeyId": kyber.0,
            "kyberPreKey": kyberPub.serialize().base64EncodedString(),
            "kyberPreKeySignature": kyberSig.base64EncodedString()
        ]
    }

    /// JSON { peerId, bundle } (für Multipeer/QR)
    func makeHandshakeData(myAppId: String, deviceId: Int32 = 1) throws -> Data {
        // Falls die Serialisierung fehlschlägt, bleibt der PreKey erst mal reserviert
        // und wird nach TTL (Store) wieder freigegeben. Das ist ok und verhindert Re-Use.
        let bundle = try makeOwnPreKeyBundle(deviceId: deviceId)
        let payload: [String: Any] = ["peerId": myAppId, "bundle": bundle]
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    func parseHandshakeData(_ data: Data) throws -> (peerId: String, bundle: [String: Any]) {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = obj["peerId"] as? String,
              let bundle = obj["bundle"] as? [String: Any] else {
            throw NSError(domain: "SignalEngine", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "Ungültiges Handshake-JSON"])
        }
        return (pid, bundle)
    }

    /// SHA-256 Fingerprint eines Identity-PublicKeys (hex)
    func fingerprint(from identityData: Data) -> String {
        let hash = SHA256.hash(data: identityData)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Fingerprint deiner eigenen Identity
    func myFingerprint() -> String {
        fingerprint(from: myIdentity.publicKey.serialize())
    }

    // MARK: - Session-Aufbau mit dem Peer (persistiert über Store)

    func processPeerBundle(_ bundleJSON: [String: Any], peerId: String, deviceId: Int32 = 1) throws {
        func require<T>(_ value: T?, _ name: String) throws -> T {
            if let v = value { return v }
            throw NSError(domain: "SignalEngine", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Ungültiges Bundle – Feld fehlt/ungültig: \(name)"])
        }

        let registrationId = try require(u32(bundleJSON["registrationId"]), "registrationId")
        _ = registrationId // optional: prüfen/loggen

        let preKeyId       = try require(u32(bundleJSON["preKeyId"]), "preKeyId")
        let signedPreKeyId = try require(u32(bundleJSON["signedPreKeyId"]), "signedPreKeyId")
        let kyberPreKeyId  = try require(u32(bundleJSON["kyberPreKeyId"]), "kyberPreKeyId")

        let preKeyData       = try require(b64(bundleJSON["preKey"]), "preKey")
        let spkData          = try require(b64(bundleJSON["signedPreKey"]), "signedPreKey")
        let spkSig           = try require(b64(bundleJSON["signedPreKeySignature"]), "signedPreKeySignature")
        let identityData     = try require(b64(bundleJSON["identity"]), "identity")
        let kyberPreKeyData  = try require(b64(bundleJSON["kyberPreKey"]), "kyberPreKey")
        let kyberPreKeySig   = try require(b64(bundleJSON["kyberPreKeySignature"]), "kyberPreKeySignature")

        let preKeyPub    = try PublicKey(preKeyData)
        let spkPub       = try PublicKey(spkData)
        let identityPub  = try PublicKey(identityData)
        let kyberPreKey  = try KEMPublicKey(kyberPreKeyData)

        let bundle = try PreKeyBundle(
            registrationId: registrationId,
            deviceId: UInt32(deviceId),
            prekeyId: preKeyId,
            prekey: preKeyPub,
            signedPrekeyId: signedPreKeyId,
            signedPrekey: spkPub,
            signedPrekeySignature: spkSig,
            identity: IdentityKey(publicKey: identityPub),
            kyberPrekeyId: kyberPreKeyId,
            kyberPrekey: kyberPreKey,
            kyberPrekeySignature: kyberPreKeySig
        )

        let addr = try ProtocolAddress(name: peerId, deviceId: UInt32(deviceId))

        // Das baut/aktualisiert die Session *persistiert* im Store.
        // Wir sind hier der SENDER → Remote-Bundle verarbeiten (kein lokaler PreKey-Verbrauch nötig).
        try processPreKeyBundle(bundle,
                                for: addr,
                                sessionStore: store,
                                identityStore: store,
                                context: ctx,
                                usePqRatchet: true)
    }

    // MARK: - Encrypt / Decrypt

    struct CipherWire: Codable {
        let mt: Int   // MessageType
        let ct: String // base64(serialized CiphertextMessage)
    }

    func encryptEnvelope(to peerId: String, inner: [String: Any]) throws -> CipherWire {
        let addr = try ProtocolAddress(name: peerId, deviceId: 1)
        let plain = try JSONSerialization.data(withJSONObject: inner)
        let c = try signalEncrypt(message: plain,
                                  for: addr,
                                  sessionStore: store,
                                  identityStore: store,
                                  context: ctx)

        return CipherWire(
            mt: Int(c.messageType.rawValue),
            ct: c.serialize().base64EncodedString()
        )
    }

    func decryptEnvelope(from senderId: String, wire: CipherWire) throws -> [String: Any] {
        let addr = try ProtocolAddress(name: senderId, deviceId: 1)
        let raw = Data(base64Encoded: wire.ct)!

        let plain: Data
        if wire.mt == CiphertextMessage.MessageType.preKey.rawValue {
            // Erste Nachricht der Session (nutzt unseren One-Time-PreKey).
            // Libsignal ruft dabei auf unserem Store intern `removePreKey(id:)` → endgültiger Verbrauch.
            let pre = try PreKeySignalMessage(bytes: raw)
            plain = try signalDecryptPreKey(message: pre,
                                            from: addr,
                                            sessionStore: store,
                                            identityStore: store,
                                            preKeyStore: store,
                                            signedPreKeyStore: store,
                                            kyberPreKeyStore: store,
                                            context: ctx,
                                            usePqRatchet: true)

            // Optionaler Sicherheitsgurt: falls die Lib die ID exponiert, einmal hart konsumieren.
            // (Kein Problem, wenn der Datensatz schon weg ist.)
            if let preId = try pre.preKeyId() {
                try? store.consumePreKey(id: preId, context: ctx)
            }

            // Nachschub sicherstellen
            try? store.ensurePreKeyBatch(context: ctx)
            try? store.ensureKyberPreKey(context: ctx)
        } else {
            // Folge-Nachrichten (normale Double-Ratchet)
            let sig = try SignalMessage(bytes: raw)
            plain = try signalDecrypt(message: sig,
                                      from: addr,
                                      sessionStore: store,
                                      identityStore: store,
                                      context: ctx)
        }

        let obj = try JSONSerialization.jsonObject(with: plain, options: [])
        guard let inner = obj as? [String: Any] else {
            throw NSError(domain: "SignalEngine", code: -20,
                          userInfo: [NSLocalizedDescriptionKey: "Unerwartetes Plaintext-Format"])
        }
        return inner
    }
}

// MARK: - Hilfsfunktionen
private func u32(_ any: Any?) -> UInt32? {
    switch any {
    case let v as UInt32: return v
    case let v as UInt:   return UInt32(v)
    case let v as Int:    return UInt32(v)
    case let v as Int32:  return UInt32(bitPattern: v)
    case let v as NSNumber: return v.uint32Value
    default: return nil
    }
}

private func b64(_ any: Any?) -> Data? {
    guard let s = any as? String else { return nil }
    return Data(base64Encoded: s)
}
