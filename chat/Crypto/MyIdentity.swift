import Foundation
import UIKit
import KeychainAccess   // 🆕

struct MyIdentity: Codable {
    let id: String
    let name: String

    private static let keychain     = Keychain(service: "com.safechat.identity")
        .accessibility(.whenUnlockedThisDeviceOnly)
    private static let keychainKey  = "my_identity_v1"
    private static let legacyUDKey  = "my_identity_v1"

    /// Lädt die Identität aus der Keychain oder erzeugt sie neu.
    static func loadOrCreate() -> MyIdentity {
        if let data = try? keychain.getData(keychainKey),
           let saved = try? JSONDecoder().decode(MyIdentity.self, from: data) {
            return saved
        }

        if let udData = UserDefaults.standard.data(forKey: legacyUDKey),
           let legacy = try? JSONDecoder().decode(MyIdentity.self, from: udData) {
            _ = try? keychain.set(udData, key: keychainKey)   // in Keychain sichern
            UserDefaults.standard.removeObject(forKey: legacyUDKey)
            return legacy
        }

        let fresh = MyIdentity(id: UUID().uuidString,
                               name: UIDevice.current.name)
        if let encoded = try? JSONEncoder().encode(fresh) {
            _ = try? keychain.set(encoded, key: keychainKey)
        }
        return fresh
    }
}
