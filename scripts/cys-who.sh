#!/usr/bin/env bash
# cys-who.sh <role> — cys-네이티브 역할→surface 해석 (jarvis-who.sh의 cys 이식본)
# ─────────────────────────────────────────────────────────────────────────────
# cmux판(jarvis-who.sh)은 `cmux top`으로 tab명+cwd 2계열 휴리스틱 해석이 필요했으나,
# cys는 역할이 1급 개념(claim-role/launch-agent)이라 `cys list`가 role→surface를 직접 준다.
# → 해석이 결정론·단순. 불일치/미발견 = 비0 종료(send 중단 신호), jarvis-who와 계약 동일.
#
# 별칭 매핑(전용 워커를 프로젝트별로 상주시키는 병렬 토폴로지용):
#   <project> → worker-<project> 로 정규화한다. 절차상 worker-2/worker-3 같은 번호 별칭을
#   전용 워커에 물리고 싶으면 ROLE_ALIASES 에 `번호:정식역할` 로 적는다.
#   worker-1·lead·spare·worker → 표준 worker(여분/개발용 — 전용 작업 점유 안 함).
# 표준 역할(master/cso/worker/reviewer-gemini/reviewer-codex)은 그대로 해석.
set -u

# ── 설정(자기 환경에 맞게 override) ──────────────────────────────────────────
#   PROJECTS      = 전용 워커가 붙은 하위 프로젝트 이름 → `worker-<이름>` 으로 해석된다.
#   ROLE_ALIASES  = 추가 별칭. 공백 구분 `별칭:정식역할` 목록.
PROJECTS=("project-a" "project-b")                                  # (프로젝트별 분기는 자기 환경에 맞게)
ROLE_ALIASES="${ROLE_ALIASES:-worker-2:worker-project-a worker-3:worker-project-b}"

role="${1:?usage: cys-who.sh <master|cso|worker|reviewer-gemini|reviewer-codex|<project>>}"

# 별칭/프로젝트 역할 → 정식 cys 역할로 정규화
want="$role"
case "$role" in
  worker-1|lead|spare)   want="worker" ;;           # 여분/개발용 = 표준 worker(전용 작업 미점유)
  reviewer)              want="reviewer-gemini" ;;  # generic reviewer 요청 시 gemini로(관례)
  *)
    for _p in "${PROJECTS[@]}"; do
      [ "$role" = "$_p" ] && { want="worker-$_p"; break; }
    done
    for _a in $ROLE_ALIASES; do
      [ "$role" = "${_a%%:*}" ] && { want="${_a#*:}"; break; }
    done
    ;;
esac

# cys list 실측 → role 필드 정확 일치 surface_ref 출력 (첫 일치).
# ★필드 정확일치(-F'\t' $2==r): "role=worker" 부분일치가 "role=worker-<project>"에 오탐되는 것을 차단
#   (병렬 토폴로지에서 worker vs worker-<project> 정확 분별이 load-bearing).
line="$(cys list 2>/dev/null | awk -F'\t' -v r="role=$want" '$2==r {print $1; exit}')"
[ -n "$line" ] || { echo "ERR no live surface with role \"$want\" (요청: $role)" >&2; exit 4; }
echo "$line"
