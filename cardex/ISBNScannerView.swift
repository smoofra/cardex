import SwiftUI
import AVFoundation
import Vision

public struct ISBNScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScanned: (String) -> Void

    public init(onScanned: @escaping (String) -> Void) {
        self.onScanned = onScanned
    }

    public var body: some View {
        ZStack {
            CameraScannerView(onScanned: { isbn in
                onScanned(isbn)
                dismiss()
            })
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .padding(12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding()
                }
                Spacer()
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 280, height: 180)
                Spacer()
                Text("Align the ISBN barcode or number within the frame")
                    .padding(12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 40)
            }
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

private final class ScannerViewController: UIViewController,
        AVCaptureMetadataOutputObjectsDelegate,
        AVCaptureVideoDataOutputSampleBufferDelegate {

    var onScanned: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ocrQueue = DispatchQueue(label: "org.elder-gods.cardex.ocr", qos: .default)
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didSendResult = false
    private var lastOCRTime: TimeInterval = 0

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
                DispatchQueue.main.async { if granted { self.setupSession() } }
            }
        default:
            break
        }
    }

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        guard session.canAddOutput(metadataOutput) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        metadataOutput.metadataObjectTypes = [.ean13, .ean8]

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: ocrQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()

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

    // MARK: - Barcode delegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didSendResult else { return }
        for obj in metadataObjects {
            guard let code = obj as? AVMetadataMachineReadableCodeObject,
                  let value = code.stringValue,
                  let isbn = normalizedISBN(from: value) else { continue }
            didSendResult = true
            stopSession()
            onScanned?(isbn)
            return
        }
    }

    // MARK: - OCR delegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !didSendResult else { return }
        let now = CACurrentMediaTime()
        guard now - lastOCRTime > 1.0 else { return }
        lastOCRTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNRecognizeTextRequest { [weak self] req, _ in
            guard let self, !self.didSendResult else { return }
            let strings = (req.results as? [VNRecognizedTextObservation])?.compactMap {
                $0.topCandidates(1).first?.string
            } ?? []
            guard let isbn = self.findISBN(in: strings) else { return }
            self.didSendResult = true
            self.stopSession()
            DispatchQueue.main.async { self.onScanned?(isbn) }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
    }

    // MARK: - Helpers

    private func findISBN(in strings: [String]) -> String? {
        let pattern = try? NSRegularExpression(pattern: "[0-9][0-9 \\-]{8,16}[0-9Xx]")
        for text in strings {
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            guard let matches = pattern?.matches(in: text, range: range) else { continue }
            for match in matches {
                let candidate = nsText.substring(with: match.range)
                if let isbn = normalizedISBN(from: candidate) { return isbn }
            }
        }
        return nil
    }

    private func normalizedISBN(from raw: String) -> String? {
        let digits = raw.filter { $0.isNumber }
        if digits.count == 13, digits.hasPrefix("978") || digits.hasPrefix("979") { return digits }
        if digits.count == 10 { return digits }
        return nil
    }
}

#Preview {
    NavigationStack {
        ISBNScannerView { code in print("Scanned: \(code)") }
    }
}
