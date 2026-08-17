#!/usr/bin/env bash
# CSO system sentinel v2 — 절대지침 #02 + 워크스페이스 재구조화 P2(L1 컨텍스트 측정 통합).
# 무인 상시 감시(토큰 0). 임계 초과 시 사유 출력 후 exit → 호스트(CSO, 페일백 시 master) 재호출.
# 정상이면 영구 루프. 파괴적 조치 없음(감지·경보만).
#
# 감시: ① bun server.ts 누적 ② load 급등 ③ L1 컨텍스트(세션 jsonl 크기 프록시 — LLM 폴링 0)
# L1 대상: worker-1~3(jarvis/<role>.session 우선·STATE.md §세션 폴백 — sid-staleness 결함 보정 2026-06-16),
#          WATCH_SUBPROJECTS·cso(~/.claude/jarvis/<role>.session 에서 — master가 갱신).
# CSO 자기경보는 master surface로 직접 push(자기 clear 불가 — 설계 §3).
# ★master 백스톱(2026-06-16 오너 발견 갭 보정): master는 영구 자율제외(단일통제점·gate sg_master_guard)이나
#   '무거우면 오너께 경보(alert-only)'는 해야 함(미구현이던 경로). master sid=핀파일(.cmux_master_surface)에서
#   해석, MASTER_L1_MB(자가정리 200k보다 훨씬 위=진짜 백스톱) 초과 시 master surface로 경보만(clear 절대 없음).
set -u
POLL=${POLL:-60}
NCPU=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
BUN_MAX=${BUN_MAX:-4}
LOAD_MAX=${LOAD_MAX:-16}   # ★5분평균 기준(2026-06-18 옵션A 오너승인). 1분평균은 macOS데몬(mds/duet/mobileasset)+GDrive 일과성 스파이크가 16~23 진동→플래핑. 5분평균(지속부하만)으로 전환=플래핑 근절·폭주 포착력 무손실. 값 16 유지(헤드룸 충분).
LOAD_HARD_MAX=${LOAD_HARD_MAX:-30}   # 1분 하드실링(CSO 재량): 5분평균이 못 따라잡는 극단 순간폭주를 즉시경보로 조기포착. 일과성 피크(~23) 위에 둬 플래핑 무관(안전비대칭).
L1_MAX_MB=${L1_MAX_MB:-1}   # P1 통합(2026-06-15 오너/master 승인): 30은 죽은임계(실측 600k≈3.6MB, 30MB는 윈도 5배초과 후에야 발화). 저비용 1차스크린 1MB로 강등(worst tok/MB 누락0, 안전비대칭). 실발화는 safety-gate가 jsonl usage 실토큰(FIRE600k/RELEASE450k)으로 판정.
MASTER_L1_MB=${MASTER_L1_MB:-4}   # ★master 백스톱 경보 임계(2026-06-16). 실측 391k≈3MB(~7.8B/tok)→4MB≈~510k. master 자가정리(200k≈1.6MB)보다 훨씬 위로 둬 '자가감시 실패 시에만' 발화하는 진짜 백스톱(상시 nag 아님). alert-only(clear 절대 없음).
STALL_DETECT_ENABLED=${STALL_DETECT_ENABLED:-1}   # ★페인 stall 감지 ON(오너 승인 2026-06-24). KILL-SWITCH: 이 줄 1→0 (또는 env STALL_DETECT_ENABLED=0).

# ── 설정(자기 환경에 맞게 override) ──────────────────────────────────────────
#   JARVIS_ROOT      = 워크스페이스 루트(master/워커 폴더가 사는 곳)
#   JARVIS_CHANNELS  = 이 스크립트 묶음이 설치된 디렉터리(형제 스크립트 호출용)
#   WATCH_SUBPROJECTS= L1 컨텍스트를 함께 감시할 하위 프로젝트 역할 이름들
JARVIS_ROOT="${JARVIS_ROOT:-$HOME/jarvis}"
CH="${JARVIS_CHANNELS:-$HOME/.claude/channels}"
WATCH_SUBPROJECTS="${WATCH_SUBPROJECTS:-project-a}"   # (프로젝트별 분기는 자기 환경에 맞게)

AX="$JARVIS_ROOT"
PROJ="$HOME/.claude/projects"

# cwd → Claude Code 프로젝트 디렉터리명. 규칙: 비영숫자 1글자 → '-' 1글자.
#   ★경로를 하드코딩하지 않고 여기서 파생한다 — 루트가 바뀌어도 배선이 안 끊긴다.
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

jsonl_mb() {  # arg: path -> MB(정수) 또는 빈값
  [ -f "$1" ] || return 0
  echo $(( $(stat -f %z "$1" 2>/dev/null || echo 0) / 1048576 ))
}

# 신선도 가드(2026-06-17 오너발견 유령측정 근절): jsonl mtime이 STALE_SEC 이상 정체하거나 부재면
# 죽은·폐지 페인의 유령세션 → 측정 제외. idle 활성세션은 토큰 불변이라 제외해도 무해(깨어나면 mtime 갱신→재측정).
STALE_SEC=${STALE_SEC:-21600}   # 6h. lead-dead(25h)보다 짧게 — 6h~25h 정체는 무발화 제외, 25h+는 lead-dead 경보.
jsonl_fresh() {  # path -> 0 fresh / 1 stale·부재
  [ -f "$1" ] || return 1
  [ $(( $(date +%s) - $(stat -f %m "$1" 2>/dev/null || echo 0) )) -lt "$STALE_SEC" ]
}

l1_check() {  # 출력: "role MB path" (임계 초과 첫 건) 또는 무출력
  local role sid p mb
  for d in w1 w2 lead; do
    # sid-staleness 결함 보정(2026-06-16): jarvis/<role>.session(master가 재각성 시 갱신·권위) 우선,
    # 없을 때만 STATE.md 그렙 폴백(구판·STATE 빈칸/구sid 잔존 시 오측정 위험 — 폴백은 차선).
    sid=$(cat "$HOME/.claude/jarvis/$d.session" 2>/dev/null)
    [ -n "$sid" ] || sid=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
          "$AX/workers/$d/STATE.md" 2>/dev/null | head -1)
    [ -n "$sid" ] || continue
    p="$PROJ/$(slug "$AX/workers/$d")/$sid.jsonl"
    case "$d" in w*) role="worker-${d#w}";; *) role="$d";; esac
    # lead 생존 판정(설계 §4): jsonl 25h 무변동/부재 = 정기 발화 체계 정지 의심(경보). stale 가드보다 우선.
    if [ "$d" = "lead" ] && { [ ! -f "$p" ] || [ $(( $(date +%s) - $(stat -f %m "$p" 2>/dev/null || echo 0) )) -ge 90000 ]; }; then
      echo "lead-dead 0 ${p:-missing}"; return
    fi
    jsonl_fresh "$p" || continue   # 신선도 가드: 죽은·폐지 페인 유령세션 측정 제외
    mb=$(jsonl_mb "$p"); [ "${mb:-0}" -ge "$L1_MAX_MB" ] && { echo "$role $mb $p"; return; }
  done
  # shellcheck disable=SC2086
  for role in $WATCH_SUBPROJECTS cso; do
    sid=$(cat "$HOME/.claude/jarvis/$role.session" 2>/dev/null)
    [ -n "$sid" ] || continue
    p="$PROJ/$(slug "$AX/$role")/$sid.jsonl"
    jsonl_fresh "$p" || continue   # 신선도 가드: 폐지페인 유령측정 제외(2026-06-17)
    mb=$(jsonl_mb "$p"); [ "${mb:-0}" -ge "$L1_MAX_MB" ] && { echo "$role $mb $p"; return; }
  done
}

master_surface() { sed -n 's/.*"surface_ref"[^"]*"\([^"]*\)".*/\1/p' "$HOME/.cmux_master_surface" 2>/dev/null | head -1; }

# role → jsonl 경로(읽기전용·마커 스윕용, 2026-06-17). l1_check 로직 미러(기존 무손상).
resolve_jsonl() {
  local role=$1 sid d sub
  case "$role" in
    worker-1|w1) d=w1;; worker-2|w2) d=w2;; worker-3|w3) d=w3;; lead) d=lead;;   # ★Track1 2026-06-25: w3 커버
    master) sid=$(sed -n 's/.*"session_id"[^"]*"\([^"]*\)".*/\1/p' "$HOME/.cmux_master_surface" 2>/dev/null | head -1)
            [ -n "$sid" ] && echo "$PROJ/$(slug "$AX")/$sid.jsonl"; return ;;
    cso) sub=cso;;
    # 하위 프로젝트 역할은 WATCH_SUBPROJECTS 에 등록된 것만 인정(미등록=미해석·fail-closed).
    *) case " $WATCH_SUBPROJECTS " in *" $role "*) sub="$role";; *) return;; esac ;;
  esac
  if [ -n "${d:-}" ]; then
    sid=$(cat "$HOME/.claude/jarvis/$d.session" 2>/dev/null)
    [ -n "$sid" ] || sid=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$AX/workers/$d/STATE.md" 2>/dev/null | head -1)
    [ -n "$sid" ] && echo "$PROJ/$(slug "$AX/workers/$d")/$sid.jsonl"; return
  fi
  sid=$(cat "$HOME/.claude/jarvis/$role.session" 2>/dev/null)
  [ -n "$sid" ] && echo "$PROJ/$(slug "$AX/$sub")/$sid.jsonl"
}

master_l1_check() {  # ★master 백스톱: 출력 "master <MB> <tok> <stale0|1>"(MASTER_L1_MB 초과 시) 또는 무출력.
  # 핀 sid 라이브(2026-06-17 frozen 오판 교훈) + 토큰 실측 병행 + 신선도 플래그. 측정·경보 전용(clear 절대 없음).
  local sid p mb tok age stale
  sid=$(sed -n 's/.*"session_id"[^"]*"\([^"]*\)".*/\1/p' "$HOME/.cmux_master_surface" 2>/dev/null | head -1)
  [ -n "$sid" ] || return 0
  p="$PROJ/$(slug "$AX")/$sid.jsonl"
  [ -f "$p" ] || return 0
  mb=$(jsonl_mb "$p")
  [ "${mb:-0}" -ge "$MASTER_L1_MB" ] || return 0
  # 토큰 실측(MB↔토큰 비선형 보정 — gate가 같은 jsonl 직접 파싱)
  tok=$(bash "$CH/cso-autoclear-safety-gate.sh" ctx-tokens --jsonl "$p" 2>/dev/null)
  [[ "$tok" =~ ^[0-9]+$ ]] || tok="?"
  # 핀 신선도: 정체면 frozen/추적실패 의심(479k 오판 방지) → 경보에 표식
  age=$(( $(date +%s) - $(stat -f %m "$p" 2>/dev/null || echo 0) ))
  stale=0; [ "$age" -ge "$STALE_SEC" ] && stale=1
  echo "master $mb $tok $stale"
}

while true; do
  # bun 누적 감지: 공식 플러그인 정상 bun(telegram 등 MCP, cwd가 plugins 경로)은 제외하고 워커 검증용 bun만 카운트.
  # ★2026-06-17 오너발견 오탐: 'bun server.ts'는 상대경로라 ps args에 플러그인 경로가 안 나와 grep -v "claude-plugins" 무효
  #   → cwd 실측(lsof)으로 */plugins/* 제외해야 정확. 원의도=워커가 검증 후 안 닫은 bun 누적 폭주만 감지(플러그인 아님).
  bun_n=0
  for _bp in $(ps aux | grep 'bun server.ts' | grep -v grep | awk '{print $2}'); do
    _bcwd=$(lsof -a -d cwd -p "$_bp" 2>/dev/null | tail -1 | awk '{print $NF}')
    case "$_bcwd" in */plugins/*) ;; *) bun_n=$((bun_n+1)) ;; esac   # cwd 못 읽으면 보수적 카운트(안전비대칭)
  done
  # 5분평균(지속부하)으로 판정 + 1분 하드실링(극단 순간폭주). uptime: "load averages: <1m> <5m> <15m>"(macOS 공백구분).
  read -r load1 load5 _ < <(uptime | sed -E 's/.*load averages?: ([0-9.]+)[, ]+([0-9.]+)[, ]+([0-9.]+).*/\1 \2 \3/')
  over_load=$(awk -v l5="${load5:-0}" -v l1="${load1:-0}" -v m="$LOAD_MAX" -v hm="$LOAD_HARD_MAX" 'BEGIN{print (l5+0>m || l1+0>hm)?1:0}')

  if [ "${bun_n:-0}" -ge "$BUN_MAX" ]; then
    echo "ALERT bun_accumulation count=$bun_n (>=$BUN_MAX) load=$load1 — 잔존 bun server.ts 의심, ppid/cwd 확인 후 완료분 강제 종료"
    exit 0
  fi
  if [ "$over_load" = "1" ]; then
    echo "ALERT load_high load5=$load5 (>$LOAD_MAX 5분평균) load1=$load1 (하드실링 $LOAD_HARD_MAX) ncpu=$NCPU bun=$bun_n — 지속부하/극단피크 급등, 폭주 프로세스 식별 필요"
    exit 0
  fi

  l1=$(l1_check)
  if [ -n "$l1" ]; then
    set -- $l1
    role=$1; mb=$2
    # P1 통합 보정(2026-06-15~16 실측결함 2차수정, CSO): MB는 '저비용 1차후보'일 뿐 — 발화 여부는 게이트가
    # 실토큰으로 정직판정한다. 1MB 1차스크린은 lead(3MB)를 상시 후보로 만들고, 여기서 조치불가 상태까지
    # exit하면 bun/load 감시가 매폴링 끊긴다(제1임무 위협). → 게이트 erc로 분기:
    #   exit+통지 = 0 CLEAR-ELIGIBLE / 2 ALERT_ONLY (실제 clear 가능/수동판단 필요 — CSO·master 깨울 가치).
    #   루프지속  = 1 BLOCK / 3 ABORT(HALT·master하드가드) / 10 NO-TRIGGER / 11 COOLING / ★12 WARN-ADVISORY.
    #   ★WARN(12, 2026-06-17): 500~600k 주의권고 1회+쿨다운, exit 절대금지(loop)=bun/load 유지. exit는 0/2만.
    GATE="$CH/cso-autoclear-safety-gate.sh"
    if [ -x "$GATE" ]; then
      verdict=$("$GATE" evaluate "$role" 2>/dev/null); erc=$?
    else
      verdict="(safety-gate 부재 — 게이트 없이 보수적 발화)"; erc=0
    fi
    if [ "$erc" -eq 0 ] || [ "$erc" -eq 2 ]; then   # FIRE-actionable: 실 clear 가능/필요 → CSO·master 깨움(exit)
      NM="$HOME/.claude/jarvis/${role}.l1-notified"; now=$(date +%s); last=$(cat "$NM" 2>/dev/null)
      L1_NOTIFY_COOLDOWN=${L1_NOTIFY_COOLDOWN:-1800}
      if [ -z "$last" ] || ! [[ "$last" =~ ^[0-9]+$ ]] || [ $((now - last)) -ge "$L1_NOTIFY_COOLDOWN" ]; then
        echo "$now" > "$NM"
        if [ "$role" = "cso" ]; then  # CSO 자기경보 → master 직접 라우팅(자기 clear 불가)
          ms=$(master_surface)
          if [ -n "$ms" ]; then
            cmux send --surface "$ms" "[sentinel→master] 경보: CSO 컨텍스트 FIRE(L1) jsonl=${mb}MB — $verdict — CSO clear 시퀀스 집행 필요(설계 §4)" 2>/dev/null
            sleep 2; cmux send-key --surface "$ms" enter 2>/dev/null
          fi
        fi
        echo "ALERT l1_context role=$role jsonl=${mb}MB FIRE-actionable — $verdict — clear 시퀀스 집행 검토(집행은 AUTO_CLEAR_ENABLED 무장+토글 후, 현 OFF=판정·경보만)"
        exit 0
      fi
      # 쿨다운 내 재통지 억제 → 루프지속(bun/load 유지).
    elif [ "$erc" -eq 12 ]; then   # ★WARN-ADVISORY(CRIT-2): 주의권고 1회+쿨다운. ★exit 절대금지(loop-continue).
      WM="$HOME/.claude/jarvis/${role}.warn-notified"; wnow=$(date +%s); wlast=$(cat "$WM" 2>/dev/null)
      L1_WARN_COOLDOWN=${L1_WARN_COOLDOWN:-1800}
      if [ -z "$wlast" ] || ! [[ "$wlast" =~ ^[0-9]+$ ]] || [ $((wnow - wlast)) -ge "$L1_WARN_COOLDOWN" ]; then
        echo "$wnow" > "$WM"
        # 권고 직송: 해당 role surface(cso는 자기→master). 해석 실패 시 master 폴백(누락 방지).
        if [ "$role" = "cso" ]; then rs=$(master_surface)
        else rs=$(bash "$CH/jarvis-who.sh" "$role" 2>/dev/null); [ -n "$rs" ] || rs=$(master_surface); fi
        if [ -n "$rs" ]; then
          cmux send --surface "$rs" "[sentinel→${role}] 주의권고: $verdict (윈도 50%↑) — 작업 일단락 시 체크포인트+/clear 검토(권고·집행 아님)" 2>/dev/null
          sleep 2; cmux send-key --surface "$rs" enter 2>/dev/null
        fi
        echo "ALERT l1_context role=$role WARN-ADVISORY — $verdict (주의권고 1회·exit 안 함·loop지속)"
      fi
      # ★exit 없음 — loop-continue(bun/load 감시 유지). 과거 exit폭주 교훈.
    elif [ "$erc" -eq 10 ]; then   # NO-TRIGGER: 토큰 임계 아래 하강 → 마커 2층(.l1-notified+.warn-notified) 모두 해제
      rm -f "$HOME/.claude/jarvis/${role}.l1-notified" "$HOME/.claude/jarvis/${role}.warn-notified" 2>/dev/null
    fi
    # BLOCK(1)/ABORT(3)/COOLING(11)/쿨다운억제: 조치 불가/불요 → 감시 지속(bun/load 유지). 게이트가 디듀프 audit.
  fi

  # ★master 백스톱 경보(2026-06-16 오너 발견 갭 보정): 측정·경보 전용. master는 자율제외라 clear 절대 없음.
  # exit 안 함(경보는 push로 오너 도달·bun/load 제1임무 유지)·쿨다운 마커로 디듀프(3차보정 철학 동일).
  ml1=$(master_l1_check)
  if [ -n "$ml1" ]; then
    set -- $ml1; mmb=$2; mtok=$3; mstale=$4   # "master <MB> <tok> <stale0|1>"
    swarn=""; [ "${mstale:-0}" = "1" ] && swarn=" ⚠jsonl 정체(frozen/추적실패 의심 — 토큰 신뢰 낮음)"
    NM="$HOME/.claude/jarvis/master.l1-notified"; now=$(date +%s); last=$(cat "$NM" 2>/dev/null)
    L1_NOTIFY_COOLDOWN=${L1_NOTIFY_COOLDOWN:-1800}
    if [ -z "$last" ] || ! [[ "$last" =~ ^[0-9]+$ ]] || [ $((now - last)) -ge "$L1_NOTIFY_COOLDOWN" ]; then
      echo "$now" > "$NM"
      ms=$(master_surface)
      if [ -n "$ms" ]; then
        cmux send --surface "$ms" "[sentinel→오너] 마스터 컨텍스트 무거움: ${mtok} tok / jsonl ${mmb}MB (임계 ${MASTER_L1_MB}MB)${swarn} — SESSION_STATE 저장 후 /clear 권고(마스터=단일통제점·자율제외 → 오너 직접 입력)" 2>/dev/null
        sleep 2; cmux send-key --surface "$ms" enter 2>/dev/null
      fi
      echo "ALERT l1_context role=master ${mtok}tok/${mmb}MB${swarn} — 오너 경보(alert-only·자율제외, clear 안 함)"
    fi
  else
    rm -f "$HOME/.claude/jarvis/master.l1-notified" 2>/dev/null   # 임계 아래(clear됨/여유) → 다음 초과 즉시통지 복원
  fi

  # ════════════════════════════════════════════════════════════════════════
  # ★페인 stall 감지(설계 pane-stall-detection-rule-design-2026-06-24·오너 승인). ★다크 출시: 기본 OFF.
  # 판정 = jsonl 구조화필드(화면 아님): TERMINAL/NETWORK-DOWN만 경보, 디바운스 STALL_DEBOUNCE폴링+쿨다운.
  # mtime정체(STALL_LOOK_SEC)는 '볼 시점'만 — verdict는 stall_classify.py(마지막 ERROR vs PROGRESS 레코드).
  # ★절대 exit 안 함(loop-continue·제1임무 무중단). CSO=감지·경보만, nudge=오너(master 분기·CSO→master 단일).
  # OFF 가드(단일 if): set -u 환경에서 내부 미평가 → 회귀0. 위치=master 백스톱 직후·스윕 직전(순수 추가).
  if [ "${STALL_DETECT_ENABLED:-0}" = "1" ]; then
    STALL_LOOK_SEC=${STALL_LOOK_SEC:-300}      # ★5분 들여다볼 게이트(오너 승인 2026-06-26: 1800→300). FP0 분류기라 안전·그림자 유용성↑
    STALL_GRACE_SEC=${STALL_GRACE_SEC:-600}    # retry 정지(stuck) 판정 grace
    STALL_DEBOUNCE=${STALL_DEBOUNCE:-2}        # 연속 폴링 N회 후에만 경보
    STALL_COOLDOWN=${STALL_COOLDOWN:-1800}
    NUDGE_ENABLED=${NUDGE_ENABLED:-0}          # ★Track1: nudge 집행 토글. 기본 OFF=감지+master경보만(그림자).
    STALL_CLASSIFIER="$CH/stall_classify.py"
    # 이식성 timeout(macOS엔 timeout/gtimeout 부재 — perl alarm으로 죽은페인 read-screen hang 방어).
    _stall_to() { perl -e 'alarm shift @ARGV; exec @ARGV' "$@" 2>/dev/null; }
    _stall_nd=0
    for _srole in worker-1 worker-2 worker-3 lead; do   # ★Track1 2026-06-25: worker-3 커버(resolve_jsonl w3 분기 추가)
      _sp=$(resolve_jsonl "$_srole"); { [ -n "$_sp" ] && [ -f "$_sp" ]; } || continue
      _sage=$(( $(date +%s) - $(stat -f %m "$_sp" 2>/dev/null || echo 0) ))
      # 윈도: STALL_LOOK_SEC 이상 정체 && STALE_SEC 미만(그 이상=죽은페인=제외). 밖이면 마커 청소(복구).
      if ! { [ "$_sage" -ge "$STALL_LOOK_SEC" ] && [ "$_sage" -lt "$STALE_SEC" ]; }; then
        rm -f "$HOME/.claude/jarvis/${_srole}.stall-pending" "$HOME/.claude/jarvis/${_srole}.stall-notified" 2>/dev/null
        continue
      fi
      [ -f "$STALL_CLASSIFIER" ] || continue
      _scls=$(python3 "$STALL_CLASSIFIER" "$_sp" "$_sage" "$STALL_GRACE_SEC" 2>/dev/null)
      _sc=${_scls%% *}
      if [ "$_sc" = "AMBIGUOUS" ]; then
        # 보조 read-screen(timeout·다중프레임): 프레임변화/task-id/스피너=WORKING, 에러표식=TERMINAL, 불명확=무경보(보수).
        _ss=$(bash "$CH/jarvis-who.sh" "$_srole" 2>/dev/null)
        if [ -n "$_ss" ]; then
          _sf1=$(_stall_to 5 cmux read-screen --surface "$_ss" --lines 20)
          sleep 2
          _sf2=$(_stall_to 5 cmux read-screen --surface "$_ss" --lines 20)
          if [ "$_sf1" != "$_sf2" ]; then _sc=WORKING
          elif printf '%s' "$_sf2" | grep -qE 'task-id|Compacting|esc to interrupt'; then _sc=WORKING
          elif printf '%s' "$_sf2" | grep -qiE 'API Error|Connection closed|Unable to connect'; then _sc=TERMINAL; _scls="screen_confirmed_terminal"
          else _sc=WORKING; fi
        else _sc=WORKING; fi
      fi
      _pend="$HOME/.claude/jarvis/${_srole}.stall-pending"
      # ★Track1: TOOL-FORMAT-STALL도 경보 후보(TERMINAL과 동급 debounce·cooldown). TOOL-FORMAT-RETRY=grace(후보 아님→else 청소).
      if [ "$_sc" = "TERMINAL" ] || [ "$_sc" = "NETWORK-DOWN" ] || [ "$_sc" = "TOOL-FORMAT-STALL" ]; then
        [ "$_sc" = "NETWORK-DOWN" ] && _stall_nd=$((_stall_nd+1))
        _pc=$(cat "$_pend" 2>/dev/null); [[ "$_pc" =~ ^[0-9]+$ ]] || _pc=0
        _pc=$((_pc+1)); echo "$_pc" > "$_pend"
        if [ "$_pc" -ge "$STALL_DEBOUNCE" ] && { [ "$_sc" = "TERMINAL" ] || [ "$_sc" = "TOOL-FORMAT-STALL" ]; }; then   # netdown은 아래 집계로
          _nm="$HOME/.claude/jarvis/${_srole}.stall-notified"; _snow=$(date +%s); _slast=$(cat "$_nm" 2>/dev/null)
          if [ -z "$_slast" ] || ! [[ "$_slast" =~ ^[0-9]+$ ]] || [ $((_snow - _slast)) -ge "$STALL_COOLDOWN" ]; then
            echo "$_snow" > "$_nm"
            # ★nudge 체인(T1-4): 워커→lead / lead→master. master는 로스터 외(자율제외). owner surface 해석.
            case "$_srole" in
              worker-*) _sowner="lead"; _sownsurf=$(bash "$CH/jarvis-who.sh" lead 2>/dev/null) ;;
              lead)     _sowner="master"; _sownsurf=$(master_surface) ;;
              *)        _sowner="master"; _sownsurf=$(master_surface) ;;
            esac
            # 항상: master surface 경보(현 stall 라우팅 재사용·CSO 감지전용)
            _sms=$(master_surface)
            if [ -n "$_sms" ]; then
              cmux send --surface "$_sms" "[sentinel→master] 페인 stall 감지: ${_srole} (${_scls}) jsonl ${_sage}s 정체·자가복구 안 됨 — nudge 오너=${_sowner}(NUDGE_ENABLED=${NUDGE_ENABLED}). CSO 감지·경보 전용." 2>/dev/null
              sleep 2; cmux send-key --surface "$_sms" enter 2>/dev/null
            fi
            # ★nudge 집행(다크 OFF): NUDGE_ENABLED=1 + TOOL-FORMAT-STALL일 때만 오너에 재프롬프트. 기본 OFF=경보만.
            if [ "${NUDGE_ENABLED:-0}" = "1" ] && [ "$_sc" = "TOOL-FORMAT-STALL" ] && [ -n "$_sownsurf" ]; then
              cmux send --surface "$_sownsurf" "[sentinel→${_sowner}] ${_srole} tool-format stall(도구호출을 텍스트로 출력+동결). 해당 워커에 '실제 도구를 호출해 계속하라' nudge 요청(작업 손실 없음·재프롬프트)." 2>/dev/null
              sleep 2; cmux send-key --surface "$_sownsurf" enter 2>/dev/null
              echo "NUDGE tool_format role=${_srole} owner=${_sowner}"
            fi
            echo "ALERT pane_stall role=${_srole} ${_scls} frozen=${_sage}s — nudge오너=${_sowner}(CSO 감지전용·loop지속)"
          fi
        fi
      else
        rm -f "$_pend" 2>/dev/null   # 후보 아님(IDLE/SELF-RECOVERING/WORKING/TOOL-FORMAT-RETRY) → pending 해제
      fi
    done
    # 네트워크 전역다운 집계(2+페인 동시 isNetworkDown) → 단일 경보(개별 억제)
    if [ "${_stall_nd:-0}" -ge 2 ]; then
      _nnm="$HOME/.claude/jarvis/netdown.stall-notified"; _snow=$(date +%s); _slast=$(cat "$_nnm" 2>/dev/null)
      if [ -z "$_slast" ] || ! [[ "$_slast" =~ ^[0-9]+$ ]] || [ $((_snow - _slast)) -ge "$STALL_COOLDOWN" ]; then
        echo "$_snow" > "$_nnm"
        _sms=$(master_surface)
        if [ -n "$_sms" ]; then
          cmux send --surface "$_sms" "[sentinel→master] ★네트워크 전역 다운 의심: ${_stall_nd}개 페인 동시 connection-error(isNetworkDown). 복구 대기(비-actionable)·개별 경보 억제·단일 집계." 2>/dev/null
          sleep 2; cmux send-key --surface "$_sms" enter 2>/dev/null
        fi
        echo "ALERT network_down_global panes=${_stall_nd} — 단일 집계(loop지속)"
      fi
    fi
  fi

  # ★마커 스윕(HIGH 적대검증, 2026-06-17): 토큰↓+MB<L1_MAX 하강 시 l1_check 무출력→마커 청소 스킵→영구침묵 방지.
  # l1_check와 독립으로 매 폴링, 존재 마커의 role을 직접 해석해 MB<L1_MAX(여유)면 청소(토큰 파싱 불필요).
  for m in "$HOME/.claude/jarvis/"*.l1-notified "$HOME/.claude/jarvis/"*.warn-notified; do
    [ -e "$m" ] || continue
    r=$(basename "$m"); r=${r%.l1-notified}; r=${r%.warn-notified}
    jp=$(resolve_jsonl "$r")
    if [ -z "$jp" ] || [ ! -f "$jp" ] || [ "$(jsonl_mb "$jp")" -lt "$L1_MAX_MB" ]; then rm -f "$m"; fi
  done

  sleep "$POLL"
done
