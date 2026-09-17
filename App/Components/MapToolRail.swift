import SwiftUI
import CloakKit

/// What the map card can show. `places` is the dropped pin, or saved places
/// when there is no pin; it is not on the rail, because tapping the map and
/// the search bar are how anybody gets to a place.
enum MapTool: String, CaseIterable, Identifiable {
    case places, route, drive, trips

    var id: String { rawValue }

    /// The tools with a button on the rail, top to bottom.
    static let rail: [MapTool] = [.route, .drive, .trips]

    var title: String {
        switch self {
        case .places: "Places"
        case .route: "Route"
        case .drive: "Drive"
        case .trips: "Trips"
        }
    }

    var symbol: String {
        switch self {
        case .places: "mappin.and.ellipse"
        case .route: "point.topleft.down.to.point.bottomright.curvepath"
        case .drive: "dpad"
        case .trips: "clock.arrow.circlepath"
        }
    }
}

/// How exposed the reported place looks, for the rail's last button.
enum ExposureLevel {
    /// Nothing checked yet, or nothing to close.
    case covered
    /// Something worth closing.
    case exposed
    /// Something that gives the pin away on its own.
    case serious

    @MainActor
    static var current: ExposureLevel {
        guard let reading = ExposureController.shared.reading else { return .covered }
        if reading.isSeriouslyExposed { return .serious }
        return reading.isClean ? .covered : .exposed
    }
}

/// One narrow glass column of icon buttons down the right edge of the map:
/// locate, the three tools, and exposure at the foot.
struct MapToolRail: View {
    var selected: MapTool?
    var exposure: ExposureLevel
    /// The seven day signing clock, when this copy is signed at all. A build
    /// with no provisioning profile has none, and shows nothing.
    var signing: SignatureInfo?
    var onLocate: () -> Void
    var onSelect: (MapTool) -> Void
    var onExposure: () -> Void
    var onSigning: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            railButton(symbol: "location", label: "Centre on my real location", isSelected: false, action: onLocate)
            ForEach(MapTool.rail) { tool in
                hairline
                railButton(symbol: tool.symbol, label: tool.title, isSelected: selected == tool) {
                    onSelect(tool)
                }
                .accessibilityAddTraits(selected == tool ? .isSelected : [])
            }
            hairline
            exposureButton
            if let signing {
                hairline
                signingButton(signing)
            }
        }
        .padding(.vertical, 2)
        .frame(width: 48)
        .liquidSurface(radius: 24)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: 26, height: 1)
            .accessibilityHidden(true)
    }

    private var exposureButton: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            onExposure()
        } label: {
            Image(systemName: exposure == .covered ? "eye.slash" : "eye")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(exposureTint)
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if exposure == .serious {
                        Circle()
                            .fill(Palette.danger)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Palette.ground, lineWidth: 1.5))
                            .offset(x: -7, y: 8)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel("Exposure")
        .accessibilityValue(exposureValue)
    }

    /// The signing clock: a ring of what is left of the seven days with the
    /// days in the middle. Quiet until it matters, amber inside two days, red
    /// once it has lapsed. It opens the signing screen, which is where
    /// refreshing happens.
    private func signingButton(_ info: SignatureInfo) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            onSigning()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: CGFloat(info.fractionLeft))
                    .stroke(signingTint(info), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if info.hasExpired {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(signingTint(info))
                } else {
                    Text("\(info.daysLeft)")
                        .font(.live(.caption2))
                        .foregroundStyle(signingTint(info))
                }
            }
            .frame(width: 24, height: 24)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel("Signing")
        .accessibilityValue(info.hasExpired ? "Expired" : "\(info.daysLeft) \(info.daysLeft == 1 ? "day" : "days") left")
    }

    private func signingTint(_ info: SignatureInfo) -> Color {
        if info.hasExpired { return Palette.danger }
        return info.isUrgent ? Palette.warn : Color(.label)
    }

    private var exposureTint: Color {
        switch exposure {
        case .covered: Color(.secondaryLabel)
        case .exposed: Palette.warn
        case .serious: Palette.danger
        }
    }

    private var exposureValue: String {
        switch exposure {
        case .covered: "Nothing to close"
        case .exposed: "Something to close"
        case .serious: "Something gives you away"
        }
    }

    private func railButton(symbol: String, label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(.label))
                .frame(width: 38, height: 38)
                .background {
                    // Neutral: the open tool is shown by a lighter disc, not
                    // by colour, so the rail never competes with the card.
                    if isSelected {
                        Circle().fill(Color.white.opacity(0.18))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}
