import SwiftUI
import LibSignalClient
import SignalCoreKit

@main
struct chatApp: App {
    @StateObject private var licenseManager = LicenseManager()

    var body: some Scene {
        WindowGroup {
            Group {
                switch licenseManager.isLicensed {
                case .none:
                    // Während die Prüfung läuft
                    ProgressView("Zugriffsprüfung…")
                        .task { licenseManager.checkLicense() }

                case .some(true):
                    // Gerät ist freigegeben → App starten
                    NavigationStack {
                        LaunchUnlockView()
                    }

                case .some(false):
                    // Gerät NICHT freigegeben → Fehleransicht anzeigen
                    LicenseErrorView()
                        .environmentObject(licenseManager)
                }
            }
        }
    }
}
