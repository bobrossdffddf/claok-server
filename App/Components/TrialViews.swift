import SwiftUI
import CloakKit

struct TrialChip: View {
    @Bindable private var trial = TrialController.shared
    @State private var now = Date.now
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.tight) {
                ZStack {
                    Circle()
                        .stroke(Palette.raised, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat(trial.liveRemaining / TrialController.allowance))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(trial.isUsedUp ? "Free minutes used up" : "Free: \(TrialController.format(trial.liveRemaining)) left today")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                Text("Unlock")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.ground)
                    .lineLimit(1)
                    .padding(.horizontal, Metrics.snug)
                    .padding(.vertical, 6)
                    .background(Palette.accentFill, in: Capsule())
            }
            .padding(.horizontal, Metrics.snug)
            .frame(minHeight: 52)
            .background(Palette.surface.opacity(0.9), in: .rect(cornerRadius: Metrics.radius, style: .continuous))
            .contentShape(.rect(cornerRadius: Metrics.radius, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .onReceive(clock) { now = $0 }
    }

    private var tint: Color {
        trial.liveRemaining < 120 ? Palette.warn : Palette.accent
    }

    private var detail: String {
        if trial.running { return "Counting while your location is changed" }
        if let reset = trial.resetsAt, trial.isUsedUp {
            return "Back at \(reset.formatted(date: .omitted, time: .shortened))"
        }
        return "Routes, driving and SHIELD need a licence"
    }
}

struct PaywallView: View {
    @Environment(LicenseController.self) private var licensing
    @Environment(\.dismiss) private var dismiss
    @Bindable private var trial = TrialController.shared
    @State private var key = ""
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 48

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Metrics.loose) {
                    VStack(spacing: Metrics.regular) {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: heroSize))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tint)
                            .frame(minHeight: heroSize + 8)
                            .accessibilityHidden(true)

                        Text("Unlock all of Cloak")
                            .font(.title.bold())
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)

                        Text(trial.paywallReason ?? "The free version changes your location for 10 minutes a day.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: Metrics.snug) {
                        perk("infinity", "No daily limit")
                        perk("point.topleft.down.to.point.bottomright.curvepath", "Routes, real driving and walking")
                        perk("shield.lefthalf.filled", "SHIELD")
                        perk("calendar.badge.clock", "Routines, schedules and trip replay")
                        perk("dpad.fill", "Joystick")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()

                    VStack(alignment: .leading, spacing: Metrics.tight) {
                        TextField("CLOAK-", text: $key)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .padding(.horizontal, Metrics.snug)
                            .frame(minHeight: 48)
                            .background(Palette.surface, in: .rect(cornerRadius: Metrics.radius, style: .continuous))

                        if let problem = licensing.problem {
                            Label(problem, systemImage: "exclamationmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(Palette.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, Metrics.loose)
                .padding(.top, Metrics.loose)
                .padding(.bottom, Metrics.loose)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.ground.ignoresSafeArea())
            .paywallActionBar {
                Button {
                    Task {
                        await licensing.activate(key: key)
                        if licensing.isUnlocked { dismiss() }
                    }
                } label: {
                    if licensing.isWorking {
                        ProgressView().tint(Palette.ground)
                    } else {
                        Text("Unlock with licence").font(.headline)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(key.count < 8 || licensing.isWorking)

                Button {
                    dismiss()
                } label: {
                    Text("Keep using the free version")
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }

    private func perk(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
        }
    }
}

// MARK: - Bottom bar

private extension View {
    @ViewBuilder
    func paywallActionBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        let content = VStack(spacing: Metrics.hair) { bar() }
            .padding(.horizontal, Metrics.loose)
            .padding(.top, Metrics.snug)
            .padding(.bottom, Metrics.tight)
            .background { ActionBarBackdrop() }

        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom) { content }
        } else {
            safeAreaInset(edge: .bottom) {
                content
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
