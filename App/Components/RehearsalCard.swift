import SwiftUI
import CloakKit

/// Shows the drive as it would come out, graded, before it runs. A trace
/// preview with the weakest second called out, drawn from the same engine the
/// live run uses.
struct RehearsalCard: View {
    let rehearsal: Rehearsal
    @State private var expanded = false

    private var tint: Color {
        switch rehearsal.score {
        case 80...: Palette.ok
        case 55..<80: Palette.warn
        default: Palette.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.snug) {
            header

            TracePreview(samples: rehearsal.samples, weakest: rehearsal.weakest, tint: tint)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .background(.fill.quaternary, in: .rect(cornerRadius: 14, style: .continuous))

            HStack(alignment: .top, spacing: Metrics.snug) {
                stat("Top speed", Exposure.describeSpeed(rehearsal.topSpeed))
                stat("Stops", "\(rehearsal.stops)")
                stat("Takes", Journey.clock(rehearsal.duration))
            }

            if let weakest = rehearsal.weakest {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(Palette.warn)
                        Text("Weakest moment: \(weakest.reason.lowercased())")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: Metrics.tight)
                        Text("\(Int(weakest.at))s in")
                            .font(.live(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Image(systemName: "chevron.down")
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(PressableStyle())
                .accessibilityHint(expanded ? "Double tap to hide the detail" : "Double tap for the detail")

                if expanded {
                    Text("At \(Int(weakest.at)) seconds in, going \(Exposure.describeSpeed(weakest.speed)), the trace \(weakest.reason.lowercased()). It is marked on the preview above. This is the single second most likely to catch an eye; the rest of the drive is smoother than this point.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            } else {
                Text("No single moment stands out. The speed changes are within what a car does and the heading tracks the road.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // No card of its own: it is placed in a grouped list row, which is
        // the container.
        .padding(.vertical, Metrics.hair)
    }

    private var header: some View {
        HStack(spacing: Metrics.snug) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 4).frame(width: 42, height: 42)
                    .accessibilityHidden(true)
                Circle()
                    .trim(from: 0, to: CGFloat(rehearsal.score) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 42, height: 42)
                Text("\(rehearsal.score)")
                    .font(.live(.subheadline))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            VStack(alignment: .leading, spacing: 2) {
                Text(rehearsal.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Rehearsed offline, before it runs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.live(.subheadline))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The shape of the drive, drawn from the sampled fixes, coloured by speed,
/// with the weakest second marked.
private struct TracePreview: View {
    let samples: [SimulatedFix]
    let weakest: Rehearsal.Moment?
    let tint: Color

    private struct Segment: Identifiable {
        let id: Int
        let from: CGPoint
        let to: CGPoint
        let intensity: Double
    }

    var body: some View {
        GeometryReader { geo in
            let layout = build(in: geo.size)
            ZStack {
                if layout.segments.isEmpty {
                    Text("No trace")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(layout.segments) { segment in
                        segmentPath(segment)
                    }
                    if let start = layout.start {
                        Circle().fill(Palette.ok).frame(width: 8, height: 8).position(start)
                    }
                    if let mark = layout.weakest {
                        Circle().stroke(Palette.warn, lineWidth: 2).frame(width: 16, height: 16).position(mark)
                    }
                }
            }
        }
    }

    private func segmentPath(_ segment: Segment) -> some View {
        Path { path in
            path.move(to: segment.from)
            path.addLine(to: segment.to)
        }
        .stroke(tint.opacity(0.35 + 0.65 * segment.intensity), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }

    private struct Layout {
        var segments: [Segment]
        var start: CGPoint?
        var weakest: CGPoint?
    }

    private func build(in size: CGSize) -> Layout {
        guard samples.count > 1 else { return Layout(segments: [], start: nil, weakest: nil) }

        var minLat = samples[0].coordinate.latitude, maxLat = minLat
        var minLon = samples[0].coordinate.longitude, maxLon = minLon
        for f in samples {
            minLat = min(minLat, f.coordinate.latitude); maxLat = max(maxLat, f.coordinate.latitude)
            minLon = min(minLon, f.coordinate.longitude); maxLon = max(maxLon, f.coordinate.longitude)
        }
        let spanLat = max(maxLat - minLat, 0.00001) * 1.2
        let spanLon = max(maxLon - minLon, 0.00001) * 1.2
        let baseLat = minLat - (maxLat - minLat) * 0.1
        let baseLon = minLon - (maxLon - minLon) * 0.1

        let inset: CGFloat = 12
        let w = size.width - inset * 2
        let h = size.height - inset * 2

        func project(_ c: Coordinate) -> CGPoint {
            let x = (c.longitude - baseLon) / spanLon
            let y = (c.latitude - baseLat) / spanLat
            return CGPoint(x: inset + CGFloat(x) * w, y: inset + h - CGFloat(y) * h)
        }

        let maxSpeed = max(1.0, samples.map(\.speed).max() ?? 1.0)
        var segments: [Segment] = []
        segments.reserveCapacity(samples.count - 1)
        for i in 0..<(samples.count - 1) {
            segments.append(Segment(
                id: i,
                from: project(samples[i].coordinate),
                to: project(samples[i + 1].coordinate),
                intensity: samples[i].speed / maxSpeed
            ))
        }
        return Layout(
            segments: segments,
            start: project(samples[0].coordinate),
            weakest: weakest.map { project($0.coordinate) }
        )
    }
}
