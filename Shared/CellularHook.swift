import Foundation

public enum CellularHook {
    nonisolated(unsafe) public static var prepare: (@Sendable () async -> Bool)?
    nonisolated(unsafe) public static var finished: (@Sendable (Bool) async -> Void)?
}
