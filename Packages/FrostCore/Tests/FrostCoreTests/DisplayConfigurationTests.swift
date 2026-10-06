import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct DisplayConfigurationTests {
    typealias Display = DisplayConfiguration.Display
    let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func display(_ id: CGDirectDisplayID = 1, frame: CGRect? = nil, visible: CGRect, scale: CGFloat = 2) -> Display {
        Display(id: id, frame: frame ?? self.frame, visibleFrame: visible, scale: scale)
    }

    @Test func aDockChangeIsNotAChange() {
        // The Dock grew (a tile appeared) at the bottom, then moved to the side: only the visible frame's bottom and
        // sides changed, the menu bar didn't.
        let before = DisplayConfiguration(displays: [display(visible: CGRect(x: 0, y: 80, width: 1512, height: 863))])
        let taller = DisplayConfiguration(displays: [display(visible: CGRect(x: 0, y: 96, width: 1512, height: 847))])
        let side = DisplayConfiguration(displays: [display(visible: CGRect(x: 70, y: 0, width: 1442, height: 943))])
        #expect(before == taller)
        #expect(before == side)
        #expect(before.displays[0].menuBarHeight == 39)
    }

    @Test func theMenuBarHidingIsAChange() {
        let before = DisplayConfiguration(displays: [display(visible: CGRect(x: 0, y: 80, width: 1512, height: 863))])
        let hidden = DisplayConfiguration(displays: [display(visible: CGRect(x: 0, y: 80, width: 1512, height: 902))])
        #expect(before != hidden)
    }

    @Test func resolutionScaleAndArrangementChangesAreChanges() {
        let base = display(visible: CGRect(x: 0, y: 80, width: 1512, height: 863))
        let configuration = DisplayConfiguration(displays: [base])
        let larger = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        #expect(configuration != DisplayConfiguration(displays: [
            display(frame: larger, visible: CGRect(x: 0, y: 80, width: 1800, height: 1050)),
        ]))
        #expect(configuration != DisplayConfiguration(displays: [
            display(visible: CGRect(x: 0, y: 80, width: 1512, height: 863), scale: 1),
        ]))
        let second = display(2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                             visible: CGRect(x: 1512, y: 0, width: 1920, height: 1055))
        #expect(configuration != DisplayConfiguration(displays: [base, second]))
        let moved = display(2, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                            visible: CGRect(x: -1920, y: 0, width: 1920, height: 1055))
        #expect(DisplayConfiguration(displays: [base, second]) != DisplayConfiguration(displays: [base, moved]))
    }

    @Test func theOrderScreensAreListedInDoesNotMatter() {
        let a = display(1, visible: CGRect(x: 0, y: 0, width: 1512, height: 943))
        let b = display(2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                        visible: CGRect(x: 1512, y: 0, width: 1920, height: 1055))
        #expect(DisplayConfiguration(displays: [a, b]) == DisplayConfiguration(displays: [b, a]))
    }
}
