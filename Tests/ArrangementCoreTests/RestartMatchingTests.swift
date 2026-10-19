import Testing
import Foundation
import CoreGraphics
@testable import ArrangementCore

struct RestartMatchingTests {
    private func window(_ title: String, document: String? = nil, app: String = "com.microsoft.VSCode", nativeID: UInt32? = nil, session: String = "") -> WindowRecord {
        WindowRecord(appID: app, appName: "Code", title: title, session: session, nativeID: nativeID,
                     documentURL: document, frame: CGRect(x: 0, y: 0, width: 700, height: 500), displayID: "display")
    }
    @Test func legacyTwoProjectSnapshotMatchesAfterMacRestartAndWelcomeAppears() {
        let saved = [window("README.md — window-arrange — Work (Offline)", nativeID: 489, session: "old-boot"),
                     window("sample-project — Work (Offline)", nativeID: 48, session: "old-boot")]
        let live = [window("Welcome — sample-project — Work (Offline)", nativeID: 489, session: "new-boot"),
                    window("README.md — window-arrange — Work (Offline)", nativeID: 48, session: "new-boot")]
        let matches = WindowMatcher.match(saved: saved, live: live)
        #expect(matches.count == 2)
        #expect(matches[saved[0].id] == live[1].id)
        #expect(matches[saved[1].id] == live[0].id)
    }
    @Test func bothEditorsChangeWhileWorkspaceAndProfileStayTheSame() {
        let saved = [window("one.swift — alpha — Work"), window("two.swift — beta — Work")]
        let live = [window("Welcome — beta — Work"), window("three.swift — alpha — Work")]
        let matches = WindowMatcher.match(saved: saved, live: live)
        #expect(matches[saved[0].id] == live[1].id)
        #expect(matches[saved[1].id] == live[0].id)
    }
    @Test func defaultProfileWithoutTrailingProfileMatchesChangedEditors() {
        let saved = [window("one.swift — alpha"), window("two.swift — beta")]
        let live = [window("three.swift — beta"), window("four.swift — alpha")]
        let matches = WindowMatcher.match(saved: saved, live: live)
        #expect(matches[saved[0].id] == live[1].id)
        #expect(matches[saved[1].id] == live[0].id)
    }
    @Test func noEditorAndDefaultProfileMatchesWelcomeAfterRestart() {
        let saved = [window("alpha"), window("beta")]
        let live = [window("Welcome — beta"), window("Welcome — alpha")]
        let matches = WindowMatcher.match(saved: saved, live: live)
        #expect(matches[saved[0].id] == live[1].id)
        #expect(matches[saved[1].id] == live[0].id)
    }
    @Test func sameWorkspaceInDifferentProfilesRemainsDistinct() {
        let saved = [window("one.swift — alpha — Work"), window("two.swift — alpha — Personal")]
        let live = [window("three.swift — alpha — Personal"), window("four.swift — alpha — Work")]
        let matches = WindowMatcher.match(saved: saved, live: live)
        #expect(matches[saved[0].id] == live[1].id)
        #expect(matches[saved[1].id] == live[0].id)
    }
    @Test func duplicateWorkspaceWindowsAreNotGuessedAfterOneTitleMatches() {
        let saved = [window("one.swift — alpha — Work"), window("two.swift — alpha — Work")]
        let live = [window("two.swift — alpha — Work"), window("three.swift — alpha — Work")]
        let matches = WindowMatcher.match(saved: saved, live: live)
        #expect(matches.count == 1)
        #expect(matches[saved[1].id] == live[0].id)
        #expect(matches[saved[0].id] == nil)
    }
    @Test func sharedProfileDoesNotMatchDifferentProjects() {
        let saved = [window("alpha — Work"), window("beta — Work")]
        let live = [window("one.swift — gamma — Work"), window("two.swift — delta — Work")]
        #expect(WindowMatcher.match(saved: saved, live: live).isEmpty)
    }
    @Test func uniqueProfileAloneDoesNotMatchDifferentProjectsWithNoEditor() {
        let saved = [window("alpha — Work"), window("beta — Home")]
        let live = [window("gamma — Work", document: ""), window("delta — Home", document: "")]
        #expect(WindowMatcher.match(saved: saved, live: live).isEmpty)
    }
    @Test func liveDocumentIdentifiesDefaultProfileWorkspaceAfterRestart() {
        let saved = [window("one.swift — alpha"), window("beta")]
        let live = [window("Welcome — beta", document: ""), window("two.swift — alpha", document: "file:///tmp/alpha/two.swift")]
        let matches = WindowMatcher.match(saved: saved, live: live)
        #expect(matches[saved[0].id] == live[1].id)
        #expect(matches[saved[1].id] == live[0].id)
    }
    @Test func ambiguousProjectKeysNeverDependOnEnumerationOrder() {
        let saved = [window("old1 — alpha — Work"), window("old2 — alpha — Work")]
        let live = [window("new1 — alpha — Work"), window("new2 — alpha — Work")]
        #expect(WindowMatcher.match(saved: saved, live: live).isEmpty)
        #expect(WindowMatcher.match(saved: saved.reversed(), live: live.reversed()).isEmpty)
    }
    @Test func genericAppsDoNotUseEditorTitleHeuristics() {
        let saved = [window("old — alpha — Work", app: "other"), window("old — beta — Work", app: "other")]
        let live = [window("new — alpha — Work", app: "other"), window("new — beta — Work", app: "other")]
        #expect(WindowMatcher.match(saved: saved, live: live).isEmpty)
    }
    @Test func uniqueDocumentURLSurvivesTitleChangesInGenericApps() {
        let saved = [window("old1", document: "file:///tmp/a%20b.swift", app: "other"), window("old2", document: "file:///tmp/c.swift", app: "other")]
        let live = [window("new2", document: "file:///tmp/c.swift", app: "other"), window("new1", document: "file:///tmp/a%20b.swift", app: "other")]
        let matches = WindowMatcher.match(saved: saved, live: live)
        #expect(matches[saved[0].id] == live[1].id)
        #expect(matches[saved[1].id] == live[0].id)
    }
    @Test func duplicateDocumentURLsAreNotGuessed() {
        let saved = [window("old1", document: "file:///tmp/a.swift", app: "other"), window("old2", document: "file:///tmp/a.swift", app: "other")]
        let live = [window("new1", document: "file:///tmp/a.swift", app: "other"), window("new2", document: "file:///tmp/a.swift", app: "other")]
        #expect(WindowMatcher.match(saved: saved, live: live).isEmpty)
    }
    @Test func insidersAndDirtyEditorTitlesUseWorkspaceIdentity() {
        let saved = [window("● one.swift — alpha — Work", app: "com.microsoft.VSCodeInsiders"),
                     window("two.swift — beta — Work", app: "com.microsoft.VSCodeInsiders")]
        let live = [window("Welcome — beta — Work", app: "com.microsoft.VSCodeInsiders"),
                    window("three.swift — alpha — Work", app: "com.microsoft.VSCodeInsiders")]
        let matches = WindowMatcher.match(saved: saved, live: live)
        #expect(matches[saved[0].id] == live[1].id)
        #expect(matches[saved[1].id] == live[0].id)
    }
    @Test func documentURLsWithEscapedCharactersAreCanonicalized() {
        let saved = [window("one", document: "file:///tmp/a%20b.swift", app: "other"), window("two", document: "file:///tmp/other.swift", app: "other")]
        let live = [window("three", document: "file:///tmp/sub/../a%20b.swift", app: "other"), window("four", document: "file:///tmp/other.swift", app: "other")]
        #expect(WindowMatcher.match(saved: saved, live: live)[saved[0].id] == live[0].id)
    }
}
