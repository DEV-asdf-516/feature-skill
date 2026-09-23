#!/usr/bin/env bash
# =============================================================
# 스모크: Codex usage/cost telemetry — `codex exec --json` 이벤트 JSONL 기반 (실제 LLM 호출 없음, fake codex, 임시 저장소)
# 파일 경로: tests/smoke-codex-usage.sh
# 사용법: bash tests/smoke-codex-usage.sh
#
# 사례:
#   A. 워커(gpt-5.6-luna) turn.completed 1개 {input 10000, cached 6000, cache_write 1000, output 500, reasoning 300}
#      → input_uncached 3000 / cache_read 6000 / cache_write 1000 / input_effective 10000 / output 500 / reasoning_output 300 / tokens_total 10500 / num_turns 1,
#        estimated_cost_usd = (4000*0.20 + 6000*0.02 + 500*1.20)/1M = 0.00152 (reasoning 이중 가산 없음), cost_usd null, cost_kind estimated
#   B. turn.completed 여러 개 → 합산(num_turns 2)
#   C. 가격표에 없는 모델 → estimated null / unknown
#   D. rc≠0 + 이번 invocation 의 유효한 -o 결과 → 기존 CLI_EXIT_STATUS_MISMATCH 복구 유지(워커·읽기 전용 검증자), raw exit_code 보존
#   E. usage 이벤트 없음/깨짐 → WARN + usage 행 생략, 피처 실행은 그대로 성공, 같은 invocation 재실행 없음
#   F. invocation 별 usage 행 정확히 1개, stdout(events.jsonl)/stderr(stderr.log) 분리, -o 는 invocation 전용 임시 경로(provenance 유지)
#   G. usage_summary: reported/estimated/combined/cost_unknown 분리
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-codex-usage-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks" "$TMP/side"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"true\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"true\"|" "$CFG" && rm -f "$CFG.bak"
# 워커·검증자는 codex(가격표 모델), 리뷰어·디자이너·수정자는 claude
sed -i.bak 's/^VALIDATOR_MODEL=.*/VALIDATOR_MODEL="gpt-5.6-sol"/; s/^WORKER_MODEL=.*/WORKER_MODEL="gpt-5.6-luna"/; s/^REVIEWER_CLI=.*/REVIEWER_CLI="claude"/; s/^DESIGNER_CLI=.*/DESIGNER_CLI="claude"/; s/^FIXER_CLI=.*/FIXER_CLI="claude"/' "$CFG" && rm -f "$CFG.bak"
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && echo "base 01" > src/u01.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/u01.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
printf '{"version":1,"units":[{"id":"01-intake","title":"접수","goal":"unit 01","requirements":["REQ-01"],"scope":{"files":["src/u01.txt"],"new_file_roots":[]},"references":["implementation.md#01"],"targeted_test":"true"}]}\n' > .agent-work/implementation-units.json
RUN=".claude/skills/feature/scripts/feature-run.sh"; LOOP=".claude/skills/feature/scripts/consensus-loop.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" FEATURE_LIVE_TEE=1 FAKE_CONTRACT="$CONTRACT" MOCK_REVIEW_CONTRACT="$REVIEW_CONTRACT"
mkdir -p "$MOCK_STATE"

# --- fake codex: FAKE_USAGE_MODE = one | two | none | broken ; FAKE_CODEX_RC = exit code. stdout = --json 이벤트, stderr = 진단 ---
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
out=""; readonly_sb=0; has_json=0
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; --json) has_json=1; shift;; --sandbox) [ "$2" = read-only ] && readonly_sb=1; shift 2;; *) shift;; esac; done
[ "$has_json" = 1 ] || { echo "codex called without --json" >&2; exit 9; }
printf '%s\n' "$out" >> "$MOCK_STATE/o-args"
echo "diag to stderr" >&2
printf '{"type":"thread.started","thread_id":"t1"}\n'
case "${FAKE_USAGE_MODE:-one}" in
  one) printf '{"type":"turn.completed","usage":{"input_tokens":10000,"cached_input_tokens":6000,"cache_write_input_tokens":1000,"output_tokens":500,"reasoning_output_tokens":300}}\n';;
  two) printf '{"type":"turn.completed","usage":{"input_tokens":10000,"cached_input_tokens":6000,"cache_write_input_tokens":1000,"output_tokens":500,"reasoning_output_tokens":300}}\n'
       printf '{"type":"item.completed","item":{"type":"agent_message","text":"x"}}\n'
       printf '{"type":"turn.completed","usage":{"input_tokens":2000,"cached_input_tokens":500,"cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":50}}\n';;
  none) printf 'tokens used\n123\n';;
  broken) printf '{"type":"turn.completed","usage":{"input_tokens":\n';;
esac
if [ "$readonly_sb" = 1 ]; then
  echo "validator" >> "$MOCK_LOG"
  printf '{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}\n' "$FAKE_CONTRACT" > "$out"
else
  echo "worker" >> "$MOCK_LOG"
  echo "worker edit" >> src/u01.txt
  printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[{"name":"u01","result":"PASS"}],"context_updates":{"upsert":[],"remove":[]}}\n' > "$out"
fi
exit "${FAKE_CODEX_RC:-0}"
EOF
# --- fake claude: 리뷰어 APPROVE (usage 보고) ---
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "reviewer" >> "$MOCK_LOG"
printf '{"structured_output":{"schema_version":%s,"verdict":"APPROVE","issues":[]},"session_id":"fake","total_cost_usd":0.25,"num_turns":3,"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}\n' "$MOCK_REVIEW_CONTRACT"
EOF
chmod +x "$TMP/bin/codex" "$TMP/bin/claude"

fake_pass() { bash "$LOOP" "$1" > "$TMP/consensus-$1.log" 2>&1 || { cat "$TMP/consensus-$1.log"; fail "픽스처: $1 합의 PASS 실패"; }; }
run_runner() { : > "$MOCK_LOG"; bash "$RUN" > "$TMP/run.log" 2>&1; echo $?; }
status() { jq -r '.status' .agent-work/run-state.json; }
calls() { grep -c "^$1\$" "$MOCK_LOG" 2>/dev/null || true; }
row() { jq -c "select(.role==\"$1\")" .agent-work/usage.jsonl; }
rowf() { row "$1" | jq -r "$2"; }
reset_tree() {
  git checkout -q -- src
  rm -rf .agent-work/units .agent-work/implementation-context.json .agent-work/implementation-units.lock.json .agent-work/feature-scope.lock.json .agent-work/worker-baseline.tree \
    .agent-work/worker-result.json .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/reviews/impl-attempt-* .agent-work/.session-* .agent-work/usage.jsonl \
    .agent-work/cli-anomalies.jsonl .agent-work/worker-outcome.guard.json "$MOCK_STATE"/*
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
}
fake_pass design; fake_pass impl

# ===== 사례 A/F: 워커 1 invocation = usage 행 1개, 필드 매핑·비용, stdout/stderr 분리 =====
reset_tree
rc="$(FAKE_USAGE_MODE=one run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -20 "$TMP/run.log"; fail "A: exit 0/DONE 기대, 실제 $rc/$(status)"; }
[ "$(calls worker)" -eq 1 ] || fail "A: 워커 호출 1회가 아님"
[ "$(row WORKER | wc -l | tr -d ' ')" = 1 ] || fail "F: 워커 invocation 1회에 usage 행이 1개가 아님: $(row WORKER)"
[ "$(rowf WORKER '[.cli,.model,.schema_version,.source,.num_turns]|@csv')" = '"codex","gpt-5.6-luna",3,"codex-events",1' ] || fail "A: 워커 행 메타 불일치: $(row WORKER)"
[ "$(rowf WORKER '[.input_uncached,.cache_read,.cache_write,.input_effective,.output,.reasoning_output,.tokens_total]|@csv')" = '3000,6000,1000,10000,500,300,10500' ] || fail "A: 토큰 매핑 불일치: $(row WORKER)"
[ "$(rowf WORKER '[.cost_usd,.cost_kind,((.estimated_cost_usd*100000000)|round),.pricing_basis,.exit_code,.success]|@csv')" = ',"estimated",152000,"openai-standard-token-rate-2026-09-23",0,true' ] || fail "A: 비용 필드 불일치(luna: 4000*0.20+6000*0.02+500*1.20 = 1520/1M): $(row WORKER)"
[ "$(rowf WORKER '.tokens_total == (.input_effective + .output)')" = true ] || fail "A: tokens_total 에 reasoning 이 이중 가산됨"
raw="$(ls .agent-work/units/01-intake/worker-*.log.events.jsonl | head -1)"
[ -f "$raw" ] && [ -f "${raw%.events.jsonl}.stderr.log" ] || fail "F: stdout 이벤트/stderr 로그가 분리되지 않음: $(ls .agent-work/units/01-intake)"
jq -e 'select(.type=="turn.completed")' "$raw" >/dev/null && grep -q 'diag to stderr' "${raw%.events.jsonl}.stderr.log" && ! grep -q 'diag to stderr' "$raw" || fail "F: JSONL 에 stderr 가 섞였거나 stderr 로그가 비어 있음"
[ -f .agent-work/reviews/validator-impl-round-01.json.events.jsonl ] && [ -f .agent-work/reviews/validator-impl-round-01.json.stderr.log ] || fail "F: 읽기 전용(검증자) 호출도 events/stderr 분리돼야 함"
grep -q '^\.agent-work/units/01-intake/worker-result.json$' "$MOCK_STATE/o-args" || fail "F: 워커 -o 가 unit 결과 경로가 아님: $(cat "$MOCK_STATE/o-args")"
ls .agent-work/reviews | grep -q 'invocation-.*\.tmp' && fail "F: invocation 임시 -o 파일이 남음"
# claude 행(리뷰어)은 reported 비용 그대로, codex 전용 필드 null
[ "$(rowf REVIEWER '[.cost_usd,.cost_kind,.estimated_cost_usd,.reasoning_output,.schema_version]|@csv')" = '0.25,"reported",,,3' ] || fail "A: claude 행 비용 provenance 불일치: $(row REVIEWER)"
pass "A/F: 워커 invocation 당 usage 행 1개, input/cache/output/reasoning 매핑, luna 추정 비용 0.00152, reasoning 이중 가산 없음, events/stderr 분리, -o provenance 유지"

# ===== 사례 G: usage_summary 비용 분리 (reviewer reported 0.25 + worker estimated 0.00152, 검증자(sol) 는 픽스처 단계 행) =====
summary="$(bash -c "source $CFG; usage_summary")"
[ "$(printf '%s' "$summary" | jq -r '[((.reported_cost_usd*100)|round), .cost_unknown_invocations, (.by_role.WORKER.cost_unknown_invocations), ((.by_role.WORKER.estimated_cost_usd*100000000)|round), (.by_role.REVIEWER.estimated_cost_usd)]|@csv')" = '25,0,0,152000,0' ] \
  || fail "G: usage_summary 비용 분리 불일치: $summary"
[ "$(printf '%s' "$summary" | jq -r '(.combined_cost_usd_estimate - .reported_cost_usd - .estimated_cost_usd) | fabs < 0.0000001')" = true ] || fail "G: combined ≠ reported + estimated: $summary"
pass "G: usage_summary reported/estimated/combined/cost_unknown 분리"

# ===== 사례 B: turn.completed 여러 개 → 합산 =====
reset_tree
rc="$(FAKE_USAGE_MODE=two run_runner)"; [ "$rc" -eq 0 ] || fail "B: 실행 실패 ($rc)"
[ "$(rowf WORKER '[.num_turns,.input_uncached,.cache_read,.cache_write,.input_effective,.output,.reasoning_output,.tokens_total]|@csv')" = '2,4500,6500,1000,12000,600,350,12600' ] || fail "B: 합산 불일치: $(row WORKER)"
# luna: (12000-6500)*0.20 + 6500*0.02 + 600*1.20 = 1100 + 130 + 720 = 1950 /1M
[ "$(rowf WORKER '((.estimated_cost_usd*100000000)|round)')" = 195000 ] || fail "B: 합산 비용 불일치: $(row WORKER)"
pass "B: turn.completed 여러 개 합산(num_turns 2)"

# ===== 사례 C: 가격표에 없는 모델 → estimated null / unknown =====
reset_tree
sed -i.bak 's/^WORKER_MODEL=.*/WORKER_MODEL="gpt-9-future"/' "$CFG" && rm -f "$CFG.bak"
rc="$(FAKE_USAGE_MODE=one run_runner)"; [ "$rc" -eq 0 ] || fail "C: 실행 실패 ($rc)"
[ "$(rowf WORKER '[.model,.cost_usd,.estimated_cost_usd,.cost_kind,.pricing_basis,.tokens_total]|@csv')" = '"gpt-9-future",,,"unknown",,10500' ] || fail "C: unknown 모델 행 불일치: $(row WORKER)"
[ "$(bash -c "source $CFG; usage_summary" | jq -r '.by_role.WORKER.cost_unknown_invocations')" = 1 ] || fail "C: unknown 이 집계되지 않음"
# gpt-6 luna/sol 가격: luna 4000*0.10+6000*0.01+500*0.50 = 400+60+250 = 710 /1M
sed -i.bak 's/^WORKER_MODEL=.*/WORKER_MODEL="gpt-6-luna"/' "$CFG" && rm -f "$CFG.bak"
reset_tree; rc="$(FAKE_USAGE_MODE=one run_runner)"; [ "$rc" -eq 0 ] || fail "C(gpt-6): 실행 실패 ($rc)"
[ "$(rowf WORKER '[.model,.cost_kind,((.estimated_cost_usd*100000000)|round)]|@csv')" = '"gpt-6-luna","estimated",71000' ] || fail "C(gpt-6-luna): 비용 불일치: $(row WORKER)"
[ "$(bash -c "source $CFG; codex_model_pricing gpt-6-sol")" = "2.00 0.20 10.00" ] || fail "C(gpt-6-sol): 가격표 불일치"
sed -i.bak 's/^WORKER_MODEL=.*/WORKER_MODEL="gpt-5.6-luna"/' "$CFG" && rm -f "$CFG.bak"
pass "C: 가격표에 없는 모델 → estimated_cost_usd null, cost_kind unknown, 추측 가격 없음"

# ===== 사례 D: rc≠0 + 유효한 -o 결과 → CLI_EXIT_STATUS_MISMATCH 복구 유지 (워커 + 읽기 전용 검증자), raw exit_code 보존 =====
reset_tree
rc="$(FAKE_USAGE_MODE=one FAKE_CODEX_RC=1 run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -20 "$TMP/run.log"; fail "D: 워커 exit 1 + 유효 결과가 DONE 으로 복구되지 않음 ($rc/$(status))"; }
[ "$(calls worker)" -eq 1 ] || fail "D: 워커가 재실행됨"
grep -q 'CLI_EXIT_STATUS_MISMATCH: WORKER codex exited 1' "$TMP/run.log" || fail "D: 워커 mismatch WARN 없음"
[ "$(rowf WORKER '[.exit_code,.success,.tokens_total]|@csv')" = '1,false,10500' ] || fail "D: usage 행이 raw exit 1/false + 토큰을 함께 보존하지 않음: $(row WORKER)"
jq -e '.role=="WORKER" and .recovery=="STRUCTURED_RESULT" and .raw_exit_code==1' .agent-work/cli-anomalies.jsonl >/dev/null || fail "D: anomaly 행 불일치"
# 읽기 전용 검증자(codex) exit 1 + -o 결과 → 사용, usage 행 기록
rm -f .agent-work/consensus-design.json .agent-work/usage.jsonl .agent-work/cli-anomalies.jsonl; : > "$MOCK_LOG"
FAKE_USAGE_MODE=one FAKE_CODEX_RC=1 bash "$LOOP" design > "$TMP/loop.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q 'CLI_EXIT_STATUS_MISMATCH: VALIDATOR codex exited 1' "$TMP/loop.log" || { tail -10 "$TMP/loop.log"; fail "D: 검증자 exit 1 + -o 결과 복구가 깨짐 ($rc)"; }
# sol: 4000*4.00 + 6000*0.40 + 500*20.00 = 16000 + 2400 + 10000 = 28400 /1M
[ "$(rowf VALIDATOR '[.exit_code,.success,.model,.cost_kind,((.estimated_cost_usd*1000000)|round)]|@csv')" = '1,false,"gpt-5.6-sol","estimated",28400' ] || fail "D: 검증자 usage 행 불일치: $(row VALIDATOR)"
grep -q 'validator-design-round-01.json.invocation-.*\.tmp$' "$MOCK_STATE/o-args" || fail "F: 검증자 -o 가 invocation 전용 임시 경로가 아님: $(cat "$MOCK_STATE/o-args")"
pass "D: rc≠0 + 유효 -o 결과 → 기존 CLI_EXIT_STATUS_MISMATCH 복구 유지(워커·검증자), raw exit_code 와 토큰 함께 기록"

# ===== 사례 E: usage 이벤트 없음(옛 plain 텍스트만)/깨짐 → WARN + 행 생략, 실행은 성공, 재실행 없음 =====
for mode in none broken; do
  reset_tree
  rc="$(FAKE_USAGE_MODE=$mode run_runner)"
  [ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -20 "$TMP/run.log"; fail "E($mode): telemetry 실패가 실행을 실패시킴 ($rc/$(status))"; }
  [ "$(calls worker)" -eq 1 ] || fail "E($mode): telemetry 때문에 워커가 재실행됨 ($(calls worker)회)"
  grep -q 'turn.completed usage 없음 — 기록 생략' "$TMP/run.log" || fail "E($mode): WARN 이 없음"
  [ "$(row WORKER | wc -l | tr -d ' ')" = 0 ] || fail "E($mode): usage 없는 invocation 이 행으로 기록됨: $(row WORKER)"
  [ "$(row REVIEWER | wc -l | tr -d ' ')" = 1 ] || fail "E($mode): 다른 역할의 행이 사라짐"
done
pass "E: usage 이벤트 없음/깨짐 → WARN + 행 생략(plain 'tokens used' 미사용), 실행 성공, 같은 invocation 재실행 없음"

rm -rf "$TMP"
echo "smoke-codex-usage: 전부 통과"
