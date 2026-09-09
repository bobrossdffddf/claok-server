import Foundation

public struct GPXPoint: Hashable, Sendable {
    public var coordinate: Coordinate
    public var elevation: Double?
    public var time: Date?

    public init(coordinate: Coordinate, elevation: Double? = nil, time: Date? = nil) {
        self.coordinate = coordinate
        self.elevation = elevation
        self.time = time
    }
}

public struct GPXDocument: Sendable {
    public var name: String
    public var points: [GPXPoint]

    public init(name: String, points: [GPXPoint]) {
        self.name = name
        self.points = points
    }

    public var polyline: Polyline { Polyline(points: points.map(\.coordinate)) }

    public func serialized() -> String {
        let formatter = ISO8601DateFormatter()
        var body = ""
        for point in points {
            body += "      <trkpt lat=\"\(point.coordinate.latitude)\" lon=\"\(point.coordinate.longitude)\">\n"
            if let elevation = point.elevation {
                body += "        <ele>\(elevation)</ele>\n"
            }
            if let time = point.time {
                body += "        <time>\(formatter.string(from: time))</time>\n"
            }
            body += "      </trkpt>\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Cloak" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(name)</name>
            <trkseg>
        \(body)    </trkseg>
          </trk>
        </gpx>
        """
    }
}

public final class GPXParser: NSObject, XMLParserDelegate {
    private var points: [GPXPoint] = []
    private var name = "Imported"
    private var currentCoordinate: Coordinate?
    private var currentElevation: Double?
    private var currentTime: Date?
    private var buffer = ""
    private let formatter = ISO8601DateFormatter()

    public override init() { super.init() }

    public func parse(data: Data) -> GPXDocument? {
        points = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), !points.isEmpty else { return nil }
        return GPXDocument(name: name, points: points)
    }

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        buffer = ""
        if elementName == "trkpt" || elementName == "wpt" || elementName == "rtept" {
            guard let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init) else { return }
            currentCoordinate = Coordinate(latitude: lat, longitude: lon)
            currentElevation = nil
            currentTime = nil
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "name" where points.isEmpty && !text.isEmpty:
            name = text
        case "ele":
            currentElevation = Double(text)
        case "time":
            currentTime = formatter.date(from: text)
        case "trkpt", "wpt", "rtept":
            if let coordinate = currentCoordinate {
                points.append(GPXPoint(coordinate: coordinate, elevation: currentElevation, time: currentTime))
            }
            currentCoordinate = nil
        default:
            break
        }
        buffer = ""
    }
}
