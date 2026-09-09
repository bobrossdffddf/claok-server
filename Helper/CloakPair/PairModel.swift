import AppKit
import CoreImage
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class PairModel {
    enum Stage {
        case idle
        case working(String)
        case ready([String], String)
        case failed(String)
    }

    var stage: Stage = .idle
    private let server = SetupServer()

    func reset() {
        Task { await server.stop() }
        stage = .idle
    }

    func generate() {
        stage = .working("Talking to the phone")
        Task {
            do {
                let pairing = try await Task.detached { try PairingGenerator.run().get() }.value
                guard !pairing.isEmpty else {
                    stage = .failed("The pairing record came back empty. See pair-debug.txt in the Cloak folder.")
                    return
                }

                stage = .working("Locating the developer image")
                let files = try await Task.detached { try DeveloperImageLocator.extract() }.value

                stage = .working("Starting the local handover")

                let pairingURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("cloak-handover-pairing.plist")
                try pairing.write(to: pairingURL, options: .atomic)

                let handout = try await server.start(files: [
                    "pairing.plist": pairingURL,
                    "Image.dmg": files.image,
                    "Image.dmg.trustcache": files.trustCache,
                    "BuildManifest.plist": files.manifest
                ])

                let payload = SetupPayload(
                    developerImage: SetupPayload.ImageSource(
                        host: handout.host,
                        port: handout.port,
                        token: handout.token
                    )
                )
                let encoded = try payload.encoded()
                stage = .ready(QRRenderer.chunks(for: encoded), "Serving from \(handout.host):\(handout.port)\npairing \(pairing.count) bytes\n\(files.source)")
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    func generatePairingOnly() {
        stage = .working("Talking to the phone")
        Task {
            do {
                let pairing = try await Task.detached { try PairingGenerator.run().get() }.value
                let pairingURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("cloak-handover-pairing.plist")
                try pairing.write(to: pairingURL, options: .atomic)

                let handout = try await server.start(files: ["pairing.plist": pairingURL])
                let payload = SetupPayload(
                    developerImage: SetupPayload.ImageSource(
                        host: handout.host,
                        port: handout.port,
                        token: handout.token
                    )
                )
                let encoded = try payload.encoded()
                stage = .ready(QRRenderer.chunks(for: encoded), "Pairing record only, \(pairing.count) bytes")
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    func importExisting() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList, .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a pairing record"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }

        Task {
            do {
                let pairingURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("cloak-handover-pairing.plist")
                try data.write(to: pairingURL, options: .atomic)
                let handout = try await server.start(files: ["pairing.plist": pairingURL])
                let payload = SetupPayload(
                    developerImage: SetupPayload.ImageSource(
                        host: handout.host,
                        port: handout.port,
                        token: handout.token
                    )
                )
                stage = .ready(QRRenderer.chunks(for: try payload.encoded()), "Imported record, \(data.count) bytes")
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }
}

enum PairingError: LocalizedError {
    case toolMissing
    case toolFailed(String)
    case noDevice
    case unreadableRecord
    case authorizationDeclined

    var errorDescription: String? {
        switch self {
        case .toolMissing:
            "The cloak-pair-cli helper binary is missing. Run Scripts/build-bridge.sh again."
        case .toolFailed(let output):
            "The pairing tool failed.\n\(output)"
        case .noDevice:
            "No iPhone found. Plug it in, unlock it, and tap Trust."
        case .unreadableRecord:
            "usbmuxd returned an empty pairing record. Unplug the phone, plug it back in, unlock it, tap Trust, and try again."
        case .authorizationDeclined:
            "Cancelled."
        }
    }
}

enum PairingDebug {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/Cloak/pair-debug.txt")

    static func reset() {
        try? "Cloak Pair debug \(Date())\n".write(to: url, atomically: true, encoding: .utf8)
    }

    static func log(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
            return
        }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }
}

enum PairingGenerator {
    static func toolURL() -> URL? {
        let manager = FileManager.default
        var candidates: [URL] = []

        if let resource = Bundle.main.url(forResource: "cloak-pair-cli", withExtension: nil) {
            candidates.append(resource)
        }
        let bundle = Bundle.main.bundleURL
        candidates.append(bundle.deletingLastPathComponent().appendingPathComponent("cloak-pair-cli"))
        candidates.append(URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/Cloak/cloak-pair-cli"))
        candidates.append(URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/Cloak/Bridge/cloak-bridge/target/release/cloak-pair-cli"))

        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }

    static func run() -> Result<Data, PairingError> {
        PairingDebug.reset()

        guard let tool = toolURL() else {
            PairingDebug.log("cloak-pair-cli not found")
            return .failure(.toolMissing)
        }
        PairingDebug.log("tool = \(tool.path)")

        let udid = deviceUDID()
        PairingDebug.log("udid = \(udid ?? "none")")

        if let udid, case .failure(let error) = shell(tool: "idevicepair", arguments: ["-u", udid, "pair"]) {
            PairingDebug.log("idevicepair pair warning: \(error.localizedDescription)")
        }

        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cloak-pair-\(UUID().uuidString).plist")

        let process = Process()
        process.executableURL = tool
        process.arguments = udid == nil ? [output.path] : [output.path, udid!]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            PairingDebug.log("cli launch failed: \(error.localizedDescription)")
            return .failure(.toolFailed(error.localizedDescription))
        }

        let outText = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        PairingDebug.log("cli status=\(process.terminationStatus) out=\(outText.trimmingCharacters(in: .whitespacesAndNewlines)) err=\(errText.trimmingCharacters(in: .whitespacesAndNewlines))")

        guard process.terminationStatus == 0 else {
            let detail = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 5 { return .failure(.noDevice) }
            return .failure(.toolFailed(detail.isEmpty ? "exit \(process.terminationStatus)" : detail))
        }

        guard let data = FileManager.default.contents(atPath: output.path), !data.isEmpty else {
            PairingDebug.log("cli wrote nothing")
            return .failure(.unreadableRecord)
        }
        try? FileManager.default.removeItem(at: output)

        PairingDebug.log("pair record bytes=\(data.count)")
        return .success(data)
    }

    private static func deviceUDID() -> String? {
        guard case .success(let output) = shell(tool: "idevice_id", arguments: ["-l"]) else { return nil }
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    private static func shell(tool: String, arguments: [String]) -> Result<String, PairingError> {
        let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        guard let executable = searchPaths
            .map({ $0 + "/" + tool })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .failure(.toolMissing)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do { try process.run() } catch { return .failure(.toolFailed(error.localizedDescription)) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { return .failure(.toolFailed(output)) }
        return .success(output)
    }
}

enum QRRenderer {
    static let chunkSize = 700

    static func chunks(for data: Data) -> [String] {
        let encoded = data.base64EncodedString()
        guard encoded.count > chunkSize else { return ["cloak:0:1:" + encoded] }
        var pieces: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: chunkSize, limitedBy: encoded.endIndex) ?? encoded.endIndex
            pieces.append(String(encoded[index..<end]))
            index = end
        }
        return pieces.enumerated().map { "cloak:\($0.offset):\(pieces.count):\($0.element)" }
    }

    static func image(for payload: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
