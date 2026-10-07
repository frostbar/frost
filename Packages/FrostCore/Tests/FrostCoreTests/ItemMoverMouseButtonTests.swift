import Testing
import CoreGraphics
@testable import FrostCore

/// A ⌘-drag posted while the user holds a mouse button gets mixed up with the user's own drag (their drag events carry
/// the item along, even off the menu bar): every attempt waits for the buttons to be released first.
@MainActor @Suite struct ItemMoverMouseButtonTests {
    let mover = ItemMover(scanner: MenuBarItemScanner())

    @Test func returnsAtOnceWhenNoButtonIsHeld() async throws {
        var checks = 0
        mover.isMouseButtonHeld = { checks += 1; return false }
        try await mover.waitForMouseButtonsReleased(timeout: .zero)
        #expect(checks == 1)
    }

    @Test func waitsUntilTheUserLetsGo() async throws {
        var remaining = 3
        mover.isMouseButtonHeld = { remaining -= 1; return remaining >= 0 }
        try await mover.waitForMouseButtonsReleased(timeout: .seconds(5), poll: .milliseconds(1))
        #expect(remaining < 0)
    }

    @Test func givesUpWhenTheButtonStaysDown() async {
        mover.isMouseButtonHeld = { true }
        await #expect(throws: ItemMoveError.mouseButtonHeld) {
            try await mover.waitForMouseButtonsReleased(timeout: .milliseconds(20), poll: .milliseconds(1))
        }
    }

    // MARK: - Open menus (a ⌘-drag would close the user's menu and not take effect)

    @Test func goesAheadAtOnceWithoutAMenu() async throws {
        var checks = 0
        mover.isMenuOpen = { checks += 1; return false }
        #expect(try await mover.waitForMenusToClose(timeout: .zero))
        #expect(checks == 1)
    }

    @Test func waitsForTheMenuToClose() async throws {
        var remaining = 3
        mover.isMenuOpen = { remaining -= 1; return remaining >= 0 }
        #expect(try await mover.waitForMenusToClose(timeout: .seconds(5), poll: .milliseconds(1)))
        #expect(remaining < 0)
    }

    @Test func goesAheadWhenTheMenuStaysOpen() async throws {
        mover.isMenuOpen = { true }
        #expect(try await !mover.waitForMenusToClose(timeout: .milliseconds(20), poll: .milliseconds(1)))
    }

    @Test func waitsLessWhileShuttingDown() {
        #expect(ItemMover.mouseReleaseTimeout(isShuttingDown: true) < ItemMover.mouseReleaseTimeout(isShuttingDown: false))
    }
}
