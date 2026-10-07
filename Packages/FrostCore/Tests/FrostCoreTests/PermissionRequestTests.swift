import CoreGraphics
import Testing
@testable import FrostCore

@Suite struct PermissionRequestTests {
    @Test func aPromptThatShowsUpEndsTheRequest() {
        #expect(PermissionRequest.decide(elapsed: .milliseconds(300), promptVisible: true) == .promptShown)
        // Even right at the deadline: the prompt wins.
        #expect(PermissionRequest.decide(elapsed: PermissionRequest.promptTimeout, promptVisible: true) == .promptShown)
    }

    @Test func noPromptYetKeepsWaitingUntilTheTimeout() {
        #expect(PermissionRequest.decide(elapsed: .zero, promptVisible: false) == .keepWaiting)
        let almost = PermissionRequest.promptTimeout - .milliseconds(1)
        #expect(PermissionRequest.decide(elapsed: almost, promptVisible: false) == .keepWaiting)
    }

    /// The system API stayed silent (it prompts once per process and only while the permission has no entry): Frost is
    /// already listed in Privacy & Security, so open the pane.
    @Test func noPromptByTheTimeoutOpensTheSettingsPane() {
        #expect(PermissionRequest.decide(elapsed: PermissionRequest.promptTimeout, promptVisible: false) == .openSettings)
        #expect(PermissionRequest.decide(elapsed: .seconds(10), promptVisible: false) == .openSettings)
    }
}

// MARK: - Prompt window detection

@Suite struct PermissionPromptDetectionTests {
    /// The window the prompt really is on macOS 26.
    private static func promptWindow(id: CGWindowID = 900) -> WindowSnapshot {
        WindowSnapshot(windowID: id, ownerName: "universalAccessAuthWarn", ownerPID: 4242,
                       ownerExecutablePath: "/System/Library/PrivateFrameworks/UniversalAccess.framework/"
                           + "Versions/A/Resources/universalAccessAuthWarn.app/Contents/MacOS/universalAccessAuthWarn",
                       isOnScreen: true)
    }

    private static func window(_ id: CGWindowID, owner: String?, pid: pid_t = 100,
                               path: String? = "/Applications/Some App.app/Contents/MacOS/Some App",
                               onScreen: Bool = true) -> WindowSnapshot {
        WindowSnapshot(windowID: id, ownerName: owner, ownerPID: pid, ownerExecutablePath: path, isOnScreen: onScreen)
    }

    @Test func thePromptIsRecognizedByItsOwnerName() {
        #expect(PermissionRequest.isPromptWindow(ownerName: "universalAccessAuthWarn"))
        #expect(!PermissionRequest.isPromptWindow(ownerName: "System Settings"))
        #expect(!PermissionRequest.isPromptWindow(ownerName: nil))
        #expect(PermissionRequest.promptVisible(baseline: [], current: [Self.promptWindow()]))
    }

    /// A renamed prompt process: a new on-screen window owned by an executable under `/System/` is the prompt.
    @Test func aNewSystemWindowIsTreatedAsThePrompt() {
        let renamed = Self.window(901, owner: "SomeFutureAuthAgent", pid: 4243,
                                  path: "/System/Library/CoreServices/SomeFutureAuthAgent.app/Contents/MacOS/Agent")
        #expect(PermissionRequest.promptVisible(baseline: [], current: [renamed]))
    }

    /// The prompt's own windows, so its closing can be followed by ID.
    @Test func thePromptWindowsAreIdentified() {
        let existing = Self.window(800, owner: "Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
        let app = Self.window(801, owner: "Some App")
        #expect(PermissionRequest.promptWindowIDs(baseline: [existing], current: [existing, app, Self.promptWindow()])
                == [900])
        #expect(PermissionRequest.promptWindowIDs(baseline: [existing], current: [existing, app]).isEmpty)
    }

    /// A window that was already on screen before the request is never the prompt (the prompt only appears because of
    /// the request).
    @Test func windowsPresentBeforeTheRequestAreIgnored() {
        let existing = Self.window(901, owner: "SomeFutureAuthAgent",
                                   path: "/System/Library/CoreServices/SomeFutureAuthAgent.app/Contents/MacOS/Agent")
        #expect(!PermissionRequest.promptVisible(baseline: [existing], current: [existing]))
    }

    /// Always-present system UI (System Settings, Frost itself, the Dock, WindowServer, Control Center, ...) is never
    /// the prompt, even when one of its windows appears after the request (a Notification Center banner, the Dock's
    /// window list, ...).
    @Test func alwaysPresentSystemProcessesAreIgnored() {
        for owner in ["System Settings", "Frost", "Dock", "WindowServer", "Control Center", "Notification Center"] {
            let window = Self.window(902, owner: owner, path: "/System/Library/CoreServices/\(owner).app/Contents/MacOS/\(owner)")
            #expect(!PermissionRequest.promptVisible(baseline: [], current: [window]),
                    "\(owner) must not count as the prompt")
        }
    }

    /// A new window from an ordinary app (a document window opening behind the prompt) is not the prompt.
    @Test func newUserAppWindowsAreNotThePrompt() {
        let document = Self.window(903, owner: "Preview")
        #expect(!PermissionRequest.promptVisible(baseline: [], current: [document]))
    }

    /// A new window of a third-party app that happens to live outside `/System/` is not the prompt either.
    @Test func aSystemPathIsRequiredForTheFallback() {
        let thirdParty = Self.window(904, owner: "Auth Helper", path: "/Library/Application Support/Auth Helper/helper")
        #expect(!PermissionRequest.promptVisible(baseline: [], current: [thirdParty]))
        // Without a resolvable executable path the fallback cannot decide, and stays silent.
        let unknown = Self.window(905, owner: "Auth Helper", path: nil)
        #expect(!PermissionRequest.promptVisible(baseline: [], current: [unknown]))
    }

    /// Only windows that are really on screen count: an off-screen prompt (another Space, a hidden window) is not
    /// something the user can act on.
    @Test func offScreenWindowsDoNotCount() {
        let offScreen = Self.window(906, owner: "SomeFutureAuthAgent", path: "/System/Library/CoreServices/Agent",
                                    onScreen: false)
        #expect(!PermissionRequest.promptVisible(baseline: [], current: [offScreen]))
        #expect(!PermissionRequest.promptVisible(baseline: [], current: [Self.promptWindow(id: 907).offScreen()]))
    }

    /// The window list entries are read the way `CGWindowListCopyWindowInfo` returns them.
    @Test func windowsAreReadFromTheWindowListEntry() {
        let entry: [String: Any] = [
            kCGWindowNumber as String: 42,
            kCGWindowOwnerPID as String: 4242,
            kCGWindowOwnerName as String: "universalAccessAuthWarn",
            kCGWindowIsOnscreen as String: true,
        ]
        let window = WindowSnapshot(windowInfo: entry, ownerExecutablePath: "/System/x")
        #expect(window?.windowID == 42)
        #expect(window?.ownerPID == 4242)
        #expect(window?.ownerName == "universalAccessAuthWarn")
        #expect(window?.isOnScreen == true)
        #expect(window?.ownerExecutablePath == "/System/x")
        // Entries without an ID or owner PID are not windows Frost can compare.
        #expect(WindowSnapshot(windowInfo: [kCGWindowOwnerPID as String: 1], ownerExecutablePath: nil) == nil)
        #expect(WindowSnapshot(windowInfo: [kCGWindowNumber as String: 1], ownerExecutablePath: nil) == nil)
        // A window list that omits the on-screen flag (e.g. a filtered list) counts as off screen.
        let noFlag: [String: Any] = [kCGWindowNumber as String: 7, kCGWindowOwnerPID as String: 9]
        #expect(WindowSnapshot(windowInfo: noFlag, ownerExecutablePath: nil)?.isOnScreen == false)
    }
}

private extension WindowSnapshot {
    func offScreen() -> WindowSnapshot {
        WindowSnapshot(windowID: windowID, ownerName: ownerName, ownerPID: ownerPID,
                       ownerExecutablePath: ownerExecutablePath, isOnScreen: false)
    }
}
