import SwiftUI
import AVFoundation
import Vision

public struct DOIScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScanned: (String) -> Void

    public init(onScanned: @escaping (String) -> Void) {
        self.onScanned = onScanned
    }

    public var body: some View {
        ZStack {
            CameraDOIScannerView(onScanned: { doi in
                onScanned(doi)
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
                    .frame(width: 320, height: 180)
                Spacer()
                Text("Align the DOI or arXiv ID within the frame")
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

private struct CameraDOIScannerView: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> DOIScannerViewController {
        let vc = DOIScannerViewController()
        vc.onScanned = onScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: DOIScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DOIScannerViewController, coordinator: ()) {
        uiViewController.stopSession()
    }
}

private final class DOIScannerViewController: UIViewController,
        AVCaptureVideoDataOutputSampleBufferDelegate {

    var onScanned: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ocrQueue = DispatchQueue(label: "org.elder-gods.cardex.doi-ocr", qos: .default)
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

        ocrQueue.async {
            self.session.startRunning()
        }
    }

    func stopSession() {
        if session.isRunning { session.stopRunning() }
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
            guard let doi = self.findDOI(in: strings) else { return }
            self.didSendResult = true
            self.stopSession()
            DispatchQueue.main.async { self.onScanned?(doi) }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
    }

    // MARK: - Helpers

    private func findDOI(in strings: [String]) -> String? {
        let doiPattern = try? NSRegularExpression(pattern: "(?i)(?:doi:\\s*)?(10\\.\\d{4,}/\\S+)")
        let arxivPattern = try? NSRegularExpression(pattern: "(?i)arxiv:\\s*(\\d{4}\\.\\d{4,5}(?:v\\d+)?|[a-z.-]+/\\d{7}(?:v\\d+)?)")
        for text in strings {
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            if let match = doiPattern?.firstMatch(in: text, range: range) {
                let captureRange = match.range(at: 1)
                if captureRange.location != NSNotFound {
                    return nsText.substring(with: captureRange)
                }
            }
            if let match = arxivPattern?.firstMatch(in: text, range: range) {
                let captureRange = match.range(at: 1)
                if captureRange.location != NSNotFound {
                    let idWithVersion = nsText.substring(with: captureRange)
                    // Strip version suffix (v1, v4, etc.) before forming DOI
                    let id = idWithVersion.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
                    return "10.48550/arXiv.\(id)"
                }
            }
        }
        return nil
    }
}

#Preview {
    NavigationStack {
        DOIScannerView { doi in print("Scanned: \(doi)") }
    }
}
