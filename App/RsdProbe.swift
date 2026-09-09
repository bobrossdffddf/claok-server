import Foundation

#if canImport(CloakBridge)
import CloakBridge

enum RsdProbe {
    static func run(ports: [UInt16] = [62078, 49152]) async -> String {
        var lines: [String] = ["Lockdown probe:"]

        for (host, port) in ports.flatMap({ port in [LocalAddresses.reflector, "127.0.0.1"].map { ($0, port) } }) {
            let report = await Task.detached(priority: .userInitiated) { () -> String in
                var scratch = [CChar](repeating: 0, count: 8192)
                let code = host.withCString { address in
                    cloak_probe_rsd(address, port, &scratch, scratch.count)
                }
                guard code == CLOAK_OK else { return "probe call failed (\(code))" }
                return String(cString: scratch)
            }.value

            lines.append("  \(host):\(port) \(condense(report))")
        }

        return lines.joined(separator: "\n")
    }

    private static func condense(_ report: String) -> String {
        guard let data = report.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return shorten(report)
        }

        let stage = object["stage"] as? String ?? "?"

        switch stage {
        case "services":
            let count = object["serviceCount"] as? Int ?? 0
            let dvt = (object["hasDvt"] as? Bool) == true
            var line = "RSD ANSWERED. \(count) services, dvt=\(dvt)"
            if let services = object["services"] as? [String] {
                line += "\n      " + services.prefix(8).joined(separator: "\n      ")
            }
            return line
        case "no-services":
            let keys = (object["rootKeys"] as? [String]) ?? []
            return "XPC root received but no Services. keys: \(keys.joined(separator: ", "))"
        case "root-not-dict":
            return "XPC root was not a dictionary: \(shorten(object["root"] as? String ?? "?"))"
        default:
            return shorten(object["reason"] as? String ?? report)
        }
    }

    private static func shorten(_ text: String) -> String {
        text.count > 160 ? String(text.prefix(160)) + "…" : text
    }
}

#else

enum RsdProbe {
    static func run(ports: [UInt16] = []) async -> String { "Bridge not built" }
}

#endif
