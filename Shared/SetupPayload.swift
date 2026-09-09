import Foundation

public struct SetupPayload: Codable, Sendable {
    public struct ImageSource: Codable, Sendable {
        public var host: String
        public var port: UInt16
        public var token: String

        public init(host: String, port: UInt16, token: String) {
            self.host = host
            self.port = port
            self.token = token
        }

        public func url(for name: String) -> URL? {
            var components = URLComponents()
            components.scheme = "http"
            components.host = host
            components.port = Int(port)
            components.path = "/" + name
            components.queryItems = [URLQueryItem(name: "token", value: token)]
            return components.url
        }
    }

    public var version: Int
    public var pairing: Data?
    public var developerImage: ImageSource?

    public init(version: Int = 1, pairing: Data? = nil, developerImage: ImageSource?) {
        self.version = version
        self.pairing = pairing
        self.developerImage = developerImage
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case pairing
        case developerImage = "ddi"
    }

    public static func decode(_ data: Data) -> SetupPayload? {
        try? JSONDecoder().decode(SetupPayload.self, from: data)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
