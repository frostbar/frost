#!/usr/bin/env bash
# Show Frost's logs from the VM: its stdout/stderr file plus unified-log entries of
# Frost's os.Logger subsystem "dev.frost.Frost" (categories: app, sections, scanner,
# mover, capture, frostbar, freezeframe, activation, layout, newitems).
#   scripts/vm/vm-logs.sh            # last 10 minutes
#   scripts/vm/vm-logs.sh 1h         # custom window for `log show --last`
#   scripts/vm/vm-logs.sh -f         # stream live (Ctrl-C to stop)
source "$(dirname "$0")/common.sh"
vm_running || die "VM '$VM_NAME' is not running (scripts/vm/vm-up.sh)"
pred='subsystem == "dev.frost.Frost"'
if [[ "${1:-}" == "-f" ]]; then
  exec ssh "${SSH_OPTS[@]}" "$VM_USER@$(vm_ip)" "/usr/bin/log stream --style compact --level debug --predicate '$pred'"
fi
echo "===== $GUEST_LOG (stdout/stderr) ====="
vm_ssh "cat '$GUEST_LOG' 2>/dev/null || echo '(none)'"
echo "===== unified log, last ${1:-10m} ====="
vm_ssh "/usr/bin/log show --style compact --info --debug --last '${1:-10m}' --predicate '$pred'"
