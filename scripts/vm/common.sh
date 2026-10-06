#!/usr/bin/env bash
# Shared helpers for the Frost test VM scripts. Source this file; don't run it.
#
# All GUI testing of Frost happens inside a tart macOS VM so that nothing touches
# the host desktop. See docs/testing-vm.md.

set -euo pipefail

VM_NAME="${FROST_VM:-frost-test}"
VM_USER="${FROST_VM_USER:-admin}"
VM_PASS="${FROST_VM_PASS:-admin}"
VM_STATE="${FROST_VM_STATE:-$HOME/.local/share/frost-vm}"
VM_KEY="$VM_STATE/id_ed25519"
VM_RUN_LOG="$VM_STATE/run.log"
VM_VENV="$VM_STATE/venv"
# shellcheck disable=SC2034 # used by the scripts that source this file
GUEST_APP="/Applications/Frost.app"
# shellcheck disable=SC2034
GUEST_LOG="/tmp/frost-stdout.log"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC2034
HOST_APP="$REPO_ROOT/build/DerivedData/Build/Products/Debug/Frost.app"

mkdir -p "$VM_STATE"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[vm] $*" >&2; }

# Locate tart: PATH first, then the known install locations.
TART="$(command -v tart 2>/dev/null || true)"
for c in "$HOME/.local/opt/tart/tart.app/Contents/MacOS/tart" /opt/homebrew/bin/tart; do
  [[ -n "$TART" ]] && break
  [[ -x "$c" ]] && TART="$c"
done
[[ -n "$TART" ]] || die "tart not found (see docs/testing-vm.md, 'Install tart')"

vm_exists()  { "$TART" list --quiet 2>/dev/null | grep -qx "$VM_NAME"; }
vm_running() { "$TART" list --format json 2>/dev/null \
  | /usr/bin/python3 -c 'import sys,json; n=sys.argv[1]; sys.exit(0 if any(v["Name"]==n and v.get("Running") for v in json.load(sys.stdin)) else 1)' "$VM_NAME"; }

vm_ip() { "$TART" ip "$VM_NAME" --wait "${1:-5}"; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ConnectTimeout=5 -o BatchMode=yes -o ServerAliveInterval=15 -i "$VM_KEY")

# Run a command in the guest over SSH as $VM_USER. Arguments are joined into one
# remote shell command line (like ssh itself), so quote accordingly.
vm_ssh() { ssh "${SSH_OPTS[@]}" "$VM_USER@$(vm_ip)" "$@"; }

# Same, but with a TTY (for interactive use).
vm_ssh_tty() { ssh -t "${SSH_OPTS[@]/BatchMode=yes/BatchMode=no}" "$VM_USER@$(vm_ip)" "$@"; }

# Copy host -> guest / guest -> host (paths on the guest side are prefixed with ":").
vm_scp() {
  local ip; ip="$(vm_ip)"
  local args=()
  for a in "$@"; do
    if [[ "$a" == :* ]]; then args+=("$VM_USER@$ip${a}"); else args+=("$a"); fi
  done
  scp -q "${SSH_OPTS[@]}" "${args[@]}"
}

# Run a command in the guest's logged-in GUI (Aqua) session of $VM_USER.
# Goes through sudo + `launchctl asuser` so the process is in the gui/<uid>
# bootstrap namespace (needed for WindowServer / LaunchServices / TCC).
vm_gui() {
  local q; q="$(printf '%q ' "$@")"
  vm_ssh "sudo -n launchctl asuser \$(id -u $VM_USER) sudo -n -u $VM_USER $q"
}

# Ensure key-based SSH works, installing the host key once (via sshpass with the
# image's default password, or tart exec). Retries while the guest finishes booting
# (sshd accepts connections before authentication works).
vm_ensure_ssh_key() {
  [[ -f "$VM_KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C frost-vm -f "$VM_KEY"
  local pub; pub="$(cat "$VM_KEY.pub")"
  local install="mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys) && chmod 600 ~/.ssh/authorized_keys"
  local i
  for i in $(seq 1 40); do
    ssh "${SSH_OPTS[@]}" "$VM_USER@$(vm_ip)" true 2>/dev/null && return 0
    if (( i % 5 == 0 )); then
      if command -v sshpass >/dev/null; then
        SSHPASS="$VM_PASS" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR -o ConnectTimeout=5 -o PubkeyAuthentication=no "$VM_USER@$(vm_ip)" "$install" 2>/dev/null || true
      else
        "$TART" exec "$VM_NAME" /bin/bash -c "cd ~$VM_USER && $install" 2>/dev/null || true
      fi
    fi
    sleep 3
  done
  die "could not set up key-based SSH to $VM_USER@$(vm_ip)"
}

# vnc://:password@127.0.0.1:port printed by `tart run --vnc-experimental`.
vm_vnc_url() {
  local u
  u="$(grep -Eo 'vnc://[^ ]+' "$VM_RUN_LOG" 2>/dev/null | tail -1 | sed 's/\.\.\.$//')"
  [[ -n "$u" ]] || return 1
  echo "$u"
}

# vncdotool invocation against the VM's framebuffer (never touches the host display).
vm_vncdo() {
  [[ -x "$VM_VENV/bin/vncdo" ]] || {
    log "installing vncdotool into $VM_VENV"
    /usr/bin/python3 -m venv "$VM_VENV" && "$VM_VENV/bin/pip" install -q vncdotool
  }
  local url hostport pass
  url="$(vm_vnc_url)" || die "no VNC URL in $VM_RUN_LOG (was the VM started by vm-up.sh?)"
  pass="$(sed -E 's#vnc://:([^@]*)@.*#\1#' <<<"$url")"
  hostport="$(sed -E 's#vnc://[^@]*@##; s#/$##' <<<"$url")"
  PYTHONWARNINGS=ignore "$VM_VENV/bin/vncdo" -s "${hostport%:*}::${hostport##*:}" -p "$pass" "$@"
}

# Install a Frost.app bundle from the host as the guest's $GUEST_APP (quits Frost first). tar (without AppleDouble
# files) keeps symlinks and _CodeSignature intact, so the signature stays valid; checked in the guest afterwards.
vm_install_app() {
  local app="$1" name tar="/tmp/frost-install-$$.tar"
  name="$(basename "$app")"
  COPYFILE_DISABLE=1 tar -C "$(dirname "$app")" -cf "$tar" "$name"
  vm_scp "$tar" ":$tar"
  rm -f "$tar"
  vm_ssh "pkill -x Frost; sleep 0.5; rm -rf '$GUEST_APP' /tmp/frost-install && mkdir /tmp/frost-install \
    && tar -C /tmp/frost-install -xf '$tar' && rm -f '$tar' && mv '/tmp/frost-install/$name' '$GUEST_APP' \
    && rm -rf /tmp/frost-install && { xattr -dr com.apple.quarantine '$GUEST_APP' 2>/dev/null; true; } \
    && codesign --verify --deep --strict '$GUEST_APP'"
}

# Install Frost.app from a release DMG on the host as the guest's $GUEST_APP (quits Frost first): mounted in the guest
# and copied with ditto, like a drag to Applications (the copy carries no quarantine attribute: scp doesn't add one).
vm_install_dmg() {
  local dmg="$1" remote="/tmp/frost-install-$$.dmg"
  vm_scp "$dmg" ":$remote"
  vm_ssh "pkill -x Frost; sleep 0.5; mnt=\$(mktemp -d) \
    && hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint \"\$mnt\" '$remote' || exit 1; \
    test -d \"\$mnt/Frost.app\" && rm -rf '$GUEST_APP' && ditto \"\$mnt/Frost.app\" '$GUEST_APP'; rc=\$?; \
    hdiutil detach -quiet \"\$mnt\"; rm -f '$remote'; test \$rc = 0 && codesign --verify --deep --strict '$GUEST_APP'"
}

# The designated requirement of the guest's $GUEST_APP (what TCC matches its grants against).
vm_designated_requirement() {
  vm_ssh "codesign -d -r- '$GUEST_APP' 2>&1 | sed -n 's/^designated => //p'"
}
