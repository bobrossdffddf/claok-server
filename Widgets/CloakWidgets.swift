import WidgetKit
import SwiftUI
import AppIntents
import CloakKit

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: SimulationSnapshot
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, snapshot: .stopped)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: .now, snapshot: current()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let entry = StatusEntry(date: .now, snapshot: current())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(60))))
    }

    private func current() -> SimulationSnapshot {
        guard let data = AppGroup.defaults.data(forKey: "snapshot"),
              let decoded = try? JSONDecoder().decode(SimulationSnapshot.self, from: data) else {
            return .stopped
        }
        return decoded
    }
}

struct StatusWidgetView: View {
    var entry: StatusEntry

    private var snapshot: SimulationSnapshot { entry.snapshot }

    /// The widget only gets to redraw every minute or so, and the app stops
    /// writing the snapshot the moment iOS suspends it. A fix older than a few
    /// minutes means what follows is history, not status, and saying so is
    /// better than showing a stale speed as though it were current.
    private var isStale: Bool {
        guard snapshot.isRunning, let stamp = snapshot.fix?.timestamp else { return false }
        return entry.date.timeIntervalSince(stamp) > 300
    }

    private var headline: String {
        if !snapshot.isRunning { return "Real location" }
        if isStale { return "Not updating" }
        if snapshot.isPaused { return "Paused" }
        return snapshot.mode.activityWord
    }

    private var symbol: String {
        if !snapshot.isRunning { return "location.slash" }
        if isStale { return "exclamationmark.triangle.fill" }
        if snapshot.isPaused { return "pause.fill" }
        return snapshot.mode.symbol
    }

    private var accent: Color {
        if !snapshot.isRunning { return .secondary }
        if isStale || snapshot.isPaused { return .orange }
        return .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(headline, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .lineLimit(1)

            if snapshot.isRunning {
                Text(snapshot.mode.subject)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                if let fix = snapshot.fix {
                    Text("\(Int(Speed.toMph(fix.speed).rounded())) mph")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if snapshot.distanceRemaining != nil {
                    ProgressView(value: min(max(snapshot.progress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(accent)
                    if let left = snapshot.distanceRemaining, left > 0 {
                        Text(Units.distance(left) + " left")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Nothing running")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.cloak.status", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Cloak status")
        .description("Where this phone currently says it is.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

@available(iOS 18.0, *)
struct PanicControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.cloak.panic") {
            ControlWidgetButton(action: PanicRestoreIntent()) {
                Label("Panic restore", systemImage: "xmark.octagon.fill")
            }
        }
        .displayName("Panic restore")
        .description("Stop simulating and return to the real location.")
    }
}

@main
struct CloakWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        StatusWidget()
        DriveLiveActivity()
        if #available(iOS 18.0, *) {
            PanicControl()
        }
    }
}
