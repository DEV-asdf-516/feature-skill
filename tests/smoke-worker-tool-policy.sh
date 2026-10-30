#!/usr/bin/env bash
# =============================================================
# 스모크: 워커 CLI 도구 제한 — SH 강제 (P0-1). 실제 LLM 호출 없음(가짜 claude/codex 가 argv·환경을 기록), 임시 저장소.
# 파일 경로: tests/smoke-worker-tool-policy.sh
# 사용법: bash tests/smoke-worker-tool-policy.sh
#
# 사례:
#   A. Claude 워커: 최초(--session-id)·resume(--resume)·test-fix 호출 모두 --disallowedTools "Agent,ScheduleWakeup" + child 환경변수
#      CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 / CLAUDE_CODE_DISABLE_AGENT_VIEW=1. SendMessage 는 금지 목록에 없음. --allowedTools Bash 는 그대로(편집·테스트 허용).
#      같은 실행의 Claude 리뷰어·디자이너·수정자 호출에는 그 플래그도 환경변수도 없다. 러너(부모) 환경에도 없다.
#   B. Codex 워커: exec(최초)·exec resume(후속 unit) 모두 -c 'agents.enabled=false' 가 다른 -c 뒤에 붙는다. Codex 검증자(read-only)에는 없다.
#      전역 ~/.codex/config.toml 은 건드리지 않는다(CODEX_HOME 아래 파일 불변).
#   C. CLI 가 --disallowedTools 를 거부하면 그 호출은 실패로 끝나고 제한 없는 재실행이 없다(워커 호출 1회, 무제한 재호출 0회).
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-toolpolicy-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks" "$TMP/codex-home"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"echo full-test >> $TMP/calls.log\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"echo full-lint >> $TMP/calls.log\"|" "$CFG" && rm -f "$CFG.bak"
# 기본: 워커·리뷰어·디자이너·수정자 claude, 검증자 codex. 사례 B 에서 워커를 codex 로 바꾼다.
sed -i.bak 's/^VALIDATOR_CLI=.*/VALIDATOR_CLI="codex"/; s/^WORKER_CLI=.*/WORKER_CLI="claude"/; s/^DESIGNER_CLI=.*/DESIGNER_CLI="claude"/; s/^FIXER_CLI=.*/FIXER_CLI="claude"/; s/^REVIEWER_CLI=.*/REVIEWER_CLI="claude"/' "$CFG" && rm -f "$CFG.bak"
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && for u in 01 02; do echo "base $u" > "src/u$u.txt"; done
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/u01.txt","src/u02.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
cat > .agent-work/implementation-units.json <<EOF
{"version":1,"units":[
 {"id":"01-intake","title":"접수","goal":"unit 01","requirements":["REQ-01"],"scope":{"files":["src/u01.txt"],"new_file_roots":[]},"references":["implementation.md#01"],"targeted_test":"bash -c 'if [ -f $TMP/fail-test-01 ]; then rm -f $TMP/fail-test-01; echo test-01-fail >> $TMP/calls.log; exit 1; fi; echo test-01 >> $TMP/calls.log'"},
 {"id":"02-drop","title":"Drop","goal":"unit 02","requirements":["REQ-02"],"scope":{"files":["src/u02.txt"],"new_file_roots":[]},"references":["implementation.md#02"],"targeted_test":"echo test-02 >> $TMP/calls.log"}
]}
EOF
RUN=".claude/skills/feature/scripts/feature-run.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" FEATURE_LIVE_TEE=1 MOCK_VALIDATOR_CONTRACT="$CONTRACT" MOCK_REVIEW_CONTRACT="$REVIEW_CONTRACT" CODEX_HOME="$TMP/codex-home"
mkdir -p "$MOCK_STATE"
printf 'model = "keep"\n' > "$TMP/codex-home/config.toml"; cp "$TMP/codex-home/config.toml" "$TMP/codex-config.orig"

# --- 공용 mock CLI: 호출마다 argv 한 줄($MOCK_STATE/argv.log: "<cli> <role> <argv...>")과 환경($MOCK_STATE/env.log) 을 기록. 역할은 스키마로 판별 ---
cat > "$TMP/bin/mock-cli" <<'EOF'
#!/usr/bin/env bash
cli="$(basename "$0")"; argv_all="$*"
out=""; schema=""; prompt=""; editing=0; resume_tid=""; session_flag=""; want_help=0
if [ "$cli" = codex ] && [ "${1:-}" = exec ] && [ "${2:-}" = resume ]; then [ "${3:-}" = --help ] && want_help=1 || resume_tid="$3"; fi
[ "$want_help" = 1 ] && { echo "usage: codex exec resume [--json] [--output-schema] [--output-last-message] [--sandbox]"; exit 0; }
args=("$@")
while [ "$#" -gt 0 ]; do case "$1" in
  exec|resume|-p|--json|--verbose) shift;;
  -o) out="$2"; shift 2;;
  --output-schema) schema="$(cat "$2")"; shift 2;;
  --json-schema) schema="$2"; shift 2;;
  --sandbox) [ "$2" = workspace-write ] && editing=1; shift 2;;
  --permission-mode) editing=1; shift 2;;
  --session-id|--resume) session_flag="$1"; shift 2;;
  -m|-c|--model|--effort|--output-format|--tools|--allowedTools|--disallowedTools|--append-system-prompt) shift 2;;
  *) prompt="$1"; shift;;
esac; done
usage='"session_id":"fake","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
[ "$cli" = codex ] && printf '{"type":"thread.started","thread_id":"%s"}\n' "${resume_tid:-mock-thread-$$}"
emit() { if [ "$cli" = codex ]; then if [ -n "$out" ]; then printf '%s\n' "$1" > "$out"; else printf '%s\n' "$1"; fi; printf '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1}}\n'
        else printf '{"type":"result","structured_output":%s,%s}\n' "$1" "$usage"; fi; }
role=""
case "$schema" in *'"blocking_issues"'*) role=validator;; *'"issues"'*) role=reviewer;; *'"context_updates"'*) role=worker;; "") [ "$editing" = 1 ] && role=editor;; esac
[ -n "$role" ] || { echo "UNKNOWN-ROLE" >> "$MOCK_LOG"; exit 1; }
# argv 는 프롬프트(마지막 인자)를 뺀 나머지를 기록한다(프롬프트에 'Agent' 같은 단어가 섞여 오탐하지 않게)
argv_no_prompt=(); for a in "${args[@]}"; do [ "$a" = "$prompt" ] || argv_no_prompt+=("$a"); done
{ printf '%s %s %s ' "$cli" "$role" "${session_flag:-${resume_tid:+resume}}"; printf '%s' "${argv_no_prompt[*]}" | tr '\n' ' '; printf '\n'; } >> "$MOCK_STATE/argv.log"   # 스키마 본문의 줄바꿈 제거(한 호출 = 한 줄)
printf '%s %s bg=%s agentview=%s\n' "$cli" "$role" "${CLAUDE_CODE_DISABLE_BACKGROUND_TASKS:-unset}" "${CLAUDE_CODE_DISABLE_AGENT_VIEW:-unset}" >> "$MOCK_STATE/env.log"
# 사례 C: --disallowedTools 를 거부하는 CLI 흉내
if [ "$cli" = claude ] && [ "$role" = worker ] && [ -f "$MOCK_STATE/reject-disallowed" ]; then
  case " ${args[*]} " in *" --disallowedTools "*) echo "error: unknown option '--disallowedTools'" >&2; echo "worker-rejected" >> "$MOCK_LOG"; exit 1;; esac
fi
case "$role" in
  validator) echo "validator" >> "$MOCK_LOG"; emit "{\"schema_version\":$MOCK_VALIDATOR_CONTRACT,\"verdict\":\"PASS\",\"blocking_issues\":[]}"; exit 0;;
  editor) echo "editor" >> "$MOCK_LOG"; if [ "$cli" = codex ]; then echo ok; else printf '{"type":"result","result":"ok",%s}\n' "$usage"; fi; exit 0;;
  reviewer) echo "reviewer" >> "$MOCK_LOG"; emit "{\"schema_version\":$MOCK_REVIEW_CONTRACT,\"verdict\":\"APPROVE\",\"issues\":[]}"; exit 0;;
esac
unit="$(printf '%s' "$prompt" | grep -oE '"id": *"[0-9]+-[a-z0-9-]+"' | head -1 | sed -E 's/.*"([0-9]+-[a-z0-9-]+)"/\1/')"
n="${unit%%-*}"
if printf '%s' "$prompt" | grep -q 'targeted test'; then echo "test-fix $unit" >> "$MOCK_LOG"; else echo "worker $unit" >> "$MOCK_LOG"; fi
echo "worker $unit" >> "src/u$n.txt"
emit "$(printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[{"name":"u%s","result":"PASS"}],"context_updates":{"upsert":[],"remove":[]}}' "$n")"
exit 0
EOF
chmod +x "$TMP/bin/mock-cli"; cp "$TMP/bin/mock-cli" "$TMP/bin/claude"; cp "$TMP/bin/mock-cli" "$TMP/bin/codex"

fake_pass() { bash .claude/skills/feature/scripts/consensus-loop.sh "$1" > "$TMP/consensus-$1.log" 2>&1 || { cat "$TMP/consensus-$1.log"; fail "픽스처: $1 합의 PASS 체크포인트 생성 실패"; }; }
fake_pass design; fake_pass impl
run_runner() { : > "$MOCK_LOG"; : > "$MOCK_STATE/argv.log"; : > "$MOCK_STATE/env.log"; bash "$RUN" > "$TMP/run.log" 2>&1; echo $?; }
status() { jq -r '.status' .agent-work/run-state.json; }
reason() { jq -r '.reason' .agent-work/run-state.json; }
calls() { grep -c "^$1" "$MOCK_LOG" 2>/dev/null || true; }
argv_of() { grep "^$1 $2 " "$MOCK_STATE/argv.log"; }
reset_tree() {
  git checkout -q -- src
  rm -rf .agent-work/units .agent-work/implementation-context.json .agent-work/implementation-units.lock.json .agent-work/feature-scope.lock.json .agent-work/worker-baseline.tree \
    .agent-work/worker-result.json .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/reviews/impl-attempt-* .agent-work/.session-* \
    .agent-work/worker-session.json .agent-work/worker-handoff.json .agent-work/usage.jsonl .agent-work/cli-anomalies.jsonl .agent-work/worker-outcome.guard.json "$MOCK_STATE"/*
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
}

# ===== 사례 A: Claude 워커 — 최초·resume·test-fix 모두 정책 적용, 다른 역할·부모에는 없음 =====
reset_tree; touch "$TMP/fail-test-01"   # unit 01 targeted test 1회 실패 → test-fix 턴(같은 세션 resume) 유발
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -20 "$TMP/run.log"; fail "A: exit 0/DONE 기대, 실제 $rc/$(status)"; }
[ "$(calls 'worker 0')" -eq 2 ] && [ "$(calls 'test-fix')" -eq 1 ] || fail "A: 워커 2회 + test-fix 1회가 아님: $(paste -sd'|' "$MOCK_LOG")"
worker_lines="$(grep '^claude worker ' "$MOCK_STATE/argv.log")"
[ "$(printf '%s\n' "$worker_lines" | wc -l | tr -d ' ')" = 3 ] || fail "A: claude 워커 argv 기록이 3줄이 아님: $worker_lines"
printf '%s\n' "$worker_lines" | grep -q '^claude worker --session-id ' || fail "A: 최초 턴(--session-id) 기록 없음"
[ "$(printf '%s\n' "$worker_lines" | grep -c '^claude worker --resume ')" = 2 ] || fail "A: resume 턴(--resume) 이 2회가 아님"
while IFS= read -r line; do
  case "$line" in *"--disallowedTools Agent,ScheduleWakeup"*) ;; *) fail "A: 워커 호출에 --disallowedTools Agent,ScheduleWakeup 없음: $line";; esac
  case "$line" in *"SendMessage"*) fail "A: SendMessage 가 금지 목록에 있음: $line";; esac
  case "$line" in *"Monitor"*) fail "A: Monitor 가 임의로 금지됨: $line";; esac
  case "$line" in *"--allowedTools Bash"*) ;; *) fail "A: 워커의 --allowedTools Bash 가 사라짐(편집·테스트 허용 유지): $line";; esac
done <<< "$worker_lines"
[ "$(grep -c '^claude worker bg=1 agentview=1$' "$MOCK_STATE/env.log")" = 3 ] || fail "A: 워커 child 환경변수가 3회 모두 설정되지 않음: $(grep '^claude worker' "$MOCK_STATE/env.log")"
for other in reviewer editor; do
  argv_of claude "$other" | grep -q 'disallowedTools Agent' && fail "A: $other 에 워커 정책 플래그가 붙음: $(argv_of claude "$other")"
  grep "^claude $other " "$MOCK_STATE/env.log" | grep -qv 'bg=unset agentview=unset' && fail "A: $other child 에 워커 환경변수가 샘: $(grep "^claude $other" "$MOCK_STATE/env.log")"
done
[ "$(calls reviewer)" -ge 1 ] || fail "A: 리뷰어 호출이 없어 대조 불가"
[ -z "${CLAUDE_CODE_DISABLE_BACKGROUND_TASKS:-}" ] && [ -z "${CLAUDE_CODE_DISABLE_AGENT_VIEW:-}" ] || fail "A: 러너(부모) 환경에 워커 환경변수가 설정됨"
grep -q 'Agent' .agent-work/worker-session.json && fail "A: 세션 저널에 도구 정책이 섞임(저널 계약 불변)"
pass "A: Claude 워커 최초·resume·test-fix 모두 --disallowedTools Agent,ScheduleWakeup + child 환경변수(SendMessage·Monitor 미금지, Bash 허용), 리뷰어·수정자·부모는 무변경"

# ===== 사례 B: Codex 워커 — exec / exec resume 모두 -c agents.enabled=false, 검증자(read-only)에는 없음, 전역 config 불변 =====
reset_tree
sed -i.bak 's/^WORKER_CLI=.*/WORKER_CLI="codex"/' "$CFG" && rm -f "$CFG.bak"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -20 "$TMP/run.log"; fail "B: exit 0/DONE 기대, 실제 $rc/$(status)"; }
new_line="$(grep '^codex worker  ' "$MOCK_STATE/argv.log" | head -1)"; resume_line="$(grep '^codex worker resume ' "$MOCK_STATE/argv.log" | head -1)"
[ -n "$new_line" ] && [ -n "$resume_line" ] || fail "B: codex 워커 exec(최초)·exec resume(후속) 기록이 없음: $(cat "$MOCK_STATE/argv.log")"
for line in "$new_line" "$resume_line"; do
  case "$line" in *"-c agents.enabled=false"*) ;; *) fail "B: codex 워커 호출에 -c agents.enabled=false 없음: $line";; esac
  # 정책 -c 는 model_reasoning_effort / sandbox_mode 등 다른 -c 뒤에 온다(호출별 설정이 덮어쓰지 못하게)
  [ "${line##*-c model_reasoning_effort}" != "$line" ] && [ "${line##*agents.enabled=false}" = "" ] || true
  after_policy="${line#*agents.enabled=false}"; case "$after_policy" in *" -c "*) fail "B: 정책 -c 뒤에 다른 -c 가 옴(덮어쓰기 가능): $line";; esac
done
grep '^codex validator ' "$MOCK_STATE/argv.log" | grep -q 'agents.enabled' && fail "B: 검증자(read-only) 에 워커 정책이 붙음"
cmp -s "$TMP/codex-home/config.toml" "$TMP/codex-config.orig" || fail "B: 전역 codex config.toml 이 변경됨"
# 모델 호출 횟수는 정책 전과 같다(unit 2개 → 워커 2회, 재호출 없음)
[ "$(calls 'worker 0')" -eq 2 ] || fail "B: codex 워커 호출 횟수가 2회가 아님: $(paste -sd'|' "$MOCK_LOG")"
pass "B: Codex 워커 exec·exec resume 모두 -c agents.enabled=false(다른 -c 뒤), 검증자 무변경, 전역 config 불변, 호출 횟수 불변"

# ===== 사례 C: CLI 가 옵션을 거부하면 실패로 끝나고 제한 없는 재실행이 없다 =====
reset_tree
sed -i.bak 's/^WORKER_CLI=.*/WORKER_CLI="claude"/' "$CFG" && rm -f "$CFG.bak"
touch "$MOCK_STATE/reject-disallowed"
rc="$(run_runner)"
[ "$rc" -eq 1 ] && [ "$(status)" = ENV_ERROR ] || { tail -20 "$TMP/run.log"; fail "C: 옵션 거부가 실패(ENV_ERROR)로 끝나지 않음 ($rc/$(status))"; }
[ "$(calls worker-rejected)" -eq 1 ] && [ "$(calls 'worker 0')" -eq 0 ] || fail "C: 거부 뒤 제한 없이 재호출됨: $(paste -sd'|' "$MOCK_LOG")"
[ "$(grep -c '^claude worker' "$MOCK_STATE/argv.log")" = 1 ] || fail "C: 워커 CLI 호출이 1회가 아님"
grep '^claude worker' "$MOCK_STATE/argv.log" | grep -q 'disallowedTools Agent,ScheduleWakeup' || fail "C: 거부된 호출에도 정책이 붙어 있어야 함"
pass "C: CLI 가 --disallowedTools 를 거부 → 호출 실패, 제한 해제·무제한 재실행 0회"

rm -rf "$TMP"
echo "smoke-worker-tool-policy: 전부 통과"
