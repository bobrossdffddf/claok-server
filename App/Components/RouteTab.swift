import SwiftUI
import SwiftData
import MapKit
import CloakKit

struct RouteTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedRoute.createdAt, order: .reverse) private var saved: [SavedRoute]

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var showsSaveDialog = false
    @State private var routeName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                destinationField

                if !results.isEmpty {
                    searchResults
                }

                modePicker

                if model.travelMode == .drive {
                    personaPicker
                }

                stops

                if let plan = model.activePlan, plan.waypoints.count >= 2 {
                    preview(plan)
                }

                if let reading = model.believability {
                    BelievabilityCard(reading: reading)
                }

                options

                actions

                if !saved.isEmpty {
                    savedRoutes
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .alert("Name this route", isPresented: $showsSaveDialog) {
            TextField("Morning commute", text: $routeName)
            Button("Save") { saveRoute() }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Destination search

    private var destinationField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Add a stop")
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.dim)

                TextField("Search an address or place", text: $query)
                    .textFieldStyle(.plain)
                    .font(.label(15))
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { runSearch() }
                    .onChange(of: query) { _, _ in scheduleSearch() }

                if searching {
                    ProgressView().controlSize(.small).tint(Palette.accent)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.dim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Palette.surface, in: .rect(cornerRadius: 14, style: .continuous))

            Text("Or press and hold anywhere on the map.")
                .font(.label(12))
                .foregroundStyle(Palette.dim)
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(results, id: \.self) { item in
                Button {
                    guard let location = item.placemark.location else { return }
                    model.addStop(Coordinate(location.coordinate), title: item.name ?? "Stop")
                    query = ""
                    results = []
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "Result")
                                .font(.label(14, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if let detail = item.placemark.title {
                                Text(detail)
                                    .font(.label(12))
                                    .foregroundStyle(Palette.dim)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Palette.accent)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Palette.surface.opacity(0.7), in: .rect(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        guard query.trimmingCharacters(in: .whitespaces).count >= 3 else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await performSearch()
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        Task { await performSearch() }
    }

    private func performSearch() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        searching = true
        defer { searching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let anchor = model.routeWaypoints.last?.coordinate ?? model.realPosition {
            request.region = MKCoordinateRegion(
                center: anchor.clCoordinate,
                latitudinalMeters: 60_000,
                longitudinalMeters: 60_000
            )
        }

        let response = try? await MKLocalSearch(request: request).start()
        guard !Task.isCancelled else { return }
        results = Array((response?.mapItems ?? []).prefix(6))
    }

    // MARK: - Stops

    private var stops: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(text: "Stops")
                Spacer()
                if !model.routeWaypoints.isEmpty {
                    Button("Clear") { model.clearStops() }
                        .font(.label(12, weight: .semibold))
                        .foregroundStyle(Palette.danger)
                }
            }

            if model.routeWaypoints.isEmpty {
                emptyStops
            }

            ForEach(Array(model.routeWaypoints.enumerated()), id: \.element.id) { index, waypoint in
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(index == 0 ? Palette.ok : (index == model.routeWaypoints.count - 1 ? Palette.accent : Palette.raised))
                            .frame(width: 26, height: 26)
                        Text("\(index + 1)")
                            .font(.readout(12, weight: .bold))
                            .foregroundStyle(index == 0 || index == model.routeWaypoints.count - 1 ? Palette.ground : .white)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(waypoint.title)
                            .font(.label(14))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(String(format: "%.5f, %.5f", waypoint.coordinate.latitude, waypoint.coordinate.longitude))
                            .font(.readout(11, weight: .regular))
                            .foregroundStyle(Palette.dim)
                    }

                    Spacer(minLength: 4)

                    Button {
                        model.removeStop(waypoint)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(Palette.dim)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(Palette.surface.opacity(0.6), in: .rect(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var emptyStops: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No stops yet")
                .font(.label(14, weight: .medium))
                .foregroundStyle(.white)
            Text("Search above, or press and hold the map. The first stop is where the drive begins, the last is where it ends.")
                .font(.label(12))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            if let real = model.realPosition {
                Button {
                    model.addStop(real, title: "Where I am")
                } label: {
                    Label("Start from where I am", systemImage: "location.fill")
                }
                .buttonStyle(QuietButtonStyle())
                .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.opacity(0.5), in: .rect(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Preview

    private func preview(_ plan: RoutePlan) -> some View {
        HStack(spacing: 0) {
            metric(title: "Distance", value: distanceText(plan))
            divider
            metric(title: "Drive time", value: durationText(plan.expectedTravelTime))
            divider
            metric(title: "At \(String(format: "%.2gx", model.playbackRate))", value: durationText(plan.expectedTravelTime / max(model.playbackRate, 0.1)))
        }
        .padding(.vertical, 14)
        .background(Palette.accent.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.3), lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairline).frame(width: 1, height: 26)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.readout(17, weight: .semibold)).foregroundStyle(.white)
            Text(title).font(.label(11)).foregroundStyle(Palette.dim)
        }
        .frame(maxWidth: .infinity)
    }

    private func distanceText(_ plan: RoutePlan) -> String {
        let metres = plan.polyline.length
        let miles = metres / 1609.34
        return miles < 0.2
            ? String(format: "%.0f ft", metres * 3.28084)
            : String(format: "%.1f mi", miles)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total)s"
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            if let status = model.routeStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Palette.accent)
                    Text(status).font(.label(13)).foregroundStyle(Palette.accent)
                    Spacer()
                }
            }

            Button(model.activePlan == nil ? "Build the route" : "Start driving") {
                Task {
                    if model.activePlan == nil {
                        await model.previewRoute()
                    } else {
                        await model.startRoute()
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.routeWaypoints.count < 2 || model.isBusy)
            .opacity(model.routeWaypoints.count < 2 || model.isBusy ? 0.5 : 1)

            if model.activePlan != nil {
                Button {
                    routeName = model.routeWaypoints.last?.title ?? "Route"
                    showsSaveDialog = true
                } label: {
                    Label("Save this route", systemImage: "bookmark")
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
    }

    private func saveRoute() {
        let name = routeName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        context.insert(SavedRoute(name: name, mode: model.travelMode, personaID: model.persona.id, waypoints: model.routeWaypoints))
        try? context.save()
        model.banner = "Saved \(name)."
    }

    // MARK: - Pickers

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Mode")
            HStack(spacing: 8) {
                ForEach(TravelMode.allCases) { mode in
                    Button {
                        model.travelMode = mode
                        model.activePlan = nil
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: mode.symbolName)
                                .font(.system(size: 15, weight: .semibold))
                            Text(mode.displayName).font(.label(11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .foregroundStyle(model.travelMode == mode ? Palette.ground : .white)
                        .background(
                            model.travelMode == mode ? Palette.accent : Palette.raised,
                            in: .rect(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var personaPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Driver")
            HStack(spacing: 8) {
                ForEach(DriverPersona.all) { persona in
                    Button {
                        model.persona = persona
                    } label: {
                        VStack(spacing: 3) {
                            Text(persona.name).font(.label(13, weight: .semibold))
                            Text(offsetLabel(persona))
                                .font(.readout(11, weight: .regular))
                                .opacity(0.75)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(model.persona.id == persona.id ? Palette.ground : .white)
                        .background(
                            model.persona.id == persona.id ? Palette.accent : Palette.raised,
                            in: .rect(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var options: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Loop the route").font(.label(15)).foregroundStyle(.white)
                Spacer()
                Toggle("", isOn: Binding(get: { model.loopRoute }, set: { model.loopRoute = $0 }))
                    .labelsHidden()
                    .tint(Palette.accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Playback speed").font(.label(15)).foregroundStyle(.white)
                    Spacer()
                    Text(String(format: "%.2fx", model.playbackRate))
                        .font(.readout(14))
                        .foregroundStyle(Palette.accent)
                }
                Slider(
                    value: Binding(get: { model.playbackRate }, set: { model.playbackRate = $0 }),
                    in: 0.25...8,
                    step: 0.25
                )
                .tint(Palette.accent)
            }
        }
        .padding(14)
        .background(Palette.surface, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private var savedRoutes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Saved routes")
            ForEach(saved) { route in
                Button {
                    model.routeWaypoints = route.waypoints
                    model.travelMode = route.mode
                    model.activePlan = nil
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: route.mode.symbolName)
                            .foregroundStyle(Palette.accent)
                        Text(route.name).font(.label(14)).foregroundStyle(.white)
                        Spacer()
                        Text("\(route.waypoints.count) stops")
                            .font(.label(12))
                            .foregroundStyle(Palette.dim)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Palette.surface.opacity(0.6), in: .rect(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        context.delete(route)
                        try? context.save()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func offsetLabel(_ persona: DriverPersona) -> String {
        let mph = Int(Speed.toMph(persona.speedOffset).rounded())
        return mph >= 0 ? "limit +\(mph)" : "limit \(mph)"
    }
}
