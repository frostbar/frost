#!/usr/bin/env bash
# Send mouse/keyboard input to the VM (or grab its framebuffer) through the
# VM's own VNC server — input goes to the guest only, never the host desktop.
# Arguments are vncdotool commands; coordinates are framebuffer pixels
# (3456x2234 at the default 1728x1117@2x mode, i.e. points x 2).
#   scripts/vm/vm-vnc.sh move 2956 30 click 1          # e.g. click the ❄ status item
#   scripts/vm/vm-vnc.sh key alt-w                     # ⌘W  (Apple's VNC server maps VNC alt → ⌘)
#   scripts/vm/vm-vnc.sh move 2956 30 keydown meta click 1 keyup meta   # ⌥-click (VNC meta → ⌥)
#   scripts/vm/vm-vnc.sh key alt-,                     # ⌘,  (use the literal key, not "comma")
# Modifiers: alt = ⌘, meta = ⌥, super does nothing, ctrl/shift as usual. `click 6/7` scroll.
# VNC pointer drags don't drive AppKit drag-and-drop destinations; use the guest-side
# scripts/vm/guest-drag.swift for that (see docs/testing-vm.md).
source "$(dirname "$0")/common.sh"
vm_running || die "VM '$VM_NAME' is not running (scripts/vm/vm-up.sh)"
[[ $# -gt 0 ]] || die "usage: $0 <vncdotool commands...>"
vm_vncdo "$@"
