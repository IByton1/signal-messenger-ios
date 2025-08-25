import Foundation

struct ServerConfig {
    static let shared = ServerConfig()

    let httpBaseURL: URL
    let licenseBaseURL: URL
    let socketBaseURL: URL
    let pinnedCertificateData: Data?

    init(bundle: Bundle = .main,
         env: [String: String] = ProcessInfo.processInfo.environment) {
        func url(for key: String, default defaultValue: String) -> URL {
            if let value = env[key] ?? bundle.infoDictionary?[key] as? String,
               let url = URL(string: value) {
                return url
            }
            return URL(string: defaultValue)!
        }

        httpBaseURL = url(for: "CHAT_HTTP_BASE_URL", default: "https://localhost:3000")
        licenseBaseURL = url(for: "LICENSE_BASE_URL", default: "https://localhost:4000")
        socketBaseURL = url(for: "PUSH_SOCKET_URL", default: "wss://localhost:3000")

        if let base64 = env["PINNED_CERT_BASE64"] ?? bundle.infoDictionary?["PINNED_CERT_BASE64"] as? String,
           let data = Data(base64Encoded: base64) {
            pinnedCertificateData = data
        } else {
            pinnedCertificateData = nil
        }
    }
}
