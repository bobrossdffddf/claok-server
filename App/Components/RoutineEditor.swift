import SwiftUI
import SwiftData
import MapKit
import CloakKit

/// Sets up the two places a routine runs between, and when.
struct RoutineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var model

    @Query(sort: \Place.name) private var places: [Place]

    var existing: Routine?

    @State private var name = "Weekday"
    @State private var homeID: UUID?
    @State private var workID: UUID?
    @State private var leave = Calendar.current.date(bySettingHour: 8, minute: 15, second: 0, of: .now) ?? .now
    @State private var back = Calendar.current.date(bySettingHour: 17, minute: 30, second: 0, of: .now) ?? .now
    @State private var jitter = 8.0
    @State private var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    @State private var mode: TravelMode = .drive
    @State private var drift = 9.0

    private let dayNames = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    Text("A routine runs on its own all day. The phone sleeps at home, leaves near the time you set but never exactly on it, sits at work drifting a few metres the way a real one does, and comes back in the evening. No two days come out the same.")
                        .font(.label(12))
                        .foregroundStyle(Palette.dim)
                }

                SwiftUI.Section("Places") {
                    if places.count < 2 {
                        Text("Save at least two places first. Search for them on the map, then save each one.")
                            .font(.label(13))
                            .foregroundStyle(Palette.warn)
                    }
                    Picker("Home", selection: $homeID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(places) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Picker("Work", selection: $workID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(places) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Picker("Getting there", selection: $mode) {
                        ForEach(TravelMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                SwiftUI.Section("Hours") {
                    DatePicker("Leaves home", selection: $leave, displayedComponents: .hourAndMinute)
                    DatePicker("Leaves work", selection: $back, displayedComponents: .hourAndMinute)

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
                }

                SwiftUI.Section(
                    header: Text("Slack"),
                    footer: Text("How far either departure may slide on a given day. Leaving at exactly the same minute every morning for a month is the easiest thing in the world to notice.")
                ) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Up to \(Int(jitter)) minutes either way")
                                .font(.label(14))
                            Spacer()
                        }
                        Slider(value: $jitter, in: 0...30, step: 1).tint(Palette.accent)
                    }
                }

                SwiftUI.Section(
                    header: Text("Sitting still"),
                    footer: Text("A phone on a desk wanders. Pinned to one exact coordinate for eight hours it looks like a pin, not a phone.")
                ) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Drifts up to \(Int(drift)) m")
                                .font(.label(14))
                            Spacer()
                        }
                        Slider(value: $drift, in: 3...40, step: 1).tint(Palette.accent)
                    }
                }

                SwiftUI.Section("Name") {
                    TextField("Weekday", text: $name)
                }

                if let preview = previewPlan {
                    SwiftUI.Section("Tomorrow, as it stands") {
                        ForEach(preview.segments) { segment in
                            HStack {
                                Text(segment.kind.name)
                                    .font(.label(13))
                                Spacer()
                                Text(clock(segment.start))
                                    .font(.readout(12))
                                    .foregroundStyle(Palette.dim)
                            }
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New routine" : "Edit routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(homeID == nil || workID == nil || homeID == workID)
                }
            }
        }
        .onAppear(perform: load)
    }

    private var previewPlan: RoutineDay? {
        guard let home = places.first(where: { $0.id == homeID }),
              let work = places.first(where: { $0.id == workID }) else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: leave)
        let backParts = Calendar.current.dateComponents([.hour, .minute], from: back)
        let sample = Routine(
            name: name,
            home: home.coordinate, homeName: home.name,
            work: work.coordinate, workName: work.name,
            leaveHour: parts.hour ?? 8, leaveMinute: parts.minute ?? 0,
            returnHour: backParts.hour ?? 17, returnMinute: backParts.minute ?? 0,
            jitterMinutes: Int(jitter),
            weekdays: weekdays.reduce(0) { $0 | (1 << $1) },
            mode: mode,
            dwellDrift: drift
        )
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        return sample.plan(for: tomorrow)
    }

    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func load() {
        guard let existing else { return }
        name = existing.name
        homeID = places.first { $0.coordinate == existing.home }?.id
        workID = places.first { $0.coordinate == existing.work }?.id
        leave = Calendar.current.date(bySettingHour: existing.leaveHour, minute: existing.leaveMinute, second: 0, of: .now) ?? .now
        back = Calendar.current.date(bySettingHour: existing.returnHour, minute: existing.returnMinute, second: 0, of: .now) ?? .now
        jitter = Double(existing.jitterMinutes)
        weekdays = Set((0..<7).filter { existing.weekdays & (1 << $0) != 0 })
        mode = existing.mode
        drift = existing.dwellDrift
    }

    private func save() {
        guard let home = places.first(where: { $0.id == homeID }),
              let work = places.first(where: { $0.id == workID }) else { return }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: leave)
        let backParts = Calendar.current.dateComponents([.hour, .minute], from: back)
        let mask = weekdays.reduce(0) { $0 | (1 << $1) }

        if let existing {
            existing.name = name
            existing.homeName = home.name
            existing.homeLatitude = home.coordinate.latitude
            existing.homeLongitude = home.coordinate.longitude
            existing.workName = work.name
            existing.workLatitude = work.coordinate.latitude
            existing.workLongitude = work.coordinate.longitude
            existing.leaveHour = parts.hour ?? 8
            existing.leaveMinute = parts.minute ?? 0
            existing.returnHour = backParts.hour ?? 17
            existing.returnMinute = backParts.minute ?? 0
            existing.jitterMinutes = Int(jitter)
            existing.weekdays = mask
            existing.modeRaw = mode.rawValue
            existing.dwellDrift = drift
        } else {
            context.insert(Routine(
                name: name,
                home: home.coordinate, homeName: home.name,
                work: work.coordinate, workName: work.name,
                leaveHour: parts.hour ?? 8, leaveMinute: parts.minute ?? 0,
                returnHour: backParts.hour ?? 17, returnMinute: backParts.minute ?? 0,
                jitterMinutes: Int(jitter),
                weekdays: mask,
                mode: mode,
                dwellDrift: drift
            ))
        }
        try? context.save()
        dismiss()
    }
}
