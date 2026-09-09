import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents
import CloakKit

private enum Live {
    static let accent = Color(red: 0.231, green: 0.878, blue: 0.784)
    static let warn = Color(red: 0.961, green: 0.647, blue: 0.141)
    static let danger = Color(red: 1.0, green: 0.353, blue: 0.373)

    static func tint(_ state: DriveActivityAttributes.ContentState) -> Color {
        if state.isPaused { return warn }
        if state.isOverLimit { return danger }
        return accent
    }
}

/// Lock screen and Dynamic Island presence for a running simulation.
///
/// The shape follows what Apple's own navigation and workout activities do:
/// an icon and a one-line summary on the leading side, one live number on the
/// trailing side, and a single clear action. The elapsed clock is drawn by the
/// system from a date rather than pushed, which keeps it honest to the second
/// without spending any of the update budget.
struct DriveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color(red: 0.05, green: 0.07, blue: 0.09))
                .activitySystemActionForegroundColor(Live.accent)
        } dynamicIsland: { context in
            let state = context.state
            let tint = Live.tint(state)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Badge(symbol: state.symbol, tint: tint, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.activity)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(tint)
                            Text(state.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(state.startedAt, style: .timer)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 62)
                            .foregroundStyle(.primary)
                        Text("elapsed")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        if state.progress > 0 {
                            ProgressBar(value: state.progress, tint: tint)
                        }

                        HStack(spacing: 8) {
                            Stat(value: state.speedValue, unit: "mph", tint: tint)
                            if let distance = state.distanceText {
                                Divider().frame(height: 20)
                                Text(distance)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button(intent: TogglePauseIntent()) {
                                Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .buttonStyle(.bordered)
                            .tint(Live.warn)

                            Button(intent: StopSimulationIntent()) {
                                Label("Stop", systemImage: "location.fill")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Live.danger)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: state.isPaused ? "pause.fill" : state.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            } compactTrailing: {
                if state.isMoving {
                    Text(state.speedValue)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                        .monospacedDigit()
                } else {
                    Image(systemName: "mappin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
            } minimal: {
                Image(systemName: state.isPaused ? "pause.fill" : "location.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
            }
            .keylineTint(tint)
            .widgetURL(URL(string: "cloak://open"))
        }
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let state: DriveActivityAttributes.ContentState

    private var tint: Color { Live.tint(state) }

    var body: some View {
        VStack(spacing: 13) {
            HStack(alignment: .center, spacing: 12) {
                Badge(symbol: state.isPaused ? "pause.fill" : state.symbol, tint: tint, size: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(state.isPaused ? "Paused" : state.activity)
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(tint)

                    Text(state.label)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(state.coordinateText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 2) {
                    if state.isMoving {
                        Stat(value: state.speedValue, unit: "mph", tint: tint, large: true)
                    } else {
                        Text(state.startedAt, style: .timer)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 86)
                            .foregroundStyle(tint)
                    }
                }
            }

            if state.progress > 0 {
                VStack(spacing: 5) {
                    ProgressBar(value: state.progress, tint: tint)
                    HStack {
                        Text(state.startedAt, style: .timer)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .leading)
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        if let distance = state.distanceText {
                            Text(distance)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button(intent: TogglePauseIntent()) {
                    Label(state.isPaused ? "Resume" : "Pause",
                          systemImage: state.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.9))

                Button(intent: StopSimulationIntent()) {
                    Label("Real location", systemImage: "location.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Live.danger)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Pieces

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
    }
}

private struct Stat: View {
    let value: String
    let unit: String
    let tint: Color
    var large = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: large ? 26 : 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(unit)
                .font(.system(size: large ? 11 : 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
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
