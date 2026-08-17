#!/bin/bash
# inbox-append.sh — 워커/CSO 공용 인박스 append 헬퍼 (2026-08-01 master 신설)
#
# 왜 존재하는가: 2026-08-01 하루에 같은 사고 2건(CSO 12:10 · 워커 12:31) —
#   발신자가 시각($TS)을 본문에 넣으려고 비인용 heredoc(<<EOF)으로 내려가는 순간
#   백틱 감싼 경로가 셸 명령치환으로 실행돼 빈 문자열로 소실됐다(문장은 멀쩡해 보여
#   받는 쪽이 훼손을 모른다). 규율(지침 7-0)로는 재발을 못 막았으므로,
#   **시각을 이 헬퍼가 붙인다 → 발신자는 항상 인용 heredoc(<<'EOF')만 쓰면 된다.**
#
# 사용(발신자는 본문에 변수·시각을 넣지 마라 — 전부 literal):
#   ~/.claude/channels/inbox-append.sh "worker-project-a@surface:329" <<'EOF'
#   【보고】 본문. 백틱 `무엇이든` $달러 그대로 나간다.
#   EOF
#
# 보장: ⑴시각은 헬퍼가 KST로 생성 ⑵본문은 stdin을 바이트 그대로 append(셸 확장 0)
#       ⑶append 후 마지막 줄 재독으로 도달 실측 출력.
set -u
INBOX="${CYS_INBOX:-$HOME/.cys/cmux-inbox.md}"
FROM="${1:?usage: inbox-append.sh '<from-label>' <<'EOF' ... EOF}"
TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"
{
  printf '[%s → cmux master] %s ' "$FROM" "$TS"
  cat            # stdin = 본문. 어떤 확장도 일어나지 않는다(이미 지나온 셸이 인용 heredoc이면).
  printf '\n'
} >> "$INBOX"
# 도달 실측: 방금 쓴 헤더를 파일에서 되찾아 통째 출력(⛔바이트 절단 금지 — tail -c/cut -c는
#   UTF-8 한글을 중간에서 잘라 깨진 글자를 만들고, 발신자가 「전송 실패」로 오독해 재전송한다.
#   2026-08-01 331 적발·교정).
FOUND=$(grep -cF "[$FROM → cmux master] $TS" "$INBOX")
grep -F "[$FROM → cmux master] $TS" "$INBOX" | tail -1
echo "[inbox-append] appended at $TS (재독 일치 ${FOUND}건 — 위 줄이 실물 전문)"
