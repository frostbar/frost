#!/usr/bin/env bash
# Build Frost on the host (make build) and install it in the VM at
# /Applications/Frost.app, preserving the code signature (always the same path,
# so TCC grants keyed on the designated requirement survive rebuilds).
#   --no-build   deploy the existing build/DerivedData/.../Frost.app as-is
source "$(dirname "$0")/common.sh"
if [[ "${1:-}" != "--no-build" ]]; then
  log "make build"
  make -C "$REPO_ROOT" build
fi
[[ -d "$HOST_APP" ]] || die "no build at $HOST_APP"
codesign --verify --deep --strict "$HOST_APP" || die "host build fails codesign --verify"

vm_running || "$(dirname "$0")/vm-up.sh"
log "copying Frost.app to guest $GUEST_APP"
vm_install_app "$HOST_APP" || die "installing Frost.app in the guest failed"
echo "designated => $(vm_designated_requirement)"
"$(dirname "$0")/vm-grant-tcc.sh"
log "deployed"
