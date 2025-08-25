import Foundation
import CryptoKit
import KeychainAccess

struct ContactStore {
    private static let key = "contacts_v1"

    // MARK: - Public API

    static func load() -> [Contact] {
        do {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            let key = try encryptionKey()
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decrypted = try AES.GCM.open(sealedBox, using: key)
            return try JSONDecoder().decode([Contact].self, from: decrypted)
        } catch {
            print("❌ [ContactStore] Laden fehlgeschlagen:", error.localizedDescription)
            return []
        }
    }

    static func save(_ contacts: [Contact]) {
        do {
            let json = try JSONEncoder().encode(contacts)
            let key = try encryptionKey()
            let sealed = try AES.GCM.seal(json, using: key)
            guard let combined = sealed.combined else {
                print("❌ [ContactStore] Kein AES combined block")
                return
            }
            UserDefaults.standard.set(combined, forKey: self.key)
        } catch {
            print("❌ [ContactStore] Speichern fehlgeschlagen:", error.localizedDescription)
        }
    }

    // MARK: - Schlüsselverwaltung

    private static func encryptionKey() throws -> SymmetricKey {
        let keychain = Keychain(service: "SignalChatKeys")
            .accessibility(.whenUnlockedThisDeviceOnly)
        let keyId = "contactEncKey"

        if let data = try keychain.getData(keyId) {
            return SymmetricKey(data: data)
        }

        let key = SymmetricKey(size: .bits256)
        let rawKey = Data(key.withUnsafeBytes { Data($0) })
        try keychain.set(rawKey, key: keyId)
        return key
    }
}
