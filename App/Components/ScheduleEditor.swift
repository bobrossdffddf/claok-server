import SwiftUI
import SwiftData
import CloakKit

/// Creates or edits one scheduled run.
struct ScheduleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(RunScheduler.self) private var scheduler

    @Query(sort: \Place.name) private var places: [Place]
    @Query(sort: \SavedRoute.createdAt, order: .reverse) private var routes: [SavedRoute]
    @Query(sort: \RecordedTrip.recordedAt, order: .reverse) private var trips: [RecordedTrip]

    var existing: ScheduledRun?

    @State private var name = ""
    @State private var kind: ScheduledRun.Kind = .place
    @State private var placeID: UUID?
    @State private var routeID: UUID?
    @State private var tripID: UUID?
    @State private var time = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
    @State private var weekdays: Set<Int> = []
    @State private var onceOn = Date.now
    @State private var duration = 0

    private let dayNames = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("What") {
                    Picker("Kind", selection: $kind) {
                        ForEach(ScheduledRun.Kind.allCases, id: \.self) { option in
                            Label(option.title, systemImage: option.symbol).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch kind {
                    case .place:
                        Picker("Place", selection: $placeID) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(places) { place in
                                Text(place.name).tag(UUID?.some(place.id))
                            }
                        }
                    case .route:
                        Picker("Route", selection: $routeID) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(routes) { route in
                                Text(route.name).tag(UUID?.some(route.id))
                            }
                        }
                    case .trip:
                        Picker("Recording", selection: $tripID) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(trips) { trip in
                                Text(trip.name).tag(UUID?.some(trip.id))
                            }
                        }
                    }
                }

                SwiftUI.Section("When") {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)

                    HStack(spacing: 6) {
                        ForEach(0..<7, id: \.self) { day in
                            Button {
                                if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
                            } label: {
                                Text(dayNames[day])
                                    .font(.label(13, weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .foregroundStyle(weekdays.contains(day) ? Palette.ground : .white)
                                    .background(
                                        weekdays.contains(day) ? Palette.accent : Color.white.opacity(0.08),
                                        in: .rect(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    if weekdays.isEmpty {
                        DatePicker("On", selection: $onceOn, in: Date.now..., displayedComponents: .date)
                        Text("Pick days above to repeat this every week instead.")
                            .font(.label(12))
                            .foregroundStyle(Palette.dim)
                    }
                }

                SwiftUI.Section("How long") {
                    Picker("Stop after", selection: $duration) {
                        Text("When I stop it").tag(0)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                        Text("8 hours").tag(480)
                    }
                }

                SwiftUI.Section("Name") {
                    TextField("Morning commute", text: $name)
                }

                SwiftUI.Section {
                    Text("Cloak starts this itself while it is running. If it has been shut down, you get a notification a minute beforehand instead — iOS will not let a sideloaded app wake up on its own.")
                        .font(.label(12))
                        .foregroundStyle(Palette.dim)
                }
            }
            .navigationTitle(existing == nil ? "New schedule" : "Edit schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!isValid)
                }
            }
        }
        .onAppear(perform: load)
    }

    private var isValid: Bool {
        switch kind {
        case .place: placeID != nil
        case .route: routeID != nil
        case .trip: tripID != nil
        }
    }

    private func load() {
        guard let existing else { return }
        name = existing.name
        kind = existing.kind
        switch existing.kind {
        case .place:
            placeID = places.first { $0.coordinate == existing.coordinate }?.id
        case .route: routeID = existing.targetID
        case .trip: tripID = existing.targetID
        }
        time = Calendar.current.date(bySettingHour: existing.hour, minute: existing.minute, second: 0, of: .now) ?? .now
        weekdays = Set((0..<7).filter { existing.weekdays & (1 << $0) != 0 })
        onceOn = existing.onceOn ?? .now
        duration = existing.durationMinutes
    }

    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let mask = weekdays.reduce(0) { $0 | (1 << $1) }

        var coordinate = Coordinate(latitude: 0, longitude: 0)
        var target: UUID?
        var fallbackName = "Scheduled run"

        switch kind {
        case .place:
            guard let place = places.first(where: { $0.id == placeID }) else { return }
            coordinate = place.coordinate
            fallbackName = place.name
        case .route:
            guard let route = routes.first(where: { $0.id == routeID }) else { return }
            target = route.id
            fallbackName = route.name
        case .trip:
            guard let trip = trips.first(where: { $0.id == tripID }) else { return }
            target = trip.id
            fallbackName = trip.name
        }

        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? fallbackName : name

        if let existing {
            existing.name = finalName
            existing.kindRaw = kind.rawValue
            existing.targetID = target
            existing.latitude = coordinate.latitude
            existing.longitude = coordinate.longitude
            existing.hour = parts.hour ?? 8
            existing.minute = parts.minute ?? 0
            existing.weekdays = mask
            existing.onceOn = mask == 0 ? onceOn : nil
            existing.durationMinutes = duration
            existing.isEnabled = true
        } else {
            context.insert(ScheduledRun(
                name: finalName,
                kind: kind,
                targetID: target,
                coordinate: coordinate,
                hour: parts.hour ?? 8,
                minute: parts.minute ?? 0,
                weekdays: mask,
                onceOn: mask == 0 ? onceOn : nil,
                durationMinutes: duration
            ))
        }

        try? context.save()
        scheduler.refresh()
        dismiss()
    }
}
