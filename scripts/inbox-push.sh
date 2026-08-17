#!/usr/bin/env bash
# 인박스 push 래퍼 — 워커/노드가 master 인박스에 보고할 때 쓰는 정상 경로.
#
# ★왜 있는가(master 승인 2026-07-28 · CSO 구현):
#   인박스 머리 시각을 **워커가 손으로 적어서** 네 범주의 오염이 났다:
#     ⑴KST 528건 ⑵UTC(`Z`) 307건 ⑶무표기 94건 ⑷★**표기 정상＋값 거짓**
#   ★**⑷가 최악**이다 — `+0900`이 붙어 가장 믿음직해 보이고 **축 정규화로는 못 잡는다.**
#   실사고: 한 워커가 **57분 미래**(`22:40:00+0900`)를 적었고,
#           master가 그 값을 실측 없이 `master/TODO.md`에 옮겼다(`cso/SESSION_STATE.md §9-22-9`).
#   ⇒ ★**시각을 래퍼가 찍으면 ⑵⑶⑷가 한꺼번에 사라진다**(워커가 손으로 안 적으므로).
#
# ★설계 원칙 = **「쉬운 길이 옳은 길이 되게」**(규율로 지키게 하지 않는다):
#   현행 `cat >> ~/.cys/cmux-inbox.md <<'EOF'` = 35자 / 이 래퍼 = **21자** ⇒ **마찰이 음수**다.
#   ⚠단 그 수치는 **호출 문자열만** 잰 것이고, 실사용 마찰은 **환경변수 부재**와 **실패 처리**에서 난다.
#   ⇒ 아래 두 조건이 이 도구의 성패다(master 지시).
#
# 🔴★**이 도구가 못 하는 것(먼저 적는다)**:
#   · **파일 직접 append를 막지 못한다.** 원리적으로 불가능하다.
#     ⇒ ★**이 래퍼(정상 경로)와 `cso-watch-events.sh`의 인박스 시각 검사(우회 탐지)는 짝이다.**
#       래퍼를 안 쓰고 손으로 적으면 시각이 어긋나고, **그때 검사가 잡는다.** 하나만으로는 완성되지 않는다.
#   · **워커가 발견 시각에 맞춰 거짓을 적으면** 검사도 통과한다 — **티 나는 거짓만 잡힌다.**
#
# 사용:
#   inbox-push.sh <<'EOF'
#   【보고】 본문 …
#   EOF
#   (환경변수 override: PUSH_ROLE=… PUSH_SURFACE=… PUSH_TO=…)
set -u

INBOX="${CYS_INBOX:-$HOME/.cys/cmux-inbox.md}"
TO="${PUSH_TO:-cmux master}"

# ── role 획득 — ★조건⑴: 부재 시 죽지 말고 기본값으로 가되 **그 사실을 반드시 표시**한다.
#    ⛔조용한 추정이 가장 나쁘다(거짓 발신자가 원장에 남는다).
ROLE_SRC="env"
ROLE="${PUSH_ROLE:-${CYS_ROLE:-}}"
if [ -z "${ROLE}" ]; then
  ROLE="$(basename "$(pwd)")"; ROLE_SRC="cwd추정"
fi

# ── surface 획득 — 같은 원칙.
# 🔴★CYS_SURFACE_ID가 정본이다(2026-08-09 · 워커 417 적발 · master 지시로 CSO 수리).
#   pack 정본이 그렇게 적고 있다: `WORKER_DIRECTIVE.md:141` 「너의 주소는 환경변수
#   CYS_SURFACE_ID·CYS_ROLE에 있다」. 그런데 이 줄은 **끝 `_ID`가 없는 이름**만 읽고 있었다.
#   ⇒ cys 워커 실환경 실측: CYS_SURFACE_ID=[417] · CYS_SURFACE=[] · CMUX_SURFACE_ID=[]
#     ⇒ 셋 다 비어 SURF=unknown 으로 떨어졌고, 경고는 **stderr로만** 나가고 push는 exit 0이라
#       **주소가 빈 줄이 원장에 조용히 쌓였다**(실해: master가 「완료 push가 없다」고 오판해
#       불필요한 재발신을 지시 — 원본은 인박스에 이미 있었고 머리표만 unknown이었다).
#   ★교훈: 래퍼를 만든 이유가 「손으로 적어 생긴 머리표 오염 제거」였는데,
#     **같은 칸이 다른 이유로 다시 비었다.** 이름 하나가 어긋나면 도구는 조용히 무력해진다.
#   ⚠짝인 ROLE(36행)은 `CYS_ROLE`을 이미 바르게 읽는다 — 실측으로 확인했고 손대지 않았다.
SURF_SRC="env"
SURF="${PUSH_SURFACE:-${CYS_SURFACE_ID:-${CYS_SURFACE:-${CMUX_SURFACE_ID:-}}}}"
if [ -z "${SURF}" ]; then
  SURF="unknown"; SURF_SRC="미상"
else
  case "${SURF}" in surface:*) ;; *) SURF="surface:${SURF}" ;; esac
fi

# ── 시각 — ★래퍼가 찍는다. 워커는 손대지 않는다.
TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"

BODY="$(cat)"
if [ -z "${BODY}" ]; then
  printf '🔴inbox-push: 본문이 비었다(stdin). 아무것도 쓰지 않았다.\n' >&2
  exit 2
fi

HEAD="[${ROLE}@${SURF} → ${TO}] ${TS}"

# ── ★조건⑵: 실패하면 **폴백을 막지 말고 보이게** 한다.
#    파일 append는 원리적으로 막을 수 없다 ⇒ 숨기면 원장에 빈칸만 남는다.
#    ⇒ 실패 시 **그대로 쓸 수 있는 폴백 명령을 인쇄**하고, 그 우회는 시각 검사가 잡는다.
if ! { printf '\n%s %s\n' "${HEAD}" "${BODY}"; } >> "${INBOX}" 2>/dev/null; then
  {
    printf '🔴inbox-push: 인박스 쓰기 실패 — %s\n' "${INBOX}"
    printf '▶폴백(그대로 실행 가능·⚠시각을 직접 적어야 한다):\n'
    printf "  cat >> %s <<'EOF'\n\n%s %s\n<본문>\nEOF\n" "${INBOX}" "${HEAD}" ""
    printf '⚠폴백으로 쓰면 시각이 손으로 적히므로 CSO 인박스 시각 검사에 걸릴 수 있다(정상 동작).\n'
  } >&2
  exit 1
fi

# ── 획득 출처 표시 — ★추정으로 간 경우 반드시 보이게.
if [ "${ROLE_SRC}" != "env" ] || [ "${SURF_SRC}" != "env" ]; then
  printf '⚠inbox-push: 발신자 정보를 추정했다 — role=%s(%s) surface=%s(%s)\n' \
    "${ROLE}" "${ROLE_SRC}" "${SURF}" "${SURF_SRC}" >&2
  printf '   정확히 하려면: PUSH_ROLE=<역할> PUSH_SURFACE=<surface:N> inbox-push.sh\n' >&2
fi
printf '✅inbox-push: %s (%d바이트)\n' "${HEAD}" "${#BODY}"
