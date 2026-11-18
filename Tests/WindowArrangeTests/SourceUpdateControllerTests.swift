import Foundation
import Testing
@testable import WindowArrange

struct SourceUpdateControllerTests {
    private let root = URL(fileURLWithPath: "/tmp/window-arrange", isDirectory: true)

    @Test func onlyFingerprintedPathsTriggerChecks() {
        for path in ["Sources/WindowArrange/App.swift", "Resources/Info.plist", "scripts/build.ts", "Package.swift", "package.json"] {
            #expect(SourceUpdateController.isRelevant("/tmp/window-arrange/\(path)", root: root))
        }
        for path in [".build/debug/App.o", "dist/Window Arrange.app/Contents/Info.plist", ".local/update.log",
                     ".git/index", "Tests/WindowArrangeTests/A.swift", "README.md"] {
            #expect(!SourceUpdateController.isRelevant("/tmp/window-arrange/\(path)", root: root))
        }
        #expect(!SourceUpdateController.isRelevant("/tmp/window-arrange-other/Sources/A.swift", root: root))
    }

    @Test func requiresStampedBundleOutsideDevelopmentMode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        FileManager.default.createFile(atPath: directory.appendingPathComponent("scripts/update.ts").path, contents: Data())
        let info: [String: Any] = ["WindowArrangeSourceRoot": directory.path, "WindowArrangeBunPath": "/bin/sh",
                                   "WindowArrangeSourceFingerprint": "abc", "WindowArrangeBuildConfiguration": "release"]
        let bundle = URL(fileURLWithPath: "/Applications/Window Arrange.app")
        let configuration = try #require(SourceUpdateController.configuration(info: info, bundle: bundle, arguments: ["app"]))
        #expect(configuration.buildConfiguration == "release" && configuration.fingerprint == "abc")
        #expect(SourceUpdateController.configuration(info: info, bundle: bundle, arguments: ["app", "--development"]) == nil)
        #expect(SourceUpdateController.configuration(info: info, bundle: URL(fileURLWithPath: "/tmp/WindowArrange"), arguments: ["app"]) == nil)
        #expect(SourceUpdateController.configuration(info: [:], bundle: bundle, arguments: ["app"]) == nil)
        var missingBun = info
        missingBun["WindowArrangeBunPath"] = "/nonexistent/bun"
        #expect(SourceUpdateController.configuration(info: missingBun, bundle: bundle, arguments: ["app"]) == nil)
    }

    @MainActor @Test func statusMenuOffersUpdateOnlyWhenSourcesChanged() {
        var state = StatusMenuState(update: .upToDate)
        let controller = StatusMenuController(installStatusItem: false, state: { state }, perform: { _ in }, trackingChanged: { _ in })
        controller.menuNeedsUpdate(controller.menu)
        #expect(controller.menu.items.first?.title == "Window Arrangeを開く")
        state.update = .available
        controller.menuNeedsUpdate(controller.menu)
        #expect((controller.menu.items.first as? StatusActionMenuItem)?.menuAction == .update)
        state.update = .updating
        controller.menuNeedsUpdate(controller.menu)
        #expect(controller.menu.items.first?.isEnabled == false)
    }
}
