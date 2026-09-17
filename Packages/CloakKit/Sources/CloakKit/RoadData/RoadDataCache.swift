import Foundation

public actor RoadDataCache {
    private let directory: URL
    private let maximumAge: TimeInterval
    private let emptyMaximumAge: TimeInterval
    private var memory: [String: RoadMetadata] = [:]
    /// Fetches already running, so two routes through the same streets, or a
    /// route and the alternatives offered beside it, share one request instead
    /// of racing each other to make the same one.
    private var running: [String: Task<RoadMetadata, Error>] = [:]

    public init(
        directory: URL? = nil,
        maximumAge: TimeInterval = 60 * 60 * 24 * 90,
        /// Roads do not move, so a real answer is kept for months. An answer
        /// with nothing in it is kept for minutes: it is far more likely to be
        /// a mirror having a bad afternoon than a square kilometre of city
        /// with no roads in it, and keeping it for months is how one bad
        /// afternoon turned into a route that never found a speed limit again.
        emptyMaximumAge: TimeInterval = 15 * 60
    ) {
        let base = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RoadData", isDirectory: true)
        self.directory = base
        self.maximumAge = maximumAge
        self.emptyMaximumAge = emptyMaximumAge
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    public func metadata(for box: BoundingBox, loader: @Sendable @escaping (BoundingBox) async throws -> RoadMetadata) async -> RoadMetadata {
        let key = Self.key(for: box)
        if let cached = fresh(key) { return cached }

        let task: Task<RoadMetadata, Error>
        if let known = running[key] {
            task = known
        } else {
            task = Task { try await loader(box) }
            running[key] = task
        }

        do {
            // A cancelled route lets go of its requests. Nothing is kept from a
            // cancelled or failed fetch, so another route waiting on the same
            // box asks again rather than inheriting the failure.
            let fresh = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if running[key] == task { running[key] = nil }
            // Nothing worth keeping is still an answer for now, but it is not
            // kept the way a real one is.
            memory[key] = fresh
            if !fresh.isEmpty, !fresh.wasFallback { writeDisk(key: key, value: fresh) }
            return fresh
        } catch {
            if running[key] == task { running[key] = nil }
            // A failure is not a fact. Anything already known about this box is
            // better than nothing; otherwise say plainly that there is no data.
            if let stale = memory[key] ?? readDisk(key: key) { return stale }
            return .empty
        }
    }

    public func purge() {
        memory.removeAll()
        running.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// What is known about this box and still worth using.
    private func fresh(key: String, now: Date = .now) -> RoadMetadata? {
        if let cached = memory[key], keeps(cached, now: now) { return cached }
        if let disk = readDisk(key: key), keeps(disk, now: now) {
            memory[key] = disk
            return disk
        }
        return nil
    }

    private func fresh(_ key: String) -> RoadMetadata? { fresh(key: key) }

    func keeps(_ value: RoadMetadata, now: Date = .now) -> Bool {
        // A fallback is a record of a failure, never an answer to hand back.
        guard !value.wasFallback else { return false }
        let age = now.timeIntervalSince(value.fetchedAt)
        return age < (value.isEmpty ? emptyMaximumAge : maximumAge)
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
