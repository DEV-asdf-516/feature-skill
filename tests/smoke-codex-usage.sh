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
#   E. usage 이벤트 없음/깨짐/usage:{}/정상+깨진 줄 혼재 → WARN + unknown 행 1개(과소 집계·0달러 없음), 피처 실행은 그대로 성공, 같은 invocation 재실행 없음
#   F. invocation 별 usage 행 정확히 1개, stdout(events.jsonl)/stderr(stderr.log) 분리, -o 는 invocation 전용 임시 경로(provenance 유지)
#   G. usage_summary: reported/estimated/combined/cost_unknown 분리
#   H. gpt-6-astra 단문/장문(turn 별 272K 판정)·캐시 쓰기 별도율·가정 기록·음수 토큰·미등록 모델 unknown
#   I. DONE 보고 줄·usage-summary.json 이 usage_summary 와 같은 숫자, by_cli/by_model
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
  none) printf '{"type":"item.completed","item":{"type":"agent_message","text":"tokens used 123"}}\n';;   # 유효 JSON 이벤트만, turn.completed 없음
  plain) printf 'tokens used\n123\n';;   # 옛 plain 텍스트 — JSON 이 아니므로 CORRUPT(읽지 않는다)
  broken) printf '{"type":"turn.completed","usage":{"input_tokens":\n';;
  emptyusage) printf '{"type":"turn.completed","usage":{}}\n';;
  corruptmix) printf '{"type":"turn.completed","usage":{"input_tokens":10000,"cached_input_tokens":6000,"cache_write_input_tokens":1000,"output_tokens":500,"reasoning_output_tokens":300}}\n'
              printf 'not json at all\n';;
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
    .agent-work/worker-result.json .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/reviews/impl-attempt-* .agent-work/.session-* \
    .agent-work/worker-session.json .agent-work/worker-session.migrate* .agent-work/worker-handoff.json .agent-work/usage.jsonl \
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
[ "$(rowf WORKER '[.cli,.model,.schema_version,.source,.num_turns]|@csv')" = '"codex","gpt-5.6-luna",4,"codex-events",1' ] || fail "A: 워커 행 메타 불일치: $(row WORKER)"
[ "$(rowf WORKER '[.input_uncached,.cache_read,.cache_write,.input_effective,.output,.reasoning_output,.tokens_total]|@csv')" = '3000,6000,1000,10000,500,300,10500' ] || fail "A: 토큰 매핑 불일치: $(row WORKER)"
[ "$(rowf WORKER '[.cost_usd,.cost_kind,((.estimated_cost_usd*100000000)|round),.pricing_basis,.exit_code,.success]|@csv')" = ',"estimated",157000,"openai-api-standard-2026-10-30",0,true' ] || fail "A: 비용 필드 불일치(luna 5.6: 3000*0.20 + 6000*0.02 + 1000*0.25(30분 캐시 쓰기) + 500*1.20 = 1570/1M): $(row WORKER)"
[ "$(rowf WORKER '.pricing_assumptions | (index("cache_write_ttl=30m(assumed; TTL not observable in events)") != null) and (any(startswith("cache_write_rate=")) | not)')" = true ] || fail "A: luna 행의 가정 목록 불일치(TTL 30분 가정 있어야 하고 단가 미등록 가정은 없어야 함): $(row WORKER)"
[ "$(rowf WORKER '[.usage_observation_status,.usage_error]|@csv')" = '"complete",' ] || fail "A: 정상 행의 usage_observation_status 가 complete 가 아님"
[ "$(rowf WORKER '.tokens_total == (.input_effective + .output)')" = true ] || fail "A: tokens_total 에 reasoning 이 이중 가산됨"
raw="$(ls .agent-work/units/01-intake/worker-*.log.events.jsonl | head -1)"
[ -f "$raw" ] && [ -f "${raw%.events.jsonl}.stderr.log" ] || fail "F: stdout 이벤트/stderr 로그가 분리되지 않음: $(ls .agent-work/units/01-intake)"
jq -e 'select(.type=="turn.completed")' "$raw" >/dev/null && grep -q 'diag to stderr' "${raw%.events.jsonl}.stderr.log" && ! grep -q 'diag to stderr' "$raw" || fail "F: JSONL 에 stderr 가 섞였거나 stderr 로그가 비어 있음"
[ -f .agent-work/reviews/validator-impl-round-01.json.events.jsonl ] && [ -f .agent-work/reviews/validator-impl-round-01.json.stderr.log ] || fail "F: 읽기 전용(검증자) 호출도 events/stderr 분리돼야 함"
grep -q '^\.agent-work/units/01-intake/worker-result.json$' "$MOCK_STATE/o-args" || fail "F: 워커 -o 가 unit 결과 경로가 아님: $(cat "$MOCK_STATE/o-args")"
ls .agent-work/reviews | grep -q 'invocation-.*\.tmp' && fail "F: invocation 임시 -o 파일이 남음"
# claude 행(리뷰어)은 reported 비용 그대로, codex 전용 필드 null
[ "$(rowf REVIEWER '[.cost_usd,.cost_kind,.estimated_cost_usd,.reasoning_output,.schema_version]|@csv')" = '0.25,"reported",,,4' ] || fail "A: claude 행 비용 provenance 불일치: $(row REVIEWER)"
pass "A/F: 워커 invocation 당 usage 행 1개, input/cache/output/reasoning 매핑, luna 추정 비용 0.00157, reasoning 이중 가산 없음, events/stderr 분리, -o provenance 유지"

# ===== 사례 G: usage_summary 비용 분리 (reviewer reported 0.25 + worker estimated 0.00152, 검증자(sol) 는 픽스처 단계 행) =====
summary="$(bash -c "source $CFG; usage_summary")"
[ "$(printf '%s' "$summary" | jq -r '[((.reported_cost_usd*100)|round), .cost_unknown_invocations, (.by_role.WORKER.cost_unknown_invocations), ((.by_role.WORKER.estimated_cost_usd*100000000)|round), (.by_role.REVIEWER.estimated_cost_usd)]|@csv')" = '25,0,0,157000,0' ] \
  || fail "G: usage_summary 비용 분리 불일치: $summary"
[ "$(printf '%s' "$summary" | jq -r '(.combined_cost_usd_estimate - .reported_cost_usd - .estimated_cost_usd) | fabs < 0.0000001')" = true ] || fail "G: combined ≠ reported + estimated: $summary"
pass "G: usage_summary reported/estimated/combined/cost_unknown 분리"

# ===== 사례 B: turn.completed 여러 개 → 합산 =====
reset_tree
rc="$(FAKE_USAGE_MODE=two run_runner)"; [ "$rc" -eq 0 ] || fail "B: 실행 실패 ($rc)"
[ "$(rowf WORKER '[.num_turns,.input_uncached,.cache_read,.cache_write,.input_effective,.output,.reasoning_output,.tokens_total]|@csv')" = '2,4500,6500,1000,12000,600,350,12600' ] || fail "B: 합산 불일치: $(row WORKER)"
# luna 5.6, turn 별: turn1 3000*0.20+6000*0.02+1000*0.25+500*1.20 = 1570 / turn2 1500*0.20+500*0.02+100*1.20 = 430 → 2000 /1M
[ "$(rowf WORKER '((.estimated_cost_usd*100000000)|round)')" = 200000 ] || fail "B: 합산 비용 불일치: $(row WORKER)"
pass "B: turn.completed 여러 개 합산(num_turns 2)"

# ===== 사례 C: 가격표에 없는 모델 → estimated null / unknown =====
reset_tree
sed -i.bak 's/^WORKER_MODEL=.*/WORKER_MODEL="gpt-9-future"/' "$CFG" && rm -f "$CFG.bak"
rc="$(FAKE_USAGE_MODE=one run_runner)"; [ "$rc" -eq 0 ] || fail "C: 실행 실패 ($rc)"
[ "$(rowf WORKER '[.model,.cost_usd,.estimated_cost_usd,.cost_kind,.pricing_basis,.tokens_total]|@csv')" = '"gpt-9-future",,,"unknown",,10500' ] || fail "C: unknown 모델 행 불일치: $(row WORKER)"
[ "$(bash -c "source $CFG; usage_summary" | jq -r '.by_role.WORKER.cost_unknown_invocations')" = 1 ] || fail "C: unknown 이 집계되지 않음"
# gpt-6-luna(GOAL-6): 3000*0.10 + 6000*0.01 + 1000*0.125 + 500*0.50 = 300+60+125+250 = 735 /1M
sed -i.bak 's/^WORKER_MODEL=.*/WORKER_MODEL="gpt-6-luna"/' "$CFG" && rm -f "$CFG.bak"
reset_tree; rc="$(FAKE_USAGE_MODE=one run_runner)"; [ "$rc" -eq 0 ] || fail "C(gpt-6): 실행 실패 ($rc)"
[ "$(rowf WORKER '[.model,.cost_kind,((.estimated_cost_usd*100000000)|round)]|@csv')" = '"gpt-6-luna","estimated",73500' ] || fail "C(gpt-6-luna): 비용 불일치: $(row WORKER)"
[ "$(bash -c "source $CFG; codex_model_pricing gpt-6-sol" | jq -r '[(.input*100|round),(.cached*100|round),(.cache_write_30m*100|round),(.cache_write_12h*100|round),(.output*100|round),.long_context_input_tokens,(.long.input*100|round)]|@csv')" = '200,20,250,500,1000,272000,400' ] || fail "C(gpt-6-sol): 가격표 불일치"
bash -c "source $CFG; codex_model_pricing gpt-6.1-sol" >/dev/null 2>&1 && fail "C: 정확한 모델 ID 매칭이 아님(gpt-6.1-sol 이 등록 모델로 취급됨)"
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
# sol 5.6: uncached 3000*4.00 + cache_read 6000*0.40 + cache_write 1000*5.00(별도율) + 500*20.00 = 12000 + 2400 + 5000 + 10000 = 29400 /1M
[ "$(rowf VALIDATOR '[.exit_code,.success,.model,.cost_kind,((.estimated_cost_usd*1000000)|round)]|@csv')" = '1,false,"gpt-5.6-sol","estimated",29400' ] || fail "D: 검증자 usage 행 불일치: $(row VALIDATOR)"
grep -q 'validator-design-round-01.json.invocation-.*\.tmp$' "$MOCK_STATE/o-args" || fail "F: 검증자 -o 가 invocation 전용 임시 경로가 아님: $(cat "$MOCK_STATE/o-args")"
pass "D: rc≠0 + 유효 -o 결과 → 기존 CLI_EXIT_STATUS_MISMATCH 복구 유지(워커·검증자), raw exit_code 와 토큰 함께 기록"

# ===== 사례 E: usage 이벤트 없음(옛 plain 텍스트만)/깨짐 → WARN + 행 생략, 실행은 성공, 재실행 없음 =====
# [리뷰 1] none → USAGE_EVENTS_MISSING / broken(JSON 못 읽는 줄) → USAGE_EVENTS_CORRUPT / emptyusage(usage:{}) → USAGE_FIELDS_INCOMPLETE /
# corruptmix(정상 turn + 깨진 줄) → 정상 turn 만 합산해 complete 로 적지 않고 unknown(partial). 어느 경우도 0 달러·estimated 가 아니다.
for mode in none:USAGE_EVENTS_MISSING:unavailable plain:USAGE_EVENTS_CORRUPT:unavailable broken:USAGE_EVENTS_CORRUPT:unavailable emptyusage:USAGE_FIELDS_INCOMPLETE:unavailable corruptmix:USAGE_EVENTS_CORRUPT:partial; do
  err="${mode#*:}"; err="${err%%:*}"; obs="${mode##*:}"; mode="${mode%%:*}"
  reset_tree
  rc="$(FAKE_USAGE_MODE=$mode run_runner)"
  [ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -20 "$TMP/run.log"; fail "E($mode): telemetry 실패가 실행을 실패시킴 ($rc/$(status))"; }
  [ "$(calls worker)" -eq 1 ] || fail "E($mode): telemetry 때문에 워커가 재실행됨 ($(calls worker)회)"
  grep -q 'unknown 행으로 기록' "$TMP/run.log" || fail "E($mode): WARN 이 없음"
  # [GOAL-6] 실제로 시작한 invocation 은 행 1개(unknown) — 비용·토큰은 null(0 아님), 원본 이벤트 경로 보존
  [ "$(row WORKER | wc -l | tr -d ' ')" = 1 ] && [ "$(rowf WORKER '[.cost_kind,.cost_usd,.estimated_cost_usd,.tokens_total,.input_uncached,.usage_observation_status,.usage_error,(.raw_log|endswith(".events.jsonl"))]|@csv')" = "\"unknown\",,,,,\"$obs\",\"$err\",true" ] \
    || fail "E($mode): usage 판정 불가 invocation 이 unknown 행 1개(null 비용·토큰, $err/$obs)로 기록되지 않음: $(row WORKER)"
  [ "$(row REVIEWER | wc -l | tr -d ' ')" = 1 ] || fail "E($mode): 다른 역할의 행이 사라짐"
  [ "$(bash -c "source $CFG; usage_summary" | jq -r '[.cost_unknown_invocations,.usage_unobserved_invocations]|@csv')" = '1,1' ] || fail "E($mode): 요약이 미관측 invocation 을 세지 않음"
  grep -q '추정 불가 1건(사용량 미관측 1건' "$TMP/run.log" || fail "E($mode): DONE 보고에 미관측 건수가 없음"
done
pass "E: usage 이벤트 없음/깨짐/usage:{}/정상+깨진 줄 혼재 → WARN + unknown 행 1개(0달러 아님, 과소 집계 없음, plain 'tokens used' 미사용), 실행 성공, 같은 invocation 재실행 없음"

# ===== 사례 H: gpt-6-astra 단문/장문 구간, 캐시 쓰기 별도율, 가정 기록 (P0-4) — 러너 없이 recorder 직접 호출 =====
#   단문 turn {input 10000, cached 6000, write 1000, output 500}: 3000*10 + 6000*1 + 1000*12.5 + 500*50 = 73500 /1M = 0.0735
#   장문 turn {input 300000(>272K), cached 100000, write 50000, output 1000}: 150000*20 + 100000*2 + 50000*25 + 1000*75 = 4525000 /1M = 4.525
#   같은 invocation 에 두 turn 이 섞이면 turn 별로 구간을 고른다(누적 입력으로 판정하지 않음): 0.0735 + 4.525 = 4.5985, long_context_turns 1
reset_tree
printf '{"type":"thread.started","thread_id":"t-h"}\n{"type":"turn.completed","usage":{"input_tokens":10000,"cached_input_tokens":6000,"cache_write_input_tokens":1000,"output_tokens":500,"reasoning_output_tokens":300}}\n' > "$TMP/side/astra-short.jsonl"
printf '{"type":"thread.started","thread_id":"t-h"}\n{"type":"turn.completed","usage":{"input_tokens":300000,"cached_input_tokens":100000,"cache_write_input_tokens":50000,"output_tokens":1000,"reasoning_output_tokens":0}}\n' > "$TMP/side/astra-long.jsonl"
cat "$TMP/side/astra-short.jsonl" "$TMP/side/astra-long.jsonl" > "$TMP/side/astra-mixed.jsonl"
rec() { bash -c "source $CFG; log_role_usage codex \"$1\" \"$2\" \"$3\" \"$4\" 0 inv-$3" 2>>"$TMP/side/rec.warn"; }
rec VALIDATOR gpt-6-astra h-short "$TMP/side/astra-short.jsonl"; rec VALIDATOR gpt-6-astra h-long "$TMP/side/astra-long.jsonl"; rec REVIEWER gpt-6-astra h-mixed "$TMP/side/astra-mixed.jsonl"
rowl() { jq -c --arg l "$1" 'select(.label==$l)' .agent-work/usage.jsonl; }
[ "$(rowl h-short | jq -r '[.cost_kind,((.estimated_cost_usd*10000)|round),.long_context_turns,.pricing_basis]|@csv')" = '"estimated",735,0,"openai-api-standard-2026-10-30"' ] || fail "H(short): astra 단문 비용 불일치: $(rowl h-short)"
[ "$(rowl h-long | jq -r '[.cost_kind,((.estimated_cost_usd*1000)|round),.long_context_turns]|@csv')" = '"estimated",4525,1' ] || fail "H(long): astra 장문 비용 불일치: $(rowl h-long)"
[ "$(rowl h-mixed | jq -r '[((.estimated_cost_usd*10000)|round),.long_context_turns,.num_turns]|@csv')" = '45985,1,2' ] || fail "H(mixed): turn 별 구간 선택이 아님(누적 판정?): $(rowl h-mixed)"
[ "$(rowl h-short | jq -r '.pricing_assumptions | (index("cache_write_ttl=30m(assumed; TTL not observable in events)") != null) and (any(startswith("long_context_tier=turn_proxy(per turn.completed input_tokens>272000")))')" = true ] || fail "H: 캐시 쓰기 TTL·장문 판정(turn_proxy) 가정이 기록되지 않음: $(rowl h-short)"
[ "$(rowl h-short | jq -r '.pricing_assumptions | any(startswith("cache_write_rate="))')" = false ] || fail "H: astra 는 캐시 쓰기율이 등록돼 있는데 단가 가정이 붙음"
# 음수 토큰 → 0 으로, 가격표 밖 모델은 unknown(0 달러 아님), usage 없음은 unknown 행(0 달러 아님 — 사례 E)
printf '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":200,"cache_write_input_tokens":-5,"output_tokens":10}}\n' > "$TMP/side/neg.jsonl"
rec WORKER gpt-6-astra h-neg "$TMP/side/neg.jsonl"
[ "$(rowl h-neg | jq -r '[.input_uncached,.cache_write,((.estimated_cost_usd*10000000)|round)]|@csv')" = '0,0,7000' ] || fail "H(neg): 음수 토큰 방지 실패: $(rowl h-neg)"
rec WORKER gpt-9-future h-unknown "$TMP/side/astra-short.jsonl"
[ "$(rowl h-unknown | jq -r '[.cost_kind,.estimated_cost_usd,.pricing_assumptions,.pricing_basis]|@csv')" = '"unknown",,,' ] || fail "H(unknown): 미등록 모델이 0 달러/추정으로 기록됨: $(rowl h-unknown)"
pass "H: gpt-6-astra 단문 0.0735 / 장문(turn 입력 272K 초과) 4.525 / 혼합은 turn 별 구간, 캐시 쓰기 별도율·TTL 30분 가정 기록, 음수 토큰 0, 미등록 모델 unknown"

# ===== 사례 I: 최종 보고(러너 DONE 로그·usage-summary.json)와 usage_summary 숫자 일치, by_cli/by_model 분리 =====
reset_tree
rc="$(FAKE_USAGE_MODE=one run_runner)"; [ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "I: 실행 실패 ($rc)"
summary="$(bash -c "source $CFG; usage_summary")"
[ -f .agent-work/usage-summary.json ] && [ "$(jq -c '[.invocations,.reported_cost_usd,.estimated_cost_usd,.combined_cost_usd_estimate,.cost_unknown_invocations]' .agent-work/usage-summary.json)" = "$(printf '%s' "$summary" | jq -c '[.invocations,.reported_cost_usd,.estimated_cost_usd,.combined_cost_usd_estimate,.cost_unknown_invocations]')" ] \
  || fail "I: usage-summary.json 이 usage_summary 와 다름"
line="$(grep '비용(usage_summary' "$TMP/run.log")" || fail "I: DONE 로그에 비용 보고 줄이 없음"
case "$line" in *"Claude 보고 비용 \$0.25 (reported)"*"Codex 추정 비용 \$0.0016 (API 표준 요금 기준 환산, estimated)"*"합계 추정 \$0.2516 (실제 청구액 아님)"*"추정 불가 0건(사용량 미관측 0건"*) ;; *) fail "I: 보고 줄의 숫자가 usage_summary 와 다름: $line";; esac
case "$line" in *"claude=1건(reported \$0.25, estimated \$0"*"codex=1건(reported \$0, estimated \$0.0016"*) ;; *) fail "I: by_cli 분리 보고 없음: $line";; esac
[ "$(printf '%s' "$summary" | jq -r '[.by_cli.codex.invocations,.by_cli.claude.invocations,.by_model["gpt-5.6-luna"].invocations,(.by_model["gpt-5.6-luna"].estimated_cost_usd*100000000|round),(.pricing_bases|join(","))]|@csv')" = '1,1,1,157000,"openai-api-standard-2026-10-30"' ] || fail "I: by_cli/by_model/pricing_bases 불일치: $summary"
pass "I: DONE 보고(reported + estimated + combined 추정 + unknown 건수)가 usage_summary·usage-summary.json 과 같은 숫자, by_cli/by_model 분리"

# ===== 사례 J (GOAL-6 P0-A): 5종 × short/long 요금표 전수 비교, 30m/12h 캐시 쓰기, 272,000/272,001 경계, 요청 전체 요율, 누적 비판정 =====
price() { bash -c "source $CFG; codex_model_pricing $1"; }
est() { bash -c "source $CFG; codex_estimate_cost '$1' \"\$(codex_model_pricing $2)\""; }   # turns_json model
flat() { jq -r '[.input,.cached,.cache_write_30m,.cache_write_12h,.output,.long_context_input_tokens,.long.input,.long.cached,.long.cache_write_30m,.long.cache_write_12h,.long.output]|map(tostring)|join(" ")' | sed 's/\.0\b//g'; }
check_price() { [ "$(price "$1" | flat)" = "$2" ] || fail "J: $1 요금표 불일치: $(price "$1" | flat) ≠ $2"; }
check_price gpt-6-astra  "10 1 12.5 25 50 272000 20 2 25 50 75"
check_price gpt-5.6-sol  "4 0.4 5 10 20 272000 8 0.8 10 20 30"
check_price gpt-6-sol    "2 0.2 2.5 5 10 272000 4 0.4 5 10 15"
check_price gpt-5.6-luna "0.2 0.02 0.25 0.5 1.2 272000 0.4 0.04 0.5 1 1.8"
check_price gpt-6-luna   "0.1 0.01 0.125 0.25 0.5 272000 0.2 0.02 0.25 0.5 0.75"
for m in gpt-6-astra gpt-5.6-sol gpt-6-sol gpt-5.6-luna gpt-6-luna; do
  p="$(price "$m")"
  [ "$(printf '%s' "$p" | jq -r '[.cache_write_30m,.cache_write_12h,.long.cache_write_30m,.long.cache_write_12h,.long]|map(.==null)|any')" = false ] || fail "J: $m 에 null 캐시 쓰기/long 이 남음"
  # long = short×2(입력·캐시·캐시쓰기), 출력 ×1.5 / 30m = 입력×1.25, 12h = 입력×2.5
  [ "$(printf '%s' "$p" | jq -r '(.long.input==.input*2) and (.long.cached==.cached*2) and (.long.cache_write_30m==.cache_write_30m*2) and (.long.cache_write_12h==.cache_write_12h*2) and ((.long.output*100|round)==(.output*150|round)) and ((.cache_write_30m*1000|round)==(.input*1250|round)) and ((.cache_write_12h*1000|round)==(.input*2500|round)) and ((.long.cache_write_30m*1000|round)==(.long.input*1250|round))')" = true ] || fail "J: $m 의 구간/캐시 쓰기 비율이 규칙과 다름: $p"
done
# 동일 fixture (input 10000, cached 6000, write 1000(30m), output 500) 의 기대값
fx='[{"i":10000,"c":6000,"w":1000,"w12":0,"o":500,"r":300}]'
for pair in gpt-6-astra:735000 gpt-5.6-sol:294000 gpt-6-sol:147000 gpt-5.6-luna:15700 gpt-6-luna:7350; do
  m="${pair%%:*}"; want="${pair##*:}"
  got="$(est "$fx" "$m" | jq -r '(.estimated_cost_usd*10000000|round)')"
  [ "$got" = "$want" ] || fail "J: $m fixture 비용 불일치: $got ≠ $want (/1e7)"
done
# 30m/12h 분기: 12h 토큰이 분리 관측되면 12h 단가, 캐시 쓰기 토큰은 일반 입력으로 다시 과금하지 않는다(uncached 에서 제외)
# astra: uncached 10000-6000-1000-500 = 2500*10 + 6000*1 + 1000*12.5 + 500*25 + 500*50 = 25000+6000+12500+12500+25000 = 81000
got="$(est '[{"i":10000,"c":6000,"w":1000,"w12":500,"o":500,"r":0}]' gpt-6-astra)"
[ "$(printf '%s' "$got" | jq -r '[(.estimated_cost_usd*10000000|round),(.assumptions|any(startswith("cache_write_ttl=observed")))]|@csv')" = '810000,true' ] || fail "J: 30m/12h 분기 또는 캐시 쓰기 이중 과금: $got"
# 경계: 272,000 은 short, 272,001 은 long — 요청(turn) 전체에 long 요율 (sol 5.6: 272000*4=1088000 vs 272001*8=2176008 /1M)
[ "$(est '[{"i":272000,"c":0,"w":0,"w12":0,"o":0,"r":0}]' gpt-5.6-sol | jq -r '[(.estimated_cost_usd*1000|round),.long_context_turns]|@csv')" = '1088,0' ] || fail "J: 272,000 이 short 가 아님"
[ "$(est '[{"i":272001,"c":0,"w":0,"w12":0,"o":0,"r":0}]' gpt-5.6-sol | jq -r '[(.estimated_cost_usd*1000000|round),.long_context_turns]|@csv')" = '2176008,1' ] || fail "J: 272,001 이 요청 전체 long 요율이 아님"
# 작은 turn 여럿의 합이 272K 를 넘어도 long 이 아니다(누적 판정 금지): 3×100,000 → 300000*4 = 1.2 (/1M)
[ "$(est '[{"i":100000,"c":0,"w":0,"w12":0,"o":0,"r":0},{"i":100000,"c":0,"w":0,"w12":0,"o":0,"r":0},{"i":100000,"c":0,"w":0,"w12":0,"o":0,"r":0}]' gpt-5.6-sol | jq -r '[(.estimated_cost_usd*10|round),.long_context_turns]|@csv')" = '12,0' ] || fail "J: 누적 토큰으로 long 판정됨"
[ "$(est "$fx" gpt-6-sol | jq -r '.assumptions | any(startswith("long_context_tier=turn_proxy"))')" = true ] || fail "J: turn_proxy 한계 가정이 없음"
# [리뷰 4] 12시간 캐시 쓰기만 있는 turn(w=0, w12>0) 에도 TTL 근거가 남는다(observed) — 금액: astra 2500*10+6000*1+200*25+500*50 = 25000+6000+5000+25000 = 61000 /1M
got="$(est '[{"i":8700,"c":6000,"w":0,"w12":200,"o":500,"r":0}]' gpt-6-astra)"
[ "$(printf '%s' "$got" | jq -r '[(.estimated_cost_usd*10000000|round),(.assumptions|any(startswith("cache_write_ttl=observed"))),(.assumptions|any(startswith("cache_write_ttl=30m")))]|@csv')" = '610000,true,false' ] || fail "J: 12h-only turn 의 TTL 근거가 빠짐: $got"
[ "$(est '[{"i":1000,"c":0,"w":0,"w12":0,"o":10,"r":0}]' gpt-6-astra | jq -r '.assumptions|any(startswith("cache_write_ttl="))')" = false ] || fail "J: 캐시 쓰기 없는 turn 에 TTL 가정이 붙음"
pass "J: 5종×short/long 요금표 전수 일치(null 없음, ×2/×1.5/×1.25/×2.5 규칙), fixture 5종 비용, 30m/12h 분기(12h-only TTL 근거 포함), 272,000/272,001 경계·요청 전체 요율, 누적 비판정"

rm -rf "$TMP"
echo "smoke-codex-usage: 전부 통과"
