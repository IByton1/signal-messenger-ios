import Foundation
import KeychainAccess

@MainActor
final class LicenseManager: ObservableObject {
    @Published var isLicensed: Bool? = nil
    private let deviceIdKey = "device_id"
    private let client = LicenseClient()

    private func getOrCreateDeviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) {
            return existing
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: deviceIdKey)
            return newId
        }
    }

    @MainActor
    func checkLicense() {
        Task {
            let deviceId = getOrCreateDeviceId()
            do {
                let ok = try await client.checkNow(deviceId: deviceId)
                isLicensed = ok
            } catch {
                isLicensed = false
                print("❌ Lizenzprüfung fehlgeschlagen: \(error)")
            }
        }
    }
}
