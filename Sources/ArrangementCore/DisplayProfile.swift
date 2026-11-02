import Foundation

/// Names, resolution, Dock placement and enumeration order do not define identity.
public struct DisplayProfile: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case builtinOnly, openWithExternal, clamshell, externalOnly

        public var title: String {
            switch self {
            case .builtinOnly: return "内蔵画面のみ"
            case .openWithExternal: return "MacBook＋外部モニター"
            case .clamshell: return "クラムシェル"
            case .externalOnly: return "外部モニターのみ"
            }
        }
    }

    public let mode: Mode
    public let displayIDs: Set<String>

    public init(mode: Mode, displayIDs: Set<String>) {
        self.mode = mode
        self.displayIDs = displayIDs
    }

    public static func detect(displays: [DisplayRecord], lidClosed: Bool?) -> DisplayProfile? {
        guard !displays.isEmpty, displays.allSatisfy({ !$0.id.isEmpty && $0.isBuiltin != nil }),
              Set(displays.map(\.id)).count == displays.count else { return nil }
        let builtin = displays.contains { $0.isBuiltin == true }
        let external = displays.contains { $0.isBuiltin == false }
        // The lid can change before the screen list settles. Never save that transient state.
        if builtin && lidClosed == true { return nil }
        let mode: Mode
        if !external { mode = .builtinOnly }
        else if lidClosed == true { mode = .clamshell }
        else if builtin || lidClosed == false { mode = .openWithExternal }
        else { mode = .externalOnly }
        return DisplayProfile(mode: mode, displayIDs: Set(displays.map(\.id)))
    }

    public func label(displays: [DisplayRecord]) -> String {
        let names = displays.filter { displayIDs.contains($0.id) && $0.isBuiltin != true }
            .sorted { $0.id < $1.id }.map(\.name)
        return ([mode.title] + names).joined(separator: " · ")
    }
}

public enum ProfileSaveError: LocalizedError {
    case conflict, changed
    public var errorDescription: String? {
        switch self {
        case .conflict: return "同じ構成のSnapshotがあります。更新するSnapshotを確認してください。"
        case .changed: return "保存先のSnapshotが変更されました。もう一度保存してください。"
        }
    }
}

extension AppData {
    public func snapshots(for profile: DisplayProfile) -> [Snapshot] {
        snapshots.filter { $0.profile == profile }
    }

    /// Ambiguous imported data is never automatically selected.
    public func automaticSnapshot(for profile: DisplayProfile) -> Snapshot? {
        let matches = snapshots(for: profile)
        return matches.count == 1 ? matches.first : nil
    }

    /// Updating keeps identity/name and demotes any other conflicting entries to manual snapshots.
    @discardableResult
    public mutating func saveSnapshot(_ snapshot: Snapshot, replacing id: UUID? = nil) throws -> UUID {
        var saved = snapshot
        if let id {
            guard let index = snapshots.firstIndex(where: { $0.id == id }),
                  let profile = snapshot.profile, snapshots[index].profile == profile else { throw ProfileSaveError.changed }
            saved.id = id
            saved.name = snapshots[index].name
            saved.createdAt = snapshots[index].createdAt
            saved.updatedAt = snapshot.createdAt
            for other in snapshots.indices where snapshots[other].profile == profile && other != index {
                snapshots[other].profile = nil
            }
            snapshots[index] = saved
        } else {
            if let profile = snapshot.profile, !snapshots(for: profile).isEmpty { throw ProfileSaveError.conflict }
            snapshots.insert(saved, at: 0)
        }
        selectedSnapshotID = saved.id
        return saved.id
    }
}

/// Independent of timers and AppKit so timing, busy states and reconnects can be tested.
public struct ProfileRestoreGate {
    private var candidate: DisplayProfile?
    private var stableSince: TimeInterval?
    private var handled: DisplayProfile?
    public let settlingDelay: TimeInterval

    public init(settlingDelay: TimeInterval = 3) { self.settlingDelay = settlingDelay }

    public mutating func invalidate(retry: Bool = false) {
        stableSince = nil
        if retry { handled = nil }
    }

    public mutating func markHandled(_ profile: DisplayProfile) { handled = profile }

    public mutating func observe(_ profile: DisplayProfile?, now: TimeInterval, enabled: Bool, ready: Bool) -> DisplayProfile? {
        guard enabled else {
            candidate = nil; stableSince = nil; handled = nil
            return nil
        }
        guard let profile else {
            candidate = nil; stableSince = nil
            return nil
        }
        if profile != candidate || stableSince == nil {
            candidate = profile; stableSince = now
            return nil
        }
        guard ready, now - (stableSince ?? now) >= settlingDelay, handled != profile else { return nil }
        handled = profile
        return profile
    }
}
