import SwiftUI
import AVFoundation

private struct Unchecked<T>: @unchecked Sendable {
    let value: T
}

struct PairingScannerView: UIViewControllerRepresentable {
    var onPayload: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        private let handler: Unchecked<(Data) -> Void>
        private var chunks: [Int: String] = [:]
        private var expected = 0

        init(onPayload: @escaping (Data) -> Void) {
            self.handler = Unchecked(value: onPayload)
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }

            var payload: Data?

            if value.hasPrefix("cloak:") {
                let parts = value.dropFirst(6).split(separator: ":", maxSplits: 2)
                guard parts.count == 3,
                      let index = Int(parts[0]),
                      let total = Int(parts[1]) else { return }
                expected = total
                chunks[index] = String(parts[2])
                guard chunks.count == expected else { return }
                let joined = (0..<expected).compactMap { chunks[$0] }.joined()
                payload = Data(base64Encoded: joined)
            } else {
                payload = Data(base64Encoded: value)
            }

            guard let payload else { return }
            let deliver = handler
            MainActor.assumeIsolated { deliver.value(payload) }
        }
    }
}

final class ScannerViewController: UIViewController {
    weak var delegate: AVCaptureMetadataOutputObjectsDelegate?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer

        let box = Unchecked(value: session)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let box = Unchecked(value: session)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value.stopRunning()
        }
    }
}
