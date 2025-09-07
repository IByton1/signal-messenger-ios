import SwiftUI
import UniformTypeIdentifiers

struct ChangeUnlockPatternView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentInput: [Int] = []
    @State private var serverHost: String = UserDefaults.standard.string(forKey: "customServerHost") ?? ""
    @State private var usePinning: Bool = UserDefaults.standard.bool(forKey: "useCertificatePinning")
    @State private var certificateData: Data? = UserDefaults.standard.data(forKey: "pinnedCertificateData")
    @State private var certificateName: String = UserDefaults.standard.string(forKey: "pinnedCertificateName") ?? ""
    @State private var showingFileImporter = false

    var body: some View {
        VStack {
            Text("Neues Entsperrmuster")
                .font(.title2)
                .padding(.top)

            TextField("Server-Host", text: $serverHost)
                .textFieldStyle(.roundedBorder)
                .foregroundColor(.black)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding()

            Toggle("Zertifikat-Pinning", isOn: $usePinning)
                .padding(.horizontal)

            if usePinning {
                Button(certificateName.isEmpty ? "Zertifikat auswählen" : certificateName) {
                    showingFileImporter = true
                }
                .padding(.horizontal)
                .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.data]) { result in
                    switch result {
                    case .success(let urls):
                        if let url = urls.first, let data = try? Data(contentsOf: url) {
                            certificateData = data
                            certificateName = url.lastPathComponent
                        }
                    case .failure(let error):
                        print("❌ Datei laden fehlgeschlagen:", error.localizedDescription)
                    }
                }
            }

            Spacer()

            GeometryReader { geo in
                let size = geo.size
                let buttonSize = CGSize(width: size.width / 3, height: size.height / 3)

                VStack(spacing: 0) {
                    ForEach(0..<3) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<3) { col in
                                let index = row * 3 + col
                                Rectangle()
                                    .foregroundStyle(.black)
                                    .frame(width: buttonSize.width, height: buttonSize.height)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        handleTap(index)
                                    }
                                    .overlay(
                                        Text(currentInput.contains(index) ? "●" : "")
                                            .foregroundStyle(.white)
                                            .font(.title)
                                    )
                            }
                        }
                    }
                }
            }

            Spacer()

            Button("Zurücksetzen") {
                currentInput.removeAll()
            }
            .padding(.bottom)

            Button("Speichern") {
                save()
            }
            .disabled(currentInput.count != 4)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color.black)
        .foregroundColor(.white)
        .navigationTitle("Muster ändern")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func handleTap(_ index: Int) {
        guard !currentInput.contains(index), currentInput.count < 4 else { return }
        currentInput.append(index)
    }

    private func save() {
        guard currentInput.count == 4 else { return }
        do {
            try UnlockManager.savePattern(currentInput)
            UserDefaults.standard.set(serverHost, forKey: "customServerHost")
            UserDefaults.standard.set(usePinning, forKey: "useCertificatePinning")
            if usePinning, let data = certificateData {
                UserDefaults.standard.set(data, forKey: "pinnedCertificateData")
                UserDefaults.standard.set(certificateName, forKey: "pinnedCertificateName")
            } else {
                UserDefaults.standard.removeObject(forKey: "pinnedCertificateData")
                UserDefaults.standard.removeObject(forKey: "pinnedCertificateName")
            }
            dismiss()
        } catch {
            print("❌ Muster-Speichern fehlgeschlagen:", error.localizedDescription)
        }
    }
}
