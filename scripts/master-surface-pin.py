#!/usr/bin/env python3
# SessionStart 훅 (마스터 전용). 두 가지를 한다:
#  (1) surface UUID 고정: 마스터(cwd=JARVIS_ROOT)의 caller UUID를 ~/.cmux_master_surface에 기록(부수효과).
#  (2) 자동 복원 지령 주입: /clear·재시작·resume 후 첫 입력 처리 전에, 무엇을 입력하든 전 맥락
#      복원부터 하도록 additionalContext로 주입(오너 2026-06-12 지시 — 복귀 트리거 불요).
# 워커(하위 폴더)·CSO(cso/)는 cwd 가드로 즉시 skip → 오염·노이즈 방지.
import json, sys, os, subprocess, re, datetime

# ── 설정(자기 환경에 맞게 override) ────────────────────────────────────────
#   JARVIS_ROOT = 워크스페이스 루트. 이 cwd 로 뜬 세션만 「마스터」로 취급한다.
JARVIS_ROOT = os.environ.get("JARVIS_ROOT") or os.path.expanduser("~/jarvis")
CMUX = os.environ.get("CMUX_BIN") or "/Applications/cmux.app/Contents/Resources/bin/cmux"


def project_slug(path):
    """cwd → Claude Code 프로젝트 디렉터리명(비영숫자 1글자 → '-' 1글자)."""
    return re.sub(r"[^A-Za-z0-9]", "-", path)

def stale_guard():
    # 옛 frozen 세션/동기화 지연으로 SESSION_STATE 본문이 며칠 전이면 자동 감지(2026-06-17 오너 지시).
    # cmux 완전 종료 후 옛 sid로 부활하면 '며칠 전 날짜로 복원'됨 → 날짜 비교로 즉시 경보.
    try:
        with open(os.path.join(JARVIS_ROOT, "master", "SESSION_STATE.md")) as f:
            head = f.read(2000)
        m = re.search(r"현재 세션 \((\d{4}-\d{2}-\d{2})", head)
        if not m:
            return ""
        hdr = datetime.date.fromisoformat(m.group(1))
        today = datetime.date.today()
        if (today - hdr).days >= 1:
            return ("⚠️⚠️ [STALE 경고 — 옛 세션/동기화 지연 가능] SESSION_STATE 헤더 날짜=%s 인데 오늘=%s 다. "
                    "본문 상세를 그대로 신뢰하지 말라. **1차 권위 = 메모리(MEMORY.md 색인+핵심) + 라이브 실측"
                    "(`date`·`jarvis-who.sh`·`fired-<오늘>-*` 락·CronList)**. 옛 frozen 세션으로 부활했을 수 있으니 "
                    "현재 날짜·진행 상태를 라이브로 재확정한 뒤 SESSION_STATE를 최신화하라.\n\n") % (m.group(1), today)
    except Exception:
        pass
    return ""
def inbox_backlog():
    # (2026-08-15 오너 지시 「결정론적 능동감시」) 인박스 미처리 스윕을 사람 절차가 아니라
    # 훅이 강제한다: 복원마다 최근 워커→master 헤더를 코드가 직접 세어 주입. 실패 = 무해(빈 문자열).
    # ⛔마커 어휘 grep 금지 계보(451 갈무리 17시간 방치·RECOVERY 6-1) — 헤더 전건만 센다.
    try:
        p = os.path.expanduser("~/.cys/cmux-inbox.md")
        total = int(subprocess.check_output(["wc", "-l", p], timeout=10).split()[0])
        tail = subprocess.check_output(["tail", "-n", "800", p], timeout=10).decode("utf-8", "replace").splitlines()
        base = total - len(tail)
        hdrs = [(base + i + 1, ln) for i, ln in enumerate(tail) if "→ cmux master]" in ln]
        if not hdrs:
            return ""
        first, last = hdrs[0][0], hdrs[-1][0]
        m = re.search(r"\] (20\d{2}-\d{2}-\d{2}[T ][\d:+.Z]+)", hdrs[-1][1])
        ts = m.group(1) if m else "?"
        return ("\U0001F4E5 [인박스 결정론 스윕 — 훅 실측] 최근 800줄 내 워커→master 헤더 **%d건**(줄 %d~%d·최신 %s·파일 전체 %d줄). "
                "복원 시 SESSION_STATE의 「스윕 기점」 이후 헤더 **전건**을 대조하고 미처리를 즉시 처리하라. "
                "⛔tail-N·마커 어휘 grep 금지(RECOVERY 6-1·v6). 기점이 %d보다 오래됐으면 그 사이 전 구간을 훑는다.\n\n"
                % (len(hdrs), first, last, ts, total, first))
    except Exception:
        return ""

# ⛔풀 경로 수동 테스트 금지(2026-08-15 실사고): 가짜 stdin으로 전체 실행하면 (1)번 부수효과가
# ~/.cmux_master_surface 의 session_id 를 가짜 값으로 덮어 CSO ctx-sentinel 이 실명한다. 테스트 = --test-backlog 만.
if "--test-backlog" in sys.argv:
    print(inbox_backlog() or "(헤더 0건 또는 실패 — 빈 주입)")
    sys.exit(0)

try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
cwd = d.get("cwd", "")
if cwd != JARVIS_ROOT:                 # 마스터만(하위 워커·cso 제외, 정확 일치)
    sys.exit(0)
role = os.environ.get("JARVIS_ROLE") or ""
if role.startswith("worker") or role == "cso":  # 루트 여유 워커·풀 워커(worker-N)·cso — 마스터 아님 (P1 prefix 보정)
    sys.exit(0)

# (1) surface UUID 고정 — caller 기준(focused 아님). 실패해도 복원 지령은 계속.
try:
    out = subprocess.check_output([CMUX, "identify", "--id-format", "both"], timeout=10)
    caller = json.loads(out).get("caller") or {}
    if caller.get("surface_id"):
        rec = {k: caller.get(k) for k in
               ("surface_id", "surface_ref", "pane_id", "pane_ref", "window_id", "workspace_id")}
        rec["cwd"] = cwd
        rec["session_id"] = d.get("session_id")
        rec["source"] = d.get("source")
        with open(os.path.expanduser("~/.cmux_master_surface"), "w") as f:
            f.write(json.dumps(rec, ensure_ascii=False, indent=2) + "\n")
except Exception:
    pass

# (2) 자동 복원 지령 주입 — 무엇을 입력하든 전 맥락 복원부터(트리거 불요)
ctx = (
    "🔄 [마스터 자동 복원 — 무조건 선행] 너는 이 워크스페이스의 **마스터**다. "
    "지금 들어온 사용자 입력이 무엇이든(인사·질문·작업지시 등 무관), 그것을 처리하기 **전에 반드시 먼저** "
    "전 맥락을 복원하라. 복원 순서:\n"
    "1) `~/.claude/projects/%s/memory/MEMORY.md` 색인 + 핵심 메모리" % project_slug(JARVIS_ROOT) +
    "(자비스 운영교리·절대지침 #01~#03·진행 백로그·복귀 체크포인트) 로드.\n"
    "2) `%s/master/SESSION_STATE.md`(현재상태·다음 액션 큐) + `%s/master/RECOVERY.md`(복원순서·정기스캔 cron 관리) 읽기.\n" % (JARVIS_ROOT, JARVIS_ROOT) +
    "3) 라이브 재점검: `cmux list-panes` · `ps`(claude/bun) · `uptime` → 워커 jsonl 상태 대조.\n"
    "4) cron 확인(lead 체제): 08시 정기발화는 **lead 소유**(master 아님) → `jarvis-who.sh lead`로 lead 생존 확인, "
    "08시 지났고 `~/.claude/cron/fired-<오늘>-*` 없으면 lead에 발화 지시(직접 실행 금지). master 자기 cron = **09:03 검증 cron** — "
    "`CronList`에 없으면 `master/RECOVERY.md` §정기 발화 Cron 관리의 프롬프트로 재등록. (구 08시 cron은 lead fired 3일 실증 후 삭제 예정.)\n"
    "5) 무인 워처(완료워처·CSO sentinel)·caffeinate 가동 확인, 끊겼으면 재가동.\n"
    "복원·재점검을 마친 뒤에야 사용자 입력에 답한다. 첫 응답 서두에 '복원 완료'를 1줄로 알린다. 호칭=오너."
)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                         "additionalContext": stale_guard() + inbox_backlog() + ctx}}, ensure_ascii=False))
