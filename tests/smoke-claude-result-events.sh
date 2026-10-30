#!/usr/bin/env bash
# =============================================================
# 스모크: Claude stream-json result 이벤트 판정 (P0-2) — 실제 LLM 호출 없음(가짜 claude 가 stream-json 을 흉내), 임시 저장소.
# 파일 경로: tests/smoke-claude-result-events.sh
# 사용법: bash tests/smoke-claude-result-events.sh
#
# 불변식: type=result 이벤트가 정확히 하나이고 워커 JSON 스키마가 유효할 때만 정상 수용한다. 0개·복수·파싱 실패는 명시적 오류이며
#   중간의 유효한 이벤트를 자동 선택하지 않는다. 원본 .stream.jsonl·CLI 종료 코드(usage.jsonl 의 exit_code 는 CLI 가 돌려준 값 그대로)·
#   호출 전후 tree 는 보존되고, 변경 코드가 남아 결과가 불확실하면 WORKER_OUTCOME_UNCERTAIN 가드를 따른다. 같은 워커 작업을 자동 재호출하지 않는다.
# 사례:
#   A. result 1개(중간에 assistant 이벤트 다수) + CLI exit 0 → DONE, 워커 1회, 그 result 가 $raw 로 추출
#   B. result 2개(하위 Agent 가 result 를 남긴 상황; 두 번째가 비정형, 첫 번째는 유효) + exit 0 → CLAUDE_RESULT_MULTIPLE, 첫 번째를 고르지 않음,
#      변경 보존 + WORKER_OUTCOME_UNCERTAIN, 재실행 시 워커 0회, 호출 전 tree 로 복구한 뒤에만 재호출
#   C. result 0개 + 변경 → 같은 WORKER_OUTCOME_UNCERTAIN(CLAUDE_RESULT_MISSING) / result 0개 + 변경 없음 → ENV_ERROR(실행 실패), 재실행 시 워커 재호출 허용
#   D. JSON 깨진 줄 + result 없음 + 변경 → CLAUDE_RESULT_INVALID + WORKER_OUTCOME_UNCERTAIN
#   E. result 1개 + exit 1 → 기존 CLI_EXIT_STATUS_MISMATCH 복구(유일하고 유효한 결과에만) / result 2개 + exit 1 → 복구 없음(UNCERTAIN)
#   F. result 1개인데 워커 스키마 불일치(status 없음) → 수용하지 않음(실행 실패·tree 보존)
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-claude-result-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"echo full-test >> $TMP/calls.log\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"echo full-lint >> $TMP/calls.log\"|" "$CFG" && rm -f "$CFG.bak"
sed -i.bak 's/^VALIDATOR_CLI=.*/VALIDATOR_CLI="codex"/; s/^WORKER_CLI=.*/WORKER_CLI="claude"/; s/^DESIGNER_CLI=.*/DESIGNER_CLI="claude"/; s/^FIXER_CLI=.*/FIXER_CLI="claude"/; s/^REVIEWER_CLI=.*/REVIEWER_CLI="claude"/' "$CFG" && rm -f "$CFG.bak"
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && echo "base 01" > src/u01.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/u01.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
printf '{"version":1,"units":[{"id":"01-intake","title":"접수","goal":"unit 01","requirements":["REQ-01"],"scope":{"files":["src/u01.txt"],"new_file_roots":[]},"references":["implementation.md#01"],"targeted_test":"echo test-01 >> %s/calls.log"}]}\n' "$TMP" > .agent-work/implementation-units.json
RUN=".claude/skills/feature/scripts/feature-run.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" FEATURE_LIVE_TEE=1 MOCK_VALIDATOR_CONTRACT="$CONTRACT" MOCK_REVIEW_CONTRACT="$REVIEW_CONTRACT"
mkdir -p "$MOCK_STATE"

# --- fake codex(검증자 PASS) ---
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
out=""; while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
printf '{"type":"thread.started","thread_id":"t-%s"}\n{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1}}\n' "$$"
echo "validator" >> "$MOCK_LOG"
printf '{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}\n' "$MOCK_VALIDATOR_CONTRACT" > "$out"
EOF
# --- fake claude: 리뷰어(--tools) 는 APPROVE(json). 워커(stream-json) 는 FAKE_STREAM_MODE 대로 stream-json 을 흉내:
#   one | two | zero | broken | one-badschema ; FAKE_WORKER_EDIT=0 이면 파일을 고치지 않음 ; FAKE_WORKER_RC = 종료 코드
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
is_reviewer=0; outfmt=json
while [ "$#" -gt 0 ]; do case "$1" in --tools) is_reviewer=1; shift 2;; --output-format) outfmt="$2"; shift 2;; -p|--verbose) shift;; --session-id|--resume|--model|--effort|--permission-mode|--json-schema|--allowedTools|--disallowedTools|--append-system-prompt) shift 2;; *) shift;; esac; done
usage='"session_id":"fake","total_cost_usd":0.1,"num_turns":2,"usage":{"input_tokens":5,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
if [ "$is_reviewer" = 1 ]; then echo "reviewer" >> "$MOCK_LOG"; printf '{"structured_output":{"schema_version":%s,"verdict":"APPROVE","issues":[]},%s}\n' "$MOCK_REVIEW_CONTRACT" "$usage"; exit 0; fi
[ "$outfmt" = stream-json ] || { echo "worker called without stream-json" >&2; exit 9; }
echo "worker" >> "$MOCK_LOG"
[ "${FAKE_WORKER_EDIT:-1}" = 0 ] || echo "worker edit" >> src/u01.txt
good='{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[{"name":"u01","result":"PASS"}],"context_updates":{"upsert":[],"remove":[]}}'
printf '{"type":"system","subtype":"init"}\n{"type":"assistant","message":{"usage":{"input_tokens":7,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}\n'
case "${FAKE_STREAM_MODE:-one}" in
  one)    printf '{"type":"result","subtype":"success","structured_output":%s,%s}\n' "$good" "$usage";;
  two)    printf '{"type":"result","subtype":"success","structured_output":%s,%s}\n' "$good" "$usage"
          printf '{"type":"assistant","message":{"usage":{"input_tokens":3,"output_tokens":1}}}\n'
          printf '{"type":"result","subtype":"error_during_execution","is_error":true,%s}\n' "$usage";;
  zero)   printf '{"type":"assistant","message":{"usage":{"input_tokens":3,"output_tokens":1}}}\n';;
  broken) printf '{"type":"assistant","message":{"usa\n';;
  one-badschema) printf '{"type":"result","subtype":"success","structured_output":{"note":"no status"},%s}\n' "$usage";;
  one-malformed) printf '{"type":"assistant","message":{"usa\n'; printf '{"type":"result","subtype":"success","structured_output":%s,%s}\n' "$good" "$usage";;
esac
exit "${FAKE_WORKER_RC:-0}"
EOF
chmod +x "$TMP/bin/codex" "$TMP/bin/claude"

fake_pass() { bash .claude/skills/feature/scripts/consensus-loop.sh "$1" > "$TMP/consensus-$1.log" 2>&1 || { cat "$TMP/consensus-$1.log"; fail "픽스처: $1 합의 PASS 체크포인트 생성 실패"; }; }
fake_pass design; fake_pass impl
run_runner() { : > "$MOCK_LOG"; bash "$RUN" > "$TMP/run.log" 2>&1; echo $?; }
status() { jq -r '.status' .agent-work/run-state.json; }
reason() { jq -r '.reason' .agent-work/run-state.json; }
calls() { grep -c "^$1\$" "$MOCK_LOG" 2>/dev/null || true; }
unit_dir=.agent-work/units/01-intake
stream_file() { ls "$unit_dir"/worker-*.log.stream.jsonl 2>/dev/null | tail -1; }
raw_file() { f="$(stream_file)"; printf '%s' "${f%.stream.jsonl}"; }
reset_tree() {
  git checkout -q -- src
  rm -rf .agent-work/units .agent-work/implementation-context.json .agent-work/implementation-units.lock.json .agent-work/feature-scope.lock.json .agent-work/worker-baseline.tree \
    .agent-work/worker-result.json .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/reviews/impl-attempt-* .agent-work/.session-* \
    .agent-work/worker-session.json .agent-work/worker-handoff.json .agent-work/usage.jsonl .agent-work/cli-anomalies.jsonl .agent-work/worker-outcome.guard.json "$MOCK_STATE"/*
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
}
expect_uncertain() { # label mode rc
  local label="$1"
  rc="$(FAKE_STREAM_MODE=$2 FAKE_WORKER_RC=$3 run_runner)"
  [ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] || { tail -20 "$TMP/run.log"; fail "$label: exit 2/WORKER_OUTCOME_UNCERTAIN 기대, 실제 $rc/$(reason)"; }
  [ "$(calls worker)" -eq 1 ] || fail "$label: 워커 호출이 1회가 아님 ($(calls worker))"
  grep -q 'test-01' "$MOCK_LOG" && fail "$label: 불확실 결과인데 targeted test 로 진행"
  [ "$(tail -1 src/u01.txt)" = "worker edit" ] || fail "$label: 워커 변경이 자동 원복됨(보존돼야 함)"
  [ -f "$(stream_file)" ] || fail "$label: 원본 stream.jsonl 이 보존되지 않음"
  [ ! -f "$(raw_file)" ] && [ ! -s "$unit_dir/worker-result.json" ] || fail "$label: 모호한 결과에서 \$raw/result 가 만들어짐(자동 선택 금지)"
  [ -f "$unit_dir/worker-before.tree" ] && [ -f "$unit_dir/worker-after.tree" ] || fail "$label: 호출 전후 tree 증거가 없음"
  jq -e --argjson rc "$3" '.active==true and .role=="WORKER" and .raw_exit_code==$rc and (.invocation_id|type=="string" and length>0) and (.raw_log|type=="string") and (.reason|type=="string" and length>0)' .agent-work/worker-outcome.guard.json >/dev/null \
    || fail "$label: outcome 가드 불일치(raw rc·invocation_id·raw_log·reason 보존): $(cat .agent-work/worker-outcome.guard.json)"
  [ "$(anomalies)" -eq 0 ] || fail "$label: 모호한 결과에 CLI_EXIT_STATUS_MISMATCH 복구가 적용됨"
  # [리뷰 2] 결과 검증에 떨어진 첫 턴의 claude 세션은 확정되지 않는다(.new 만) — 다음 실행이 그 대화를 잇지 않는다
  [ ! -f .agent-work/.session-feature-worker ] || fail "$label: 무효 결과인데 claude 세션이 확정됨(.session-feature-worker 존재)"
  # [GOAL-6] 실패한 invocation 도 usage 행 1개(unknown) — 숨은 0건 없음. 중단 경로에서도 비용 보고 줄이 나온다
  [ "$(jq -r 'select(.role=="WORKER") | [.cost_kind,.cost_usd,.estimated_cost_usd,.tokens_total,.success,(.usage_observation_status|type),(.usage_error|type),(.raw_log|endswith(".stream.jsonl"))]|@csv' .agent-work/usage.jsonl 2>/dev/null)" = '"unknown",,,,false,"string","string",true' ] \
    || fail "$label: 실패 invocation 의 usage unknown 행이 없거나 필드 불일치: $(jq -c 'select(.role=="WORKER")' .agent-work/usage.jsonl 2>/dev/null)"
  [ "$(jq -r 'select(.role=="WORKER") | .invocation_id' .agent-work/usage.jsonl)" = "$(jq -r '.invocation_id' .agent-work/worker-outcome.guard.json)" ] || fail "$label: usage 행과 가드의 invocation_id 가 다름"
  grep -q '비용(usage_summary.*추정 불가 1건(사용량 미관측 1건' "$TMP/run.log" || fail "$label: 중단(NEED_USER) 경로에 비용 보고 줄이 없거나 unknown 1건이 아님: $(grep '비용(' "$TMP/run.log")"
  # 재실행: 워커 0회(자동 재호출 없음) — 사용자가 호출 전 tree 로 복구한 뒤에만 재호출
  rc="$(FAKE_STREAM_MODE=one run_runner)"
  [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] && [ ! -s "$MOCK_LOG" ] || fail "$label(재실행): 복구 전인데 모델이 호출됨: $(paste -sd'|' "$MOCK_LOG")"
}
anomalies() { if [ -f .agent-work/cli-anomalies.jsonl ]; then grep -c . .agent-work/cli-anomalies.jsonl || true; else echo 0; fi; }

# ===== 사례 A: result 1개 → DONE =====
reset_tree
rc="$(FAKE_STREAM_MODE=one run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -20 "$TMP/run.log"; fail "A: exit 0/DONE 기대, 실제 $rc/$(status)"; }
[ "$(calls worker)" -eq 1 ] || fail "A: 워커 1회가 아님"
jq -e '.type=="result" and .subtype=="success"' "$(raw_file)" >/dev/null || fail "A: 유일한 result 가 \$raw 로 추출되지 않음"
jq -e '.status=="DONE"' "$unit_dir/worker-result.json" >/dev/null || fail "A: 결과 JSON 불일치"
[ "$(jq -r 'select(.role=="WORKER") | [.exit_code,.success,.cost_usd]|@csv' .agent-work/usage.jsonl)" = '0,true,0.1' ] || fail "A: usage 행 불일치"
pass "A: result 1개 → 추출·DONE, 워커 1회"

# ===== 사례 B: result 2개 + exit 0 → MULTIPLE, 첫 번째(유효)를 고르지 않음, UNCERTAIN, 재실행 0회, 복구 후 재호출 =====
reset_tree
expect_uncertain B two 0
grep -q 'CLAUDE_RESULT_MULTIPLE' "$TMP/run.log" || { tail -20 "$TMP/run.log"; fail "B: CLAUDE_RESULT_MULTIPLE 진단이 없음"; }
[ "$(jq -c 'select(.type=="result")' "$(stream_file)" | wc -l | tr -d ' ')" = 2 ] || fail "B: 원본 stream 에 result 2개가 그대로 남아 있어야 함"
[ "$(jq -r 'select(.role=="WORKER") | [.usage_error,.usage_observation_status,.context_last_turn]|@csv' .agent-work/usage.jsonl 2>/dev/null)" = '"CLAUDE_RESULT_MULTIPLE","partial",3' ] \
  || fail "B: 모호한 결과의 usage 가 어느 result 의 비용으로 기록되거나 unknown 행이 없음(관측 가능한 마지막 assistant 입력만 partial 로): $(jq -c 'select(.role=="WORKER")' .agent-work/usage.jsonl)"
[ "$(bash -c "source $CFG; usage_summary" | jq -r '[.cost_unknown_invocations,.usage_unobserved_invocations,.by_role.WORKER.cost_unknown_invocations]|@csv')" = '1,1,1' ] || fail "B: 요약의 unknown 건수가 실패 invocation 을 세지 않음"
# 사용자 복구(호출 전 tree 로) → 재실행 시 워커 재호출 → DONE
git checkout -q -- src/u01.txt
rc="$(FAKE_STREAM_MODE=one run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] && [ "$(calls worker)" -eq 1 ] || { tail -20 "$TMP/run.log"; fail "B(복구 후): 재호출·DONE 실패 ($rc/$(status), worker $(calls worker))"; }
pass "B: result 2개 → CLAUDE_RESULT_MULTIPLE, 자동 선택 없음, 변경 보존 + WORKER_OUTCOME_UNCERTAIN, 재실행 0회, 복구 후에만 재호출"

# ===== 사례 C: result 0개 =====
reset_tree
expect_uncertain "C(변경)" zero 0
grep -q 'CLAUDE_RESULT_MISSING' "$TMP/run.log" || fail "C: CLAUDE_RESULT_MISSING 진단이 없음"
reset_tree
rc="$(FAKE_STREAM_MODE=zero FAKE_WORKER_EDIT=0 run_runner)"
[ "$rc" -eq 1 ] && [ "$(status)" = ENV_ERROR ] || { tail -20 "$TMP/run.log"; fail "C(무변경): 결과 없음 + 변경 없음은 실행 실패(ENV_ERROR)여야 함 ($rc/$(status))"; }
[ "$(calls worker)" -eq 1 ] && [ ! -f .agent-work/worker-outcome.guard.json ] || fail "C(무변경): 가드가 생기거나 워커가 재호출됨"
rc="$(FAKE_STREAM_MODE=one run_runner)"; [ "$rc" -eq 0 ] && [ "$(calls worker)" -eq 1 ] || fail "C(무변경 재실행): 변경 없는 실패 뒤 재호출이 허용돼야 함"
pass "C: result 0개 + 변경 → CLAUDE_RESULT_MISSING + UNCERTAIN / 변경 없음 → 실행 실패, 재실행 시 재호출 허용"

# ===== 사례 D: JSON 깨진 줄 =====
reset_tree
expect_uncertain D broken 0
grep -q 'CLAUDE_RESULT_INVALID' "$TMP/run.log" || fail "D: CLAUDE_RESULT_INVALID 진단이 없음"
pass "D: 파싱 실패 → CLAUDE_RESULT_INVALID + UNCERTAIN, 원본 보존"

# ===== 사례 E: CLI_EXIT_STATUS_MISMATCH 복구는 유일하고 유효한 결과에만 =====
reset_tree
rc="$(FAKE_STREAM_MODE=one FAKE_WORKER_RC=1 run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] && [ "$(calls worker)" -eq 1 ] || { tail -20 "$TMP/run.log"; fail "E(1개+exit1): 기존 복구가 깨짐 ($rc/$(status))"; }
grep -q 'CLI_EXIT_STATUS_MISMATCH: WORKER claude exited 1' "$TMP/run.log" || fail "E: mismatch WARN 없음"
[ "$(jq -r 'select(.role=="WORKER") | [.exit_code,.success]|@csv' .agent-work/usage.jsonl)" = '1,false' ] || fail "E: raw exit code 가 usage 에 보존되지 않음"
reset_tree
expect_uncertain "E(2개+exit1)" two 1
pass "E: 유일한 유효 result + exit 1 → 복구 / result 2개 + exit 1 → 복구 없이 UNCERTAIN"

# ===== 사례 F: result 1개 + 워커 스키마 불일치 (GOAL-6 P0-B) =====
#   변경 있음 → CLI rc 0 이어도 WORKER_OUTCOME_UNCERTAIN 가드(before/after·invocation_id·raw·rc·이유), 재실행 모델 0회, 복구 후에만 재호출
#   변경 없음 → 기존 실행 실패(ENV_ERROR), 재실행 시 재호출 허용. 이 경우 유일한 result 의 reported 비용은 그대로 기록된다
reset_tree
rc="$(FAKE_STREAM_MODE=one-badschema run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] || { tail -20 "$TMP/run.log"; fail "F(변경): 스키마 불일치 + 변경이 UNCERTAIN 가드가 아님 ($rc/$(reason))"; }
[ "$(calls worker)" -eq 1 ] && [ "$(tail -1 src/u01.txt)" = "worker edit" ] || fail "F: 재호출되거나 변경이 원복됨"
grep -q 'test-01' "$MOCK_LOG" && fail "F: 스키마 불일치인데 targeted test 로 진행"
jq -e '.active==true and .raw_exit_code==0 and .reason=="WORKER_RESULT_SCHEMA_INVALID" and (.invocation_id|length>0) and (.raw_log|type=="string")' .agent-work/worker-outcome.guard.json >/dev/null \
  || fail "F: 가드에 rc 0·이유·invocation_id·raw 경로가 없음: $(cat .agent-work/worker-outcome.guard.json)"
[ ! -f .agent-work/.session-feature-worker ] && [ -f .agent-work/.session-feature-worker.new ] || fail "F: CLI rc 0 + 스키마 불일치인데 claude 세션이 결과 검증 전에 확정됨"
[ "$(jq -r 'select(.role=="WORKER") | [.cost_kind,.cost_usd,.exit_code]|@csv' .agent-work/usage.jsonl)" = '"reported",0.1,0' ] || fail "F: 유일한 result 의 reported 비용이 기록되지 않음"
rc="$(FAKE_STREAM_MODE=one run_runner)"
[ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] && [ ! -s "$MOCK_LOG" ] || fail "F(재실행): 복구 전인데 모델이 호출됨: $(paste -sd'|' "$MOCK_LOG")"
git checkout -q -- src/u01.txt
rc="$(FAKE_STREAM_MODE=one run_runner)"; [ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "F(복구 후): 재호출·DONE 실패 ($rc/$(status))"
[ -f .agent-work/.session-feature-worker ] || fail "F(복구 후): 유효 결과 뒤에도 세션이 확정되지 않음"
reset_tree
rc="$(FAKE_STREAM_MODE=one-badschema FAKE_WORKER_EDIT=0 run_runner)"
[ "$rc" -eq 1 ] && [ "$(status)" = ENV_ERROR ] && [ ! -f .agent-work/worker-outcome.guard.json ] || { tail -20 "$TMP/run.log"; fail "F(무변경): 기존 실행 실패 정책이 아님 ($rc/$(status))"; }
grep -q 'WORKER_RESULT_SCHEMA_INVALID' "$TMP/run.log" || fail "F(무변경): 실패 이유가 로그에 없음"
grep -q '비용(usage_summary' "$TMP/run.log" || fail "F(무변경): ENV_ERROR 경로에 비용 보고 줄이 없음"
rc="$(FAKE_STREAM_MODE=one run_runner)"; [ "$rc" -eq 0 ] && [ "$(calls worker)" -eq 1 ] || fail "F(무변경 재실행): 재호출이 허용돼야 함"
pass "F: result 1개 + 스키마 불일치 — 변경 있음 → rc 0 이어도 UNCERTAIN 가드(이유·invocation·raw), 재실행 0회, 복구 후 재호출 / 변경 없음 → 실행 실패·재호출 허용"

# ===== 사례 G: result 1개 + JSON 깨진 줄 혼재 → CLAUDE_RESULT_INVALID (조용히 성공시키지 않음), 원본 보존 =====
reset_tree
expect_uncertain G one-malformed 0
[ "$(jq -r '.reason' .agent-work/worker-outcome.guard.json)" = CLAUDE_RESULT_INVALID ] && [ "$(jq -r 'select(.role=="WORKER") | .usage_error' .agent-work/usage.jsonl)" = CLAUDE_RESULT_INVALID ] \
  || fail "G: result 1개 + 손상 줄이 INVALID 로 진단되지 않음(가드: $(jq -r '.reason' .agent-work/worker-outcome.guard.json))"
[ "$(jq -R -c 'fromjson? | select(.type=="result")' "$(stream_file)" 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && grep -q '"usa$' "$(stream_file)" || fail "G: 원본 stream(result + 손상 줄)이 보존되지 않음"
pass "G: result 1개 + malformed 줄 → CLAUDE_RESULT_INVALID + UNCERTAIN, 원본 보존"

# ===== 사례 H: 시작 전 실패(usage.jsonl 없음)는 빈 상태로 보고 — invocation 을 만들지 않는다 =====
reset_tree
mv .agent-work/implementation-units.json "$TMP/units.bak"
rc="$(run_runner)"; mv "$TMP/units.bak" .agent-work/implementation-units.json
[ "$rc" -ne 0 ] && grep -q 'child invocation 없음 — usage.jsonl 없음' "$TMP/run.log" && [ ! -f .agent-work/usage.jsonl ] || fail "H: 시작 전 실패가 빈 비용 상태로 보고되지 않음 ($rc): $(grep '비용(' "$TMP/run.log")"
pass "H: 시작 전 실패 → usage 행 없음, 비용 보고는 빈 상태(0달러 아님)"

# ===== 사례 I (리뷰 3): 명시적 종료 함수를 거치지 않은 예기치 않은 종료에도 비용 보고 1회(EXIT trap), 상태 ENV_ERROR =====
reset_tree
cp "$RUN" "$TMP/feature-run.orig"
sed -i.bak 's|^      notify_feature_done \|\| true |      [ ! -f "$MOCK_STATE/crash" ] \|\| exit 7; notify_feature_done \|\| true |' "$RUN" && rm -f "$RUN.bak"
grep -q 'MOCK_STATE/crash' "$RUN" || fail "I: 크래시 주입 실패"
touch "$MOCK_STATE/crash"
rc="$(FAKE_STREAM_MODE=one run_runner)"
[ "$rc" -eq 7 ] && [ "$(status)" = ENV_ERROR ] && grep -q '예기치 않은 종료 (exit 7)' .agent-work/run-state.json || { tail -5 "$TMP/run.log"; fail "I: 예기치 않은 종료가 ENV_ERROR 로 기록되지 않음 ($rc/$(status))"; }
[ "$(grep -c '비용(usage_summary' "$TMP/run.log")" = 1 ] || fail "I: 예기치 않은 종료 경로의 비용 보고가 0회 또는 중복: $(grep -c '비용(usage_summary' "$TMP/run.log")회"
[ -f .agent-work/usage-summary.json ] || fail "I: usage-summary.json 이 없음"
cp "$TMP/feature-run.orig" "$RUN"; rm -f "$MOCK_STATE/crash"
# 명시적 경로(env_error)는 종전처럼 1회만 — 중복 없음
reset_tree
rc="$(FAKE_STREAM_MODE=zero FAKE_WORKER_EDIT=0 run_runner)"
[ "$rc" -eq 1 ] && [ "$(grep -c '비용(usage_summary' "$TMP/run.log")" = 1 ] || fail "I: env_error 경로에서 비용 보고가 중복됨: $(grep -c '비용(usage_summary' "$TMP/run.log")회"
pass "I: 예기치 않은 종료(exit 7) → EXIT trap 이 ENV_ERROR 기록 + 비용 보고 1회, 명시적 경로는 중복 없음"

rm -rf "$TMP"
echo "smoke-claude-result-events: 전부 통과"
