import Testing
import CoreGraphics
@testable import WindowArrange

struct SwitcherLayoutTests {
    @Test(arguments: [1, 4, 20]) func sizeChangesWidthAndPreviewHeight(windowCount: Int) {
        let small = SwitcherLayout(windowCount: windowCount, maximumWidth: 1800, requestedScale: 0.7)
        let standard = SwitcherLayout(windowCount: windowCount, maximumWidth: 1800)
        let large = SwitcherLayout(windowCount: windowCount, maximumWidth: 1800, requestedScale: 1.5)
        #expect(small.width < standard.width)
        #expect(standard.width < large.width)
        #expect(small.scale < standard.scale)
        #expect(standard.scale < large.scale)
    }
    @Test(arguments: [CGFloat(600), 960, 1400]) func enlargedSwitcherFitsDisplay(maximumWidth: CGFloat) {
        for count in [0, 1, 2, 4, 20] {
            let layout = SwitcherLayout(windowCount: count, maximumWidth: maximumWidth, requestedScale: 1.5)
            #expect(layout.width <= maximumWidth + 0.001)
            #expect(layout.scale > 0)
            #expect(layout.columns >= 1)
        }
    }
    @Test func standardSizePreservesExistingFourColumnWidth() {
        #expect(SwitcherLayout(windowCount: 4, maximumWidth: 1800).width == 1000)
    }
}
