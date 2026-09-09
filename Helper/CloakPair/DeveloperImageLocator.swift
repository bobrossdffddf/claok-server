import Foundation

struct DeveloperImageFiles {
    var image: URL
    var trustCache: URL
    var manifest: URL
    var source: String
}

enum DeveloperImageLocatorError: LocalizedError {
    case notFound([String])
    case attachFailed(String)
    case incomplete(String, String)

    var errorDescription: String? {
        switch self {
        case .notFound(let searched):
            "No iOS developer image found on this Mac. Open Xcode once and let it finish installing components, then try again.\n\nLooked in:\n" + searched.joined(separator: "\n")
        case .attachFailed(let detail):
            "Could not open the developer disk image.\n\(detail)"
        case .incomplete(let path, let detail):
            "The developer image at \(path) is missing something: \(detail)"
        }
    }
}

enum DeveloperImageLocator {
    static func extractedRestoreDirectories() -> [URL] {
        var roots = [
            "/Library/Developer/DeveloperDiskImages/iOS_DDI",
            NSHomeDirectory() + "/Library/Developer/DeveloperDiskImages/iOS_DDI"
        ]
        roots.append(contentsOf: developerRoots().map { $0 + "/Platforms/iPhoneOS.platform/Library/Developer/CoreServices/CoreDeviceDDIs/iOS_DDI" })
        return roots.map { URL(fileURLWithPath: $0).appendingPathComponent("Restore", isDirectory: true) }
    }

    static func diskImageCandidates() -> [URL] {
        var paths = [
            "/Library/Developer/CoreDevice/CandidateDDIs/iOS_DDI.dmg",
            NSHomeDirectory() + "/Library/Developer/CoreDevice/CandidateDDIs/iOS_DDI.dmg"
        ]
        paths.append(contentsOf: developerRoots().map { $0 + "/Platforms/iPhoneOS.platform/Library/Developer/CoreServices/CoreDeviceDDIs/iOS_DDI.dmg" })
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func developerRoots() -> [String] {
        var roots: [String] = []
        if let selected = run("/usr/bin/xcode-select", ["-p"])?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
            roots.append(selected)
        }
        let applications = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        for entry in applications where entry.hasPrefix("Xcode") && entry.hasSuffix(".app") {
            roots.append("/Applications/\(entry)/Contents/Developer")
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted }
    }

    static func extract() throws -> DeveloperImageFiles {
        var searched: [String] = []

        for restore in extractedRestoreDirectories() {
            searched.append(restore.path)
            guard FileManager.default.fileExists(atPath: restore.path) else { continue }
            return try stage(from: restore, source: restore.path)
        }

        for diskImage in diskImageCandidates() {
            searched.append(diskImage.path)
            guard FileManager.default.fileExists(atPath: diskImage.path) else { continue }
            return try stageFromDiskImage(diskImage)
        }

        throw DeveloperImageLocatorError.notFound(searched)
    }

    static func stageFromDiskImage(_ diskImage: URL) throws -> DeveloperImageFiles {
        let mountPoint = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CloakDDI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        guard run("/usr/bin/hdiutil", ["attach", diskImage.path, "-mountpoint", mountPoint.path, "-nobrowse", "-readonly", "-quiet"]) != nil else {
            throw DeveloperImageLocatorError.attachFailed("hdiutil could not attach \(diskImage.path)")
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
            try? FileManager.default.removeItem(at: mountPoint)
        }

        let restore = mountPoint.appendingPathComponent("Restore", isDirectory: true)
        return try stage(from: restore, source: diskImage.path)
    }

    static func stage(from restore: URL, source: String) throws -> DeveloperImageFiles {
        let manager = FileManager.default
        let manifest = restore.appendingPathComponent("BuildManifest.plist")
        guard manager.fileExists(atPath: manifest.path) else {
            throw DeveloperImageLocatorError.incomplete(restore.path, "no BuildManifest.plist")
        }

        let firmware = restore.appendingPathComponent("Firmware", isDirectory: true)
        let entries = (try? manager.contentsOfDirectory(atPath: restore.path)) ?? []
        let images = entries.filter { $0.hasSuffix(".dmg") }
        guard !images.isEmpty else {
            throw DeveloperImageLocatorError.incomplete(restore.path, "no disk image")
        }

        func trustCacheURL(for name: String) -> URL? {
            let candidates = [
                firmware.appendingPathComponent("\(name).trustcache"),
                restore.appendingPathComponent("\(name).trustcache")
            ]
            return candidates.first { manager.fileExists(atPath: $0.path) }
        }

        func size(_ name: String) -> Int {
            let attributes = try? manager.attributesOfItem(atPath: restore.appendingPathComponent(name).path)
            return (attributes?[.size] as? NSNumber)?.intValue ?? 0
        }

        let cryptex = images.first { name in
            manager.fileExists(atPath: firmware.appendingPathComponent("\(name).cryptex_info").path)
                && trustCacheURL(for: name) != nil
        }

        let fallback = images
            .filter { trustCacheURL(for: $0) != nil }
            .max { size($0) < size($1) }

        guard let chosen = cryptex ?? fallback, let trustCache = trustCacheURL(for: chosen) else {
            throw DeveloperImageLocatorError.incomplete(restore.path, "no disk image with a matching trust cache")
        }

        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CloakDDIStaged-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        let stagedImage = staging.appendingPathComponent("Image.dmg")
        let stagedTrustCache = staging.appendingPathComponent("Image.dmg.trustcache")
        let stagedManifest = staging.appendingPathComponent("BuildManifest.plist")

        try manager.copyItem(at: restore.appendingPathComponent(chosen), to: stagedImage)
        try manager.copyItem(at: trustCache, to: stagedTrustCache)
        try manager.copyItem(at: manifest, to: stagedManifest)

        return DeveloperImageFiles(
            image: stagedImage,
            trustCache: stagedTrustCache,
            manifest: stagedManifest,
            source: "\(source) (\(chosen))"
        )
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
