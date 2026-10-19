import Foundation

public struct WindowReferenceKey: Hashable {
    public let appID: String
    public let session: String
    public let windowID: UInt32
    public init(appID: String, session: String, windowID: UInt32) {
        self.appID = appID; self.session = session; self.windowID = windowID
    }
}

/// AXWindows can omit a still-open window after it moves to an inactive Space.
/// Keep references while WindowServer confirms the same process/session/window.
public struct WindowReferenceCache<Reference> {
    private var entries: [WindowReferenceKey: Reference] = [:]
    public init() {}
    public mutating func merge(visible: [WindowReferenceKey: Reference], alive: Set<WindowReferenceKey>) -> [WindowReferenceKey: Reference] {
        entries = entries.filter { alive.contains($0.key) }
        for (key, reference) in visible where alive.contains(key) { entries[key] = reference }
        return entries
    }
    public mutating func remove(_ key: WindowReferenceKey) { entries.removeValue(forKey: key) }
}
