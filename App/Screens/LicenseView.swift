import SwiftUI
import CloakKit

/// The gate. One field, and enough context that somebody who has just paid
/// knows what to put in it.
struct LicenseView: View {
    @Environment(LicenseController.self) private var licensing

    @State private var key = ""
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 56

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.loose) {
                VStack(spacing: Metrics.regular) {
                    Image(systemName: "key.fill")
                        .font(.system(size: heroSize))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .frame(minHeight: heroSize + 8)
                        .accessibilityHidden(true)

                    Text("Enter your licence")
                        .font(.title.bold())
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    Text("It came with your receipt and looks like CLOAK-XXXXX-XXXXX-XXXXX-XXXXX. One licence covers one phone.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: Metrics.tight) {
                    TextField("CLOAK-", text: $key)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .textContentType(.oneTimeCode)
                        .submitLabel(.go)
                        .onSubmit {
                            guard key.count >= 8, !licensing.isWorking else { return }
                            Task { await licensing.activate(key: key) }
                        }
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                        .focused($focused)
                        .padding(.horizontal, Metrics.regular)
                        .frame(minHeight: 52)
                        .background(Palette.surface, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                                .strokeBorder(focused ? Palette.accent.opacity(0.6) : Palette.hairline, lineWidth: 1)
                        )

                    if let problem = licensing.problem {
                        Label(problem, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // The field's footer, the way Settings writes one: the
                    // two things people ask about, in plain sentences.
                    Text("Using it on a new phone means releasing it from the old one first, in Settings. It keeps working offline: Cloak checks in occasionally and holds a fortnight's grace, so a flight or a dead server does not lock you out.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Metrics.hair)
                }
            }
            .padding(.horizontal, Metrics.loose)
            .padding(.top, Metrics.loose)
            .padding(.bottom, Metrics.loose)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.ground.ignoresSafeArea())
        .licenseActionBar {
            Button {
                Task { await licensing.activate(key: key) }
            } label: {
                if licensing.isWorking {
                    ProgressView().tint(Palette.ground)
                } else {
                    Text("Unlock Cloak").font(.headline)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(key.count < 8 || licensing.isWorking)

            Button {
                Task { await licensing.startTrial() }
            } label: {
                VStack(spacing: 2) {
                    Label("Try it free", systemImage: "gift")
                        .font(.body)
                    Text("10 minutes of location changing every day")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }

}

/// Shown when the licence itself is the problem, rather than a missing one.
struct LicenseRefusedView: View {
    @Environment(LicenseController.self) private var licensing
    let reason: String

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Cloak is locked")
            } icon: {
                Image(systemName: "lock.circle.fill")
                    .foregroundStyle(Palette.warn)
            }
        } description: {
            Text(reason)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground.ignoresSafeArea())
        .licenseActionBar {
            Button {
                Task { await licensing.start() }
            } label: {
                Text("Try again").font(.headline)
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                Task { await licensing.release() }
            } label: {
                Text("Use a different licence")
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Bottom bar

private extension View {
    /// One prominent button and one quiet one, pinned to the bottom and
    /// riding up with the keyboard.
    @ViewBuilder
    func licenseActionBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
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
