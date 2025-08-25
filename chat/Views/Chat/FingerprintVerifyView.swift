import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins
import SignalCoreKit
import LibSignalClient

import SwiftUI
import SignalCoreKit

struct FingerprintVerifyView: View {
    let pair: FingerprintPair
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case showCode, scanOther, showOwnAfterScan, done }
    private let role: Role
    @State private var phase: Phase
    @State private var scanned: String?
    @State private var trustSet = false

    private enum Role { case showFirst, scanFirst }

    init(pair: FingerprintPair) {
        self.pair = pair
        if pair.mine < pair.peer {
            self.role = .showFirst
            _phase = State(initialValue: .showCode)
        } else {
            self.role = .scanFirst
            _phase = State(initialValue: .scanOther)
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            switch phase {
            case .showCode:
                QRCodeView(text: pair.mine)
                Text("Eigener Fingerprint")
                Button("Weiter") { phase = .scanOther }

            case .scanOther:
                QRScannerView { code in
                    scanned = code
                    if role == .showFirst {
                        phase = .done
                    } else {
                        phase = .showOwnAfterScan
                    }
                }

            case .showOwnAfterScan:
                if let scanned {
                    VStack {
                        resultText(for: scanned)
                        QRCodeView(text: pair.mine)
                        Button("Fertig") { dismiss() }
                    }
                }

            case .done:
                if let scanned {
                    resultText(for: scanned)
                }
                Button("Fertig") { dismiss() }
            }
        }
        .padding()
    }

    @ViewBuilder
    private func resultText(for scanned: String) -> some View {
        if scanned == pair.peer {
            Text("Ihre Verbindung ist jetzt sicher")
                .font(.headline)
                .foregroundColor(.green)
                .onAppear {
                    if !trustSet {
                        trustSet = true
                        setTrust()
                    }
                }
        } else {
            Text("Ihre Verbindung ist nicht sicher – keine Nachrichten senden!")
                .font(.headline)
                .foregroundColor(.red)
        }
    }

    private func setTrust() {
        do {
            let address = try ProtocolAddress(name: pair.peerId, deviceId: 1)
            try SignalEngine.shared.protocolStore.setTrust(.trusted,
                                                   for: address,
                                                   context: PersistentSignalProtocolStore.Context())
            print("🔐 Verbindung als vertrauenswürdig markiert.")
        } catch {
            print("❌ Fehler beim Setzen des Trust-Levels:", error.localizedDescription)
        }
    }
}


struct QRCodeView: View {
    let text: String
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        if let img = generate() {
            Image(uiImage: img)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
        } else {
            Text("QR Fehler")
        }
    }

    private func generate() -> UIImage? {
        let data = Data(text.utf8)
        filter.setValue(data, forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        if let cg = context.createCGImage(scaled, from: scaled.extent) {
            return UIImage(cgImage: cg)
        }
        return nil
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onFound = onFound
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onFound: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            requestCameraAccessIfNeeded()
        }

        private func requestCameraAccessIfNeeded() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted {
                        DispatchQueue.main.async { self.setupSession() }
                    }
                }
            case .authorized:
                setupSession()
            default:
                // Hier könntest du eine Fehlermeldung anzeigen
                break
            }
        }

        private func setupSession() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input  = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()

            let previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = view.bounds
            view.layer.insertSublayer(previewLayer, at: 0)
            self.preview = previewLayer

            session.startRunning()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr,
                  let str = obj.stringValue else { return }
            session.stopRunning()
            onFound?(str)
        }
    }

}

