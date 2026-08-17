#!/usr/bin/env bash
# 마스터/cmux 생존 단발 점검 (heartbeat의 실체 — 상주 데몬 아님, F4 폴러누적 회피).
# 호출 시 1회 점검 후 종료. Cron 발화 전 가드 + 수동 점검용.
# exit 0 = HEALTHY, exit 1 = 문제(사유 출력). 읽기 전용(무위험).
set -u
CMUX=/Applications/cmux.app/Contents/Resources/bin/cmux
PIN="$HOME/.cmux_master_surface"
BUN_MAX=${BUN_MAX:-4}; LOAD_MAX=${LOAD_MAX:-16}
problems=()

# 1) cmux 소켓 생존
[ "$("$CMUX" ping 2>/dev/null)" = "PONG" ] || problems+=("cmux_socket_dead")

# 2) 마스터 surface 고정파일 + UUID
if [ -f "$PIN" ]; then
  PIN_SID=$(python3 -c "import json;print(json.load(open('$PIN')).get('surface_id') or '')" 2>/dev/null)
  PIN_PANE=$(python3 -c "import json;print(json.load(open('$PIN')).get('pane_id') or '')" 2>/dev/null)
  [ -n "$PIN_SID" ] || problems+=("surface_pin_empty")
else
  problems+=("no_surface_pin"); PIN_SID=""; PIN_PANE=""
fi

# 3) 마스터 claude 프로세스 생존 (cwd=핀 cwd 일치로 판정 — 플래그 비의존·cmux 재시작 내성)
#    구버전은 '--session-id' 플래그로 탐지했으나 cmux 재시작 후 현 claude는 그 플래그 없이
#    기동되어 오탐(no_master_claude) → 08시 cron이 매일 HOLD될 위험. cwd 일치가 정본.
MASTER_CWD=$(python3 -c "import json;print(json.load(open('$PIN')).get('cwd') or '')" 2>/dev/null)
mc_found=0
if [ -n "$MASTER_CWD" ]; then
  for pid in $(ps -axo pid,command | grep -- '.local/bin/claude' | grep -v grep | awk '{print $1}'); do
    pcwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
    [ "$pcwd" = "$MASTER_CWD" ] && { mc_found=1; break; }
  done
fi
[ "$mc_found" = "1" ] || problems+=("no_master_claude")

# 4) 고정 pane_id가 현재 cmux에 실존하는지(재배치/소멸 감지)
if [ -n "$PIN_PANE" ]; then
  if ! "$CMUX" list-panes --id-format uuids 2>/dev/null | grep -qi "$PIN_PANE"; then
    # list-panes가 uuid 미지원일 수 있어 read-screen으로 2차 확인
    "$CMUX" read-screen --surface "$PIN_SID" --lines 1 >/dev/null 2>&1 || problems+=("master_pane_gone")
  fi
fi

# 5) bun 누적 가드 (CSO #02 — 발화 전 서버폭주 차단)
BUN=$(ps aux | grep 'bun server.ts' | grep -v grep | wc -l | tr -d ' ')
[ "${BUN:-0}" -ge "$BUN_MAX" ] && problems+=("bun_accumulation:$BUN")

# 6) load 가드 (5분평균 판정 — macOS 데몬/GDrive 순간 1분 스파이크 플래핑 회피, sentinel과 일관)
read LOAD1 LOAD5 LOAD15 <<<"$(uptime | sed -E 's/.*load averages?: //' | awk '{print $1, $2, $3}')"
over=$(awk -v l="${LOAD5:-0}" -v m="$LOAD_MAX" 'BEGIN{print (l+0>m)?1:0}')
[ "$over" = "1" ] && problems+=("load_high:5m=$LOAD5")

if [ ${#problems[@]} -eq 0 ]; then
  echo "HEALTHY sid=${PIN_SID:0:8} bun=$BUN load5=$LOAD5 load1=$LOAD1"
  exit 0
else
  echo "UNHEALTHY: ${problems[*]}"
  exit 1
fi
