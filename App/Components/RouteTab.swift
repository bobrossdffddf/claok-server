import SwiftUI
import SwiftData
import MapKit
import CloakKit

/// The route card: where it starts, where it goes, how, and the one button
/// that builds or drives it. One accent fill, the primary button; every row
/// sits in a plain group.
struct RouteCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedRoute.createdAt, order: .reverse) private var saved: [SavedRoute]

    let chrome: CardContext
    /// Puts the cursor in the search bar, which is where stops come from.
    var onSearch: () -> Void
    /// The same search, scoped to choosing where the route begins.
    var onChooseStart: () -> Void

    @State private var showsSaveDialog = false
    @State private var routeName = ""
    @State private var locatingStart = false
    @State private var justSaved = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FloatingCard(title: "Route", collapsible: true, onClose: chrome.onClose) {
            if !model.routeWaypoints.isEmpty {
                Menu {
                    Button("Clear every stop", systemImage: "trash", role: .destructive) { model.clearStops() }
                } label: {
                    CardHeaderGlyph(symbol: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        } content: {
            VStack(alignment: .leading, spacing: Metrics.regular) {
                stops

                travel

                RouteChoices()

                if let plan = model.activePlan, plan.waypoints.count >= 2 {
                    preview(plan)
                }

                if let reading = model.believability {
                    BelievabilityCard(reading: reading)
                        .padding(Metrics.snug)
                        .background(
                            // Red only when something here gives the route
                            // away, which is meaning, not decoration.
                            reading.tells.contains { $0.severity == .bad } ? Palette.danger.opacity(0.14) : Color.white.opacity(0.07),
                            in: .rect(cornerRadius: CardMetrics.groupRadius, style: .continuous)
                        )
                }

                if let rehearsal = model.rehearsal {
                    RehearsalCard(rehearsal: rehearsal)
                        .padding(Metrics.snug)
                        .background(Color.white.opacity(0.07), in: .rect(cornerRadius: CardMetrics.groupRadius, style: .continuous))
                }

                playback

                if !saved.isEmpty {
                    savedRoutes
                }
            }
        } footer: {
            CardActionBar(status: model.routeStatus) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task {
                        if model.activePlan == nil {
                            await model.previewRoute()
                        } else {
                            await model.startRoute()
                        }
                    }
                } label: {
                    Label(model.activePlan == nil ? "Build the route" : "Start driving",
                          systemImage: model.activePlan == nil ? "point.topleft.down.to.point.bottomright.curvepath" : "car.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.routeWaypoints.count < 2 || model.isBusy)
            } secondary: {
                Button {
                    routeName = model.routeWaypoints.last?.title ?? "Route"
                    showsSaveDialog = true
                } label: {
                    Image(systemName: justSaved ? "checkmark" : "bookmark")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(SquareIconButtonStyle())
                .scaleEffect(justSaved && !reduceMotion ? 1.08 : 1)
                .animation(reduceMotion ? nil : .bouncy(duration: 0.4), value: justSaved)
                .disabled(model.activePlan == nil)
                .accessibilityLabel("Save this route")
            }
        }
        .alert("Name this route", isPresented: $showsSaveDialog) {
            TextField("Morning commute", text: $routeName)
            Button("Save") { saveRoute() }
            Button("Cancel", role: .cancel) { }
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["CLOAK_TOUR_SAVE"] == "1" {
                routeName = model.routeWaypoints.last?.title ?? "Route"
                showsSaveDialog = true
            }
        }
        #endif
    }

    // MARK: - Stops

    /// Start, any stops between, destination. The first waypoint is where the
    /// drive begins and the last is where it ends, so with a single stop the
    /// question is which end it is: the phone's own position is the start,
    /// anything else is somewhere to go.
    @ViewBuilder
    private var stops: some View {
        let waypoints = model.routeWaypoints
        CardGroup {
            if waypoints.isEmpty {
                startFromHereRow
                GroupDivider(inset: 48)
                destinationPlaceholder
            } else if waypoints.count == 1 {
                if startsHere {
                    stopRow(waypoints[0], index: 0, role: .start)
                    GroupDivider(inset: 48)
                    destinationPlaceholder
                } else {
                    startFromHereRow
                    GroupDivider(inset: 48)
                    stopRow(waypoints[0], index: 0, role: .destination)
                    GroupDivider(inset: 48)
                    addStopRow
                }
            } else {
                ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, waypoint in
                    if index > 0 { GroupDivider(inset: 48) }
                    stopRow(waypoint, index: index, role: index == 0 ? .start : (index == waypoints.count - 1 ? .destination : .middle))
                        .transition(.opacity)
                }
                GroupDivider(inset: 48)
                addStopRow
            }
        }
        .animation(.snappy(duration: 0.3), value: waypoints.map(\.id))
    }

    /// The always available way to add another stop, at the foot of the list.
    /// It opens search scoped to adding a stop, so the results lead with Add a
    /// stop and a place chosen there lands in the route.
    private var addStopRow: some View {
        Button(action: onSearch) {
            CardRow(value: "Add a stop") {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Palette.accent)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel("Add a stop")
        .accessibilityHint("Opens search to add another stop to the route")
    }

    private enum StopRole { case start, middle, destination }

    private func stopRow(_ waypoint: RouteWaypoint, index: Int, role: StopRole) -> some View {
        let isHere = role == .start && startsHere
        let caption: String?
        switch role {
        case .start: caption = "Start"
        case .middle: caption = nil
        case .destination: caption = "Destination"
        }
        return CardRow(
            caption: caption,
            value: isHere ? "Where I am" : waypoint.title
        ) {
            switch role {
            case .start: RouteDot(color: Palette.ok)
            case .destination: RouteDot(color: Palette.danger)
            case .middle:
                Text("\(index + 1)")
                    .font(.live(.caption2))
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
        } trailing: {
            HStack(spacing: 0) {
                if role == .destination, let plan = model.activePlan {
                    Text(TripFormat.duration(plan.expectedTravelTime))
                        .font(.live(.subheadline))
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.trailing, Metrics.hair)
                }
                if role == .start {
                    startMenu
                }
                RowIconButton(symbol: "minus.circle", label: "Remove \(waypoint.title)") {
                    model.removeStop(waypoint)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(caption.map { "\($0), \(isHere ? "Where I am" : waypoint.title)" } ?? "Stop \(index + 1), \(waypoint.title)")
    }

    /// The row for a route with no start of its own.
    ///
    /// Building or driving inserts the real position as the first stop, so the
    /// row says that outright rather than leaving it to be discovered, and the
    /// whole row is a menu: pin it now, or go and choose somewhere else. It
    /// used to be a bare navigation arrow with no label, which nobody pressed.
    private var startFromHereRow: some View {
        Menu {
            startOptions
        } label: {
            CardRow(caption: "Start", value: "Where I am", detail: "Tap to change") {
                RouteDot(color: Palette.ok)
            } trailing: {
                if locatingStart {
                    ProgressView().frame(width: 44, height: 44)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(RowButtonStyle())
        .disabled(locatingStart)
        .accessibilityLabel("Start, where I am")
        .accessibilityHint("Choose where the route begins")
    }

    /// On a start that is already a place, the same two choices behind one
    /// grey control, beside the remove button.
    private var startMenu: some View {
        Menu {
            startOptions
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("Change the start")
    }

    @ViewBuilder
    private var startOptions: some View {
        if !startsHere {
            Button("Use where I am", systemImage: "location.fill") { startFromHere() }
        }
        Button("Choose a different start", systemImage: "magnifyingglass") { onChooseStart() }
    }

    private var destinationPlaceholder: some View {
        Button(action: onSearch) {
            CardRow(caption: "Destination", value: "Search, or hold the map", valueColor: Color(.secondaryLabel)) {
                RouteDot(color: Palette.danger)
            }
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityHint("Opens search to choose where the route goes")
    }

    private func startFromHere() {
        guard !locatingStart else { return }
        locatingStart = true
        Task {
            let placed = await model.startFromRealPosition()
            locatingStart = false
            if placed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
    }

    /// True when the route already begins on the phone's own position.
    private var startsHere: Bool {
        guard let real = model.realPosition, let first = model.routeWaypoints.first else { return false }
        return first.coordinate.distance(to: real) < AppModel.sameSpot
    }

    // MARK: - How

    private var travel: some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            Picker("Mode", selection: Binding(get: { model.travelMode }, set: { model.travelMode = $0 })) {
                ForEach(TravelMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if model.travelMode == .drive {
                CardGroup {
                    // One row with the choice in a menu. The offset against
                    // the limit is in each menu item, where it is read at the
                    // moment of choosing, instead of a sentence under the row.
                    Menu {
                        Picker("Driver", selection: Binding(
                            get: { model.persona.id },
                            set: { id in
                                if let persona = DriverPersona.all.first(where: { $0.id == id }) {
                                    model.persona = persona
                                }
                            }
                        )) {
                            ForEach(DriverPersona.all) { persona in
                                Text("\(persona.name), limit \(offsetMph(persona)) mph").tag(persona.id)
                            }
                        }
                    } label: {
                        CardRow(value: "Driver") {
                            Image(systemName: "steeringwheel")
                                .foregroundStyle(Color(.secondaryLabel))
                                .frame(width: 24)
                        } trailing: {
                            HStack(spacing: Metrics.hair) {
                                Text(model.persona.name)
                                    .foregroundStyle(Color(.secondaryLabel))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color(.tertiaryLabel))
                            }
                            .padding(.trailing, Metrics.tight)
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityLabel("Driver")
                    .accessibilityValue(model.persona.name)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.travelMode)
    }

    // MARK: - Preview

    private func preview(_ plan: RoutePlan) -> some View {
        VStack(alignment: .leading, spacing: Metrics.snug) {
            HStack(spacing: 0) {
                metric(title: "Distance", value: Units.distance(plan.polyline.length))
                divider
                metric(title: "Drive time", value: TripFormat.duration(plan.expectedTravelTime))
                divider
                metric(title: "At \(String(format: "%.2gx", model.playbackRate))", value: TripFormat.duration(plan.expectedTravelTime / max(model.playbackRate, 0.1)))
            }

            RouteRibbon(plan: plan)
        }
        .padding(Metrics.snug)
        .background(Color.white.opacity(0.07), in: .rect(cornerRadius: CardMetrics.groupRadius, style: .continuous))
    }

    private var divider: some View {
        Divider().frame(height: 28)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.live(.body))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            RowCaption(text: title)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Playback

    private var playback: some View {
        CardGroup {
            Toggle(isOn: Binding(get: { model.loopRoute }, set: { model.loopRoute = $0 })) {
                Text("Loop the route").font(.body).foregroundStyle(Color(.label))
            }
            .tint(Palette.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: 52)

            GroupDivider()

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    RowCaption(text: "Playback speed")
                    Spacer()
                    Text(String(format: "%.2fx", model.playbackRate))
                        .font(.live(.subheadline))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(get: { model.playbackRate }, set: { model.playbackRate = $0 }),
                    in: 0.25...8,
                    step: 0.25
                )
                .tint(Color(.label))
                .accessibilityLabel("Playback speed")
                .accessibilityValue(String(format: "%.2f times", model.playbackRate))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, Metrics.tight)
        }
    }

    // MARK: - Saved

    private var savedRoutes: some View {
        CardGroup(title: "Saved routes") {
            ForEach(Array(saved.enumerated()), id: \.element.id) { index, route in
                if index > 0 { GroupDivider(inset: 52) }
                Button {
                    load(route)
                } label: {
                    CardRow(value: route.name) {
                        Image(systemName: route.mode.symbolName)
                            .foregroundStyle(Color(.secondaryLabel))
                            .frame(width: 24)
                    } trailing: {
                        Text("\(route.waypoints.count) stops")
                            .font(.subheadline)
                            .foregroundStyle(Color(.secondaryLabel))
                            .padding(.trailing, Metrics.tight)
                    }
                }
                .buttonStyle(RowButtonStyle())
                .contextMenu {
                    Button("Load this route", systemImage: "arrow.down.circle") { load(route) }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        context.delete(route)
                        try? context.save()
                    }
                }
            }
        }
    }

    private func load(_ route: SavedRoute) {
        model.routeWaypoints = route.waypoints
        model.travelMode = route.mode
        model.routeInputsChanged(needsNewRoute: true)
    }

    private func saveRoute() {
        let name = routeName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        context.insert(SavedRoute(name: name, mode: model.travelMode, personaID: model.persona.id, waypoints: model.routeWaypoints))
        try? context.save()
        model.banner = "Saved \(name)."
        justSaved = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            justSaved = false
        }
    }

    private func offsetMph(_ persona: DriverPersona) -> String {
        let mph = Int(Speed.toMph(persona.speedOffset).rounded())
        return mph >= 0 ? "+\(mph)" : "\(mph)"
    }
}
