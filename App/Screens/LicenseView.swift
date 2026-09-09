import SwiftUI
import CloakKit

/// The gate. One field, and enough context that somebody who has just paid
/// knows what to put in it.
struct LicenseView: View {
    @Environment(LicenseController.self) private var licensing

    @State private var key = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            RadialGradient(
                colors: [Palette.accent.opacity(0.14), .clear],
                center: .topLeading, startRadius: 20, endRadius: 560
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.loose) {
                    ZStack {
                        Circle().fill(Palette.accent.opacity(0.13)).frame(width: 72, height: 72)
                        Image(systemName: "key.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                    }

                    VStack(alignment: .leading, spacing: Metrics.snug) {
                        Text("Enter your licence")
                            .font(.label(30, weight: .bold))
                            .foregroundStyle(.white)

                        Text("It came with your receipt and looks like CLOAK-XXXXX-XXXXX-XXXXX-XXXXX. One licence covers one phone.")
                            .font(.label(15))
                            .foregroundStyle(Palette.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: Metrics.tight) {
                        TextField("CLOAK-", text: $key)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.readout(17))
                            .foregroundStyle(.white)
                            .focused($focused)
                            .padding(16)
                            .background(Palette.surface, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                                    .strokeBorder(focused ? Palette.accent.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1)
                            )

                        if let problem = licensing.problem {
                            Text(problem)
                                .font(.label(13))
                                .foregroundStyle(Palette.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Button {
                        Task { await licensing.activate(key: key) }
                    } label: {
                        if licensing.isWorking {
                            ProgressView().tint(Palette.ground)
                        } else {
                            Text("Unlock Cloak")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(key.count < 8 || licensing.isWorking)
                    .opacity(key.count < 8 ? 0.45 : 1)

                    VStack(alignment: .leading, spacing: Metrics.tight) {
                        note("One phone at a time", "Using it on a new phone means releasing it from the old one first, in Settings.")
                        note("It keeps working offline", "Cloak checks in occasionally and holds a fortnight's grace, so a flight or a dead server does not lock you out.")
                    }
                }
                .padding(22)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }

    private func note(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Metrics.snug) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.label(13, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.label(12)).foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.snug)
        .background(Palette.surface.opacity(0.55), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// Shown when the licence itself is the problem, rather than a missing one.
struct LicenseRefusedView: View {
    @Environment(LicenseController.self) private var licensing
    let reason: String

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: Metrics.regular) {
                Image(systemName: "lock.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Palette.warn)
                Text("Cloak is locked")
                    .font(.label(24, weight: .bold))
                    .foregroundStyle(.white)
                Text(reason)
                    .font(.label(14))
                    .foregroundStyle(Palette.dim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Try again") { Task { await licensing.start() } }
                    .buttonStyle(PrimaryButtonStyle())

                Button("Use a different licence") { Task { await licensing.release() } }
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(30)
        }
        .preferredColorScheme(.dark)
    }
}
