import SwiftUI
import MapKit
import SwiftData
import CloakKit

struct MapScreen: View {
    @Environment(AppModel.self) private var model

    /// Opens on the phone. `.automatic` with nothing on the map frames the
    /// whole continent, and waiting for the model's own position before moving
    /// the camera was not enough: MapKit has a location well before the model
    /// does, so the first thing anybody saw was North America. MapKit framing
    /// its own user location needs nothing from the model at all.
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selection: Coordinate?
    /// The card open over the map, if any. With none open and nothing
    /// running there is no card at all, only the map.
    @State private var tool: MapTool? = MapScreen.initialTool
    /// While true, choosing a place adds it to the route instead of dropping a
    /// pin, and the pin card leads with Add as stop. Set by the route card's
    /// Add a stop affordance, cleared once a stop is added or search is left.
    @State private var addingStop = false
    /// True while that search is for the route's start rather than another
    /// stop, so what is chosen goes to the front of the route.
    @State private var choosingStart = false
    @State private var showsSigning = false
    /// Screenshot tours only: a made up signing clock, so the rail's ring can
    /// be captured on a simulator build, which carries no provisioning
    /// profile and therefore no signature at all.
    @State private var tourSigning: SignatureInfo?
    /// The name of whatever the last search or tap chose, so a stop keeps its
    /// real name rather than "Stop N".
    @State private var selectionName = "Dropped pin"

    // Search, which lives in the bar across the top and shows what it finds
    // in a card.
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    // Where the floating chrome ends, so the card is never offered room that
    // runs underneath the search bar or the tool rail.
    @State private var topChromeBottom: CGFloat = 60
    @State private var railBottom: CGFloat = 320
    @Bindable private var trial = TrialController.shared
    @State private var showsSettings = false
    @State private var showsExposure = false
    /// The map follows a running simulation until you move it yourself, and
    /// picks it up again when the next run starts. There is no button for
    /// this, because there does not need to be one.
    @State private var followsSimulation = true
    /// Whether the map has been brought to the phone once already. The camera
    /// starts as `.automatic`, which with nothing on the map frames the whole
    /// continent, so the app used to open on a picture of North America with
    /// a dot somewhere in Texas.
    @State private var hasFramedStart = false

    /// The route as MapKit wants it, built once per route rather than from
    /// every point on every redraw. The screen redraws each second while a
    /// drive runs, and converting a few thousand points each time was a
    /// visible stutter on the map.
    @State private var routeOverlay: [CLLocationCoordinate2D]?
    /// How far the camera is from the ground, so the route's road signs can
    /// match the zoom. Set when a camera move ends, not every frame.
    @State private var routeCameraDistance: CLLocationDistance?

    /// Ties the compass in the control column to this map. MapKit's own
    /// placement of it could not be kept off the battery on iOS 26.
    @Namespace private var mapScope

    /// The map's own coordinate space, so taps and the map measure from the
    /// same corner whatever is padded around it.
    private static let mapSpace = "cloak.map"

    var body: some View {
        ZStack(alignment: .topLeading) {
            MapReader { proxy in
                Map(position: $camera, scope: mapScope) {
                    // The route itself, its alternatives, and what is on it.
                    // Drawn in its own file so the look of the route and the
                    // chrome around the map can change independently.
                    RouteMapContent(model: model, overlay: routeOverlay, cameraDistance: routeCameraDistance)

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

                    // Only while spoofing. iOS already draws the blue dot, and
                    // while a simulation runs that dot is the spoofed position,
                    // which is the one people want to see moving. This second
                    // marker is where the phone really is, in grey, so the two
                    // read as the same kind of thing and never get mixed up.
                    // Showing it when nothing is being faked just put two markers
                    // on one spot.
                    if model.snapshot.isRunning, let real = model.realPosition {
                        Annotation("Really here", coordinate: real.clCoordinate) {
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
                // The map draws full bleed, so MapKit's own controls were laying
                // themselves out against the top of the screen and landing on top
                // of the battery. The safe area padding further down used to hold
                // the compass back, and on iOS 26 it no longer does: a rotated map
                // put the compass straight over the battery again. So MapKit
                // places no controls at all here, and the compass is drawn in
                // Cloak's own control column instead, bound to this map by
                // `mapScope`, where the safe area is Cloak's to respect.
                //
                // MapUserLocationButton is gone on purpose: Cloak already has a
                // centre-on-me control in its own chrome, and two buttons doing
                // one job is how the collision started.
                .mapControls { }
                // The map's own frame, named, so a tap and the map agree on where
                // the finger was.
                //
                // They stopped agreeing when the safe area padding below was added
                // to keep MapKit's controls off the battery: `.local` inside a
                // gesture means the space of the view the gesture is attached to,
                // and that view now begins 64 points below the map does. A tap was
                // being read 64 points down the map from where it happened, which
                // is exactly how far below the finger the pin landed.
                //
                // A named space is measured from the map itself, so no amount of
                // padding around it can pull the two apart again.
                // The map has to stop ignoring the safe area *here*, before the
                // coordinate space is named, not on the whole reader further down.
                // Applied outside, the map still rendered full bleed while this
                // named space measured the inset frame, so every tap was read
                // about a status bar further down the map than the finger was.
                .ignoresSafeArea()
                .coordinateSpace(.named(Self.mapSpace))
                .onTapGesture(coordinateSpace: .named(Self.mapSpace)) { point in
                    guard let coordinate = proxy.convert(point, from: .named(Self.mapSpace)) else { return }
                    withAnimation(.snappy) {
                        endSearch()
                        selection = Coordinate(coordinate)
                        selectionName = "Dropped pin"
                        tool = .places
                    }
                }
                // Press and hold drops a route stop straight in, which is the
                // fastest way to build a drive without typing an address.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.mapSpace)))
                        .onEnded { value in
                            guard case .second(true, let drag?) = value,
                                  let coordinate = proxy.convert(drag.startLocation, from: .named(Self.mapSpace)) else { return }
                            let index = model.routeWaypoints.count + 1
                            model.addStop(Coordinate(coordinate), title: "Stop \(index)")
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            // The route card opens on it, so the stop that
                            // just appeared on the map is also in a list.
                            withAnimation(.snappy) {
                                endSearch()
                                tool = .route
                            }
                        }
                )
                // MapKit's own controls lay themselves out against the map's
                // frame, and that frame now ignores the safe area, so without this
                // the compass sat on top of the battery. It has to come after
                // ignoresSafeArea to put the controls back inside.
                //
                // The trailing inset is the other half of it. 96 points down was
                // far enough to clear the battery, but it put the compass straight
                // into Cloak's own button column, which is drawn above the map and
                // therefore swallowed every tap meant for it. 72 points in moves it
                // out of that column's lane instead of underneath it.
                //
                // The compass has since moved into the chrome (see `mapControls`
                // above). These insets stay because they also define the part of
                // the map the camera frames a region into, and taking them away
                // would move where "centre on me" lands.
                .safeAreaPadding(.top, 96)
                .safeAreaPadding(.trailing, 72)
                .onMapCameraChange(frequency: .onEnd) { context in
                    // Before the guard: the road signs need the zoom whether
                    // or not anything is moving, so they can thin out when the
                    // map is pulled back and fill in when it is close.
                    routeCameraDistance = context.camera.distance
                    // Any deliberate move of the map hands control back to the
                    // person until something new starts.
                    guard let fix = model.snapshot.fix, model.snapshot.mode.isMoving else { return }
                    let centre = context.camera.centerCoordinate
                    let drift = Coordinate(centre).distance(to: fix.coordinate)
                    if drift > 1200 { followsSimulation = false }
                }
            }
            .ignoresSafeArea()

            // A soft blur under the status bar, the way Maps does it, so a
            // street name never runs underneath the clock.
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(
                        stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom)
                }
                .ignoresSafeArea(edges: .top)
                .frame(height: Metrics.tight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // The chrome is a sibling of the map rather than an overlay on
            // it. An overlay on a view that ignores the safe area is laid out
            // against the same full-bleed frame, and lands on the clock. In a
            // ZStack only the child that asks for it goes full bleed.
            chromeLayer
        }
        .mapScope(mapScope)
        .animation(.snappy(duration: 0.3), value: tool)
        .animation(.snappy(duration: 0.3), value: isSearchShowing)
        .modifier(ExposureFeed(selection: selection))
        .sheet(isPresented: $trial.showsPaywall) { PaywallView() }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onChange(of: isSearchShowing) { _, showing in
            // Leaving search without landing on a pin drops the add a stop
            // scope, so a later search from the top bar teleports as before.
            if !showing, tool != .places { addingStop = false }
        }
        .onChange(of: model.activePlan.map { "\($0.polyline.points.count)-\($0.polyline.length)-\($0.polyline.points.first?.latitude ?? 0)" }, initial: true) { _, _ in
            routeOverlay = model.activePlan?.polyline.points.map(\.clCoordinate)
        }
        .onChange(of: model.snapshot.isRunning) { _, running in
            if running { followsSimulation = true }
        }
        #if DEBUG
        .task { await seedTourState() }
        #endif
        .onChange(of: startingPoint, initial: true) { _, point in
            // Once, and only for the first fix. After that the person owns the
            // camera, and snapping it back every time the position updates is
            // the most irritating thing a map can do.
            guard !hasFramedStart, let point else { return }
            hasFramedStart = true
            camera = .region(MKCoordinateRegion(
                center: point.clCoordinate,
                latitudinalMeters: 2_500,
                longitudinalMeters: 2_500
            ))
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

    #if DEBUG
    /// Screenshot tours only: a dropped pin, some stops and which card is open
    /// from the environment, so the populated states can be captured without
    /// a finger on the simulator. CLOAK_TOUR_TAB=places|route|drive|trips|none
    /// picks the card (see `initialTool`), CLOAK_TOUR_PIN="lat,lon",
    /// CLOAK_TOUR_STOPS="lat,lon;lat,lon", CLOAK_TOUR_SEARCH="text" fills the
    /// search bar, CLOAK_TOUR_BUILD=1 builds the route from the stops,
    /// CLOAK_TOUR_DETENT=peek closes the card to the running strip, and
    /// CLOAK_TOUR_RUNNING=route to draw the running header from a made-up
    /// snapshot (nothing is sent anywhere; the simulator has no tunnel), and
    /// CLOAK_TOUR_HEADING=degrees to turn the map so the compass shows.
    private func seedTourState() async {
        let env = ProcessInfo.processInfo.environment
        guard env["CLOAK_TOUR"] == "map" else { return }
        if let pin = env["CLOAK_TOUR_PIN"].flatMap(CoordinateParser.parse) {
            selection = pin
        }
        if let stops = env["CLOAK_TOUR_STOPS"], model.routeWaypoints.isEmpty {
            for (index, text) in stops.split(separator: ";").enumerated() {
                if let coordinate = CoordinateParser.parse(String(text)) {
                    model.addStop(coordinate, title: "Stop \(index + 1)")
                }
            }
        }
        if env["CLOAK_TOUR_BUILD"] == "1", model.routeWaypoints.count >= 2 {
            // Builds the route, so the preview, the route choices and the
            // Start driving state can be captured. Asks Apple Maps, so the
            // simulator needs a network.
            Task { await model.previewRoute() }
        }
        if env["CLOAK_TOUR_DETENT"] == "peek" {
            tool = nil
        }
        if let text = env["CLOAK_TOUR_SEARCH"] {
            query = text
        }
        if env["CLOAK_TOUR_ADDSTOP"] == "1" {
            addingStop = true
        }
        if env["CLOAK_TOUR_START"] == "1" {
            addingStop = true
            choosingStart = true
        }
        if let seconds = env["CLOAK_TOUR_TRIAL"].flatMap(Double.init) {
            TrialPreview.override = seconds
        }
        if let days = env["CLOAK_TOUR_SIGNING"].flatMap(Double.init) {
            tourSigning = SignatureInfo(expires: Date(timeIntervalSinceNow: days * 86_400), signedTo: "Tour")
        }
        if let heading = env["CLOAK_TOUR_HEADING"].flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(2))
            hasFramedStart = true
            camera = .camera(MapCamera(
                centerCoordinate: CLLocationCoordinate2D(latitude: 32.7767, longitude: -96.7970),
                distance: 1_500,
                heading: heading
            ))
        }
        if env["CLOAK_TOUR_RUNNING"] == "route" {
            let here = Coordinate(latitude: 32.7767, longitude: -96.7970)
            let fake = SimulationSnapshot(
                isRunning: true,
                mode: .route(name: "Stop 3", mode: .drive),
                fix: SimulatedFix(coordinate: here, speed: 13.4, course: 40),
                progress: 0.35,
                distanceRemaining: 3_400,
                nextStopDistance: 800,
                speedLimit: 15.6
            )
            var faked = fake
            faked.startedAt = Date(timeIntervalSinceNow: -754)
            let shown = faked
            // The model polls the real engine once a second and would put
            // "stopped" straight back, so keep the made-up one in place.
            while !Task.isCancelled {
                if model.snapshot != shown { model.snapshot = shown }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }
    #endif

    /// Where to open the map: the running simulation when there is one,
    /// otherwise the phone itself.
    private var startingPoint: Coordinate? {
        if model.snapshot.isRunning, let fix = model.snapshot.fix { return fix.coordinate }
        return model.realPosition
    }

    #if DEBUG
    private static var initialTool: MapTool? {
        let env = ProcessInfo.processInfo.environment
        guard env["CLOAK_TOUR"] == "map", let name = env["CLOAK_TOUR_TAB"]?.lowercased() else { return nil }
        return MapTool(rawValue: name)
    }
    #else
    private static var initialTool: MapTool? { nil }
    #endif

    // MARK: - Chrome

    private nonisolated static let chromeSpace = "cloak.chrome"

    /// True while the search bar is in use. The rail steps aside then, so the
    /// results have the height of the screen rather than what is left under
    /// the rail.
    private var isSearchShowing: Bool {
        searchFocused || !query.isEmpty
    }

    /// Three things float over the map, and never more: the top bar, the rail,
    /// and one card.
    private var chromeLayer: some View {
        // Not inside a GlassEffectContainer, on purpose. The search capsule
        // and the rail draw their glass as a background, which is what keeps
        // their buttons tappable, and a container gathers every background
        // glass shape into one layer drawn over the views it belongs to: the
        // first build of this screen had a search bar and a rail with nothing
        // visible in them.
        ZStack(alignment: .top) {
            card
                .padding(.horizontal, CardMetrics.inset)
                .padding(.top, cardTopLimit)
                // The card stops at the home indicator's safe area rather
                // than running under it. That also keeps it clear of the
                // Apple Maps mark and Legal link, which sit in that strip at
                // the bottom left, so they are never under the card's corner.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            topBar

            if !isSearchShowing {
                railColumn
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            // MapKit's compass, under the rail, outside any glass container,
            // which does not draw MapKit's own view. Shown only while the map
            // is turned away from north and no card is open.
            MapCompass(scope: mapScope)
                .mapControlVisibility(.automatic)
                .padding(.trailing, CardMetrics.inset + 2)
                .padding(.top, railBottom + Metrics.snug)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .opacity(isSearchShowing || hasCard ? 0 : 1)
        }
        .coordinateSpace(.named(Self.chromeSpace))
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .sheet(isPresented: $showsExposure) { ExposureView() }
        .sheet(isPresented: $showsSigning) { SigningView() }
    }

    /// The highest the card's top edge may go: under the rail, or under the
    /// search bar while searching.
    private var cardTopLimit: CGFloat {
        (isSearchShowing ? topChromeBottom : max(topChromeBottom, railBottom)) + Metrics.snug
    }

    /// Settings and search, and a banner under them only while there is one.
    private var topBar: some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            MapSearchBar(
                text: $query,
                isSearching: searching,
                needsAttention: !AttentionItem.badge(model: model).isEmpty,
                focus: $searchFocused,
                onSettings: { showsSettings = true },
                onSubmit: submitSearch
            )
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.chromeSpace)).maxY } action: { topChromeBottom = $0 }

            bannerView
        }
        .padding(.horizontal, CardMetrics.inset)
        .padding(.top, Metrics.hair)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The rail down the right edge.
    private var railColumn: some View {
        MapToolRail(
            selected: railSelection,
            exposure: ExposureLevel.current,
            signing: tourSigning ?? SigningPreview.current,
            onLocate: centreOnMe,
            onSelect: { chosen in
                withAnimation(.snappy(duration: 0.3)) {
                    endSearch()
                    if tool == chosen { close() } else { tool = chosen }
                }
            },
            onExposure: { showsExposure = true },
            onSigning: { showsSigning = true }
        )
        .padding(.trailing, CardMetrics.inset)
        .padding(.top, topChromeBottom + Metrics.tight)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.chromeSpace)).maxY } action: { railBottom = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    /// The tool the rail marks as open.
    private var railSelection: MapTool? {
        guard let tool, tool != .places else { return nil }
        return tool
    }

    private var hasCard: Bool {
        isSearchShowing || tool != nil || model.snapshot.isRunning
    }

    /// The one card on screen: search while searching, otherwise the open
    /// tool, otherwise the running card, otherwise nothing.
    ///
    /// While something runs, Drive is the running card opened up. Route and
    /// Trips replace the running card while they are open, and closing them
    /// brings it back, so there is never a card stacked on a card.
    @ViewBuilder
    private var card: some View {
        let context = CardContext(onClose: { withAnimation(.snappy(duration: 0.3)) { close() } })

        if isSearchShowing || (tool == .places && selection == nil) {
            FloatingCard(
                title: addingStop ? (choosingStart ? "Choose a start" : "Add a stop") : nil,
                subtitle: addingStop ? (choosingStart ? "Search for where the route begins" : "Search for a place to add to your route") : nil,
                onClose: addingStop ? { withAnimation(.snappy(duration: 0.3)) { cancelAddStop() } } : nil
            ) {
                SearchResultsList(
                    results: results,
                    query: query,
                    isSearching: searching,
                    typedCoordinate: CoordinateParser.parse(query.trimmingCharacters(in: .whitespaces)),
                    onChoose: choose,
                    onAddStop: addStopFromSearch,
                    addingStop: addingStop
                )
            }
        } else if model.snapshot.isRunning, tool == nil || tool == .drive {
            RunningCard(expanded: tool == .drive) {
                withAnimation(.snappy(duration: 0.3)) { tool = tool == .drive ? nil : .drive }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let tool {
            switch tool {
            case .places:
                if let selection {
                    PlacesCard(chrome: context, coordinate: selection, name: selectionName, addingStop: addingStop) { next in
                        withAnimation(.snappy(duration: 0.3)) {
                            // Adding a stop takes its pin off the map, since the
                            // route now draws its own, and leaves add a stop.
                            if next == .route { self.selection = nil; addingStop = false }
                            self.tool = next
                        }
                    }
                }
            case .route:
                RouteCard(chrome: context, onSearch: { enterAddStop() }, onChooseStart: { enterChooseStart() })
            case .drive:
                DriveCard(chrome: context)
            case .trips:
                TripsCard(chrome: context)
            }
        }
    }

    private func close() {
        // Closing the place card takes its pin with it, so a closed card
        // really does leave the map clear.
        if tool == .places { selection = nil }
        addingStop = false
        choosingStart = false
        tool = nil
    }

    private func centreOnMe() {
        guard let real = model.realPosition else { return }
        hasFramedStart = true
        withAnimation(.settle) {
            camera = .region(MKCoordinateRegion(center: real.clCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
        }
    }

    // MARK: - Search

    private func endSearch() {
        searchTask?.cancel()
        query = ""
        results = []
        searching = false
        searchFocused = false
    }

    /// Opens search scoped to adding a stop: the results lead with Add a stop,
    /// and a place chosen there lands in the route rather than teleporting.
    private func enterAddStop() {
        addingStop = true
        choosingStart = false
        searchFocused = true
    }

    /// The same search, for the start of the route. What is chosen goes to the
    /// front of the stops rather than the end.
    private func enterChooseStart() {
        addingStop = true
        choosingStart = true
        searchFocused = true
    }

    /// Leaves the add a stop flow without choosing, back to the route card.
    private func cancelAddStop() {
        endSearch()
        addingStop = false
        choosingStart = false
    }

    /// A result, or typed coordinates, chosen: drop the pin there, bring the
    /// map to it, and open the place card on it.
    private func choose(_ coordinate: Coordinate, name: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.3)) {
            endSearch()
            selection = coordinate
            selectionName = name
            tool = .places
        }
        hasFramedStart = true
        withAnimation(.settle) {
            camera = .region(MKCoordinateRegion(center: coordinate.clCoordinate, latitudinalMeters: 1500, longitudinalMeters: 1500))
        }
    }

    private func addStopFromSearch(_ coordinate: Coordinate, name: String) {
        if choosingStart {
            // The front of the route, which is what makes it the start, and
            // the same rebuild `addStop` would have asked for.
            model.routeWaypoints.insert(RouteWaypoint(coordinate: coordinate, title: name), at: 0)
            model.routeInputsChanged(needsNewRoute: true)
        } else {
            model.addStop(coordinate, title: name)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.3)) {
            endSearch()
            addingStop = false
            choosingStart = false
            tool = .route
        }
    }

    private func submitSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        if let coordinate = CoordinateParser.parse(text) {
            choose(coordinate, name: "Dropped pin")
            return
        }
        searchTask?.cancel()
        searchTask = Task { await performSearch(text) }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3, CoordinateParser.parse(text) == nil else {
            results = []
            searching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(text)
        }
    }

    private func performSearch(_ text: String) async {
        guard !text.isEmpty else { return }
        searching = true
        defer { searching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let anchor = model.routeWaypoints.last?.coordinate ?? model.realPosition {
            request.region = MKCoordinateRegion(center: anchor.clCoordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        let response = try? await MKLocalSearch(request: request).start()
        guard !Task.isCancelled else { return }
        results = Array((response?.mapItems ?? []).prefix(8))
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner = model.banner {
            HStack(alignment: .top, spacing: Metrics.snug) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(Palette.warn)
                Text(FriendlyError.make(banner).headline == "That did not work" ? banner : FriendlyError.make(banner).advice)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "xmark")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(Metrics.snug)
            .liquidSurface(radius: Metrics.cardRadius, tint: Palette.warn)
            .transition(.move(edge: .top).combined(with: .opacity))
            .contentShape(.rect(cornerRadius: Metrics.cardRadius, style: .continuous))
            .onTapGesture { withAnimation(.settle) { model.banner = nil } }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Double tap to dismiss")
        }
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

/// Where the phone really is while something else is being reported.
///
/// Deliberately the same shape as the system location dot, in grey: the point
/// is that it reads as "this is also you", not as a pin or a destination.
struct RealYouMarker: View {
    private let tint = Palette.faint

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.25)).frame(width: 26, height: 26)
            Circle().fill(tint).frame(width: 12, height: 12)
                .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 2))
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
            .font(.live(.caption))
            .foregroundStyle(Palette.ground)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Palette.accent))
            .overlay(Circle().stroke(Palette.ground, lineWidth: 2))
    }
}

