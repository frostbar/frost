#!/usr/bin/env bash
# Upgrade test in the VM: the previous release builds up real state (remembered sections, seen icons, the image disk
# cache) around FakeItems, then the build under test is installed over it and must start, keep running, keep the
# layout and migrate that state. See docs/testing-vm.md, "Upgrade test".
#   scripts/vm/vm-upgrade-test.sh                       # newest older release -> current tree (make build, Debug)
#   scripts/vm/vm-upgrade-test.sh --previous v0.3.0     # upgrade from a given release tag
#   scripts/vm/vm-upgrade-test.sh --build build/release/0.3.2/Frost-0.3.2.dmg   # a release candidate (release.sh)
#   scripts/vm/vm-upgrade-test.sh --build v0.3.1        # a published release
# Options:
#   --previous TAG     release to upgrade from (default: the newest published release older than the build under test)
#   --build WHAT       dev (default: `make build`, what vm-deploy.sh installs), a DMG, a Frost.app, or a release tag
#   --no-build         with --build dev: test the existing Debug build without rebuilding
#   --old-seconds N    how long the previous release runs (default 60)
#   --new-seconds N    how long the build under test runs before the checks (default 60); then it runs
#   --churn-seconds N  this much longer, and no remembered section may be re-keyed in that time (default 45)
# Exit status: 0 passed, 1 the build under test failed a check, 2 the test couldn't run (setup error).
# A passing DMG writes a marker to UPGRADE_TEST_MARKERS (scripts/release/config.sh), which release.sh --publish
# requires. Evidence of every run: build/upgrade-test/runs/<time>/ (output.txt, layouts, stored state, logs).
# Leaves the build under test installed and running in the guest (with FakeItems); `make vm-deploy` restores the
# current Debug build after testing a DMG.
source "$(dirname "$0")/common.sh"
# shellcheck source=scripts/release/config.sh
source "$REPO_ROOT/scripts/release/config.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

previous=""; build="dev"; do_build=1; old_seconds=60; new_seconds=60; churn_seconds=45
while [[ $# -gt 0 ]]; do
  case "$1" in
    --previous) previous="$2"; shift 2 ;;
    --build) build="$2"; shift 2 ;;
    --no-build) do_build=0; shift ;;
    --old-seconds) old_seconds="$2"; shift 2 ;;
    --new-seconds) new_seconds="$2"; shift 2 ;;
    --churn-seconds) churn_seconds="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done
for n in "$old_seconds" "$new_seconds" "$churn_seconds"; do
  [[ $n =~ ^[0-9]+$ ]] || { echo "durations are whole seconds" >&2; exit 2; }
done

# ---- The test layout ---------------------------------------------------------------------------------------------
# FakeItems (with FAKEITEMS_EXTRA=3 and FAKEITEMS_LIVE=1) and FakeItemsB, arranged by writing every status item's
# Preferred Position before anything launches (smaller = further right; docs/macos-behavior.md), so it works with
# release builds, which have no test hooks. Chosen to exercise what changed between versions:
# - FIExtra0..2: AX descriptions with digits, whose identity keys gained number normalization and occurrence suffixes;
# - FILiveHelp / FILiveDesc: live numbers in the AX help / description (their old keys changed every second);
# - FIBlink: hidden 4 s out of every 20 s, re-added at the far left each time (kept in Always Hidden, where a release
#   without the window watch also leaves it).
VISIBLE=(FIMenuA FIStar FBTwo)
HIDDEN=(FIWide FIPopover FIPercent FIBolt FIClock FIDual FIExtra0 FIExtra1 FILiveHelp FILiveDesc FBLeaf)
ALWAYS_HIDDEN=(FINoop FIBeta FIExtra2 FIBlink)
# Items whose identity key holds a live number: an image cached under such a key can't always be migrated (the item
# must show the same number again), so leftovers of these are expected.
LIVE_ITEMS="FILiveHelp,FILiveDesc"
FROST_POSITIONS=(FrostIcon=100 FrostHiddenSeparator=110 FrostAlwaysHiddenSeparator=1000)
GUEST_DIR=/tmp/frost-upgrade-test

RUN="$UPGRADE_TEST_DIR/runs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"
exec > >(tee -a "$RUN/output.txt") 2>&1

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
setup_fail() { printf '\033[1;31mupgrade test: SETUP ERROR:\033[0m %s\n(evidence: %s)\n' "$*" "$RUN" >&2; exit 2; }
guest_now() { vm_ssh "date +%s"; }
guest_clock() { vm_ssh "date '+%Y-%m-%d %H:%M:%S'"; }
frost_pid() { vm_ssh "pgrep -x Frost" 2>/dev/null | head -1 || true; }
wait_until() { local remaining=$(( $1 - SECONDS )); (( remaining > 0 )) && sleep "$remaining"; true; }

# Version, build number and CDHash of a Frost.app on the host.
app_info() {
  local plist="$1/Contents/Info.plist"
  printf '%s %s %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" \
    "$(codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
}
dmg_info() {
  local mnt info
  mnt=$(mktemp -d)
  hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$1" || { rmdir "$mnt"; return 1; }
  info=$(app_info "$mnt/Frost.app") || info=""
  hdiutil detach -quiet "$mnt" || true
  rmdir "$mnt" 2>/dev/null || true
  [[ -n $info ]] && echo "$info"
}

# A published release's DMG, downloaded once to UPGRADE_TEST_DIR/releases/<tag>/ and checked against the digest GitHub
# lists for it.
release_dmg() {
  local tag="$1" dir="$UPGRADE_TEST_DIR/releases/$1" name digest dmg
  read -r name digest < <(gh release view "$tag" -R "$GITHUB_REPO" --json assets \
    -q '.assets[] | select(.name | endswith(".dmg")) | "\(.name) \(.digest)"' | head -1) \
    || setup_fail "release $tag not found in $GITHUB_REPO (gh release view $tag)"
  [[ -n ${name:-} ]] || setup_fail "release $tag has no DMG"
  dmg="$dir/$name"
  if [[ ! -f $dmg || ( $digest == sha256:* && "sha256:$(shasum -a 256 "$dmg" | cut -d' ' -f1)" != "$digest" ) ]]; then
    mkdir -p "$dir"
    gh release download "$tag" -R "$GITHUB_REPO" -p "$name" -D "$dir" --clobber >&2 \
      || setup_fail "could not download $name of $tag"
  fi
  if [[ $digest == sha256:* && "sha256:$(shasum -a 256 "$dmg" | cut -d' ' -f1)" != "$digest" ]]; then
    setup_fail "$dmg doesn't match the digest GitHub lists ($digest)"
  fi
  echo "$dmg"
}

# Newest published release (not a draft or prerelease) whose version is lower than $1.
release_before() {
  local current="$1" v best=""
  while read -r v; do
    [[ $v != "$current" && $(printf '%s\n%s\n' "$v" "$current" | sort -V | head -1) == "$v" ]] || continue
    [[ -z $best || $(printf '%s\n%s\n' "$v" "$best" | sort -V | tail -1) == "$v" ]] && best="$v"
  done < <(gh release list -R "$GITHUB_REPO" --exclude-drafts --exclude-pre-releases --limit 100 --json tagName \
             -q '.[].tagName' | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p')
  [[ -n $best ]] && echo "v$best"
}

# Section layout from the guest's menu bar (guest-sections.swift). Retries for up to 30 s until every title in $2
# (comma-separated) is there and, when $3 names an earlier layout, until the sections match it (FIBlink is gone 4 s
# out of 20; an item may be mid-move). Writes the last answer to $1.
snapshot_sections() {
  local out="$1" required="$2" compare="${3:-}" deadline=$((SECONDS + 30)) json
  while :; do
    json=$(vm_ssh "$GUEST_DIR/guest-sections --json" 2>/dev/null) || json=""
    if [[ -n $json ]] && /usr/bin/python3 -I -c '
import json, sys
layout = json.loads(sys.argv[1])["sections"]
if any(t not in layout for t in filter(None, sys.argv[2].split(","))): sys.exit(1)
if sys.argv[3]:
    with open(sys.argv[3]) as handle: earlier = json.load(handle)["sections"]
    if any(layout.get(t) != s for t, s in earlier.items()): sys.exit(1)
' "$json" "$required" "$compare"; then
      break
    fi
    (( SECONDS < deadline )) || break
    sleep 2
  done
  if [[ -z $json ]]; then
    echo '{"sections": {}, "frost": {}, "windows": []}' > "$out"
    return 1
  fi
  printf '%s\n' "$json" > "$out"
}

# Click the snowflake (VNC input into the guest only), leave the Frost Bar open for 8 s (live refresh captures the
# Hidden items), close it with a second click and park the pointer on the desktop.
open_frost_bar_once() {
  local json x
  json=$(vm_ssh "$GUEST_DIR/guest-sections --json") || return 1
  x=$(/usr/bin/python3 -I -c 'import json,sys; f=json.loads(sys.argv[1])["frost"]["icon"]; print(int((f["x"]+f["width"]/2)*2))' "$json")
  "$SCRIPT_DIR/vm-vnc.sh" move "$x" 30 click 1 pause 8 move "$x" 30 click 1 pause 1 move 1728 1400
}

guest_log() { # $1 = start (guest local time) -> Frost's unified log since then
  vm_ssh "/usr/bin/log show --start '$1' --info --style compact --predicate 'subsystem == \"dev.frost.Frost\"'"
}

# ---- 1. The build under test --------------------------------------------------------------------------------------
step "Build under test: $build"
kind=""; artifact=""; artifact_sha=""
case "$build" in
  dev)
    if (( do_build )); then make -C "$REPO_ROOT" build || setup_fail "make build failed"; fi
    [[ -d $HOST_APP ]] || setup_fail "no build at $HOST_APP"
    kind=dev; artifact="$HOST_APP"
    read -r new_version new_build new_cdhash < <(app_info "$HOST_APP") ;;
  v[0-9]*)
    kind=dmg; artifact=$(release_dmg "$build") ;;
  *.dmg)
    [[ -f $build ]] || setup_fail "no DMG at $build"
    kind=dmg; artifact="$(cd "$(dirname "$build")" && pwd)/$(basename "$build")" ;;
  *.app|*.app/)
    [[ -d $build/Contents ]] || setup_fail "no app at $build"
    kind=app; artifact="$(cd "$build" && pwd)"
    read -r new_version new_build new_cdhash < <(app_info "$artifact") ;;
  *) setup_fail "--build takes dev, a DMG, a Frost.app or a release tag (got '$build')" ;;
esac
if [[ $kind == dmg ]]; then
  read -r new_version new_build new_cdhash < <(dmg_info "$artifact") || setup_fail "could not read the app in $artifact"
  artifact_sha=$(shasum -a 256 "$artifact" | cut -d' ' -f1)
fi
[[ -n ${new_version:-} && -n ${new_build:-} ]] || setup_fail "could not read the version of the build under test"
echo "  $kind: $artifact"
echo "  Frost $new_version (build $new_build), CDHash $new_cdhash"

# ---- 2. The previous release --------------------------------------------------------------------------------------
if [[ -z $previous ]]; then
  previous=$(release_before "$new_version") || setup_fail "no published release older than $new_version (pass --previous)"
fi
step "Previous release: $previous"
old_dmg=$(release_dmg "$previous")
read -r old_version old_build _ < <(dmg_info "$old_dmg") || setup_fail "could not read the app in $old_dmg"
echo "  $old_dmg: Frost $old_version (build $old_build)"
[[ $(printf '%s\n%s\n' "$old_version" "$new_version" | sort -V | head -1) == "$old_version" ]] \
  || echo "  note: $previous ($old_version) is newer than the build under test ($new_version): a downgrade"

# ---- 3. Guest: clean state, seeded layout, the previous release ----------------------------------------------------
step "Guest: reset Frost, seed the layout, install $previous"
vm_running || "$SCRIPT_DIR/vm-up.sh" || setup_fail "the VM didn't start"
vm_ssh "test -d /Applications/FakeItems.app && test -d /Applications/FakeItemsB.app" \
  || "$SCRIPT_DIR/vm-fake-items.sh" deploy || setup_fail "deploying FakeItems failed"
vm_ssh "mkdir -p $GUEST_DIR"
vm_scp "$SCRIPT_DIR/guest-sections.swift" "$SCRIPT_DIR/guest-frost-state.py" ":$GUEST_DIR/"
vm_ssh "swiftc -O -o $GUEST_DIR/guest-sections $GUEST_DIR/guest-sections.swift" || setup_fail "compiling guest-sections failed"
"$SCRIPT_DIR/vm-run.sh" --quit >/dev/null 2>&1 || true
{
  echo "pkill -x FakeItems; pkill -x FakeItemsB; pkill -x Frost; sleep 1"
  echo "defaults delete dev.frost.Frost >/dev/null 2>&1; rm -rf ~/Library/Caches/dev.frost.Frost"
  echo "defaults delete dev.frost.FakeItems >/dev/null 2>&1; defaults delete dev.frost.FakeItemsB >/dev/null 2>&1"
  echo "p() { defaults write \"\$1\" \"NSStatusItem Preferred Position \$2\" -float \"\$3\"; }"
  for entry in "${FROST_POSITIONS[@]}"; do echo "p dev.frost.Frost ${entry%%=*} ${entry#*=}"; done
  domain() { [[ $1 == FB* ]] && echo dev.frost.FakeItemsB || echo dev.frost.FakeItems; }
  position=10; for name in "${VISIBLE[@]}"; do echo "p $(domain "$name") $name $position"; position=$((position + 10)); done
  position=200; for name in "${HIDDEN[@]}"; do echo "p $(domain "$name") $name $position"; position=$((position + 10)); done
  position=1100; for name in "${ALWAYS_HIDDEN[@]}"; do echo "p $(domain "$name") $name $position"; position=$((position + 10)); done
  # No onboarding (an upgraded user finished it long ago), the Frost Bar instead of in-place expansion (the VM has no
  # notch), and no Sparkle update check (the previous release would offer the newest release).
  echo "defaults write dev.frost.Frost hasCompletedOnboarding -bool true"
  echo "defaults write dev.frost.Frost displayMode frostBar"
  echo "defaults write dev.frost.Frost SUEnableAutomaticChecks -bool false"
} | vm_ssh "bash -s" || setup_fail "seeding the guest's defaults failed"
vm_install_dmg "$old_dmg" || setup_fail "installing $previous in the guest failed"
old_requirement=$(vm_designated_requirement)
echo "  installed $previous: designated => $old_requirement"
# TCC keeps one row per service and app, with the requirement it was granted to: grant to the installed release.
"$SCRIPT_DIR/vm-grant-tcc.sh" || setup_fail "granting permissions failed"

# ---- 4. Run the previous release -----------------------------------------------------------------------------------
step "Run $previous for ${old_seconds} s (FakeItems with live items; the Frost Bar opened once)"
"$SCRIPT_DIR/vm-fake-items.sh" launch A 3 live || setup_fail "launching FakeItems failed"
"$SCRIPT_DIR/vm-fake-items.sh" launch B || setup_fail "launching FakeItemsB failed"
sleep 2
old_since=$(guest_now); old_start=$(guest_clock); old_t0=$SECONDS
"$SCRIPT_DIR/vm-run.sh" || setup_fail "$previous didn't start"
old_pid=$(frost_pid)
sleep 15
open_frost_bar_once || setup_fail "opening the Frost Bar of $previous failed"
wait_until $((old_t0 + old_seconds))
all_titles=$(IFS=,; echo "${VISIBLE[*]},${HIDDEN[*]},${ALWAYS_HIDDEN[*]}")
snapshot_sections "$RUN/old-sections.json" "$all_titles" || setup_fail "could not read the menu bar layout"
vm_ssh "/usr/bin/python3 -I $GUEST_DIR/guest-frost-state.py" > "$RUN/old-state.json" || setup_fail "could not read Frost's state"
guest_log "$old_start" > "$RUN/old-log.txt" || true
[[ -n $old_pid && $(frost_pid) == "$old_pid" ]] || {
  "$SCRIPT_DIR/vm-crash-check.sh" --wait 10 "$old_since" || true
  setup_fail "$previous stopped running during setup"
}
"$SCRIPT_DIR/vm-crash-check.sh" "$old_since" >/dev/null || setup_fail "$previous crashed during setup (vm-crash-check.sh $old_since)"
(IFS=,; /usr/bin/python3 -I "$SCRIPT_DIR/upgrade-test-check.py" seed "$RUN" --expect "visible=${VISIBLE[*]}" \
  "hidden=${HIDDEN[*]}" "always-hidden=${ALWAYS_HIDDEN[*]}") || setup_fail "the previous release's state is not as seeded"
echo "  cache files: $(/usr/bin/python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["cache"]))' "$RUN/old-state.json") entries"
"$SCRIPT_DIR/vm-run.sh" --quit >/dev/null || setup_fail "quitting $previous failed"

# ---- 5. Install and run the build under test -----------------------------------------------------------------------
step "Install Frost $new_version (build $new_build) over it and run it for $((new_seconds + churn_seconds)) s"
case "$kind" in
  dmg) vm_install_dmg "$artifact" ;;
  *) vm_install_app "$artifact" ;;
esac || setup_fail "installing the build under test failed"
new_requirement=$(vm_designated_requirement)
if [[ $new_requirement == "$old_requirement" ]]; then
  tcc_note="kept: same designated requirement as $previous, so its grants apply unchanged (as on a user's Mac)"
else
  # A dev build is self-signed, releases are Developer ID signed: macOS would ask again, so grant to the new signature.
  tcc_note="re-granted: the designated requirement differs from $previous's ($new_requirement)"
  "$SCRIPT_DIR/vm-grant-tcc.sh" || setup_fail "granting permissions failed"
fi
echo "  permissions $tcc_note"
new_since=$(guest_now); new_start=$(guest_clock); new_t0=$SECONDS
"$SCRIPT_DIR/vm-run.sh" || true
new_pid=$(frost_pid)
echo "  launched at $new_start (guest), pid ${new_pid:-none}"
sleep 15
failed=0; checks="$RUN/checks.txt"; : > "$checks"
record() { echo "$*" | tee -a "$checks"; }
if [[ -n $new_pid && $(frost_pid) == "$new_pid" ]]; then
  open_frost_bar_once || record "FAIL could not open the Frost Bar (VNC)"
  wait_until $((new_t0 + new_seconds + churn_seconds))
fi

# ---- 6. Checks ---------------------------------------------------------------------------------------------------
step "Checks"
guest_log "$new_start" > "$RUN/new-log.txt" || true
running_pid=$(frost_pid)
if [[ -z $new_pid || $running_pid != "$new_pid" ]]; then
  failed=1
  record "FAIL Frost is not running any more (launched as pid ${new_pid:-none}, now ${running_pid:-none})"
  if ! "$SCRIPT_DIR/vm-crash-check.sh" --wait 20 "$new_since" > "$RUN/crash-check.txt"; then
    # The crash and the frame it happened in, for the summary line; the whole report excerpt follows.
    record "FAIL $(tail -1 "$RUN/crash-check.txt"): $(sed -n 's/^  exception: //p' "$RUN/crash-check.txt" | head -1) \
in $(sed -n '/crashed thread/{n;s/^ *[^ ]* *//;p;}' "$RUN/crash-check.txt" | head -1)"
    sed '$d' "$RUN/crash-check.txt" | tee -a "$checks"
  else
    record "note $(tail -1 "$RUN/crash-check.txt"): it quit or was killed without one"
  fi
else
  record "ok   Frost $new_version still running as pid $new_pid after $((SECONDS - new_t0)) s"
  if "$SCRIPT_DIR/vm-crash-check.sh" "$new_since" > "$RUN/crash-check.txt"; then
    record "ok   $(tail -1 "$RUN/crash-check.txt")"
  else
    failed=1
    record "FAIL $(tail -1 "$RUN/crash-check.txt")"
    cat "$RUN/crash-check.txt" >> "$checks"
  fi
  snapshot_sections "$RUN/new-sections.json" "" "$RUN/old-sections.json" || true
  vm_ssh "/usr/bin/python3 -I $GUEST_DIR/guest-frost-state.py" > "$RUN/new-state.json" || setup_fail "could not read Frost's state"
  /usr/bin/python3 -I "$SCRIPT_DIR/upgrade-test-check.py" upgrade "$RUN" --live "$LIVE_ITEMS" --grace "$new_seconds" \
    --pid "$new_pid" | tee -a "$checks" || failed=1
  # The preferences and Frost's own Preferred Positions survive the upgrade.
  /usr/bin/python3 -I -c '
import json, sys
old, new = (json.load(open(p))["defaults"] for p in sys.argv[1:3])
keys = [k for k in old if k in ("displayMode", "hasCompletedOnboarding") or k.startswith("NSStatusItem Preferred Position Frost")]
changed = [f"{k}: {old[k]!r} -> {new.get(k)!r}" for k in keys if new.get(k) != old[k]]
print(f"FAIL settings changed: {changed}" if changed else f"ok   settings kept ({len(keys)} keys)")
sys.exit(1 if changed else 0)
' "$RUN/old-state.json" "$RUN/new-state.json" | tee -a "$checks" || failed=1
fi
grep -q '^FAIL' "$checks" && failed=1

# ---- 7. Summary --------------------------------------------------------------------------------------------------
step "Summary"
{
  echo "upgrade: $previous (Frost $old_version, build $old_build) -> $kind Frost $new_version (build $new_build)"
  echo "build under test: $artifact"
  echo "permissions: $tcc_note"
  echo "evidence: $RUN"
  if (( failed )); then echo "RESULT: FAILED"; else echo "RESULT: PASSED"; fi
} | tee "$RUN/summary.txt"
if (( failed )); then
  printf '\033[1;31mupgrade test FAILED\033[0m: %s\n' "$(grep '^FAIL' "$checks" | head -3 | sed 's/^FAIL //' | awk 'NR > 1 { printf "; " } { printf "%s", $0 }')"
  exit 1
fi
if [[ $kind == dmg ]]; then
  mkdir -p "$UPGRADE_TEST_MARKERS"
  marker="$UPGRADE_TEST_MARKERS/$new_version-$new_build.txt"
  info="$(dirname "$artifact")/build-info.txt"
  {
    echo "version=$new_version"
    echo "build=$new_build"
    echo "dmg=$artifact"
    echo "dmg_sha256=$artifact_sha"
    echo "cdhash=$new_cdhash"
    echo "previous=$previous"
    [[ -f $info ]] && grep -E '^(commit|source)=' "$info"
    echo "passed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "run=$RUN"
  } > "$marker"
  echo "release marker: $marker"
fi
printf '\033[1;32mupgrade test PASSED\033[0m\n'
