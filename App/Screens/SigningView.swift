import SwiftUI
import CloakKit

struct SigningView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var controller = RenewController()
    @State private var password = ""
    @State private var code = ""

    private var signature: SignatureInfo? { controller.signature }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
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
                .padding(Metrics.regular)
            }
            .background(Palette.ground.ignoresSafeArea())
            .navigationTitle("Signing")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { controller.refreshSignature() }
        }
    }

    private var ringTint: Color {
        guard let signature else { return Palette.dim }
        if signature.hasExpired { return Palette.danger }
        return signature.isUrgent ? Palette.warn : Palette.accent
    }

    private var countdownCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 18) {
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
                            .font(.readout(34, weight: .bold))
                            .foregroundStyle(ringTint)
                        Text(signature?.daysLeft == 1 ? "DAY" : "DAYS")
                            .font(.label(10, weight: .bold))
                            .foregroundStyle(Palette.dim)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.readout(22, weight: .bold))
                        .foregroundStyle(ringTint)
                    if let signature {
                        Text("Until \(signature.expires.formatted(date: .abbreviated, time: .shortened))")
                            .font(.label(13))
                            .foregroundStyle(Palette.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            Divider().overlay(Palette.hairline)

            Text("Apple makes apps installed this way re-sign themselves every seven days. The computer that installed Cloak keeps doing that on its own. You can also refresh right here.")
                .font(.label(13))
                .foregroundStyle(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.ok)
                Text("Free. Not a payment.")
                    .font(.label(14, weight: .semibold))
                    .foregroundStyle(Palette.ok)
                Spacer()
            }

            if case .working(let label, let progress) = controller.phase {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress).tint(Palette.accent)
                    Text(label).font(.label(12)).foregroundStyle(Palette.dim)
                }
            } else {
                Button {
                    controller.renew(password: password.isEmpty ? nil : password,
                                     pairing: try? model.pairingStore.load())
                } label: {
                    Label("Refresh now", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(controller.appleID.isEmpty)
            }

            if controller.appleID.isEmpty {
                Text("Sign in below to refresh on the phone.")
                    .font(.label(12))
                    .foregroundStyle(Palette.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Metrics.card)
        .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private var headline: String {
        guard let signature else { return "Not signed" }
        if signature.hasExpired { return "Expired" }
        return "\(signature.daysLeft) \(signature.daysLeft == 1 ? "day" : "days") left"
    }

    private var appleIDCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(.title3))
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple ID")
                        .font(.label(16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Sign in once. Cloak remembers it for every refresh after this.")
                        .font(.label(12))
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "envelope").foregroundStyle(Palette.dim).frame(width: 20)
                    TextField("Apple ID email", text: $controller.appleID)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                }
                .padding(.vertical, 12)
                Divider().overlay(Palette.hairline)
                HStack(spacing: 10) {
                    Image(systemName: "lock").foregroundStyle(Palette.dim).frame(width: 20)
                    SecureField(controller.hasStoredPassword ? "Saved" : "Password", text: $password)
                }
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 12)
            .background(Palette.raised, in: .rect(cornerRadius: 14, style: .continuous))

            Toggle(isOn: Binding(get: { controller.autoRenew }, set: { controller.setAuto($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep it renewed automatically")
                        .font(.label(14, weight: .medium))
                        .foregroundStyle(.white)
                    Text("Saves your password to this iPhone's keychain so refreshes never ask again.")
                        .font(.label(11))
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Palette.accent)

            if controller.appleID.isEmpty == false {
                Button("Sign out") { controller.signOut(); password = "" }
                    .buttonStyle(QuietButtonStyle(tint: Palette.danger))
            }

            Text("Used only to sign Cloak with Apple. Nothing is sent anywhere else.")
                .font(.label(11))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.card)
        .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func codeCard(sms: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(sms ? "Apple texted you a code" : "Apple sent a code to your other devices")
                .font(.label(15, weight: .semibold))
                .foregroundStyle(.white)
            TextField("Verification code", text: $code)
                .keyboardType(.numberPad)
                .padding(12)
                .background(Palette.raised, in: .rect(cornerRadius: 12, style: .continuous))
            Button("Submit code") { controller.submitCode(code); code = "" }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(code.count < 4)
            Button("Cancel") { controller.cancel() }
                .buttonStyle(QuietButtonStyle(tint: Palette.dim))
        }
        .padding(Metrics.card)
        .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private var checklistCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "What refreshing needs")
            checkRow("Apple ID", ok: !controller.appleID.isEmpty, detail: controller.appleID.isEmpty ? "Sign in above" : controller.appleID)
            checkRow("Pairing", ok: model.hasAnyPairing, detail: model.hasAnyPairing ? "Ready" : "Pair without a computer first")
            checkRow("Tunnel", ok: model.hasLocalNetwork, detail: model.hasLocalNetwork ? "On" : "Turn the tunnel on")
        }
        .padding(Metrics.card)
        .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func checkRow(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Palette.ok : Palette.warn)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.label(14, weight: .medium)).foregroundStyle(.white)
                Text(detail).font(.label(11)).foregroundStyle(Palette.dim).lineLimit(1)
            }
            Spacer()
        }
    }

    private func noticeCard(_ message: String, tint: Color, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(message).font(.label(13)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.4), lineWidth: 1))
    }
}
