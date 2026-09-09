import SwiftUI

struct PairWindow: View {
    @State private var model = PairModel()

    var body: some View {
        VStack(spacing: 20) {
            header

            switch model.stage {
            case .idle:
                idleView
            case .working(let message):
                VStack(spacing: 10) {
                    ProgressView().progressViewStyle(.circular)
                    Text(message).foregroundStyle(.secondary)
                }
            case .ready(let chunks, let note):
                QRCarousel(chunks: chunks)
                Text(note)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("Open Cloak on the iPhone, go to the pairing step, and point the camera here. Keep this window open until the phone says the developer image is stored, and keep both devices on the same Wi-Fi.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                Button("Start over") { model.reset() }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                VStack(spacing: 8) {
                    Button("Try again") { model.reset() }
                    Button("Pairing record only, skip the developer image") { model.generatePairingOnly() }
                        .font(.callout)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(30)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "qrcode")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("Cloak Pair").font(.largeTitle.bold())
            Text("Run this once. Cloak never needs a computer again.")
                .foregroundStyle(.secondary)
        }
    }

    private var idleView: some View {
        VStack(spacing: 14) {
            Text("Plug the iPhone in with a cable, unlock it, and tap Trust if it asks. Both machines need to be on the same Wi-Fi so the developer image can transfer.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button {
                model.generate()
            } label: {
                Label("Generate pairing code", systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                model.importExisting()
            } label: {
                Label("Use an existing pairing file", systemImage: "doc")
            }
        }
    }
}

struct QRCarousel: View {
    let chunks: [String]
    @State private var index = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            if let image = QRRenderer.image(for: chunks[min(index, chunks.count - 1)]) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 360, height: 360)
                    .background(.white)
                    .clipShape(.rect(cornerRadius: 10))
            }
            if chunks.count > 1 {
                Text("Frame \(min(index, chunks.count - 1) + 1) of \(chunks.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .onReceive(timer) { _ in
            guard chunks.count > 1 else { return }
            index = (index + 1) % chunks.count
        }
    }
}
