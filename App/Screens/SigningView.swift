import SwiftUI
import CloakKit

struct SigningView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable private var controller = RenewController.shared
    @State private var password = ""
    @State private var code = ""

    private var signature: SignatureInfo? { controller.signature }

    /// After Apple refuses one, the field is the most obvious place to say so.
    private var passwordPrompt: String {
        if controller.passwordRejected { return "Enter your password again" }
        return controller.hasStoredPassword ? "Saved" : "Password"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Metrics.regular) {
                    if case .failed(let message) = controller.phase {
                        noticeCard(message, tint: Palette.danger, icon: "exclamationmark.triangle.fill")
                    }
                    if case .done = controller.phase {
                        noticeCard("Refreshed. Cloak is good for another seven days.", tint: Palette.ok, icon: "checkmark.seal.fill")
                    }
                    countdownCard
                    if case .needsCode(let sms) = controller.phase {
                        codeCard(sms: sms)
                    }
                    appleIDCard
                    checklistCard
                }
                .padding(.horizontal, Metrics.regular)
                .padding(.bottom, Metrics.loose)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.ground.ignoresSafeArea())
            .signingActionBar { bottomAction }
            .navigationTitle("Signing")
            .navigationBarTitleDisplayMode(.large)
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
            .onAppear { controller.refreshSignature() }
        }
        .tint(Palette.accent)
    }

    /// The system close button on iOS 26, and the familiar Done before it.
    private static var closePlacement: ToolbarItemPlacement {
        if #available(iOS 26.0, *) { return .cancellationAction }
        return .confirmationAction
    }

    // MARK: - Bottom action

    /// Refresh, or the code Apple asked for, or the progress of either.
    @ViewBuilder
    private var bottomAction: some View {
        if case .needsCode = controller.phase {
            Button {
                controller.submitCode(code); code = ""
            } label: {
                Text("Submit code").font(.headline)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(code.count < 4)

            Button {
                controller.cancel()
            } label: {
                Text("Cancel")
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
        } else if case .working(let label, let progress) = controller.phase {
            VStack(alignment: .leading, spacing: Metrics.tight) {
                ProgressView(value: progress)
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 50)
        } else {
            Button {
                controller.renew(password: password.isEmpty ? nil : password,
                                 pairing: try? model.pairingStore.load())
            } label: {
                Label("Refresh now", systemImage: "arrow.clockwise")
                    .font(.headline)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(controller.appleID.isEmpty)

            if controller.appleID.isEmpty {
                Text("Sign in with your Apple ID above to refresh on the phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
        }
    }

    // MARK: - Cards

    private var ringTint: Color {
        guard let signature else { return .secondary }
        if signature.hasExpired { return Palette.danger }
        return signature.isUrgent ? Palette.warn : Palette.accent
    }

    private var countdownCard: some View {
        VStack(alignment: .leading, spacing: Metrics.regular) {
            HStack(spacing: Metrics.regular) {
                ZStack {
                    Circle()
                        .stroke(Palette.raised, lineWidth: 8)
                        .frame(width: 96, height: 96)
                    Circle()
                        .trim(from: 0, to: CGFloat(signature?.fractionLeft ?? 0))
                        .stroke(ringTint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 96, height: 96)
                        .animation(.easeInOut, value: signature?.fractionLeft)
                    VStack(spacing: 0) {
                        Text("\(signature?.daysLeft ?? 0)")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit())
                            .foregroundStyle(ringTint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(signature?.daysLeft == 1 ? "day" : "days")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 80)
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Metrics.hair) {
                    Text(headline)
                        .font(.title2.bold())
                        .foregroundStyle(ringTint)
                    if let signature {
                        Text("Until \(signature.expires.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }

            Divider()

            Text("Apple makes apps installed this way re-sign themselves every seven days. The computer that installed Cloak keeps doing that on its own. You can also refresh right here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Label("Free. Not a payment.", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ok)
        }
        .card()
    }

    private var headline: String {
        guard let signature else { return "Not signed" }
        if signature.hasExpired { return "Expired" }
        return "\(signature.daysLeft) \(signature.daysLeft == 1 ? "day" : "days") left"
    }

    private var appleIDCard: some View {
        VStack(alignment: .leading, spacing: Metrics.snug) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple ID")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Sign in once. Cloak remembers it for every refresh after this.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "person.badge.key.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }

            VStack(spacing: 0) {
                HStack(spacing: Metrics.tight) {
                    Image(systemName: "envelope").foregroundStyle(.secondary).frame(width: 20)
                    TextField("Apple ID email", text: $controller.appleID)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                }
                .frame(minHeight: 44)
                Divider()
                HStack(spacing: Metrics.tight) {
                    Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 20)
                    SecureField(passwordPrompt, text: $password)
                }
                .frame(minHeight: 44)
            }
            .font(.body)
            .padding(.horizontal, Metrics.snug)
            .background(Palette.raised, in: .rect(cornerRadius: Metrics.radius, style: .continuous))

            Toggle(isOn: Binding(get: { controller.autoRenew }, set: { controller.setAuto($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep it renewed automatically")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text("Saves your password to this iPhone's keychain so refreshes never ask again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if controller.appleID.isEmpty == false {
                Button(role: .destructive) {
                    controller.signOut(); password = ""
                } label: {
                    Text("Sign out")
                        .font(.body)
                        .foregroundStyle(Palette.danger)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
            }

            Text("Used only to sign Cloak with Apple. Nothing is sent anywhere else.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private func codeCard(sms: Bool) -> some View {
        VStack(alignment: .leading, spacing: Metrics.snug) {
            Text(sms ? "Apple texted you a code" : "Apple sent a code to your other devices")
                .font(.headline)
                .foregroundStyle(.primary)
            TextField("Verification code", text: $code)
                .keyboardType(.numberPad)
                .font(.title3.monospacedDigit())
                .padding(.horizontal, Metrics.snug)
                .frame(minHeight: 48)
                .background(Palette.raised, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var checklistCard: some View {
        VStack(alignment: .leading, spacing: Metrics.snug) {
            Text("What refreshing needs")
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            checkRow("Apple ID", ok: !controller.appleID.isEmpty, detail: controller.appleID.isEmpty ? "Sign in above" : controller.appleID)
            checkRow("Pairing", ok: model.hasAnyPairing, detail: model.hasAnyPairing ? "Ready" : "Pair without a computer first")
            checkRow("Tunnel", ok: model.hasLocalNetwork, detail: model.hasLocalNetwork ? "On" : "Turn the tunnel on")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func checkRow(_ title: String, ok: Bool, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Palette.ok : Palette.warn)
        }
        .accessibilityElement(children: .combine)
    }

    private func noticeCard(_ message: String, tint: Color, icon: String) -> some View {
        Label {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.snug)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - Bottom bar

private extension View {
    @ViewBuilder
    func signingActionBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        let content = VStack(spacing: Metrics.hair) { bar() }
            .padding(.horizontal, Metrics.regular)
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
