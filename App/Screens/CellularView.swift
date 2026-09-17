import SwiftUI
import CloakKit

struct CellularView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable private var assist = CellularAssist.shared
    @State private var now = Date.now

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                statusSection
                relinkSection
                shortcutSection
                labSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Cellular")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onReceive(clock) { now = $0 }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
    }

    private var beatText: String {
        let status = RemotePairingBackend.status()
        guard status.isReady else {
            return status.failed ? "Not linked: \(status.reason ?? "")" : "Not linked"
        }
        return "Linked"
    }

    /// The one thing that actually makes cellular work, said plainly and
    /// first. iOS only offers its pairing service on a real local-network
    /// interface. The Wi-Fi radio being switched on creates one, whether or
    /// not it is joined to anything, and that is all this needs. The shortcut
    /// below exists only to switch the radio back on when it is off.
    private var statusSection: some View {
        let wifi = RemotePairingDiscovery.hasLocalNetworkInterface
        let linked = RemotePairingBackend.status().isReady
        return SwiftUI.Section {
            CellularRow(
                title: linked ? "Linked on cellular" : (wifi ? "Ready to link" : "If it will not link, switch the Wi-Fi radio on"),
                subtitle: linked
                    ? "Working right now. You do not need to do anything."
                    : (wifi
                        ? "Cloak links on cellular directly. This usually just works."
                        : "Cloak usually links on cellular on its own. Only if it will not, switching the Wi-Fi radio on (no network needed) gives iOS what it wants."),
                symbol: linked ? "checkmark.circle.fill" : (wifi ? "wifi" : "wifi"),
                symbolColor: linked ? Palette.ok : (wifi ? Palette.ok : Palette.warn))

            HStack(spacing: 12) {
                CellularRow(title: "Link", subtitle: beatText, symbol: "waveform.path.ecg")
                Spacer(minLength: 8)
                StatusMark(ok: linked)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Right now")
        } footer: {
            Text("Most of the time cellular just works. If a link ever will not come up, switching the Wi-Fi radio on in Control Centre, without joining any network, is all iOS needs. Keep using cellular for data as normal.")
        }
    }

    private var relinkSection: some View {
        SwiftUI.Section {
            Toggle(isOn: $assist.enabled) {
                CellularRow(
                    title: "Relink automatically",
                    subtitle: "Runs the shortcut only when there is no Wi-Fi",
                    symbol: "arrow.triangle.2.circlepath")
            }

            HStack(spacing: 12) {
                CellularRow(
                    title: "What works on this iPhone",
                    subtitle: assist.learned.map(\.title) ?? "Not measured yet. Run the test below once.",
                    symbol: "brain")
                Spacer(minLength: 8)
                StatusMark(ok: assist.learned != nil)
            }
            .accessibilityElement(children: .combine)

            if assist.learned != nil {
                Button {
                    assist.forget()
                } label: {
                    Label("Measure again", systemImage: "arrow.counterclockwise")
                }
            }
        } header: {
            Text("Relink")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let learned = assist.learned {
                    Text("\(learned.title): \(learned.detail)")
                }
                Text("Once the link is up it rides a heartbeat and survives leaving Wi-Fi. If it ever drops on cellular, Cloak relinks with a tiny shortcut that flips one switch for a couple of seconds. When the link drops in the background, Cloak sends one notification. Tap it and the relink finishes on its own.")
            }
        }
    }

    private var shortcutSection: some View {
        SwiftUI.Section {
            LabeledContent {
                TextField("Shortcut name", text: $assist.shortcutName)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            } label: {
                Label {
                    Text("Name")
                } icon: {
                    Image(systemName: "square.2.layers.3d.fill")
                        .foregroundStyle(.tint)
                }
            }

            step(1, "In Shortcuts, make a new shortcut named exactly \"\(assist.shortcutName)\".")
            step(2, "Add If. Condition: Shortcut Input is \"wifi\". Inside it add Set Wi-Fi, turned On.")
            step(3, "Add another If: Shortcut Input is \"dataoff\". Inside, Set Cellular Data, Off.")
            step(4, "Add a third If: Shortcut Input is \"dataon\". Inside, Set Cellular Data, On.")
            step(5, "When iOS first asks for permission, tap Always Allow so it never asks again.")

            Button {
                assist.openShortcutLink()
            } label: {
                Label(assist.shortcutLink.isEmpty ? "Open Shortcuts" : "Get the shortcut", systemImage: "plus.square.on.square")
            }
        } header: {
            Text("The shortcut")
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.tint)
        }
        .accessibilityLabel("Step \(number). \(text)")
    }

    private var labSection: some View {
        SwiftUI.Section {
            if assist.isTesting {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Testing")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await assist.runLab(model: model) }
                } label: {
                    Label("Run cellular test", systemImage: "play.fill")
                        .modifier(ActionRowStyle())
                }
                .disabled(model.snapshot.isRunning)
            }

            ForEach(assist.trials) { trial in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trial.strategy.title)
                        Text(trial.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                } icon: {
                    Image(systemName: trial.worked ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(trial.worked ? Palette.ok : Palette.danger)
                        .accessibilityLabel(trial.worked ? "Worked" : "Failed")
                }
            }
        } header: {
            Text("Test")
        } footer: {
            Text("Turn Wi-Fi off in Control Center, leave cellular on, then run this. Cloak drops the link and tries each way in until one works, and remembers it.")
        }
    }
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

/// Title over a subtitle with a leading symbol, in system text styles.
private struct CellularRow: View {
    let title: String
    var subtitle: String?
    let symbol: String
    var symbolColor: Color?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(symbolColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint))
        }
    }
}

/// Ready or not, as a system symbol. Shape as well as colour.
private struct StatusMark: View {
    let ok: Bool

    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(ok ? Palette.ok : Palette.warn)
            .accessibilityLabel(ok ? "Ready" : "Needs attention")
    }
}


/// The loud one. Shown on the main screen only when the phone has dropped to
/// cellular and the relink shortcut has never run, which is exactly the moment
/// somebody is about to lose the link and not know why.
struct CellularSetupChip: View {
    var action: () -> Void
    private var assist: CellularAssist { CellularAssist.shared }

    // Label colours are named outright: inside a button label the
    // hierarchical styles can resolve against the tint.
    var body: some View {
        if assist.needsShortcutNow {
            Button(action: action) {
                HStack(spacing: Metrics.snug) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.warn)
                        .frame(width: 34, height: 34)
                        .background(Palette.warn.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("You are on cellular. Set up relinking")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(.label))
                            .lineLimit(2)
                        Text("One shortcut, once. Without it the link drops off Wi-Fi.")
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
                .frame(minHeight: 56)
                .background(Palette.surface, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                        .strokeBorder(Palette.warn.opacity(0.45), lineWidth: 1)
                )
                .contentShape(.rect(cornerRadius: Metrics.radius, style: .continuous))
            }
            .buttonStyle(PressableStyle(scale: 0.98))
        }
    }
}
