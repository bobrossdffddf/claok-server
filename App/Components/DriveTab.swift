import SwiftUI
import CloakKit

/// The drive card, when nothing is running: the speed and the stick, SHIELD,
/// and auto stop. While something runs the same controls open under the
/// running card instead, with no card of their own.
struct DriveCard: View {
    let chrome: CardContext

    var body: some View {
        FloatingCard(title: "Drive", collapsible: true, onClose: chrome.onClose) {
            DriveControls()
        }
    }
}

/// The speed dial, the joystick, SHIELD and auto stop.
///
/// Laid out in a plain stack inside the card's scroll view, never a List: the
/// joystick is a zero-distance drag, and a List row is a cell that can claim
/// the touch for its own scrolling and never send the release that stops the
/// car.
struct DriveControls: View {
    @Environment(AppModel.self) private var model

    @State private var shieldProblem: String?
    @State private var shieldStarting = false
    @State private var showsShieldHelp = false

    var body: some View {
        VStack(spacing: Metrics.regular) {
            // The instrument and the control side by side, so both are on
            // screen at once. Stacked, the dial alone filled the card.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Metrics.snug) {
                    dial
                    JoystickPad()
                }
                VStack(spacing: Metrics.regular) {
                    dial
                    JoystickPad()
                }
            }
            .frame(maxWidth: .infinity)

            // SHIELD and auto stop on one surface, not a box each.
            CardGroup {
                shield
                GroupDivider()
                autoExpire
            }
        }
    }

    private var dial: some View {
        SpeedDial(
            speed: model.snapshot.fix?.speed ?? 0,
            limit: model.snapshot.speedLimit,
            course: model.snapshot.fix?.course ?? -1,
            diameter: 150
        )
    }

    /// SHIELD: drive for real, be seen at the limit.
    private var shield: some View {
        let settings = model.shield
        let active = model.isShielding

        return VStack(spacing: 0) {
            HStack(spacing: Metrics.snug) {
                Image(systemName: "shield.checkered")
                    .font(.body)
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text("SHIELD")
                    .font(.body)
                    .foregroundStyle(Color(.label))
                Button {
                    showsShieldHelp = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(Color(.tertiaryLabel))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What SHIELD does")
                .popover(isPresented: $showsShieldHelp) {
                    Text("Drive for real, and apps see you at the limit however fast the car goes. \(settings.mode.detail). Press Start as you pull out. Set a destination on the Route card first only if you want it to follow a particular way.")
                        .font(.subheadline)
                        .foregroundStyle(Color(.label))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 280)
                        .padding()
                        .presentationCompactAdaptation(.popover)
                }
                Spacer(minLength: Metrics.tight)
                Toggle("", isOn: Binding(
                    get: { settings.isEnabled },
                    set: { model.setShield(settings.with(isEnabled: $0)) }
                ))
                .labelsHidden()
                .tint(Palette.accent)
                .disabled(active)
                .accessibilityLabel("SHIELD")
            }
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .frame(minHeight: 52)

            if settings.isEnabled {
                GroupDivider()

                VStack(alignment: .leading, spacing: Metrics.snug) {
                    Picker("SHIELD mode", selection: Binding(
                        get: { settings.mode },
                        set: { model.setShield(settings.with(mode: $0)) }
                    )) {
                        ForEach(ShieldSettings.Mode.allCases) { mode in
                            Text(mode.name).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(active)

                    if active {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.snapshot.fix.map { String(format: "Reporting %.0f mph", Units.mph($0.speed)) } ?? "Starting")
                                .font(.live(.subheadline))
                                .foregroundStyle(Color(.label))
                            Text(model.snapshot.speedLimit.map { String(format: "Limit here %.0f mph", Units.mph($0)) } ?? "Reading the limit")
                                .font(.footnote)
                                .foregroundStyle(Color(.secondaryLabel))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button(role: .destructive) {
                            Task { await model.stop() }
                        } label: {
                            Text("Stop SHIELD")
                        }
                        .buttonStyle(CardSecondaryButtonStyle(tint: Palette.danger))
                    } else if !model.snapshot.isRunning {
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            shieldStarting = true
                            shieldProblem = nil
                            Task {
                                shieldProblem = await model.startShield()
                                shieldStarting = false
                            }
                        } label: {
                            Text(shieldStarting ? "Starting" : (model.routeWaypoints.count >= 2 ? "Start SHIELD on your route" : "Start SHIELD"))
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(shieldStarting)
                    }

                    if let shieldProblem {
                        Text(shieldProblem)
                            .font(.footnote)
                            .foregroundStyle(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }
        }
    }

    /// Auto stop, as one row with the five lengths under it.
    private var autoExpire: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.tight) {
                HStack {
                    Text("Auto stop")
                        .font(.body)
                        .foregroundStyle(Color(.label))
                    Spacer()
                    Text(model.autoStopMinutes == 0 ? "Off" : "\(model.autoStopMinutes) min")
                        .font(.live(.subheadline, weight: .regular))
                        .foregroundStyle(Color(.secondaryLabel))
                }
                Picker("Auto stop", selection: Binding(
                    get: { model.autoStopMinutes },
                    set: { model.setAutoStop(minutes: $0) }
                )) {
                    ForEach([0, 15, 30, 60, 240], id: \.self) { minutes in
                        Text(Self.autoStopLabel(minutes)).tag(minutes)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityValue(model.autoStopMinutes == 0 ? "Off" : "After \(model.autoStopMinutes) minutes")
            }
            .padding(14)
        }
    }

    private static func autoStopLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Off"
        case 60: "1h"
        case 240: "4h"
        default: "\(minutes)m"
        }
    }
}

struct SpeedDial: View {
    let speed: Double
    let limit: Double?
    let course: Double
    var diameter: CGFloat = 190

    private var mph: Int { Int(Speed.toMph(speed).rounded()) }
    private var limitMph: Int? { limit.map { Int(Speed.toMph($0).rounded()) } }
    private var fraction: Double { min(1, Speed.toMph(speed) / 80) }
    private var stroke: CGFloat { diameter >= 170 ? 14 : 11 }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.0, to: 0.75)
                .stroke(.quaternary, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(135))

            Circle()
                .trim(from: 0.0, to: 0.75 * fraction)
                .stroke(
                    AngularGradient(
                        colors: [Palette.accentDeep, Palette.accent, Palette.warn],
                        center: .center,
                        startAngle: .degrees(135),
                        endAngle: .degrees(405)
                    ),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                )
                .rotationEffect(.degrees(135))
                .animation(.easeOut(duration: 0.6), value: fraction)

            VStack(spacing: 0) {
                Text("\(mph)")
                    .font(.live(.largeTitle))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("mph")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let limitMph, limitMph > 0 {
                    Text("limit \(limitMph)")
                        .font(.live(.caption2))
                        .foregroundStyle(mph > limitMph + 6 ? Palette.warn : Color.secondary)
                        .padding(.top, 2)
                }
            }

            if course >= 0 {
                Image(systemName: "location.north.fill")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .offset(y: -(diameter / 2 - 21))
                    .rotationEffect(.degrees(course))
            }
        }
        .frame(width: diameter, height: diameter)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed")
        .accessibilityValue(limitMph.map { "\(mph) miles per hour, limit \($0)" } ?? "\(mph) miles per hour")
    }
}

struct JoystickPad: View {
    @Environment(AppModel.self) private var model
    @State private var knob: CGSize = .zero
    @State private var active = false

    private let radius: CGFloat = 74

    var body: some View {
        VStack(spacing: Metrics.tight) {
            ZStack {
                Circle()
                    .fill(.fill.quaternary)

                ForEach(0..<4) { index in
                    Rectangle()
                        .fill(.tertiary)
                        .frame(width: 1, height: 12)
                        .offset(y: -radius + 10)
                        .rotationEffect(.degrees(Double(index) * 90))
                }

                Circle()
                    .fill(active ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.fill.secondary))
                    .frame(width: 54, height: 54)
                    .overlay(
                        Image(systemName: "arrow.up")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(active ? AnyShapeStyle(Palette.ground) : AnyShapeStyle(.secondary))
                            .rotationEffect(.degrees(bearing))
                            .opacity(magnitude > 0.08 ? 1 : 0.3)
                    )
                    .offset(knob)
                    .shadow(color: active ? Palette.accent.opacity(0.5) : .clear, radius: 10)
            }
            .frame(width: radius * 2, height: radius * 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Manual control")
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let limited = clamp(value.translation)
                        knob = limited
                        active = true
                        Task { await model.steer(bearing: bearing, throttle: magnitude) }
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { knob = .zero }
                        active = false
                        Task { await model.releaseSteering() }
                    }
            )

            Text(active ? String(format: "%.0f° at %.0f%%", bearing, magnitude * 100) : "Drag to move")
                .font(.caption)
                .foregroundStyle(Color(.secondaryLabel))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: radius * 2)
        }
    }

    private var magnitude: Double {
        let distance = sqrt(knob.width * knob.width + knob.height * knob.height)
        return min(1, distance / radius)
    }

    private var bearing: Double {
        guard magnitude > 0.02 else { return 0 }
        let radians = atan2(knob.width, -knob.height)
        let degrees = radians * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    private func clamp(_ translation: CGSize) -> CGSize {
        let distance = sqrt(translation.width * translation.width + translation.height * translation.height)
        guard distance > radius else { return translation }
        let scale = radius / distance
        return CGSize(width: translation.width * scale, height: translation.height * scale)
    }
}
