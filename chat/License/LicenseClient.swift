import Foundation
import KeychainAccess

struct LicenseClient {
    private let baseURL = ServerConfig.shared.licenseBaseURL

    /// Sendet Anfrage an den Server: "Darf dieses Gerät die App nutzen?"
    func checkNow(deviceId: String) async throws -> Bool {
        let url = baseURL.appendingPathComponent("/api/check-now")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["deviceId": deviceId])

        let (data, response) = try await PinnedSession.shared.data(for: req)

        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            return true
        } else {
            // Optional: Log Fehlermeldung vom Server
            let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            print("Server-Antwort: \(msg?["error"] ?? "unbekannt")")
            return false
        }
    }
}
