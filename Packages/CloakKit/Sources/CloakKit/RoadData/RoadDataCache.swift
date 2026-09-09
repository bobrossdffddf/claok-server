import Foundation

public actor RoadDataCache {
    private let directory: URL
    private let maximumAge: TimeInterval
    private var memory: [String: RoadMetadata] = [:]

    public init(directory: URL? = nil, maximumAge: TimeInterval = 60 * 60 * 24 * 90) {
        let base = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RoadData", isDirectory: true)
        self.directory = base
        self.maximumAge = maximumAge
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    public func metadata(for box: BoundingBox, loader: @Sendable (BoundingBox) async throws -> RoadMetadata) async -> RoadMetadata {
        let key = Self.key(for: box)
        if let cached = memory[key], Date.now.timeIntervalSince(cached.fetchedAt) < maximumAge {
            return cached
        }
        if let disk = readDisk(key: key), Date.now.timeIntervalSince(disk.fetchedAt) < maximumAge {
            memory[key] = disk
            return disk
        }
        do {
            let fresh = try await loader(box)
            memory[key] = fresh
            writeDisk(key: key, value: fresh)
            return fresh
        } catch {
            if let stale = memory[key] ?? readDisk(key: key) { return stale }
            return .empty
        }
    }

    public func purge() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func readDisk(key: String) -> RoadMetadata? {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RoadMetadata.self, from: data)
    }

    private func writeDisk(key: String, value: RoadMetadata) {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func key(for box: BoundingBox) -> String {
        let rounded = [box.minLatitude, box.minLongitude, box.maxLatitude, box.maxLongitude]
            .map { String(format: "%.3f", $0) }
            .joined(separator: "_")
        return rounded.replacingOccurrences(of: "-", with: "n").replacingOccurrences(of: ".", with: "d")
    }
}
