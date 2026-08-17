#!/usr/bin/env bash
# master-send.sh — master 발신 **원장 래퍼**. 전송과 기록이 **한 동작**이다.
#
# 왜 만드는가(2026-07-26 04:1x · master 지시):
#   워커 입력줄에 master 서식 텍스트가 보일 때 **⑴미제출인지 ⑵고스트인지 구별할 방법이 없었다.**
#   CSO에겐 대조할 **발신 원장이 없기 때문**이다. 실제로 04:09 CSO가 254의 고스트를
#   "master 발신·미도달"로 단정해 오보했다. **원인은 판단이 아니라 원장 부재였다.**
#   → 이 래퍼로 보내면 **보낸 사실이 자동으로 남는다.** 기억해서 기록하는 설계는 실패한다
#     (오늘 밤 "장치는 있는데 경로를 안 탄다"를 아홉 번 봤다). **규율이 아니라 구조로 만든다.**
#
# 하는 일(순서 고정):
#   ⑴입력줄 실측 → ⑵Ctrl-U로 비움(이어붙기 차단) → ⑶비었는지 실측 → ⑷본문 전송
#   → ⑸입력줄에 실렸는지 실측 → ⑹Return → ⑺**입력줄이 비었는지로 제출 판정**
#   → ⑻원장에 append(성공/실패 무관·시도 자체를 남긴다)
#
# 사용법:
#   master-send.sh <surface-ref> "<본문>"           예) master-send.sh surface:254 "지시…"
#   master-send.sh <surface-ref> -                  (본문을 stdin으로)
#   master-send.sh --cycle <surface-ref>            ★순환(/clear) — 절차·판정·기록까지 한 동작
#   MSEND_NO_RETURN=1 …    Return 없이 입력줄까지만
#   MSEND_DRYRUN=1 …       읽기만·무접촉(원장 기록도 안 함) — 파괴적 분기 시험용
#   MSEND_FORCE_CLEAR=1 …  보호 페인 입력줄이 비어있지 않아도 강행
#   MSEND_JARVIS_WHO=<경로> jarvis-who 대체(시험용). 기본 ~/.claude/channels/jarvis-who.sh
#   MSEND_TARGET_CWD=<경로> 순환 판정용 대상 페인 cwd를 직접 지정(시험용·해석 우회)
#   MSEND_PROJECTS_DIR=<경로> cmux 대상의 세션 저장 루트. 기본 ~/.claude/projects
#   MSEND_CYCLE_TEMPLATE=<경로> 순환 후 복원 포인터 본문. 기본 ~/.claude/channels/cycle-restore-template.md
#   MSEND_NO_REINJECT=1  순환 후 복원 재주입을 끈다(시험용)
#
# 첫 인자: `surface:<숫자>` **또는 역할이름**(cso·worker-1…). 역할이름은 jarvis-who로 해석되고,
#   해석에 실패하면 **보내지 않고 exit 4**로 죽는다 — 원장에도 남기지 않는다(발신이 아니므로).
#   ★exit 코드: 2=사용법·형식 오류 · 3=master 입력줄 보호 게이트 · 4=인자 오용(호출 오류)
#
# ★기계 소산 표식(nonce): 본문 전송에는 `[master#<6hex>]`가 **자동으로** 붙고 원장에 남는다.
#   ∴ **접두 없음 = 우회 또는 고스트**가 성립한다(master가 기억할 필요가 없다).
#   고정 표식은 고스트가 문맥에서 베낀다 → **1회용 난수 + 본문 해시 결속**으로 위조를 드러낸다.
#
# 원장: ~/.claude/channels/.master-send-ledger.jsonl (JSONL·append-only)
#   ★첫 줄에 ledger_start를 기록한다. **그 시각 이전은 소급 판정 불가** —
#   "원장에 없으니 고스트"는 **ledger_start 이후에만** 성립한다.
set -u

CH="${JARVIS_CHANNELS:-${HOME}/.claude/channels}"   # 이 스크립트 묶음이 설치된 디렉터리
LEDGER="${MSEND_LEDGER:-${CH}/.master-send-ledger.jsonl}"
CYS="${MSEND_CYS:-$(command -v cys 2>/dev/null || echo /usr/local/bin/cys)}"
CMUX="${MSEND_CMUX:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
SETTLE="${MSEND_SETTLE:-2}"     # paste 착지 대기(타이핑가드가 조기 Return을 삼킨다)

die() { printf '%s\n' "ERR: $*" >&2; exit 2; }
[ $# -ge 2 ] || die "사용법: $0 <surface-ref> \"<본문>\" | <surface-ref> - | --cycle <surface-ref>"

# ── ★`--cycle` 서브커맨드 (2026-07-26 06:0x · master 지시 1) ──────────────────
#   순환을 **본문 전송과 같은 문**으로 넣는다. master가 두 번 연속 손으로 보내 원장에 빈칸이 났고,
#   그 대가로 **고스트 판별기가 무력화**됐다(05:57 실증). ★규율로 두 번 실패했으니 구조로 옮긴다.
CYCLE_MODE=0
if [ "$1" = "--cycle" ]; then
  CYCLE_MODE=1; shift
  [ $# -ge 1 ] || die "사용법: $0 --cycle <surface-ref>"
  SURF="$1"; shift
  BODY="/clear"
else
  SURF="$1"; shift
  BODY="$*"
  [ "${BODY}" = "-" ] && BODY="$(cat)"
fi
[ -n "${BODY}" ] || die "본문이 비었다"

# ── ★★인자 오용 게이트 (2026-07-27 · master 지시 · worker-3 구현) ──────────────
#   증상: master가 `master-send.sh cso "본문"`으로 불렀다. 이 래퍼는 첫 인자를 **surface-ref로만**
#   받고 역할이름을 해석하지 않아 `cmux send --surface cso`가 rc=1로 죽었고, 결과가 **일반
#   `send_failed`** 로 나왔다(원장 실측: surface="cso" 2건).
#   🔴왜 심각한가: master도 CSO도 그 결과를 **「래퍼/채널 고장」으로 오독**했고, 그 오독을 근거로
#   **고스트 판정 규칙을 느슨하게 바꿀 뻔했다**("고장 기간이니 무표식을 고스트로 보지 마라").
#   ⇒ ★**호출 오류가 탐지기의 감도를 낮추는 방향으로 전파됐다.** 실패는 조용하면 안 되고,
#     **「틀린 이름을 댄 실패」가 「고장」처럼 보이면 더 나쁘다.** → 여기서 갈라 죽인다.
#   ⚠원장에 남기지 않는다 — **안 보낸 것을 원장에 남기면 「원장=발신 사실」이 깨진다.**
#   ★위치: `--cycle`과 본문 전송이 **합류한 뒤**다. 두 경로가 같은 게이트를 탄다(브리프 ⑷).
JARVIS_WHO="${MSEND_JARVIS_WHO:-${CH}/jarvis-who.sh}"
# ★엄격 판정 — `surface:2abc`·`surface:`·`surface:-1`을 통과시키면 게이트가 없는 것과 같다.
#   `case` 글롭(`surface:[0-9]*`)은 뒤에 무엇이 붙어도 통과하므로 정규식으로 못박는다.
is_surface_ref() { printf '%s' "$1" | grep -qE '^surface:[0-9]+$'; }

if ! is_surface_ref "${SURF}"; then
  WHO_RAW=""; WHO_RC=0
  if [ -x "${JARVIS_WHO}" ]; then
    WHO_RAW="$("${JARVIS_WHO}" "${SURF}" 2>&1)" || WHO_RC=$?
  else
    WHO_RC=127; WHO_RAW="실행 불가(파일 없음 또는 실행권한 없음): ${JARVIS_WHO}"
  fi
  # jarvis-who는 성공 시 **마지막 줄에 surface ref만** 낸다(경고가 앞에 붙을 수 있어 tail -1).
  WHO_REF="$(printf '%s' "${WHO_RAW}" | tail -n1 | tr -d '[:space:]')"
  if [ "${WHO_RC}" = "0" ] && is_surface_ref "${WHO_REF}"; then
    printf '%s\n' "역할해석: '${SURF}' → ${WHO_REF} (${JARVIS_WHO})" >&2
    SURF="${WHO_REF}"
  else
    # ★T1-c가 잡은 것: 초판은 **모든 실패에** "이건 채널 고장이 아니라 호출 오류다"를 찍었다.
    #   그런데 jarvis-who rc=3은 **실제로 cmux가 안 잡히는 상태**다 — 그때 그 문장은 거짓이고,
    #   ★**「고장을 호출 오류로 오독」하는 정반대 방향의 같은 병**을 새로 만든다.
    #   ⇒ 원인을 **분류해서** 말한다. 뭉뚱그린 단정은 그 자체가 이 사고의 원인이었다.
    case "${WHO_RC}" in
      2)   GCLASS="caller_error"
           GLINE="★**이건 채널 고장이 아니라 호출 오류다.** jarvis-who가 모르는 이름이다 — 인자를 고쳐서 다시 불러라." ;;
      0)   GCLASS="resolver_contract_violation"
           GLINE="★**이건 채널 고장이 아니다.** jarvis-who가 rc=0인데 surface:<숫자>를 내지 않았다(해석기 계약 위반)." ;;
      3)   GCLASS="infra_cmux_unreachable"
           GLINE="★**이건 호출 오류가 아니라 배선 장애다** — cmux 제어소켓에 못 닿는다. 인자를 바꿔도 안 풀린다. 배선을 고쳐라." ;;
      127) GCLASS="resolver_missing"
           GLINE="★**이건 호출 오류가 아니라 배선 장애다** — jarvis-who 자체가 없거나 실행 불가다." ;;
      5)   GCLASS="target_not_live"
           GLINE="★**이건 호출 오류가 아니라 대상 부재다** — 그 역할의 cwd로 도는 살아있는 페인이 없다." ;;
      6)   GCLASS="target_ambiguous"
           GLINE="★**이건 호출 오류가 아니라 대상 모호다** — cwd 후보가 여럿이고 탭 제목으로 못 갈랐다. surface:<숫자>로 직접 지정해라." ;;
      *)   GCLASS="resolve_failed"
           GLINE="★원인 미분류(jarvis-who rc=${WHO_RC}). 아래 출력 원문을 보고 판단해라 — **추정으로 메우지 마라.**" ;;
    esac
    printf '%s\n' "ERR: **첫 인자가 surface-ref도 아니고 역할 해석도 실패했다 — 보내지 않고 중단한다.**" >&2
    printf '%s\n' "     받은 값        : $(printf '%s' "${SURF}" | sed -n l)" >&2
    printf '%s\n' "     기대 형식      : surface:<숫자>  (예: surface:2)  또는 jarvis-who가 아는 역할이름" >&2
    printf '%s\n' "     jarvis-who     : ${JARVIS_WHO} (rc=${WHO_RC})" >&2
    printf '%s\n' "     jarvis-who 출력: $(printf '%s' "${WHO_RAW}" | tr '\n' '|')" >&2
    printf '%s\n' "     분류           : MSEND_GATE_CLASS=${GCLASS}" >&2
    printf '%s\n' "     ${GLINE}" >&2
    printf '%s\n' "     ⚠어느 경우든 **일반 send_failed로 보이지 않게** 여기서 죽었다. 이 실패를 「래퍼/채널이 죽었다」로" >&2
    printf '%s\n' "       뭉뚱그려 읽지 마라 — 그 오독이 고스트 판정 규칙을 느슨하게 만든다(2026-07-27 실사고)." >&2
    printf '%s\n' "     ⚠원장에 기록하지 않았다(보낸 것이 없으므로). 원장의 빈칸이 아니라 **애초에 발신이 아니다.**" >&2
    exit 4
  fi
fi

# ── ★슬래시 명령(순환 포함) 지원 (2026-07-26 05:2x · master 지시) ────────────────
#   왜: master가 254 순환을 **생 `cys send "/clear"`로 손수** 보내 **원장에 빈칸**이 생겼다.
#   원장은 「없으면 고스트」의 근거인데 **우회 경로가 있으면 그 판정이 성립하지 않는다.**
#   ★**순환도 전송이다.** 그러니 같은 문에 넣는다 — 기억이 아니라 구조로.
KIND="body"
[ "${CYCLE_MODE}" = "1" ] && KIND="cycle"
# ★의도는 **다듬은 값**으로 판정한다(T1이 잡은 것): `" /clear"`처럼 앞에 공백이 붙으면
#   `case /*` 가 안 걸려 **조용히 평문으로 나가고 순환은 일어나지 않는다.** 실패가 조용하면 안 된다.
BODY_TRIM="$(printf '%s' "${BODY}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [ "${BODY_TRIM}" != "${BODY}" ] && [ "${BODY_TRIM#/}" != "${BODY_TRIM}" ] \
   && [[ "${BODY}" != *$'\n'* ]]; then
  die "슬래시 명령으로 보이는데 앞뒤 공백이 있다(그대로 보내면 평문이 된다): $(printf '%s' "${BODY}" | sed -n l)"
fi
# ⚠T-N4가 잡은 것: 이 `case`가 `--cycle`이 세운 `KIND=cycle`을 **`slash`로 덮어썼다.**
#   원장에 `kind=cycle`이 안 남으면 「순환을 래퍼로 보냈다」를 원장에서 셀 수 없다 —
#   ★**표식을 만들어 놓고 그 표식이 기록에 안 남는** 형태다. 자동 판별은 cycle이 아닐 때만 돈다.
if [ "${CYCLE_MODE}" = "0" ]; then
  case "${BODY}" in
    # ⚠`grep -q $'\n'`는 **항상 참**이다(개행이 패턴 구분자가 돼 빈 패턴이 된다).
    #   초판이 그 관용구를 써서 슬래시 판정이 **한 번도 안 탔다** — T2가 잡았다. `[[ ]]`로 고친다.
    /*) if [[ "${BODY}" == *$'\n'* ]]; then KIND="body"; else KIND="slash"; fi ;;
  esac
fi
# ★정확성 게이트: 슬래시 명령은 **한 글자만 어긋나도 다른 일**을 한다(선행 공백이면 평문으로 제출된다).
#   `sed -n l`과 같은 검사를 값에 직접 건다 — 눈으로 보는 확인은 확인이 아니다.
if [ "${KIND}" = "slash" ] || [ "${KIND}" = "cycle" ]; then
  case "${BODY}" in
    " "*|*" ") die "슬래시 명령에 선행/후행 공백이 있다: $(printf '%s' "${BODY}" | sed -n l)" ;;
  esac
  printf '%s' "${BODY}" | grep -qE '^/[A-Za-z][A-Za-z0-9_-]*( .*)?$' \
    || die "슬래시 명령 형식이 아니다: $(printf '%s' "${BODY}" | sed -n l)"
fi

# ── ★★파괴적 전송 앞의 입력줄 보호 게이트 (CSO 추가 · 오늘 밤 실사고에서 도출) ──────
#   현행 래퍼는 **무조건 Ctrl-U로 비운다.** 워커 입력줄의 고스트에는 옳다.
#   ★그러나 **master 페인에는 오너이 직접 타이핑하신다.** 05:21 실측:
#     `❯ 할루시네이션을 궁극적으로 0까지 수렴하는 것을 목표로 엄청\난 시간과 토큰을…`(미완성·타이핑 중)
#   그 상태에서 이 래퍼를 master 페인에 쓰면 **오너 문장이 조용히 지워진다.**
#   → **master 페인 + 입력줄 비어있지 않음 = 중단**. 강행은 MSEND_FORCE_CLEAR=1을 명시할 때만.
#   ★게이트는 발신자보다 강하다(2026-07-26 박제). 지우는 것은 되돌릴 수 없다.
#   ★MSEND_MASTER_REF — **게이트를 시험할 수 있게** 하는 훅. 이게 없으면 게이트를 태우려면
#     오너이 실제로 타이핑 중일 때를 기다려야 하고, 그러면 **가장 중요한 분기가 영원히 미검증**으로 남는다.
MASTER_REF="${MSEND_MASTER_REF:-$(python3 -c 'import json;print(json.load(open("'"${HOME}"'/.cmux_master_surface"))["surface_ref"])' 2>/dev/null || echo "")}"

# ── 원장 초기화(최초 1회) — 시작 시각을 명시해야 소급 오판을 막는다 ──────────────
if [ ! -f "${LEDGER}" ]; then
  printf '{"type":"ledger_start","ts":"%s","note":"이 시각 이전 발신은 원장에 없다 — 소급 판정 불가. 이후에만 「원장에 없음 = 고스트」가 성립한다.","limits":["★이 원장은 이 래퍼를 거친 발신만 담는다. 손으로 보낸 cys/cmux send는 여기 없다 — 실제로 2026-07-26 05:19 master가 254 순환 /clear를 생 명령으로 보내 빈칸이 생겼다.","∴ 「원장에 없음 = 고스트」는 **래퍼를 100%% 거쳤을 때만** 성립한다. 부분 원장은 원장이 아니다.","순환(/clear)도 전송이다 — kind=cycle/slash로 이 원장에 남는다(2026-07-26 05:2x부터).","본문 전송에는 nonce 표식 `[master#<6hex>]`가 자동으로 붙고 원장 nonce 필드와 짝을 이룬다. 초안의 nonce가 원장에 없거나 본문 해시와 안 맞으면 우회 또는 고스트다.","순환 직후에는 세션 파일이 바뀐다. 구세션에 제출된 것을 신세션 jsonl에서 찾으면 항상 음성이다."]}\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "${LEDGER}"
fi

# ── ★백엔드 라우팅(2026-07-26 04:2x · master 지적 ②) ──────────────────────────
#   래퍼가 cys 전용이라 cmux 페인(master·cso)에 보내면 send_failed가 났다.
#   판별 = **cys list에 그 ref가 있으면 cys, 없으면 cmux**. 비우기 방식도 갈린다:
#   cys=`send-key C-u`(실측 작동) · cmux=**`send`가 입력줄을 대체**(cmux엔 C-u가 없다·Unknown key).
BACKEND="cmux"
if "${CYS}" list 2>/dev/null | awk '{print $1}' | grep -qx "${SURF}"; then BACKEND="cys"; fi
[ -n "${MSEND_FORCE_BACKEND:-}" ] && BACKEND="${MSEND_FORCE_BACKEND}"

bk_read()  { if [ "${BACKEND}" = "cys" ]; then "${CYS}" read-screen --surface "${SURF}" 2>/dev/null
             else "${CMUX}" read-screen --surface "${SURF}" 2>/dev/null; fi; }
bk_send()  { if [ "${BACKEND}" = "cys" ]; then "${CYS}" send --surface "${SURF}" "$1" >/dev/null 2>&1
             else "${CMUX}" send --surface "${SURF}" "$1" >/dev/null 2>&1; fi; }
bk_key()   { if [ "${BACKEND}" = "cys" ]; then "${CYS}" send-key --surface "${SURF}" "$1" >/dev/null 2>&1
             else "${CMUX}" send-key --surface "${SURF}" "$1" >/dev/null 2>&1; fi; }
# ★실측(04:4x·일회용 cmux 페인): `cmux send ""` = **Error: send requires text**(비우기 실패),
#   `send-key C-u` = **Unknown key**, **`ctrl+u`는 작동**(입력줄 실제로 비워짐). cys는 `C-u`.
bk_clear() { if [ "${BACKEND}" = "cys" ]; then bk_key C-u
             else bk_key ctrl+u; fi; }

# ★MSEND_DRYRUN=1 — **읽기만 하고 아무것도 바꾸지 않는다**(비우기·전송·Return 전부 무동작).
#   왜 필요한가: 이 래퍼의 가장 중요한 분기는 **파괴적 경로의 게이트**인데, 그걸 시험하려고
#   실제로 보내면 시험이 사고가 된다. 오늘 밤 규율 그대로 — **검증하려고 규칙을 어기지 않는다.**
#   ⚠dry-run은 **원장에 기록하지 않는다.** 안 보낸 것을 원장에 남기면 「원장=발신 사실」이 깨진다.
if [ "${MSEND_DRYRUN:-0}" = "1" ]; then
  bk_send()  { printf 'DRYRUN send: %s\n' "${1:0:60}" >&2; return 0; }
  bk_key()   { printf 'DRYRUN key: %s\n' "$1" >&2; return 0; }
  bk_clear() { printf 'DRYRUN clear(Ctrl-U)\n' >&2; return 0; }
fi

# ── 입력줄 판독(NBSP·공백 처리는 python으로) ───────────────────────────────────
read_input_line() {   # → 입력줄 내용(비었으면 빈 문자열)
  bk_read | python3 -c '
import sys
line=""
for ln in sys.stdin.read().splitlines():
    s=ln.strip()
    if s.startswith("❯"):
        d=s[1:].strip().replace(" "," ").strip()
        # ★입력줄 = **마지막 `❯` 줄**. 큐 마커면 "초안 없음"이다(2026-07-26 05:3x 실측 교정).
        #   구판은 큐 마커 줄에서 갱신을 건너뛰어 **위쪽에 에코된 이미 제출된 프롬프트**로 되돌아갔다.
        #   실증(253): 마지막 ❯ = `Press up to edit queued messages`인데 판독 결과는 그 위의
        #   `[master] ★★오너 지시 = 완전판 4차 발행…`(에코)이었다.
        #   → ⑴보호 게이트가 헛발화하고 ⑵`POST`가 안 비어 **제출=no 거짓 음성**이 난다(중복 전송의 씨앗).
        # 🔴★3상태 개정(master 승인 2026-07-28): 「큐 마커」와 「진짜 빈 줄」을 갈랐다.
        #   구판은 둘 다 ""를 반환 → 가드가 「빈 입력줄」로 읽어 Return을 막았다.
        #   실측: cmux 제출 판정 **61% 실패**(성공7/실패12·실패 전건 landed_seen=False).
        #   ★큐 마커 = **본문이 이미 큐에 안전하게 들어갔다** = 제출된 것과 같다 → Return 불요.
        line="\x00QUEUED" if d == "Press up to edit queued messages" else d
print(line)
' 2>/dev/null
}

# 🔴★4상태 개정(2026-08-14 master · 오너 승인 유지보수 묶음 · CSO 페인 빔 오판 4회 실증):
#   긴 접힘 본문이 입력 박스를 넘치면 **`❯` 첫 행이 표시창 밖으로 밀려** 판독에 ❯ 줄이 아예 없다.
#   구판은 그것을 「빈 입력줄」과 동일 취급 → Return 스킵 → 초안 방치(제출=not_attempted).
#   ⇒ 「❯ 미관측(NOSEEN)」을 「❯ 실측·비어 있음」과 갈랐다. NOSEEN일 때는 **이번 발신의
#   nonce가 화면에 실재할 때만** Return 허용 — nonce는 발신마다 난수라 고스트·에코(구 nonce)가
#   가질 수 없는 증거다. ⛔빈 ❯ 실측 시 Return 차단은 현행 그대로(고스트 방벽 무손상 —
#   자동 제출로 박스가 빈 경우는 ❯가 보이므로 이 경로에 안 들어온다).
read_input_line_v2() {
  bk_read | python3 -c '
import sys
line=""; seen=False
for ln in sys.stdin.read().splitlines():
    s=ln.strip()
    if s.startswith("❯"):
        seen=True
        d=s[1:].strip()
        line="\x00QUEUED" if d == "Press up to edit queued messages" else d
if not seen: line="\x00NOSEEN"
print(line)
' 2>/dev/null
}
marker_on_screen() { bk_read | grep -qF "[master#${NONCE}]"; }

# ★★cmux 종단 결함의 본체(04:4x 실측): **`cmux send`는 기존 입력줄에 덧붙이고, 개행을 Enter로 해석**한다.
#   실증: `LINE-ONE\nLINE-TWO` 전송 → 앞 잔존물+LINE-ONE이 **실행**되고 LINE-TWO만 남았다.
#   → 여러 줄 본문을 그대로 보내면 **조각 제출**된다(master 04:29 전송이 도달 0이었던 이유).
#   대책: cmux 백엔드에서는 **개행을 `⏎ `로 접어 단일행으로** 보낸다(내용 보존·조각화 차단).
#   cys는 bracketed-paste로 여러 줄이 원자 착지하므로 변환하지 않는다.
MULTILINE_FOLDED="no"
# ⚠기존 결함 교정(2026-07-26 05:3x · CSO): 여기도 `grep -q $'\n'`을 썼다 — **항상 참**이라
#   cmux 백엔드에서는 **모든 본문이 접기 분기를 탔다**(단일행이라 바꿀 개행이 없어 무해했을 뿐,
#   `multiline_folded=yes`는 거짓 기록이었다). 조건이 늘 참이면 그 분기는 **시험된 적이 없다.**
if [ "${BACKEND}" = "cmux" ] && [[ "${BODY}" == *$'\n'* ]]; then
  BODY="$(printf '%s' "${BODY}" | python3 -c 'import sys;print(" ⏎ ".join(sys.stdin.read().splitlines()))')"
  MULTILINE_FOLDED="yes"
fi

# ── ★★기계 소산 표식(nonce 접두) — master 지시 2 (2026-07-26 06:0x) ────────────
#   목적: **접두 없음 = 우회 또는 고스트**가 성립하게 만든다. 그러면 master가 기억할 필요가 없다.
#   ★그런데 **고정 문자열이면 곧 위조된다.** 고스트는 워커 자기 컨텍스트에서 파생되고,
#     그 컨텍스트에는 **접두가 붙은 과거 프롬프트가 들어 있다** → 고스트가 `[master]`를 그대로 베낀다.
#     (오늘 밤 실제로 `[master] …` 형태의 고스트를 여러 건 봤다.)
#   → 표식을 **1회용 난수 + 본문 결속**으로 만든다:
#       ⑴ nonce는 매 전송 새로 뽑는다(문맥에서 예측 불가)
#       ⑵ 원장에 `nonce ↔ body_sha256 ↔ surface`를 함께 남긴다
#       ⑶ 검증 = 초안의 nonce가 원장에 있고 **그 본문 해시·수신 페인과 맞는가**
#     ∴ 과거 nonce를 베끼면 **본문이 안 맞아 들통난다**(재현 고스트 탐지와 같은 원리).
#   ⚠슬래시/순환에는 붙이지 않는다 — `/clear`는 **한 글자만 달라도 다른 일**이 된다.
NONCE=""
if [ "${KIND}" = "body" ] && [ "${MSEND_NO_TAG:-0}" != "1" ]; then
  NONCE="$(openssl rand -hex 3 2>/dev/null || od -An -tx1 -N3 /dev/urandom | tr -d ' \n')"
  [ -n "${NONCE}" ] || die "nonce 생성 실패 — 표식 없이 보내지 않는다(무표식 발신은 우회와 구별되지 않는다)"
  # 손으로 친 `[master]`가 앞에 있으면 **그 자리를 표식으로 대체**한다(이중 접두 방지).
  case "${BODY}" in
    "[master]"*) BODY="[master#${NONCE}]${BODY#\[master\]}" ;;
    *)           BODY="[master#${NONCE}] ${BODY}" ;;
  esac
fi

TS_START="$(date '+%Y-%m-%dT%H:%M:%S%z')"
PRE="$(read_input_line)"

# ★게이트 발효 지점 — 비우기(bk_clear) **앞**이어야 의미가 있다. 뒤에 두면 이미 지운 뒤다.
if [ -n "${PRE}" ] && [ -n "${MASTER_REF}" ] && [ "${SURF}" = "${MASTER_REF}" ] \
   && [ "${MSEND_FORCE_CLEAR:-0}" != "1" ]; then
  printf '%s\n' "ERR: **master 페인 입력줄에 텍스트가 있다 — 지우지 않고 중단한다.**" >&2
  printf '%s\n' "     실측: $(printf '%s' "${PRE}" | sed -n l)" >&2
  printf '%s\n' "     ★오너이 타이핑 중일 수 있다. 원장으로는 판정 불가다(오너 타이핑은 어디에도 안 남는다)." >&2
  printf '%s\n' "     확인 후 강행하려면 MSEND_FORCE_CLEAR=1 로 다시 실행해라." >&2
  python3 - "$LEDGER" "$TS_START" "$SURF" "$PRE" "$BODY" <<'PY'
import json,sys
led,ts,surf,pre,body = sys.argv[1:6]
rec={"type":"send_aborted","ts":ts,"surface":surf,"reason":"master_pane_input_not_empty",
     "pre_input":pre[:120],"body_head":body[:80],
     "note":"입력줄 보호 게이트로 중단. 지운 것 없음·보낸 것 없음."}
open(led,"a",encoding="utf-8").write(json.dumps(rec,ensure_ascii=False)+"\n")
PY
  exit 3
fi

# ── 순환 완료 판정용 「전」 상태 채집 (KIND=slash·/clear 계열에서만 쓴다) ──────────
#   ★판정 3종(master 04:00 규명): ⑴핀파일 source=clear ⑵세션 id 교체 ⑶footer CTX 표기 소멸.
#   그중 **세션 id 교체가 가장 강한 증거**다 — 화면·핀파일과 달리 위조·지연이 없다.
#
# ── ★★대상 세션 오측 수정 (2026-07-27 · master 지시 · worker-3 구현) ──────────────
#   증상: `--cycle surface:2`(=cso)를 돌렸는데 출력이 `likely_ctx_gone (<session-a> → <session-a>)`.
#   **<session-a>는 master 자기 세션 id**다 — 구판 cmux 분기가 `~/.cmux_master_surface`를
#   **대상과 무관하게** 읽어 **master의 전/후를 비교**하고 있었다(실측: 그 핀 파일의 surface_ref=surface:1).
#   ⇒ ★**판정이 맞은 것은 우연이지 측정의 결과가 아니다.** (실제 cso는 <session-b> → <session-c>로 정상 교체됐다 —
#     `~/.claude/projects/<cso 페인의 프로젝트 슬러그>/` mtime 실측으로 독립 확인.)
#   → 대상이 master 페인일 때만 핀을 쓰고, 그 외에는 **대상 페인의 세션 파일 교체**로 잰다.
#   → ★대상 세션을 특정하지 못하면 **단정하지 않는다**(`undetermined_대상세션_미상`).
#     모르는 것을 아는 것처럼 출력하는 것이 이 시스템의 최대 위험이다.
PROJECTS_DIR="${MSEND_PROJECTS_DIR:-${HOME}/.claude/projects}"

# cwd → Claude Code 프로젝트 디렉터리명. 실측 규칙: **비영숫자 1글자 → '-' 1글자**.
#   검증: `/home/me/My Drive/jarvis/project-a` → `-home-me-My-Drive-jarvis-project-a`.
enc_project_dir() { printf '%s' "$1" | python3 -c 'import sys,re;print(re.sub(r"[^A-Za-z0-9]","-",sys.stdin.read()),end="")'; }

# cwd → 그 프로젝트의 **최신 세션 파일 basename**(없으면 빈 문자열).
newest_session_in_cwd() {
  _d="${PROJECTS_DIR}/$(enc_project_dir "$1")"
  [ -d "${_d}" ] || { printf ''; return 1; }
  _f="$(ls -t "${_d}"/*.jsonl 2>/dev/null | head -1)"
  [ -n "${_f}" ] || { printf ''; return 1; }
  printf '%s' "$(basename "${_f}")"
}

# 대상 페인의 cwd 해석. ★MSEND_TARGET_CWD로 우회 가능(시험 가능성 — 이 경로는 cmux 안에서만 돈다).
resolve_target_cwd() {
  if [ -n "${MSEND_TARGET_CWD:-}" ]; then printf '%s' "${MSEND_TARGET_CWD}"; return 0; fi
  if [ "${BACKEND}" = "cys" ]; then
    "${CYS}" status --json 2>/dev/null | python3 -c '
import json,sys
ref=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: print("",end=""); raise SystemExit
for s in d.get("surfaces",[]):
    if s.get("surface_ref")==ref: print(s.get("cwd") or "",end=""); break
else: print("",end="")
' "${SURF}" 2>/dev/null
    return 0
  fi
  # cmux — surface → 직속 프로세스 pid → lsof cwd (jarvis-who와 같은 기법·검증된 경로)
  _tsv="$("${CMUX}" top --processes --format tsv 2>/dev/null)" || { printf ''; return 1; }
  [ -n "${_tsv}" ] || { printf ''; return 1; }
  # ★후보가 여럿이면 **고르지 않는다.** 프로젝트 디렉터리가 실재하는 cwd만 후보로 남기고,
  #   그래도 둘 이상이면 미상으로 돌린다 — 모호한 채로 단정하면 이 작업의 원래 병이 재발한다.
  _cands=""
  while IFS= read -r _pid; do
    [ -n "${_pid}" ] || continue
    _c="$(lsof -a -p "${_pid}" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    [ -n "${_c}" ] || continue
    [ -d "${PROJECTS_DIR}/$(enc_project_dir "${_c}")" ] || continue
    case " ${_cands} " in *" ${_c} "*) ;; *) _cands="${_cands} ${_c}" ;; esac
  done < <(awk -F'\t' -v s="${SURF}" '$4=="process" && $6==s { print $5 }' <<<"${_tsv}")
  # shellcheck disable=SC2086
  set -- ${_cands}
  [ $# -eq 1 ] || { printf ''; return 1; }
  printf '%s' "$1"
}

# 대상의 현재 세션 식별자. 특정 불가 = 빈 문자열(★추정으로 메우지 않는다).
target_session_id() {
  if [ "${BACKEND}" = "cys" ]; then
    "${CYS}" status --json 2>/dev/null | python3 -c '
import json,sys
ref=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
for s in d.get("surfaces",[]):
    if s.get("surface_ref")==ref:
        print(((s.get("usage") or {}).get("session_file") or "").split("/")[-1]); break
else: print("")
' "${SURF}" 2>/dev/null
    return 0
  fi
  # ★핀은 **master 페인일 때만** 유효하다(핀 파일이 master 전용이라서 — surface_ref=surface:1 실측).
  if [ -n "${MASTER_REF}" ] && [ "${SURF}" = "${MASTER_REF}" ]; then
    python3 -c 'import json;print(json.load(open("'"${HOME}"'/.cmux_master_surface")).get("session_id",""))' 2>/dev/null || printf ''
    return 0
  fi
  _cwd="$(resolve_target_cwd)" || { printf ''; return 0; }
  [ -n "${_cwd}" ] || { printf ''; return 0; }
  newest_session_in_cwd "${_cwd}" 2>/dev/null || printf ''
}

SESS_BEFORE=""
if [ "${KIND}" = "slash" ] || [ "${KIND}" = "cycle" ]; then
  SESS_BEFORE="$(target_session_id)"
fi

# ⑵ 이어붙기 차단 — 잔존물이 있으면 비운다(오늘 확정: 초안은 다음 전송에 실려 나간다)
# ★**무조건 비운다**(04:4x 실측이 이유): 판독기가 입력줄을 못 보면(프롬프트 서식이 다르거나 화면이
#   stale) `PRE`가 빈 것으로 읽혀 **비우기를 조용히 건너뛰고** 잔존물 위에 덧붙는다 — 실증: 셸 페인에서
#   `잔존물-먼저-깔아둔다` + 본문이 한 줄로 이어붙어 제출됐다. **관측 실패가 방어를 끄면 안 된다.**
#   Ctrl-U는 **큐 대기 메시지를 파괴하지 않음이 검증**돼 있으므로(회귀 ②) 항상 눌러도 안전하다.
bk_clear
sleep 1
MID="$(read_input_line)"
if [ -n "${PRE}" ] && [ -z "${MID}" ]; then CLEARED="yes"
elif [ -n "${MID}" ]; then CLEARED="no"
elif [ -n "${PRE}" ]; then CLEARED="unknown"
else CLEARED="empty_or_unreadable"; fi

# ⑷ 본문 전송
SEND_RC=0
bk_send "${BODY}" || SEND_RC=$?
sleep "${SETTLE}"
LANDED="$(read_input_line)"

# ⑹ Return
# ★S8이 드러낸 것: **Return 1회는 타이핑가드에 삼켜진다.** 오늘 master가 겪은 미제출
#   (252·253 지시가 입력줄에 남아 있던 것)의 정체가 이것이다. → **폴링 재시도**로 구조 해결.
#   제출 판정은 매 시도 후 **입력줄이 비었는가**로 한다(화면에 문장이 보이는 것은 도달이 아니다).
# ★거짓 음성 방지(master 지적 ① 2026-07-26 04:2x): 화면 판독은 **지연**된다.
#   한 번 읽고 "입력줄에 남아있다 = 미제출"로 단정하면 **실제로는 제출된 것을 미제출로 보고**하고,
#   그 보고는 **중복 전송**을 부른다. 거짓 양성=유실 · 거짓 음성=중복 — 둘 다 위험하다.
#   → 판정을 **두 경로**로 만든다: ⒜입력줄 빔이 **연속 2회 일치** ⒝**본문이 transcript에 렌더**(양성 증거).
text_in_transcript() {   # $1=텍스트 — 앞부분이 입력줄이 아닌 화면 영역에 나타났는가
  bk_read | python3 -c '
import sys,re
body=sys.argv[1]
scr=sys.stdin.read()
lines=[l for l in scr.splitlines()]
# 입력줄(❯로 시작)은 제외하고 본다 — 입력 박스가 아니라 transcript에서 확인해야 한다
tx="".join(l for l in lines if not l.strip().startswith("❯"))
norm=lambda x: re.sub(r"\s+","",x)
key=norm(body)[:14]
print("yes" if key and key in norm(tx) else "no")
' "$1" 2>/dev/null
}
# ★기존 호출부 계약 보존 — 본문 판정은 동작이 바뀌지 않는다(인자만 밖으로 뺐다).
body_in_transcript() { text_in_transcript "${BODY}"; }

# ★★고스트(프롬프트 제안) 차단 가드 — **빈 입력줄에 Enter 단독 전송 금지** (2026-07-27 · master 티켓)
#   근거 = Claude 공식 문서 `interactive-mode` §Prompt suggestions: 제안은 **입력창에 회색 글씨**로 뜨고
#   `Tab`/`→`로 입력창에 들어간 뒤 **`Enter`로 제출**된다.
#   ⇒ ★**입력줄이 비어 있을 때 Enter는 「제안 제출」 외에 할 수 있는 일이 없다.**
#   우리가 Return을 보내는 이유는 언제나 **우리 본문을 제출하기 위해서**다. 본문이 입력줄에 없으면
#   그 Enter에는 정당한 목적이 없고, 남는 효과는 **우리가 쓰지 않은 문장의 제출**뿐이다.
#   ★비대칭이 설계 근거다:
#     · 건너뛰어 잃는 것 = 제출 확인 라벨 1개. 본문은 원장에 있고, 재전송은 ⑵에서 **무조건 비우고**
#       시작하므로 이어붙지 않는다 — **가역**이다.
#     · 보내서 잃는 것 = **대상 세션에 우리가 쓰지 않은 프롬프트가 제출된다** — **비가역**이다.
#   ⇒ 확신이 설 때만 Enter를 보낸다(**fail-closed**). 판독 지연 흡수를 위해 3회 폴링한 뒤에만 건너뛴다.
#   ⚠dry-run은 애초에 아무것도 안 보내 입력줄이 늘 비어 있으므로 가드를 우회한다(bk_key가 이미 무동작).
safe_return() {   # 0=Return 보냄 · 1=키 전송 실패 · 2=가드가 막음(빈 입력줄)
  [ "${MSEND_DRYRUN:-0}" = "1" ] && { bk_key Return; return 0; }
  _g=1
  while [ "${_g}" -le 3 ]; do
    _rl="$(read_input_line_v2)"
    # 🔴★QUEUED = 본문이 큐에 들어갔다 ⇒ **이미 제출된 것과 같다. Return을 보내지 않는다.**
    #   ⛔가드 완화가 아니다 — 아래 「진짜 빈 줄」 분기는 **현행 그대로** Return을 막는다(고스트 승인문 방벽 유지).
    if [ "${_rl}" = "$(printf '\x00')QUEUED" ]; then return 3; fi
    # 🔴★4상태: ❯ 미관측(박스 오버플로) + 이번 nonce 화면 실재 ⇒ 초안이 있는 것 — Return 허용(2026-08-14).
    if [ "${_rl}" = "$(printf '\x00')NOSEEN" ]; then
      if marker_on_screen; then
        if bk_key Return; then return 0; else return 1; fi
      fi
      _rl=""
    fi
    if [ -n "${_rl}" ]; then
      if bk_key Return; then return 0; else return 1; fi
    fi
    _g=$((_g+1)); [ "${_g}" -le 3 ] && sleep 1
  done
  printf '%s\n' "가드: 3회 판독 모두 입력줄이 비어 보여 Return을 보내지 않았다 — 빈 입력줄+Enter는 **프롬프트 제안 제출** 경로다." >&2
  return 2
}

# 🔴★제출 판정용 판독 (master 지시 ⑶ 2026-07-28 22:1x)
#   **버그**: `read_input_line`이 `\x00QUEUED`를 반환하는데 아래 `POST` 검사들이 그것을
#   **「입력줄에 잔존한 텍스트」**로 읽어 `SUBMITTED=no`를 냈다 — ★**설계(QUEUED=제출 완료)와 코드가 반대.**
#   실증: 864B 발신이 `landed_seen=True`인데 `submitted=no`·경고 「입력줄에 잔존: QUEUED」.
#   ⇒ **제출 판정 문맥에서는 QUEUED를 「비었다」(=제출됨)로 정규화**한다.
#   ⚠`safe_return` 안의 `read_input_line`은 **그대로 둔다** — 거기서는 QUEUED를 구별해야 rc=3이 난다.
post_line() {
  local _v; _v="$(read_input_line_v2)"
  [ "${_v}" = "$(printf '\x00')QUEUED" ] && _v=""
  # NOSEEN = 박스에 초안이 넘쳐 남아 있음 — 「비었다」 증거로 쓰면 거짓 제출 판정이 난다(비움 아님으로 정규화).
  [ "${_v}" = "$(printf '\x00')NOSEEN" ] && _v="OVERFLOW_DRAFT"
  printf '%s' "${_v}"
}

RET="skipped"; RET_TRIES=0; VERDICT_BY=""
POST="$(post_line)"
if [ "${MSEND_NO_RETURN:-0}" != "1" ]; then
  RET="failed"
  for _try in 1 2 3; do
    RET_TRIES="${_try}"
    safe_return; _rrc=$?
    case "${_rrc}" in
      0) RET="sent" ;;
      # ★이미 보낸 Return이 있으면 그 사실을 덮지 않는다 — 2회차 가드 발동은 「1회차가 제출을 끝냈다」는 뜻일 수 있다.
      # 🔴★rc=3 = 큐 진입(제출과 동등) — master 승인
      3) [ "${RET}" = "sent" ] || RET="queued"; break ;;
      2) [ "${RET}" = "sent" ] || RET="skipped_box_read_empty"; break ;;
      *) RET="failed"; break ;;
    esac
    sleep 3
    POST="$(post_line)"
    [ -z "${POST}" ] && break
  done
  # 판정 폴링 — 지연을 흡수한다(최대 ~12초)
  _empty_streak=0
  for _p in 1 2 3 4 5 6; do
    POST="$(post_line)"
    if [ -z "${POST}" ]; then _empty_streak=$((_empty_streak+1)); else _empty_streak=0; fi
    if [ "$(body_in_transcript)" = "yes" ]; then VERDICT_BY="transcript"; break; fi
    if [ "${_empty_streak}" -ge 2 ]; then VERDICT_BY="empty_x2"; break; fi
    sleep 2
  done
fi

# ⑺ 제출 판정 — ★master 지적: 화면에 문장이 보이는 것은 도달이 아니다.
#   **입력줄이 비었는가**로 판정한다(입력 박스 vs transcript 구별).
# ★T4가 잡은 결함: 존재하지 않는 surface에서 read가 빈 문자열을 돌려주자 "입력줄 비었다"로
#   읽어 **제출=yes**를 냈다. **관측 실패를 성공으로 읽는** 형태다(오늘 밤 내내 잡던 그것).
#   → 제출 판정에 **양성 증거**를 요구한다: 본문이 입력줄에 **실린 것을 본 적 있어야** 한다.
# ★cmux 종단 결함 수정(2026-07-26 04:3x · master 시험 전송이 드러냄):
#   초판은 `LANDED`(전송 직후 입력줄에서 본문 관측)가 없으면 **transcript 증거를 보기도 전에**
#   `undetermined`로 단락시켰다. cmux 페인은 판독이 늦어 그 중간 관측을 놓치므로,
#   **실제로 도달한 전송을 「미확정」으로 보고**했다(원장 04:29:37 실증).
#   ⚠거짓 양성(관측실패→성공)을 막으려다 **거짓 음성(성공→관측실패)** 으로 기운 것이다. 둘 다 위험하다.
#   → 판정 순서 교정: **양성 증거(VERDICT_BY)가 서면 그것이 이긴다.** LANDED는 보조 관측일 뿐이다.
#   → 없는 surface 방어는 `SEND_RC`와 **화면 관측 가능 여부**가 담당한다(LANDED가 아니라).
SCREEN_OK="no"; [ -n "$(bk_read | head -c 40)" ] && SCREEN_OK="yes"
if [ "${SEND_RC}" != "0" ]; then SUBMITTED="send_failed"
elif [ "${SCREEN_OK}" = "no" ]; then SUBMITTED="undetermined_화면_관측불가"
elif [ "${RET}" = "skipped" ]; then SUBMITTED="not_attempted"
elif [ "${RET}" = "failed" ]; then SUBMITTED="return_failed"
# ★가드가 Return을 막았다 = **제출을 시도하지 않았다.** 「제출 실패」가 아니라 「미시도」다.
#   ★이름에 주의: `빈입력줄`이 아니라 **`입력줄빔관측`**이다 — 우리가 아는 것은 「3회 판독에서 비어 보였다」뿐이고
#   「비어 있었다」는 사실 주장이 아니다. 판독이 고장 났고 본문은 실제로 실려 있었을 수 있다.
#   **관측 실패에 사실의 이름을 붙이면 다음 사람이 그 이름 위에 행동한다**(master 2026-07-27 박제).
elif [ "${RET}" = "queued" ]; then SUBMITTED="queued"   # ★큐 진입 = 제출됨(원장이 실제와 일치하게)
elif [ "${RET}" = "skipped_box_read_empty" ]; then SUBMITTED="not_attempted_입력줄빔관측"
# ★★내 오판 정정(04:3x): 나는 "도달했다"는 **틀린 전제**로 판정을 느슨하게 고쳤다.
#   master 실측 = **도달 0**. 그 상태에서 `empty_x2`를 양성 증거로 인정하면 **거짓 양성**이 된다 —
#   **빈 입력줄은 "제출됐다"가 아니라 "애초에 아무것도 안 실렸다"일 수 있기 때문**이다.
#   → 규칙: **`transcript` 증거만 단독 양성**. `empty_x2`는 **본문이 입력줄에 실린 것을 본 뒤(LANDED)** 에만 유효.
elif [ "${VERDICT_BY}" = "transcript" ]; then SUBMITTED="yes"
elif [ -z "${LANDED}" ]; then SUBMITTED="undetermined_본문_미관측"
elif [ -n "${VERDICT_BY}" ]; then SUBMITTED="yes"
else SUBMITTED="no"; fi

# ── ★순환 완료 판정 (KIND=slash) ─────────────────────────────────────────────
#   ★**「보냈다」 ≠ 「순환했다」.** 오늘 밤 내내 잡은 형태다(장치 ≠ 우회 경로 차단).
#   제출 판정(입력줄 빔)은 **명령이 들어갔다**는 뜻일 뿐, 세션이 실제로 갈렸는지는 별개다.
#   그래서 **세션 id 교체**를 직접 확인한다. 확인 못 하면 **못 했다고 적는다**(추정 금지).
CYCLE_VERIFIED="n/a"; SESS_AFTER=""
if { [ "${KIND}" = "slash" ] || [ "${KIND}" = "cycle" ]; } && printf '%s' "${BODY}" | grep -qE '^/clear( |$)'; then
  # ★대상 세션을 애초에 못 잡았으면 **측정 자체가 없다.** 그 상태에서 `likely_ctx_gone` 같은 단정을
  #   내는 것이 이번 사고의 본체였다(엉뚱한 세션을 재고도 판정문은 확신에 차 있었다).
  #   → 미상은 미상이라고 적는다. 보조 신호(CTX 소멸)도 **쓰지 않는다** — 근거가 대상의 것이 아니므로.
  if [ -z "${SESS_BEFORE}" ]; then
    CYCLE_VERIFIED="undetermined_대상세션_미상"
  else
    CYCLE_VERIFIED="unverified"
    for _c in 1 2 3 4 5 6 7 8; do
      sleep 2
      SESS_AFTER="$(target_session_id)"
      if [ -n "${SESS_AFTER}" ] && [ "${SESS_AFTER}" != "${SESS_BEFORE}" ]; then
        CYCLE_VERIFIED="yes_session_swapped"; break
      fi
      # 보조 증거: footer의 CTX 표기 소멸(순환 직후엔 토큰이 0이라 표기가 사라진다)
      # ★단 **화면을 읽을 수 있을 때만** 이 신호를 쓴다. 없는 surface·죽은 페인은 읽기가 빈 문자열을
      #   돌려주는데, 그걸 "표기가 사라졌다"로 읽으면 **관측 실패를 순환 성공으로 보고**한다.
      #   실측: T3에서 존재하지 않는 surface:999가 `likely_ctx_gone`을 냈다. 오늘 밤 다섯 번째 같은 형태다.
      _scr="$(bk_read)"
      if [ -n "${_scr}" ] && ! printf '%s' "${_scr}" | grep -qa "CTX "; then
        CYCLE_VERIFIED="likely_ctx_gone"
      fi
    done
  fi
fi

# ── ★★순환 후 복원 포인터 자동 재주입 (2026-07-27 · master 티켓) ────────────
#   🔴왜 구조로 옮기는가: master가 워커를 순환시켜 놓고 **복원 지시를 잊는다.** 같은 날 두 번 났다
#   (낮에 270을 12분 방치 · 16:3x에 288을 14분 방치). ★**「규율로 기억하면 잊는다」가 하루에 두 번 증명됐다.**
#   순환된 워커는 컨텍스트가 비어 **스스로 다음 행동을 모른다** — 아무도 안 보내면 그냥 서 있는다.
#   ⇒ 순환과 복원 포인터를 **한 동작**으로 묶는다. 기억이 아니라 구조로.
#   ★적용 범위: `--cycle`뿐 아니라 **래퍼를 거친 모든 `/clear`**에 건다(판정값 기준).
#     `--cycle`이라는 **표지**에만 걸면 표지 없이 같은 일을 하는 경로가 그대로 열린다(장기기억
#     `marker-based-guards-miss-markerless-cases`). 위험은 「어느 명령을 썼나」가 아니라 「세션이 갈렸나」다.
#   ⚠문구는 **템플릿 파일**에 둔다 — 하드코딩하면 다음에 또 낡는다(오늘 계속 잡은 형태).
#   ⚠**실패를 조용히 넘기지 않는다** — 순환만 성공하고 재주입이 실패하면 **방치 상태가 그대로 재현**된다.
REINJECT="n/a"; REINJECT_ERR=""
CYCLE_TPL="${MSEND_CYCLE_TEMPLATE:-${CH}/cycle-restore-template.md}"
if [ "${CYCLE_VERIFIED}" = "yes_session_swapped" ] && [ "${MSEND_NO_REINJECT:-0}" != "1" ]; then
  if [ "${MSEND_DRYRUN:-0}" = "1" ]; then
    REINJECT="dryrun_skipped"
  elif [ ! -f "${CYCLE_TPL}" ]; then
    REINJECT="failed"; REINJECT_ERR="template_missing:${CYCLE_TPL}"
  else
    RTEXT="$(cat "${CYCLE_TPL}")"
    # cmux는 개행을 Enter로 해석해 조각 제출된다 → 본문 전송과 같은 규칙으로 접는다.
    if [ "${BACKEND}" = "cmux" ] && [[ "${RTEXT}" == *$'\n'* ]]; then
      RTEXT="$(printf '%s' "${RTEXT}" | python3 -c 'import sys;print(" ⏎ ".join(sys.stdin.read().splitlines()))')"
    fi
    if [ -z "${RTEXT}" ]; then
      REINJECT="failed"; REINJECT_ERR="template_empty:${CYCLE_TPL}"
    else
      sleep 3                       # 새 세션 프롬프트가 뜰 때까지
      bk_clear; sleep 1             # §6-11 — 전송 전 비우기(잔존물 이어붙기 차단)
      if bk_send "${RTEXT}"; then
        sleep "${SETTLE}"
        RLANDED="$(read_input_line)"
        for _r in 1 2 3; do
          safe_return; _rrc2=$?
          [ "${_rrc2}" = "0" ] || break
          sleep 3
          [ -z "$(read_input_line)" ] && break
        done
        # ★도달 실측 — 「보냈다」로 끝내면 순환 후 정지를 다시 못 잡는다(master 지시).
        REINJECT="unverified"
        for _r in 1 2 3 4 5 6; do
          if [ "$(text_in_transcript "${RTEXT}")" = "yes" ]; then REINJECT="yes"; break; fi
          if [ -n "${RLANDED}" ] && [ -z "$(read_input_line)" ]; then REINJECT="yes"; break; fi
          sleep 2
        done
        [ "${REINJECT}" = "unverified" ] && REINJECT_ERR="submit_unverified"
      else
        REINJECT="failed"; REINJECT_ERR="send_failed"
      fi
    fi
  fi
  if [ "${REINJECT}" != "yes" ] && [ "${REINJECT}" != "dryrun_skipped" ]; then
    printf '%s\n' "⚠ ★**순환은 됐는데 복원 포인터 재주입이 확인되지 않았다** (${REINJECT}${REINJECT_ERR:+ · ${REINJECT_ERR}})." >&2
    printf '%s\n' "   ⇒ ${SURF}는 지금 **컨텍스트가 빈 채로 지시를 기다리고 있다.** 손으로 복원 지시를 보내라." >&2
    printf '%s\n' "   템플릿: ${CYCLE_TPL}" >&2
  fi
fi

HASH="$(printf '%s' "${BODY}" | shasum -a 256 | awk '{print $1}')"

# ⑻ 원장 append — 성공·실패 무관하게 **시도 자체**를 남긴다(실패도 사실이다)
if [ "${MSEND_DRYRUN:-0}" = "1" ]; then
  printf 'DRYRUN: 원장 기록 생략 — kind=%s cleared=%s submitted=%s cycle=%s\n' \
    "${KIND}" "${CLEARED}" "${SUBMITTED}" "${CYCLE_VERIFIED}"
  exit 0
fi
python3 - "$LEDGER" "$TS_START" "$SURF" "$HASH" "$BODY" "$CLEARED" "$LANDED" "$SUBMITTED" "$RET" "$SEND_RC" "$PRE" "$RET_TRIES" "$VERDICT_BY" "$BACKEND" "$MULTILINE_FOLDED" "$KIND" "$CYCLE_VERIFIED" "$SESS_BEFORE" "$SESS_AFTER" "$NONCE" <<'PY'
import json,sys
(led,ts,surf,h,body,cleared,landed,submitted,ret,rc,pre,tries,vby,backend,folded,
 kind,cycle,sb,sa,nonce) = sys.argv[1:21]
rec={"type":"send","ts":ts,"surface":surf,"kind":kind,"body_sha256":h,"body_head":body[:80],
     "body_len":len(body),"pre_input":pre[:80],"input_cleared":cleared,
     "landed_head":landed[:80],"return":ret,"return_tries":int(tries),"send_rc":int(rc),"submitted":submitted,
     "verdict_by":vby,"backend":backend,"landed_seen":bool(landed),"multiline_folded":folded}
if kind in ("slash","cycle"):
    rec.update({"cycle_verified":cycle,"session_before":sb,"session_after":sa})
if nonce:
    rec["nonce"]=nonce
with open(led,"a",encoding="utf-8") as f:
    f.write(json.dumps(rec,ensure_ascii=False)+"\n")
PY

# ── 재주입 원장 (별도 1줄) — ★실패도 반드시 남긴다 ─────────────────────────────
#   순환 성공 + 재주입 실패 = **방치 상태**다. 그게 원장에 안 남으면 사후에 셀 수 없다.
if [ "${REINJECT}" != "n/a" ] && [ "${REINJECT}" != "dryrun_skipped" ]; then
  python3 - "$LEDGER" "$TS_START" "$SURF" "$REINJECT" "$REINJECT_ERR" "$CYCLE_TPL" "$BACKEND" <<'PY'
import json,sys,hashlib,os
led,ts,surf,st,err,tpl,backend = sys.argv[1:8]
try:
    body=open(tpl,encoding="utf-8").read()
except Exception:
    body=""
rec={"type":"send","kind":"cycle_reinject","ts":ts,"surface":surf,
     "reinject":st,"backend":backend,"template":tpl,
     "body_sha256":hashlib.sha256(body.encode()).hexdigest() if body else "",
     "body_len":len(body),"via":"master-send.sh --cycle 후속"}
if st != "yes":
    rec["error"]="cycle_reinject_failed"
    if err: rec["error_detail"]=err
try:
    with open(led,"a",encoding="utf-8") as f:
        f.write(json.dumps(rec,ensure_ascii=False)+"\n")
except Exception:
    pass   # fail-open — 기록 실패가 전송 실패가 되면 안 된다
PY
fi

printf '%s → %s[%s] | 비움=%s · Return=%s(%s회) · **제출=%s**%s | sha=%s… | 원장 기록됨\n' \
  "${TS_START}" "${SURF}" "${BACKEND}" "${CLEARED}" "${RET}" "${RET_TRIES}" "${SUBMITTED}" \
  "$([ -n "${VERDICT_BY}" ] && printf '(근거=%s)' "${VERDICT_BY}")" "${HASH:0:12}"
[ "${SUBMITTED}" = "no" ] && printf '⚠ 제출 실패 — 입력줄에 잔존: %s\n' "${POST:0:80}"
if { [ "${KIND}" = "slash" ] || [ "${KIND}" = "cycle" ]; } && [ "${CYCLE_VERIFIED}" != "n/a" ]; then
  printf '순환 판정: **%s** (대상=%s · 세션 %s → %s)\n' \
    "${CYCLE_VERIFIED}" "${SURF}" "${SESS_BEFORE:0:8}" "${SESS_AFTER:0:8}"
  [ "${CYCLE_VERIFIED}" = "unverified" ] && \
    printf '⚠ ★**순환 미확인이다. 「보냈다」를 「순환했다」로 읽지 마라.** 세션 id가 안 갈렸다.\n'
  [ "${REINJECT}" != "n/a" ] && \
    printf '복원 재주입: **%s**%s (템플릿=%s)\n' "${REINJECT}" \
      "$([ -n "${REINJECT_ERR}" ] && printf ' · %s' "${REINJECT_ERR}")" "${CYCLE_TPL##*/}"
  [ "${CYCLE_VERIFIED}" = "undetermined_대상세션_미상" ] && \
    printf '⚠ ★**대상 세션을 특정하지 못했다 — 순환 여부를 판정하지 않았다.** 이것은 "순환 안 됨"도 "순환 됨"도 아니다.\n  대상 cwd 해석 실패(cmux top/lsof 또는 프로젝트 디렉터리 부재). MSEND_TARGET_CWD로 직접 지정하면 판정 가능하다.\n'
fi
exit 0
