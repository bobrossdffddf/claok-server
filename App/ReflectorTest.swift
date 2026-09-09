import Foundation
import Network

enum ReflectorTest {
    static func run(port rawPort: UInt16 = 52099, timeout: TimeInterval = 8) async -> String {
        guard let port = NWEndpoint.Port(rawValue: rawPort) else {
            return "Bad port"
        }

        let listener: NWListener
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: port)
        } catch {
            return "Could not open a listener on \(rawPort): \(error.localizedDescription)"
        }

        let received = Received()

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                guard let data, !data.isEmpty else { return }
                Task { await received.markInbound(data.count) }
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
        listener.start(queue: .global())

        defer { listener.cancel() }

        try? await Task.sleep(for: .milliseconds(400))

        let host = NWEndpoint.Host(LocalAddresses.reflector)
        let connection = NWConnection(host: host, port: port, using: .tcp)

        let states = AsyncStream<NWConnection.State> { continuation in
            connection.stateUpdateHandler = { continuation.yield($0) }
            connection.start(queue: .global())
        }

        var connected = false
        let deadline = Date().addingTimeInterval(timeout)

        outer: for await state in states {
            switch state {
            case .ready:
                connected = true
                break outer
            case .failed(let error):
                connection.cancel()
                return "Connect to \(LocalAddresses.reflector):\(rawPort) failed: \(error.localizedDescription)"
            case .cancelled:
                return "Connection cancelled before it was ready"
            default:
                if Date() > deadline { break outer }
            }
        }

        guard connected else {
            connection.cancel()
            return "Connect to \(LocalAddresses.reflector):\(rawPort) timed out. The tunnel is not reflecting."
        }

        let probe = Data("cloak-reflector-probe".utf8)
        connection.send(content: probe, completion: .contentProcessed { _ in })

        var echoed: Data?
        let echoDeadline = Date().addingTimeInterval(4)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128) { data, _, _, _ in
            echoed = data
        }

        while echoed == nil && Date() < echoDeadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        let inbound = await received.inbound
        connection.cancel()

        if let echoed, echoed == probe {
            return "PASS. TCP connected through \(LocalAddresses.reflector), \(probe.count) bytes sent, listener saw \(inbound) bytes, echo returned intact. The reflector carries data correctly."
        }

        if inbound > 0 {
            return "PARTIAL. The listener received \(inbound) bytes through the reflector, but the echo did not come back. Reflection works outbound, fails on the return path."
        }

        return "FAIL. TCP connected through \(LocalAddresses.reflector) but no data arrived at the listener. The reflector passes handshakes but drops payload."
    }
}

private actor Received {
    private(set) var inbound = 0

    func markInbound(_ count: Int) {
        inbound += count
    }
}
