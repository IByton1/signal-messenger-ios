# Chat iOS App

Diese App ist eine experimentelle Ende-zu-Ende verschlüsselte Chat-Anwendung für iOS. Sie kommuniziert mit einem eigenen Node.js‑Server und nutzt ein selbst signiertes Zertifikat.

## Voraussetzungen

- macOS mit [Xcode](https://developer.apple.com/xcode/)
- [CocoaPods](https://cocoapods.org/)
- Ein laufender Server aus dem Projekt [chat-server](https://github.com/IByton1/chat-server)

## Server einrichten

1. Repository klonen und Skript ausführen (siehe README des Server‑Projekts):
   ```bash
   git clone https://github.com/IByton1/chat-server.git
   cd chat-server
   ./install_pi_local.sh   # oder install_pi_public.sh
   ```
2. Nach dem Start befindet sich das generierte Zertifikat unter `ssl/certificate.crt` auf dem Server.

## Zertifikat und IP in der App anpassen

1. Zertifikat in Base64 umwandeln:
   ```bash
   base64 -w 0 ssl/certificate.crt > certificate.base64
   ```
   Kopiere den gesamten Inhalt der Datei `certificate.base64`.
2. Öffne die Datei [`chat/Info.plist`](chat/Info.plist) und ersetze die Werte:
   - `CHAT_HTTP_BASE_URL` → `https://<SERVER-IP>:3000`
   - `LICENSE_BASE_URL`  → `https://<SERVER-IP>:4000`
   - `PUSH_SOCKET_URL`   → `wss://<SERVER-IP>:3000`
   - `PINNED_CERT_BASE64` → base64‑String aus Schritt 1
3. Stelle sicher, dass die IP-Adresse (`<SERVER-IP>`) mit der IP deines Servers übereinstimmt.

## App installieren und starten

1. Abhängigkeiten installieren:
   ```bash
   pod install
   ```
2. Öffne `chat.xcworkspace` in Xcode.
3. Wähle dein Team für das Codesigning und starte die App auf einem Gerät oder Simulator.

## Hinweise

- Ports `3000` (HTTP/Socket) und `4000` (Lizenzserver) müssen vom iOS-Gerät aus erreichbar sein.
- Bei Änderungen am Zertifikat muss der Base64‑String in `Info.plist` aktualisiert werden.

Viel Erfolg beim Ausprobieren! ✨
