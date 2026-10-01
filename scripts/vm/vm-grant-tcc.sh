#!/usr/bin/env bash
# Grant Frost (dev.frost.Frost at /Applications/Frost.app) Accessibility, Screen
# Recording and PostEvent in the VM by writing the guest's system TCC.db.
# Only possible because SIP is disabled in the Cirrus Labs images. The csreq
# column is built from the deployed app's designated requirement (pins the
# "Frost Local Signing" leaf cert), so the grant survives rebuilds. Idempotent;
# vm-deploy.sh runs it after every install.
#   scripts/vm/vm-grant-tcc.sh           # grant
#   scripts/vm/vm-grant-tcc.sh --revoke  # remove Frost's rows (test first-run flows)
#   scripts/vm/vm-grant-tcc.sh --show    # list Frost's rows
source "$(dirname "$0")/common.sh"
vm_running || die "VM '$VM_NAME' is not running (scripts/vm/vm-up.sh)"
BUNDLE_ID="dev.frost.Frost"
SERVICES="kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent"
DB="/Library/Application Support/com.apple.TCC/TCC.db"
action="${1:---grant}"

vm_ssh "bash -s" <<REMOTE
set -euo pipefail
DB="$DB"
case "$action" in
  --show) sudo sqlite3 "\$DB" "select service, auth_value, length(csreq), datetime(last_modified,'unixepoch') from access where client='$BUNDLE_ID'"; exit 0 ;;
  --revoke) sudo sqlite3 "\$DB" "delete from access where client='$BUNDLE_ID'" ;;
  --grant)
    csrutil status | grep -q disabled || { echo "SIP is enabled in the guest; cannot write TCC.db" >&2; exit 1; }
    test -d "$GUEST_APP" || { echo "$GUEST_APP missing" >&2; exit 1; }
    req=\$(codesign -d -r- "$GUEST_APP" 2>&1 | sed -n 's/^designated => //p')
    test -n "\$req" || { echo "no designated requirement on $GUEST_APP" >&2; exit 1; }
    echo "\$req" | csreq -r- -b /tmp/frost.csreq
    hex=\$(xxd -p /tmp/frost.csreq | tr -d '\n'); rm -f /tmp/frost.csreq
    for s in $SERVICES; do
      sudo sqlite3 "\$DB" "insert or replace into access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags, last_modified) values ('\$s', '$BUNDLE_ID', 0, 2, 4, 1, X'\$hex', 0, cast(strftime('%s','now') as integer))"
    done
    # macOS 15+/26 also shows a recurring "... is requesting to bypass the system
    # private window picker" alert for screen capture (replayd, not TCC). Push the
    # next-alert date far out for Frost and for SSH-launched screencapture.
    /usr/bin/python3 - <<'PY'
import os, plistlib, datetime, subprocess
p = os.path.expanduser("~/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist")
os.makedirs(os.path.dirname(p), exist_ok=True)
try:
    d = plistlib.load(open(p, "rb"))
except Exception:
    d = {}
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
far = datetime.datetime(2099, 1, 1)
for k in ("/Applications/Frost.app/Contents/MacOS/Frost", "dev.frost.Frost", "/usr/libexec/sshd-keygen-wrapper", "/usr/libexec/sshd-session"):
    e = d.get(k, {})
    e.update({"kScreenCaptureApprovalLastAlerted": now, "kScreenCaptureApprovalLastUsed": now,
              "kScreenCapturePrivacyHintDate": far, "kScreenCapturePrivacyHintPolicy": 2592000})
    e.setdefault("kScreenCaptureAlertableUsageCount", 1)
    d[k] = e
plistlib.dump(d, open(p, "wb"))
subprocess.run(["killall", "replayd"], stderr=subprocess.DEVNULL)
PY
    ;;
  *) echo "unknown option $action" >&2; exit 2 ;;
esac
# Make tccd drop its cache (system + per-user instances respawn on demand).
sudo killall tccd 2>/dev/null || true
REMOTE
[[ "$action" == --show ]] || log "TCC ${action#--} done for $BUNDLE_ID ($SERVICES)"
