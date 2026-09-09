import Foundation
import Network

enum ServiceScan {
    static func run() async -> String {
        var lines: [String] = []

        for host in [LocalAddresses.reflector, "127.0.0.1"] {
            lines.append("Ports on \(host):")
            for port in [UInt16(62078), 49152, 27015] {
                lines.append("  \(port): \(await probePort(port, host: host))")
            }
        }

        lines.append("")
        lines.append("Bonjour on this device:")
        for type in ["_remotepairing._tcp", "_remoted._tcp", "_apple-mobdev2._tcp"] {
            let found = await browse(type: type)
            lines.append("  \(type): \(found)")
        }

        return lines.joined(separator: "\n")
    }

    private static func probePort(_ raw: UInt16, host: String) async -> String {
        guard let port = NWEndpoint.Port(rawValue: raw) else { return "bad port" }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let settled = Settled()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task {
                        if await settled.claim() { continuation.resume(returning: "open") }
                    }
                case .failed(let error):
                    Task {
                        if await settled.claim() { continuation.resume(returning: "refused (\(error.localizedDescription))") }
                    }
                case .waiting(let error):
                    Task {
                        if await settled.claim() { continuation.resume(returning: "waiting (\(error.localizedDescription))") }
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global())

            Task {
                try? await Task.sleep(for: .seconds(3))
                if await settled.claim() { continuation.resume(returning: "no answer") }
            }
        }

        if outcome == "open" {
            let held = await holdOpen(connection)
            connection.cancel()
            return "open, \(held)"
        }

        connection.cancel()
        return outcome
    }

    private static func holdOpen(_ connection: NWConnection) async -> String {
        let dropped = Dropped()
        connection.stateUpdateHandler = { state in
            if case .failed = state { Task { await dropped.mark() } }
            if case .cancelled = state { Task { await dropped.mark() } }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16) { _, _, complete, _ in
            if complete { Task { await dropped.mark() } }
        }
        try? await Task.sleep(for: .seconds(2))
        return await dropped.value ? "closed by peer within 2s" : "stayed open 2s with no data sent"
    }

    private static func browse(type: String) async -> String {
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
        let store = Names()

        browser.browseResultsChangedHandler = { results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return nil
            }
            Task { await store.set(names) }
        }
        browser.start(queue: .global())
        try? await Task.sleep(for: .seconds(3))
        browser.cancel()

        let names = await store.value
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}

private actor Settled {
    private var done = false
    func claim() -> Bool {
        if done { return false }
        done = true
        return true
    }
}

private actor Dropped {
    private(set) var value = false
    func mark() { value = true }
}

private actor Names {
    private(set) var value: [String] = []
    func set(_ names: [String]) { value = names }
}
