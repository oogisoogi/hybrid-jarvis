#!/usr/bin/env bash
# Master mode-4 completion watcher (jarvis doctrine, 2026-06-12).
# Polls one or more Claude session jsonl files. Exits (re-invoking the master)
# when ANY watched session goes IDLE/COMPLETE:
#   - jsonl mtime unchanged for >= IDLE_SECS, AND
#   - the last assistant message ends with narration (text), not a pending tool_use.
# A static jsonl whose last assistant msg is a tool_use = waiting on a tool/subagent
# -> treated as BUSY, NOT fired. No cmux surface dep.
#
# Usage: master-complete-watch.sh <jsonl_path> [<jsonl_path> ...]
set -u
IDLE_SECS=${IDLE_SECS:-150}
POLL=${POLL:-30}

idle_check() {  # arg: jsonl path -> prints IDLE or BUSY
  python3 - "$1" <<'PY'
import sys, json, os, time
p = sys.argv[1]
try:
    age = time.time() - os.path.getmtime(p)
except OSError:
    print("BUSY"); sys.exit()
if age < float(os.environ.get("IDLE_SECS", "150")):
    print("BUSY"); sys.exit()
last = None
try:
    with open(p) as f:
        for ln in f:
            try:
                d = json.loads(ln)
            except Exception:
                continue
            if d.get("type") == "assistant":
                last = d
except OSError:
    print("BUSY"); sys.exit()
if not last:
    print("BUSY"); sys.exit()
content = last.get("message", {}).get("content", [])
has_tool = any(c.get("type") == "tool_use" for c in content)
print("BUSY" if has_tool else "IDLE")
PY
}

# label: jsonl 경로 → 사람이 읽는 이름. 기본은 프로젝트 디렉터리명.
# (프로젝트별 분기는 자기 환경에 맞게 — 예: case "$1" in *project-a*) echo project-a;; esac)
label() { basename "$(dirname "$1")"; }

export IDLE_SECS
while true; do
  for jp in "$@"; do
    [ -f "$jp" ] || continue
    if [ "$(idle_check "$jp")" = "IDLE" ]; then
      echo "IDLE $(label "$jp") $jp"
      exit 0
    fi
  done
  sleep "$POLL"
done
