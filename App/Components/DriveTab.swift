import SwiftUI
import CloakKit

struct DriveTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SpeedDial(
                    speed: model.snapshot.fix?.speed ?? 0,
                    limit: model.snapshot.speedLimit,
                    course: model.snapshot.fix?.course ?? -1
                )
                .padding(.top, 8)

                JoystickPad()

                autoExpire

                if model.snapshot.isRunning {
                    Button("Stop simulating") {
                        Task { await model.stop() }
                    }
                    .buttonStyle(QuietButtonStyle(tint: Palette.danger))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var autoExpire: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow(text: "Auto stop")
                Spacer()
                Text(model.autoStopMinutes == 0 ? "Off" : "\(model.autoStopMinutes) min")
                    .font(.readout(13))
                    .foregroundStyle(model.autoStopMinutes == 0 ? Palette.dim : Palette.warn)
            }
            HStack(spacing: 8) {
                ForEach([0, 15, 30, 60, 240], id: \.self) { minutes in
                    Button {
                        model.setAutoStop(minutes: minutes)
                    } label: {
                        Text(minutes == 0 ? "Off" : "\(minutes)m")
                            .font(.label(13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundStyle(model.autoStopMinutes == minutes ? Palette.ground : .white)
                            .background(
                                model.autoStopMinutes == minutes ? Palette.warn : Palette.raised,
                                in: .rect(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Simulation ends on its own, so you can never forget it is on.")
                .font(.label(12))
                .foregroundStyle(Palette.dim)
        }
        .padding(14)
        .background(Palette.surface, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

struct SpeedDial: View {
    let speed: Double
    let limit: Double?
    let course: Double

    private var mph: Int { Int(Speed.toMph(speed).rounded()) }
    private var limitMph: Int? { limit.map { Int(Speed.toMph($0).rounded()) } }
    private var fraction: Double { min(1, Speed.toMph(speed) / 80) }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.0, to: 0.75)
                .stroke(Palette.raised, style: StrokeStyle(lineWidth: 14, lineCap: .round))
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
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(135))
                .animation(.easeOut(duration: 0.6), value: fraction)

            VStack(spacing: 2) {
                Text("\(mph)")
                    .font(.readout(46, weight: .bold))
                    .foregroundStyle(.white)
                Text("mph")
                    .font(.label(12))
                    .foregroundStyle(Palette.dim)
                if let limitMph, limitMph > 0 {
                    Text("limit \(limitMph)")
                        .font(.label(11, weight: .semibold))
                        .foregroundStyle(mph > limitMph + 6 ? Palette.warn : Palette.dim)
                        .padding(.top, 4)
                }
            }

            if course >= 0 {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Palette.accent)
                    .offset(y: -74)
                    .rotationEffect(.degrees(course))
            }
        }
        .frame(width: 190, height: 190)
    }
}

struct JoystickPad: View {
    @Environment(AppModel.self) private var model
    @State private var knob: CGSize = .zero
    @State private var active = false

    private let radius: CGFloat = 74

    var body: some View {
        VStack(spacing: 12) {
            Eyebrow(text: "Manual control")

            ZStack {
                Circle()
                    .fill(Palette.surface)
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))

                ForEach(0..<4) { index in
                    Rectangle()
                        .fill(Palette.hairline.opacity(0.6))
                        .frame(width: 1, height: 12)
                        .offset(y: -radius + 10)
                        .rotationEffect(.degrees(Double(index) * 90))
                }

                Circle()
                    .fill(active ? Palette.accent : Palette.raised)
                    .frame(width: 54, height: 54)
                    .overlay(
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(active ? Palette.ground : Palette.dim)
                            .rotationEffect(.degrees(bearing))
                            .opacity(magnitude > 0.08 ? 1 : 0.3)
                    )
                    .offset(knob)
                    .shadow(color: active ? Palette.accent.opacity(0.5) : .clear, radius: 10)
            }
            .frame(width: radius * 2, height: radius * 2)
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

            Text(active ? String(format: "%.0f° at %.0f%%", bearing, magnitude * 100) : "Drag to walk or drive by hand")
                .font(.label(12))
                .foregroundStyle(Palette.dim)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Palette.surface.opacity(0.5), in: .rect(cornerRadius: 18, style: .continuous))
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
