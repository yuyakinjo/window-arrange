import ApplicationServices
import CoreGraphics
import Testing
@testable import WindowArrange

struct SwitcherWindowEligibilityTests {
    private func includes(title: String = "Document", role: String? = kAXWindowRole,
                          subrole: String? = kAXStandardWindowSubrole, level: Int = 0,
                          main: Bool = false, fullscreen: Bool = false, focused: Bool = false,
                          width: CGFloat = 800, height: CGFloat = 600) -> Bool {
        SwitcherWindowEligibility.includes(frame: CGRect(x: 0, y: 0, width: width, height: height),
            level: level, title: title, role: role, subrole: subrole,
            main: main, fullscreen: fullscreen, focused: focused)
    }

    @Test(arguments: ["", " \t\n", "Document"])
    func ordinaryWindowsDoNotNeedTitlesOrLargeFrames(_ title: String) {
        #expect(includes(title: title, width: 40, height: 30))
    }

    @Test func untitledDialogsNeedMainOrFocusedEvidence() {
        #expect(!includes(title: "", subrole: kAXDialogSubrole))
        #expect(includes(title: "Save", subrole: kAXDialogSubrole))
        #expect(includes(title: "", subrole: kAXDialogSubrole, main: true))
        #expect(includes(title: "", subrole: kAXDialogSubrole, focused: true))
    }

    @Test(arguments: [kAXFloatingWindowSubrole, "AXSystemDialog"])
    func auxiliaryWindowsStayExcludedEvenIfMainFocusedOrFullscreen(_ subrole: String) {
        #expect(!includes(subrole: subrole, main: true, fullscreen: true, focused: true))
    }

    @Test(arguments: [kAXStandardWindowSubrole, kAXDialogSubrole, "AXUnknown"])
    func floatingOverlaysNeedMainOrFullscreenEvidence(_ subrole: String) {
        // ChatGPT's dictation strip and sidebar use otherwise ordinary subroles.
        #expect(!includes(subrole: subrole, level: 3, focused: true, width: 720, height: 84))
        #expect(includes(subrole: subrole, level: 3, main: true))
        #expect(includes(subrole: subrole, level: 3, fullscreen: true))
    }

    @Test func desktopSurfacesCannotBecomeDestinations() {
        #expect(!includes(level: -1, main: true, fullscreen: true, focused: true))
    }

    @Test func customToolkitsNeedATitledSubstantialWindowRoot() {
        #expect(includes(subrole: "AXUnknown", width: 100, height: 50))
        #expect(includes(subrole: nil, width: 100, height: 50))
        #expect(!includes(subrole: "AXUnknown", width: 99, height: 50))
        #expect(!includes(subrole: "AXUnknown", width: 100, height: 49))
        #expect(!includes(title: "", subrole: "AXUnknown"))
        #expect(!includes(role: "AXGroup", subrole: "AXUnknown"))
    }

    @Test func focusFillsMissingSemanticsWithoutAdmittingNonWindowElements() {
        #expect(includes(title: "", role: nil, subrole: nil, focused: true))
        #expect(includes(title: "", subrole: "AXUnknown", focused: true))
        #expect(!includes(role: "AXGroup", subrole: "AXUnknown", focused: true))
        // Emacs reports a text-field role with the standard-window subrole.
        #expect(includes(role: "AXTextField", focused: true))
    }
}
