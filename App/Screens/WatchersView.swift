import SwiftUI
import UIKit
import CloakKit

/// The apps on this phone that look for a faked location, each judged
/// against the current exposure.
struct WatchersView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var exposure = ExposureController.shared

    private var installed: [Watcher] {
        Watcher.known.filter { watcher in
            guard let url = URL(string: watcher.scheme) else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
    }

    private var verdicts: [Watcher.Verdict] {
        Watcher.judge(installed: installed, against: exposure.reading)
    }

    var body: some View {
        NavigationStack {
            List {
                if verdicts.isEmpty {
                    SwiftUI.Section {
                        ContentUnavailableView {
                            Label("No watchers installed", systemImage: "eye.slash")
                        } description: {
                            Text("None of the apps Cloak knows about are installed. That is the best case. Anything else on the phone gets the same location and has no reason to doubt it.")
                        }
                    } footer: {
                        Text(Self.explainer)
                    }
                } else {
                    summarySection
                    ForEach(verdicts) { verdict in
                        verdictSection(verdict)
                    }
                }
                everythingElseSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Who is watching")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        .task { if exposure.reading == nil { exposure.refresh() } }
    }

    private var summarySection: some View {
        let counts = Dictionary(grouping: verdicts, by: \.standing).mapValues(\.count)
        return SwiftUI.Section {
            Text("\(verdicts.count) app\(verdicts.count == 1 ? "" : "s") on this phone look\(verdicts.count == 1 ? "s" : "") for a faked location")
                .font(.headline)

            countRow(count: counts[.covered] ?? 0, label: "Covered", symbol: "checkmark.circle.fill", tint: Palette.ok)
            countRow(count: counts[.exposed] ?? 0, label: "Exposed", symbol: "exclamationmark.circle.fill", tint: Palette.warn)
            countRow(count: counts[.alwaysKnows] ?? 0, label: "Always know", symbol: "xmark.circle.fill", tint: Palette.danger)
        } footer: {
            Text(Self.explainer)
        }
    }

    private static let explainer = "Each app is caught by a different check. This lists which one reads what, and whether that thing is open right now. Close the leaks in Exposure and the verdicts here change with them."

    private func countRow(count: Int, label: String, symbol: String, tint: Color) -> some View {
        LabeledContent {
            Text("\(count)")
                .monospacedDigit()
        } label: {
            Label {
                Text(label)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func verdictSection(_ verdict: Watcher.Verdict) -> some View {
        SwiftUI.Section {
            LabeledContent {
                Text(verdict.watcher.certainty == .documented ? "Documented" : "Likely")
                    .font(.subheadline)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verdict.watcher.name)
                            .font(.headline)
                        Text(verdict.headline)
                            .font(.subheadline)
                            .foregroundStyle(tint(for: verdict.standing))
                    }
                } icon: {
                    Image(systemName: verdict.watcher.symbol)
                        .foregroundStyle(tint(for: verdict.standing))
                }
            }
            .accessibilityElement(children: .combine)

            let reads = readNames(verdict.watcher)
            if !reads.isEmpty {
                LabeledContent("Reads", value: reads.joined(separator: ", "))
            }

            ForEach(verdict.open) { leak in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(leak.title)
                        Text(leak.fix)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Palette.warn)
                        .accessibilityLabel("Open")
                }
                .accessibilityElement(children: .combine)
            }
        } footer: {
            Text(verdict.watcher.note)
        }
    }

    private func readNames(_ watcher: Watcher) -> [String] {
        var names: [String] = []
        if watcher.reads.contains(.ip) { names.append("connection") }
        if watcher.reads.contains(.country) { names.append("country") }
        if watcher.reads.contains(.timeZone) { names.append("clock") }
        if watcher.reads.contains(.motion) { names.append("motion") }
        if watcher.reads.contains(.softwareFlag) { names.append("simulation mark") }
        if watcher.teleportSensitive { names.append("jumps") }
        return names
    }

    private var everythingElseSection: some View {
        SwiftUI.Section {
            Label {
                Text("Everything else takes the location it is given")
            } icon: {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Maps, weather, ride sharing you have not installed, camera geotags, and the rest simply take the location they are given. If the pin is somewhere plausible and the trace is believable, they have nothing to notice.")
        }
    }

    private func tint(for standing: Watcher.Verdict.Standing) -> Color {
        switch standing {
        case .covered: Palette.ok
        case .exposed: Palette.warn
        case .alwaysKnows: Palette.danger
        }
    }
}
