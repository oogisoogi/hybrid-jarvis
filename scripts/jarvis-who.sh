#!/usr/bin/env bash
# jarvis-who.sh <role> — 역할→surface 라이브 해석 (WORKSPACE-RESTRUCTURE-DESIGN §1, P0)
# roster 같은 저장 상태 없음: 매 호출 cmux 라이브 조회.
#
# ★2026-07-16 개정 (오너 질의 "페인 제목을 수시로 바꿔도 되는가" → 실측 후 수정):
#   구판은 **탭 제목**을 1차 키로 써서 제목이 바뀌면 즉시 깨졌다. 실증: cso 페인 제목이
#   Claude Code에 의해 "✳ CSO 역할 전환 및 시스템 초기화"로 자동 변경되어
#   `jarvis-who.sh cso` → `ERR no surface with tab "cso"` (아무도 손대지 않았는데 배선 단절).
#   = **제목은 사람이 보는 이름표인데 기계가 그걸 주소로 썼다.** cys는 이 분리를 이미 했다
#   (cys-who.sh 주석: "cys는 역할이 1급 개념이라 cys list가 role→surface를 직접 준다").
#
#   개정 원칙: **cwd = 1차 키(권위)** · **탭 제목 = 동점 판별용 보조**(cosmetic).
#   → 오너은 어떤 페인의 제목이든 언제든 바꿔도 된다. 배선이 안 깨진다.
#   불일치/미발견 = 비0 종료(send 중단 신호). 이 안전 의미는 구판 그대로 보존.
set -u
role="${1:?usage: jarvis-who.sh <master|cso|worker-1|worker-2|worker-3|lead|spare|<project>>}"

# ── 설정(자기 환경에 맞게 override) ──────────────────────────────────────────
#   JARVIS_ROOT = 워크스페이스 루트. cwd 대조는 이 루트의 basename 을 접미로 쓴다.
#   PROJECTS    = 하위 프로젝트 페인의 역할 이름(= 루트 아래 폴더명과 같아야 한다).
JARVIS_ROOT="${JARVIS_ROOT:-$HOME/jarvis}"
ROOT_SFX="$(basename "$JARVIS_ROOT")"
PROJECTS=("project-a" "project-b")   # (프로젝트별 분기는 자기 환경에 맞게)

# ★2026-08-07 워크스페이스 이사에서 얻은 교훈: 작업 루트를 옮겼더니 하드코딩된 구 suffix가
#   신경로에 **하나도 안 맞아** cso·master 전건 exit 5였다(= 배선 완전 단절).
#   ⇒ ⑴suffix 를 JARVIS_ROOT 에서 파생시키고 ⑵cwd 대조를 `*/"$cwd_sfx"`로
#     **슬래시 경계까지** 요구하게 했다. (구판 `*"$cwd_sfx"`는 `/foo/xjarvis` 같은
#     접미 유사경로도 삼킨다 — 루트 이름이 짧고 흔한 낱말이면 그 함정이 실제 위험이 된다.)
case "$role" in
  master)       tab="master";  cwd_sfx="$ROOT_SFX" ;;
  cso)          tab="cso";     cwd_sfx="$ROOT_SFX/cso" ;;
  worker-1|worker-2|worker-3)
                n="${role#worker-}"; tab="$role"; cwd_sfx="$ROOT_SFX/workers/w$n" ;;
  lead)         tab="worker-1"; cwd_sfx="$ROOT_SFX/workers/w1" ;;  # 다이어트(오너 07-06): lead 페인 폐지 → w1이 아침 스캔 발화 인계(B3 무수정 이양)
  spare)        tab="workbench-spare"; cwd_sfx="$ROOT_SFX" ;;
  # 하위 프로젝트 페인 = PROJECTS 등록분만 해석(미등록 = 에러·fail-closed).
  # 페인 cwd 가 루트 아래가 아닌 프로젝트는 여기에 cwd_sfx 를 직접 적어라.
  *) _hit=0
     for _p in "${PROJECTS[@]}"; do
       [ "$role" = "$_p" ] && { tab="$_p"; cwd_sfx="$ROOT_SFX/$_p"; _hit=1; break; }
     done
     [ "$_hit" = 1 ] || { echo "ERR unknown role: $role" >&2; exit 2; } ;;
esac

tsv="$(cmux top --processes --format tsv 2>/dev/null)" || { echo "ERR cmux unreachable" >&2; exit 3; }

# ── 키1(권위) = cwd 실측 ── 모든 surface를 훑어 직속 프로세스 cwd가 기대 경로로 끝나는 후보 수집
cands=""
while IFS= read -r s; do
  [ -n "$s" ] || continue
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
    case "$cwd" in */"$cwd_sfx") cands="$cands $s"; break ;; esac
  done < <(awk -F'\t' -v s="$s" '$4=="process" && $6==s { print $5 }' <<<"$tsv")
done < <(awk -F'\t' '$4=="surface" { print $5 }' <<<"$tsv")

# shellcheck disable=SC2086
set -- $cands
case $# in
  0) echo "ERR no live surface with cwd *…/$cwd_sfx (role=$role) — send 중단" >&2; exit 5 ;;
  1) echo "$1"; exit 0 ;;
esac

# ── 키2(보조) = 탭 제목 ── cwd 후보가 둘 이상일 때만(예: master vs spare, 둘 다 cwd=루트)
#    제목은 바뀔 수 있으므로 여기서 못 찾아도 실패로 보지 않고 첫 후보를 쓰지 **않는다** —
#    모호한 채로 send하면 엉뚱한 페인에 명령이 간다(그게 더 위험). 명시적 에러로 중단.
surface="$(awk -F'\t' -v want="$tab" '
  $4=="surface" { t=$7; sub(/^[^[:alnum:]]+[[:space:]]*/, "", t); if (t==want) { print $5; exit } }' <<<"$tsv")"
if [ -n "$surface" ]; then
  for c in "$@"; do
    [ "$c" = "$surface" ] && { echo "$surface"; exit 0; }
  done
fi
echo "ERR cwd *…/$cwd_sfx 후보가 여럿($*)이고 탭 제목 \"$tab\"으로 판별 실패 — send 중단" >&2
exit 6
