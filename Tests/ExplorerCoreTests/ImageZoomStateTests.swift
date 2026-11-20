// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import XCTest
@testable import ExplorerCore

final class ImageZoomStateTests: XCTestCase {
    func testActualSizeUsesOriginalPixelsAndScreenDensity() {
        for backingScale: CGFloat in [1, 2] {
            var state = ImageZoomState(pixelSize: CGSize(width: 4000, height: 2000), backingScale: backingScale,
                                       viewportSize: CGSize(width: 800, height: 600))
            state.actualSize()
            XCTAssertEqual(state.mode, .manual)
            XCTAssertEqual(state.scaleFactor, 1)
            XCTAssertEqual(state.displayedSize, CGSize(width: 4000 / backingScale, height: 2000 / backingScale))
        }
    }

    func testFitRespectsAspectRatioAndViewportAtRetinaDensity() {
        let landscape = ImageZoomState(pixelSize: CGSize(width: 4000, height: 2000), backingScale: 2,
                                       viewportSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(landscape.mode, .fit)
        XCTAssertEqual(landscape.scaleFactor, 0.4, accuracy: 0.00001)
        XCTAssertEqual(landscape.displayedSize, CGSize(width: 800, height: 400))
        let portrait = ImageZoomState(pixelSize: CGSize(width: 2000, height: 4000), backingScale: 1,
                                      viewportSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(portrait.scaleFactor, 0.15, accuracy: 0.00001)
        XCTAssertEqual(portrait.displayedSize, CGSize(width: 300, height: 600))
    }

    func testFitEnlargesSmallImagesUpToMaximumScale() {
        let state = ImageZoomState(pixelSize: CGSize(width: 100, height: 50), backingScale: 2,
                                   viewportSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(state.scaleFactor, 8)
        XCTAssertEqual(state.displayedSize, CGSize(width: 400, height: 200))
        let moderate = ImageZoomState(pixelSize: CGSize(width: 200, height: 100), backingScale: 1,
                                      viewportSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(moderate.scaleFactor, 4)
        XCTAssertEqual(moderate.displayedSize, CGSize(width: 800, height: 400))
    }

    func testResizeUpdatesFitButPreservesManualScale() {
        var state = ImageZoomState(pixelSize: CGSize(width: 4000, height: 2000), backingScale: 2,
                                   viewportSize: CGSize(width: 800, height: 600))
        state.updateViewport(CGSize(width: 400, height: 300))
        XCTAssertEqual(state.scaleFactor, 0.2, accuracy: 0.00001)
        state.setZoom(1.25)
        state.updateViewport(CGSize(width: 1200, height: 900))
        XCTAssertEqual(state.mode, .manual)
        XCTAssertEqual(state.scaleFactor, 1.25)
        XCTAssertEqual(state.displayedSize, CGSize(width: 2500, height: 1250))
        state.fit()
        XCTAssertEqual(state.scaleFactor, 0.6, accuracy: 0.00001)
    }

    func testMovingBetweenScreensKeepsManualPixelScaleAndRefitsAutomaticMode() {
        var state = ImageZoomState(pixelSize: CGSize(width: 4000, height: 2000), backingScale: 1,
                                   viewportSize: CGSize(width: 800, height: 600))
        state.updateBackingScale(2)
        XCTAssertEqual(state.scaleFactor, 0.4, accuracy: 0.00001)
        XCTAssertEqual(state.displayedSize, CGSize(width: 800, height: 400))
        state.actualSize()
        state.updateBackingScale(1)
        XCTAssertEqual(state.scaleFactor, 1)
        XCTAssertEqual(state.mode, .manual)
        XCTAssertEqual(state.displayedSize, CGSize(width: 4000, height: 2000))
    }

    func testManualStepsAndLimits() {
        var state = ImageZoomState(pixelSize: CGSize(width: 100, height: 100), viewportSize: CGSize(width: 200, height: 200))
        state.actualSize()
        state.zoomIn()
        XCTAssertEqual(state.scaleFactor, 1.25)
        state.zoomOut()
        XCTAssertEqual(state.scaleFactor, 1)
        state.setZoom(100)
        XCTAssertEqual(state.scaleFactor, 8)
        state.zoomIn()
        XCTAssertEqual(state.scaleFactor, 8)
        state.setZoom(0.0001)
        XCTAssertEqual(state.scaleFactor, 0.01)
        state.zoomOut()
        XCTAssertEqual(state.scaleFactor, 0.01)
    }

    func testHugeImageCanFitBelowManualMinimum() {
        var state = ImageZoomState(pixelSize: CGSize(width: 1_000_000, height: 500_000), backingScale: 2,
                                   viewportSize: CGSize(width: 500, height: 400))
        XCTAssertEqual(state.scaleFactor, 0.001, accuracy: 0.000001)
        XCTAssertEqual(state.displayedSize, CGSize(width: 500, height: 250))
        state.zoomOut()
        XCTAssertEqual(state.scaleFactor, 0.001, accuracy: 0.000001)
        XCTAssertEqual(state.mode, .fit)
        state.zoomIn()
        XCTAssertEqual(state.scaleFactor, 0.01)
        state.fit()
        XCTAssertEqual(state.scaleFactor, 0.001, accuracy: 0.000001)
    }

    func testMalformedGeometryStaysFiniteAndInvalidZoomDoesNotChangeState() {
        var state = ImageZoomState(pixelSize: CGSize(width: CGFloat.nan, height: -CGFloat.infinity), backingScale: .infinity,
                                   viewportSize: CGSize(width: 0, height: -5))
        XCTAssertEqual(state.pixelSize, CGSize(width: 1, height: 1))
        XCTAssertEqual(state.backingScale, 1)
        XCTAssertEqual(state.viewportSize, CGSize(width: 1, height: 1))
        XCTAssertEqual(state.displayedSize, CGSize(width: 1, height: 1))
        let original = state
        for invalid: CGFloat in [.nan, .infinity, -.infinity, 0, -1] {
            state.setZoom(invalid)
            XCTAssertEqual(state, original)
        }
        state.updateBackingScale(0)
        state.updateViewport(CGSize(width: CGFloat.infinity, height: CGFloat.nan))
        XCTAssertTrue(state.displayedSize.width.isFinite)
        XCTAssertTrue(state.displayedSize.height.isFinite)
    }
}
