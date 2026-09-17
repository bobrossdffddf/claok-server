import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CloakKit

/// The trips card: recordings, schedules, the routine and the flight
/// planner, as one scrolling list of groups.
///
/// These used to be four panes behind a segmented control inside the tab,
/// which made them a third level of navigation inside a sheet that already had
/// one. Each is short enough to be a section, so now they are: every primary
/// action is one scroll away, nothing is hidden behind a control whose other
/// three states you have to remember, and the flight planner, which is a full
/// editor of its own, opens as a sheet the way the schedule and routine
/// editors always have.
struct TripsCard: View {
    @Environment(AppModel.self) private var model
    @Environment(RunScheduler.self) private var scheduler
    @Environment(\.modelContext) private var context

    @Query(sort: \RecordedTrip.recordedAt, order: .reverse) private var trips: [RecordedTrip]
    @Query(sort: \ScheduledRun.createdAt, order: .reverse) private var runs: [ScheduledRun]
    @Query(sort: \Routine.createdAt, order: .reverse) private var routines: [Routine]

    @State private var showsImporter = false
    @State private var editing: ScheduledRun?
    @State private var creating = false
    @State private var editingRoutine: Routine?
    @State private var creatingRoutine = false
    @State private var buildingCover = false
    @State private var showsFlight = false

    let chrome: CardContext

    private var journey: JourneyController { JourneyController.shared }

    var body: some View {
        FloatingCard(title: "Trips", collapsible: true, onClose: chrome.onClose) {
            VStack(alignment: .leading, spacing: Metrics.regular) {
                recordSection
                scheduleSection
                routineSection
                if let first = routines.first {
                    todaySection(first)
                }
                flightSection
            }
        }
        .sheet(isPresented: $creating) { ScheduleEditor() }
        .sheet(item: $editing) { ScheduleEditor(existing: $0) }
        .sheet(isPresented: $creatingRoutine) { RoutineEditor() }
        .sheet(isPresented: $buildingCover) { LivingCoverView() }
        .sheet(item: $editingRoutine) { RoutineEditor(existing: $0) }
        .sheet(isPresented: $showsFlight) { flightEditor }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.xml, .data]) { result in
            guard case .success(let url) = result else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url),
                  let document = GPXParser().parse(data: data) else {
                model.banner = "That file did not parse as GPX."
                return
            }
            let fixes = document.points.map {
                SimulatedFix(coordinate: $0.coordinate, timestamp: $0.time ?? .now)
            }
            context.insert(RecordedTrip(name: document.name, fixes: fixes))
            model.banner = "Imported \(document.points.count) points."
        }
    }

    // MARK: - Record

    private var recordSection: some View {
        CardGroup(title: "Record") {
            VStack(alignment: .leading, spacing: Metrics.snug) {
                if model.isRecording {
                    HStack(spacing: Metrics.snug) {
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(Palette.danger)
                            .symbolEffect(.pulse, isActive: true)
                            .accessibilityHidden(true)
                        Text("Recording, \(model.recordingFixes.count) points\(model.isRecordingReal ? " from your real drive" : "")")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Color(.label))
                            .lineLimit(1)
                    }

                    Button {
                        let fixes = model.finishRecording()
                        guard fixes.count > 1 else {
                            model.banner = "Not enough points to save."
                            return
                        }
                        context.insert(RecordedTrip(name: "Trip \(trips.count + 1)", fixes: fixes))
                    } label: {
                        Label("Stop and save", systemImage: "stop.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: Palette.danger))
                } else {
                    Button {
                        model.startRecording()
                    } label: {
                        Label(model.snapshot.isRunning ? "Start recording" : "Record my real drive", systemImage: "record.circle")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(Metrics.snug)

            GroupDivider()

            if trips.isEmpty {
                emptyLine("Nothing recorded yet")
                GroupDivider()
            } else {
                ForEach(trips) { trip in
                    tripRow(trip)
                    GroupDivider(inset: 52)
                }
            }

            GroupActionRow(title: "Import a GPX file", symbol: "square.and.arrow.down", showsChevron: false) {
                showsImporter = true
            }
        }
    }

    private func tripRow(_ trip: RecordedTrip) -> some View {
        CardRow(value: trip.name, detail: summary(trip)) {
            Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: 24)
        } trailing: {
            HStack(spacing: 0) {
                ShareLink(item: exportURL(trip)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share \(trip.name)")

                RowIconButton(symbol: "play.fill", tint: Color(.label), label: "Replay \(trip.name)") {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task { await model.replay(trip) }
                }
            }
        }
        .contextMenu {
            Button("Replay", systemImage: "play") { Task { await model.replay(trip) } }
            Button("Delete", systemImage: "trash", role: .destructive) { context.delete(trip) }
        }
    }

    private func summary(_ trip: RecordedTrip) -> String {
        let km = trip.distance / 1000
        let minutes = Int(trip.duration / 60)
        return String(format: "%.2f km · %d min · %d points", km, minutes, trip.fixes.count)
    }

    private func exportURL(_ trip: RecordedTrip) -> URL {
        let document = GPXDocument(
            name: trip.name,
            points: trip.fixes.map { GPXPoint(coordinate: $0.coordinate, elevation: $0.altitude, time: $0.timestamp) }
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(trip.name.replacingOccurrences(of: " ", with: "-")).gpx")
        try? document.serialized().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Schedule

    private var scheduleSection: some View {
        CardGroup(title: "Schedule") {
            if let next = scheduler.nextUp {
                HStack(spacing: Metrics.snug) {
                    Image(systemName: "clock")
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(width: 24)
                    Text("Next: \(next.name) ")
                        .foregroundStyle(Color(.label))
                    + Text(next.at, style: .relative)
                        .foregroundStyle(Color(.secondaryLabel))
                }
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                GroupDivider(inset: 52)
            }

            if runs.isEmpty {
                emptyLine("Nothing scheduled")
                GroupDivider()
            } else {
                ForEach(runs) { run in
                    scheduleRow(run)
                    GroupDivider(inset: 52)
                }
            }

            GroupActionRow(title: "New schedule", symbol: "plus", showsChevron: false) {
                creating = true
            }
        }
    }

    private func scheduleRow(_ run: ScheduledRun) -> some View {
        CardRow(value: run.name, detail: run.scheduleText) {
            Image(systemName: run.kind.symbol)
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: 24)
        } trailing: {
            Toggle("", isOn: Binding(
                get: { run.isEnabled },
                set: { run.isEnabled = $0; try? context.save(); scheduler.refresh() }
            ))
            .labelsHidden()
            .tint(Palette.accent)
            .padding(.trailing, Metrics.tight)
            .accessibilityLabel("\(run.name) on")
        }
        .onTapGesture { editing = run }
        .accessibilityAction(named: "Edit") { editing = run }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editing = run }
            Button("Delete", systemImage: "trash", role: .destructive) {
                context.delete(run)
                try? context.save()
                scheduler.refresh()
            }
        }
    }

    // MARK: - Routine

    private var routineSection: some View {
        CardGroup(title: "Routine") {
            if let live = scheduler.routineNow {
                CardRow(value: live, detail: scheduler.routineNext.map { "Then \($0.name) at \($0.at.formatted(date: .omitted, time: .shortened))" } ?? "Running on its own") {
                    Circle()
                        .fill(Palette.ok)
                        .frame(width: 10, height: 10)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                }
                GroupDivider(inset: 52)
            }

            if routines.isEmpty {
                emptyLine("No routine yet")
                GroupDivider()
            } else {
                ForEach(routines) { item in
                    CardRow(value: item.name, detail: item.summary) {
                        Image(systemName: "house")
                            .foregroundStyle(Color(.secondaryLabel))
                            .frame(width: 24)
                    } trailing: {
                        Toggle("", isOn: Binding(
                            get: { item.isEnabled },
                            set: { item.isEnabled = $0; try? context.save() }
                        ))
                        .labelsHidden()
                        .tint(Palette.accent)
                        .padding(.trailing, Metrics.tight)
                        .accessibilityLabel("\(item.name) on")
                    }
                    .onTapGesture { editingRoutine = item }
                    .accessibilityAction(named: "Edit") { editingRoutine = item }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editingRoutine = item }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            context.delete(item)
                            try? context.save()
                        }
                    }
                    GroupDivider(inset: 52)
                }
            }

            GroupActionRow(title: routines.isEmpty ? "Build my week from real places" : "Build another week", symbol: "sparkles", showsChevron: false) {
                buildingCover = true
            }

            if routines.isEmpty {
                GroupDivider(inset: 52)
                GroupActionRow(title: "Set one up by hand", symbol: "plus", showsChevron: false) {
                    creatingRoutine = true
                }
            }
        }
    }

    private func todaySection(_ routine: Routine) -> some View {
        CardGroup(title: "Today") {
            let plan = routine.plan()
            ForEach(Array(plan.segments.enumerated()), id: \.offset) { index, segment in
                let now = segment.contains(.now)
                if index > 0 { GroupDivider(inset: 52) }
                HStack(spacing: Metrics.snug) {
                    Image(systemName: symbol(for: segment.kind))
                        .foregroundStyle(now ? AnyShapeStyle(Palette.ok) : AnyShapeStyle(Color(.secondaryLabel)))
                        .frame(width: 24)
                    Text(segment.kind.name)
                        .foregroundStyle(Color(.label))
                    Spacer(minLength: Metrics.tight)
                    Text(clock(segment.start))
                        .font(.live(.subheadline, weight: .regular))
                        .foregroundStyle(Color(.secondaryLabel))
                }
                .font(.body)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(now ? .isSelected : [])
            }
        }
    }

    private func symbol(for kind: RoutineDay.Kind) -> String {
        switch kind {
        case .dwell: "house.fill"
        case .travel(_, _, _, let mode): mode == .drive ? "car.fill" : "figure.walk"
        }
    }

    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    // MARK: - Flight

    private var flightSection: some View {
        CardGroup(title: "Flight") {
            Button {
                showsFlight = true
            } label: {
                CardRow(value: flightTitle, detail: flightDetail,
                        valueColor: Color(.label)) {
                    if journey.planning {
                        ProgressView().controlSize(.small).frame(width: 24)
                    } else {
                        Image(systemName: "airplane")
                            .foregroundStyle(Color(.secondaryLabel))
                            .frame(width: 24)
                    }
                } trailing: {
                    RowChevron()
                }
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityHint("Opens the flight itinerary")
        }
    }

    private var flightTitle: String {
        if journey.planning { return "Planning a trip" }
        if journey.problem != nil { return "Could not plan the trip" }
        if let itinerary = journey.proposal { return itinerary.summary }
        return "No trip planned yet"
    }

    private var flightDetail: String {
        if journey.planning { return "Working out the airports and naming both ends" }
        if let problem = journey.problem { return problem }
        if let itinerary = journey.proposal {
            let leaves = itinerary.departs.formatted(date: .omitted, time: .shortened)
            let arrives = itinerary.arrives.formatted(date: .omitted, time: .shortened)
            return journey.isRunning ? "Under way. Arrives \(arrives)" : "Leaves \(leaves), arrives \(arrives)"
        }
        return "Drop a pin, then Travel there"
    }

    /// The itinerary editor in the sheet it has room in, with the trip's one
    /// primary action pinned under it.
    private var flightEditor: some View {
        NavigationStack {
            List {
                ItineraryEditor()
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.ground.ignoresSafeArea())
            .pinnedAction { ItineraryAction() }
            .navigationTitle("Flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsFlight = false }
                }
            }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
    }

    // MARK: - Empty

    /// An empty group says so in one short line.
    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color(.secondaryLabel))
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

/// A quiet placeholder for a list with nothing in it yet.
struct EmptyNote: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: Metrics.tight) {
            Image(systemName: symbol)
                .font(.system(.title, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, Metrics.regular)
        .background(Palette.surface.opacity(0.5), in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}
