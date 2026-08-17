#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# spawn-worker.sh — 위임 마찰 원커맨드 래퍼 (트랙① · cys 기판)
# ════════════════════════════════════════════════════════════════════════════
# 목적: master의 워커 위임 6스텝(new-surface→claude→부팅대기→각성주입→검증→브리프)의
#       함정을 없애고 **한 명령**으로 낮춘다. → 위임 마찰 = 자기수행 수준.
#
# 설계정본: docs/DESIGN-spawn-worker.md (실측기반).
# 규율: additive(기존 배선 무수정) · WORKER_DIRECTIVE · 환각0 · 실측검증("OK"≠도달).
#
# ★설계판단(A): 브리프의 spawn 스텝 1~5는 `cys launch-agent`가 이미 구현(모델 baked·
#   준비폴링·trust-prompt 자동확인·역할디렉티브·F1/F2 대응). 재구현=중복 → 이 래퍼는
#   그 위에 ①모델 footer 실측검증 ②각성 넛지(결정론) ③브리프 파일 주입 ④구조화 반환을 얹는다.
#
# 실측 근거(핵심 — 모두 이 세션에서 surface로 확인):
#   · read-screen(--lines 없음)=라이브 vt100 화면(clean text·0 ANSI escape byte 실측). 검증에 이것만 사용.
#     --lines N=stale scrollback(과거) → 라이브 판정 금지.
#   · cys send=verbatim bracketed-paste(멀티라인 원자착지·개행보존). 반환 "OK"≠화면도달.
#   · claude 콜드스타트서 Return을 타이핑가드가 삼킴(F1) → send선행+대기+도달검증+재시도.
#   · claude 입력 clear = **Ctrl-U(실측 지워짐)**. Escape는 안 지워짐(실측). → ghost clear는 C-u.
#   · 활성 thinking 신호 = **'esc to interrupt'**(처리 중에만). '✻ ..for Ns' 타이머는 완료 후에도
#     잔존(실측) → thinking 판정에 쓰지 마라(false-thinking 무한대기 유발).
#   · 모델 footer 리터럴: "Opus 4.8 · CTX.. · 5h.. · 7d..".
#   · worker 역할 caller는 타 surface close 불가(실측) → 정리는 대상 자기종료(C-c×2→exit).
#   · 동시 세션 다수(11+·실측 surface 신설 관측) → surface 해석은 launch-agent 자기출력만 신뢰
#     (전역 list diff 추정은 cross-talk 레이스 → 금지·fail-closed).
#
# 사용:
#   spawn-worker.sh --cwd <path> [--role worker] [--model opus|sonnet|fable]
#                   [--title <t>] [--brief-file <f>] [--no-awaken]
#                   [--timeout 90] [--idle 2] [--strict-model] [--dry-run] [--json]
# ════════════════════════════════════════════════════════════════════════════
set -u

CYS="${CYS:-cys}"
INBOX="$HOME/.cys/cmux-inbox.md"
SELF_SURF="$($CYS identify 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["caller"]["surface_ref"])' 2>/dev/null || echo 'surface:?')"

# ── 기본값 ──────────────────────────────────────────────────────────────────
CWD=""; ROLE="worker"; MODEL="opus"; TITLE=""; BRIEF_FILE=""
AWAKEN=1; TIMEOUT=90; IDLE=2; STRICT_MODEL=0; DRYRUN=0; JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)          CWD="${2:?}"; shift 2;;
    --role)         ROLE="${2:?}"; shift 2;;
    --model)        MODEL="${2:?}"; shift 2;;
    --title)        TITLE="${2:?}"; shift 2;;
    --brief-file)   BRIEF_FILE="${2:?}"; shift 2;;
    --awaken)       AWAKEN=1; shift;;
    --no-awaken)    AWAKEN=0; shift;;
    --timeout)      TIMEOUT="${2:?}"; shift 2;;
    --idle)         IDLE="${2:?}"; shift 2;;
    --strict-model) STRICT_MODEL=1; shift;;
    --dry-run)      DRYRUN=1; shift;;
    --json)         JSON=1; shift;;
    -h|--help)      sed -n '1,52p' "$0"; exit 0;;
    *) echo "ERR: unknown arg '$1'"; exit 2;;
  esac
done

# ── 검증 ────────────────────────────────────────────────────────────────────
[ -n "$CWD" ] || { echo "ERR: --cwd 필수"; exit 2; }
[ -d "$CWD" ] || { echo "ERR: --cwd 디렉터리 없음: $CWD"; exit 2; }
if [ -n "$BRIEF_FILE" ] && [ ! -f "$BRIEF_FILE" ]; then echo "ERR: --brief-file 없음: $BRIEF_FILE"; exit 2; fi

# ── ★모델 정책 결정론 게이트 (오너 지시 2026-07-25) ──────────────────────────
# "페인 열 때 어떤 모델?"을 master의 기억·관성이 아니라 **프로젝트 정본**이 강제한다.
# 정본 = <cwd>/.claude/spawn-model (한 줄: opus|sonnet|fable). 존재 시 --model 지정보다 우선.
# → 「저비용 모델로 돌려야 하는 정기 작업에 최상위 모델 지정」 같은 정책위반을 구조적으로 차단.
MODEL_POLICY_FILE="$CWD/.claude/spawn-model"
if [ -f "$MODEL_POLICY_FILE" ]; then
  POLICY_MODEL="$(tr '[:upper:]' '[:lower:]' < "$MODEL_POLICY_FILE" | tr -d '[:space:]')"
  case "$POLICY_MODEL" in
    opus|sonnet|fable)
      if [ "$MODEL" != "$POLICY_MODEL" ]; then
        echo "[spawn-worker] ★모델 정책 강제: 요청=$MODEL → 정책=$POLICY_MODEL (정본 $MODEL_POLICY_FILE · master 지정 무시)"
      fi
      MODEL="$POLICY_MODEL"
      ;;
    *) echo "[spawn-worker] ⚠ spawn-model 값 무효('$POLICY_MODEL') — 무시하고 --model=$MODEL 사용";;
  esac
else
  echo "[spawn-worker] ⚠ 모델 정책 파일 부재($MODEL_POLICY_FILE) — --model=$MODEL 사용(결정론 위해 정책 파일 심기 권장)"
fi
case "$MODEL" in
  opus)   AGENT="claude";        MTOK="Opus";;
  sonnet) AGENT="claude-sonnet"; MTOK="Sonnet";;
  fable)  AGENT="claude-fable";  MTOK="Fable";;
  *) echo "ERR: --model 은 opus|sonnet|fable"; exit 2;;
esac

# ── ★모델 세대 파생 (2026-07-25 신설 · master 지시4 채택안②) ──────────────────
# 문제: MTOK은 계열("Opus")뿐이라 4.8이든 5든 "모델검증 OK"로 통과했다 — 실측으로 244·246이
#   Opus 4.8로 떴는데 이 검증이 걸러내지 못했고, master가 그 OK를 세대 보증으로 오신했다.
# 해법: 기대 세대를 **agents.json 어댑터 cmd에서 파생**한다(단일 진실원). 하드코딩("Opus 5")을
#   피하므로 어댑터만 갱신하면 검증이 자동으로 따라온다.
# fail-soft: cmd에서 세대를 파생할 수 없으면(새 명명 규칙 등) 경고만 내고 기존 계열 검증으로
#   진행한다 → 새 모델 출시가 워커 기동을 막지 않는다. hard fail은 --strict-model 일 때만.
PACK_DIR="${CYS_PACK_DIR:-$HOME/.cys/pack}"

# derive_expect <agent_key> → footer 기대 표기(예 "Opus 5") · 파생 불가 시 빈 문자열
# ※JSON은 argv로 넘긴다(python3 heredoc + stdin 파이프 동시 사용은 stdin 충돌 — 실측 교훈).
derive_expect() {
  python3 - "$PACK_DIR/agents.json" "$1" <<'PYX'
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
    cmd = (d.get(sys.argv[2]) or {}).get("cmd", "")
except Exception:
    print(""); sys.exit(0)
m = re.search(r'--model\s+(\S+)', cmd)
if not m:
    print(""); sys.exit(0)
mid = m.group(1)
# claude-<family>-<ver…> → "Family ver(점표기)". 예: claude-opus-5→"Opus 5" ·
# claude-haiku-4-5→"Haiku 4.5" · claude-opus-4-8→"Opus 4.8". 미지 형식은 빈 출력(fail-soft).
g = re.match(r'^claude-(opus|sonnet|haiku|fable)-(\d+(?:-\d+)*)$', mid)
print("%s %s" % (g.group(1).capitalize(), g.group(2).replace("-", ".")) if g else "")
PYX
}

# ── ★★관측원 서열 (2026-08-11 · master 승인 · TICKET=<ticket-id>) ─────
# 왜 고쳤나: 구판은 **footer 단독** 관측이었는데 2026-08-07(cys 0.15.0 배포)부터 footer 에서
#   모델 토큰이 안 읽힌다. 그 결과 **53건 전건이 「모델 세대 불일치」로 오발화**했다
#   (08-07 9 / 08-08 15 / 08-09 9 / 08-10 13 / 08-11 6 · opus·sonnet 무관 = 노드 속성이 아님).
#   실제 모델은 정상이었다 — surface:442 의 자식 프로세스가 `claude --model claude-opus-5`.
#   ⇒ ★**관측 실패에 「불일치」라는 상태 단정 이름이 붙어 있었다.** 읽는 쪽은 agents.json·pack heal·
#   picker 를 의심하게 되고(실제로 CSO 가 세 축을 다 팠다), 진짜 불일치는 53건 잡음에 묻힌다.
# 서열(master 편성):
#   ⑴ jsonl(실물·1순위) — 워커 세션 라이브 jsonl 의 model 레코드. **실제로 무엇이 돌고 있나.**
#       ⚠무각성 상비 워커는 첫 턴 전이라 **부재가 정상**이다 ⇒ 부재는 결함이 아니라 다음 순위로 간다.
#       ⚠★**신선도 fail-closed**: spawn 이후 갱신된 파일만 본다. 안 그러면 **같은 폴더의 죽은 세션**
#         모델을 「실물 정본」 라벨을 달고 보고하게 된다([[stale-input-frames-the-neighbor]]).
#   ⑵ args(기동핀·2순위) — 자식 claude 프로세스의 `--model`. 즉시 가능하지만 ★**「기동 핀이 전달됐다」**
#       이지 **실물이 아니다**(picker 오염은 이 뒤에서 일어날 수 있다) ⇒ 출처 라벨로 구분한다.
#   ⑶ footer(보조·3순위) — 렌더/폭/배율 변경에 취약하다는 것이 실증됐으므로 강등.
#   ⑷ 셋 다 실패 → ⛔「불일치」가 아니라 **「관측 실패」**로 발화(개명 필수).
gen_from_id() {   # claude-opus-5 → "Opus 5" · 미지 형식은 빈 출력(derive_expect 와 같은 규칙)
  python3 - "$1" <<'PYG'
import re, sys
g = re.match(r'^claude-(opus|sonnet|haiku|fable)-(\d+(?:-\d+)*)$', sys.argv[1])
print("%s %s" % (g.group(1).capitalize(), g.group(2).replace("-", ".")) if g else "")
PYG
}

# surf_field: cys list 한 줄에서 필드 추출. ★탭 구분자 고정 — 공백 분할 금지
#   (경로에 공백이 실재할 수 있다: 예 `My Drive` ⇒ 공백 분할은 cwd 를 조용히 자른다).
surf_pid() { $CYS list 2>/dev/null | awk -F'\t' -v s="$SREF" '$1==s{for(i=1;i<=NF;i++) if($i ~ /^pid=/){sub(/^pid=/,"",$i); print $i; exit}}'; }
surf_cwd() { $CYS list 2>/dev/null | awk -F'\t' -v s="$SREF" '$1==s{print $NF; exit}'; }

obs_args_id() {   # ⑵ 자식 claude 프로세스 args → 모델 id (없으면 빈 출력)
  local p c out
  p="$(surf_pid)"; [ -n "$p" ] || return 0
  for c in $(pgrep -P "$p" 2>/dev/null); do
    out="$(ps -p "$c" -o command= 2>/dev/null | grep -oE '\-\-model[= ]+[^ ]+' | head -1 | sed -E 's/^--model[= ]+//')"
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  done
  return 0
}

obs_jsonl_id() {  # ⑴ 워커 세션 라이브 jsonl → message.model (없으면 빈 출력)
  local cwd slug dir cands n f
  cwd="$(surf_cwd)"; [ -n "$cwd" ] || return 0
  slug="$(printf '%s' "$cwd" | sed 's/[^a-zA-Z0-9]/-/g')"
  dir="${CYS_CLAUDE_DIR:-$HOME/.cys/claude}/projects/$slug"
  [ -d "$dir" ] || return 0
  # ★신선도 게이트: spawn 스탬프보다 새 파일만(스탬프 없으면 관측 포기 = fail-closed).
  [ -n "${SPAWN_STAMP:-}" ] && [ -f "$SPAWN_STAMP" ] || return 0
  cands="$(find "$dir" -maxdepth 1 -name '*.jsonl' -newer "$SPAWN_STAMP" 2>/dev/null)"
  [ -n "$cands" ] || return 0
  n="$(printf '%s\n' "$cands" | grep -c '^')"     # ★개행 없는 마지막 줄도 세는 계수(wc -l 금지)
  f="$(printf '%s\n' "$cands" | xargs -I{} stat -f '%m %N' {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  [ -n "$f" ] || return 0
  # 🔴★**stderr 로 보낸다** — 이 함수의 stdout 은 **반환값 채널**이다.
  #   실증(2026-08-11 첫 실사격): `log` 가 stdout 으로 나가 모델 id 에 로그 한 줄이 섞였고,
  #   그 오염된 값이 기대값과 안 맞아 ★**거짓 「세대 불일치」 경보**를 쐈다 — 오늘 고치려던 바로 그 결함이
  #   수정본 안에서 재현된 것이다. ⚠self-test 48/48 은 이걸 못 잡는다(obs_* 를 오버라이드하므로).
  log "  [관측⑴] jsonl 후보 ${n}개 · 채택=$(basename "$f")" >&2   # ★범위를 출력에 남긴다
  python3 - "$f" <<'PYJ'
import json, sys
last = ""
try:
    for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
        try: d = json.loads(line)
        except Exception: continue
        m = (d.get("message") or {}).get("model")
        if isinstance(m, str) and m: last = m
except Exception: pass
print(last)
PYJ
}

# observe_model → "<실측토큰>|<출처라벨>" (관측 실패 시 "|없음(3경로 전부 실패)")
observe_model() {
  local id tok
  id="$(obs_jsonl_id)"
  if [ -n "$id" ]; then tok="$(gen_from_id "$id")"; printf '%s|%s\n' "${tok:-$id}" "jsonl(실물·1순위)"; return 0; fi
  id="$(obs_args_id)"
  if [ -n "$id" ]; then tok="$(gen_from_id "$id")"; printf '%s|%s\n' "${tok:-$id}" "args(기동핀·2순위·실물아님)"; return 0; fi
  tok="$(sbottom | grep -oE '(Opus|Sonnet|Haiku|Fable)[^·]*' | tail -1 | sed 's/[[:space:]]*$//')"
  if [ -n "$tok" ]; then printf '%s|%s\n' "$tok" "footer(보조·3순위)"; return 0; fi
  printf '|%s\n' "없음(3경로 전부 실패)"
}

# verify_model: 3경로 실측 ↔ agents.json 파생 기대값 대조. 프로덕션·self-test 공용(중복 0).
#   부작용(log/inbox/fail_cleanup)은 이 안에 두고, self-test는 sbottom/inbox/fail_cleanup을
#   오버라이드해 **같은 코드 경로**를 실행한다 → "경고·실패가 실제로 나는지"를 실증할 수 있다.
verify_model() {
  EXPECT_TOK="$(derive_expect "$AGENT")"
  local obs raw
  raw="$(observe_model)"; ACTUAL="${raw%%|*}"; MODEL_SRC="${raw#*|}"
  if [ -n "$EXPECT_TOK" ]; then
    MODEL_GEN_CHECKED=true
    if [ -z "$ACTUAL" ]; then
      # ★⑷ 개명 지점 — 못 본 것을 「틀렸다」고 부르지 않는다.
      log "  ⚠ 모델 관측 실패 — 기대='$EXPECT_TOK' · 출처=${MODEL_SRC}"
      inbox "【경고】 spawn-worker: 모델 관측 실패(${SREF}·role=${ROLE}) — 요청=${MODEL} · 기대='$EXPECT_TOK'(agents.json $AGENT.cmd 파생) · 실측=미검출 · 출처=${MODEL_SRC}. ★이것은 세대 오류가 아니다 — 모델이 틀렸다는 뜻이 아니라 3경로(jsonl 실물·args 기동핀·footer 보조)가 전부 못 읽었다는 뜻이다. 관측원 점검 요망. ⛔이 발화에는 「불・일・치」 낱말을 넣지 않는다(회귀 ⑤-d 가 낱말 0건을 강제한다 — 옛 이름이 슬그머니 돌아오는 것을 막는 장치다)."
      [ "$STRICT_MODEL" = 1 ] && fail_cleanup 6 "--strict-model 위반(관측 실패로 세대 미보증 · 기대 '$EXPECT_TOK')"
    elif printf '%s' "$ACTUAL" | grep -qF "$EXPECT_TOK"; then
      MODEL_OK=true; log "  모델검증 OK ($EXPECT_TOK · 세대 대조 · 출처=${MODEL_SRC})"
    else
      log "  ⚠ 모델 세대 불일치 — 기대='$EXPECT_TOK' 실측='$ACTUAL' · 출처=${MODEL_SRC}"
      # ★`${SREF}` 중괄호 필수 — `$SREF·`로 쓰면 middle dot(U+00B7)이 변수명으로 파싱돼
      #   set -u 하에서 "unbound variable"로 즉사한다(self-test ④-b가 실제로 잡아냄).
      inbox "【경고】 spawn-worker: 모델 세대 불일치(${SREF}·role=${ROLE}) — 요청=${MODEL} · 기대='$EXPECT_TOK'(agents.json $AGENT.cmd 파생) · 실측='$ACTUAL' · 출처=${MODEL_SRC}. 어댑터 구세대 잔존·pack heal 덮어쓰기·picker 오염 의심 → RECOVERY '재삽입 체크 2' 확인."
      [ "$STRICT_MODEL" = 1 ] && fail_cleanup 6 "--strict-model 위반(기대 '$EXPECT_TOK' ↔ 실측 '$ACTUAL' · 출처 ${MODEL_SRC})"
    fi
  else
    # fail-soft: 세대 파생 불가(새 명명 규칙·어댑터/파일 부재) → 계열만 검증하고 진행.
    log "  ⚠ 세대 파생 불가($AGENT.cmd) → 계열 검증으로 폴백('$MTOK'·세대 미보증)"
    if [ -z "$ACTUAL" ]; then
      log "  ⚠ 모델 관측 실패(계열) — 출처=${MODEL_SRC}"
      inbox "【경고】 spawn-worker: 모델 관측 실패(${SREF}·role=${ROLE}) — 요청=${MODEL}(${MTOK}) · 실측=미검출 · 출처=${MODEL_SRC}. ★불일치가 아니라 관측 실패다."
      [ "$STRICT_MODEL" = 1 ] && fail_cleanup 6 "--strict-model 위반(관측 실패·요청 $MTOK)"
    elif printf '%s' "$ACTUAL" | grep -q "$MTOK"; then
      MODEL_OK=true; log "  모델검증 OK ($MTOK · 계열만·세대 미보증 · 출처=${MODEL_SRC})"
    else
      log "  ⚠ 모델 불일치 — 실측 '$ACTUAL'에 '$MTOK' 없음 · 출처=${MODEL_SRC}"
      inbox "【경고】 spawn-worker: 모델 불일치(${SREF}) — 요청=$MODEL($MTOK) · 실측='$ACTUAL' · 출처=${MODEL_SRC}. Fable 오염 의심."
      [ "$STRICT_MODEL" = 1 ] && fail_cleanup 6 "--strict-model 위반(요청 $MTOK 미검출)"
    fi
  fi
}

# ── self-test 하네스 (SPAWN_WORKER_SELFTEST=1 · 워커를 띄우지 않고 파생·대조 로직만 검증) ──
if [ "${SPAWN_WORKER_SELFTEST:-0}" = "1" ]; then
  FAILS=0; TOTAL=0
  ck() { # ck <label> <got> <want>
    TOTAL=$((TOTAL+1))
    if [ "$2" = "$3" ]; then echo "  ok   $1 → '$2'"
    else echo "  FAIL $1 → got='$2' want='$3'"; FAILS=$((FAILS+1)); fi
  }
  echo "[self-test] ① live agents.json 파생 ($PACK_DIR/agents.json)"
  ck "claude"        "$(derive_expect claude)"        "Opus 5"
  ck "claude-sonnet" "$(derive_expect claude-sonnet)" "Sonnet 5"
  ck "claude-fable"  "$(derive_expect claude-fable)"  "Fable 5"

  echo "[self-test] ② 가짜 팩으로 세대·미지 id 파생(비파괴 — CYS_PACK_DIR 격리)"
  FAKE="$(mktemp -d)"; PACK_DIR_SAVE="$PACK_DIR"
  python3 - "$FAKE/agents.json" <<'PYF'
import json, sys
json.dump({
  "claude":        {"cmd": "claude --model claude-opus-4-8 --dangerously-skip-permissions"},
  "claude-sonnet": {"cmd": "claude --model claude-haiku-4-5 --dangerously-skip-permissions"},
  "claude-fable":  {"cmd": "claude --model gpt-9-turbo --dangerously-skip-permissions"},
}, open(sys.argv[1], "w"))
PYF
  PACK_DIR="$FAKE"
  ck "구세대 claude-opus-4-8" "$(derive_expect claude)"        "Opus 4.8"
  ck "claude-haiku-4-5"       "$(derive_expect claude-sonnet)" "Haiku 4.5"
  ck "미지 id(fail-soft)"     "$(derive_expect claude-fable)"  ""
  ck "어댑터 부재(fail-soft)" "$(derive_expect claude-nope)"   ""
  rm -f "$FAKE/agents.json"
  ck "agents.json 부재(fail-soft)" "$(derive_expect claude)"   ""
  rmdir "$FAKE" 2>/dev/null
  PACK_DIR="$PACK_DIR_SAVE"

  echo "[self-test] ③ footer 대조 판정(실제 footer 문자열 샘플)"
  F5="  Opus 5 · CTX 8% · 5h 19% · 7d 24%"
  F48="  Opus 4.8 · CTX 27% · 5h 5% · 7d 21%"
  m() { printf '%s' "$1" | grep -qF "$2" && echo match || echo nomatch; }
  ck "Opus5 footer vs 'Opus 5'"   "$(m "$F5"  "Opus 5")"   "match"
  ck "★4.8 footer vs 'Opus 5'"    "$(m "$F48" "Opus 5")"   "nomatch"
  ck "4.8 footer vs 'Opus 4.8'"   "$(m "$F48" "Opus 4.8")" "match"
  ck "★구 계열검증의 맹점 재현"    "$(m "$F48" "Opus")"     "match"


  echo "[self-test] ④ 불일치 경로 **실행** 검증(프로덕션과 동일한 verify_model · 의존 함수만 오버라이드)"
  # verify_model이 쓰는 부작용 함수를 테스트용으로 갈아끼운다. 코드 경로는 프로덕션과 동일하다.
  log()          { echo "$*"; }
  inbox()        { echo "[inbox발화] $*"; }
  fail_cleanup() { echo "[fail_cleanup] rc=$1 msg=$2"; FC_CALLED=1; }   # 원본은 exit — 테스트는 기록만
  SREF="surface:TEST"; ROLE="selftest"; MODEL="opus"; AGENT="claude"; MTOK="Opus"
  TOUT="$(mktemp)"
  # ★관측⑴⑵도 오버라이드한다(2026-08-11). 안 하면 self-test가 실제 `cys list`를 때려
  #   **테스트가 운영 상태를 건드린다**(강제발화 3단 ⑴ 사전 목록화의 적용).
  #   기본값 = 빈 값 ⇒ ④는 종전대로 footer 경로를 태운다(구 케이스 의미 보존).
  T_JSONL=""; T_ARGS=""
  # ★원본을 다른 이름으로 보존한다 — ⑤-h 가 **실물 함수**를 태우기 위해서다.
  eval "ORIG_obs_jsonl_id() $(declare -f obs_jsonl_id | tail -n +2)"
  obs_jsonl_id() { printf '%s\n' "$T_JSONL"; }
  obs_args_id()  { printf '%s\n' "$T_ARGS"; }

  # ④-a 일치(footer=Opus 5 · 기대=live claude=Opus 5)
  sbottom() { printf '%s\n' "  Opus 5 · CTX 8% · 5h 19% · 7d 24%"; }
  MODEL_OK=false; MODEL_GEN_CHECKED=false; STRICT_MODEL=0; FC_CALLED=0
  verify_model > "$TOUT" 2>&1
  ck "일치 → model_verified"   "$MODEL_OK"          "true"
  ck "일치 → 세대대조 수행"     "$MODEL_GEN_CHECKED" "true"
  ck "일치 → inbox 무발화"      "$(grep -c '\[inbox발화\]' "$TOUT")" "0"

  # ④-b ★불일치(footer=구세대 Opus 4.8 · 기대=Opus 5) — 오늘 244·246 상황의 재현
  sbottom() { printf '%s\n' "  Opus 4.8 · CTX 27% · 5h 5% · 7d 21%"; }
  MODEL_OK=false; MODEL_GEN_CHECKED=false; STRICT_MODEL=0; FC_CALLED=0
  verify_model > "$TOUT" 2>&1
  ck "불일치 → model_verified=false" "$MODEL_OK" "false"
  ck "불일치 → 경고 로그(⚠ 라인)"    "$(grep -c '⚠ 모델 세대 불일치' "$TOUT")" "1"
  ck "불일치 → 로그+inbox 양쪽 발화" "$(grep -c '모델 세대 불일치' "$TOUT")" "2"
  ck "불일치 → inbox 경보 발화"      "$(grep -c '\[inbox발화\].*세대 불일치' "$TOUT")" "1"
  ck "불일치 → 로그에 실측값"        "$(grep -c "기대='Opus 5' 실측='Opus 4.8'" "$TOUT")" "1"
  ck "불일치 → inbox에 실측값"       "$(grep -c "실측='Opus 4.8'" "$TOUT")" "2"
  ck "불일치 → 출처 등급 병기"       "$(grep -c "출처=footer(보조·3순위)" "$TOUT")" "2"
  ck "불일치 → strict 아니면 fail 안 함" "$FC_CALLED" "0"

  # ④-c ★불일치 + --strict-model → hard fail 경로 발동
  MODEL_OK=false; MODEL_GEN_CHECKED=false; STRICT_MODEL=1; FC_CALLED=0
  verify_model > "$TOUT" 2>&1
  ck "strict 불일치 → fail_cleanup 호출" "$FC_CALLED" "1"
  ck "strict 불일치 → rc 6"              "$(grep -o 'rc=6' "$TOUT" | head -1)" "rc=6"

  # ④-d 파생 불가(미지 id) → fail-soft: 계열 검증으로 진행하고 기동을 막지 않는다
  FAKE2="$(mktemp -d)"
  python3 -c "import json,sys;json.dump({'claude':{'cmd':'claude --model gpt-9-turbo'}},open(sys.argv[1],'w'))" "$FAKE2/agents.json"
  PACK_DIR="$FAKE2"
  sbottom() { printf '%s\n' "  Opus 5 · CTX 8% · 5h 19% · 7d 24%"; }
  MODEL_OK=false; MODEL_GEN_CHECKED=false; STRICT_MODEL=0; FC_CALLED=0
  verify_model > "$TOUT" 2>&1
  ck "파생불가 → 계열검증으로 통과" "$MODEL_OK"          "true"
  ck "파생불가 → 세대 미보증 표기"  "$MODEL_GEN_CHECKED" "false"
  ck "파생불가 → 폴백 경고 1회"     "$(grep -c '세대 파생 불가' "$TOUT")" "1"
  PACK_DIR="$PACK_DIR_SAVE"; rm -rf "$FAKE2"

  echo "[self-test] ⑤ ★관측원 서열 (2026-08-11 · TICKET=<ticket-id>)"
  MTOK="Opus"; AGENT="claude"; MODEL="opus"

  # ⑤-a jsonl(1순위)이 args(2순위)를 이긴다 — args를 일부러 구세대로 두고 jsonl이 정답
  T_JSONL="claude-opus-5"; T_ARGS="claude-opus-4-8"
  sbottom() { printf '%s\n' "  Opus 4.8 · CTX 8%"; }
  MODEL_OK=false; MODEL_GEN_CHECKED=false; STRICT_MODEL=0; FC_CALLED=0
  verify_model > "$TOUT" 2>&1
  ck "⑤-a jsonl 우선 → OK"        "$MODEL_OK" "true"
  ck "⑤-a 출처=jsonl(실물)"       "$(grep -c '출처=jsonl(실물·1순위)' "$TOUT")" "1"
  ck "⑤-a 무발화"                 "$(grep -c '\[inbox발화\]' "$TOUT")" "0"

  # ⑤-b jsonl 부재(무각성 상비 = 첫 턴 전 · 정상) → args 채택. footer는 틀려도 무시된다
  T_JSONL=""; T_ARGS="claude-opus-5"
  MODEL_OK=false; MODEL_GEN_CHECKED=false; STRICT_MODEL=0; FC_CALLED=0
  verify_model > "$TOUT" 2>&1
  ck "⑤-b args 채택 → OK"         "$MODEL_OK" "true"
  ck "⑤-b 출처=args(기동핀)"      "$(grep -c '출처=args(기동핀·2순위·실물아님)' "$TOUT")" "1"

  # ⑤-c 둘 다 부재 → footer(보조)로 강등 채택
  T_JSONL=""; T_ARGS=""
  sbottom() { printf '%s\n' "  Opus 5 · CTX 8%"; }
  MODEL_OK=false; MODEL_GEN_CHECKED=false; STRICT_MODEL=0; FC_CALLED=0
  verify_model > "$TOUT" 2>&1
  ck "⑤-c footer 폴백 → OK"       "$MODEL_OK" "true"
  ck "⑤-c 출처=footer(보조)"      "$(grep -c '출처=footer(보조·3순위)' "$TOUT")" "1"

  # ⑤-d 🔴★**오늘의 오발화 형태 재현** — cys 0.15.0 이후 실제 footer(모델 토큰 없음)를 그대로 굳혀 넣는다.
  #   구판은 이 입력에서 「모델 세대 불일치」를 쐈다(53건). 신판은 「관측 실패」여야 하고,
  #   ★「불일치」라는 낱말이 **한 번도 나오면 안 된다**(음성 검사 — 이것이 이 케이스의 핵심).
  T_JSONL=""; T_ARGS=""
  sbottom() { printf '%s\n' "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent"; }
  MODEL_OK=false; MODEL_GEN_CHECKED=false; STRICT_MODEL=0; FC_CALLED=0
  verify_model > "$TOUT" 2>&1
  ck "⑤-d 관측실패 → model_verified=false" "$MODEL_OK" "false"
  ck "⑤-d 관측실패 로그+inbox 양쪽"        "$(grep -c '모델 관측 실패' "$TOUT")" "2"
  ck "⑤-d ★「불일치」 낱말 0건(개명 확인)" "$(grep -c '불일치' "$TOUT")" "0"
  ck "⑤-d 출처=없음(3경로 전부 실패)"      "$(grep -c '출처=없음(3경로 전부 실패)' "$TOUT")" "2"
  ck "⑤-d strict 아니면 fail 안 함"        "$FC_CALLED" "0"

  # ⑤-e 진짜 불일치 양성 — jsonl(실물)이 구세대를 보고하면 그때는 발화해야 한다
  T_JSONL="claude-opus-4-8"; T_ARGS=""
  MODEL_OK=false; MODEL_GEN_CHECKED=false; STRICT_MODEL=0; FC_CALLED=0
  verify_model > "$TOUT" 2>&1
  ck "⑤-e 실물 구세대 → 불일치 발화" "$(grep -c '\[inbox발화\].*세대 불일치' "$TOUT")" "1"
  ck "⑤-e 출처=jsonl 병기(로그+inbox)" "$(grep -c "실측='Opus 4.8' · 출처=jsonl(실물·1순위)" "$TOUT")" "2"
  ck "⑤-e 관측실패로 부르지 않음"    "$(grep -c '모델 관측 실패' "$TOUT")" "0"

  # ⑤-f strict + 관측 실패 → hard fail(세대 미보증이므로 strict 의미는 유지) · 단 이름은 「관측 실패」
  T_JSONL=""; T_ARGS=""
  MODEL_OK=false; MODEL_GEN_CHECKED=false; STRICT_MODEL=1; FC_CALLED=0
  verify_model > "$TOUT" 2>&1
  ck "⑤-f strict 관측실패 → fail_cleanup" "$FC_CALLED" "1"
  ck "⑤-f rc 6"                            "$(grep -o 'rc=6' "$TOUT" | head -1)" "rc=6"
  ck "⑤-f 사유에 「관측 실패」"            "$(grep -c 'fail_cleanup.*관측 실패' "$TOUT")" "1"

  # ⑤-g 미지 모델 id(실물) → 파생 불가 토큰이라도 **원문 그대로 실려** 불일치로 잡힌다(조용히 통과 금지)
  T_JSONL="gpt-9-turbo"; T_ARGS=""
  MODEL_OK=false; MODEL_GEN_CHECKED=false; STRICT_MODEL=0; FC_CALLED=0
  verify_model > "$TOUT" 2>&1
  ck "⑤-g 미지 id → 불일치 발화"  "$(grep -c '\[inbox발화\].*세대 불일치' "$TOUT")" "1"
  ck "⑤-g 미지 id 원문 노출"      "$(grep -c "실측='gpt-9-turbo'" "$TOUT")" "2"

  # ⑤-h 🔴★**실제 obs_jsonl_id 를 태운다**(오버라이드 해제 · 픽스처 사용).
  #   왜: ⑤-a~g 는 obs_* 를 오버라이드하므로 ★**그 함수 자신의 결함은 구조적으로 못 잡는다.**
  #   실제로 첫 실사격에서 `log` 가 stdout(=반환값 채널)을 오염시켜 거짓 「세대 불일치」를 쐈다.
  #   ⇒ 이 케이스는 **반환값이 모델 id 한 줄뿐인가**를 강제한다.
  FX="$(mktemp -d)"; FXCWD="$FX/proj dir"; mkdir -p "$FXCWD"    # ★경로에 공백 포함(우리 실환경 재현)
  FXSLUG="$(printf '%s' "$FXCWD" | sed 's/[^a-zA-Z0-9]/-/g')"
  mkdir -p "$FX/claude/projects/$FXSLUG"
  printf '%s\n' \
    '{"message":{"model":"claude-opus-5","role":"assistant"}}' \
    '{"message":{"model":"claude-opus-4-8","role":"assistant"}}' \
    > "$FX/claude/projects/$FXSLUG/live.jsonl"
  SPAWN_STAMP="$FX/stamp"; : > "$SPAWN_STAMP"
  touch -t 202001010000 "$SPAWN_STAMP"          # 픽스처보다 오래된 기준선 = 신선도 통과
  CYS_CLAUDE_DIR="$FX/claude"
  surf_cwd() { printf '%s\n' "$FXCWD"; }
  T_OUT="$(ORIG_obs_jsonl_id 2>/dev/null)"
  ck "⑤-h 실물 함수 → 마지막 model 채택" "$T_OUT" "claude-opus-4-8"
  ck "⑤-h ★반환값 1줄(로그 오염 0)"      "$(printf '%s' "$T_OUT" | grep -c '^')" "1"
  ck "⑤-h 로그 낱말 혼입 0(약한 검사 교정)" "$(printf '%s' "$T_OUT" | grep -c '관측')" "0"
  # ⑤-i 신선도 fail-closed — 기준선이 픽스처보다 새로우면 ⑴은 **아무것도 채택하지 않는다**
  touch "$SPAWN_STAMP"
  ck "⑤-i 스탬프가 새로우면 부재"        "$(ORIG_obs_jsonl_id 2>/dev/null)" ""
  rm -rf "$FX"; unset CYS_CLAUDE_DIR SPAWN_STAMP
  rm -f "$TOUT"

  echo "[self-test] 결과: $((TOTAL-FAILS))/$TOTAL 통과$([ "$FAILS" = 0 ] || echo " ★$FAILS 실패")"
  exit "$([ "$FAILS" = 0 ] && echo 0 || echo 1)"
fi

# 🔴★KST 고정(2026-07-28 교정). 구판 = `date -u …Z`(UTC) — **원장(kind=brief 9건)과 인박스 머리**
# 두 곳에 UTC를 써서 **같은 원장 안에 두 시간축이 섞였다**(KST 458건 ↔ UTC 9건).
# ⇒ CSO가 21:01 기동을 **「12:01 = 9시간 전」**으로 읽고 「surface 번호 재사용」을 의심,
#   「프로세스 나이 < 마지막 발신 경과」면 이력 불신이라는 처방까지 올렸다. 그 조건은 UTC 때문에
#   **항상 참**이라 채택했으면 원장 이력 전체가 상시 불신됐다(집행 전 승인 요청이라 막혔다).
# ★평소 98%가 맞아서 아무도 의심하지 않았다 — 소수 이상치가 가장 늦게 발견된다.
# master-send.sh(`date '+%Y-%m-%dT%H:%M:%S%z'`)와 **같은 형식으로 통일한다.**
TS()    { date '+%Y-%m-%dT%H:%M:%S%z'; }
log()   { echo "[spawn-worker] $*"; }
inbox() { [ "$DRYRUN" = 1 ] && { echo "WOULD inbox: $*"; return; }; printf '[worker@%s → cmux master] %s %s\n' "$SELF_SURF" "$(TS)" "$*" >> "$INBOX"; }

# ★★P2 — spawn 브리프를 master 발신 원장에 남긴다 (2026-07-27 · master 승인)
#   $1=본문 $2=제출상태(true|landed_submit_unconfirmed|absent)
#   ⚠원장은 append-only 다 — 여기서도 **append 만** 한다(읽기·재기록 없음).
#   ⚠실패해도 spawn 을 막지 않는다(fail-open) — 기록 실패가 기동 실패가 되면 안 된다.
LEDGER="${MSEND_LEDGER:-$HOME/.claude/channels/.master-send-ledger.jsonl}"
ledger_brief() {
  [ "$DRYRUN" = 1 ] && { echo "WOULD ledger: kind=brief surface=$SREF submitted=$2"; return 0; }
  [ -f "$LEDGER" ] || return 0     # 원장이 아직 없으면 만들지 않는다(초기화는 master-send.sh 소관)
  python3 - "$LEDGER" "$(TS)" "$SREF" "$1" "$2" "$ROLE" "$BRIEF_FILE" <<'PY' 2>/dev/null || true
import json,sys,hashlib
led,ts,surf,body,state,role,src = sys.argv[1:8]
rec={"type":"send","ts":ts,"surface":surf,"kind":"brief",
     "body_sha256":hashlib.sha256(body.encode("utf-8")).hexdigest(),
     "body_head":body[:80],"body_len":len(body),
     "submitted":state,"backend":"cys","via":"spawn-worker.sh","role":role,"brief_file":src,
     "note":"spawn 경로 브리프 — master-send.sh 래퍼를 타지 않으므로 nonce 표식이 없다. 무표식이 정상이며 이 엔트리가 그 근거다."}
with open(led,"a",encoding="utf-8") as f:
    f.write(json.dumps(rec,ensure_ascii=False)+"\n")
PY
}

# ── 라이브 화면 헬퍼 (모두 --lines 없이 = vt100 현화면·clean text 실측) ──────
screen()  { $CYS read-screen --surface "$SREF" 2>/dev/null; }
sbottom() { screen | tail -n 30; }   # ★footer 토큰 전용 존. ❯ 탐색에는 쓰지 마라(아래 R1).
# ── ★★R1 — ❯ 탐색에서 판독 창을 제거한다 (2026-07-27 · master 티켓 · 진단 §1) ──
#   결함: ❯를 `sbottom`(tail -30) **안에서만** 찾았다. 화면은 93행이고 ❯는 항상 아래에서
#   5번째라 창의 여유가 **25행뿐**이다. 박스 높이 H에 대해 ❯는 아래에서 H+4번째이므로
#   ⇒ **H가 27행을 넘는 순간 ❯가 창 밖으로 나가고 `grep` 이 0행을 돌려 판독이 무조건 실패**한다.
#   실증 3건이 전부 이 문턱의 반대편이었다: 271=7,713자 · 272=6,693자 · 08:0x 사고=4,004자.
#   ★백엔드(cmux/cys)와 무관하다 — 변수는 **본문 길이 = 박스 높이**다. 종전 진단의 「cmux」는 우연이었다.
#   ★그리고 이 결함은 **긴 본문일수록** 난다 — 즉 **가장 중요한 전송에서만** 난다.
#   ⇒ 전 화면에서 찾는다. stale-top 오탐은 **`tail -1`이 이미 막는다**(창으로 막을 필요가 없었다).
#   ⚠★짧은 본문으로만 시험하면 이 결함은 **절대 재현되지 않는다.** 회귀 시험에 tall 시나리오 필수.
box_line() { screen | grep '❯' | tail -1; }
# is_ready: 하단에 footer 토큰 AND 프롬프트 박스 ❯ 둘 다 존재해야(부팅중 스크롤백 오탐 차단)
#   ★❯ 판정만 전 화면으로 옮긴다(footer 토큰은 실제로 하단에 있으므로 sbottom 유지).
is_ready()    { local b; b="$(sbottom)"; printf '%s' "$b" | grep -qE 'CTX [0-9]+%|Opus|Sonnet|Fable|bypass permissions' && [ -n "$(box_line)" ]; }
# is_thinking: 'esc to interrupt'만(✻ 타이머는 완료후 잔존 → 제외)
is_thinking() { screen | grep -qi 'esc to interrupt'; }
is_idle()     { is_ready && ! is_thinking; }
# 입력박스에 내용이 있나(도달/ghost 신호): ❯ 뒤에 non-space.
# ★claude는 ❯ 뒤에 NBSP(U+00A0)를 렌더(ASCII 공백 아님·hexdump 실측 c2 a0) → NBSP 정규화 후 판정.
box_nonempty(){ box_line | python3 -c '
import sys
s=sys.stdin.read()
i=s.find("❯")
rest=(s[i+1:] if i>=0 else "").strip()
sys.exit(0 if rest else 1)
' 2>/dev/null; }

wait_idle() { # $1=timeout_sec
  local t="${1:-$TIMEOUT}" i=0
  while [ "$i" -lt "$t" ]; do is_idle && return 0; sleep 1; i=$((i+1)); done
  return 1
}

# ── ★★고스트(프롬프트 제안) 차단 가드 — **빈 입력줄에 Enter 단독 전송 금지** (2026-07-27 · master 티켓)
#   근거 = Claude 공식 문서 `interactive-mode` §Prompt suggestions: 제안은 **입력창에 회색 글씨**로 뜨고
#   `Tab`/`→`로 입력창에 들어간 뒤 **`Enter`로 제출**된다.
#   ⇒ ★**입력줄이 비어 있을 때 Enter는 「제안 제출」 외에 할 수 있는 일이 없다.**
#   이 스크립트가 Return을 보내는 이유는 언제나 **우리가 방금 넣은 텍스트를 제출하기 위해서**다.
#   그 텍스트가 입력줄에 없으면 Enter에는 정당한 목적이 없고, 남는 효과는 **우리가 쓰지 않은 문장의 제출**뿐이다.
#   ★비대칭: 건너뛰면 「제출 확인」 라벨 하나를 잃을 뿐이고(상태는 landed_submit_unconfirmed로 정직하게 남는다),
#            보내면 **대상 세션에 유령 프롬프트가 제출된다** — 후자가 비가역이다. ⇒ **fail-closed.**
#   판독 지연을 흡수하려고 3회 폴링한 뒤에만 건너뛴다(단발 판독으로 끄지 않는다).
box_nonempty_of() { # $1=surface — SREF 비의존(자기종료 경로용)
  # ★R1 동일 적용: 여기에도 tail -n 30 을 썼었다 — **고치려던 결함을 가드가 그대로 물려받았다**(자기적발).
  $CYS read-screen --surface "$1" 2>/dev/null | grep '❯' | tail -1 | python3 -c '
import sys
s=sys.stdin.read()
i=s.find("❯")
sys.exit(0 if (s[i+1:] if i>=0 else "").strip() else 1)
' 2>/dev/null; }
safe_return_to() { # $1=surface → 0=Return 보냄 · 1=가드가 막음(빈 입력줄)
  local s="$1" i=1
  while [ "$i" -le 3 ]; do
    if box_nonempty_of "$s"; then
      $CYS send-key --surface "$s" Return >/dev/null 2>&1
      return 0
    fi
    i=$((i+1)); [ "$i" -le 3 ] && sleep 1
  done
  log "  가드: 3회 판독 모두 입력줄이 비어 보여 Return 미전송(surface $s) — 빈 입력줄+Enter = 프롬프트 제안 제출 경로다"
  return 1
}

# ── 대상 자기종료 (worker caller는 close 불가 → C-c×2→exit로 프로세스트리 사망) ──
self_exit() { # $1=surface (인자로 받아 SREF 비의존)
  local s="$1"
  $CYS send-key --surface "$s" C-c >/dev/null 2>&1; sleep 1
  $CYS send-key --surface "$s" C-c >/dev/null 2>&1; sleep 2
  $CYS send --surface "$s" "exit" >/dev/null 2>&1; sleep 0.6
  # ★`exit`가 입력줄에 실린 것을 확인한 뒤에만 Enter — 안 실렸으면 그 Enter는 제안을 제출한다.
  safe_return_to "$s"; sleep 1
}
# 실패 시 좀비 방지: 생성된 surface를 자기종료시키고 실패 종료
fail_cleanup() { # $1=exitcode $2=msg
  log "  실패정리: $2 → surface $SREF 자기종료(좀비 방지)"
  inbox "【경고】 spawn-worker 실패(${SREF}·role=$ROLE): $2 — 좀비 방지 위해 대상 자기종료 실행. (worker caller는 close-surface 불가 → C-c×2→exit)"
  [ -n "${SREF:-}" ] && self_exit "$SREF"
  exit "$1"
}

# ── 주입 프로토콜 (함정 a·b·d·e 내장 · 인코딩/줄바꿈/타이밍 안전) ────────────
# 검증은 '박스 상태전이'(빈→채움→빈/thinking)를 **폴링**으로 — 단발 체크는 paste 렌더 지연에
# 오탐→조기 재send→**중복주입**(실측 버그). 폴링으로 실제 미도달일 때만 1회 재send.
poll_true() { # $1=함수명 $2=최대초 → 0.5s 간격 폴링
  local fn="$1" max="${2:-8}" n=$(( ${2:-8} * 2 )) i=0
  while [ "$i" -lt "$n" ]; do "$fn" && return 0; sleep 0.5; i=$((i+1)); done
  return 1
}
box_empty_or_think() { is_thinking || ! box_nonempty; }
# ★inject 결과 3값 (2026-07-27 · master 승인 P1) — 전역으로 마지막 결과를 남긴다.
#   true                       = 제출 확인됨
#   landed_submit_unconfirmed  = **본문이 입력줄에 실린 것은 봤는데 제출을 확인 못 했다**
#   absent                     = 실린 것을 못 봤다(주입 시도조차 못 한 경우 포함)
#   ★이름이 왜 이래야 하는가: `unsubmitted`는 「제출되지 않았다」는 **사실 주장**이다. 우리가 아는 것은
#     **「제출을 확인하지 못했다」**뿐이다 — 실제로는 제출됐는데 판독만 실패했을 수 있다.
#     **관측 실패에 사실의 이름을 붙이면 다음 사람이 그 이름 위에 행동한다**(master 2026-07-27 박제).
INJECT_STATE="absent"
inject() { # $1=text  → 0=제출 확인, 1=미확인(상세는 $INJECT_STATE)
  local text="$1"
  INJECT_STATE="absent"
  wait_idle "$TIMEOUT" || { log "  주입보류: idle 미도달"; return 1; }
  # (b) ghost 초안 → Ctrl-U clear (Escape는 안 지워짐·실측). 최대 2회.
  if box_nonempty; then
    log "  ghost 초안 감지 → Ctrl-U clear"
    $CYS send-key --surface "$SREF" C-u >/dev/null 2>&1; sleep 1
    box_nonempty && { $CYS send-key --surface "$SREF" C-u >/dev/null 2>&1; sleep 1; }
  fi
  # (e) verbatim 단일인자 send + (a) 폴링 도달검증(paste 렌더 지연 흡수·중복 방지)
  $CYS send --surface "$SREF" "$text" >/dev/null 2>&1
  if ! poll_true box_nonempty 8; then
    # ★★P0 (2026-07-27 · master 승인) — **재send 직전에 반드시 비운다.**
    #   왜: 이 분기의 조건은 「본문이 안 갔다」가 아니라 **「4초 안에 화면에서 못 봤다」**이다.
    #   paste 렌더 지연·화면 stale이면 **실제로는 도달했는데** 여기로 온다. 그 상태에서 그냥 재send하면
    #   **두 본문이 이어붙는다.** 실증(2026-07-27 surface:270 첫 브리프): 4,004자 × 2 = **8,008자**가
    #   한 프롬프트로 제출됐다(두 조각 바이트 동일). 두 조각이 같은 글이라 사람 눈에는 「좀 길다」로만 보인다 —
    #   ★잔존물이 고스트였다면 **하이브리드 프롬프트**가 제출됐을 것이다(WORKER_DIRECTIVE §6-11).
    #   ⇒ 비우면 「도달했든 안 했든」 **두 경우 모두 옳아져** 이 판독에 의존할 필요가 없어진다.
    #   ★폴링 시간을 늘리는 것은 해법이 아니다 — 빈도만 줄이고 구조는 그대로다(master 박제).
    log "  폴링 후 미관측 → **입력줄 비우고** 재send 1회(이어붙기 차단)"
    $CYS send-key --surface "$SREF" C-u >/dev/null 2>&1; sleep 1
    $CYS send --surface "$SREF" "$text" >/dev/null 2>&1
    poll_true box_nonempty 8 || { log "  ⚠ 재send 후에도 미관측 — Return 안 보냄"; INJECT_STATE="absent"; return 1; }
  fi
  # 여기 도달 = **본문이 입력줄에 실린 것을 봤다.** 이후 실패는 「안 갔다」가 아니라 「제출 미확인」이다.
  INJECT_STATE="landed_submit_unconfirmed"
  # (a·★) submit: paste 직후 Return은 타이핑가드가 삼킴(F1 실측) → **settle 후 Return**(master ②).
  #   제출확인(박스 비워짐 or thinking)까지 settle→Return을 최대 3회 반복.
  local try
  for try in 1 2 3; do
    sleep "$IDLE"                                   # 타이핑가드 안정화(paste settle)
    # ★고스트 가드: 본문이 입력줄에 남아 있을 때만 Return. 비어 있으면 **이미 제출됐거나 애초에 없는 것**이고,
    #   그 상태의 Enter는 제안(prompt suggestion)을 제출하는 일밖에 하지 않는다.
    if ! safe_return_to "$SREF"; then
      # 비어 있다 = 우리 것이 이미 나갔을 가능성이 높지만 **단정하지 않는다**(§P1 명명 규율).
      poll_true box_empty_or_think 6 && { INJECT_STATE="true"; return 0; }
      log "  Return 생략(가드·입력줄 빔) — 제출 확인 못 함"
      break
    fi
    poll_true box_empty_or_think 6 && { INJECT_STATE="true"; return 0; }
    log "  Return 미반영(시도 $try) — settle 후 재시도"
  done
  # ★여기서 INJECT_STATE는 landed_submit_unconfirmed 로 남는다(absent 아님).
  #   본문은 입력줄에 있다 — **재전송하면 이어붙는다.** 경보 문구가 그것을 말해야 한다.
  log "  ⚠ 제출 미확인 — 본문은 입력줄에 실려 있다(재전송 금지 대상)"
  return 1
}

# ════════════════════════════════════════════════════════════════════════════
log "start $([ "$DRYRUN" = 1 ] && echo '(DRY-RUN)') — role=$ROLE agent=$AGENT model=$MODEL cwd=$CWD"

# 1) 프리플라이트
if [ "$DRYRUN" = 0 ]; then
  [ "$($CYS ping 2>/dev/null)" = "pong" ] || { echo "ABORT: cys 데몬 미응답(ping)"; exit 3; }
  gc="$($CYS gate-check 2>/dev/null)"; grc=$?
  if [ "$grc" = 4 ] || [ "$gc" = "paused" ]; then
    echo "ABORT: kill-switch paused — spawn 보류"; inbox "【경고】 spawn-worker: kill-switch paused 라 spawn 보류(role=$ROLE cwd=$CWD)."; exit 4
  fi
fi

# ── ★관측 probe (읽기 전용 · 2026-08-11 · TICKET=<ticket-id>) ────────────
#   왜 필요한가: self-test 는 obs_jsonl_id·obs_args_id 를 **오버라이드**해서 태운다 ⇒
#   ★**실제 관측 코드(cys list 파싱·슬러그 파생·신선도 게이트·jsonl 판독)는 한 번도 안 돈다.**
#   「한 번도 실행되지 않은 경로는 검증되지 않은 코드다」 — 오늘 적발한 결함이 정확히 그 형태였다.
#   ⇒ 라이브 노드에 대고 **실측**한다. ⛔부작용 0: spawn·주입·inbox·kill 전부 없음(출력만).
#   사용: SPAWN_WORKER_PROBE=surface:442 bash spawn-worker.sh --role probe --cwd "$HOME"
if [ -n "${SPAWN_WORKER_PROBE:-}" ]; then
  SREF="$SPAWN_WORKER_PROBE"
  inbox()        { echo "[probe] ⛔inbox 억제: $*"; }
  fail_cleanup() { echo "[probe] ⛔fail_cleanup 억제 rc=$1 msg=$2"; }
  _p="$(surf_pid)"
  # 신선도 기준선 = 그 워커 프로세스의 기동 시각(= 실전 SPAWN_STAMP 의 등가물).
  SPAWN_STAMP="$(mktemp -t spawnworker-probe)"
  # 🔴★`ps -o lstart=` 를 쓰지 마라 — **로케일 지역화**된다(실측 2026-08-11:
  #   `2026년  8월 11일 화요일 10시 40분 25초`). strptime 이 조용히 실패하고 스탬프가 「지금」으로
  #   남아 ⑴이 **전부 배제**되는데, 출력은 「jsonl 부재(첫 턴 전)」과 **구별되지 않는다.**
  #   ⇒ ★계기가 고장난 채 「정상」으로 읽힌다. **locale 무관인 `etime`(경과시간)으로 역산한다.**
  if [ -n "$_p" ]; then
    _e="$(ps -p "$_p" -o etime= 2>/dev/null | tr -d ' ')"
    if [ -n "$_e" ]; then
      python3 - "$SPAWN_STAMP" "$_e" <<'PYT'
import os, re, sys, time
m = re.match(r'^(?:(?:(\d+)-)?(\d+):)?(\d+):(\d+)$', sys.argv[2])
if m:
    d, h, mi, s = (int(x) if x else 0 for x in m.groups())
    t = time.time() - (d*86400 + h*3600 + mi*60 + s)
    os.utime(sys.argv[1], (t, t))
else:
    sys.stderr.write("[probe] ⚠ etime 파싱 실패 — 스탬프=지금(⑴ 전부 배제됨·부재와 구별 안 됨)\n")
PYT
    fi
  fi
  echo "[probe] SREF=$SREF · pid=${_p:-미검출} · 신선도 기준=$(date -r "$SPAWN_STAMP" '+%F %T')"
  echo "[probe] cwd='$(surf_cwd)'"
  echo "[probe] ⑴obs_jsonl_id = '$(obs_jsonl_id)'"
  echo "[probe] ⑵obs_args_id  = '$(obs_args_id)'"
  echo "[probe] observe_model = '$(observe_model)'"
  echo "[probe] derive_expect($AGENT) = '$(derive_expect "$AGENT")'"
  MODEL_OK=false; MODEL_GEN_CHECKED=false; STRICT_MODEL=0
  verify_model
  echo "[probe] 판정: MODEL_OK=$MODEL_OK · 실측='$ACTUAL' · 출처=$MODEL_SRC"
  rm -f "$SPAWN_STAMP"; exit 0
fi

# 2) spawn (네이티브 launch-agent 위임 · surface는 자기출력만 신뢰 · fail-closed)
SREF=""
if [ "$DRYRUN" = 1 ]; then
  echo "WOULD: cys launch-agent --role $ROLE --agent $AGENT --cwd $CWD"
  SREF="surface:<new>"
else
  # ★spawn 스탬프 — jsonl 관측⑴의 신선도 기준선. 이 시각보다 새 세션 파일만 「실물」로 인정한다.
  #   ⛔없으면 관측⑴을 포기한다(fail-closed) — 같은 폴더의 죽은 세션 모델을 실물로 오인하면
  #   ★「출처=jsonl(실물)」라벨을 단 틀린 값이 나가고, 그건 미검출보다 위험하다.
  SPAWN_STAMP="$(mktemp -t spawnworker-stamp)"
  LA="$($CYS launch-agent --role "$ROLE" --agent "$AGENT" --cwd "$CWD" 2>&1)"
  log "launch-agent out: $(printf '%s' "$LA" | tr '\n' '|')"
  # launch-agent 자기출력의 surface:N만 파싱(전역 diff 추정 금지 — 동시성 cross-talk 방지)
  SREF="$(printf '%s' "$LA" | grep -oE 'surface:[0-9]+' | tail -1)"
  if [ -z "$SREF" ]; then
    echo "FATAL: launch-agent 출력서 surface 미해석(fail-closed·추정 안함)"
    inbox "【경고】 spawn-worker: launch-agent가 surface를 안 뱉음 — 수동 'cys list' 확인 요망. out=[$(printf '%s' "$LA"|tr '\n' '|')]"
    exit 5
  fi
  log "surface = $SREF"
fi

READY=false; MODEL_OK=false; AWAKE_OK=false; BRIEF_OK=false; STATUS="partial"
MODEL_GEN_CHECKED=false; EXPECT_TOK=""   # ★세대 대조 여부·기대 표기(2026-07-25 additive)
ACTUAL=""; MODEL_SRC="미실행"            # ★실측값·출처 등급(2026-08-11 additive · 관측원 서열)

if [ "$DRYRUN" = 1 ]; then
  echo "WOULD: 준비폴링→모델검증→각성넛지→브리프주입→반환"; STATUS="dry-run"
else
  # 3) 준비 폴링 — 실패 시 좀비 방지 정리
  log "준비 폴링(max ${TIMEOUT}s)…"
  if wait_idle "$TIMEOUT"; then READY=true; log "  ready(idle)"; else
    fail_cleanup 7 "준비 타임아웃(${TIMEOUT}s) — 워커 미기동/행"
  fi

  # 4) 모델 실측검증 (footer) — ★세대까지 대조(2026-07-25 · 지시4 채택안②)
  verify_model
  # 5) 제목: ★2026-07-27 정정 — 아래 구주석은 **거짓이었다**.
  #    구주석: 「cys 사후 set-title 프리미티브 부재(실측)」 ← ⛔틀림. worker@297 규명(판정문
  #    <cys 소스 체크아웃>/docs/verdict-pane-title-numbering-2026-07-27.md):
  #      · RPC **`surface.rename` 실재**(handlers.rs:1750) — 설치본 데몬 무변경 probe로 디스패치 확인
  #        (빈 params→invalid_params / 미지 메서드→method_not_found 로 갈림 = 대조군 있는 실험).
  #      · **`cys new-surface --title` 도 존재**(생성 시 지정). 없는 것은 **CLI 사후 서브커맨드**뿐이고
  #        GUI 는 이미 그 RPC 를 쓴다(src-tauri/main.rs:2067 ← ui/src/main.ts:1994).
  #    ★교훈: 「CLI 에 없다」를 「기능이 없다」로 적었다. **표면(CLI)의 부재를 능력의 부재로 승격**한 것이고,
  #      그 거짓 주석을 근거로 master 가 오너께 「cys 는 제목 변경 불가」라고 보고했다(2026-07-27).
  #      + strings 로 못 찾은 것도 부재의 증거가 아니다 — rustc 가 16바이트 이하 리터럴을 즉값으로
  #      최적화해 `surface.rename`·`surface.resize` 는 strings 0건인데 정상 디스패치한다.
  #    현재 --title 은 여전히 무동작(래퍼 미배선). 번호화 구현안은 판정문 §4(A/B/C) 참조.
  [ -n "$TITLE" ] && log "  --title='$TITLE' 은 이 래퍼가 아직 배선하지 않았다(무동작). ⚠cys 자체는 지원한다(new-surface --title · RPC surface.rename) — 판정문 §4 참조."
  # 5-1) ★페인 제목 번호화 — 오너 절대 규칙(2026-07-27): 제목 = 「번호 · 역할특성」.
  #      구현 = worker@297 (~/.cys/pack/bin/javis_panetitle.py · pack-ownership=custom 실측 = 업데이트 불가침).
  #      멱등: 이미 규칙에 맞으면 rename RPC 를 아예 호출하지 않는다(plan/apply 공통).
  #      ⚠fail-open(제목 실패로 spawn 을 죽이지 않는다) — 단 ★조용히 넘기지 않고 반드시 로그에 남긴다.
  #        (오늘의 규율: 실패를 fail-open 하려면 그 실패가 보여야 한다.)
  if [ -n "${SREF:-}" ]; then
    _pt_sid="${SREF#surface:}"
    if _pt_out=$(python3 "$HOME/.cys/pack/bin/javis_panetitle.py" apply --surface "${_pt_sid}" --json 2>&1); then
      log "  제목 규칙 적용 OK (surface ${_pt_sid})"
    else
      log "  ⚠제목 규칙 적용 실패 — spawn 은 계속한다. 수동 복구: python3 ~/.cys/pack/bin/javis_panetitle.py apply --surface ${_pt_sid}"
      log "     사유: ${_pt_out}"
    fi
  fi

  # 6) 각성 넛지 — ★결정론(launch-agent 디렉티브의 F1/F2 비결정성 우회). 항상 1회 주입(idempotent:
  #    워커가 WORKER_DIRECTIVE.md 재독). 설계 §6과 일치(항상주입=결정론 선택). launch-agent 주입과의
  #    중복은 파일 재독이라 무해. --no-awaken 이면 skip.
  if [ "$AWAKEN" = 1 ]; then
    AWK="WORKER_DIRECTIVE 각성: ~/.cys/pack/directives/WORKER_DIRECTIVE.md 전문을 지금 Read로 읽고 내면화하라(특히 2조 전 기능 오케스트레이션·7-1 push 규율). 모든 보고·질문·경고·막힘은 공용 인박스 ~/.cys/cmux-inbox.md 에 append(형식 [<role>@<surface> → cmux master] ISO시각 내용). node CLI(codex·agy) 호출 시 NODE_OPTIONS 오염 가능성 있으니 서브셸에서 'unset NODE_OPTIONS' 후 호출하라. 그 뒤 작업 브리프를 기다려라."
    log "각성 넛지 주입…"
    if inject "$AWK"; then AWAKE_OK=true; log "  각성 주입 도달확인"; else log "  ⚠ 각성 주입 미검증"; fi
  fi

  # 7) 브리프 주입
  if [ -n "$BRIEF_FILE" ]; then
    log "브리프 주입 ($BRIEF_FILE)…"
    BRIEF="$(cat "$BRIEF_FILE")"
    if inject "$BRIEF"; then BRIEF_OK=true; log "  브리프 제출 확인"; else log "  ⚠ 브리프 $INJECT_STATE"; fi
    BRIEF_STATE="$INJECT_STATE"
    # ★★P2 (2026-07-27 · master 승인) — **브리프는 원장에 남긴다.**
    #   왜: spawn 경로는 master-send.sh 를 우회해 nonce·원장이 둘 다 없었다. 실측 — surface:270 의 첫
    #   브리프는 12:29 제출인데 원장의 그 surface 최초 기록은 13:02 였다.
    #   ⇒ **워커 생애에서 가장 중요한 지시가 원장 밖**에 있었다. 「원장에 없으면 고스트」 판정의 구멍이다.
    #   면제는 **launch-agent 내장 각성 프롬프트 1건에 한정**한다(브리프는 면제 대상 아님).
    ledger_brief "$BRIEF" "$BRIEF_STATE"
  fi

  # 종합 상태
  if [ "$READY" = true ] && [ "$MODEL_OK" = true ] \
     && { [ "$AWAKEN" = 0 ] || [ "$AWAKE_OK" = true ]; } \
     && { [ -z "$BRIEF_FILE" ] || [ "$BRIEF_OK" = true ]; }; then STATUS="ok"; fi

  # partial(워커는 살아있으나 각성/브리프 미확인) → master 교착 방지 인박스 경고(자동 kill 안 함: master salvage 여지)
  # ★P1: 경보 문구가 **무엇을 하지 말아야 하는지**를 말해야 한다. 구판은 상태 구분 없이
  #   "브리프 재전송 요망"만 찍었는데, 본문이 이미 입력줄에 실린 경우 그 지시는 **이어붙기를 지시**한다.
  if [ "$STATUS" != "ok" ]; then
    if [ "${BRIEF_STATE:-}" = "landed_submit_unconfirmed" ]; then
      BRIEF_ADVICE="⛔브리프 재전송 금지 — 본문이 입력줄에 실려 있다. 제출 여부는 확인 못 했다(제출됐는데 판독만 실패했을 수 있다). Return 만 보내고 다시 확인하거나 워커에게 직접 물어라. 재전송하면 이어붙는다."
    elif [ -n "$BRIEF_FILE" ] && [ "${BRIEF_STATE:-absent}" = "absent" ]; then
      BRIEF_ADVICE="브리프가 입력줄에 실린 것을 못 봤다 — 재전송 가능."
    else
      BRIEF_ADVICE="브리프 지정 없음."
    fi
    inbox "【경고】 spawn-worker partial(${SREF}·role=$ROLE): ready=$READY model=$MODEL_OK awaken=$AWAKE_OK brief=${BRIEF_STATE:-n/a}. 워커는 살아있음(자동 종료 안 함). ${BRIEF_ADVICE}"
  fi
fi

# 8) 반환
if [ "$JSON" = 1 ]; then
  printf '{"surface_ref":"%s","role":"%s","agent":"%s","model":"%s","title_requested":"%s","ready":%s,"model_verified":%s,"model_expected":"%s","model_generation_checked":%s,"awaken_verified":%s,"brief_injected":%s,"brief_state":"%s","status":"%s"}\n' \
    "$SREF" "$ROLE" "$AGENT" "$MODEL" "$TITLE" "$READY" "$MODEL_OK" "$EXPECT_TOK" "$MODEL_GEN_CHECKED" "$AWAKE_OK" "$BRIEF_OK" "${BRIEF_STATE:-n/a}" "$STATUS"
else
  echo "───────────────────────────────────────────────"
  echo " spawn-worker 결과: $STATUS"
  echo "  surface       = $SREF"
  echo "  role / model  = $ROLE / $MODEL($AGENT)"
  echo "  ready         = $READY   model_verified = $MODEL_OK"
  echo "  모델 기대값   = ${EXPECT_TOK:-(파생불가·계열검증 폴백)}   세대대조 = $MODEL_GEN_CHECKED"
  echo "  awaken        = $AWAKE_OK (요청 awaken=$AWAKEN)"
  echo "  brief_injected= $BRIEF_OK  brief_state = ${BRIEF_STATE:-n/a} $( [ -n "$BRIEF_FILE" ] && echo "($BRIEF_FILE)" )"
  echo "  정리(별건)    = worker caller는 close 불가 → self_exit(C-c×2→exit) 또는 특권 caller"
  echo "───────────────────────────────────────────────"
fi
[ "$STATUS" = "ok" ] || [ "$STATUS" = "dry-run" ]
