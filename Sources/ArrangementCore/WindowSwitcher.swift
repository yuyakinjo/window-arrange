import Foundation
import CoreGraphics

public protocol SwitcherChoice: RawRepresentable, CaseIterable, Codable, Hashable, Identifiable where RawValue == String {
    var title: String { get }
}
public extension SwitcherChoice { var id: String { rawValue } }
public enum SwitcherApps: String, SwitcherChoice {
    case all, active, other, underCursor, appUnderCursor
    public var title: String { switch self {
    case .all: return "すべてのアプリ"; case .active: return "現在のアプリ"; case .other: return "現在以外のアプリ"
    case .underCursor: return "カーソル下のウィンドウ"; case .appUnderCursor: return "カーソル下のアプリ"
    } }
    public var helpText: String { switch self {
    case .all: return "起動中の各アプリのウィンドウを表示します。"
    case .active: return "切替画面を開く直前に使っていたアプリのウィンドウだけを表示します。"
    case .other: return "切替画面を開く直前に使っていたアプリを除く、ほかのアプリのウィンドウを表示します。"
    case .underCursor: return "マウス位置を含むウィンドウを表示します。重なっている背後のウィンドウも対象です。"
    case .appUnderCursor: return "マウス位置にある最前面のウィンドウのアプリについて、そのアプリの各ウィンドウを表示します。"
    } }
}
public enum SwitcherSpaces: String, SwitcherChoice {
    case all, visible, other
    public var title: String { switch self { case .all: return "すべてのSpaces"; case .visible: return "表示中のSpaces"; case .other: return "表示されていないSpaces" } }
}
public enum SwitcherScreens: String, SwitcherChoice {
    case all, switcher
    public var title: String { self == .all ? "すべてのディスプレイ" : "切替画面と同じディスプレイ" }
}
public enum SwitcherVisibility: String, SwitcherChoice {
    case show, hide, last
    public var title: String { switch self { case .show: return "表示"; case .hide: return "非表示"; case .last: return "末尾に表示" } }
}
public enum SwitcherOrder: String, SwitcherChoice {
    case recent, created, alphabetical, space
    public var title: String { switch self { case .recent: return "最近使った順"; case .created: return "最近作成した順"; case .alphabetical: return "名前順"; case .space: return "Space順" } }
}
public enum SwitcherStyle: String, SwitcherChoice {
    case thumbnails, icons
    public var title: String { self == .thumbnails ? "サムネイル" : "アプリアイコン" }
}
public enum SwitcherTitlePosition: String, SwitcherChoice {
    case top, bottom
    public var title: String { self == .top ? "上" : "下" }
}
public enum SwitcherTheme: String, SwitcherChoice {
    case system, light, dark
    public var title: String { switch self { case .system: return "システムに合わせる"; case .light: return "ライト"; case .dark: return "ダーク" } }
}
public enum SwitcherRelease: String, SwitcherChoice {
    case focus, hold
    public var title: String { self == .focus ? "選択したウィンドウに切替" : "一覧を表示したままにする" }
}
public enum SwitcherCommand: String, CaseIterable, Identifiable {
    case summon, next, previous, confirm, cancel, closeWindow, quitApp
    public var id: String { rawValue }
    public var title: String { switch self {
    case .summon: return "切替画面を開く"; case .next: return "次のウィンドウ"; case .previous: return "前のウィンドウ"
    case .confirm: return "決定"; case .cancel: return "キャンセル"
    case .closeWindow: return "ウィンドウを閉じる"; case .quitApp: return "アプリを終了"
    } }
}

public enum SwitcherAction {
    case next, previous, up, down, confirm, cancel, closeWindow, quitApp

    init(_ command: SwitcherCommand) {
        switch command {
        case .summon, .next: self = .next
        case .previous: self = .previous
        case .confirm: self = .confirm
        case .cancel: self = .cancel
        case .closeWindow: self = .closeWindow
        case .quitApp: self = .quitApp
        }
    }
}

public struct SwitcherExcludedApp: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct SwitcherSettings: Codable, Equatable {
    public var enabled = true
    public var apps: SwitcherApps = .all
    public var excludedApps: [SwitcherExcludedApp] = []
    public var spaces: SwitcherSpaces = .all
    public var screens: SwitcherScreens = .all
    public var minimized: SwitcherVisibility = .show
    public var hidden: SwitcherVisibility = .show
    public var fullscreen = true
    public var windowless: SwitcherVisibility = .last
    public var order: SwitcherOrder = .recent
    public var onePerApp = false
    public var separateTabs = false
    public var style: SwitcherStyle = .thumbnails
    public var titlePosition: SwitcherTitlePosition = .bottom
    public var theme: SwitcherTheme = .system
    public static let windowScaleRange = 0.7...1.5
    public var windowScale = 1.0
    public var effectiveWindowScale: Double {
        windowScale.isFinite ? min(Self.windowScaleRange.upperBound, max(Self.windowScaleRange.lowerBound, windowScale)) : 1
    }
    public var release: SwitcherRelease = .focus
    public var summon = Shortcut(keyCode: 48, modifiers: 256, label: "⌘⇥")
    public var next = Shortcut(keyCode: 48, modifiers: 0, label: "⇥")
    public var previous = Shortcut(keyCode: 48, modifiers: 512, label: "⇧⇥")
    public var confirm = Shortcut(keyCode: 36, modifiers: 0, label: "↩")
    public var cancel = Shortcut(keyCode: 53, modifiers: 0, label: "Esc")
    public var closeWindow = Shortcut(keyCode: 13, modifiers: 256, label: "⌘W")
    public var quitApp = Shortcut(keyCode: 12, modifiers: 256, label: "⌘Q")
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case enabled, apps, spaces, screens, minimized, hidden, fullscreen, windowless, order, onePerApp, separateTabs
        case style, titlePosition, theme, windowScale, release, summon, next, previous, confirm, cancel, closeWindow, quitApp, excludedApps
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        apps = try values.decode(SwitcherApps.self, forKey: .apps)
        excludedApps = try values.decodeIfPresent([SwitcherExcludedApp].self, forKey: .excludedApps) ?? []
        spaces = try values.decode(SwitcherSpaces.self, forKey: .spaces)
        screens = try values.decode(SwitcherScreens.self, forKey: .screens)
        minimized = try values.decode(SwitcherVisibility.self, forKey: .minimized)
        hidden = try values.decode(SwitcherVisibility.self, forKey: .hidden)
        fullscreen = try values.decode(Bool.self, forKey: .fullscreen)
        windowless = try values.decode(SwitcherVisibility.self, forKey: .windowless)
        order = try values.decode(SwitcherOrder.self, forKey: .order)
        onePerApp = try values.decode(Bool.self, forKey: .onePerApp)
        separateTabs = try values.decode(Bool.self, forKey: .separateTabs)
        style = try values.decode(SwitcherStyle.self, forKey: .style)
        titlePosition = try values.decodeIfPresent(SwitcherTitlePosition.self, forKey: .titlePosition) ?? .bottom
        theme = try values.decode(SwitcherTheme.self, forKey: .theme)
        windowScale = try values.decodeIfPresent(Double.self, forKey: .windowScale) ?? 1
        windowScale = effectiveWindowScale
        release = try values.decode(SwitcherRelease.self, forKey: .release)
        summon = try values.decode(Shortcut.self, forKey: .summon)
        next = try values.decode(Shortcut.self, forKey: .next)
        previous = try values.decode(Shortcut.self, forKey: .previous)
        confirm = try values.decode(Shortcut.self, forKey: .confirm)
        cancel = try values.decode(Shortcut.self, forKey: .cancel)
        closeWindow = try values.decodeIfPresent(Shortcut.self, forKey: .closeWindow) ?? closeWindow
        quitApp = try values.decodeIfPresent(Shortcut.self, forKey: .quitApp) ?? quitApp
    }
    public subscript(_ command: SwitcherCommand) -> Shortcut {
        get { switch command { case .summon: return summon; case .next: return next; case .previous: return previous; case .confirm: return confirm; case .cancel: return cancel; case .closeWindow: return closeWindow; case .quitApp: return quitApp } }
        set { switch command { case .summon: summon = newValue; case .next: next = newValue; case .previous: previous = newValue; case .confirm: confirm = newValue; case .cancel: cancel = newValue; case .closeWindow: closeWindow = newValue; case .quitApp: quitApp = newValue } }
    }
    /// Local commands are matched with the held summon modifiers removed, so Command+Tab
    /// continues a session whose local next key is Tab. Compare effective chords, not labels.
    public func conflict(for shortcut: Shortcut, command: SwitcherCommand) -> SwitcherCommand? {
        let hold = command == .summon ? shortcut.modifiers : summon.modifiers
        func normalized(_ key: Shortcut) -> Shortcut { Shortcut(keyCode: key.keyCode, modifiers: key.modifiers & ~hold, label: key.label) }
        var candidate = self; candidate[command] = shortcut
        let locals = SwitcherCommand.allCases.filter { $0 != .summon }
        for (index, a) in locals.enumerated() {
            for b in locals.dropFirst(index + 1) where normalized(candidate[a]).conflicts(with: normalized(candidate[b])) {
                return command == a ? b : a
            }
        }
        // The summon chord always means next while the switcher is open.
        for local in locals where local != .next && normalized(candidate[local]).conflicts(with: normalized(candidate.summon)) {
            return local
        }
        return nil
    }
}

public struct SwitcherWindow: Identifiable, Equatable {
    public var id: String
    public var appID: String
    public var appName: String
    public var title: String
    public var frame: CGRect
    public var screenID: String
    public var spaces: Set<UInt64>
    public var spaceIndex: Int
    public var minimized: Bool
    public var hidden: Bool
    public var fullscreen: Bool
    public var windowless: Bool
    public var tabGroup: String?
    public var focused: UInt64
    public var created: UInt64
    public init(id: String, appID: String = "app", appName: String = "App", title: String = "", frame: CGRect = .zero,
                screenID: String = "", spaces: Set<UInt64> = [], spaceIndex: Int = 0, minimized: Bool = false,
                hidden: Bool = false, fullscreen: Bool = false, windowless: Bool = false, tabGroup: String? = nil,
                focused: UInt64 = 0, created: UInt64 = 0) {
        self.id = id; self.appID = appID; self.appName = appName; self.title = title; self.frame = frame
        self.screenID = screenID; self.spaces = spaces; self.spaceIndex = spaceIndex; self.minimized = minimized
        self.hidden = hidden; self.fullscreen = fullscreen; self.windowless = windowless; self.tabGroup = tabGroup
        self.focused = focused; self.created = created
    }
}
public struct SwitcherContext {
    public var activeApp: String?
    public var activeWindow: String?
    public var cursorApp: String?
    public var cursorWindows: Set<String>
    public var visibleSpaces: Set<UInt64>
    public var screenID: String
    public init(activeApp: String? = nil, activeWindow: String? = nil, cursorApp: String? = nil,
                cursorWindows: Set<String> = [], visibleSpaces: Set<UInt64> = [], screenID: String = "") {
        self.activeApp = activeApp; self.activeWindow = activeWindow; self.cursorApp = cursorApp
        self.cursorWindows = cursorWindows; self.visibleSpaces = visibleSpaces; self.screenID = screenID
    }
}
public enum SwitcherList {
    public static func windows(_ windows: [SwitcherWindow], settings: SwitcherSettings, context: SwitcherContext) -> [SwitcherWindow] {
        let excludedAppIDs = Set(settings.excludedApps.map(\.id))
        let filtered = windows.filter { w in
            if excludedAppIDs.contains(w.appID) { return false }
            switch settings.apps {
            case .all: break
            case .active: if w.appID != context.activeApp { return false }
            case .other: if w.appID == context.activeApp { return false }
            case .underCursor: if !context.cursorWindows.contains(w.id) { return false }
            case .appUnderCursor: if w.appID != context.cursorApp { return false }
            }
            if w.hidden && settings.hidden == .hide { return false }
            // AltTab treats windowless apps independently of Space, display and
            // window state: they have no window to which those filters can apply.
            if w.windowless { return settings.windowless != .hide && settings.apps != .underCursor }
            if settings.spaces != .all {
                let visible = !w.spaces.isDisjoint(with: context.visibleSpaces)
                if settings.spaces == .visible ? !visible : visible { return false }
            }
            if settings.screens == .switcher && w.screenID != context.screenID { return false }
            return !(w.minimized && settings.minimized == .hide) && !(!settings.fullscreen && w.fullscreen)
        }
        // Choose the most recently focused tab/app representative independently of display order.
        let representatives = filtered.sorted { $0.focused == $1.focused ? $0.id < $1.id : $0.focused > $1.focused }
        var appIDs = Set<String>(), tabIDs = Set<String>()
        let admitted = representatives.filter { w in
            if settings.onePerApp && !appIDs.insert(w.appID).inserted { return false }
            if !settings.separateTabs, let group = w.tabGroup, !tabIDs.insert(group).inserted { return false }
            return true
        }
        return admitted.sorted { a, b in
            // AltTab orders these buckets separately, with windowless apps last,
            // then hidden apps, then minimized windows, before the chosen sort.
            if settings.windowless == .last && a.windowless != b.windowless { return !a.windowless }
            if settings.hidden == .last && a.hidden != b.hidden { return !a.hidden }
            if settings.minimized == .last && a.minimized != b.minimized { return !a.minimized }
            switch settings.order {
            case .recent: if a.focused != b.focused { return a.focused > b.focused }
            case .created: if a.created != b.created { return a.created > b.created }
            case .alphabetical:
                let order = (a.appName + " " + a.title).localizedStandardCompare(b.appName + " " + b.title)
                if order != .orderedSame { return order == .orderedAscending }
            case .space:
                let ai = a.spaceIndex == 0 ? Int.max : a.spaceIndex, bi = b.spaceIndex == 0 ? Int.max : b.spaceIndex
                if ai != bi { return ai < bi }
                if a.focused != b.focused { return a.focused > b.focused }
            }
            return a.id < b.id
        }
    }
}

public struct SwitcherSelection {
    public private(set) var ids: [String] = []
    public private(set) var selected: String?
    public init() {}
    public mutating func open(ids: [String], current: String?, backwards: Bool) {
        self.ids = ids
        guard !ids.isEmpty else { selected = nil; return }
        if let current, let index = ids.firstIndex(of: current) {
            selected = ids[(index + (backwards ? ids.count - 1 : 1)) % ids.count]
        } else { selected = backwards ? ids.last : ids.first }
    }
    public mutating func move(_ delta: Int) {
        guard !ids.isEmpty else { selected = nil; return }
        let index = selected.flatMap { ids.firstIndex(of: $0) } ?? 0
        selected = ids[((index + delta) % ids.count + ids.count) % ids.count]
    }
    /// Move to the same column in the next/previous row, wrapping at the grid edges.
    /// A short final row uses its last available tile when that column is missing.
    public mutating func moveVertically(_ delta: Int, columns: Int) {
        guard !ids.isEmpty, columns > 0 else { return }
        let index = selected.flatMap { ids.firstIndex(of: $0) } ?? 0
        let rows = (ids.count + columns - 1) / columns
        let row = ((index / columns + delta) % rows + rows) % rows
        selected = ids[min(row * columns + index % columns, ids.count - 1)]
    }
    public mutating func select(_ id: String) { if ids.contains(id) { selected = id } }
    public mutating func reconcile(ids: [String]) {
        let oldIndex = selected.flatMap { self.ids.firstIndex(of: $0) } ?? 0
        self.ids = ids
        if let selected, ids.contains(selected) { return }
        selected = ids.isEmpty ? nil : ids[min(oldIndex, ids.count - 1)]
    }
}

public enum SwitcherKeyRouting {
    public static func command(key: Shortcut, settings: SwitcherSettings, heldModifiers: UInt32) -> SwitcherAction? {
        let modifiers = key.modifiers & ~heldModifiers
        let triggerModifiers = settings.summon.modifiers & ~heldModifiers
        if key.keyCode == settings.summon.keyCode && modifiers == triggerModifiers { return .next }
        if key.keyCode == settings.summon.keyCode && triggerModifiers & 512 == 0 && modifiers == triggerModifiers | 512 { return .previous }
        if let command = [SwitcherCommand.cancel, .confirm, .previous, .next, .closeWindow, .quitApp].first(where: {
            let command = settings[$0]
            // Closing/quitting still requires the configured modifiers to be physically held.
            if ($0 == .closeWindow || $0 == .quitApp), key.modifiers & command.modifiers != command.modifiers { return false }
            return command.keyCode == key.keyCode && command.modifiers & ~heldModifiers == modifiers
        }) { return SwitcherAction(command) }
        // Arrow navigation supplements configured shortcuts while the switcher is open.
        guard modifiers == 0 else { return nil }
        switch key.keyCode {
        case 123: return .previous
        case 124: return .next
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }
}
