#!/usr/bin/env bash
# Run a command in the Frost test VM as the admin user (over SSH).
#   scripts/vm/vm-exec.sh 'sw_vers; csrutil status'
#   scripts/vm/vm-exec.sh --gui open -a TextEdit   # run inside the logged-in GUI session
#   scripts/vm/vm-exec.sh                           # interactive shell
source "$(dirname "$0")/common.sh"
vm_running || die "VM '$VM_NAME' is not running (scripts/vm/vm-up.sh)"
if [[ "${1:-}" == "--gui" ]]; then shift; vm_gui "$@"; exit; fi
if [[ $# -eq 0 ]]; then vm_ssh_tty; else vm_ssh "$@"; fi
