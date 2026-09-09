import Foundation
import CloakKit

public struct DeveloperImageFetcher: Sendable {
    public enum Progress: Sendable {
        case started(String)
        case bytes(received: Int64, expected: Int64, file: String)
        case finished
        case failed(String)
    }

    private static let names = ["Image.dmg", "Image.dmg.trustcache", "BuildManifest.plist"]

    public init() {}

    public func fetchPairing(from source: SetupPayload.ImageSource) async throws -> Data {
        guard let url = source.url(for: "pairing.plist") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    public func fetch(
        from source: SetupPayload.ImageSource,
        onProgress: @Sendable @escaping (Progress) -> Void
    ) async -> Bool {
        var collected: [String: Data] = [:]

        for name in Self.names {
            guard let url = source.url(for: name) else {
                onProgress(.failed("Could not build a URL for \(name)."))
                return false
            }
            onProgress(.started(name))

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 180
                request.cachePolicy = .reloadIgnoringLocalCacheData

                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    onProgress(.failed("The helper refused the request for \(name)."))
                    return false
                }

                let expected = http.expectedContentLength
                var buffer = Data()
                buffer.reserveCapacity(expected > 0 ? Int(expected) : 1 << 20)
                var counter: Int64 = 0
                var lastReport: Int64 = 0

                for try await byte in bytes {
                    buffer.append(byte)
                    counter += 1
                    if counter - lastReport > 262_144 {
                        lastReport = counter
                        onProgress(.bytes(received: counter, expected: expected, file: name))
                    }
                }

                collected[name] = buffer
            } catch {
                onProgress(.failed(error.localizedDescription))
                return false
            }
        }

        guard let image = collected["Image.dmg"],
              let trustCache = collected["Image.dmg.trustcache"],
              let manifest = collected["BuildManifest.plist"] else {
            onProgress(.failed("The helper did not send all three files."))
            return false
        }

        do {
            try DeveloperImageBundle(image: image, trustCache: trustCache, manifest: manifest).save()
            onProgress(.finished)
            return true
        } catch {
            onProgress(.failed(error.localizedDescription))
            return false
        }
    }
}
