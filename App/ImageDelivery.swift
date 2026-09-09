import Foundation
import CloakKit

/// Fetches the developer disk image from the licence server.
///
/// iOS will not offer its location service until this image is mounted, so
/// this is the point at which a licence stops being a boolean somebody can
/// patch out and starts being something the app cannot work without. The
/// request carries the signed activation token, and the server checks it
/// again at its end, where it can also see a licence that has been withdrawn
/// since the phone last asked.
@MainActor
@Observable
final class ImageDelivery {
    enum State: Equatable {
        case idle
        case working(String, Double)
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle

    private static let files = ["Image.dmg", "Image.dmg.trustcache", "BuildManifest.plist"]

    var isReady: Bool { DeveloperImageBundle.isPresent }

    var progress: Double {
        if case .working(_, let fraction) = state { return fraction }
        return isReady ? 1 : 0
    }

    var detail: String {
        switch state {
        case .idle: isReady ? "Ready" : "Not downloaded yet"
        case .working(let name, _): "Downloading \(name)"
        case .ready: "Ready"
        case .failed(let message): message
        }
    }

    @discardableResult
    func fetch(token: LicenseToken?) async -> Bool {
        if isReady {
            state = .ready
            return true
        }

        guard let token else {
            state = .failed("Cloak needs an active licence before it can finish setting up.")
            return false
        }

        var collected: [String: Data] = [:]

        for (index, name) in Self.files.enumerated() {
            state = .working(name, Double(index) / Double(Self.files.count))

            var request = URLRequest(
                url: Licensing.serverBase.appendingPathComponent("v1/ddi/\(name)"))
            request.setValue("Bearer \(token.raw)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 240
            request.cachePolicy = .reloadIgnoringLocalCacheData

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                guard (200..<300).contains(status) else {
                    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let reason = object?["error"] as? String
                    state = .failed(reason ?? "The server would not send the setup files (\(status)).")
                    return false
                }
                collected[name] = data
            } catch {
                state = .failed("Could not reach the server: \(error.localizedDescription)")
                return false
            }
        }

        guard let image = collected["Image.dmg"],
              let trustCache = collected["Image.dmg.trustcache"],
              let manifest = collected["BuildManifest.plist"] else {
            state = .failed("The server did not send all three files.")
            return false
        }

        do {
            try DeveloperImageBundle(image: image, trustCache: trustCache, manifest: manifest).save()
            state = .ready
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }
}
