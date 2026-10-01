#!/usr/bin/env bash
# Stop the Frost test VM (graceful shutdown, then force after a timeout).
source "$(dirname "$0")/common.sh"
if ! vm_running; then log "VM '$VM_NAME' is not running"; exit 0; fi
"$TART" stop "$VM_NAME" --timeout "${1:-60}"
log "VM '$VM_NAME' stopped"
