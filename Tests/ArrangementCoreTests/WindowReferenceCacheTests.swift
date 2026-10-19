import Testing
@testable import ArrangementCore

struct WindowReferenceCacheTests {
    let key = WindowReferenceKey(appID: "code", session: "679:launch-one", windowID: 82)
    @Test func windowOmittedFromAXListRemainsWhileWindowServerConfirmsItIsOpen() {
        var cache = WindowReferenceCache<String>()
        _ = cache.merge(visible: [key: "saved-AX-reference"], alive: [key])
        let restored = cache.merge(visible: [:], alive: [key])
        #expect(restored[key] == "saved-AX-reference")
    }
    @Test func closedWindowIsRemoved() {
        var cache = WindowReferenceCache<String>()
        _ = cache.merge(visible: [key: "reference"], alive: [key])
        #expect(cache.merge(visible: [:], alive: []).isEmpty)
    }
    @Test func applicationRestartCannotReuseOldReferenceForRecycledWindowID() {
        let restarted = WindowReferenceKey(appID: "code", session: "679:launch-two", windowID: 82)
        var cache = WindowReferenceCache<String>()
        _ = cache.merge(visible: [key: "old-reference"], alive: [key])
        #expect(cache.merge(visible: [:], alive: [restarted]).isEmpty)
        #expect(cache.merge(visible: [restarted: "new-reference"], alive: [restarted])[restarted] == "new-reference")
    }
    @Test func refreshedReferenceReplacesOldOneWithoutDuplicatingWindow() {
        var cache = WindowReferenceCache<String>()
        _ = cache.merge(visible: [key: "old-reference"], alive: [key])
        let result = cache.merge(visible: [key: "fresh-reference"], alive: [key])
        #expect(result.count == 1)
        #expect(result[key] == "fresh-reference")
    }
    @Test func referencesAreSeparatedByApplication() {
        let other = WindowReferenceKey(appID: "other", session: key.session, windowID: key.windowID)
        var cache = WindowReferenceCache<String>()
        _ = cache.merge(visible: [key: "code-reference"], alive: [key])
        #expect(cache.merge(visible: [:], alive: [other]).isEmpty)
    }
    @Test func explicitInvalidationPreventsReturningDeadAXReference() {
        var cache = WindowReferenceCache<String>()
        _ = cache.merge(visible: [key: "dead-reference"], alive: [key])
        cache.remove(key)
        #expect(cache.merge(visible: [:], alive: [key]).isEmpty)
    }
}
