import Foundation
import CoreLocation
import CoreMotion
import CloakKit

@MainActor
final class LocationPeek: NSObject {
    struct Result: Sendable {
        var coordinate: Coordinate
        var sampledAt: Date
    }

    private let manager = CLLocationManager()
    private let activity = CMMotionActivityManager()
    private var continuation: CheckedContinuation<Result?, Never>?
    private(set) var lastResult: Result?
    private(set) var realMotionDetected = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func beginMonitoringMotion() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        activity.startActivityUpdates(to: .main) { [weak self] update in
            guard let update else { return }
            self?.realMotionDetected = update.automotive || update.cycling || update.running
        }
    }

    func sample(clearing: @Sendable () async -> Void, restoring: @Sendable () async -> Void, settle: Duration = .seconds(2)) async -> Result? {
        await clearing()
        try? await Task.sleep(for: settle)

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
            self.continuation = continuation
            manager.requestLocation()
        }

        await restoring()
        if let result { lastResult = result }
        return result
    }
}

extension LocationPeek: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let result = Result(coordinate: Coordinate(last.coordinate), sampledAt: .now)
        Task { @MainActor in
            self.continuation?.resume(returning: result)
            self.continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(returning: nil)
            self.continuation = nil
        }
    }
}
