import SwiftUI
import AVFoundation

public struct ISBNScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScanned: (String) -> Void

    public init(onScanned: @escaping (String) -> Void) {
        self.onScanned = onScanned
    }

    public var body: some View {
        ZStack {
            CameraScannerView(onScanned: { code in
                onScanned(code)
                dismiss()
            })
            .ignoresSafeArea()

            // Simple overlay with guidance
            VStack {
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .padding(12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding()
                }
                Spacer()
                Text("Align the ISBN barcode within the frame")
                    .padding(12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 40)
            }

            // Framing rectangle
            Rectangle()
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 280, height: 180)
        }
        .preferredColorScheme(.dark)
        .navigationBarHidden(true)
    }
}

// MARK: - UIKit camera bridge
private struct CameraScannerView: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onScanned = onScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: ScannerViewController, coordinator: ()) {
        uiViewController.stopSession()
    }
}

private final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didSendResult = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.setupSession() }
                }
            }
        default:
            // No permission; nothing else to do here. You may want to surface UI in SwiftUI layer.
            break
        }
    }

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        // Configure inputs
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        // Configure outputs
        guard session.canAddOutput(metadataOutput) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = [.ean13, .ean8]

        // Finish configuration before starting the session
        session.commitConfiguration()

        // Setup preview layer and start running after commit
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
        previewLayer?.frame = view.bounds

        session.startRunning()
    }

    func stopSession() {
        if session.isRunning { session.stopRunning() }
    }

    // MARK: - Delegate
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !didSendResult else { return }
        for obj in metadataObjects {
            guard let codeObject = obj as? AVMetadataMachineReadableCodeObject,
                  let value = codeObject.stringValue else { continue }

            if let isbn = normalizedISBN(from: value) {
                didSendResult = true
                stopSession()
                onScanned?(isbn)
                break
            }
        }
    }

    // Normalize and filter to ISBN if possible
    private func normalizedISBN(from raw: String) -> String? {
        let digits = raw.filter { $0.isNumber }
        // EAN-13 ISBNs start with 978 or 979
        if digits.count == 13, (digits.hasPrefix("978") || digits.hasPrefix("979")) {
            return digits
        }
        // Some scanners may yield ISBN-10 without prefix; accept 10-digit as well
        if digits.count == 10 { return digits }
        return nil
    }
}

#Preview {
    NavigationStack {
        ISBNScannerView { code in
            print("Scanned: \(code)")
        }
    }
}
