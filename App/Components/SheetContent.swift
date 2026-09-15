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
    @State private var tab: SheetTab = {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["CLOAK_TOUR_TAB"],
           let chosen = SheetTab.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) {
            return chosen
        }
        #endif
        return .places
    }()
    @Namespace private var tabNamespace
    @State private var showsSigning = false

    var body: some View {
        VStack(spacing: 0) {
            LiveHeader()
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 12)

            SigningChip { showsSigning = true }
                .padding(.horizontal, 18)
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
        .background(Palette.backdrop.opacity(0.5))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsSigning) { SigningView() }
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
                    VStack(spacing: 5) {
                        Image(systemName: item.symbol)
                            .font(.system(.body, weight: .semibold))
                            .symbolVariant(tab == item ? .fill : .none)
                        Text(item.rawValue)
                            .font(.label(11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundStyle(tab == item ? Palette.accent : Palette.dim)
                    .background {
                        if tab == item {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Palette.accent.opacity(0.16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .strokeBorder(Palette.accent.opacity(0.25), lineWidth: 1))
                                .matchedGeometryEffect(id: "tab", in: tabNamespace)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(Palette.ground.opacity(0.6), in: .rect(cornerRadius: 17, style: .continuous))
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
        Units.distance(meters)
    }
}


/// The Vanish-style signing status, on the main panel so the seven day clock
/// is never a surprise. Reads the real expiry out of the signature and opens
/// the full Signing screen on tap.
struct SigningChip: View {
    var action: () -> Void
    private var info: SignatureInfo? { SignatureInfo.fromBundle() }

    private var tint: Color {
        guard let info else { return Palette.dim }
        if info.hasExpired { return Palette.danger }
        return info.isUrgent ? Palette.warn : Palette.accent
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Palette.raised, lineWidth: 3).frame(width: 34, height: 34)
                    Circle()
                        .trim(from: 0, to: CGFloat(info?.fractionLeft ?? 0))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 34, height: 34)
                    Text("\(info?.daysLeft ?? 0)")
                        .font(.readout(13, weight: .bold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.map { $0.hasExpired ? "Signature expired" : "\($0.daysLeft) \($0.daysLeft == 1 ? "day" : "days") left" } ?? "Signing")
                        .font(.label(14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(info?.hasExpired == true ? "Tap to refresh now" : "Tap to refresh or set auto")
                        .font(.label(11))
                        .foregroundStyle(Palette.dim)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Palette.dim)
            }
            .padding(12)
            .background(Palette.surface.opacity(0.7), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}