import SwiftUI
import MapKit
import SwiftData
import CloakKit

struct MapScreen: View {
    @Environment(AppModel.self) private var model

    @State private var camera: MapCameraPosition = .automatic
    @State private var detent: PresentationDetent = .fraction(0.42)
    @State private var selection: Coordinate?
    @State private var showsDiagnostics = false
    @State private var showsSettings = false
    /// The map follows a running simulation until you move it yourself, and
    /// picks it up again when the next run starts. There is no button for
    /// this, because there does not need to be one.
    @State private var followsSimulation = true

    /// The route as MapKit wants it, built once per route rather than from
    /// every point on every redraw. The screen redraws each second while a
    /// drive runs, and converting a few thousand points each time was a
    /// visible stutter on the map.
    @State private var routeOverlay: [CLLocationCoordinate2D]?

    var body: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let route = routeOverlay {
                    MapPolyline(coordinates: route)
                        .stroke(Palette.accent.opacity(0.85), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }

                ForEach(model.routeWaypoints) { waypoint in
                    Annotation(waypoint.title, coordinate: waypoint.coordinate.clCoordinate) {
                        WaypointPin(index: (model.routeWaypoints.firstIndex(of: waypoint) ?? 0) + 1)
                    }
                }

                if model.geofence.isEnabled {
                    MapCircle(center: model.geofence.center.clCoordinate, radius: model.geofence.radius)
                        .foregroundStyle(Palette.danger.opacity(0.05))
                        .stroke(Palette.danger.opacity(0.35), lineWidth: 1)
                }

                if let selection {
                    Annotation("Dropped pin", coordinate: selection.clCoordinate) {
                        DroppedPin()
                    }
                }

                if let fix = model.snapshot.fix {
                    Annotation("Simulated", coordinate: fix.coordinate.clCoordinate) {
                        SimulatedMarker(course: fix.course, moving: fix.speed > 0.5)
                    }
                }

                // Your real location, always. While a simulation runs iOS hands
                // this app the fake fix too, so the blue dot is the fake one;
                // this marker is the last real position Cloak read before it
                // started, kept on the map so you never lose where you are.
                if model.snapshot.isRunning, let real = model.realPosition {
                    Annotation("You (real)", coordinate: real.clCoordinate) {
                        RealYouMarker()
                    }
                }

                UserAnnotation()
            }
            // Flat, not realistic 3D terrain: the realistic mode is the most
            // expensive thing MapKit can draw, and this screen redraws once a
            // second for the whole of a drive. Flat is what Apple Maps shows in
            // its default view too.
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .including([.cafe, .restaurant, .gasStation])))
            .mapControls {
                MapCompass()
                MapUserLocationButton()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                // Any deliberate move of the map hands control back to the
                // person until something new starts.
                guard let fix = model.snapshot.fix, model.snapshot.mode.isMoving else { return }
                let centre = context.camera.centerCoordinate
                let drift = Coordinate(centre).distance(to: fix.coordinate)
                if drift > 1200 { followsSimulation = false }
            }
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                withAnimation(.snappy) {
                    selection = Coordinate(coordinate)
                    if detent == .fraction(0.16) { detent = .fraction(0.42) }
                }
            }
            // Press and hold drops a route stop straight in, which is the
            // fastest way to build a drive without typing an address.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        guard case .second(true, let drag?) = value,
                              let coordinate = proxy.convert(drag.startLocation, from: .local) else { return }
                        let index = model.routeWaypoints.count + 1
                        model.addStop(Coordinate(coordinate), title: "Stop \(index)")
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.snappy) {
                            if detent == .fraction(0.16) { detent = .fraction(0.42) }
                        }
                    }
            )
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) { topBar }
        .overlay(alignment: .topTrailing) { controlStack }
        .overlay(alignment: .top) { bannerView }
        .sheet(isPresented: .constant(true)) {
            SheetContent(selection: $selection, detent: $detent)
                .presentationDetents([.fraction(0.16), .fraction(0.42), .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.42)))
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(26)
                .interactiveDismissDisabled()
        }
        .onChange(of: model.activePlan.map { "\($0.polyline.points.count)-\($0.polyline.length)-\($0.polyline.points.first?.latitude ?? 0)" }, initial: true) { _, _ in
            routeOverlay = model.activePlan?.polyline.points.map(\.clCoordinate)
        }
        .onChange(of: model.snapshot.isRunning) { _, running in
            if running { followsSimulation = true }
        }
        .onChange(of: model.snapshot.fix?.coordinate) { _, coordinate in
            guard followsSimulation, let coordinate, model.snapshot.mode.isMoving else { return }
            withAnimation(.easeInOut(duration: 0.9)) {
                camera = .camera(MapCamera(
                    centerCoordinate: coordinate.clCoordinate,
                    distance: 900,
                    heading: model.snapshot.fix?.course ?? 0
                ))
            }
        }
    }

    private var topBar: some View {
        StatusPill(showsDiagnostics: $showsDiagnostics)
            .frame(maxWidth: 250, alignment: .leading)
            .padding(.leading, Metrics.regular)
            .padding(.top, Metrics.tight)
    }

    private var controlStack: some View {
        VStack(spacing: 10) {
            CircleControl(symbol: "scope") {
                guard let real = model.realPosition else { return }
                withAnimation(.snappy) {
                    camera = .region(MKCoordinateRegion(center: real.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
                }
            }
            CircleControl(symbol: "gearshape") { showsSettings = true }
            if model.snapshot.isRunning {
                CircleControl(symbol: "exclamationmark.octagon.fill", tint: Palette.danger) {
                    Task { await model.panic() }
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.snapshot.isRunning)
        .padding(.trailing, Metrics.snug)
        .padding(.top, 54)
        .sheet(isPresented: $showsDiagnostics) { DiagnosticsView() }
        .sheet(isPresented: $showsSettings) { SettingsView() }
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner = model.banner {
            Text(FriendlyError.make(banner).headline == "That did not work" ? banner : FriendlyError.make(banner).advice)
                .font(.label(13))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(padding: 12, radius: 14)
                .padding(.horizontal, Metrics.regular)
                .padding(.top, 76)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { withAnimation { model.banner = nil } }
        }
    }
}

struct StatusPill: View {
    @Environment(AppModel.self) private var model
    @Binding var showsDiagnostics: Bool

    var body: some View {
        Button {
            showsDiagnostics = true
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(tint.opacity(0.22)).frame(width: 28, height: 28)
                    Circle().fill(tint).frame(width: 9, height: 9)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.label(13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.readout(11, weight: .regular))
                        .foregroundStyle(Palette.dim)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(Palette.dim)
            }
            .glassCard(padding: 10, radius: 16)
        }
        .buttonStyle(.plain)
    }

    private var tint: Color {
        if model.snapshot.linkMessage != nil { return Palette.danger }
        if model.snapshot.isPaused { return Palette.warn }
        return model.snapshot.isRunning ? Palette.accent : Palette.dim
    }

    private var title: String {
        if model.snapshot.linkMessage != nil { return "Link problem" }
        if model.snapshot.isPaused { return "Paused" }
        return model.snapshot.mode.title
    }

    private var subtitle: String {
        if let message = model.snapshot.linkMessage { return message }
        guard let fix = model.snapshot.fix else { return "Apps see your real location" }
        return String(format: "%.5f, %.5f", fix.coordinate.latitude, fix.coordinate.longitude)
    }
}

struct SimulatedMarker: View {
    var course: Double
    var moving: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.accent.opacity(0.18))
                .frame(width: pulse ? 54 : 40, height: pulse ? 54 : 40)
            Circle()
                .fill(Palette.accent)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(Palette.ground, lineWidth: 3.5))
                .shadow(color: Palette.accent.opacity(0.6), radius: 8)
            if moving, course >= 0 {
                Image(systemName: "location.north.fill")
                    .font(.system(.caption2, weight: .black))
                    .foregroundStyle(Palette.ground)
                    .rotationEffect(.degrees(course))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

struct RealYouMarker: View {
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.25)).frame(width: 26, height: 26)
                Circle().fill(Color.blue).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
            Text("You")
                .font(.readout(9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.blue, in: Capsule())
        }
    }
}

struct DroppedPin: View {
    var body: some View {
        Image(systemName: "mappin.circle.fill")
            .font(.system(.title))
            .foregroundStyle(Palette.warn, Palette.ground)
            .shadow(radius: 4)
    }
}

struct WaypointPin: View {
    let index: Int

    var body: some View {
        Text("\(index)")
            .font(.readout(12, weight: .bold))
            .foregroundStyle(Palette.ground)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Palette.accent))
            .overlay(Circle().stroke(Palette.ground, lineWidth: 2))
    }
}

