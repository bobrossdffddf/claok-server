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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(entry.snapshot.isRunning ? "Simulating" : "Real location", systemImage: entry.snapshot.isRunning ? "location.fill" : "location.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.snapshot.isRunning ? .blue : .secondary)
            if let fix = entry.snapshot.fix {
                Text(String(format: "%.4f", fix.coordinate.latitude))
                    .font(.callout.monospacedDigit())
                Text(String(format: "%.4f", fix.coordinate.longitude))
                    .font(.callout.monospacedDigit())
                Text("\(Int(Speed.toMph(fix.speed).rounded())) mph")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
