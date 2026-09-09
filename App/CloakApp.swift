import SwiftUI
import SwiftData
import CloakKit

@main
struct CloakApp: App {
    @State private var model = AppModel()
    @State private var scheduler = RunScheduler()
    @State private var licensing = LicenseController()

    private let container: ModelContainer = {
        let schema = Schema([Place.self, SavedRoute.self, RecordedTrip.self, ScheduledRun.self, Routine.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            // A store that will not open is not a reason to refuse to launch.
            // Falling back to memory loses saved places, and the alternative
            // loses the whole app.
            return try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(scheduler)
                .environment(licensing)
                .tint(Palette.accent)
                .preferredColorScheme(.dark)
                .task {
                    await licensing.start()
                    model.onAppear()
                    scheduler.attach(container: container, model: model)
                }
                .onOpenURL { _ in
                    // LocalDevVPN bounces back here after switching its tunnel
                    // on. Nothing to do but notice that it worked.
                    Task { await model.ensureTunnelUp() }
                }
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(LicenseController.self) private var licensing

    var body: some View {
        Group {
            switch licensing.state {
            case .checking:
                LoadingScreen()
            case .needsKey:
                LicenseView()
            case .refused(let reason):
                LicenseRefusedView(reason: reason)
            case .unlocked:
                if model.isOnboarded && model.isSetupComplete {
                    MapScreen()
                } else {
                    OnboardingView()
                }
            }
        }
        .overlay(alignment: .top) {
            if let update = licensing.update {
                UpdateBanner(update: update)
                    .padding(.horizontal, Metrics.regular)
                    .padding(.top, Metrics.tight)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: licensing.update)
    }
}

struct LoadingScreen: View {
    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            ProgressView().tint(Palette.accent)
        }
        .preferredColorScheme(.dark)
    }
}

/// Says a new build exists and where to get it. Cloak is not on the App Store,
/// so nothing tells anybody about an update unless the app does.
struct UpdateBanner: View {
    @Environment(LicenseController.self) private var licensing
    let update: LicenseUpdate

    var body: some View {
        HStack(spacing: Metrics.snug) {
            Image(systemName: update.required ? "exclamationmark.arrow.circlepath" : "arrow.down.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(update.required ? Palette.warn : Palette.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(update.required ? "Update needed" : "Cloak \(update.version) is out")
                    .font(.label(14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(update.notes.isEmpty ? "Tap to get it." : update.notes)
                    .font(.label(12))
                    .foregroundStyle(Palette.dim)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if !update.required {
                Button {
                    licensing.dismissUpdate()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.dim)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Metrics.snug)
        .glassCard(padding: Metrics.snug, radius: 14)
        .contentShape(.rect)
        .onTapGesture { licensing.openUpdate() }
    }
}
