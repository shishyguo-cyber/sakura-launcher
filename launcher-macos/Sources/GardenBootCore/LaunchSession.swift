import Foundation

public struct LaunchSession {
    public private(set) var activePID: Int32?
    private let targetIdentifier: String
    private var knownPIDs: Set<Int32>

    public init(targetIdentifier: String, existingPIDs: Set<Int32>) {
        self.targetIdentifier = targetIdentifier
        self.knownPIDs = existingPIDs
    }

    public mutating func didLaunch(identifier: String, pid: Int32) -> Bool {
        guard identifier == targetIdentifier else { return false }
        let wasEmpty = knownPIDs.isEmpty
        guard knownPIDs.insert(pid).inserted, wasEmpty else { return false }
        activePID = pid
        return true
    }

    public mutating func didTerminate(pid: Int32) -> Bool {
        knownPIDs.remove(pid)
        guard knownPIDs.isEmpty, activePID != nil else { return false }
        activePID = nil
        return true
    }
    public mutating func finish() { activePID = nil }
}
