import CoreGraphics
import Foundation
import Testing
@testable import WindowArrange

struct SwitcherWindowDiscoveryTests {
    @Test func accessoryAppWithoutAXWindowsExcludesNamedBackingSurface() {
        var cached: [UInt32: String] = [:]
        let candidates = SwitcherWindowDiscovery.candidates(current: [:], cached: &cached,
            server: [window(179, title: "Claude", width: 800, height: 612)],
            isValid: { _, _ in true }, hasSpace: { _ in true }, allowsServerOnlyWindows: false)
        #expect(candidates.isEmpty)
    }

    @Test func accessoryAppKeepsRealSettingsWindowsAndDialogs() {
        var cached: [UInt32: String] = [:]
        let candidates = SwitcherWindowDiscovery.candidates(current: [85: "settings", 86: "dialog"], cached: &cached,
            server: [window(85, title: "Settings"), window(86, title: "Dialog", layer: 3)],
            isValid: { _, _ in true }, hasSpace: { _ in false }, allowsServerOnlyWindows: false)
        #expect(candidates == [85, 86])
    }

    @Test func accessoryAppKeepsValidatedWindowOnAnotherSpace() {
        var cached: [UInt32: String] = [85: "settings"]
        let candidates = SwitcherWindowDiscovery.candidates(current: [:], cached: &cached,
            server: [window(85, title: "Settings")], isValid: { _, _ in true },
            hasSpace: { _ in true }, allowsServerOnlyWindows: false)
        #expect(candidates == [85])
        #expect(cached[85] == "settings")
    }

    @Test func accessoryAppDoesNotRediscoverSurfaceAfterAXReferenceBecomesInvalid() {
        var cached: [UInt32: String] = [179: "dead popover"]
        let candidates = SwitcherWindowDiscovery.candidates(current: [179: "dead popover"], cached: &cached,
            server: [window(179, title: "Claude")], isValid: { _, _ in false },
            hasSpace: { _ in true }, allowsServerOnlyWindows: false)
        #expect(candidates.isEmpty)
        #expect(cached.isEmpty)
    }

    @Test func requestedCloseRemovesRetainedNamedSurfaceAndValidCachedReference() {
        var cached: [UInt32: String] = [85: "retained closed window"]
        let candidates = SwitcherWindowDiscovery.candidates(current: [:], cached: &cached,
            server: [window(85, title: "closed document")], isValid: { _, _ in true },
            hasSpace: { _ in false }, requestedClosures: [85])
        #expect(candidates.isEmpty)
        #expect(cached.isEmpty)
    }
    @Test(arguments: [true, false]) func requestedCloseKeepsWindowWhenAppIsConfirmingOrCloseIsCancelled(exposed: Bool) {
        var cached: [UInt32: String] = [85: "document"]
        let candidates = SwitcherWindowDiscovery.candidates(current: exposed ? [85: "document"] : [:], cached: &cached,
            server: [window(85, title: "document")], isValid: { _, _ in true },
            hasSpace: { _ in !exposed }, requestedClosures: [85])
        #expect(candidates == [85])
    }
    private func window(_ id: UInt32, title: String = "", layer: Int = 0,
                        width: CGFloat = 1720, height: CGFloat = 1410) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id), kCGWindowName as String: title,
         kCGWindowLayer as String: NSNumber(value: layer),
         kCGWindowBounds as String: CGRect(x: 0, y: 0, width: width, height: height).dictionaryRepresentation]
    }

    @Test func deadCachedPopupIsRemovedWhileItsServerSurfaceStillExists() {
        var cached: [UInt32: String] = [250: "dead AX reference", 85: "editor"]
        let candidates = SwitcherWindowDiscovery.candidates(current: [85: "editor"], cached: &cached,
            server: [window(250, layer: 3, width: 84, height: 77), window(85, title: "project")],
            isValid: { _, reference in reference == "editor" }, hasSpace: { _ in true })
        #expect(candidates == [85])
        #expect(cached == [85: "editor"])
    }

    @Test func windowOmittedFromAXOnAnotherSpaceKeepsItsValidReference() {
        var cached: [UInt32: String] = [85: "editor"]
        let candidates = SwitcherWindowDiscovery.candidates(current: [:], cached: &cached,
            server: [window(85)], isValid: { _, _ in true }, hasSpace: { _ in true })
        #expect(candidates == [85])
        #expect(cached[85] == "editor")
    }

    @Test func cachedPanelOmittedFromAXDoesNotReturnEvenIfItsReferenceStillResponds() {
        var cached: [UInt32: String] = [250: "old popup"]
        let candidates = SwitcherWindowDiscovery.candidates(current: [:], cached: &cached,
            server: [window(250, layer: 3, width: 84, height: 77)],
            isValid: { _, _ in true }, hasSpace: { _ in false })
        #expect(candidates.isEmpty)
        #expect(cached.isEmpty)
    }

    @Test func ordinaryWindowRemainsDiscoverableAfterItsAXReferenceBecomesInvalid() {
        var cached: [UInt32: String] = [85: "dead AX reference"]
        let candidates = SwitcherWindowDiscovery.candidates(current: [:], cached: &cached,
            server: [window(85)], isValid: { _, _ in false }, hasSpace: { _ in true })
        #expect(candidates == [85])
        #expect(cached.isEmpty)
    }

    @Test func closedWindowIsEvictedFromCache() {
        var cached: [UInt32: String] = [85: "editor"]
        let candidates = SwitcherWindowDiscovery.candidates(current: [:], cached: &cached,
            server: [], isValid: { _, _ in true }, hasSpace: { _ in true })
        #expect(candidates.isEmpty)
        #expect(cached.isEmpty)
    }

    @Test func freshAXDialogCanBeUntitledSmallAndAbsentFromServerInventory() {
        var cached: [UInt32: String] = [:]
        let candidates = SwitcherWindowDiscovery.candidates(current: [86: "dialog"], cached: &cached,
            server: [], isValid: { _, _ in true }, hasSpace: { _ in false })
        #expect(candidates == [86])
        #expect(cached[86] == "dialog")
    }

    @Test func currentlyExposedAXDialogRemainsOnAPanelLayer() {
        var cached: [UInt32: String] = [86: "old dialog"]
        let candidates = SwitcherWindowDiscovery.candidates(current: [86: "dialog"], cached: &cached,
            server: [window(86, layer: 3, width: 84, height: 77)],
            isValid: { _, _ in true }, hasSpace: { _ in false })
        #expect(candidates == [86])
        #expect(cached[86] == "dialog")
    }

    @Test func invalidCurrentReferenceDoesNotBypassInternalSurfaceFiltering() {
        var cached: [UInt32: String] = [:]
        let candidates = SwitcherWindowDiscovery.candidates(current: [250: "internal element"], cached: &cached,
            server: [window(250, layer: 3, width: 84, height: 77), window(3821, width: 3440, height: 30)],
            isValid: { _, _ in false }, hasSpace: { _ in true })
        #expect(candidates.isEmpty)
        #expect(cached.isEmpty)
    }

    @Test func chromeAddressBarPopupIsExcludedOnVisibleSpace() {
        var cached: [UInt32: String] = [:]
        let candidates = SwitcherWindowDiscovery.candidates(current: [63: "browser"], cached: &cached,
            server: [window(63, title: "window-name"), window(65, width: 744, height: 89)],
            isValid: { _, _ in true }, hasSpace: { _ in true }, isOnVisibleSpace: { _ in true })
        #expect(candidates == [63])
    }

    @Test func untitledServerWindowOnAnotherSpaceRemainsDiscoverable() {
        var cached: [UInt32: String] = [:]
        let candidates = SwitcherWindowDiscovery.candidates(current: [:], cached: &cached,
            server: [window(85)], isValid: { _, _ in false }, hasSpace: { _ in true },
            isOnVisibleSpace: { _ in false })
        #expect(candidates == [85])
    }

    @Test func visibleUntitledAXWindowsAndDialogsArePreserved() {
        var cached: [UInt32: String] = [85: "minimized window"]
        let candidates = SwitcherWindowDiscovery.candidates(current: [86: "dialog"], cached: &cached,
            server: [window(85), window(86, width: 744, height: 89)],
            isValid: { _, _ in true }, hasSpace: { _ in true }, isOnVisibleSpace: { _ in true })
        #expect(candidates == [85, 86])
    }

    @Test func failedAXQueryDoesNotDiscardUntitledServerWindows() {
        var cached: [UInt32: String] = [:]
        let candidates = SwitcherWindowDiscovery.candidates(current: [:], cached: &cached,
            server: [window(85)], isValid: { _, _ in false }, hasSpace: { _ in true })
        #expect(candidates == [85])
    }

    @Test func namedServerWindowOnVisibleSpaceRemainsDiscoverable() {
        var cached: [UInt32: String] = [:]
        let candidates = SwitcherWindowDiscovery.candidates(current: [:], cached: &cached,
            server: [window(85, title: "document")], isValid: { _, _ in false }, hasSpace: { _ in true },
            isOnVisibleSpace: { _ in true })
        #expect(candidates == [85])
    }
}
