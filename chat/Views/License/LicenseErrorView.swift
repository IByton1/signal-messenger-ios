import SwiftUI

struct LicenseErrorView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text("Zugriff verweigert")
                .font(.title2.bold())
            Text("Diese App-Instanz ist nicht lizenziert.\nBitte kontaktiere den Administrator.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .padding()
    }
}
