#!/usr/bin/env bash
# List the crash reports a process left in the guest since a given time; exit 1 if there are any.
#   scripts/vm/vm-crash-check.sh SINCE                  # Frost crash reports written at or after SINCE
#   scripts/vm/vm-crash-check.sh --wait 15 SINCE        # wait up to 15 s for a report to appear (ReportCrash writes
#                                                       # it a few seconds after the crash); returns as soon as one does
#   scripts/vm/vm-crash-check.sh --process FakeItems SINCE
# SINCE is the guest's clock: epoch seconds (`scripts/vm/vm-exec.sh date +%s`) or a local time
# "YYYY-MM-DD HH:MM:SS". Reports are the .ips files in the guest's ~/Library/Logs/DiagnosticReports and
# /Library/Logs/DiagnosticReports (and their Retired folders) whose header names the process and whose file is not
# older than SINCE. For each, prints the file name, the exception, the termination reason and the crashed thread's top
# frames. Exit status: 0 = none, 1 = at least one report, 2 = usage or VM error.
source "$(dirname "$0")/common.sh"
process="Frost"; wait_seconds=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --process) process="$2"; shift 2 ;;
    --wait) wait_seconds="$2"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[[ $# -eq 1 ]] || { echo "usage: $0 [--wait SECONDS] [--process NAME] SINCE" >&2; exit 2; }
since="$1"
[[ $wait_seconds =~ ^[0-9]+$ ]] || { echo "--wait takes whole seconds" >&2; exit 2; }
vm_running || { echo "VM '$VM_NAME' is not running" >&2; exit 2; }

# The guest-side part prints the reports and exits 1 when it found any (2 on errors).
set +e
vm_ssh "/usr/bin/python3 -I - $(printf '%q ' "$since" "$process" "$wait_seconds")" <<'PY'
import glob, json, os, subprocess, sys, time

since_arg, process, wait_seconds = sys.argv[1], sys.argv[2], int(sys.argv[3])
if since_arg.isdigit():
    since = int(since_arg)
else:
    try:
        since = int(time.mktime(time.strptime(since_arg, "%Y-%m-%d %H:%M:%S")))
    except ValueError:
        print(f"SINCE must be epoch seconds or 'YYYY-MM-DD HH:MM:SS' (got {since_arg!r})", file=sys.stderr)
        sys.exit(2)

roots = [os.path.expanduser("~/Library/Logs/DiagnosticReports"), "/Library/Logs/DiagnosticReports"]

def reports():
    found = []
    for root in roots:
        for path in glob.glob(os.path.join(root, "*.ips")) + glob.glob(os.path.join(root, "Retired", "*.ips")):
            try:
                if os.path.getmtime(path) < since:
                    continue
                with open(path, encoding="utf-8", errors="replace") as handle:
                    header_line = handle.readline()
                    body = handle.read()
                header = json.loads(header_line)
            except (OSError, ValueError):
                continue
            if process not in (header.get("app_name"), header.get("name"), header.get("procName")):
                continue
            # bug_type 309 / 109: crash. Others (e.g. 288 stackshot, 298 hang) are listed too but don't fail.
            found.append((path, header, body))
    return sorted(found, key=lambda item: os.path.getmtime(item[0]))

deadline = time.time() + wait_seconds
found = reports()
while not found and time.time() < deadline:
    time.sleep(1)
    found = reports()

when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(since))
crashes = 0
for path, header, body in found:
    kind = str(header.get("bug_type", "?"))
    is_crash = kind in ("309", "109")
    crashes += is_crash
    print(f"{'CRASH' if is_crash else 'report'} ({'bug_type ' + kind}): {path}")
    print(f"  {header.get('app_name', process)} {header.get('app_version', '')} ({header.get('build_version', '')}) "
          f"at {header.get('timestamp', '?')}")
    try:
        report = json.loads(body)
    except ValueError:
        continue
    exception = report.get("exception", {})
    if exception:
        print(f"  exception: {exception.get('type', '?')} {exception.get('signal', '')} "
              f"{exception.get('subtype', '')}".rstrip())
    termination = report.get("termination", {})
    if termination.get("indicator"):
        print(f"  termination: {termination.get('indicator')}")
    for line in report.get("asi", {}).values():
        print(f"  asi: {' '.join(line) if isinstance(line, list) else line}")
    images = report.get("usedImages", [])
    for thread in report.get("threads", []):
        if not thread.get("triggered"):
            continue
        print(f"  crashed thread {thread.get('queue', thread.get('name', ''))}:")
        for frame in thread.get("frames", [])[:12]:
            index = frame.get("imageIndex", -1)
            image = images[index].get("name", "?") if 0 <= index < len(images) else "?"
            symbol = frame.get("symbol") or f"+{frame.get('imageOffset', 0)}"
            print(f"    {image:<24} {symbol[:120]}")
if crashes:
    print(f"{crashes} crash report(s) of {process} since {when}")
    sys.exit(1)
print(f"no crash report of {process} since {when}" + (f" ({len(found)} other report(s))" if found else ""))
PY
status=$?
set -e
exit "$status"
