import Foundation
import CoreGraphics

public enum WindowAction: String, CaseIterable, Codable, Identifiable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    case fill, center, nextDisplay, minimize, fullscreen, snapshot, restore
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .left: return "左半分"; case .right: return "右半分"
        case .top: return "上半分"; case .bottom: return "下半分"
        case .topLeft: return "左上 ¼"; case .topRight: return "右上 ¼"
        case .bottomLeft: return "左下 ¼"; case .bottomRight: return "右下 ¼"
        case .fill: return "画面いっぱいに配置"; case .center: return "中央に配置"
        case .nextDisplay: return "次のディスプレイへ"; case .minimize: return "最小化"
        case .fullscreen: return "フルスクリーン切替"; case .snapshot: return "Snapshotを保存"
        case .restore: return "選択中のSnapshotを復元"
        }
    }
    public var symbol: String {
        switch self {
        case .left, .right: return "rectangle.split.2x1"
        case .top, .bottom: return "rectangle.split.1x2"
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return "rectangle.split.2x2"
        case .fill: return "arrow.up.left.and.arrow.down.right"
        case .center: return "viewfinder"; case .nextDisplay: return "display.2"
        case .minimize: return "minus.square"; case .fullscreen: return "arrow.up.backward.and.arrow.down.forward"
        case .snapshot: return "camera"; case .restore: return "arrow.counterclockwise"
        }
    }
}

public struct Shortcut: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var label: String
    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    public func conflicts(with other: Shortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

public struct DisplayRecord: Codable, Identifiable {
    public var id: String
    public var name: String
    public var frame: CGRect
    public var visibleFrame: CGRect
    public init(id: String, name: String, frame: CGRect, visibleFrame: CGRect) {
        self.id = id; self.name = name; self.frame = frame; self.visibleFrame = visibleFrame
    }
}

public struct SpaceRecord: Codable, Identifiable {
    public var id: String
    public var index: Int
    public var label: String
    public var displayID: String
    public init(id: String, index: Int, label: String, displayID: String = "") { self.id = id; self.index = index; self.label = label; self.displayID = displayID }
}

public struct WindowRecord: Codable, Identifiable {
    public var id = UUID()
    public var appID: String
    public var appName: String
    public var title: String
    public var identifier: String
    public var session: String
    public var nativeID: UInt32?
    /// nil for legacy data; empty when queried but no document URL is exposed.
    public var documentURL: String?
    public var frame: CGRect
    public var displayID: String
    public var spaceID: String?
    public var minimized: Bool
    public init(appID: String, appName: String, title: String, identifier: String = "", session: String = "",
                nativeID: UInt32? = nil, documentURL: String? = nil, frame: CGRect, displayID: String, spaceID: String? = nil, minimized: Bool = false) {
        self.appID = appID; self.appName = appName; self.title = title; self.identifier = identifier
        self.session = session; self.nativeID = nativeID; self.documentURL = documentURL; self.frame = frame; self.displayID = displayID
        self.spaceID = spaceID; self.minimized = minimized
    }
}

public enum SnapshotBackend: String, Codable { case accessibility, nativeSpaces }

public struct Snapshot: Codable, Identifiable {
    public var id = UUID()
    public var name: String
    public var createdAt = Date()
    public var backend: SnapshotBackend
    public var displays: [DisplayRecord]
    public var spaces: [SpaceRecord]
    public var windows: [WindowRecord]
    public init(name: String, backend: SnapshotBackend, displays: [DisplayRecord], spaces: [SpaceRecord] = [], windows: [WindowRecord]) {
        self.name = name; self.backend = backend; self.displays = displays; self.spaces = spaces; self.windows = windows
    }
}

public struct AppData: Codable {
    public var version = 1
    public var snapshots: [Snapshot] = []
    public var shortcuts: [String: Shortcut] = [:]
    public var selectedSnapshotID: UUID?
    public var spacesEnabled = true
    public init() {}
}

public enum Layout {
    public static func frame(for action: WindowAction, window: CGRect, screen: CGRect) -> CGRect? {
        let halfW = screen.width / 2, halfH = screen.height / 2
        switch action {
        case .left: return CGRect(x: screen.minX, y: screen.minY, width: halfW, height: screen.height)
        case .right: return CGRect(x: screen.midX, y: screen.minY, width: halfW, height: screen.height)
        case .top: return CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: halfH)
        case .bottom: return CGRect(x: screen.minX, y: screen.midY, width: screen.width, height: halfH)
        case .topLeft: return CGRect(x: screen.minX, y: screen.minY, width: halfW, height: halfH)
        case .topRight: return CGRect(x: screen.midX, y: screen.minY, width: halfW, height: halfH)
        case .bottomLeft: return CGRect(x: screen.minX, y: screen.midY, width: halfW, height: halfH)
        case .bottomRight: return CGRect(x: screen.midX, y: screen.midY, width: halfW, height: halfH)
        case .fill: return screen
        case .center:
            let size = CGSize(width: min(window.width, screen.width), height: min(window.height, screen.height))
            return CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        default: return nil
        }
    }
    public static func display(for frame: CGRect, in displays: [DisplayRecord]) -> DisplayRecord? {
        displays.max { a, b in area(frame.intersection(a.frame)) < area(frame.intersection(b.frame)) }
    }
    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
    public static func remap(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        if source == target { return frame }
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return frame }
        let width = min(target.width, max(1, frame.width * target.width / source.width))
        let height = min(target.height, max(1, frame.height * target.height / source.height))
        let x = target.minX + (frame.minX - source.minX) * target.width / source.width
        let y = target.minY + (frame.minY - source.minY) * target.height / source.height
        return CGRect(x: min(max(x, target.minX), target.maxX - width), y: min(max(y, target.minY), target.maxY - height), width: width, height: height)
    }
    public static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 5) -> Bool {
        abs(a.minX-b.minX) <= tolerance && abs(a.minY-b.minY) <= tolerance && abs(a.width-b.width) <= tolerance && abs(a.height-b.height) <= tolerance
    }
}

public enum WindowMatcher {
    /// Session IDs are only valid until the application restarts. Across sessions, use
    /// unique document URLs, titles and supported editor workspace identities.
    /// Uniqueness is checked against the entire set, including already matched windows.
    public static func match(saved: [WindowRecord], live: [WindowRecord]) -> [UUID: UUID] {
        var matches: [UUID: UUID] = [:]
        var used = Set<UUID>()
        let identities = EditorWindowIdentities(windows: saved + live)
        for stage in 0..<6 {
            func compatible(_ item: WindowRecord, _ candidate: WindowRecord) -> Bool {
                guard candidate.appID == item.appID else { return false }
                switch stage {
                case 0: return item.nativeID != nil && candidate.nativeID == item.nativeID && !item.session.isEmpty && candidate.session == item.session
                case 1: return !item.identifier.isEmpty && candidate.identifier == item.identifier
                case 2:
                    guard let document = WindowDocument.identity(item.documentURL) else { return false }
                    return document == WindowDocument.identity(candidate.documentURL)
                case 3: return !item.title.isEmpty && candidate.title == item.title
                case 4: return identities.matches(item, candidate)
                default: return saved.filter { $0.appID == item.appID }.count == 1 && live.filter { $0.appID == item.appID }.count == 1
                }
            }
            for item in saved where matches[item.id] == nil {
                let candidates = live.filter { compatible(item, $0) }
                guard candidates.count == 1, let candidate = candidates.first, !used.contains(candidate.id),
                      saved.filter({ compatible($0, candidate) }).count == 1 else { continue }
                matches[item.id] = candidate.id; used.insert(candidate.id)
            }
        }
        return matches
    }
}

public struct DataStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> AppData {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppData() }
        let data = try JSONDecoder().decode(AppData.self, from: Data(contentsOf: url))
        guard data.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
    public func save(_ data: AppData) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(data).write(to: url, options: .atomic)
    }
}
