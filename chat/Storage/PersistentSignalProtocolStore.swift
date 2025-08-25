import Foundation
import LibSignalClient
import GRDB
import KeychainAccess
import Security

public final class PersistentSignalProtocolStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore, SessionStore, SenderKeyStore {
    public struct Context: StoreContext {}
    public enum TrustLevel: Int { case untrusted = 0, trusted = 1, changed = 2 }

    private let dbQueue: DatabaseQueue
    private let keychain: Keychain
    private let identity: IdentityKeyPair
    private let registrationId: UInt32

    // PreKey-Pool
    private let minPreKeys = 20          // Mindestanzahl *freier* PreKeys (nicht reserviert)
    private let maxPreKeys = 100         // Obergrenze gesamt (frei + reserviert)

    // Reservierungs-Politik
    private let reservationTTLms: Int64 = 10 * 60 * 1000 // 10 Minuten

    private let preKeyIdOffset: UInt32
    private let kyberPreKeyOffset: UInt32
    
    // Signed PreKey Rotation
    private let signedPreKeyMaxAge: TimeInterval = 30 * 24 * 60 * 60
    private let signedPreKeysToKeep = 3

    public init(identity: IdentityKeyPair, registrationId: UInt32) throws {
        self.keychain = Keychain(service: "SignalChatKeys")
            .accessibility(.whenUnlockedThisDeviceOnly)
        self.identity = identity
        self.registrationId = registrationId
        self.preKeyIdOffset = try Self.preKeyIdOffset(keychain: keychain)
        self.kyberPreKeyOffset = try Self.kyberPreKeyIdOffset(keychain: keychain)

        // Persist Identity & RegistrationId
        var idData = identity.serialize()
        try keychain.set(idData, key: "identityKeyPair")
        idData.wipe()
        try keychain.set(Data(from: registrationId), key: "registrationId")

        _ = try Self.dbKey(keychain: keychain)

        let url = try Self.databaseURL()
        var config = Configuration()

        let kc = self.keychain
        config.prepareDatabase { db in
            guard let key = try kc.getData("dbKey") else {
                throw NSError(
                    domain: "PersistentSignalProtocolStore",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing dbKey in Keychain"]
                )
            }
            let hex = key.map { String(format: "%02x", $0) }.joined()
            try db.execute(sql: "PRAGMA key = \"x'\(hex)'\"")
        }

        self.dbQueue = try DatabaseQueue(path: url.path, configuration: config)

        try Self.migrator.migrate(dbQueue)

        try ensureSignedPreKey(context: Context())
        try ensurePreKeyBatch(context: Context())
        try ensureKyberPreKey(context: Context())
        try ensureSignedPreKeyRotation(context: Context())
    }

    private static func preKeyIdOffset(keychain: Keychain) throws -> UInt32 {
        let key = "preKeyOffset"
        if let data = try keychain.getData(key) {
            return data.toUInt32()
        }
        let offset = UInt32.random(in: 1_000_000...4_000_000)
        try keychain.set(Data(from: offset), key: key)
        return offset
    }

    private static func kyberPreKeyIdOffset(keychain: Keychain) throws -> UInt32 {
        let key = "kyberPreKeyOffset"
        if let data = try keychain.getData(key) {
            return data.toUInt32()
        }
        let offset = UInt32.random(in: 5_000_000...8_000_000)
        try keychain.set(Data(from: offset), key: key)
        return offset
    }

    // MARK: - DB/Key Material

    private static func databaseURL() throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("SignalChat", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("keys.db")
    }

    private static func dbKey(keychain: Keychain) throws -> Data {
        if let data = try keychain.getData("dbKey") { return data }
        var key = Data(count: 32)
        _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        try keychain.set(key, key: "dbKey")
        return key
    }

    private static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()
        // initial schema
        m.registerMigration("create") { db in
            try db.create(table: "identities") { t in
                t.column("name", .text).notNull()
                t.column("deviceId", .integer).notNull()
                t.column("publicKey", .blob).notNull()
                t.column("trustLevel", .integer).notNull().defaults(to: TrustLevel.trusted.rawValue)
                t.primaryKey(["name", "deviceId"])
            }
            try db.create(table: "prekeys") { t in
                t.column("id", .integer).primaryKey()
                t.column("record", .blob).notNull()
                // ab v2: reserved/reserved_at
            }
            try db.create(table: "signed_prekeys") { t in
                t.column("id", .integer).primaryKey()
                t.column("record", .blob).notNull()
            }
            try db.create(table: "kyber_prekeys") { t in
                t.column("id", .integer).primaryKey()
                t.column("record", .blob).notNull()
                t.column("used", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "sessions") { t in
                t.column("name", .text).notNull()
                t.column("deviceId", .integer).notNull()
                t.column("record", .blob).notNull()
                t.primaryKey(["name", "deviceId"])
            }
            try db.create(table: "sender_keys") { t in
                t.column("name", .text).notNull()
                t.column("deviceId", .integer).notNull()
                t.column("distributionId", .text).notNull()
                t.column("record", .blob).notNull()
                t.primaryKey(["name", "deviceId", "distributionId"])
            }
        }
        // v2: Reservierungen (fix gegen PreKey-Reuse)
        m.registerMigration("prekey_reservations_v2") { db in
            try db.alter(table: "prekeys") { t in
                t.add(column: "reserved", .boolean).notNull().defaults(to: false)
                t.add(column: "reserved_at", .integer) // ms since epoch; NULL wenn nicht reserviert
            }
        }
        return m
    }()

    // MARK: - Identity

    public func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair { identity }
    public func localRegistrationId(context: StoreContext) throws -> UInt32 { registrationId }

    public func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> IdentityChange {
        try dbQueue.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT publicKey,trustLevel FROM identities WHERE name=? AND deviceId=?", arguments: [address.name, address.deviceId])
            var change: IdentityChange = .newOrUnchanged
            var level = TrustLevel.trusted
            if let row = row, let existing = try? IdentityKey(bytes: row["publicKey"] as Data) {
                level = TrustLevel(rawValue: row["trustLevel"] as Int) ?? .untrusted
                if existing != identity {
                    change = .replacedExisting
                    level = .changed
                }
            }
            var data = identity.serialize()
            try db.execute(sql: "REPLACE INTO identities(name,deviceId,publicKey,trustLevel) VALUES (?,?,?,?)",
                           arguments: [address.name, address.deviceId, data, level.rawValue])
            data.wipe()
            return change
        }
    }

    public func isTrustedIdentity(_ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext) throws -> Bool {
        return try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT publicKey,trustLevel FROM identities WHERE name=? AND deviceId=?", arguments: [address.name, address.deviceId]) {
                var data = row["publicKey"] as Data
                defer { data.wipe() }
                guard let stored = try? IdentityKey(bytes: data) else { return false }
                let level = TrustLevel(rawValue: row["trustLevel"] as Int) ?? .untrusted
                return stored == identity && level == .trusted
            }
            return true
        }
    }

    public func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        return try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT publicKey FROM identities WHERE name=? AND deviceId=?", arguments: [address.name, address.deviceId]) {
                var data = row["publicKey"] as Data
                defer { data.wipe() }
                return try? IdentityKey(bytes: data)
            }
            return nil
        }
    }

    public func setTrust(_ level: TrustLevel, for address: ProtocolAddress, context: StoreContext) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE identities SET trustLevel=? WHERE name=? AND deviceId=?",
                           arguments: [level.rawValue, address.name, address.deviceId])
        }
    }

    // MARK: - One-time PreKeys (Reservieren, Verbrauch, Nachlegen)

    /// Deterministisch kleinste freie ID auswählen **und reservieren**.
    public func reserveNextPreKey(context: StoreContext) throws -> (UInt32, PreKeyRecord) {
        return try dbQueue.write { db in
            try expireStaleReservations(db: db)

            if let row = try Row.fetchOne(db, sql: "SELECT id,record FROM prekeys WHERE reserved=0 ORDER BY id LIMIT 1") {
                let id = UInt32(row["id"] as Int64)
                var data = row["record"] as Data
                defer { data.wipe() }
                try db.execute(sql: "UPDATE prekeys SET reserved=1, reserved_at=? WHERE id=?", arguments: [nowMs(), id])
                return (id, try PreKeyRecord(bytes: data))
            }

            // keine freien → nachlegen
            try generatePreKeysIfNeeded(db: db, forceMax: false)

            guard let row = try Row.fetchOne(db, sql: "SELECT id,record FROM prekeys WHERE reserved=0 ORDER BY id LIMIT 1") else {
                throw SignalError.invalidKeyIdentifier("no prekeys available after replenish")
            }
            let id = UInt32(row["id"] as Int64)
            var data = row["record"] as Data
            defer { data.wipe() }
            try db.execute(sql: "UPDATE prekeys SET reserved=1, reserved_at=? WHERE id=?", arguments: [nowMs(), id])
            return (id, try PreKeyRecord(bytes: data))
        }
    }

    /// Reservierung aufheben (z. B. wenn Handshake nicht zustande kam).
    public func unreservePreKey(id: UInt32, context: StoreContext) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE prekeys SET reserved=0, reserved_at=NULL WHERE id=?", arguments: [id])
        }
    }

    /// Verbrauchen (= endgültig löschen) und ggf. nachlegen.
    public func consumePreKey(id: UInt32, context: StoreContext) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM prekeys WHERE id=?", arguments: [id])
            try generatePreKeysIfNeeded(db: db)
        }
    }

    /// *Nur lesen* (legacy) – reserviert **nicht**.
    public func nextPreKey(context: StoreContext) throws -> (UInt32, PreKeyRecord) {
        return try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT id,record FROM prekeys ORDER BY id LIMIT 1") else {
                throw SignalError.invalidKeyIdentifier("no prekeys available")
            }
            var data = row["record"] as Data
            defer { data.wipe() }
            let id = UInt32(row["id"] as Int64)
            return (id, try PreKeyRecord(bytes: data))
        }
    }

    public func ensurePreKeyBatch(context: StoreContext) throws {
        try dbQueue.write { db in
            try generatePreKeysIfNeeded(db: db)
        }
    }

    public func rotatePreKeys(context: StoreContext) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM prekeys")
            try generatePreKeysIfNeeded(db: db, forceMax: true)
        }
    }

    private func generatePreKeysIfNeeded(db: Database, forceMax: Bool = false) throws {
        try expireStaleReservations(db: db)

        let totalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM prekeys") ?? 0
        let freeCount  = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM prekeys WHERE reserved=0") ?? 0

        let targetFree = forceMax ? maxPreKeys : minPreKeys
        let needByFree = max(0, targetFree - freeCount)
        let roomByMax  = max(0, maxPreKeys - totalCount)
        let need = min(needByFree, roomByMax)
        if need == 0 { return }

        let maxId = try Int.fetchOne(db, sql: "SELECT IFNULL(MAX(id),0) FROM prekeys") ?? 0
        var nextId = Int(preKeyIdOffset) + maxId + 1

        for _ in 0..<need {
            let priv = PrivateKey.generate()
            let rec = try PreKeyRecord(id: UInt32(nextId), privateKey: priv)
            var data = rec.serialize()
            try db.execute(sql: "INSERT INTO prekeys(id,record,reserved,reserved_at) VALUES (?,?,0,NULL)", arguments: [nextId, data])
            data.wipe()
            nextId += 1
        }
    }

    private func expireStaleReservations(db: Database) throws {
        let cutoff = nowMs() - reservationTTLms
        try db.execute(sql: "UPDATE prekeys SET reserved=0, reserved_at=NULL WHERE reserved=1 AND reserved_at < ?", arguments: [cutoff])
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - PreKeyStore

    public func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        return try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT record FROM prekeys WHERE id=?", arguments: [id]) else {
                throw SignalError.invalidKeyIdentifier("no prekey with this identifier")
            }
            var data = row["record"] as Data
            defer { data.wipe() }
            return try PreKeyRecord(bytes: data)
        }
    }

    public func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try dbQueue.write { db in
            var data = record.serialize()
            // neu: als frei anlegen
            try db.execute(sql: "REPLACE INTO prekeys(id,record,reserved,reserved_at) VALUES (?,?,0,NULL)", arguments: [id, data])
            data.wipe()
        }
    }

    public func removePreKey(id: UInt32, context: StoreContext) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM prekeys WHERE id=?", arguments: [id])
            try generatePreKeysIfNeeded(db: db)
        }
    }

    // MARK: - SignedPreKeys

    public func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        return try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT record FROM signed_prekeys WHERE id=?", arguments: [id]) else {
                throw SignalError.invalidKeyIdentifier("no signed prekey with this identifier")
            }
            var data = row["record"] as Data
            defer { data.wipe() }
            return try SignedPreKeyRecord(bytes: data)
        }
    }

    public func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try dbQueue.write { db in
            var data = record.serialize()
            try db.execute(sql: "REPLACE INTO signed_prekeys(id,record) VALUES (?,?)", arguments: [id, data])
            data.wipe()
        }
    }

    // MARK: - Kyber (PQ) PreKeys

    public func nextUnusedKyberPreKey(context: StoreContext) throws -> (UInt32, KyberPreKeyRecord) {
        return try dbQueue.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT id,record FROM kyber_prekeys WHERE used=0 ORDER BY id LIMIT 1") {
                var data = row["record"] as Data
                defer { data.wipe() }
                let id = UInt32(row["id"] as Int64)
                return (id, try KyberPreKeyRecord(bytes: data))
            }
            let (id, rec) = try generateOneKyberPreKey(db: db)
            return (id, rec)
        }
    }

    public func markKyberPreKeyUsedAndReplace(id: UInt32, context: StoreContext) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE kyber_prekeys SET used=1 WHERE id=?", arguments: [id])
            _ = try generateOneKyberPreKey(db: db)
        }
    }

    public func ensureKyberPreKey(context: StoreContext) throws {
        _ = try nextUnusedKyberPreKey(context: context)
    }

    public func ensureSignedPreKey(id: UInt32 = 1, context: StoreContext) throws {
        if (try? loadSignedPreKey(id: id, context: context)) != nil { return }

        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        let privKey = PrivateKey.generate()
        let pubKey  = privKey.publicKey
        let sig = identity.privateKey.generateSignature(message: pubKey.serialize())

        let spk = try SignedPreKeyRecord(
            id: id,
            timestamp: ts,
            privateKey: privKey,
            signature: sig
        )

        try storeSignedPreKey(spk, id: id, context: context)
    }

    private func generateOneKyberPreKey(db: Database) throws -> (UInt32, KyberPreKeyRecord) {
        let maxId = try Int.fetchOne(db, sql: "SELECT IFNULL(MAX(id),0) FROM kyber_prekeys") ?? 0
        let newId = kyberPreKeyOffset + UInt32(maxId + 1)
        let kp = KEMKeyPair.generate()
        let sig = identity.privateKey.generateSignature(message: kp.publicKey.serialize())
        let rec = try KyberPreKeyRecord(
            id: newId,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            keyPair: kp,
            signature: sig
        )
        var data = rec.serialize()
        try db.execute(sql: "INSERT INTO kyber_prekeys(id,record,used) VALUES (?,?,0)", arguments: [newId, data])
        data.wipe()
        return (newId, rec)
    }

    public func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        return try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT record FROM kyber_prekeys WHERE id=?", arguments: [id]) else {
                throw SignalError.invalidKeyIdentifier("no kyber prekey with this identifier")
            }
            var data = row["record"] as Data
            defer { data.wipe() }
            return try KyberPreKeyRecord(bytes: data)
        }
    }

    public func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try dbQueue.write { db in
            var data = record.serialize()
            try db.execute(sql: "REPLACE INTO kyber_prekeys(id,record,used) VALUES (?,?,0)", arguments: [id, data])
            data.wipe()
        }
    }

    public func markKyberPreKeyUsed(id: UInt32, context: StoreContext) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE kyber_prekeys SET used=1 WHERE id=?", arguments: [id])
        }
    }

    // MARK: - Sessions

    public func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        return try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT record FROM sessions WHERE name=? AND deviceId= ?", arguments: [address.name, address.deviceId]) {
                var data = row["record"] as Data
                defer { data.wipe() }
                return try SessionRecord(bytes: data)
            }
            return nil
        }
    }

    public func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        return try addresses.map { address in
            if let rec = try loadSession(for: address, context: context) {
                return rec
            }
            throw SignalError.sessionNotFound("\(address)")
        }
    }

    public func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        try dbQueue.write { db in
            var data = record.serialize()
            try db.execute(sql: "REPLACE INTO sessions(name,deviceId,record) VALUES (?,?,?)", arguments: [address.name, address.deviceId, data])
            data.wipe()
        }
    }

    // MARK: - Sender Keys (Gruppen)

    public func storeSenderKey(from sender: ProtocolAddress, distributionId: UUID, record: SenderKeyRecord, context: StoreContext) throws {
        try dbQueue.write { db in
            var data = record.serialize()
            try db.execute(sql: "REPLACE INTO sender_keys(name,deviceId,distributionId,record) VALUES (?,?,?,?)",
                           arguments: [sender.name, sender.deviceId, distributionId.uuidString, data])
            data.wipe()
        }
    }

    public func loadSenderKey(from sender: ProtocolAddress, distributionId: UUID, context: StoreContext) throws -> SenderKeyRecord? {
        return try dbQueue.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT record FROM sender_keys WHERE name=? AND deviceId= ? AND distributionId=?",
                                          arguments: [sender.name, sender.deviceId, distributionId.uuidString]) {
                var data = row["record"] as Data
                defer { data.wipe() }
                return try SenderKeyRecord(bytes: data)
            }
            return nil
        }
    }
    
    // MARK: - SignedPreKey Rotation (30 Tage)

    private func currentSignedPreKey(context: StoreContext) throws -> (UInt32, SignedPreKeyRecord) {
        return try dbQueue.read { db in
            guard let row = try Row.fetchOne(db,
                    sql: "SELECT id,record FROM signed_prekeys ORDER BY id DESC LIMIT 1")
            else {
                throw SignalError.invalidKeyIdentifier("no signed prekey available")
            }
            var data = row["record"] as Data
            defer { data.wipe() }
            let rec = try SignedPreKeyRecord(bytes: data)
            let id  = UInt32(row["id"] as Int64)
            return (id, rec)
        }
    }

    public func rotateSignedPreKey(context: StoreContext) throws {
        try dbQueue.write { db in
            let maxId = try Int.fetchOne(db, sql: "SELECT IFNULL(MAX(id),0) FROM signed_prekeys") ?? 0
            let newId = UInt32(maxId + 1)

            let ts = UInt64(Date().timeIntervalSince1970 * 1000)
            let priv = PrivateKey.generate()
            let pub  = priv.publicKey
            let sig  = identity.privateKey.generateSignature(message: pub.serialize())

            let spk = try SignedPreKeyRecord(
                id: newId,
                timestamp: ts,
                privateKey: priv,
                signature: sig
            )
            var data = spk.serialize()
            try db.execute(sql: "INSERT INTO signed_prekeys(id,record) VALUES (?,?)",
                           arguments: [newId, data])
            data.wipe()

            // Alte SPKs aufräumen, aber einige behalten
            let rows = try Row.fetchAll(db,
                sql: "SELECT id FROM signed_prekeys ORDER BY id DESC LIMIT ?",
                arguments: [signedPreKeysToKeep])
            let idsToKeep = rows.compactMap { Int($0["id"] as Int64) }
            if let minKeep = idsToKeep.min() {
                try db.execute(sql: "DELETE FROM signed_prekeys WHERE id < ?", arguments: [minKeep])
            }
        }
    }

    public func ensureSignedPreKeyRotation(context: StoreContext) throws {
        if (try? currentSignedPreKey(context: context)) == nil {
            try ensureSignedPreKey(context: context) // erzeugt ID 1
            return
        }
        let (_, spk) = try currentSignedPreKey(context: context)
        let ageSec = Date().timeIntervalSince1970 - (Double(spk.timestamp) / 1000.0)
        if ageSec >= signedPreKeyMaxAge {
            try rotateSignedPreKey(context: context)
        }
    }
}

// MARK: - Helpers

private extension Data {
    init(from value: UInt32) {
        var v = value
        self.init(bytes: &v, count: MemoryLayout<UInt32>.size)
    }
    func toUInt32() -> UInt32 {
        withUnsafeBytes { $0.load(as: UInt32.self) }
    }
    mutating func wipe() {
        resetBytes(in: 0..<count)
    }
}

public extension IdentityKeyPair {
    static func loadOrGenerateFromKeychain() throws -> IdentityKeyPair {
        let keychain = Keychain(service: "SignalChatKeys")
            .accessibility(.whenUnlockedThisDeviceOnly)
        if let data = try keychain.getData("identityKeyPair") {
            var d = data
            defer { d.wipe() }
            if let pair = try? IdentityKeyPair(bytes: d) { return pair }
        }
        let pair = IdentityKeyPair.generate()
        var ser = pair.serialize()
        try keychain.set(ser, key: "identityKeyPair")
        ser.wipe()
        return pair
    }
}

public extension UInt32 {
    static func loadOrGenerateRegistrationId() throws -> UInt32 {
        let keychain = Keychain(service: "SignalChatKeys")
            .accessibility(.whenUnlockedThisDeviceOnly)
        if let data = try keychain.getData("registrationId") {
            var d = data
            defer { d.wipe() }
            return d.toUInt32()
        }
        let id = UInt32.random(in: 1...0x3FFF)
        try keychain.set(Data(from: id), key: "registrationId")
        return id
    }
}
