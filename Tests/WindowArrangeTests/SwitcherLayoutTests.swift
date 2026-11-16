import Testing
import CoreGraphics
import ArrangementCore
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
        for shape in SwitcherShape.allCases {
            for style in SwitcherStyle.allCases {
                for count in [0, 1, 2, 4, 20] {
                    let layout = SwitcherLayout(windowCount: count, maximumWidth: maximumWidth, requestedScale: 1.5,
                                                shape: shape, style: style)
                    #expect(layout.width <= maximumWidth + 0.001)
                    #expect(layout.scale > 0)
                    #expect(layout.columns >= 1)
                }
            }
        }
    }
    @Test func standardSizePreservesExistingFourColumnWidth() {
        #expect(SwitcherLayout(windowCount: 4, maximumWidth: 1800).width == 1000)
    }
}

struct SwitcherGroupedLayoutTests {
    @Test func groupedLayoutPlacesGroupsSideBySideWithinTheDisplay() {
        let wide = SwitcherLayout(windowCount: 5, maximumWidth: 4000, groupColumns: [2, 3])
        #expect(wide.width == wide.contentWidth + 2 * (wide.outerPadding + wide.borderPadding + wide.gridPadding))
        #expect(wide.contentWidth == wide.groupWidth(columns: 2) + wide.groupWidth(columns: 3) + wide.groupSpacing)
        for shape in SwitcherShape.allCases {
            let narrow = SwitcherLayout(windowCount: 20, maximumWidth: 900, requestedScale: 1.5, shape: shape, groupColumns: [3, 3, 3, 1])
            #expect(narrow.width <= 900)
            #expect(narrow.groupWidth(columns: 3) + 2 * (narrow.horizontalPadding + narrow.borderPadding + narrow.gridPadding) <= 900 + 0.001)
        }
    }
    @Test func groupColumnsAreCappedAtThree() {
        #expect([0, 1, 2, 3, 7].map(SwitcherLayout.groupColumnCount(for:)) == [1, 1, 2, 3, 3])
    }
}
