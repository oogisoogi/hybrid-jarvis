# MEMORY.md 색인 예시

> 장기기억 색인의 실물 형태 예시입니다. 색인은 세션 시작 시 자동 로드되므로 **한 줄 포인터만** 둡니다
> (내용을 색인에 넣으면 매 세션 그만큼 컨텍스트를 냅니다). 각 메모리는 별도 파일 1개 = 사실 1개.

```markdown
# Memory Index

- [★★순환 규칙 v3·예측 기반](master-proactive-ctx-cycle.md) — 50=관측·순환점=예측·60후 대형 금지·70 소프트·75+=사고
- [★CTX 측정 정본](ctx-measurement-canon.md) — 자기 CTX=jsonl 실측; 인용에 출처+시점 병기
- [★★미결에는 해소 판정법](open-items-need-resolution-test.md) — 압축되면 질문만 남는다
- [★★전원연결=무인운영 의도신호](power-connection-is-intent-signal.md) — 계기=pmset -g adapter만; 잠=정상·결함 아님
- [★★초록불이 「대상을 안 만남」일 수 있다](green-test-may-never-have-touched-target.md) — 뮤테이션 검산·양방향
- [★측정 입력부터 검증](measurement-input-must-be-validated.md) — 판정로직 맞아도 입력 오염이면 오판
- [★자동로드 문서가 추가규율을 이긴다](auto-loaded-doc-beats-added-rule.md) — 규율 적기 전 자동로드 문서 grep→교체
- [★★워커 지시엔 상한·중단조건](worker-dispatch-needs-stop-condition.md) — 상한 부재→워커는 끝까지 감
- [호칭=<오너 호칭>](user-address-honorific.md) — 오너를 '<호칭>'으로
```

## 메모리 파일 1건의 형태

```markdown
---
name: open-items-need-resolution-test
description: 미결 항목에는 해소 판정법을 함께 적는다 — 압축되면 질문만 살아남는다
metadata:
  type: feedback
---

미결·대기 항목을 원장에 적을 때는 바로 아래에 「해소 판정: <실행하면 답이 나오는 명령/관측>」
한 줄을 반드시 함께 적는다.

**Why:** 질문은 미해결일 때 적히므로 반드시 적히지만, 답은 코드·커밋·대화에서 소비되고
원장에 안 남는다. 세션이 압축되면 질문만 살아남아, 다음 세션이 이미 답한 것을 또 묻는다
(하루 3회 오보 실증).

**How to apply:** 판정법을 못 적겠으면 그 항목은 아직 질문이 덜 익은 것이다.
[[measurement-input-must-be-validated]]의 원장 판본.
```

## 운영 원칙

- 저장 전에 기존 파일이 이미 다루는지 확인 — 중복 생성 대신 갱신.
- 틀린 것으로 판명된 메모리는 삭제(낡은 규율의 자동 로드 = 다음 사고의 교본).
- 코드·git 이력이 이미 기록하는 것은 저장하지 않는다.
- 관련 메모리는 `[[이름]]`으로 링크 — 규율의 계보가 보이면 다음 증류가 쉬워진다.
