import SwiftUI
import CloakKit

/// The itinerary for getting to the pin believably, and the button that runs it.
struct JourneyView: View {
    let pin: Coordinate
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Bindable private var journey = JourneyController.shared

    private var origin: Coordinate? {
        if model.snapshot.isRunning, let fix = model.snapshot.fix { return fix.coordinate }
        return model.realPosition
    }

    var body: some View {
        NavigationStack {
            List {
                whySection
                if journey.planning {
                    planningSection
                } else if let problem = journey.problem {
                    problemSection(problem)
                } else if let plan = journey.proposal {
                    itinerarySection(plan)
                    // The editable parts only. This screen draws the summary
                    // and the legs itself, and owns the one Start button at
                    // the bottom; the editor used to add both again.
                    ItineraryEditor(showsItinerary: false)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.ground.ignoresSafeArea())
            .journeyActionBar(visible: hasAction) { action }
            .navigationTitle("Travel there")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: Self.closePlacement) {
                    if #available(iOS 26.0, *) {
                        Button(role: .close) { dismiss() }
                            .tint(.primary)
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        .task {
            journey.attach(model)
            guard let origin, !journey.isRunning else { return }
            await journey.plan(to: pin, from: origin)
        }
    }

    /// The system close button on iOS 26, and the familiar Done before it.
    private static var closePlacement: ToolbarItemPlacement {
        if #available(iOS 26.0, *) { return .cancellationAction }
        return .confirmationAction
    }

    // MARK: - Bottom action

    private var hasAction: Bool {
        if journey.planning { return false }
        return journey.problem != nil || journey.proposal != nil
    }

    /// The one button this screen is for: run the trip, stop it, or ask again.
    @ViewBuilder
    private var action: some View {
        if journey.planning {
            EmptyView()
        } else if journey.problem != nil {
            Button {
                guard let origin else { return }
                Task { await journey.plan(to: pin, from: origin) }
            } label: {
                Text("Try again").font(.headline)
            }
            .buttonStyle(PrimaryButtonStyle())
        } else if let plan = journey.proposal {
            if journey.isRunning {
                Button(role: .destructive) {
                    journey.cancel()
                    Task { await model.stop() }
                } label: {
                    Text("Stop the trip").font(.headline)
                }
                .buttonStyle(PrimaryButtonStyle(tint: Palette.danger))
            } else {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    journey.start()
                } label: {
                    Text(plan.shape == .fly ? "Start the trip" : "Start the drive")
                        .font(.headline)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(origin == nil)
            }
        }
    }

    // MARK: - Sections

    private var whySection: some View {
        SwiftUI.Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("A trip, not a jump", systemImage: "airplane.departure")
                    .font(.headline)
                    .labelStyle(TintedIconLabelStyle())
                Text("A teleport is the loudest thing in a location history. This lays out a drive to a real airport, the wait, the flight and the drive on, so the history reads like somebody who travelled.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            if origin == nil {
                Label("Cloak needs your real position first. Allow location and try again.", systemImage: "location.slash")
                    .font(.footnote)
                    .foregroundStyle(Palette.warn)
            }
        }
    }

    private var planningSection: some View {
        SwiftUI.Section {
            Label {
                Text("Finding airports near you and near the pin")
                    .foregroundStyle(.secondary)
            } icon: {
                ProgressView()
            }
        }
    }

    private func problemSection(_ text: String) -> some View {
        SwiftUI.Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Could not plan this one", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .labelStyle(TintedIconLabelStyle(tint: Palette.warn))
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    private func itinerarySection(_ plan: Journey) -> some View {
        SwiftUI.Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.summary)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if journey.isRunning, let arrival = journey.arrivesAt {
                    Text("Arrives about \(arrival.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 2)

            ForEach(Array(plan.legs.enumerated()), id: \.element.id) { index, leg in
                legRow(leg, index: index)
            }
        } header: {
            Text("Itinerary")
        } footer: {
            if !journey.isRunning {
                Text("Cloak keeps the phone reporting each leg in turn. Leave it running, and the Live Activity shows where the trip is up to.")
            }
        }
    }

    private func legRow(_ leg: Journey.Leg, index: Int) -> some View {
        let state: LegState = {
            guard journey.isRunning else { return .pending }
            if index < journey.legIndex { return .done }
            if index == journey.legIndex { return .now }
            return .pending
        }()
        return HStack(spacing: Metrics.snug) {
            ZStack {
                Circle()
                    .fill(state == .now ? Palette.accent : (state == .done ? Palette.ok : Palette.raised))
                    .frame(width: 28, height: 28)
                Image(systemName: symbol(for: leg))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state == .pending ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.ground))
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(leg.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state == .pending ? .secondary : .primary)
                Text(detail(for: leg))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(Journey.clock(leg.duration))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .now ? "Now" : (state == .done ? "Done" : ""))
    }

    private enum LegState { case done, now, pending }

    private func symbol(for leg: Journey.Leg) -> String {
        switch leg.kind {
        case .drive: "car.fill"
        case .hold(_, let drift): drift == 0 ? "airplane" : "building.2.fill"
        }
    }

    private func detail(for leg: Journey.Leg) -> String {
        switch leg.kind {
        case .drive(let from, let to):
            return "Drive, \(Exposure.describe(from.distance(to: to)))"
        case .hold(_, let drift):
            return drift == 0 ? "Phone goes dark, last seen at the gate" : "Wandering the terminal"
        }
    }
}

/// One line on the main screen while a trip is running.
struct JourneyChip: View {
    var action: () -> Void
    private var journey: JourneyController { JourneyController.shared }

    var body: some View {
        if journey.isRunning, let leg = journey.currentLeg {
            Button(action: action) {
                HStack(spacing: Metrics.snug) {
                    Image(systemName: symbol(for: leg))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 34, height: 34)
                        .background(Palette.accent.opacity(0.14), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(leg.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(journey.arrivesAt.map { "Trip ends about \($0.formatted(date: .omitted, time: .shortened))" } ?? "On the way")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Metrics.snug)
                .frame(minHeight: 52)
                .background(Palette.surface, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                        .strokeBorder(Palette.accent.opacity(0.22), lineWidth: 1)
                )
                .contentShape(.rect(cornerRadius: Metrics.radius, style: .continuous))
            }
            .buttonStyle(PressableStyle(scale: 0.98))
        }
    }

    private func symbol(for leg: Journey.Leg) -> String {
        switch leg.kind {
        case .drive: "car.fill"
        case .hold(_, let drift): drift == 0 ? "airplane" : "building.2.fill"
        }
    }
}

/// A label whose icon carries a colour while its title stays in the
/// hierarchical text colour.
private struct TintedIconLabelStyle: LabelStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            if let tint {
                configuration.icon.foregroundStyle(tint)
            } else {
                configuration.icon.foregroundStyle(.tint)
            }
        }
    }
}

// MARK: - Bottom bar

private extension View {
    @ViewBuilder
    func journeyActionBar<Bar: View>(visible: Bool, @ViewBuilder _ bar: () -> Bar) -> some View {
        let content = VStack(spacing: Metrics.hair) { bar() }
            .padding(.horizontal, Metrics.regular)
            .padding(.top, Metrics.snug)
            .padding(.bottom, Metrics.tight)
            .background { ActionBarBackdrop() }

        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom) {
                if visible { content }
            }
        } else {
            safeAreaInset(edge: .bottom) {
                if visible {
                    content
                }
            }
        }
    }
}

/// Solid behind the bottom buttons, with a short fade above them, so text
/// scrolled underneath never shows between a button and the keyboard or the
/// home indicator. The edge effect alone left it readable.
private struct ActionBarBackdrop: View {
    var body: some View {
        Palette.ground
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                LinearGradient(colors: [Palette.ground.opacity(0), Palette.ground], startPoint: .top, endPoint: .bottom)
                    .frame(height: Metrics.loose)
                    .offset(y: -Metrics.loose)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
