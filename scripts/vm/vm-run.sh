#!/usr/bin/env bash
# (Re)launch /Applications/Frost.app inside the VM's logged-in GUI session.
#   scripts/vm/vm-run.sh                         # plain launch
#   scripts/vm/vm-run.sh -e FROST_DEBUG=1 -- --some-arg value
# Options:
#   -e KEY=VALUE   environment variable for the app (repeatable; `open --env`
#                  ignores single-character names, so use KEY of 2+ chars)
#   --quit         only quit a running Frost, don't launch
#   --             everything after is passed to the app as arguments
# Launching goes through LaunchServices (`open`), so Frost is its own TCC
# "responsible process" and the Accessibility/Screen Recording grants apply.
# stdout/stderr go to /tmp/frost-stdout.log in the guest (see vm-logs.sh).
source "$(dirname "$0")/common.sh"
envs=(); args=(); quit_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e) envs+=(--env "$2"); shift 2 ;;
    -e*) envs+=(--env "${1#-e}"); shift ;;
    --quit) quit_only=1; shift ;;
    --) shift; args=("$@"); break ;;
    *) die "unknown option: $1" ;;
  esac
done
vm_running || die "VM '$VM_NAME' is not running (scripts/vm/vm-up.sh)"

# Quit politely first (lets Frost restore the menu bar), then force.
vm_ssh "if pgrep -qx Frost; then osascript -e 'tell application id \"dev.frost.Frost\" to quit' >/dev/null 2>&1 & \
  for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -qx Frost || break; sleep 0.3; done; kill \$! 2>/dev/null; pkill -x Frost; sleep 0.3; pkill -9 -x Frost; fi; true"
[[ $quit_only == 1 ]] && { log "Frost quit"; exit 0; }

vm_ssh "test -d '$GUEST_APP'" || die "$GUEST_APP missing in guest — run scripts/vm/vm-deploy.sh"
cmd=(open -n "${envs[@]}" --stdout "$GUEST_LOG" --stderr "$GUEST_LOG" "$GUEST_APP")
[[ ${#args[@]} -gt 0 ]] && cmd+=(--args "${args[@]}")
vm_ssh ": > '$GUEST_LOG'; $(printf '%q ' "${cmd[@]}")"
for _ in $(seq 1 20); do vm_ssh "pgrep -qx Frost" && break; sleep 0.5; done
pid="$(vm_ssh "pgrep -x Frost" || true)"
[[ -n "$pid" ]] || die "Frost did not start (scripts/vm/vm-logs.sh for details)"
log "Frost running in guest (pid $pid)"
