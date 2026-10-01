// Run inside the guest: switch the main display to the given point size (HiDPI
// preferred) and persist it. Usage: swift set-display-mode.swift 1728 1117
import CoreGraphics
import Foundation
let a = CommandLine.arguments
guard a.count == 3, let w = Int(a[1]), let h = Int(a[2]) else { print("usage: <width> <height>"); exit(2) }
let d = CGMainDisplayID()
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(d, opts) as! [CGDisplayMode]).filter { $0.width == w && $0.height == h }
guard let mode = modes.max(by: { $0.pixelWidth < $1.pixelWidth }) else { print("no \(w)x\(h) mode"); exit(1) }
var cfg: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&cfg)
CGConfigureDisplayWithDisplayMode(cfg, d, mode, nil)
let err = CGCompleteDisplayConfiguration(cfg, .permanently)
let cur = CGDisplayCopyDisplayMode(d)!
print("result \(err.rawValue): now \(cur.width)x\(cur.height)pt (\(cur.pixelWidth)x\(cur.pixelHeight)px)")
exit(err == .success ? 0 : 1)
