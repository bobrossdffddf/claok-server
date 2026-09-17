import Foundation

/// The routes on offer for one set of stops, and which of them is the one to
/// drive.
///
/// The app keeps this as `routeAlternatives` and `selectedRouteIndex`, and
/// every change to those goes through here, so the rules about when the
/// choice survives and when it does not can be tested without the app.
public struct RouteChoice: Sendable {
    /// Apple Maps offers at most three routes between two points.
    public static let limit = 3

    /// Every route on offer, Apple Maps' first choice first.
    public private(set) var plans: [RoutePlan]
    /// Which of `plans` is the one to drive.
    public private(set) var selectedIndex: Int

    public init(plans: [RoutePlan] = [], selectedIndex: Int = 0) {
        self.plans = Array(plans.prefix(Self.limit))
        self.selectedIndex = self.plans.indices.contains(selectedIndex) ? selectedIndex : 0
    }

    /// The selected route, or nil when nothing is on offer.
    public var active: RoutePlan? {
        plans.indices.contains(selectedIndex) ? plans[selectedIndex] : nil
    }

    /// A new build's first route, on its own and selected.
    public mutating func begin(with primary: RoutePlan) {
        plans = [primary]
        selectedIndex = 0
    }

    /// The finished set of routes for the build `begin` started.
    ///
    /// Taken only while the first route is still on offer by itself. Anything
    /// else means the stops changed or a newer build replaced it while these
    /// were being finished, and a late answer must not overwrite a newer one.
    @discardableResult
    public mutating func complete(with all: [RoutePlan]) -> Bool {
        guard plans.count == 1, selectedIndex == 0, let first = all.first, first.id == plans[0].id else {
            return false
        }
        plans = Array(all.prefix(Self.limit))
        return true
    }

    /// The same route again, with something about it finished.
    ///
    /// This is how a route whose road data arrived after it was drawn gets its
    /// posted limits and its stops without the line on screen changing or the
    /// choice between routes moving. A route is recognised by its identity, so
    /// a late answer for a route that is no longer on offer changes nothing.
    @discardableResult
    public mutating func refresh(with plan: RoutePlan) -> Bool {
        guard let index = plans.firstIndex(where: { $0.id == plan.id }) else { return false }
        var updated = plan
        // The label says how this route compares with the others, which is not
        // something the road data changed.
        updated.label = plans[index].label
        plans[index] = updated
        return true
    }

    /// Selects another route on offer.
    ///
    /// False when there is no such route, it is already the selected one, or
    /// it was built for different stops or a different mode than the ones
    /// given: a route for a trip nobody is planning any more is never driven.
    @discardableResult
    public mutating func select(_ index: Int, waypoints: [RouteWaypoint], mode: TravelMode) -> Bool {
        guard plans.indices.contains(index), index != selectedIndex,
              plans[index].matches(waypoints: waypoints, mode: mode) else { return false }
        selectedIndex = index
        return true
    }

    /// Something about the trip changed.
    ///
    /// A change that moves the line, a stop or the mode, leaves nothing on
    /// offer that is still true. A change to how the line is driven, the
    /// driver or the speed help, moves no line, so every route and the choice
    /// between them stand.
    public mutating func inputsChanged(needsNewRoute: Bool) {
        guard needsNewRoute else { return }
        clear()
    }

    public mutating func clear() {
        plans = []
        selectedIndex = 0
    }

    // MARK: - Labels

    /// The same routes, each labelled to tell it apart from the others.
    public static func labelled(_ plans: [RoutePlan]) -> [RoutePlan] {
        let labels = labels(for: plans)
        return zip(plans, labels).map { plan, label in
            var plan = plan
            plan.label = label
            return plan
        }
    }

    /// A short label for each route, from what Apple Maps said about it.
    ///
    /// The fastest route says so. Every other route says how much longer it
    /// takes, and when that rounds to nothing, how much shorter or longer it
    /// is instead. The route's name is added only when the names differ,
    /// since three routes all "via I-35 N" are not told apart by it. A notice
    /// is added only when it is not on every route, for the same reason.
    ///
    /// Nothing here names a road Apple Maps did not name. A route is "via" its
    /// name, never "avoids" another's: a different name does not mean the
    /// route stays off that road.
    public static func labels(for plans: [RoutePlan]) -> [String] {
        guard plans.count > 1,
              let fastest = plans.indices.min(by: { plans[$0].expectedTravelTime < plans[$1].expectedTravelTime })
        else {
            return plans.map { _ in RoutePlan.defaultLabel }
        }

        let names = plans.map { clean($0.routeName) }
        let namesDiffer = Set(names).count > 1
        let notices = plans.map { $0.advisories.map(clean).filter { !$0.isEmpty } }
        let everywhere = notices.dropFirst().reduce(Set(notices[0])) { $0.intersection($1) }

        return plans.indices.map { index in
            var parts: [String] = []
            if index == fastest {
                parts.append("Fastest")
            } else {
                let extra = plans[index].expectedTravelTime - plans[fastest].expectedTravelTime
                let minutes = Int((extra / 60).rounded())
                if minutes < 1 {
                    parts.append("About the same time")
                    // A tenth of a mile or more, in the units the route card uses.
                    let difference = plans[index].polyline.length - plans[fastest].polyline.length
                    if abs(difference) >= Units.metresPerMile / 10 {
                        parts.append("\(Units.distance(abs(difference))) \(difference < 0 ? "shorter" : "longer")")
                    }
                } else {
                    parts.append("\(duration(minutes: minutes)) longer")
                }
            }
            if namesDiffer, !names[index].isEmpty {
                parts.append("via \(names[index])")
            }
            if let notice = notices[index].first(where: { !everywhere.contains($0) }) {
                parts.append(notice)
            }
            return parts.joined(separator: ", ")
        }
    }

    /// Minutes the way the route card writes a duration.
    static func duration(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// Apple's words, trimmed, without a trailing full stop, and without the
    /// dashes this app does not put in front of people.
    static func clean(_ text: String) -> String {
        var output = text
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while output.hasSuffix(".") { output.removeLast() }
        return output
    }
}
