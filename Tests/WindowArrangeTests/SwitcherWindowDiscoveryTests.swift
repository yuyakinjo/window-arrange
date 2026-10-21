import CoreGraphics
import Foundation
import Testing
@testable import WindowArrange

struct SwitcherWindowDiscoveryTests {
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
}
