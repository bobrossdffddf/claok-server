import SwiftUI
import SwiftData
import MapKit
import CloakKit

/// Builds a whole believable week from where you live, anchored to real
/// places. This is the thing nothing else in the category does: it fills the
/// empty history around your set-piece trips with an ordinary life.
struct LivingCoverView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var model

    @Query(sort: \Place.name) private var places: [Place]

    @State private var homeID: UUID?
    @State private var workID: UUID?
    @State private var density = 0.6
    @State private var stage: Stage = .setup
    @State private var found: [DiscoveredPlace] = []
    @State private var problem: String?
    @State private var previewDay = Date.now

    private enum Stage: Equatable {
        case setup
        case discovering
        case ready
    }

    private let finder = PlaceFinder()

    var body: some View {
        NavigationStack {
            List {
                introSection
                switch stage {
                case .setup: setup
                case .discovering: discovering
                case .ready: ready
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Living Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
    }

    private var introSection: some View {
        SwiftUI.Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("A whole week, not one trip")
                        .font(.headline)
                    Text("Cloak runs an ordinary life around real places near you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .foregroundStyle(.tint)
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Tell Cloak where you live. It finds the real cafes, shops and gyms around you and runs a believable life on its own: home overnight, out at the usual time, a stop or two at genuine local places, home in the evening. Every day different, none of them impossible.")
        }
    }

    private var home: Place? { places.first { $0.id == homeID } }
    private var work: Place? { places.first { $0.id == workID } }

    @ViewBuilder
    private var setup: some View {
        if places.isEmpty {
            SwiftUI.Section {
                ContentUnavailableView(
                    "Save your home first",
                    systemImage: "mappin.slash",
                    description: Text("Find your home on the map and save it as a place, then come back here. Work is optional."))
            }
        } else {
            SwiftUI.Section("Home") {
                placePicker(selection: $homeID, exclude: workID)
            }

            SwiftUI.Section {
                placePicker(selection: $workID, exclude: homeID, allowsNone: true)
            } header: {
                Text("Work (optional)")
            } footer: {
                Text("No work? Cloak uses an everyday nearby place so the day still has somewhere to go.")
            }

            SwiftUI.Section {
                Slider(value: $density, in: 0.2...1.0)
                    .accessibilityLabel("How busy")
                    .accessibilityValue(densityLabel)
            } header: {
                Text("How busy")
            } footer: {
                Text(densityLabel)
            }

            SwiftUI.Section {
                if problem != nil {
                    Label {
                        Text("The map has no named places near there")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.danger)
                    }
                }

                Button {
                    Task { await discover() }
                } label: {
                    Label("Find real places near me", systemImage: "location.magnifyingglass")
                        .modifier(ActionRowStyle())
                }
                .disabled(homeID == nil)
            } footer: {
                if problem != nil {
                    Text("Cloak can still run a home and work routine. Try adding a Work place, or set this up as a plain routine instead.")
                }
            }
        }
    }

    private var discovering: some View {
        SwiftUI.Section {
            HStack(spacing: 12) {
                ProgressView()
                Text("Reading the map around your places")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var ready: some View {
        SwiftUI.Section("Found \(found.count) real places") {
            ForEach(PlaceCategory.allCases, id: \.self) { category in
                let matches = found.filter { $0.category == category }
                if !matches.isEmpty {
                    LabeledContent {
                        Text("\(matches.count)")
                            .monospacedDigit()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.label)
                                Text(matches.prefix(3).map(\.name).joined(separator: ", ") + (matches.count > 3 ? " and \(matches.count - 3) more" : ""))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        } icon: {
                            Image(systemName: category.symbol)
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }

        previewSection

        SwiftUI.Section {
            Button {
                save()
            } label: {
                Label("Start living this", systemImage: "play.fill")
            }

            Button {
                stage = .setup
            } label: {
                Label("Find places again", systemImage: "arrow.uturn.backward")
            }
        }
    }

    private var previewSection: some View {
        let routine = draftRoutine()
        let plan = routine.plan(for: previewDay)
        return SwiftUI.Section("A sample day") {
            ForEach(Array(plan.segments.enumerated()), id: \.offset) { _, segment in
                HStack(spacing: 12) {
                    Text(segment.start.formatted(date: .omitted, time: .shortened))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(minWidth: 76, alignment: .leading)
                    Label {
                        Text(segment.kind.name)
                    } icon: {
                        Image(systemName: segmentSymbol(segment.kind))
                            .foregroundStyle(.tint)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            Button {
                previewDay = previewDay.addingTimeInterval(86_400)
            } label: {
                Label("See another day", systemImage: "arrow.clockwise")
            }
        }
    }

    private func segmentSymbol(_ kind: RoutineDay.Kind) -> String {
        switch kind {
        case .dwell(_, let name, _):
            found.first { $0.name == name }?.category.symbol ?? "house.fill"
        case .travel:
            "car.fill"
        }
    }

    private var densityLabel: String {
        switch density {
        case ..<0.35: "Quiet. Mostly straight home, the odd errand."
        case ..<0.7: "Normal. A stop most days, sometimes two."
        default: "Busy. Errands most days, often a couple."
        }
    }

    private func placePicker(selection: Binding<UUID?>, exclude: UUID?, allowsNone: Bool = false) -> some View {
        Group {
            if allowsNone {
                pickRow(title: "None", selected: selection.wrappedValue == nil) { selection.wrappedValue = nil }
            }
            ForEach(places.filter { $0.id != exclude }) { place in
                pickRow(title: place.name, selected: selection.wrappedValue == place.id) {
                    selection.wrappedValue = place.id
                }
            }
        }
    }

    private func pickRow(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                // Named label colour: `.primary` inside a list button
                // resolves to the tint.
                Text(title)
                    .foregroundStyle(Color(.label))
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func discover() async {
        guard let home else { return }
        problem = nil
        stage = .discovering
        let cover = LivingCover(
            home: home.coordinate,
            homeName: home.name,
            work: work?.coordinate,
            workName: work?.name ?? "Work"
        )
        let discovered = await cover.discover(using: finder)
        found = discovered
        if discovered.isEmpty {
            problem = "The map has no named places near there. Cloak can still run a home and work routine; try adding a Work place, or set this up as a plain routine instead."
            stage = .setup
        } else {
            stage = .ready
        }
    }

    private func draftRoutine() -> Routine {
        guard let home else { return Routine(home: Coordinate(latitude: 0, longitude: 0), work: Coordinate(latitude: 0, longitude: 0)) }
        let cover = LivingCover(home: home.coordinate, homeName: home.name, work: work?.coordinate, workName: work?.name ?? "Work")
        return cover.routine(from: found, density: density)
    }

    private func save() {
        let routine = draftRoutine()
        context.insert(routine)
        try? context.save()
        dismiss()
    }
}

/// A list action's label that greys out when the action is unavailable. Left
/// to itself a disabled list button kept a white title beside a teal glyph,
/// which reads as a live row.
private struct ActionRowStyle: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiaryLabel)))
    }
}
