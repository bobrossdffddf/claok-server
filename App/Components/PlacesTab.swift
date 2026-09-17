import SwiftUI
import MapKit
import SwiftData
import CoreLocation
import CloakKit

/// The dropped pin: where it is, and what can be done with it.
///
/// Normally Teleport is the one accent action, with Save and Add as stop under
/// it. Reached from the route card's Add a stop flow, that flips: Add as stop
/// becomes the accent action and Teleport steps back, so the button the person
/// came for is the obvious one. Saved places are not here; they are in the
/// search card while the field is empty.
struct PlacesCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let chrome: CardContext
    let coordinate: Coordinate
    /// The name search or a tap gave this place, so a saved place or a stop
    /// keeps it. "Dropped pin" when a bare pin was dropped on the map.
    var name: String = "Dropped pin"
    /// True when the pin was reached from the route card's Add a stop flow.
    var addingStop: Bool = false
    /// Opens another tool's card, for Add as stop.
    var onOpen: (MapTool) -> Void

    @State private var journeyTarget: Coordinate?
    @State private var showsSaveDialog = false
    @State private var placeName = ""
    @State private var suggestedName: String?
    @State private var justSaved = false

    private var hasRealName: Bool {
        name != "Dropped pin" && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        FloatingCard(
            title: hasRealName ? name : "Dropped pin",
            subtitle: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude),
            onClose: chrome.onClose
        ) {
            VStack(spacing: Metrics.tight) {
                if addingStop {
                    addStopButton(primary: true)
                    actionPair { teleportButton(primary: false); saveButton }
                } else {
                    teleportButton(primary: true)
                    actionPair { saveButton; addStopButton(primary: false) }
                }

                journeyRow
            }
        }
        .task(id: coordinate) {
            if suggestedName == nil, !hasRealName {
                suggestedName = await Self.reverseGeocodedName(coordinate)
            }
        }
        .alert("Name this place", isPresented: $showsSaveDialog) {
            TextField("Home, gym, work", text: $placeName)
            Button("Save") { savePlace() }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(item: $journeyTarget) { target in JourneyView(pin: target) }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.environment["CLOAK_TOUR_SAVE"] == "1" {
                placeName = await defaultName()
                showsSaveDialog = true
            }
        }
        #endif
    }

    /// Two card buttons side by side, stacked at accessibility text sizes so
    /// neither is squeezed below its label.
    @ViewBuilder
    private func actionPair<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: Metrics.tight) { content() }
        } else {
            HStack(spacing: Metrics.tight) { content() }
        }
    }

    private func teleportButton(primary: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task {
                await model.teleport(to: coordinate, label: hasRealName ? name : "Dropped pin")
                // Close the pin card so the running card takes its place;
                // without this nothing on screen said the spoof had started.
                if model.snapshot.isRunning {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    chrome.onClose()
                }
            }
        } label: {
            Label(primary ? "Teleport here" : "Teleport", systemImage: "bolt.fill")
        }
        .modifier(PrimaryOrSecondary(primary: primary))
    }

    private func addStopButton(primary: Bool) -> some View {
        Button {
            // Through the model, not straight onto the array. A direct append
            // skipped the rebuild, so a route already built stayed on screen
            // describing a trip without this stop in it.
            model.addStop(coordinate, title: hasRealName ? name : "Stop \(model.routeWaypoints.count + 1)")
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onOpen(.route)
        } label: {
            Label("Add as stop", systemImage: "plus")
        }
        .modifier(PrimaryOrSecondary(primary: primary))
    }

    private var saveButton: some View {
        Button {
            Task { placeName = await defaultName(); showsSaveDialog = true }
        } label: {
            Label(justSaved ? "Saved" : "Save", systemImage: justSaved ? "checkmark" : "star")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(CardSecondaryButtonStyle())
        .scaleEffect(justSaved && !reduceMotion ? 1.05 : 1)
        .animation(reduceMotion ? nil : .bouncy(duration: 0.4), value: justSaved)
        .accessibilityLabel("Save this place")
    }

    @ViewBuilder
    private var journeyRow: some View {
        if let real = model.realPosition, real.distance(to: coordinate) > 30_000 {
            let flies = Journey.shape(for: real.distance(to: coordinate)) == .fly
            Button {
                journeyTarget = coordinate
            } label: {
                HStack(spacing: Metrics.tight) {
                    Image(systemName: flies ? "airplane.departure" : "car")
                        .foregroundStyle(Color(.secondaryLabel))
                    Text(flies ? "Travel there, with a flight" : "Drive there believably")
                        .foregroundStyle(Color(.label))
                    Spacer(minLength: 0)
                    RowChevron()
                }
                .font(.body)
                .padding(.horizontal, Metrics.hair)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(PressableStyle(scale: 0.98))
        }
    }

    /// The name to suggest when saving: the place's own name, then a
    /// reverse geocoded street, then a plain fallback.
    private func defaultName() async -> String {
        if hasRealName { return name }
        if let suggestedName, !suggestedName.isEmpty { return suggestedName }
        if let found = await Self.reverseGeocodedName(coordinate) { return found }
        return "Saved place"
    }

    private func savePlace() {
        let typed = placeName.trimmingCharacters(in: .whitespaces)
        let final = typed.isEmpty ? (hasRealName ? name : (suggestedName ?? "Saved place")) : typed
        context.insert(Place(name: final, coordinate: coordinate))
        try? context.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        justSaved = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            justSaved = false
        }
    }

    /// A street or place name for a coordinate, or nil when none can be found.
    private static func reverseGeocodedName(_ c: Coordinate) async -> String? {
        let location = CLLocation(latitude: c.latitude, longitude: c.longitude)
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let mark = placemarks?.first else { return nil }
        return mark.name ?? mark.thoroughfare ?? mark.locality
    }
}

/// Makes one card button either the accent primary or the neutral secondary,
/// so a single label can be either depending on the flow it sits in.
private struct PrimaryOrSecondary: ViewModifier {
    let primary: Bool

    func body(content: Content) -> some View {
        if primary {
            content.buttonStyle(PrimaryButtonStyle())
        } else {
            content.buttonStyle(CardSecondaryButtonStyle())
        }
    }
}

enum CoordinateParser {
    static func parse(_ text: String) -> Coordinate? {
        let cleaned = text.replacingOccurrences(of: " ", with: "")
        let parts = cleaned.split(separator: ",")
        guard parts.count == 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]) else { return nil }
        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        return coordinate.isValid ? coordinate : nil
    }
}
