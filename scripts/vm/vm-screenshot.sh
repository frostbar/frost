#!/usr/bin/env bash
# Capture the VM's screen into a PNG on the host.
#   scripts/vm/vm-screenshot.sh out.png            # default: VNC framebuffer grab
#   scripts/vm/vm-screenshot.sh --guest out.png    # `screencapture` inside the guest
# The default method reads the VM framebuffer through Virtualization.framework's
# VNC server on 127.0.0.1 — it needs no TCC grant in the guest and never touches
# the host display. --guest runs screencapture in the admin GUI session and
# needs Screen Recording granted to it (docs/testing-vm.md).
source "$(dirname "$0")/common.sh"
mode=vnc
[[ "${1:-}" == "--guest" ]] && { mode=guest; shift; }
out="${1:-$REPO_ROOT/build/vm-shots/shot-$(date +%Y%m%d-%H%M%S).png}"
mkdir -p "$(dirname "$out")"
vm_running || die "VM '$VM_NAME' is not running (scripts/vm/vm-up.sh)"
if [[ $mode == vnc ]]; then
  vm_vncdo capture "$out"
else
  g="/tmp/frost-shot-$$.png"
  vm_gui /usr/sbin/screencapture -x "$g"
  vm_scp ":$g" "$out"
  vm_ssh "rm -f '$g'"
fi
[[ -s "$out" ]] || die "screenshot failed"
echo "$out"
