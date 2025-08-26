import Foundation

struct ServerConfig {
    static let shared = ServerConfig()

    let httpBaseURL: URL
    let licenseBaseURL: URL
    let socketBaseURL: URL
    let pinnedCertificateData: Data?

    init(bundle: Bundle = .main,
         env: [String: String] = ProcessInfo.processInfo.environment,
         defaults: UserDefaults = .standard) {
        func url(for key: String, default defaultValue: String) -> URL {
            if let value = env[key] ?? bundle.infoDictionary?[key] as? String,
               let url = URL(string: value) {
                return url
            }
            return URL(string: defaultValue)!
        }

        if let host = defaults.string(forKey: "customServerHost"), !host.isEmpty {
            httpBaseURL = URL(string: "https://\(host)")!
            licenseBaseURL = URL(string: "https://\(host)")!
            socketBaseURL = URL(string: "wss://\(host)")!
        } else {
            httpBaseURL = url(for: "CHAT_HTTP_BASE_URL", default: "https://chat.zeroleak.de")
            licenseBaseURL = url(for: "LICENSE_BASE_URL", default: "https://license.zeroleak.de")
            socketBaseURL = url(for: "PUSH_SOCKET_URL", default: "wss://chat.zeroleak.de")
        }

        if defaults.bool(forKey: "useCertificatePinning"),
           let data = defaults.data(forKey: "pinnedCertificateData") {
            pinnedCertificateData = data
        } else {
            pinnedCertificateData = nil
        }
    }
}
