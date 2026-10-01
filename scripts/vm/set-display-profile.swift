// Run inside the guest GUI session (vm_gui): assign a custom ColorSync profile to the main display for the current
// user, or reset it, then print the display's colour space. Usage: set-display-profile [<icc path> | --reset]
// Used to give the VM's virtual display a wide-gamut built-in display's "Color LCD" profile (see docs/testing-vm.md).
import AppKit
import ColorSync
let id = CGMainDisplayID()
let uuid = CGDisplayCreateUUIDFromDisplayID(id)!.takeRetainedValue()
let arg = CommandLine.arguments.dropFirst().first
if let arg {
    let value: CFTypeRef = arg == "--reset" ? kCFNull : URL(fileURLWithPath: arg) as CFURL
    let dict = [kColorSyncDeviceDefaultProfileID.takeUnretainedValue(): value,
                kColorSyncProfileUserScope.takeUnretainedValue(): kCFPreferencesCurrentUser] as CFDictionary
    let ok = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, dict)
    print("set:", ok)
    Thread.sleep(forTimeInterval: 1.5)
}
let cs = CGDisplayCopyColorSpace(id)
print("CG colour space:", String(describing: cs.name), "icc bytes", (cs.copyICCData() as Data?)?.count ?? 0)
if let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?.takeRetainedValue() as? [String: Any] {
    print("custom:", info["CustomProfiles"] ?? "none")
}
for s in NSScreen.screens { print("NSScreen", s.localizedName, s.colorSpace?.localizedName ?? "nil", s.frame, s.visibleFrame) }
