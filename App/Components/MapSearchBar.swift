import SwiftUI
import SwiftData
import MapKit
import CloakKit

/// Settings, then search, across the top of the map.
///
/// The settings button carries a small red dot when something there needs
/// attention: a signature about to lapse, relinking not set up on cellular,
/// the free minutes nearly gone, or the link down. The list of what, and the
/// way to each, is at the top of Settings.
struct MapSearchBar: View {
    @Binding var text: String
    var isSearching: Bool
    var needsAttention: Bool
    var focus: FocusState<Bool>.Binding
    var onSettings: () -> Void
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: Metrics.tight) {
            MapButton(symbol: "gearshape", action: onSettings)
                .overlay(alignment: .topTrailing) {
                    if needsAttention {
                        Circle()
                            .fill(Palette.danger)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Palette.ground, lineWidth: 1.5))
                            .offset(x: -3, y: 3)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Settings")
                .accessibilityValue(needsAttention ? "Something needs attention" : "")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color(.secondaryLabel))
                    .accessibilityHidden(true)
                TextField("Search places, addresses", text: $text)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .focused(focus)
                    .onSubmit(onSubmit)
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if !text.isEmpty || focus.wrappedValue {
                    Button {
                        if text.isEmpty {
                            focus.wrappedValue = false
                        } else {
                            text = ""
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color(.secondaryLabel))
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(text.isEmpty ? "Stop searching" : "Clear the search")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, (text.isEmpty && !focus.wrappedValue) || isSearching ? 14 : 0)
            .frame(minHeight: 44)
            .liquidSurface(radius: 22)
            .contentShape(.capsule)
            .onTapGesture { focus.wrappedValue = true }
        }
    }
}

/// What the search card shows: saved places while the field is empty, then
/// what was found as the person types. Plain rows on one group, grey symbols,
/// one line of address. A result drops a pin and opens it, and the pin card
/// has Add as stop; a saved place goes straight there, as it always has.
struct SearchResultsList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \Place.lastUsedAt, order: .reverse) private var places: [Place]

    let results: [MKMapItem]
    let query: String
    var isSearching: Bool
    /// Set when what was typed reads as a latitude and longitude.
    var typedCoordinate: Coordinate?
    var onChoose: (Coordinate, String) -> Void
    var onAddStop: (Coordinate, String) -> Void
    /// True while the search was opened from the Route card to add a stop. A
    /// saved place tapped in that flow must join the route, not teleport,
    /// which is what it used to do.
    var addingStop: Bool = false

    var body: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            savedPlaces
        } else {
            found
        }
    }

    // MARK: Saved places

    @ViewBuilder
    private var savedPlaces: some View {
        if places.isEmpty {
            Text("No saved places")
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryLabel))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.hair)
        } else {
            CardGroup(title: "Saved places", filled: false) {
                ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                    if index > 0 { GroupDivider(inset: 52) }
                    Button {
                        place.markUsed()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if addingStop {
                            onAddStop(place.coordinate, place.name)
                        } else {
                            Task { await model.teleport(to: place.coordinate, label: place.name) }
                        }
                    } label: {
                        CardRow(value: place.name, detail: place.subtitle.isEmpty ? nil : place.subtitle) {
                            symbol(place.symbolName)
                        } trailing: {
                            Image(systemName: addingStop ? "plus" : "arrow.up.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color(.tertiaryLabel))
                                .frame(width: 28)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityHint("Teleports here")
                    .contextMenu {
                        Button("Go here", systemImage: "location") {
                            place.markUsed()
                            Task { await model.teleport(to: place.coordinate, label: place.name) }
                        }
                        Button("Add as a stop", systemImage: "plus") {
                            onAddStop(place.coordinate, place.name)
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { context.delete(place) }
                    }
                }
            }
        }
    }

    // MARK: Results

    @ViewBuilder
    private var found: some View {
        if let typedCoordinate {
            CardGroup(filled: false) {
                Button {
                    onChoose(typedCoordinate, "Dropped pin")
                } label: {
                    CardRow(value: String(format: "%.5f, %.5f", typedCoordinate.latitude, typedCoordinate.longitude),
                            detail: "Drop a pin here") {
                        symbol("mappin")
                    } trailing: {
                        RowChevron()
                    }
                }
                .buttonStyle(RowButtonStyle())
            }
        } else if results.isEmpty {
            Text(isSearching ? "Searching" : (query.trimmingCharacters(in: .whitespaces).count < 3 ? "Keep typing" : "No places found"))
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryLabel))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.hair)
        } else {
            CardGroup(filled: false) {
                ForEach(Array(results.enumerated()), id: \.offset) { index, item in
                    if let location = item.placemark.location {
                        if index > 0 { GroupDivider(inset: 52) }
                        let coordinate = Coordinate(location.coordinate)
                        let name = item.name ?? "Search result"
                        Button {
                            onChoose(coordinate, name)
                        } label: {
                            CardRow(value: name, detail: address(item)) {
                                symbol("mappin")
                            }
                        }
                        .buttonStyle(RowButtonStyle())
                        .accessibilityHint("Drops a pin here")
                    }
                }
            }
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.body)
            .foregroundStyle(Color(.secondaryLabel))
            .frame(width: 24)
    }

    /// One line: the street and town, without the country that every result
    /// shares.
    private func address(_ item: MKMapItem) -> String? {
        let mark = item.placemark
        let street = [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let parts = [street.isEmpty ? nil : street, mark.locality].compactMap { $0 }
        return parts.isEmpty ? mark.title : parts.joined(separator: ", ")
    }
}
