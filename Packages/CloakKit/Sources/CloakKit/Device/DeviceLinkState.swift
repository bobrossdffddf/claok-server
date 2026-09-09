import Foundation

public enum LinkStage: String, CaseIterable, Sendable, Identifiable {
    case developerMode
    case pairing
    case tunnel
    case diskImage
    case service

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .developerMode: "Developer Mode"
        case .pairing: "Pairing record"
        case .tunnel: "Tunnel"
        case .diskImage: "Developer image"
        case .service: "Location service"
        }
    }

    public var detail: String {
        switch self {
        case .developerMode: "Apple gates its own developer services behind this switch. Nothing is modified, it just unlocks what iOS already ships."
        case .pairing: "Proves to the phone that this app is a trusted host. Scanned once, stored in the Keychain."
        case .tunnel: "A loopback connection to your own phone. No traffic leaves the device."
        case .diskImage: "Apple's developer disk image, mounted automatically and cached per iOS build."
        case .service: "The location simulation service Xcode uses."
        }
    }
}

public enum StageStatus: Equatable, Sendable {
    case unknown
    case working
    case ready
    case failed(String)

    public var isReady: Bool { self == .ready }

    public var symbolName: String {
        switch self {
        case .unknown: "circle.dotted"
        case .working: "circle.dashed"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

public struct DeviceLinkState: Equatable, Sendable {
    public var stages: [LinkStage: StageStatus]
    public var lastError: String?
    public var reconnectCount: Int
    public var lastGap: TimeInterval?

    public init(
        stages: [LinkStage: StageStatus] = Dictionary(uniqueKeysWithValues: LinkStage.allCases.map { ($0, .unknown) }),
        lastError: String? = nil,
        reconnectCount: Int = 0,
        lastGap: TimeInterval? = nil
    ) {
        self.stages = stages
        self.lastError = lastError
        self.reconnectCount = reconnectCount
        self.lastGap = lastGap
    }

    public var isReady: Bool { LinkStage.allCases.allSatisfy { stages[$0]?.isReady == true } }

    public func status(_ stage: LinkStage) -> StageStatus { stages[stage] ?? .unknown }

    public var firstProblem: LinkStage? {
        LinkStage.allCases.first { stages[$0]?.isReady != true }
    }
}
