import Testing
import Foundation
@testable import CloakKit

@Suite("Journey")
struct JourneyTests {
    let dallas = Coordinate(latitude: 32.7767, longitude: -96.7970)
    let dfw = Journey.Airport(name: "Dallas Fort Worth International", iata: "DFW", coordinate: Coordinate(latitude: 32.8998, longitude: -97.0403), isInternational: true)
    let love = Journey.Airport(name: "Dallas Love Field", iata: "DAL", coordinate: Coordinate(latitude: 32.8471, longitude: -96.8518), isInternational: false)
    let manhattan = Coordinate(latitude: 40.7580, longitude: -73.9855)
    let jfk = Journey.Airport(name: "John F. Kennedy International", iata: "JFK", coordinate: Coordinate(latitude: 40.6413, longitude: -73.7781), isInternational: true)
    let austin = Coordinate(latitude: 30.2672, longitude: -97.7431)
    let departing = Date(timeIntervalSince1970: 1_758_000_000)

    @Test func farPinsFlyAndNearPinsDrive() {
        #expect(Journey.shape(for: dallas.distance(to: manhattan)) == .fly)
        #expect(Journey.shape(for: dallas.distance(to: austin)) == .drive)
    }

    @Test func aFlightHasEveryLegInOrder() {
        let journey = Journey.fly(from: dallas, to: manhattan, via: dfw, and: jfk, departing: departing)
        let names = journey.legs.map(\.name)
        #expect(names == ["To DFW", "At DFW", "In the air", "Landed at JFK", "To the pin"])
        for (a, b) in zip(journey.legs, journey.legs.dropFirst()) {
            #expect(a.end == b.start)
        }
        #expect(journey.departs == departing)
    }

    @Test func theFlightHoldsAtTheDepartureGate() {
        let journey = Journey.fly(from: dallas, to: manhattan, via: dfw, and: jfk, departing: departing)
        let air = journey.legs.first { $0.name == "In the air" }!
        guard case .hold(let where_, let drift) = air.kind else { Issue.record("not a hold"); return }
        #expect(where_ == dfw.coordinate)
        #expect(drift == 0)
    }

    @Test func flightTimeIsPlausible() {
        let journey = Journey.fly(from: dallas, to: manhattan, via: dfw, and: jfk, departing: departing)
        let air = journey.legs.first { $0.name == "In the air" }!
        let hours = air.duration / 3600
        #expect(hours > 2.8)
        #expect(hours < 4.2)
        #expect(journey.totalDuration / 3600 > 5)
        #expect(journey.totalDuration / 3600 < 8)
    }

    @Test func airportLegsAreSkippedWhenAlreadyThere() {
        let journey = Journey.fly(from: dfw.coordinate, to: jfk.coordinate, via: dfw, and: jfk, departing: departing)
        let names = journey.legs.map(\.name)
        #expect(!names.contains("To DFW"))
        #expect(!names.contains("To the pin"))
        #expect(names.count == 3)
    }

    @Test func prefersTheBigAirportUnlessItIsMuchFurther() {
        #expect(Journey.choose(from: [dfw, love], near: dallas)?.iata == "DFW")
        let farAway = Journey.Airport(name: "Far International", iata: "FAR", coordinate: Coordinate(latitude: 33.9, longitude: -96.8), isInternational: true)
        #expect(Journey.choose(from: [farAway, love], near: dallas)?.iata == "DAL")
        #expect(Journey.choose(from: [], near: dallas) == nil)
    }

    @Test func summaryNamesTheAirports() {
        let journey = Journey.fly(from: dallas, to: manhattan, via: dfw, and: jfk, departing: departing)
        #expect(journey.summary.contains("DFW to JFK"))
        #expect(Journey.drive(from: dallas, to: austin).summary.hasPrefix("Drive"))
    }

    @Test func theAirportQueryIsValidOverpass() {
        let box = BoundingBox(minLatitude: 32.1, minLongitude: -97.5, maxLatitude: 33.5, maxLongitude: -96.1)
        let query = AirportFinder.query(box: box)
        // The bounding box must be parenthesised. Without the brackets Overpass
        // rejects the whole query as a syntax error and every airport lookup
        // silently returns nothing, which is exactly what happened.
        #expect(query.contains("](32.100000,-97.500000,33.500000,-96.100000);"))
        #expect(query.contains("[out:json]"))
        #expect(query.contains("out center tags;"))
    }

    @Test func decodesOverpassAirports() {
        let json = """
        {"elements":[
          {"type":"way","id":1,"center":{"lat":32.8998,"lon":-97.0403},"tags":{"aeroway":"aerodrome","iata":"DFW","name":"Dallas Fort Worth International Airport","aerodrome:type":"international"}},
          {"type":"node","id":2,"lat":32.8471,"lon":-96.8518,"tags":{"aeroway":"aerodrome","iata":"DAL","name":"Dallas Love Field"}},
          {"type":"node","id":3,"lat":32.5,"lon":-96.9,"tags":{"aeroway":"aerodrome","iata":"XXX","name":"Old Base","aerodrome:type":"military"}},
          {"type":"node","id":4,"lat":32.6,"lon":-96.9,"tags":{"aeroway":"aerodrome","name":"No Code Field"}}
        ]}
        """.data(using: .utf8)!
        let airports = AirportFinder.decode(json, near: dallas)
        #expect(airports.map(\.iata) == ["DAL", "DFW"])
        #expect(airports.first { $0.iata == "DFW" }?.isInternational == true)
    }
}

/// A passenger is never on a runway.
@Suite("Airport terminals")
struct AirportTerminalTests {
    @Test func theQueryAsksForTerminalsToo() {
        let box = BoundingBox(minLatitude: 32.1, minLongitude: -97.5, maxLatitude: 33.5, maxLongitude: -96.1)
        let query = AirportFinder.query(box: box)
        #expect(query.contains(#"nwr["aeroway"="aerodrome"]["iata"]"#))
        #expect(query.contains(#"nwr["aeroway"="terminal"]"#))
        // Two statements have to be a union or Overpass returns only the last.
        #expect(query.contains("(\n"))
        #expect(query.contains(");"))
        #expect(query.contains("](32.100000,-97.500000,33.500000,-96.100000);"))
    }

    @Test func theDoorIsTheTerminalNotTheAirfield() {
        // DFW's aerodrome centroid sits between the runways. The terminal is
        // most of a kilometre away, and the difference is the whole reason a
        // terminal hold looked like wandering around outside the building.
        let json = """
        {"elements":[
          {"lat":32.8968,"lon":-97.0380,"tags":{"aeroway":"aerodrome","iata":"DFW","name":"Dallas Fort Worth International","aerodrome:type":"international"}},
          {"lat":32.9010,"lon":-97.0420,"tags":{"aeroway":"terminal","name":"Terminal A"}}
        ]}
        """
        let airports = AirportFinder.decode(Data(json.utf8), near: Coordinate(latitude: 32.78, longitude: -96.80))
        #expect(airports.count == 1)
        let dfw = try! #require(airports.first)
        #expect(dfw.iata == "DFW")
        #expect(dfw.terminal != nil)
        #expect(dfw.door.latitude == 32.9010)
        #expect(dfw.coordinate.latitude == 32.8968)
        #expect(dfw.door.distance(to: dfw.coordinate) > 200)
    }

    @Test func aTerminalBelongingToAnotherFieldIsNotClaimed() {
        let json = """
        {"elements":[
          {"lat":32.8968,"lon":-97.0380,"tags":{"aeroway":"aerodrome","iata":"DFW","name":"DFW"}},
          {"lat":33.4000,"lon":-97.6000,"tags":{"aeroway":"terminal","name":"Somewhere else"}}
        ]}
        """
        let airports = AirportFinder.decode(Data(json.utf8), near: Coordinate(latitude: 32.78, longitude: -96.80))
        let dfw = try! #require(airports.first)
        #expect(dfw.terminal == nil)
        #expect(dfw.door == dfw.coordinate)
    }

    @Test func aTerminalIsNeverReturnedAsAnAirport() {
        let json = """
        {"elements":[
          {"lat":32.9010,"lon":-97.0420,"tags":{"aeroway":"terminal","iata":"DFW","name":"Terminal A"}}
        ]}
        """
        // A terminal carrying an iata tag used to satisfy the old decoder,
        // which only checked for the code.
        let airports = AirportFinder.decode(Data(json.utf8), near: Coordinate(latitude: 32.78, longitude: -96.80))
        #expect(airports.isEmpty)
    }

    @Test func everyPassengerLegAimsAtTheDoor() {
        let field = Coordinate(latitude: 32.8968, longitude: -97.0380)
        let door = Coordinate(latitude: 32.9010, longitude: -97.0420)
        let origin = Journey.Airport(name: "DFW", iata: "DFW", coordinate: field, terminal: door, isInternational: true)
        let destination = Journey.Airport(
            name: "LAX", iata: "LAX",
            coordinate: Coordinate(latitude: 33.9416, longitude: -118.4085),
            terminal: Coordinate(latitude: 33.9440, longitude: -118.4020),
            isInternational: true
        )
        let journey = Journey.fly(
            from: Coordinate(latitude: 32.78, longitude: -96.80),
            to: Coordinate(latitude: 34.05, longitude: -118.24),
            via: origin, and: destination
        )

        for leg in journey.legs {
            switch leg.kind {
            case .hold(let where_, let drift) where drift > 0:
                #expect(where_ == origin.door || where_ == destination.door)
            case .drive(_, let to) where to == origin.coordinate:
                Issue.record("a drive aimed at the airfield centroid instead of the terminal")
            default:
                continue
            }
        }
    }
}
