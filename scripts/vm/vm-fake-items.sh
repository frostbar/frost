#!/usr/bin/env bash
# Build the FakeItems test helpers on the host and run them inside the VM.
# They give the (otherwise almost empty) guest menu bar a set of third-party status
# items with different widths and behaviours (see Tools/FakeItems/main.swift).
#   scripts/vm/vm-fake-items.sh deploy        # build + copy both apps to guest /Applications
#   scripts/vm/vm-fake-items.sh launch [A|B] [extra] [polite|net|live]  # launch FakeItems (A, default) or FakeItemsB in
#                                             # the GUI session; extra = number of additional "Extra N" items;
#                                             # polite = popovers use cooperative NSApp.activate() (FAKEITEMS_POLITE=1)
#                                             # instead of activate(ignoringOtherApps:) -- reproduces popovers that
#                                             # ignore outside clicks unless Frost hands activation over.
#                                             # net = FIClock shows network-speed-like text whose width changes
#                                             # every second (FAKEITEMS_NET=1, like a network-speed item).
#                                             # live = three more items: live numbers in AX help / description, and
#                                             # one hidden 4 s out of every 20 s (FAKEITEMS_LIVE=1).
#                                             # Quit the app first: `open` does not relaunch a running app.
#   scripts/vm/vm-fake-items.sh quit [A|B|all]
#   scripts/vm/vm-fake-items.sh reset [A|B|all]  # quit + forget saved positions (fresh "first launch")
#   scripts/vm/vm-fake-items.sh log           # show /tmp/fakeitems.log (every click/menu/popover event)
source "$(dirname "$0")/common.sh"
vm_running || die "VM '$VM_NAME' is not running (scripts/vm/vm-up.sh)"
name_of() { case "${1:-A}" in A) echo FakeItems ;; B) echo FakeItemsB ;; *) die "unknown app $1" ;; esac; }
which_apps() { case "${1:-all}" in all) echo "FakeItems FakeItemsB" ;; *) name_of "$1" ;; esac; }
cmd="${1:-}"; shift || true
case "$cmd" in
  deploy)
    out="$("$REPO_ROOT/Tools/FakeItems/build.sh" | tail -1)"
    tmp="/tmp/fakeitems-$$.tar"
    COPYFILE_DISABLE=1 tar -C "$out" -cf "$tmp" FakeItems.app FakeItemsB.app
    vm_scp "$tmp" ":$tmp"; rm -f "$tmp"
    vm_ssh "pkill -x FakeItems; pkill -x FakeItemsB; rm -rf /Applications/FakeItems.app /Applications/FakeItemsB.app \
      && tar -C /Applications -xf '$tmp' && rm -f '$tmp' && xattr -dr com.apple.quarantine /Applications/FakeItems*.app 2>/dev/null; \
      codesign --verify /Applications/FakeItems.app /Applications/FakeItemsB.app && echo ok"
    log "FakeItems deployed" ;;
  launch)
    n="$(name_of "${1:-A}")"
    case "${3:-}" in
      "") polite=0 ;;
      polite) polite=1 ;;
      net) polite=0; net=1 ;;
      live) polite=0; live=1 ;;
      *) die "unknown launch mode '${3}' (expected: polite, net or live)" ;;
    esac
    vm_ssh "open --env FAKEITEMS_EXTRA=${2:-0} --env FAKEITEMS_POLITE=$polite --env FAKEITEMS_NET=${net:-0} --env FAKEITEMS_LIVE=${live:-0} -a /Applications/$n.app"
    for _ in $(seq 1 20); do vm_ssh "pgrep -qx $n" && break; sleep 0.3; done
    log "$n running (pid $(vm_ssh "pgrep -x $n"))" ;;
  quit)
    for n in $(which_apps "${1:-all}"); do vm_ssh "pkill -x $n; true"; done ;;
  reset)
    for n in $(which_apps "${1:-all}"); do
      vm_ssh "pkill -x $n; sleep 0.3; defaults delete dev.frost.$n >/dev/null 2>&1; true"
    done
    log "reset done" ;;
  log) vm_ssh "cat /tmp/fakeitems.log 2>/dev/null || echo '(empty)'" ;;
  *) die "usage: $0 deploy|launch [A|B] [extra] [polite|net|live]|quit [A|B|all]|reset [A|B|all]|log" ;;
esac
