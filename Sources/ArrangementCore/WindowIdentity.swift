import Foundation

enum WindowDocument {
    static func identity(_ value: String?) -> String? {
        guard let value, !value.isEmpty, let url = URL(string: value), url.scheme != nil else { return nil }
        if url.isFileURL { return url.standardizedFileURL.path.precomposedStringWithCanonicalMapping }
        return url.absoluteString
    }
}

/// VS Code's macOS default title is active editor — workspace — optional profile.
/// The editor component can disappear entirely (no editor) or become "Welcome".
/// Keep both interpretations of a two-component legacy title until the complete
/// saved/live window sets can disambiguate them. Never use enumeration order.
struct EditorWindowIdentities {
    private struct Workspace: Hashable {
        let name: String
        let profile: String?
    }
    private static let supportedApps: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
    private static let productNames: Set<String> = ["Visual Studio Code", "Code", "Code - Insiders", "Visual Studio Code - Insiders"]
    private static let nonDocumentEditors: Set<String> = ["Welcome", "Get Started", "Settings", "Keyboard Shortcuts", "Extensions", "ようこそ", "設定", "キーボード ショートカット", "拡張機能"]
    private let keys: [UUID: Set<Workspace>]

    init(windows: [WindowRecord]) {
        // A three-part default title establishes that the trailing component is
        // a profile. Do not mistake that profile for a workspace in a short title.
        var knownProfiles: [String: Set<String>] = [:]
        for window in windows where Self.supportedApps.contains(window.appID) {
            let parts = Self.parts(window.title)
            if parts.count >= 3 { knownProfiles[window.appID, default: []].insert(parts.last!) }
        }
        var keys: [UUID: Set<Workspace>] = [:]
        for window in windows where Self.supportedApps.contains(window.appID) {
            let parts = Self.parts(window.title)
            var candidates = Set<Workspace>()
            if parts.count >= 3 {
                candidates.insert(Workspace(name: parts[parts.count - 2], profile: parts.last))
            } else if parts.count == 2 {
                candidates.insert(Workspace(name: parts[0], profile: parts[1]))
                if !(knownProfiles[window.appID]?.contains(parts[1]) ?? false) {
                    candidates.insert(Workspace(name: parts[1], profile: nil))
                }
                // AXDocument lets new snapshots disambiguate editor — workspace
                // from workspace — profile without depending on a filename extension.
                if let document = WindowDocument.identity(window.documentURL),
                   URL(fileURLWithPath: document).lastPathComponent == parts[0] {
                    candidates = [Workspace(name: parts[1], profile: nil)]
                } else if window.documentURL == "" {
                    // New live records can distinguish missing metadata in an old
                    // snapshot from a window that actually has no document open.
                    // Only known non-document editors justify dropping the prefix.
                    if Self.nonDocumentEditors.contains(parts[0]) {
                        candidates = [Workspace(name: parts[1], profile: nil)]
                    } else {
                        candidates = [Workspace(name: parts[0], profile: parts[1])]
                    }
                }
            } else if let name = parts.first {
                candidates.insert(Workspace(name: name, profile: nil))
            }
            keys[window.id] = candidates.filter {
                !Self.productNames.contains($0.name) && ($0.profile != nil || !(knownProfiles[window.appID]?.contains($0.name) ?? false))
            }
        }
        self.keys = keys
    }
    func matches(_ saved: WindowRecord, _ live: WindowRecord) -> Bool {
        guard saved.appID == live.appID, let a = keys[saved.id], let b = keys[live.id] else { return false }
        return !a.isDisjoint(with: b)
    }
    private static func parts(_ title: String) -> [String] {
        var title = title.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        if title.hasPrefix("● ") { title.removeFirst(2) }
        return title.components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
