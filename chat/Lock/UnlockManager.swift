import Foundation
import CryptoKit
import CommonCrypto
import KeychainAccess

enum UnlockManager {

    // MARK: – Konstanten
    private static let keychain = Keychain(service: "com.safechat.unlock")
        .accessibility(.whenUnlockedThisDeviceOnly)

    private static let hashKey       = "patternHash_v1"
    private static let saltKey       = "patternSalt_v1"
    private static let iterKey       = "patternIter_v1"
    private static let defaultIter   = 120_000

    // MARK: – Öffentliche API

    /// Speichert ein neues Muster sicher in der Keychain (gehashed via PBKDF2)
    static func savePattern(_ pattern: [Int]) throws {
        let pwd  = patternString(pattern)
        let salt = try newOrExistingSalt()
        let hash = try pbkdf2(password: pwd, salt: salt, iterations: defaultIter)

        try keychain.set(hash, key: hashKey)
        try keychain.set(salt, key: saltKey)
        try keychain.set("\(defaultIter)", key: iterKey)
    }

    /// Beim App-Start aufrufen, legt Default-Muster „0,2,6,8“ an, falls noch nichts existiert
    static func bootstrapIfNeeded() {
        guard (try? keychain.getData(hashKey)) == nil else { return }
        try? savePattern([0, 2, 6, 8])
    }

    /// Verifiziert das Muster gegen gespeicherten Hash (true = korrekt, false = falsch)
    static func verify(pattern: [Int]) -> Bool {
        guard
            let salt  = try? keychain.getData(saltKey),
            let hash  = try? keychain.getData(hashKey),
            let iterS = try? keychain.get(iterKey),
            let iter  = Int(iterS ?? "")
        else {
            return false
        }

        let pwd = patternString(pattern)
        guard let candidate = try? pbkdf2(password: pwd, salt: salt, iterations: iter) else {
            return false
        }

        return constantTimeCompare(candidate, hash)
    }

    // MARK: – Interne Helfer

    private static func patternString(_ p: [Int]) -> String {
        p.map(String.init).joined(separator: ",")
    }

    private static func newOrExistingSalt() throws -> Data {
        if let s = try keychain.getData(saltKey) { return s }
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        return salt
    }

    private static func pbkdf2(password: String, salt: Data, iterations: Int,
                               keyLength: Int = 32) throws -> Data {
        let pwdData = Data(password.utf8)
        var derived = Data(repeating: 0, count: keyLength)
        let result = derived.withUnsafeMutableBytes { dPtr in
            salt.withUnsafeBytes { sPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     password, pwdData.count,
                                     sPtr.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     UInt32(iterations),
                                     dPtr.bindMemory(to: UInt8.self).baseAddress!, keyLength)
            }
        }
        guard result == kCCSuccess else {
            throw NSError(domain: "PBKDF2", code: Int(result))
        }
        return derived
    }

    private static func constantTimeCompare(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<lhs.count {
            difference |= lhs[i] ^ rhs[i]
        }
        return difference == 0
    }
}
