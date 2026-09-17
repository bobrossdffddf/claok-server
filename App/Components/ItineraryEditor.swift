import SwiftUI
import CloakKit

/// The flight itinerary, with the parts of it that are opinions rather than
/// arithmetic made editable.
///
/// The planner picks the nearest sensible airports, a standard hour and twenty
/// at the gate and half an hour to get out the other end. All of that is a
/// guess about one particular person on one particular day, and being wrong
/// about it shows: somebody who never checks a bag does not spend eighty
/// minutes airside, and somebody flying out of a field they can see from the
/// house does not want a forty minute drive in the history first.
///
/// Nothing here edits legs. Every control changes the plan and the itinerary
/// is laid out again from scratch, which is what guarantees it stays in order.
///
/// This is list content, not a screen. It is a run of `Section`s meant to sit
/// inside a `List`, and it deliberately has no start button of its own: the
/// screen hosting it owns the one primary action. It used to carry its own,
/// and on the Travel there screen that meant the itinerary drawn twice and two
/// Start the trip buttons one above the other.
struct ItineraryEditor: View {
    /// Whether to draw the summary and the legs. The Travel there screen
    /// already shows both in its own richer form, so it turns this off.
    var showsItinerary = true

    @Environment(AppModel.self) private var model
    @Bindable private var journey = JourneyController.shared

    @State private var remindMe = RunScheduler.remindsAboutTrips
    @State private var askingAboutReminders = false

    private var plan: Journey.Plan? { journey.proposal?.plan }

    var body: some View {
        if showsItinerary, journey.planning {
            SwiftUI.Section {
                Label {
                    Text("Working out the airports and naming both ends")
                        .foregroundStyle(.secondary)
                } icon: {
                    ProgressView()
                }
            }
        } else if showsItinerary, let problem = journey.problem {
            SwiftUI.Section {
                Label {
                    Text(problem)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warn)
                }
            }
        } else if let itinerary = journey.proposal {
            if showsItinerary {
                summarySection(itinerary)
                legsSection(itinerary)
            }
            if plan != nil, !journey.isRunning {
                airportsSection
                departureSection
                holdsSection
                drivesSection
            }
            remindersSection(itinerary)
        } else if showsItinerary {
            SwiftUI.Section {
                ContentUnavailableView(
                    "No trip planned yet",
                    systemImage: "airplane.departure",
                    description: Text("Drop a pin on the map and choose Travel there. The itinerary lands here, ready to change before you start.")
                )
            }
        }
    }

    // MARK: - The plan, as it stands

    private func summarySection(_ itinerary: Journey) -> some View {
        SwiftUI.Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(itinerary.summary)
                    .font(.headline)
                Text("Leaves \(time(itinerary.departs)), arrives \(time(itinerary.arrives))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            if journey.isRunning, let waiting = journey.waitingUntil {
                LabeledContent {
                    Text(waiting, style: .relative)
                        .monospacedDigit()
                        .foregroundStyle(Palette.warn)
                } label: {
                    Label("Waiting for the departure time", systemImage: "hourglass")
                }
            }

            if journey.isEdited, !journey.isRunning {
                Button("Put the suggested plan back") {
                    journey.resetPlan()
                }
            }
        }
    }

    private func legsSection(_ itinerary: Journey) -> some View {
        SwiftUI.Section("Itinerary") {
            ForEach(Array(itinerary.legs.enumerated()), id: \.element.id) { index, leg in
                LabeledContent {
                    Text(Journey.clock(leg.duration))
                        .monospacedDigit()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(leg.name)
                            Text("\(time(leg.start)) to \(time(leg.end))")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: symbol(for: leg))
                            .foregroundStyle(tint(for: leg, at: index))
                    }
                }
            }
        }
    }

    private func tint(for leg: Journey.Leg, at index: Int) -> Color {
        if journey.isRunning, index == journey.legIndex { return Palette.ok }
        return leg.isDark ? Palette.warn : Palette.accent
    }

    private func symbol(for leg: Journey.Leg) -> String {
        switch leg.kind {
        case .drive: "car.fill"
        case .hold: leg.isDark ? "airplane" : "building.2.fill"
        }
    }

    // MARK: - Airports

    private var airportsSection: some View {
        SwiftUI.Section {
            airportPicker(
                "Out of",
                symbol: "airplane.departure",
                current: plan?.origin,
                choices: journey.originChoices
            ) { picked in edit { $0.origin = picked } }

            airportPicker(
                "Into",
                symbol: "airplane.arrival",
                current: plan?.destination,
                choices: journey.destinationChoices
            ) { picked in edit { $0.destination = picked } }
        } header: {
            Text("Airports")
        } footer: {
            Text("Nearest first. Flying out of a smaller field is often the more believable story, and it is always the shorter drive.")
        }
    }

    private func airportPicker(
        _ title: String,
        symbol: String,
        current: Journey.Airport?,
        choices: [Journey.Airport],
        pick: @escaping (Journey.Airport) -> Void
    ) -> some View {
        let options = options(choices, including: current)
        let selection = Binding<String>(
            get: { current?.iata ?? "" },
            set: { iata in
                guard let airport = options.first(where: { $0.iata == iata }) else { return }
                pick(airport)
            }
        )
        return Picker(selection: selection) {
            if current == nil {
                Text("Not chosen").tag("")
            }
            ForEach(options, id: \.iata) { airport in
                Text("\(airport.iata), \(airport.name)").tag(airport.iata)
            }
        } label: {
            Label(title, systemImage: symbol)
        }
        .pickerStyle(.menu)
        .disabled(options.count < 2)
    }

    /// The airport in use is always on the list, even when the lookup that
    /// found it has since been thrown away.
    private func options(_ choices: [Journey.Airport], including current: Journey.Airport?) -> [Journey.Airport] {
        guard let current else { return choices }
        return choices.contains(where: { $0.iata == current.iata }) ? choices : [current] + choices
    }

    // MARK: - Departure

    private var departureSection: some View {
        SwiftUI.Section {
            DatePicker(
                selection: field(\.departure, default: Date()),
                displayedComponents: [.date, .hourAndMinute]
            ) {
                Label("Leaves at", systemImage: "clock")
            }
        } header: {
            Text("Departure")
        } footer: {
            Text("A time in the future is waited for rather than started early. Cloak has to stay open for that, so a departure hours away is a reminder to yourself more than a schedule.")
        }
    }

    // MARK: - Holds

    private var holdsSection: some View {
        SwiftUI.Section {
            holdRow(
                "Before the flight",
                symbol: "figure.walk.departure",
                value: field(\.beforeFlight, default: Journey.beforeFlight)
            )
            holdRow(
                "After landing",
                symbol: "figure.walk.arrival",
                value: field(\.afterFlight, default: Journey.afterFlight)
            )
        } header: {
            Text("Time in the terminal")
        } footer: {
            Text("Drag either one to nothing to cut that leg out of the trip.")
        }
    }

    private func holdRow(_ title: String, symbol: String, value: Binding<TimeInterval>) -> some View {
        let minutes = Binding<Double>(
            get: { min(max(0, value.wrappedValue / 60), 240) },
            set: { value.wrappedValue = $0 * 60 }
        )
        let isCut = value.wrappedValue <= 0
        return VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Text(isCut ? "Cut" : Journey.clock(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(isCut ? Palette.warn : .secondary)
            } label: {
                Label(title, systemImage: symbol)
            }
            Slider(value: minutes, in: 0...240, step: 5) {
                Text(title)
            }
            .accessibilityValue(isCut ? "Cut" : Journey.clock(value.wrappedValue))
        }
        .padding(.vertical, 4)
    }

    // MARK: - The drives

    private var drivesSection: some View {
        SwiftUI.Section {
            Toggle(isOn: field(\.drivesToAirport, default: true)) {
                driveLabel(
                    "Drive to the airport",
                    detail: plan.map { "About \(Exposure.describe($0.from.distance(to: $0.origin.door)))" }
                )
            }
            Toggle(isOn: field(\.drivesFromAirport, default: true)) {
                driveLabel(
                    "Drive on to the pin",
                    detail: plan.map { "About \(Exposure.describe($0.destination.door.distance(to: $0.to)))" }
                )
            }
        } header: {
            Text("Getting to and from")
        } footer: {
            Text("Leave one out when you would not have made that drive: dropped at the kerb, already airside, met at arrivals.")
        }
    }

    private func driveLabel(_ title: String, detail: String?) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "car.fill")
        }
    }

    // MARK: - Reminders

    private func remindersSection(_ itinerary: Journey) -> some View {
        SwiftUI.Section {
            Toggle(isOn: reminderBinding) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tell me when to switch")
                        Text(cueSummary(itinerary))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "bell.badge")
                }
            }
            .disabled(askingAboutReminders || itinerary.cues.isEmpty)

            if remindMe {
                ForEach(itinerary.cues) { cue in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cue.title)
                            Text(cue.body)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: cue.kind == .vpn ? "shield.lefthalf.filled" : "clock.arrow.2.circlepath")
                            .foregroundStyle(Palette.warn)
                    }
                }
            }
        } header: {
            Text("While you are in the air")
        } footer: {
            Text(footer(itinerary))
        }
    }

    private var reminderBinding: Binding<Bool> {
        Binding(
            get: { remindMe },
            set: { wanted in
                remindMe = wanted
                askingAboutReminders = true
                Task {
                    let granted = await journey.setReminders(wanted)
                    askingAboutReminders = false
                    guard wanted else { return }
                    remindMe = granted
                    if !granted {
                        model.banner = "Cloak cannot send notifications yet. Turn them on for Cloak in Settings, then try again."
                    }
                }
            }
        )
    }

    private func cueSummary(_ itinerary: Journey) -> String {
        let cues = itinerary.cues
        guard !cues.isEmpty else {
            return "Nothing on this trip needs switching. It stays inside one region and one time zone."
        }
        let what = itinerary.changesTimeZone ? "your VPN exit and the phone's clock" : "your VPN exit"
        return "A notification at the one moment changing \(what) is invisible, halfway through the flight."
    }

    private func footer(_ itinerary: Journey) -> String {
        guard itinerary.changesRegion else {
            return "Nothing to switch on a drive."
        }
        return "Not when you land. The flight is the only stretch where the phone reports nothing at all, so a connection that comes out somewhere new, or a clock that jumps, has nothing next to it to line up against."
    }

    // MARK: - Editing

    /// Every control writes through here: change the plan, lay the legs out
    /// again. Nothing ever reaches in and moves a leg.
    private func edit(_ change: (inout Journey.Plan) -> Void) {
        guard var plan else { return }
        change(&plan)
        journey.apply(plan)
    }

    private func field<T>(_ keyPath: WritableKeyPath<Journey.Plan, T>, default fallback: T) -> Binding<T> {
        Binding(
            get: { plan?[keyPath: keyPath] ?? fallback },
            set: { value in edit { $0[keyPath: keyPath] = value } }
        )
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// The one primary action for a trip that is not being shown on the Travel
/// there screen: start it, or stop it once it is under way.
struct ItineraryAction: View {
    @Environment(AppModel.self) private var model
    @Bindable private var journey = JourneyController.shared

    var body: some View {
        if let itinerary = journey.proposal, !journey.planning {
            if journey.isRunning {
                Button(role: .destructive) {
                    journey.cancel()
                    Task { await model.stop() }
                } label: {
                    Text("Stop the trip").font(.headline)
                }
                .buttonStyle(PrimaryButtonStyle(tint: Palette.danger))
            } else {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    journey.start()
                } label: {
                    Text(itinerary.shape == .fly ? "Start the trip" : "Start the drive")
                        .font(.headline)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}
