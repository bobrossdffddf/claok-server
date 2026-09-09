import Foundation

/// Publishes the `_remotepairing-pairable-host._tcp` record that makes this app
/// look like a computer the phone can pair with. The bridge owns the socket, so
/// this only advertises the port it is listening on.
public final class PairableHostAdvertiser: NSObject, @unchecked Sendable {
    public static let serviceType = "_remotepairing-pairable-host._tcp"

    private var service: NetService?
    private var onError: ((String) -> Void)?

    public override init() { super.init() }

    public func publish(name: String, port: UInt16, txt: [String: String], onError: @escaping (String) -> Void) {
        stop()
        self.onError = onError

        let service = NetService(domain: "local.", type: Self.serviceType, name: name, port: Int32(port))
        var record: [String: Data] = [:]
        for (key, value) in txt { record[key] = Data(value.utf8) }
        service.setTXTRecord(NetService.data(fromTXTRecord: record))
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.publish(options: [.noAutoRename])
        self.service = service
    }

    public func stop() {
        service?.stop()
        service = nil
    }
}

extension PairableHostAdvertiser: NetServiceDelegate {
    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode as String]?.intValue ?? 0
        onError?("Bonjour would not publish the record (code \(code)).")
    }
}
