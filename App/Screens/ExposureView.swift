import SwiftUI
import CloakKit

/// Everything around the pin that could give it away, and what to do about
/// each. The screen leads with one plain verdict, then lists what is open
/// worst first: what it is, why it matters, and the concrete thing that
/// closes it, with the fix sitting right beside the leak it fixes.
struct ExposureView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var exposure = ExposureController.shared
    @State private var showsWatchers = false

    var body: some View {
        NavigationStack {
            List {
                verdictSection
                leaksSections
                softwareFlagSection
                egressSection
                watchersSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Exposure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsWatchers) { WatchersView() }
        .task { if exposure.reading == nil { exposure.refresh() } }
    }

    private var installedWatchers: [Watcher] {
        Watcher.known.filter { watcher in
            guard let url = URL(string: watcher.scheme) else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
    }

    // MARK: - The verdict

    private var verdictSection: some View {
        SwiftUI.Section {
            HStack(spacing: 16) {
                Group {
                    if exposure.reading == nil, exposure.isChecking {
                        ProgressView()
                    } else {
                        Image(systemName: exposureVerdictSymbol(exposure.reading))
                            .font(.largeTitle)
                            .foregroundStyle(exposureVerdictColour(exposure.reading))
                    }
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(exposureVerdictTitle(exposure.reading, checking: exposure.isChecking))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(exposureVerdictColour(exposure.reading))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(exposureVerdictSubtitle(exposure.reading))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

            if let reading = exposure.reading {
                LabeledContent("How convincing") {
                    Text("\(reading.score) of 100")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                exposure.refresh()
            } label: {
                HStack {
                    Label(exposure.isChecking ? "Checking" : "Check now", systemImage: "arrow.clockwise")
                        .modifier(ActionRowStyle())
                    Spacer(minLength: 8)
                    if exposure.isChecking {
                        ProgressView()
                    }
                }
            }
            .disabled(exposure.isChecking || exposure.reading == nil)

            if let error = exposure.lastError {
                Label {
                    Text(error)
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warn)
                }
            }
        } footer: {
            Text("Cloak checks the three things an app can read without your location history: where your connection comes out, what time zone your clock is in, and whether the phone is really moving. These are the checks that catch people.")
        }
    }

    // MARK: - What gives it away

    /// One section per open leak, worst first, so the plain-English reason can
    /// sit in the footer under the row it explains and the fix can sit in the
    /// same section as the leak.
    @ViewBuilder
    private var leaksSections: some View {
        if let reading = exposure.reading {
            let problems = reading.problems
            if problems.isEmpty {
                SwiftUI.Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nothing is giving you away")
                                .font(.headline)
                            Text("Your connection, your clock and your motion all line up with the pin.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Palette.ok)
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("What gives it away")
                }
            } else {
                ForEach(Array(problems.enumerated()), id: \.element.id) { index, leak in
                    SwiftUI.Section {
                        exposureLeakRow(leak)
                        fixControls(for: leak)
                    } header: {
                        if index == 0 {
                            Text("What gives it away")
                        }
                    } footer: {
                        Text(leak.detail)
                    }
                }
            }
        } else {
            SwiftUI.Section {
                ContentUnavailableView {
                    Label("Nothing to grade yet", systemImage: "eye.slash")
                } description: {
                    Text("Drop a pin or start a simulation and Cloak will grade the surroundings.")
                }
            } header: {
                Text("What gives it away")
            }
        }
    }

    /// The concrete thing that closes this leak, in the same section as the
    /// leak: the VPN apps for a connection in the wrong place, the Date & Time
    /// screen for a clock in the wrong zone, a re-check when nothing has been
    /// looked at yet.
    @ViewBuilder
    private func fixControls(for leak: Exposure.Leak) -> some View {
        switch leak.kind {
        case .ip, .country:
            ForEach(exposure.installedVPNs) { app in
                Button {
                    exposure.open(app)
                } label: {
                    Label(app.name, systemImage: app.symbol)
                }
            }
            Text("Any VPN works. Pick the server named above, come back, and check again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .timeZone:
            Button {
                exposure.openDateTimeSettings()
            } label: {
                Label("Open Date & Time", systemImage: "clock")
            }
        case .unchecked:
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                exposure.refresh()
            } label: {
                Label("Check now", systemImage: "arrow.clockwise")
            }
            .disabled(exposure.isChecking)
        case .motion, .softwareFlag:
            EmptyView()
        }
    }

    // MARK: - The one thing nothing hides

    /// The simulated-fix flag is permanent and costs nothing, so it is not one
    /// of the giveaways to close. It gets its own calm note rather than a red
    /// row in the list above.
    @ViewBuilder
    private var softwareFlagSection: some View {
        if let flag = exposure.reading?.leaks.first(where: { $0.kind == .softwareFlag }) {
            SwiftUI.Section {
                exposureNoteRow(flag)
            } header: {
                Text("One thing you cannot close")
            } footer: {
                Text(flag.detail)
            }
        }
    }

    // MARK: - Where the connection comes out (the evidence)

    private var hasEgressLeak: Bool {
        guard let reading = exposure.reading else { return false }
        return reading.leaks.contains { $0.kind == .ip || $0.kind == .country }
    }

    private var egressSection: some View {
        SwiftUI.Section {
            placeRow(symbol: "mappin.and.ellipse", label: "Your pin", value: exposure.pinPlace?.placeName.nonEmpty ?? "Resolving")
            placeRow(
                symbol: "globe",
                label: "Your connection comes out in",
                value: exposure.ipPlace.map { ($0.placeName.nonEmpty ?? "Unknown place") + "  ·  " + $0.address } ?? (exposure.isChecking ? "Looking" : "Not checked")
            )

            if let distance = exposure.reading?.ipDistance {
                LabeledContent {
                    Text(distance < Exposure.ipNearMetres ? "Match" : Exposure.describe(distance) + " off")
                        .monospacedDigit()
                        .foregroundStyle(distance < Exposure.ipNearMetres ? Palette.ok : (distance < Exposure.ipFarMetres ? Palette.warn : Palette.danger))
                } label: {
                    Label {
                        Text("Distance from pin")
                    } icon: {
                        Image(systemName: "ruler")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // When the connection is not the problem, the VPN list still lives
            // here so it is never more than a tap away. When it is the problem,
            // the same buttons sit up beside that leak instead, so they are
            // shown once, where they are useful.
            if !hasEgressLeak {
                if let advice = exposure.pinPlace?.egressAdvice {
                    Label {
                        Text(advice)
                            .font(.subheadline.weight(.semibold))
                    } icon: {
                        Image(systemName: "lightbulb")
                            .foregroundStyle(.tint)
                    }
                }
                ForEach(exposure.installedVPNs) { app in
                    Button {
                        exposure.open(app)
                    } label: {
                        Label(app.name, systemImage: app.symbol)
                    }
                }
            }
        } header: {
            Text("Where your connection comes out")
        } footer: {
            Text("Cloak cannot move your connection for you. Any VPN can. Pick the server it names, come back, and check again. The chip on the main screen turns green when the two agree.")
        }
    }

    private func placeRow(symbol: String, label: String, value: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Who is watching

    private var watchersSection: some View {
        let verdicts = Watcher.judge(installed: installedWatchers, against: exposure.reading)
        let exposed = verdicts.filter { $0.standing != .covered }.count
        return SwiftUI.Section {
            Button {
                showsWatchers = true
            } label: {
                HStack(spacing: 12) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            // Named label colours: `.primary` inside a list
                            // button resolves to the tint.
                            Text("Who is watching")
                                .foregroundStyle(Color(.label))
                            Text(verdicts.isEmpty
                                 ? "No app on this phone is known to check"
                                 : (exposed == 0
                                    ? "\(verdicts.count) app\(verdicts.count == 1 ? "" : "s") check. All covered."
                                    : "\(exposed) of \(verdicts.count) app\(verdicts.count == 1 ? "" : "s") can see something"))
                                .font(.subheadline)
                                .foregroundStyle(Color(.secondaryLabel))
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: "eye.trianglebadge.exclamationmark")
                            .foregroundStyle(exposed == 0 ? Palette.ok : Palette.warn)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
                .contentShape(.rect)
            }
        } footer: {
            Text("The same reading, judged app by app: which one reads which signal, and whether that thing is open right now.")
        }
    }
}

// MARK: - Shared row styling
//
// Pure functions of the reading, so the live screen and the DEBUG preview
// below render leaks through exactly one code path and cannot drift apart.

/// The colour of the verdict at the top. It tracks the worst thing open, so a
/// single serious leak reads as serious however tidy the rest of the reading.
fileprivate func exposureVerdictColour(_ reading: Exposure?) -> Color {
    guard let reading else { return .secondary }
    if reading.isClean { return Palette.ok }
    return reading.isSeriouslyExposed ? Palette.danger : Palette.warn
}

/// Shape as well as colour, so the verdict still reads without the hue.
fileprivate func exposureVerdictSymbol(_ reading: Exposure?) -> String {
    guard let reading else { return "eye.slash" }
    if reading.isClean { return "checkmark.shield.fill" }
    return reading.isSeriouslyExposed ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill"
}

fileprivate func exposureVerdictTitle(_ reading: Exposure?, checking: Bool) -> String {
    guard let reading else { return checking ? "Checking" : "No pin yet" }
    if reading.isClean { return "You look convincing" }
    let count = reading.problems.count
    if reading.isSeriouslyExposed {
        return count == 1 ? "One thing gives you away" : "You are exposed"
    }
    return count == 1 ? "One small thing gives you away" : "\(count) small things give you away"
}

fileprivate func exposureVerdictSubtitle(_ reading: Exposure?) -> String {
    guard let reading else {
        return "Drop a pin or start a simulation and Cloak grades the surroundings."
    }
    if reading.isClean { return "Nothing around the pin gives it away." }
    return "Here is what to close, worst first. Fix it, then check again."
}

fileprivate func exposureSeverityColour(_ severity: Exposure.Leak.Severity) -> AnyShapeStyle {
    switch severity {
    case .bad: AnyShapeStyle(Palette.danger)
    case .weak: AnyShapeStyle(Palette.warn)
    case .note: AnyShapeStyle(.secondary)
    }
}

fileprivate func exposureSeveritySymbol(_ severity: Exposure.Leak.Severity) -> String {
    switch severity {
    case .bad: "exclamationmark.triangle.fill"
    case .weak: "exclamationmark.circle.fill"
    case .note: "info.circle.fill"
    }
}

fileprivate func exposureSeverityName(_ severity: Exposure.Leak.Severity) -> String {
    switch severity {
    case .bad: "Serious"
    case .weak: "Worth knowing"
    case .note: "Note"
    }
}

/// A leak, in three lines: what it is, and the concrete fix underneath, with a
/// severity glyph that carries colour and shape both.
@ViewBuilder
fileprivate func exposureLeakRow(_ leak: Exposure.Leak) -> some View {
    Label {
        VStack(alignment: .leading, spacing: 4) {
            Text(leak.title)
                .font(.headline)
            Text(leak.fix)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    } icon: {
        Image(systemName: exposureSeveritySymbol(leak.severity))
            .foregroundStyle(exposureSeverityColour(leak.severity))
            .accessibilityLabel(exposureSeverityName(leak.severity))
    }
    .accessibilityElement(children: .combine)
}

/// The calm, unfixable note. Info glyph and secondary text, so it never reads
/// as one of the red giveaways.
@ViewBuilder
fileprivate func exposureNoteRow(_ leak: Exposure.Leak) -> some View {
    Label {
        VStack(alignment: .leading, spacing: 4) {
            Text(leak.title)
                .font(.headline)
            Text(leak.fix)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    } icon: {
        Image(systemName: "info.circle.fill")
            .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
}

/// A list action's label that greys out when the action is unavailable. Left
/// to itself a disabled list button kept a white title beside a teal glyph,
/// which reads as a live row.
private struct ActionRowStyle: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiaryLabel)))
    }
}

/// A compact read of the grade for the main screen. Green when the connection
/// agrees with the pin, red when it plainly does not.
struct ExposureChip: View {
    var action: () -> Void
    private var exposure: ExposureController { ExposureController.shared }

    private var tint: Color {
        guard let reading = exposure.reading else { return .secondary }
        // `standing`, not `score`: one serious leak is enough to give you
        // away, whatever the rest of the reading adds up to.
        switch reading.standing {
        case 80...: return Palette.ok
        case 55..<80: return Palette.warn
        default: return Palette.danger
        }
    }

    private var headline: String {
        guard let reading = exposure.reading else {
            return exposure.isChecking ? "Checking exposure" : "Exposure"
        }
        // Something serious is open, so say that rather than the reassuring
        // thing. The chip used to read "Connection matches pin" beside a red
        // ring while the time zone was wrong.
        if let alarm = reading.alarm { return alarm }
        if let distance = reading.ipDistance {
            return distance < Exposure.ipNearMetres ? "Connection matches pin" : "Connection \(Exposure.describe(distance)) from pin"
        }
        return reading.leaks.contains { $0.kind == .unchecked && $0.cost >= 20 } ? "Connection not checked" : reading.grade
    }

    private var subtitle: String {
        guard let reading = exposure.reading else { return "Where your connection comes out, and more" }
        if reading.isClean { return "Nothing around the pin gives it away" }
        let count = reading.problems.count
        return "\(count) thing\(count == 1 ? "" : "s") to close. Tap for what."
    }

    // Label colours are named outright: inside a button label the
    // hierarchical styles can resolve against the tint.
    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.snug) {
                ZStack {
                    Circle().stroke(Palette.raised, lineWidth: 3).frame(width: 34, height: 34)
                    Circle()
                        .trim(from: 0, to: CGFloat(exposure.reading?.score ?? 0) / 100)
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 34, height: 34)
                    if exposure.isChecking {
                        ProgressView().scaleEffect(0.6).tint(tint)
                    } else {
                        Image(systemName: "eye.slash")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(tint)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.label))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(.horizontal, Metrics.snug)
            .frame(minHeight: 52)
            .background(Palette.surface, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 1)
            )
            .contentShape(.rect(cornerRadius: Metrics.radius, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

#if DEBUG
/// The Exposure screen needs a live pin, a network lookup and a motion sample,
/// none of which a preview canvas has, so the real screen only ever previews
/// its empty state. This renders a representative reading built from a public
/// `Exposure.grade`, through the same row helpers the live screen uses, so the
/// populated design can be seen: a pin in Tokyo with the connection, clock and
/// motion all wrong.
private struct ExposureSamplePreview: View {
    private let reading: Exposure = {
        let pin = Exposure.PinPlace(
            coordinate: Coordinate(latitude: 35.6812, longitude: 139.7671),
            city: "Tokyo", region: "Tokyo", countryCode: "JP",
            timeZone: TimeZone(identifier: "Asia/Tokyo"))
        let ip = Exposure.IPPlace(
            address: "23.114.8.2",
            coordinate: Coordinate(latitude: 37.7749, longitude: -122.4194),
            city: "San Francisco", region: "California", countryCode: "US",
            timeZone: TimeZone(identifier: "America/Los_Angeles"))
        let env = Exposure.Environment(
            pin: pin, ip: ip,
            deviceTimeZone: TimeZone(identifier: "America/Chicago") ?? .current,
            deviceIsStationary: true,
            simulatedSpeed: 25, recentTopSpeed: 25, isSimulating: true)
        return Exposure.grade(env)
    }()

    var body: some View {
        NavigationStack {
            List {
                SwiftUI.Section {
                    HStack(spacing: 16) {
                        Image(systemName: exposureVerdictSymbol(reading))
                            .font(.largeTitle)
                            .foregroundStyle(exposureVerdictColour(reading))
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(exposureVerdictTitle(reading, checking: false))
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(exposureVerdictColour(reading))
                            Text(exposureVerdictSubtitle(reading))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    LabeledContent("How convincing") {
                        Text("\(reading.score) of 100").monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                ForEach(Array(reading.problems.enumerated()), id: \.element.id) { index, leak in
                    SwiftUI.Section {
                        exposureLeakRow(leak)
                        sampleFix(for: leak)
                    } header: {
                        if index == 0 { Text("What gives it away") }
                    } footer: {
                        Text(leak.detail)
                    }
                }

                if let flag = reading.leaks.first(where: { $0.kind == .softwareFlag }) {
                    SwiftUI.Section {
                        exposureNoteRow(flag)
                    } header: {
                        Text("One thing you cannot close")
                    } footer: {
                        Text(flag.detail)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Exposure")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
    }

    // A static stand-in for the live fix controls, so the preview shows where
    // the fix sits relative to its leak.
    @ViewBuilder
    private func sampleFix(for leak: Exposure.Leak) -> some View {
        switch leak.kind {
        case .ip, .country:
            Button {} label: { Label("Proton VPN, free, no data cap", systemImage: "arrow.down.circle.fill") }
            Button {} label: { Label("NordVPN", systemImage: "shield.lefthalf.filled") }
            Text("Any VPN works. Pick the server named above, come back, and check again.")
                .font(.footnote).foregroundStyle(.secondary)
        case .timeZone:
            Button {} label: { Label("Open Date & Time", systemImage: "clock") }
        case .unchecked:
            Button {} label: { Label("Check now", systemImage: "arrow.clockwise") }
        case .motion, .softwareFlag:
            EmptyView()
        }
    }
}

#Preview("Exposure sample leaks") {
    ExposureSamplePreview()
}
#endif
