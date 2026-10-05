import AppKit
import FrostCore

/// Relaunches Frost (Screen Recording only takes effect in a new process).
///
/// A shell child process waits for this process to exit, then `open`s the app bundle (opening it directly would just
/// activate the still-running old instance). launchd adopts the child once this process exits; it waits at most 10
/// seconds. The window to reopen is recorded on termination (`AppDelegate.applicationWillTerminate`,
/// `RelaunchResume`), the same way as for System Settings' "Quit & Reopen".
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            #"i=0; while kill -0 "$0" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; exec /usr/bin/open "$1""#,
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundlePath,
        ]
        do {
            try process.run()
        } catch {
            FrostLog.app.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}
