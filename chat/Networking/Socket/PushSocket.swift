import Foundation

final class PushSocket: ObservableObject {
    static let shared = PushSocket()
    private var socket: URLSessionWebSocketTask?

    private let session = PinnedSession.shared

    func connect(userId: String) {
        guard socket == nil else { return }
        let url = ServerConfig.shared.socketBaseURL.appendingPathComponent("ws/\(userId)")
        socket = session.webSocketTask(with: url)
        socket?.resume()
        listen()
    }

    func join(room: String) {
        send(json: ["cmd": "join", "room": room])
    }

    func leave(room: String) {
        send(json: ["cmd": "leave", "room": room])
    }

    private func send(json: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(str), completionHandler: { error in
            if let error = error {
                print("❌ WS send error:", error)
            }
        })
    }

    private func listen() {
        socket?.receive { [weak self] result in
            switch result {
            case .success(.string(let str)):
                if let data = str.data(using: .utf8) {
                    NotificationCenter.default.post(name: .didReceivePush, object: data)
                }
            case .failure(let err):
                print("❌ WS Fehler:", err)
            default:
                break
            }
            self?.listen()
        }
    }
}

extension Notification.Name {
    static let didReceivePush = Notification.Name("didReceivePush")
}
