import Foundation
import Network
import Security

actor SetupServer {
    struct Handout: Sendable {
        var host: String
        var port: UInt16
        var token: String
    }

    private var listener: NWListener?
    private var files: [String: URL] = [:]
    private var token = ""
    private var connections: [NWConnection] = []

    func start(files: [String: URL], preferredPort: UInt16 = 0) throws -> Handout {
        stop()
        self.files = files
        self.token = Self.makeToken()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let created = try NWListener(
            using: parameters,
            on: preferredPort == 0 ? .any : NWEndpoint.Port(rawValue: preferredPort)!
        )

        created.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        created.start(queue: .global(qos: .userInitiated))
        listener = created

        for _ in 0..<50 {
            if let port = created.port?.rawValue, port != 0 {
                return Handout(host: try Self.localAddress(), port: port, token: token)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw SetupServerError.noPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let range = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: accumulated[..<range.lowerBound], as: UTF8.self)
                Task { await self.respond(to: head, on: connection) }
                return
            }

            if error != nil || complete {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        guard let requestLine = head.split(separator: "\r\n").first else {
            send(status: "400 Bad Request", body: Data("bad request".utf8), on: connection)
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: "400 Bad Request", body: Data("bad request".utf8), on: connection)
            return
        }

        let target = String(parts[1])
        guard let components = URLComponents(string: "http://local" + target) else {
            send(status: "400 Bad Request", body: Data("bad request".utf8), on: connection)
            return
        }

        let supplied = components.queryItems?.first { $0.name == "token" }?.value ?? ""
        guard supplied == token, !token.isEmpty else {
            send(status: "403 Forbidden", body: Data("bad token".utf8), on: connection)
            return
        }

        let name = String(components.path.dropFirst())
        if name == "manifest.json" {
            let listing = files.keys.sorted()
            let payload = try? JSONSerialization.data(withJSONObject: ["files": listing])
            send(status: "200 OK", body: payload ?? Data("{}".utf8), contentType: "application/json", on: connection)
            return
        }

        guard let url = files[name], let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            send(status: "404 Not Found", body: Data("no such file".utf8), on: connection)
            return
        }
        send(status: "200 OK", body: data, contentType: "application/octet-stream", on: connection)
    }

    private func send(status: String, body: Data, contentType: String = "text/plain", on connection: NWConnection) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"

        var payload = Data(header.utf8)
        payload.append(body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func localAddress() throws -> String {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { throw SetupServerError.noAddress }
        defer { freeifaddrs(pointer) }

        var best: String?
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name != "lo0" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if name.hasPrefix("en") { return text }
            if best == nil { best = text }
        }

        guard let best else { throw SetupServerError.noAddress }
        return best
    }
}

enum SetupServerError: LocalizedError {
    case noPort
    case noAddress

    var errorDescription: String? {
        switch self {
        case .noPort: "Could not open a local port."
        case .noAddress: "This Mac has no usable network address. Join the same Wi-Fi as the iPhone."
        }
    }
}
