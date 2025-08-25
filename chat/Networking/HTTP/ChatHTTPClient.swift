import Foundation

struct ChatHTTPClient {
    private let baseURL = ServerConfig.shared.httpBaseURL

    func sendEncrypted(from: String, to: String, payload: String) async throws {
        let url = baseURL.appendingPathComponent("sendEncrypted")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["from": from, "to": to, "payload": payload]
        req.httpBody = try JSONEncoder().encode(body)

        _ = try await PinnedSession.shared.data(for: req)
    }

    func fetchPending(me: String, roomId: String) async throws
        -> [(roomId: String, payload: String, timestamp: TimeInterval)]
    {
        var comps = URLComponents(string: "\(baseURL)/pending")!
        comps.queryItems = [
            URLQueryItem(name: "me",      value: me),
            URLQueryItem(name: "roomId",  value: roomId)
        ]
        let (data, _) = try await PinnedSession.shared.data(from: comps.url!)
        struct Row: Decodable {
            let roomId: String
            let payload: String
            let timestamp: TimeInterval
        }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        return rows.map { ($0.roomId, $0.payload, $0.timestamp) }
    }

    func fetchPendingCounts(me: String) async throws -> [String: Int] {
        let url = baseURL.appendingPathComponent("pending-counts")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "me", value: me)]
        let (data, _) = try await PinnedSession.shared.data(from: comps.url!)
        return try JSONDecoder().decode([String: Int].self, from: data)
    }
}
