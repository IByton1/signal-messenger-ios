//
//  SignalEngineTests.swift
//  chatTests
//
//  Created by Maurice Herold on 30.07.25.
//

import Testing
import XCTest
import XCTest
@testable import chat

final class SignalEngineTests: XCTestCase {

    func testEncryptAndDecryptBetweenTwoEngines() throws {
        // Erzeuge zwei unabhängige SignalEngine-Instanzen
        let alice = SignalEngine()
        let bob = SignalEngine()

        // Schritt 1: Austausch der öffentlichen PreKeyBundles
        let aliceBundle = try alice.makeOwnPreKeyBundle(deviceId: 1)
        try bob.processPeerBundle(aliceBundle, peerId: "alice", deviceId: 1)

        let bobBundle = try bob.makeOwnPreKeyBundle(deviceId: 1)
        try alice.processPeerBundle(bobBundle, peerId: "bob", deviceId: 1)

        // Schritt 2: Alice verschlüsselt eine Nachricht an Bob
        let originalMessage: [String: Any] = [
            "type": "text",
            "text": "Hallo Bob!"
        ]
        let encrypted = try alice.encryptEnvelope(to: "bob", inner: originalMessage)

        // Schritt 3: Bob entschlüsselt die empfangene Nachricht
        let decrypted = try bob.decryptEnvelope(from: "alice", wire: encrypted)

        // Schritt 4: Vergleiche Klartextdaten
        XCTAssertEqual(decrypted["type"] as? String, "text")
        XCTAssertEqual(decrypted["text"] as? String, "Hallo Bob!")
    }
}
