import SwiftUI
import MapKit
import SwiftData
import CloakKit

struct PlacesTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Binding var selection: Coordinate?
    @Binding var tab: SheetTab

    @Query(sort: \Place.lastUsedAt, order: .reverse) private var places: [Place]
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.regular) {
                searchField

                if let selection {
                    selectedCard(selection)
                }

                if !results.isEmpty {
                    Section(title: "Search results") {
                        ForEach(Array(results.enumerated()), id: \.offset) { index, item in
                            Row(symbol: "magnifyingglass",
                                title: item.name ?? "Unnamed",
                                subtitle: item.placemark.title,
                                showsDivider: index < results.count - 1) {
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.dim)
                            }
                            .contentShape(.rect)
                            .onTapGesture {
                                guard let location = item.placemark.location else { return }
                                let coordinate = Coordinate(location.coordinate)
                                self.selection = coordinate
                                Task { await model.teleport(to: coordinate, label: item.name ?? "Search result") }
                            }
                        }
                    }
                }

                if places.isEmpty {
                    EmptyNote(
                        symbol: "mappin.and.ellipse",
                        title: "No saved places yet",
                        detail: "Search for somewhere, or press and hold anywhere on the map, then save it here.")
                } else {
                    Section(title: "Saved places") {
                        ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                            Row(symbol: place.symbolName,
                                title: place.name,
                                subtitle: place.subtitle.isEmpty ? nil : place.subtitle,
                                showsDivider: index < places.count - 1) {
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.dim)
                            }
                            .contentShape(.rect)
                            .onTapGesture {
                                place.markUsed()
                                Task { await model.teleport(to: place.coordinate, label: place.name) }
                            }
                            .contextMenu {
                                Button("Go here") {
                                    place.markUsed()
                                    Task { await model.teleport(to: place.coordinate, label: place.name) }
                                }
                                Button("Add as a stop") {
                                    model.addStop(place.coordinate, title: place.name)
                                    tab = .route
                                }
                                Button("Delete", role: .destructive) { context.delete(place) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.regular)
            .padding(.vertical, Metrics.regular)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.dim)
            TextField("Search or paste 37.3318, -122.0311", text: $query)
                .textFieldStyle(.plain)
                .font(.label(15))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { Task { await search() } }
                .onChange(of: query) { _, _ in Task { await search() } }
            if searching {
                ProgressView().controlSize(.mini)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.dim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Palette.raised, in: .rect(cornerRadius: 13, style: .continuous))
    }

    private func selectedCard(_ coordinate: Coordinate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Dropped pin")
            Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                .font(.readout(15))
                .foregroundStyle(.white)

            Button("Teleport here") {
                Task { await model.teleport(to: coordinate, label: "Dropped pin") }
            }
            .buttonStyle(PrimaryButtonStyle())

            HStack(spacing: 10) {
                Button {
                    context.insert(Place(name: "Saved place", coordinate: coordinate))
                } label: {
                    Label("Save", systemImage: "star")
                }
                .buttonStyle(QuietButtonStyle())

                Button {
                    model.routeWaypoints.append(
                        RouteWaypoint(coordinate: coordinate, title: "Stop \(model.routeWaypoints.count + 1)")
                    )
                    tab = .route
                } label: {
                    Label("Add stop", systemImage: "plus")
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(16)
        .background(Palette.surface, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 2 else {
            results = []
            return
        }
        if let coordinate = CoordinateParser.parse(trimmed) {
            selection = coordinate
            results = []
            return
        }
        searching = true
        defer { searching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let real = model.realPosition {
            request.region = MKCoordinateRegion(center: real.clCoordinate, latitudinalMeters: 60000, longitudinalMeters: 60000)
        }
        guard let response = try? await MKLocalSearch(request: request).start() else { return }
        results = Array(response.mapItems.prefix(8))
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
