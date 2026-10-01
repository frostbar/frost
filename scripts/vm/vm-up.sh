#!/usr/bin/env bash
# Start the Frost test VM headless (no window on the host) if it isn't running,
# then wait until SSH works and the admin GUI session is logged in.
# The VM framebuffer is exported via Virtualization.framework's VNC server on
# 127.0.0.1 (URL in $VM_STATE/run.log); vm-screenshot.sh uses it.
source "$(dirname "$0")/common.sh"
fresh=0
vm_exists || die "VM '$VM_NAME' doesn't exist — see docs/testing-vm.md ('One-time setup')"

if vm_running; then
  log "VM '$VM_NAME' already running"
else
  fresh=1
  log "starting VM '$VM_NAME' headless"
  : >"$VM_RUN_LOG"
  nohup "$TART" run "$VM_NAME" --no-graphics --no-audio --no-clipboard --vnc-experimental \
    </dev/null >>"$VM_RUN_LOG" 2>&1 &
  disown || true
fi

for _ in $(seq 1 60); do vm_ip 2 >/dev/null 2>&1 && break; sleep 2; done
ip="$(vm_ip 5)" || die "VM has no IP after ~2 min (see $VM_RUN_LOG)"

for _ in $(seq 1 60); do nc -z -G 2 "$ip" 22 2>/dev/null && break; sleep 2; done
vm_ensure_ssh_key

# Wait for the auto-login GUI session (Dock runs once the admin user is logged in).
for _ in $(seq 1 60); do vm_ssh "pgrep -qx Dock -U $VM_USER" && break; sleep 2; done
vm_ssh "pgrep -qx Dock -U $VM_USER" || die "admin GUI session not up (auto-login disabled?)"

# The image reopens a Terminal window at login; close it so screenshots are clean.
if [[ $fresh == 1 && -z "${FROST_VM_KEEP_TERMINAL:-}" ]]; then
  for _ in $(seq 1 10); do vm_ssh "pgrep -qx Terminal" && break; sleep 1; done
  vm_ssh "osascript -e 'tell application \"Terminal\" to quit' >/dev/null 2>&1; true"
fi

for _ in $(seq 1 15); do vm_vnc_url >/dev/null && break; sleep 1; done
log "VM '$VM_NAME' up at $ip (vnc: $(vm_vnc_url >/dev/null && echo available || echo missing))"
