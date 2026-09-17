import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents
import CloakKit

private typealias Drive = DriveActivityAttributes.ContentState

// MARK: - Palette

private enum Live {
    static let accent = Color(red: 0.231, green: 0.878, blue: 0.784)
    static let warn = Color(red: 0.961, green: 0.647, blue: 0.141)
    static let danger = Color(red: 1.0, green: 0.353, blue: 0.373)
    static let card = Color(red: 0.05, green: 0.07, blue: 0.09)

    /// One colour carries the whole status, so it is worth being strict about
    /// what each one means: amber when nothing is moving or nothing is
    /// arriving, red when the reported speed would not survive a second look,
    /// and the house green the rest of the time.
    static func tint(_ state: Drive, stale: Bool) -> Color {
        if stale { return warn }
        if state.isPaused { return warn }
        if state.isOverLimit { return danger }
        return accent
    }

    static func heading(_ state: Drive, stale: Bool) -> String {
        if stale { return "Not updating" }
        if state.isPaused { return "Paused" }
        return state.activity
    }

    static func symbol(_ state: Drive, stale: Bool) -> String {
        if stale { return "exclamationmark.triangle.fill" }
        if state.isPaused { return "pause.fill" }
        return state.symbol
    }

    /// The line under the place name. In order of what a person would rather
    /// know: that the numbers have stopped being true, what the car is really
    /// doing under SHIELD, how fast against the limit, then the raw position.
    static func detail(_ state: Drive, stale: Bool, headline: Headline) -> (text: String, warn: Bool) {
        if stale { return ("Cloak stopped sending updates. Open it to carry on.", true) }
        if let shield = state.shieldText { return (shield, false) }
        if let against = state.speedAgainstLimitText, headline != .speed || state.isOverLimit {
            return (against, state.isOverLimit)
        }
        if headline != .speed, state.isMoving { return (state.speedText, false) }
        return (state.coordinateText, false)
    }
}

/// Which single number earns the largest spot.
private enum Headline {
    case arrival
    case speed
    case elapsed

    init(_ state: Drive) {
        if state.arrivalText != nil { self = .arrival }
        else if state.isMoving { self = .speed }
        else { self = .elapsed }
    }
}

// MARK: - System-drawn clocks
//
// Both of these hand a date range to SwiftUI and let the system redraw the
// digits. Pushing a new content state every second would spend the whole
// ActivityKit budget in a few minutes and still lag.

/// Counts up from the start of the run, frozen at the last known moment while
/// the simulation is paused.
private func elapsedClock(_ state: Drive) -> Text {
    let start = state.startedAt
    let end = start.addingTimeInterval(24 * 60 * 60)
    return Text(
        timerInterval: start...max(end, start.addingTimeInterval(60)),
        pauseTime: state.isPaused ? state.stamp : nil,
        countsDown: false
    )
}

/// Counts down to arrival. Nil whenever there is nothing to count down to.
private func arrivalClock(_ state: Drive, showsHours: Bool = true) -> Text? {
    guard let arrival = state.arrivalDate, arrival > state.stamp else { return nil }
    return Text(
        timerInterval: state.stamp...arrival,
        pauseTime: state.isPaused ? state.stamp : nil,
        countsDown: true,
        showsHours: showsHours
    )
}

// MARK: - The activity

/// Lock screen and Dynamic Island presence for a running simulation.
///
/// The shape follows what Apple's own navigation and workout activities do:
/// an icon and a one-line summary on the leading side, one live number on the
/// trailing side, progress and controls underneath. A run with no finish line
/// simply drops the parts that need one instead of drawing an empty bar.
struct DriveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveActivityAttributes.self) { context in
            LockScreenView(state: context.state, stale: context.isStale)
                .activityBackgroundTint(Live.card)
                .activitySystemActionForegroundColor(Live.accent)
                .widgetURL(URL(string: "cloak://open"))
        } dynamicIsland: { context in
            island(state: context.state, stale: context.isStale)
        }
    }

    private func island(state: Drive, stale: Bool) -> DynamicIsland {
        let tint = Live.tint(state, stale: stale)
        let headline = Headline(state)

        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                HStack(spacing: 7) {
                    Badge(symbol: Live.symbol(state, stale: stale), tint: tint, size: 26)
                    Text(Live.heading(state, stale: stale))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.leading, 2)
            }

            DynamicIslandExpandedRegion(.trailing) {
                HeadlineValue(state: state, headline: headline, tint: tint, ink: .island)
                    .padding(.trailing, 2)
            }

            DynamicIslandExpandedRegion(.center) {
                Text(state.label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 2)
            }

            DynamicIslandExpandedRegion(.bottom) {
                VStack(spacing: 8) {
                    if state.isRoute {
                        RouteStrip(state: state, tint: tint, ink: .island)
                    }
                    ControlRow(state: state, height: 32)
                }
                .padding(.horizontal, 2)
                .padding(.top, 2)
            }
        } compactLeading: {
            Image(systemName: Live.symbol(state, stale: stale))
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
        } compactTrailing: {
            CompactTrailing(state: state, stale: stale, tint: tint)
        } minimal: {
            Minimal(state: state, stale: stale, tint: tint)
        }
        .keylineTint(tint)
        .widgetURL(URL(string: "cloak://open"))
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let state: Drive
    let stale: Bool

    private var tint: Color { Live.tint(state, stale: stale) }
    private var headline: Headline { Headline(state) }

    var body: some View {
        let detail = Live.detail(state, stale: stale, headline: headline)

        return VStack(spacing: 7) {
            HStack(alignment: .center, spacing: 12) {
                Badge(symbol: Live.symbol(state, stale: stale), tint: tint, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(Live.heading(state, stale: stale).uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(tint)
                        .lineLimit(1)

                    Text(state.label)
                        .font(.headline)
                        .foregroundStyle(Ink.card.strong)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(detail.text)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(detail.warn ? Live.danger : Ink.card.soft)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 6)

                HeadlineValue(state: state, headline: headline, tint: tint, ink: .card, large: true)
            }

            if state.isRoute {
                RouteStrip(state: state, tint: tint, ink: .card)
            }

            ControlRow(state: state, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

// MARK: - Pieces

/// Text colours for the two surfaces this activity lives on.
///
/// The lock screen card paints its own dark tint, so writing in `.primary`
/// there would turn the label black on black in light mode. The Dynamic
/// Island is drawn by the system and is always dark, so there the semantic
/// hierarchy is the right thing to follow.
private struct Ink {
    let strong: Color
    let soft: Color

    static let card = Ink(strong: .white, soft: .white.opacity(0.62))
    static let island = Ink(strong: .primary, soft: .secondary)
}

/// The one number that gets the big spot: when the route lands, how fast the
/// phone claims to be going, or how long this has been running.
private struct HeadlineValue: View {
    let state: Drive
    let headline: Headline
    let tint: Color
    let ink: Ink
    var large = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            switch headline {
            case .arrival:
                Text(state.arrivalText ?? "")
                    .font(large ? .title2.weight(.bold) : .subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                caption("arrival")
            case .speed:
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(state.speedValue)
                        .font(large ? .title.weight(.bold) : .headline)
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    Text("mph")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ink.soft)
                }
                if let limit = state.speedLimitMph, limit > 0 {
                    caption(String(format: "limit %.0f", limit))
                } else {
                    caption("reported")
                }
            case .elapsed:
                // A running clock is wider than the digits suggest, and it
                // grows by an hour's worth of characters partway through a
                // long hold, so it is given room and allowed to shrink.
                elapsedClock(state)
                    .font(large ? .title2.weight(.bold) : .subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: large ? 104 : 72, alignment: .trailing)
                    .foregroundStyle(tint)
                caption(state.isPaused ? "held" : "elapsed")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func caption(_ words: String) -> some View {
        Text(words)
            .font(.caption2)
            .foregroundStyle(ink.soft)
            .lineLimit(1)
    }
}

/// Progress along a route, with what is left in time and in distance.
/// Nothing here is drawn for a run that has no finish line.
private struct RouteStrip: View {
    let state: Drive
    let tint: Color
    let ink: Ink

    var body: some View {
        VStack(spacing: 5) {
            ProgressBar(value: state.clampedProgress, tint: tint)

            HStack(spacing: 6) {
                if state.isArriving {
                    Text("Arriving")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                } else if let clock = arrivalClock(state) {
                    HStack(spacing: 3) {
                        clock
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(maxWidth: 62, alignment: .leading)
                        Text("left")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(ink.soft)
                } else {
                    Text(state.progressPercent)
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(ink.soft)
                }

                Spacer(minLength: 4)

                if let distance = state.distanceText {
                    Text(distance)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(ink.soft)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Route progress")
        .accessibilityValue(state.progressPercent)
    }
}

/// Hold it where it is, or drop the whole thing and go back to the truth.
private struct ControlRow: View {
    let state: Drive
    let height: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: TogglePauseIntent()) {
                Label(state.isPaused ? "Resume" : "Pause",
                      systemImage: state.isPaused ? "play.fill" : "pause.fill")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: height)
            }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.9))

            Button(intent: StopSimulationIntent()) {
                Label("Real location", systemImage: "location.fill")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: height)
            }
            .buttonStyle(.borderedProminent)
            .tint(Live.danger)
        }
    }
}

// MARK: - Dynamic Island small regions

private struct CompactTrailing: View {
    let state: Drive
    let stale: Bool
    let tint: Color

    var body: some View {
        if stale {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
        } else if state.isArriving {
            Image(systemName: "flag.checkered")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
        } else if let clock = arrivalClock(state, showsHours: overAnHour) {
            clock
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: overAnHour ? 54 : 44)
                .foregroundStyle(tint)
        } else if state.isMoving {
            Text(state.speedValue)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
        } else {
            Image(systemName: state.isPaused ? "pause.fill" : "mappin")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
        }
    }

    /// A route long enough that minutes alone would be a lie.
    private var overAnHour: Bool {
        guard let arrival = state.arrivalDate else { return false }
        return arrival.timeIntervalSince(state.stamp) >= 3600
    }
}

private struct Minimal: View {
    let state: Drive
    let stale: Bool
    let tint: Color

    var body: some View {
        if stale || state.isPaused {
            Image(systemName: stale ? "exclamationmark.triangle.fill" : "pause.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
        } else if state.isRoute {
            Ring(value: state.clampedProgress, tint: tint)
        } else {
            Image(systemName: "location.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Shapes

private struct Badge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A flatter progress bar than the system one, which reads better small.
private struct ProgressBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.75), tint],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(5, geometry.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

/// The same progress, small enough for the minimal Dynamic Island, where a bar
/// would be a couple of pixels wide and say nothing.
private struct Ring: View {
    let value: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.28), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.03, min(max(value, 0), 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
    }
}
