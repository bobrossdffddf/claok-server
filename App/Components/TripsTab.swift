import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CloakKit

struct TripsTab: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case recordings = "Recordings"
        case schedule = "Schedule"
        case routine = "Routine"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(RunScheduler.self) private var scheduler
    @Environment(\.modelContext) private var context

    @Query(sort: \RecordedTrip.recordedAt, order: .reverse) private var trips: [RecordedTrip]
    @Query(sort: \ScheduledRun.createdAt, order: .reverse) private var runs: [ScheduledRun]
    @Query(sort: \Routine.createdAt, order: .reverse) private var routines: [Routine]

    @State private var pane: Pane = .recordings
    @State private var showsImporter = false
    @State private var editing: ScheduledRun?
    @State private var creating = false
    @State private var editingRoutine: Routine?
    @State private var creatingRoutine = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.regular) {
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch pane {
                case .recordings: recordings
                case .schedule: schedule
                case .routine: routine
                }
            }
            .padding(.horizontal, Metrics.regular)
            .padding(.vertical, Metrics.regular)
        }
        .sheet(isPresented: $creating) { ScheduleEditor() }
        .sheet(item: $editing) { ScheduleEditor(existing: $0) }
        .sheet(isPresented: $creatingRoutine) { RoutineEditor() }
        .sheet(item: $editingRoutine) { RoutineEditor(existing: $0) }
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

    // MARK: - Recordings

    private var recordings: some View {
        VStack(alignment: .leading, spacing: Metrics.regular) {
            recordCard

            Button {
                showsImporter = true
            } label: {
                Label("Import a GPX file", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(QuietButtonStyle())

            if trips.isEmpty {
                EmptyNote(
                    symbol: "waveform.path.ecg",
                    title: "Nothing recorded yet",
                    detail: "Start something moving, then hit record. Cloak keeps the timing and the stops, so replaying it looks like the same trip again.")
            } else {
                Section(title: "Saved") {
                    ForEach(trips) { trip in
                        tripRow(trip, last: trip.id == trips.last?.id)
                    }
                }
            }
        }
    }

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: Metrics.snug) {
            HStack(spacing: Metrics.snug) {
                ZStack {
                    Circle()
                        .fill((model.isRecording ? Palette.danger : Palette.accent).opacity(0.16))
                        .frame(width: 38, height: 38)
                    Image(systemName: model.isRecording ? "record.circle.fill" : "record.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(model.isRecording ? Palette.danger : Palette.accent)
                        .symbolEffect(.pulse, isActive: model.isRecording)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isRecording ? "Recording" : "Record this trip")
                        .font(.label(15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(model.isRecording
                         ? "\(model.recordingFixes.count) points so far"
                         : "Captures whatever is running, with its real timing.")
                        .font(.label(12))
                        .foregroundStyle(Palette.dim)
                }
                Spacer(minLength: 0)
            }

            if model.isRecording {
                Button("Stop and save") {
                    let fixes = model.finishRecording()
                    guard fixes.count > 1 else {
                        model.banner = "Not enough points to save."
                        return
                    }
                    context.insert(RecordedTrip(name: "Trip \(trips.count + 1)", fixes: fixes))
                }
                .buttonStyle(PrimaryButtonStyle(tint: Palette.danger))
            } else {
                Button("Start recording") { model.startRecording() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.snapshot.isRunning)
                    .opacity(model.snapshot.isRunning ? 1 : 0.45)
            }
        }
        .padding(Metrics.card)
        .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func tripRow(_ trip: RecordedTrip, last: Bool) -> some View {
        Row(symbol: "arrow.clockwise.circle.fill",
            title: trip.name,
            subtitle: summary(trip),
            showsDivider: !last) {
            HStack(spacing: 14) {
                ShareLink(item: exportURL(trip)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.dim)
                }
                Button {
                    Task { await model.replay(trip) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            Button("Replay") { Task { await model.replay(trip) } }
            Button("Delete", role: .destructive) { context.delete(trip) }
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

    // MARK: - Routine

    private var routine: some View {
        VStack(alignment: .leading, spacing: Metrics.regular) {
            if let live = scheduler.routineNow {
                VStack(alignment: .leading, spacing: Metrics.tight) {
                    HStack(spacing: Metrics.snug) {
                        ZStack {
                            Circle().fill(Palette.ok.opacity(0.16)).frame(width: 34, height: 34)
                            Image(systemName: "figure.walk.motion")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Palette.ok)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(live)
                                .font(.label(15, weight: .semibold))
                                .foregroundStyle(.white)
                            if let next = scheduler.routineNext {
                                Text("Then \(next.name) ")
                                    .font(.label(12))
                                    .foregroundStyle(Palette.dim)
                                + Text(next.at, style: .relative)
                                    .font(.label(12))
                                    .foregroundStyle(Palette.dim)
                            } else {
                                Text("Running on its own")
                                    .font(.label(12))
                                    .foregroundStyle(Palette.dim)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(Metrics.card)
                .background(Palette.ok.opacity(0.09), in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
            }

            if routines.isEmpty {
                EmptyNote(
                    symbol: "house.and.flag",
                    title: "No routine yet",
                    detail: "A routine runs your phone's whole day: asleep at home, out at the usual time give or take a few minutes, parked at work drifting the way a real phone does, home in the evening. No two days come out the same.")

                Button {
                    creatingRoutine = true
                } label: {
                    Label("Set up a routine", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Section(title: "Routine") {
                    ForEach(Array(routines.enumerated()), id: \.element.id) { index, item in
                        Row(symbol: "house.and.flag",
                            title: item.name,
                            subtitle: item.summary,
                            tint: item.isEnabled ? Palette.accent : Palette.dim,
                            showsDivider: index < routines.count - 1) {
                            Toggle("", isOn: Binding(
                                get: { item.isEnabled },
                                set: { item.isEnabled = $0; try? context.save() }
                            ))
                            .labelsHidden()
                        }
                        .contentShape(.rect)
                        .onTapGesture { editingRoutine = item }
                        .contextMenu {
                            Button("Edit") { editingRoutine = item }
                            Button("Delete", role: .destructive) {
                                context.delete(item)
                                try? context.save()
                            }
                        }
                    }
                }

                if let first = routines.first {
                    Section(title: "Today", footer: "Times shift a little every day, drawn from the routine's own seed, so the same plan never repeats exactly.") {
                        let plan = first.plan()
                        ForEach(Array(plan.segments.enumerated()), id: \.offset) { index, segment in
                            Row(symbol: symbol(for: segment.kind),
                                title: segment.kind.name,
                                subtitle: clock(segment.start),
                                tint: segment.contains(.now) ? Palette.ok : Palette.dim,
                                showsDivider: index < plan.segments.count - 1)
                        }
                    }
                }
            }

            HStack(spacing: Metrics.snug) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.warn)
                Text("Anything you start by hand takes priority. The routine picks up again at the next change.")
                    .font(.label(12))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Metrics.snug)
            .background(Palette.surface.opacity(0.5), in: .rect(cornerRadius: 12, style: .continuous))
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

    // MARK: - Schedule

    private var schedule: some View {
        VStack(alignment: .leading, spacing: Metrics.regular) {
            Button {
                creating = true
            } label: {
                Label("New schedule", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())

            if let next = scheduler.nextUp {
                HStack(spacing: Metrics.snug) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Next up: \(next.name)")
                            .font(.label(14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(next.at, style: .relative)
                            .font(.readout(12, weight: .regular))
                            .foregroundStyle(Palette.dim)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Metrics.snug)
                .background(Palette.accent.opacity(0.10), in: .rect(cornerRadius: 14, style: .continuous))
            }

            if runs.isEmpty {
                EmptyNote(
                    symbol: "calendar.badge.clock",
                    title: "Nothing scheduled",
                    detail: "Set a place, route or recording to start at a time you choose — once, or every week.")
            } else {
                Section(title: "Scheduled") {
                    ForEach(runs) { run in
                        scheduleRow(run, last: run.id == runs.last?.id)
                    }
                }
            }
        }
    }

    private func scheduleRow(_ run: ScheduledRun, last: Bool) -> some View {
        Row(symbol: run.kind.symbol,
            title: run.name,
            subtitle: run.scheduleText,
            tint: run.isEnabled ? Palette.accent : Palette.dim,
            showsDivider: !last) {
            Toggle("", isOn: Binding(
                get: { run.isEnabled },
                set: { run.isEnabled = $0; try? context.save(); scheduler.refresh() }
            ))
            .labelsHidden()
        }
        .contentShape(.rect)
        .onTapGesture { editing = run }
        .contextMenu {
            Button("Edit") { editing = run }
            Button("Delete", role: .destructive) {
                context.delete(run)
                try? context.save()
                scheduler.refresh()
            }
        }
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
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Palette.dim)
            Text(title)
                .font(.label(15, weight: .semibold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.label(12))
                .foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, Metrics.regular)
        .background(Palette.surface.opacity(0.5), in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}
