import Foundation

public actor DeviceLink {
    public private(set) var state = DeviceLinkState()
    private let backend: DeviceBackend
    private let store: PairingStore
    private var continuations: [UUID: AsyncStream<DeviceLinkState>.Continuation] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var droppedAt: Date?

    public init(backend: DeviceBackend, store: PairingStore = PairingStore()) {
        self.backend = backend
        self.store = store
    }

    public var updates: AsyncStream<DeviceLinkState> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func publish() {
        for continuation in continuations.values { continuation.yield(state) }
    }

    private func set(_ stage: LinkStage, _ status: StageStatus) {
        state.stages[stage] = status
        if case .failed(let message) = status { state.lastError = message }
        publish()
    }

    public func markDeveloperMode(enabled: Bool) {
        set(.developerMode, enabled ? .ready : .failed("Developer Mode is off."))
    }

    @discardableResult
    public func bringUp() async -> Bool {
        guard Licensing.verifiedNow else {
            set(.pairing, .failed("Cloak needs an active licence."))
            return false
        }
        guard state.status(.developerMode).isReady else { return false }

        set(.pairing, .working)
        let needsRecord = await backend.requiresPairingRecord
        let record: PairingRecord
        do {
            record = try store.load()
            set(.pairing, .ready)
        } catch {
            guard !needsRecord else {
                set(.pairing, .failed(error.localizedDescription))
                return false
            }
            // The phone paired with itself, so there is nothing to import.
            record = PairingRecord(plist: Data(), udid: "")
            set(.pairing, .ready)
        }

        set(.tunnel, .working)
        do {
            try await backend.connect(pairing: record)
            set(.tunnel, .ready)
        } catch {
            set(.tunnel, .failed(error.localizedDescription))
            return false
        }

        set(.diskImage, .working)
        do {
            try await backend.mountDeveloperImage()
            set(.diskImage, .ready)
        } catch {
            set(.diskImage, .failed(error.localizedDescription))
            return false
        }

        set(.service, .working)
        do {
            try await backend.openLocationService()
            set(.service, .ready)
        } catch {
            set(.service, .failed(error.localizedDescription))
            return false
        }

        if let droppedAt {
            state.lastGap = Date.now.timeIntervalSince(droppedAt)
            self.droppedAt = nil
            publish()
        }
        return true
    }

    public func push(_ fix: SimulatedFix) async {
        do {
            try await backend.setLocation(fix.coordinate)
        } catch {
            await handleDrop(error)
        }
    }

    public func clear() async {
        try? await backend.clearLocation()
    }

    public func tearDown() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        await backend.disconnect()
        state = DeviceLinkState(stages: state.stages.mapValues { _ in .unknown })
        publish()
    }

    private func handleDrop(_ error: Error) async {
        guard reconnectTask == nil else { return }
        droppedAt = .now
        set(.service, .failed(error.localizedDescription))
        state.reconnectCount += 1
        publish()

        // Keep trying for as long as the caller wants the link. Eight quick
        // attempts and then giving up meant a tunnel that went away for a
        // minute, say because the phone changed networks, took the whole
        // simulation down with it and never came back on its own.
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            var delay: Duration = .milliseconds(400)
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }

                if await self.bringUp() {
                    await self.finishReconnect()
                    return
                }

                // Back off to half a minute and stay there, so a long outage
                // costs almost nothing and recovery is still prompt.
                delay = min(delay * 2, .seconds(30))
            }
        }
    }

    private func finishReconnect() {
        reconnectTask = nil
    }
}
