import AppKit
import SwiftUI

/// `NSVisualEffectView` background (under-window blur by default), used as the root background of the settings and
/// other windows.
///
/// `NSVisualEffectView` has no initializer taking material / blendingMode / state; they can only be set after creation.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: .zero)
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
