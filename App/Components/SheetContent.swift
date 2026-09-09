import SwiftUI
import CloakKit

enum SheetTab: String, CaseIterable, Identifiable {
    case places = "Places"
    case route = "Route"
    case drive = "Drive"
    case trips = "Trips"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .places: "mappin.and.ellipse"
        case .route: "arrow.triangle.turn.up.right.diamond"
        case .drive: "dpad"
        case .trips: "clock.arrow.circlepath"
        }
    }
}

struct SheetContent: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Coordinate?
    @Binding var detent: PresentationDetent
    @State private var tab: SheetTab = .places
    @Namespace private var tabNamespace

    var body: some View {
        VStack(spacing: 0) {
            LiveHeader()
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 12)

            tabBar
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            Divider().overlay(Palette.hairline)

            Group {
                switch tab {
                case .places: PlacesTab(selection: $selection, tab: $tab)
                case .route: RouteTab()
                case .drive: DriveTab()
                case .trips: TripsTab()
                }
            }
        }
        .background(Palette.ground.opacity(0.35))
        .preferredColorScheme(.dark)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SheetTab.allCases) { item in
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.snappy(duration: 0.28)) {
                        tab = item
                        if detent == .fraction(0.16) { detent = .fraction(0.42) }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .symbolVariant(tab == item ? .fill : .none)
                        Text(item.rawValue)
                            .font(.label(11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(tab == item ? Palette.accent : Palette.dim)
                    .background {
                        // One shape that slides between tabs, rather than four
                        // that pop in and out.
                        if tab == item {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Palette.accent.opacity(0.14))
                                .matchedGeometryEffect(id: "tab", in: tabNamespace)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Palette.surface.opacity(0.55), in: .rect(cornerRadius: 16, style: .continuous))
    }
}

struct LiveHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.snapshot.mode.title)
                        .font(.label(17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(detailLine)
                        .font(.readout(12, weight: .regular))
                        .foregroundStyle(Palette.dim)
                        .lineLimit(1)
                }
                Spacer()
                if model.snapshot.isRunning {
                    HStack(spacing: 8) {
                        CircleControl(
                            symbol: model.snapshot.isPaused ? "play.fill" : "pause.fill",
                            tint: Palette.warn
                        ) {
                            Task { await model.togglePause() }
                        }
                        CircleControl(symbol: "stop.fill", tint: Palette.danger) {
                            Task { await model.stop() }
                        }
                    }
                }
            }

            if model.snapshot.mode.isMoving {
                telemetry
            }

            if case .route = model.snapshot.mode {
                ProgressView(value: model.snapshot.progress)
                    .tint(Palette.accent)
                    .scaleEffect(x: 1, y: 0.6, anchor: .center)
            }

            // Getting back to the real location is the one thing that must
            // never be hard to find, so it lives here, at the top of the
            // sheet, visible at every height.
            if model.snapshot.isRunning {
                Button {
                    Task { await model.stop() }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label("Back to my real location", systemImage: "location.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var detailLine: String {
        guard let fix = model.snapshot.fix else { return "Apps see your real location" }
        return String(format: "%.5f, %.5f", fix.coordinate.latitude, fix.coordinate.longitude)
    }

    private var telemetry: some View {
        HStack(alignment: .top, spacing: 20) {
            Readout(
                title: "Speed",
                value: "\(Int(Speed.toMph(model.snapshot.fix?.speed ?? 0).rounded()))",
                unit: "mph",
                tint: Palette.accent
            )
            if let limit = model.snapshot.speedLimit, limit > 0 {
                Readout(title: "Limit", value: "\(Int(Speed.toMph(limit).rounded()))", unit: "mph")
            }
            if let remaining = model.snapshot.distanceRemaining {
                Readout(title: "Left", value: distanceText(remaining))
            }
            if let next = model.snapshot.nextStopDistance {
                Readout(title: "Next stop", value: distanceText(next), tint: Palette.warn)
            }
            Spacer(minLength: 0)
        }
    }

    private func distanceText(_ meters: Double) -> String {
        if meters < 950 { return "\(Int(meters.rounded())) m" }
        return String(format: "%.1f km", meters / 1000)
    }
}
