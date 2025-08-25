import Foundation

final class PinnedSession: NSObject, URLSessionDelegate {
    static let shared = PinnedSession()

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await session.data(from: url)
    }

    func webSocketTask(with url: URL) -> URLSessionWebSocketTask {
        session.webSocketTask(with: url)
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if let cert = SecTrustGetCertificateAtIndex(serverTrust, 0) {
            let serverData = SecCertificateCopyData(cert) as Data
            if let pinnedData = ServerConfig.shared.pinnedCertificateData {
                if serverData == pinnedData {
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                    return
                } else {
                    print("❌ Zertifikat stimmt nicht überein – Abbruch.")
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
            }
        }

        completionHandler(.performDefaultHandling, nil)
    }
}
