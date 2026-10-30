#!/usr/bin/env bash
# =============================================================
# 스모크: CLI 독립 세션 정책 + codex exec resume — 세션의 수명은 key(stage/attempt)가 정하고 CLI 는 어댑터다
# 파일 경로: tests/smoke-codex-resume.sh   (실제 LLM 호출 없음 — fake codex / fake claude, 임시 저장소)
# 사용법: bash tests/smoke-codex-resume.sh
#
# 불변식:
#   - codex thread id 는 최초 실행 이벤트 JSONL 의 thread.started 에서만 취득한다(--last·자동 검색 금지).
#   - 세션 확정은 두 단계다: invocation 의 유효한 결과 → 원장 .new 스테이징, 호출자의 role_session_accept → 확정.
#     수용되지 않은 세션은 다음 호출이 잇지 않는다.
#   - resume 실패·thread id 불일치·수용 미확인(marker)은 새 세션으로 조용히 대체하지 않고 중단한다(fail-closed).
#   - resume 에서도 읽기 전용 샌드박스·--output-schema·-o·--json·모델/effort 를 잃지 않는다.
# 사례 (U = 어댑터 단위 / L = impl-review-loop 통합):
#   U1. 같은 key 두 번, accept 없음 → 두 번 다 새 exec (스테이징만으로는 resume 하지 않음)
#   U2. accept 후 같은 key → exec resume <저장된 tid>, 플래그에 --json/--output-schema/-o/-c sandbox_mode="read-only", --last 없음, marker 는 accept 로 해제
#   U3. 원장 model 불일치 → SESSION_LEDGER_MISMATCH, codex 호출 0회 (자동 fresh 없음)
#   U4. resume marker 활성 → SESSION_RESUME_UNCERTAIN, codex 호출 0회
#   U5. 신규 호출 이벤트에 thread.started 없음/복수 → 세션 확정 금지(WARN), 재사용 계약 호출자의 accept 가 명시적 오류
#   U6. 재개 호출의 thread id 가 원장과 다름 → 결과 불수용, marker 유지
#   U7. resume CLI 실패(결과 없음) → 새 exec 로 대체하지 않음, marker 유지 → 재호출은 U4 로 차단
#   U8. 설치 CLI 의 exec resume 이 --output-schema 미지원 → ENV_ERROR, 스키마 없는 fallback 없음
#   U9. 호출마다 다른 key(검증자 정책) → 항상 새 exec, resume 없음
#   U10. 편집 역할(run_edit_role): accept 후 resume(-c sandbox_mode="workspace-write"), thread.started 없는 신규 호출은 WARN 후 세션 없이 진행
#   U11. resume help 에 --sandbox 가 있으면 -c sandbox_mode 에 더해 --sandbox 플래그도 전달
#   U12. stale .new — 거부된 호출이 스테이징한 원장을, 스테이징이 생략된(thread id 미확정) 후속 호출의 accept 가 확정하지 않는다
#   U13. CLI 변경(claude→codex) — 같은 key 의 claude 세션 위에서 codex 가 조용히 fresh 로 돌지 않고 SESSION_CLI_MISMATCH 로 중단
#   U14. CLI 변경(codex→claude) — 같은 key 의 codex 원장 위에서 claude 가 조용히 fresh 로 돌지 않고 중단
#   U15. 편집 역할 resume thread id 불일치 — rc 1 + 이번 -o 결과 제거(호출자가 "rc≠0+유효 결과" 경로로 수용하지 못함)
#   W1. crash recovery(codex) — accept(원장 확정) 후 저널 갱신 전 종료: ensure 가 WORKER_SESSION_MISMATCH 로 모델 0회 중단(자동 복구·fresh 없음)
#   W2. crash recovery(codex) — session_bound=true 인데 원장 소실: 같은 이유로 중단
#   L1. 리뷰어(codex) Round 1 새 exec → 수정자(claude) → Round 2 같은 thread 로 exec resume → APPROVE, 원장 수용 기록
#   L2. 승인 후 코드 변경 → 새 attempt 02 → attempt 01 스레드를 쓰지 않고 새 exec (원장 reviewer-a02, 다른 tid)
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-resume-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks" "$TMP/side"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"true\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"true\"|" "$CFG" && rm -f "$CFG.bak"
# 역할별 CLI 고정: 이 스모크는 codex 세션 어댑터 규약을 검증하므로 리뷰어를 codex 로, 수정자를 claude 로 고정한다.
# production config 의 모델→CLI 매핑이 바뀌어도 사례 의미가 유지된다(스모크 역할 CLI 고정 원칙).
sed -i.bak 's/^REVIEWER_CLI=.*/REVIEWER_CLI="codex"/; s/^VALIDATOR_CLI=.*/VALIDATOR_CLI="codex"/; s/^FIXER_CLI=.*/FIXER_CLI="claude"/; s/^DESIGNER_CLI=.*/DESIGNER_CLI="claude"/; s/^WORKER_CLI=.*/WORKER_CLI="claude"/' "$CFG" && rm -f "$CFG.bak"
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
echo "base" > src.txt 2>/dev/null || true
mkdir -p src && echo "base 01" > src/u01.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/u01.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
REVIEW_LOOP=".claude/skills/feature/scripts/impl-review-loop.sh"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" FEATURE_LIVE_TEE=1
mkdir -p "$MOCK_STATE"
: > "$MOCK_LOG"

# --- fake codex ---
# exec resume --help : resume 지원 플래그 목록(FAKE_RESUME_HELP_MINIMAL=1 이면 --output-schema 누락, FAKE_RESUME_HELP_SANDBOX=1 이면 --sandbox 포함)
# exec [resume <id>] : 플래그를 한 줄로 MOCK_LOG 에 기록, thread.started + turn.completed 이벤트를 stdout 에, -o 에 픽스처($MOCK_STATE/review-<n>.json, 없으면 review-default.json) 복사
#   FAKE_NO_THREAD_STARTED=1  : thread.started 를 내지 않음
#   FAKE_DUP_THREAD_STARTED=1 : 서로 다른 thread.started 2개
#   FAKE_RESUME_TID=<id>      : 재개 호출이 보고하는 thread id 를 저장된 것과 다르게
#   FAKE_RESUME_RC_FAIL=1     : 재개 호출이 아무 출력 없이 exit 1
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = exec ] || { echo "unexpected argv: $*" >&2; exit 9; }
shift
mode=new; sid=""
if [ "${1:-}" = resume ]; then
  shift
  if [ "${1:-}" = --help ]; then
    echo "Resume a previous session by id"
    echo "      --json"
    [ "${FAKE_RESUME_HELP_MINIMAL:-0}" = 1 ] || echo "      --output-schema <FILE>"
    echo "  -o, --output-last-message <FILE>"
    [ "${FAKE_RESUME_HELP_SANDBOX:-0}" = 1 ] && echo "  -s, --sandbox <SANDBOX_MODE>"
    exit 0
  fi
  mode=resume; sid="${1:?resume session id 없음}"; shift
fi
out=""; flags=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; flags="$flags -o"; shift 2;;
    --output-schema) flags="$flags --output-schema"; shift 2;;
    -m) flags="$flags -m=$2"; shift 2;;
    --sandbox) flags="$flags --sandbox=$2"; shift 2;;
    -c) flags="$flags -c $2"; shift 2;;
    --json) flags="$flags --json"; shift;;
    --last) flags="$flags --last"; shift;;
    *) shift;;   # prompt
  esac
done
echo "codex $mode ${sid:-none}$flags" >> "$MOCK_LOG"
if [ "$mode" = resume ] && [ "${FAKE_RESUME_RC_FAIL:-0}" = 1 ]; then exit 1; fi
n=$(( $(cat "$MOCK_STATE/codex.n" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$MOCK_STATE/codex.n"
if [ "${FAKE_NO_THREAD_STARTED:-0}" != 1 ]; then
  if [ "$mode" = resume ]; then tid="${FAKE_RESUME_TID:-$sid}"; else tid="tid-$n"; fi
  printf '{"type":"thread.started","thread_id":"%s"}\n' "$tid"
  [ "${FAKE_DUP_THREAD_STARTED:-0}" = 1 ] && printf '{"type":"thread.started","thread_id":"%s-dup"}\n' "$tid"
fi
printf '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":3,"output_tokens":10,"reasoning_output_tokens":2}}\n'
echo "diag" >&2
if [ -n "$out" ]; then
  f="$MOCK_STATE/review-$n.json"; [ -f "$f" ] || f="$MOCK_STATE/review-default.json"
  cp "$f" "$out"
fi
exit "${FAKE_CODEX_RC:-0}"
EOF
# --- fake claude (수정자 전용: FAKE_EDIT_CMD 실행) ---
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
session=""
while [ "$#" -gt 0 ]; do case "$1" in --session-id|--resume) session="$1"; shift 2;; -p) shift;; --model|--effort|--output-format|--allowedTools|--disallowedTools|--append-system-prompt|--permission-mode|--json-schema) shift 2;; *) shift;; esac; done
echo "claude editor $session" >> "$MOCK_LOG"
eval "${FAKE_EDIT_CMD:-true}"
printf '{"result":"ok","session_id":"fake","total_cost_usd":0,"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
exit "${FAKE_EDIT_RC:-0}"
EOF
chmod +x "$TMP/bin/codex" "$TMP/bin/claude"
printf '{"ok":true}\n' > "$MOCK_STATE/review-default.json"

codex_calls() { grep -c '^codex ' "$MOCK_LOG" || true; }
resume_calls() { grep -c '^codex resume ' "$MOCK_LOG" || true; }
reset_case() { : > "$MOCK_LOG"; rm -f "$MOCK_STATE"/codex.n "$MOCK_STATE"/review-[0-9]*.json .agent-work/.session-* .agent-work/usage.jsonl .agent-work/cli-anomalies.jsonl; }
# 어댑터 단위 실행: 하위 셸에서 config 를 소싱해 호출한다 (CODEX_RESUME_CHECKED 캐시도 호출 단위로 초기화됨)
ro_call() { # key out
  ( set -e; source "$CFG"; run_readonly_json_role REVIEWER "$1" "smoke-$1" .claude/skills/feature/schemas/impl-review.schema.json "$2" "prompt" "" )
}
accept() { ( set -e; source "$CFG"; role_session_accept "$1" "$2" "smoke-accept" ); }

# ===== U1: 같은 key 두 번, accept 없음 → 둘 다 새 exec =====
reset_case
ro_call k1 "$TMP/side/u1a.json" || fail "U1: 1차 호출 실패"
ro_call k1 "$TMP/side/u1b.json" || fail "U1: 2차 호출 실패"
[ "$(resume_calls)" -eq 0 ] || fail "U1: accept 없이 resume 이 일어남: $(cat "$MOCK_LOG")"
[ "$(codex_calls)" -eq 2 ] || fail "U1: codex 호출 2회가 아님"
[ -f .agent-work/.session-k1.codex.json.new ] || fail "U1: 원장 스테이징(.new) 없음"
[ ! -f .agent-work/.session-k1.codex.json ] || fail "U1: accept 없이 원장이 확정됨"
pass "U1: 스테이징만으로는 resume 하지 않음 (accept 전 두 호출 모두 새 exec)"

# ===== U2: accept 후 같은 key → 저장된 tid 로 exec resume, 계약 플래그 유지 =====
reset_case
ro_call k2 "$TMP/side/u2a.json" || fail "U2: 1차 호출 실패"
accept REVIEWER k2 || fail "U2: accept 실패"
[ -f .agent-work/.session-k2.codex.json ] || fail "U2: 원장 미확정"
tid="$(jq -r .thread_id .agent-work/.session-k2.codex.json)"
[ "$tid" = tid-1 ] || fail "U2: thread id 가 이벤트의 것이 아님: $tid"
jq -e --argjson v "$REVIEW_CONTRACT" '.role=="REVIEWER" and .cli=="codex" and (.contract_version|tonumber)==$v' .agent-work/.session-k2.codex.json >/dev/null || fail "U2: 원장 메타데이터 불일치: $(cat .agent-work/.session-k2.codex.json)"
ro_call k2 "$TMP/side/u2b.json" || fail "U2: resume 호출 실패"
line="$(grep '^codex resume ' "$MOCK_LOG")" || fail "U2: resume 호출 없음: $(cat "$MOCK_LOG")"
case "$line" in "codex resume tid-1"*) ;; *) fail "U2: 저장된 tid 로 resume 하지 않음: $line";; esac
for f in --json --output-schema ' -o' 'sandbox_mode="read-only"' '-m=' 'model_reasoning_effort'; do
  case "$line" in *"$f"*) ;; *) fail "U2: resume 호출에 '$f' 없음: $line";; esac
done
case "$line" in *--last*) fail "U2: --last 사용됨";; *--sandbox=*) fail "U2: help 에 없는 --sandbox 플래그 사용됨";; esac
[ -f .agent-work/.session-k2.resume-pending.json ] || fail "U2: resume marker 없음(수용 전)"
accept REVIEWER k2 || fail "U2: 2차 accept 실패"
[ ! -f .agent-work/.session-k2.resume-pending.json ] || fail "U2: accept 후 marker 미해제"
[ "$(jq -r .last_accepted_label .agent-work/.session-k2.codex.json)" = smoke-accept ] || fail "U2: 수용 기록 없음"
pass "U2: accept 된 key 는 저장 tid 로 resume + 스키마/샌드박스/모델 계약 유지, --last 없음, marker 해제"

# ===== U3: 원장 불일치(model 변경) → 호출 전 중단, 자동 fresh 없음 =====
calls_before="$(codex_calls)"
jq '.model="other-model"' .agent-work/.session-k2.codex.json > t && mv t .agent-work/.session-k2.codex.json
ro_call k2 "$TMP/side/u3.json" > "$TMP/u3.log" 2>&1 && fail "U3: 불일치 원장인데 성공"
grep -q SESSION_LEDGER_MISMATCH "$TMP/u3.log" || fail "U3: SESSION_LEDGER_MISMATCH 메시지 없음"
[ "$(codex_calls)" -eq "$calls_before" ] || fail "U3: 불일치인데 codex 가 호출됨"
pass "U3: 원장 설정 불일치 → 모델 호출 0회로 중단 (자동 resume·fresh 없음)"

# ===== U4: marker 활성 → 호출 전 중단 =====
reset_case
ro_call k4 "$TMP/side/u4a.json" && accept REVIEWER k4 || fail "U4: 준비 실패"
printf '{"key":"k4","invocation_id":"x","label":"y","recorded_at":"z"}\n' > .agent-work/.session-k4.resume-pending.json
calls_before="$(codex_calls)"
ro_call k4 "$TMP/side/u4b.json" > "$TMP/u4.log" 2>&1 && fail "U4: marker 활성인데 성공"
grep -q SESSION_RESUME_UNCERTAIN "$TMP/u4.log" || fail "U4: SESSION_RESUME_UNCERTAIN 메시지 없음"
[ "$(codex_calls)" -eq "$calls_before" ] || fail "U4: marker 활성인데 codex 가 호출됨"
pass "U4: 수용 미확인 marker → 재전송 없이 중단"

# ===== U5: thread.started 없음/복수 → 세션 확정 금지, 재사용 계약(accept)이 명시적 오류 =====
reset_case
FAKE_NO_THREAD_STARTED=1 ro_call k5 "$TMP/side/u5.json" > "$TMP/u5.log" 2>&1 || fail "U5: 호출 자체는 성공해야 함(결과 게이트는 호출자 소관)"
grep -q 'thread.started.thread_id 미확정' "$TMP/u5.log" || fail "U5: 세션 미확정 WARN 없음"
[ ! -f .agent-work/.session-k5.codex.json.new ] && [ ! -f .agent-work/.session-k5.codex.json ] || fail "U5: 세션이 확정/스테이징됨"
accept REVIEWER k5 > "$TMP/u5a.log" 2>&1 && fail "U5: 확정할 세션이 없는데 accept 가 성공"
grep -q '확정할 codex 세션이 없음' "$TMP/u5a.log" || fail "U5: accept 의 명시적 오류 없음"
FAKE_DUP_THREAD_STARTED=1 ro_call k5 "$TMP/side/u5b.json" > "$TMP/u5b.log" 2>&1 || fail "U5: 복수 id 호출 자체는 성공해야 함"
grep -q 'thread.started.thread_id 미확정' "$TMP/u5b.log" || fail "U5: 복수 id 에서 세션 미확정 WARN 없음"
[ ! -f .agent-work/.session-k5.codex.json.new ] || fail "U5: 복수 id 인데 스테이징됨"
pass "U5: thread.started 0개·복수 → 세션 확정 금지, 재사용 계약 accept 는 명시적 오류"

# ===== U6: 재개 thread id 불일치 → 결과 불수용, marker 유지 =====
reset_case
ro_call k6 "$TMP/side/u6a.json" && accept REVIEWER k6 || fail "U6: 준비 실패"
FAKE_RESUME_TID=tid-999 ro_call k6 "$TMP/side/u6b.json" > "$TMP/u6.log" 2>&1 && fail "U6: id 불일치인데 성공"
grep -q 'thread id 가 원장과 다름' "$TMP/u6.log" || fail "U6: 불일치 오류 없음"
[ ! -f "$TMP/side/u6b.json" ] || fail "U6: 불일치 결과가 수용됨"
[ -f .agent-work/.session-k6.resume-pending.json ] || fail "U6: marker 가 해제됨"
pass "U6: 재개된 id 가 원장과 다르면 결과 불수용 + marker 유지"

# ===== U7: resume 실패 → 새 exec 대체 없음, marker 유지, 재호출은 marker 로 차단 =====
reset_case
ro_call k7 "$TMP/side/u7a.json" && accept REVIEWER k7 || fail "U7: 준비 실패"
: > "$MOCK_LOG"
FAKE_RESUME_RC_FAIL=1 ro_call k7 "$TMP/side/u7b.json" > "$TMP/u7.log" 2>&1 && fail "U7: resume 실패인데 성공"
grep -q '자동 새 세션 전환 없음' "$TMP/u7.log" || fail "U7: fail-closed 메시지 없음"
[ "$(resume_calls)" -eq 1 ] && [ "$(codex_calls)" -eq 1 ] || fail "U7: resume 실패 후 추가 호출(새 exec 대체) 발생: $(cat "$MOCK_LOG")"
[ -f .agent-work/.session-k7.resume-pending.json ] || fail "U7: marker 없음"
ro_call k7 "$TMP/side/u7c.json" > "$TMP/u7c.log" 2>&1 && fail "U7: marker 활성 재실행이 성공"
grep -q SESSION_RESUME_UNCERTAIN "$TMP/u7c.log" || fail "U7: 재실행이 marker 로 차단되지 않음"
pass "U7: resume 실패 → fresh 대체 없음, 재실행은 marker 로 모델 호출 0회 차단"

# ===== U8: 설치 CLI 가 resume --output-schema 미지원 → ENV_ERROR =====
reset_case
ro_call k8 "$TMP/side/u8a.json" && accept REVIEWER k8 || fail "U8: 준비 실패"
calls_before="$(codex_calls)"
FAKE_RESUME_HELP_MINIMAL=1 ro_call k8 "$TMP/side/u8b.json" > "$TMP/u8.log" 2>&1 && fail "U8: 미지원인데 성공"
grep -q 'ENV_ERROR' "$TMP/u8.log" || fail "U8: ENV_ERROR 없음"
[ "$(codex_calls)" -eq "$calls_before" ] || fail "U8: 미지원인데 resume 이 실행됨"
pass "U8: resume 옵션 미지원 → 스키마 우회 없이 ENV_ERROR"

# ===== U9: 호출마다 다른 key(검증자 정책) → 항상 새 exec =====
reset_case
ro_call v-r1-aaa "$TMP/side/u9a.json" || fail "U9: 1차 실패"
ro_call v-r2-bbb "$TMP/side/u9b.json" || fail "U9: 2차 실패"
[ "$(resume_calls)" -eq 0 ] && [ "$(codex_calls)" -eq 2 ] || fail "U9: 고유 key 인데 resume 발생"
pass "U9: key 가 다르면 항상 fresh (검증자 정책은 key 로 구현됨)"

# ===== U10: 편집 역할 공용 로직 — accept 후 resume(workspace-write), thread 미확정 신규는 WARN =====
reset_case
edit_call() { ( set -e; source "$CFG"; FIXER_CLI=codex run_edit_role FIXER "$1" "smoke-edit-$1" "$TMP/side/edit-$1.raw" "prompt" "" "" "" ); }
edit_call e1 || fail "U10: 1차 편집 호출 실패"
( set -e; source "$CFG"; FIXER_CLI=codex role_session_accept FIXER e1 "smoke-accept" ) || fail "U10: accept 실패"
edit_call e1 || fail "U10: resume 편집 호출 실패"
line="$(grep '^codex resume ' "$MOCK_LOG")" || fail "U10: 편집 resume 없음"
case "$line" in *'sandbox_mode="workspace-write"'*) ;; *) fail "U10: workspace-write 샌드박스 없음: $line";; esac
: > "$MOCK_LOG"
FAKE_NO_THREAD_STARTED=1 edit_call e2 > "$TMP/u10.log" 2>&1 || fail "U10: thread 미확정 신규 편집 호출이 실패함(편집 역할은 WARN)"
grep -q 'thread.started.thread_id 미확정' "$TMP/u10.log" || fail "U10: WARN 없음"
[ ! -f .agent-work/.session-e2.codex.json.new ] || fail "U10: 미확정인데 스테이징됨"
pass "U10: 편집 역할도 같은 어댑터 — accept 후 resume, 미확정 신규는 WARN 후 세션 없이 진행"

# ===== U11: resume help 에 --sandbox 가 있으면 플래그도 전달 =====
reset_case
ro_call k11 "$TMP/side/u11a.json" && accept REVIEWER k11 || fail "U11: 준비 실패"
FAKE_RESUME_HELP_SANDBOX=1 ro_call k11 "$TMP/side/u11b.json" || fail "U11: resume 실패"
line="$(grep '^codex resume ' "$MOCK_LOG")"
case "$line" in *'--sandbox=read-only'*'sandbox_mode="read-only"'*|*'sandbox_mode="read-only"'*'--sandbox=read-only'*) ;; *) fail "U11: --sandbox + -c 둘 다 전달되지 않음: $line";; esac
pass "U11: 설치 CLI 가 --sandbox 를 지원하면 함께 전달"

# ===== U12: stale .new — 거부된 스테이징을 후속 호출의 accept 가 확정하지 않는다 =====
reset_case
ro_call k12 "$TMP/side/u12a.json" || fail "U12: 1차 호출 실패"
[ -f .agent-work/.session-k12.codex.json.new ] || fail "U12: 1차 스테이징 없음"
# 1차 결과는 호출자가 거부했다(accept 없음). 2차 호출은 thread id 미확정이라 스테이징을 생략한다 —
# 이때 accept 가 1차의 stale .new 를 확정하면 거부된 대화 스레드로 resume 하게 된다.
FAKE_NO_THREAD_STARTED=1 ro_call k12 "$TMP/side/u12b.json" > "$TMP/u12.log" 2>&1 || fail "U12: 2차 호출 실패"
accept REVIEWER k12 > "$TMP/u12a.log" 2>&1 && fail "U12: stale .new 가 확정됨"
grep -q '확정할 codex 세션이 없음' "$TMP/u12a.log" || fail "U12: accept 의 명시적 오류 없음"
[ ! -f .agent-work/.session-k12.codex.json ] && [ ! -f .agent-work/.session-k12.codex.json.new ] || fail "U12: stale 원장이 남아 확정 가능 상태"
pass "U12: 거부된 invocation 의 .new 는 후속 호출 시작 시 제거 — accept 가 확정하지 못함"

# ===== U13: claude→codex 전환 — 같은 key 면 자동 fresh 없이 중단 =====
reset_case
printf '11111111-2222-3333-4444-555555555555\n' > .agent-work/.session-k13   # 수용된 claude 세션
calls_before="$(codex_calls)"
ro_call k13 "$TMP/side/u13.json" > "$TMP/u13.log" 2>&1 && fail "U13: claude 세션 위에서 codex 가 성공"
grep -q SESSION_CLI_MISMATCH "$TMP/u13.log" || fail "U13: SESSION_CLI_MISMATCH 없음"
[ "$(codex_calls)" -eq "$calls_before" ] || fail "U13: 중단인데 codex 가 호출됨"
pass "U13: claude 에 결속된 key 로 codex 라우팅 → 모델 0회 중단 (자동 fresh 없음)"

# ===== U14: codex→claude 전환 — 같은 key 면 자동 fresh 없이 중단 =====
reset_case
ro_call k14 "$TMP/side/u14a.json" && accept REVIEWER k14 || fail "U14: codex 원장 준비 실패"
( set -e; source "$CFG"; REVIEWER_CLI=claude run_readonly_json_role REVIEWER k14 smoke-u14 \
    .claude/skills/feature/schemas/impl-review.schema.json "$TMP/side/u14b.json" "prompt" "" ) > "$TMP/u14.log" 2>&1 \
  && fail "U14: codex 원장 위에서 claude 가 성공"
grep -q SESSION_CLI_MISMATCH "$TMP/u14.log" || fail "U14: SESSION_CLI_MISMATCH 없음"
grep -q '^claude ' "$MOCK_LOG" && fail "U14: 중단인데 claude 가 호출됨"
pass "U14: codex 원장에 결속된 key 로 claude 라우팅 → 모델 0회 중단"

# ===== U15: 편집 역할 resume thread id 불일치 → rc 1 + 이번 -o 결과 제거 =====
reset_case
edit_schema_call() { ( set -e; source "$CFG"; FIXER_CLI=codex run_edit_role FIXER "$1" "smoke-e15" "$TMP/side/e15.raw" "prompt" "" .claude/skills/feature/schemas/impl-review.schema.json "$TMP/side/e15-result.json" ); }
edit_schema_call e15 || fail "U15: 1차 편집 호출 실패"
( set -e; source "$CFG"; FIXER_CLI=codex role_session_accept FIXER e15 smoke ) || fail "U15: accept 실패"
rm -f "$TMP/side/e15-result.json"
FAKE_RESUME_TID=tid-999 edit_schema_call e15 > "$TMP/u15.log" 2>&1 && fail "U15: id 불일치인데 rc 0"
grep -q 'thread id 가 원장과 다름' "$TMP/u15.log" || fail "U15: 불일치 오류 없음"
[ ! -f "$TMP/side/e15-result.json" ] || fail "U15: 불일치 invocation 의 -o 결과가 남아 수용 가능"
pass "U15: 편집 resume 불일치 → 결과 파일 제거, 호출자가 '유효 결과'로 수용 불가"

# ===== W1/W2: Feature Worker 저널 ↔ codex 원장 4분면 crash recovery (모델 0회) =====
reset_case
ensure_env() { # journal-bound ledger(yes|no) → ensure 종료코드, 로그 $TMP/w.log
  rm -f .agent-work/worker-session.json .agent-work/.session-feature-worker.codex.json
  ( set -e
    source "$CFG"
    SKILL_DIR="$TMP/repo/.claude/skills/feature"; WORKER_SCHEMA="$SKILL_DIR/schemas/worker-result.schema.json"
    WORKER_CLI=codex
    log() { echo "$*"; }; env_error() { echo "[ENV] $*" >&2; exit 1; }
    stop_need_user() { echo "[STOP] $1 $2" >&2; exit 2; }; stop_need_docs() { exit 3; }
    source "$SKILL_DIR/scripts/worker-invoke.sh"
    fp="$(worker_contract_fingerprint)" || exit 1
    model="$(role_model WORKER)"; effort="$(role_effort WORKER)"
    jq -n --argjson v 1 --arg cli codex --arg model "$model" --arg effort "$effort" --arg fp "$fp" --argjson bound "$1" \
      '{version:$v, session:"feature-worker", cli:$cli, model:$model, effort:$effort, contract_fingerprint:$fp,
        generation:1, session_bound:$bound, session_id:null, last_completed_unit_id:null, last_completed_tree:null, created_at:"t"}' \
      > .agent-work/worker-session.json
    if [ "$2" = yes ]; then
      jq -n --arg model "$model" --arg effort "$effort" --arg cv "" --arg root "$PROJECT_ROOT" \
        '{version:1, key:"feature-worker", role:"WORKER", cli:"codex", model:$model, effort:$effort, contract_version:$cv,
          project_root:$root, thread_id:"tid-w", created_at:"t", last_accepted_label:"", last_accepted_at:""}' \
        > .agent-work/.session-feature-worker.codex.json
    fi
    ensure_feature_worker_session
  ) > "$TMP/w.log" 2>&1
}
ensure_env false yes; rc=$?   # W1: accept(원장 확정) 후 저널 갱신 전 종료
[ "$rc" -eq 2 ] && grep -q 'WORKER_SESSION_MISMATCH' "$TMP/w.log" && grep -q '미결속' "$TMP/w.log" \
  || { cat "$TMP/w.log"; fail "W1: 원장 확정 + 저널 미결속이 중단되지 않음 (rc=$rc)"; }
[ "$(codex_calls)" -eq 0 ] || fail "W1: 모델이 호출됨"
pass "W1: accept 후 저널 갱신 전 crash → ensure 가 모델 0회 중단 (자동 복구·자동 fresh 없음)"
ensure_env true no; rc=$?     # W2: 결속 기록은 있는데 원장 소실
[ "$rc" -eq 2 ] && grep -q 'WORKER_SESSION_MISMATCH' "$TMP/w.log" && grep -q '소실' "$TMP/w.log" \
  || { cat "$TMP/w.log"; fail "W2: 원장 소실이 중단되지 않음 (rc=$rc)"; }
ensure_env false no; rc=$?    # 대조: 미생성(둘 다 없음)은 정상 통과
[ "$rc" -eq 0 ] || { cat "$TMP/w.log"; fail "W2: 미생성 상태가 통과하지 않음 (rc=$rc)"; }
ensure_env true yes; rc=$?    # 대조: 결속+원장 일치는 통과
[ "$rc" -eq 0 ] || { cat "$TMP/w.log"; fail "W2: 정상 결속 상태가 통과하지 않음 (rc=$rc)"; }
pass "W2: 원장 소실 → 중단 / 미생성·정상 결속 → 통과 (4분면 불변식)"

# ===== L1: 리뷰 루프 — Round 1 새 exec → 수정자 → Round 2 같은 thread resume → APPROVE =====
reset_case
rm -rf .agent-work/reviews/impl-attempt-* .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/feature-scope.lock.json
git checkout -q -- src/u01.txt
( source "$CFG"; snapshot_worktree_tree ) > .agent-work/worker-baseline.tree
echo "worker edit" >> src/u01.txt
cp .agent-work/feature-scope.json .agent-work/feature-scope.lock.json
printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}\n' > .agent-work/worker-result.json
review_issue='{"id":"R-01","action":"FIX_CODE","category":"CONTRACT_VIOLATION","evidence_type":"DIRECT_MISMATCH","basis_refs":["approach.md:L1"],"code_refs":["src/u01.txt:L1-L1"],"reachable_scenario":"","impact":"","why_blocks_now":"x","required_outcome":"y","origin":"ROUND_1","previous_issue_id":"","fix_ref":""}'
printf '%s' "$review_issue" | jq -c --argjson v "$REVIEW_CONTRACT" '{schema_version:$v,verdict:"REQUEST_CHANGES",issues:[.]}' > "$MOCK_STATE/review-1.json"
printf '{"schema_version":%s,"verdict":"APPROVE","issues":[]}\n' "$REVIEW_CONTRACT" > "$MOCK_STATE/review-2.json"
FAKE_EDIT_CMD='echo fixed >> src/u01.txt; echo "- [fix round 1] R-01 ACCEPT" >> .agent-work/decisions.md' bash "$REVIEW_LOOP" > "$TMP/l1.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { tail -30 "$TMP/l1.log"; fail "L1: 루프 exit 0 기대, 실제 $rc"; }
[ "$(grep -c '^codex new ' "$MOCK_LOG")" -eq 1 ] || fail "L1: 새 exec 1회가 아님: $(grep ^codex "$MOCK_LOG")"
line="$(grep '^codex resume ' "$MOCK_LOG")" || fail "L1: round 2 resume 없음"
case "$line" in "codex resume tid-1"*) ;; *) fail "L1: round 1 의 thread 가 아님: $line";; esac
jq -e '.key=="reviewer-a01" and .thread_id=="tid-1" and .last_accepted_label=="impl-review-a01-round-02"' .agent-work/.session-reviewer-a01.codex.json >/dev/null \
  || fail "L1: 리뷰어 원장 불일치: $(cat .agent-work/.session-reviewer-a01.codex.json)"
[ ! -f .agent-work/.session-reviewer-a01.resume-pending.json ] || fail "L1: marker 미해제"
[ -f .agent-work/.session-fixer-a01 ] || fail "L1: 수정자(claude) 세션 파일 없음"
jq -e '.next_step=="APPROVE" and .round==2 and .attempt==1' .agent-work/review-impl.json >/dev/null || fail "L1: 체크포인트가 APPROVE 가 아님"
[ "$(jq -r 'select(.role=="REVIEWER") | .cli' .agent-work/usage.jsonl | paste -sd, -)" = "codex,codex" ] || fail "L1: 리뷰어 usage 행 2개(codex)가 아님"
pass "L1: Round 1 새 exec → Round 2 같은 thread resume → APPROVE, 원장 수용 기록"

# ===== L2: 승인 후 변경 → 새 attempt 는 이전 스레드를 쓰지 않음 =====
: > "$MOCK_LOG"
echo "post-approve change" >> src/u01.txt
printf '{"schema_version":%s,"verdict":"APPROVE","issues":[]}\n' "$REVIEW_CONTRACT" > "$MOCK_STATE/review-3.json"
bash "$REVIEW_LOOP" > "$TMP/l2.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { tail -30 "$TMP/l2.log"; fail "L2: 루프 exit 0 기대, 실제 $rc"; }
[ "$(resume_calls)" -eq 0 ] || fail "L2: 새 attempt 가 이전 스레드를 resume 함: $(grep ^codex "$MOCK_LOG")"
[ "$(grep -c '^codex new ' "$MOCK_LOG")" -eq 1 ] || fail "L2: 새 exec 1회가 아님"
jq -e '.key=="reviewer-a02" and .thread_id=="tid-3"' .agent-work/.session-reviewer-a02.codex.json >/dev/null || fail "L2: attempt 02 원장 불일치"
[ "$(jq -r .thread_id .agent-work/.session-reviewer-a01.codex.json)" != "$(jq -r .thread_id .agent-work/.session-reviewer-a02.codex.json)" ] || fail "L2: attempt 간 thread 공유됨"
pass "L2: Attempt 02 는 Attempt 01 스레드와 무관한 새 세션"

echo "[SMOKE OK] codex resume 세션 정책 스모크 전체 통과"
rm -rf "$TMP"
