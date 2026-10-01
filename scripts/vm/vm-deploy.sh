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
tmp="/tmp/frost-deploy-$$.tar"
# tar (without AppleDouble files) keeps symlinks + _CodeSignature intact, so the signature stays valid.
COPYFILE_DISABLE=1 tar -C "$(dirname "$HOST_APP")" -cf "$tmp" Frost.app
vm_scp "$tmp" ":$tmp"
rm -f "$tmp"
vm_ssh "pkill -x Frost; sleep 0.5; rm -rf '$GUEST_APP' && tar -C /Applications -xf '$tmp' && rm -f '$tmp' \
  && xattr -dr com.apple.quarantine '$GUEST_APP' 2>/dev/null; codesign --verify --deep --strict '$GUEST_APP' \
  && codesign -d -r- '$GUEST_APP' 2>&1 | grep designated"
"$(dirname "$0")/vm-grant-tcc.sh"
log "deployed"
