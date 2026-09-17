import SwiftUI
import CloakKit

/// The routes Apple Maps offered for the same stops, to pick one.
///
/// Shown only when there is a choice to make. Each row says how long and how
/// far, with the route's own label ("Fastest", "2 min longer, via US-183 N")
/// under it, and the chosen one carries a tick, the way a choice in a grouped
/// list does. Choosing calls `selectRoute`, which switches the plan without
/// asking Apple Maps again.
struct RouteChoices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let plans = model.routeAlternatives
        if plans.count >= 2 {
            CardGroup(title: "Routes") {
                ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                    if index > 0 { GroupDivider(inset: 14) }
                    choice(plan, index: index, selected: index == model.selectedRouteIndex)
                }
            }
        }
    }

    private func choice(_ plan: RoutePlan, index: Int, selected: Bool) -> some View {
        Button {
            guard !selected else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            model.selectRoute(index)
        } label: {
            HStack(spacing: Metrics.snug) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.tight) {
                        Text(TripFormat.duration(plan.expectedTravelTime))
                            .font(.live(.body))
                            .foregroundStyle(Color(.label))
                        Text(Units.distance(plan.polyline.length))
                            .font(.live(.subheadline, weight: .regular))
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                    if !label(plan).isEmpty {
                        Text(label(plan))
                            .font(.footnote)
                            .foregroundStyle(Color(.secondaryLabel))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color(.label))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func label(_ plan: RoutePlan) -> String {
        var parts: [String] = []
        if !plan.label.isEmpty { parts.append(plan.label) }
        if !plan.routeName.isEmpty, !plan.label.contains(plan.routeName) { parts.append("via \(plan.routeName)") }
        return parts.joined(separator: ", ")
    }
}
