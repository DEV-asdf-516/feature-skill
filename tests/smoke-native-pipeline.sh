#!/usr/bin/env bash
# =============================================================
# 전 역할 native Agent 종단 스모크 (모델 호출 0회 — 실제 feature-run.sh + 훅 입력·Agent 전사 fixture)
# 다섯 역할 모두 claude 모델(CLAUDE_BACKEND=native)이다. claude·codex CLI 는 호출을 기록하고 실패하는 stub 이라, 한 번이라도 불리면 사례가 깨진다.
# 설정은 다섯 역할 모두 native 지만 이 파일의 사례가 실제로 호출하는 역할은 검증자·워커·리뷰어·수정자 넷이다(검증자가 PASS 해 디자이너 차례가 없다).
# native 디자이너는 tests/smoke-native-bridge.sh 의 합의 루프 사례(BLOCK → 디자이너 → PASS)가 검증한다.
# "메인 세션 + Claude Code" 는 sim_agent 가 흉내 낸다(전사·훅 페이로드 모양은 Claude Code 2.1.330 실모델 POC 에서 관측한 것).
#
# 사례
#   P1. R01 종단 — design 합의(검증자) → impl 합의(검증자) → 워커 unit → 빠른 검사 위반 → check-fix 워커(unit 밖 호출 지점) →
#       리뷰어 Round 1(REQUEST_CHANGES/FIX_CODE) → 수정자 → 리뷰어 Round 2(같은 Agent 재개, APPROVE) → verify → DONE.
#       모든 호출이 exit 42 를 거치고, 결과 없는 재실행은 같은 요청을 재제시한다(리뷰어 Round 1 은 attempt 를 올리지 않는다). CLI 0회.
#   P2. R20 — native 리뷰어의 출력이 계약에 어긋남 → REVIEW_OUTPUT_INVALID, 재실행은 모델 0회(새 요청 없음)로 같은 진단.
#   P3. R22 — native 리뷰어 DOC_GAP → NEED_USER(REVIEW_DOC_GAP) → 사용자 답 + approach.md 반영 → review-gap 워커(unit 밖 호출 지점, 같은 워커 Agent 재개)
#       → 새 리뷰 시도 → APPROVE → DONE. 검증자·디자이너 재호출 없음.
#   P4. 수정자 실행 중 계약 문서·리뷰 JSON 변경, decisions.md 의 기존 내용 변경·수정자 권한 밖 기록 추가 → NATIVE_STALE_REQUEST. 정상 ACCEPT/REJECT 추가는 수용.
# R21(codex resume thread id·marker)은 이 변경이 건드리지 않는 codex 경로다 — tests/smoke-codex-resume.sh 가 그대로 본다.
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-native-pipeline-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks" "$TMP/transcripts"
fail() { echo "[SMOKE FAIL] $*" >&2; [ ! -f "$TMP/run.log" ] || tail -25 "$TMP/run.log" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }
trap 'rm -rf "$TMP"' EXIT
unset CLAUDE_CODE_SUBAGENT_MODEL_FORCE CLAUDE_CODE_EFFORT_LEVEL NTFY_TOPIC WORKER_SESSION_ROTATE_INPUT_TOKENS
# 메인 Claude Code 프로세스 pid — 이 세션 안에서 돌리면 물려받는다. 남겨 두면 방금 만든 임시 agent 정의가 그 프로세스보다 새것이라 러너의 등록 증거 게이트(NATIVE_AGENT_RESTART_REQUIRED)가 멈춘다. 그 게이트는 tests/smoke-native-agent-definitions.sh 가 본다
unset CLAUDE_PID
export CLAUDE_CODE_SESSION_ID="sess-main" FEATURE_LIVE_TEE=1

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
cp "$PROJECT_SRC/.claude/hooks/feature_native_agent.sh" "$TMP/repo/.claude/hooks/" || fail "훅 복사 실패"
HOOK="$TMP/repo/.claude/hooks/feature_native_agent.sh"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
RUNTIME_LIB="$TMP/repo/.claude/skills/feature/scripts/lib/runtime.sh"
export CLI_LOG="$TMP/cli.log" MOCK_LOG="$TMP/calls.log"; : > "$CLI_LOG"; : > "$MOCK_LOG"
V="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$RUNTIME_LIB" | cut -d= -f2 | cut -d' ' -f1)"
RV="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$RUNTIME_LIB" | cut -d= -f2 | cut -d' ' -f1)"
for cli in claude codex; do
  printf '%s\n' '#!/usr/bin/env bash' "echo \"$cli \$*\" >> \"$CLI_LOG\"; exit 9" > "$TMP/bin/$cli"; chmod +x "$TMP/bin/$cli"
done
printf '%s\n' '#!/usr/bin/env bash' "echo full-test >> \"$MOCK_LOG\"" > "$TMP/bin/full-test"; chmod +x "$TMP/bin/full-test"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"$TMP/bin/full-test\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"true\"|; \
  s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"native\"|; s|^DESIGN_REVISION_MODEL=.*|DESIGN_REVISION_MODEL=\"claude-fable-5-2\"|; s|^VALIDATOR_MODEL=.*|VALIDATOR_MODEL=\"claude-opus-5-5\"|; \
  s|^WORKER_MODEL=.*|WORKER_MODEL=\"claude-opus-5-5\"|; s|^REVIEWER_MODEL=.*|REVIEWER_MODEL=\"claude-sonnet-5-5\"|; s|^FIXER_MODEL=.*|FIXER_MODEL=\"claude-sonnet-5-5\"|; \
  s|^VALIDATOR_PROFILE=.*|VALIDATOR_PROFILE=\"none\"|; s|^FAST_CHECK_CMD=.*|FAST_CHECK_CMD=\"tools/check.sh\"|" "$CFG" && rm -f "$CFG.bak"

cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src tools && printf 'line 1\nline 2\n' > src/a.txt
# 프로젝트 빠른 검사: src/a.txt 에 금지 토큰(BAD)이 있으면 규칙 위반(exit 1 + 진단), 없으면 통과. 읽기 전용이다.
cat > tools/check.sh <<'EOS'
#!/usr/bin/env bash
if grep -n 'BAD' src/a.txt; then echo "[no-bad-token] src/a.txt: 금지 토큰"; exit 1; fi
exit 0
EOS
chmod +x tools/check.sh
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
printf '\n## 01\nunit 01 contract\n' >> .agent-work/implementation.md
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/a.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
cat > .agent-work/implementation-units.json <<EOF
{"version":1,"units":[{"id":"01-core","title":"core","goal":"unit 01","requirements":["REQ-01"],"scope":{"files":["src/a.txt"],"new_file_roots":[]},"references":["implementation.md#01"],"targeted_test":"echo unit-test >> $MOCK_LOG"}]}
EOF

RUN=".claude/skills/feature/scripts/feature-run.sh"
ND="$TMP/repo/.agent-work/native-agent"
PASS_JSON="{\"schema_version\":$V,\"verdict\":\"PASS\",\"blocking_issues\":[]}"
DONE_JSON='{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}'
APPROVE_JSON="{\"schema_version\":$RV,\"verdict\":\"APPROVE\",\"issues\":[]}"
issue() { # action category user_question options-json
  printf '{"schema_version":%s,"verdict":"REQUEST_CHANGES","issues":[{"id":"R-01","action":"%s","category":"%s","evidence_type":"DIRECT_MISMATCH","basis_refs":["approach.md:L1"],"code_refs":["src/a.txt:L1-L1"],"reachable_scenario":"","impact":"i","why_blocks_now":"x","required_outcome":"y","origin":"ROUND_1","previous_issue_id":"","fix_ref":"","user_question":"%s","options":%s}]}' "$RV" "$1" "$2" "$3" "$4"
}
RC=0
run() { RC=0; bash "$RUN" > "$TMP/run.log" 2>&1 || RC=$?; }
reason() { jq -r '.reason' .agent-work/run-state.json; }
status() { jq -r '.status' .agent-work/run-state.json; }
req_file() { jq -r '.request_path' "$ND/pending.json"; }
req_get() { jq -r "$1" "$(req_file)"; }
req_count() { ls "$ND/requests"/*.json 2>/dev/null | wc -l | tr -d ' '; }

# 실제 Claude Code 와 같이 도구 호출마다 tool_use_id 가 다르고, dispatch 직후 PostToolUse(실측 응답 모양)가 온다 — 기본 경로는 DISPATCHING → DISPATCHED → RESULT_READY 다.
# SIM_DENY(거부 사유): 이 스킬의 훅은 통과시켰지만 다른 PreToolUse 훅이 같은 호출을 거부했다 — 메인 전사에 거부 결과만 남고 Agent 는 실행되지 않는다.
SIM_OUT=""; SIM_LAST_AGENT=""; SIM_LAST_TOOL=""; SIM_SEQ=0; SIM_TU=""
MAIN_TR="$TMP/transcripts/main-sess-main.jsonl"; mkdir -p "$TMP/transcripts"; : > "$MAIN_TR"
sim_agent() { # report-text   환경: SIM_SIDE(Agent 부작용 명령) SIM_DENY
  local req report="$1" prompt aid tr model effort intent tool
  req="$(req_file)"; intent="$(jq -r '.session_intent' "$req")"
  SIM_SEQ=$((SIM_SEQ + 1)); SIM_TU="toolu_sim_$SIM_SEQ"
  if [ "$intent" = RESUME ]; then
    tool=SendMessage
    SIM_OUT="$(jq -n --arg to "$(jq -r '.resume_agent_id' "$req")" --arg p "$(jq -r '.dispatch_line' "$req")" --arg tu "$SIM_TU" --arg tp "$MAIN_TR" \
      '{hook_event_name:"PreToolUse", session_id:"sess-main", transcript_path:$tp, tool_name:"SendMessage", tool_use_id:$tu, tool_input:{to:$to, message:$p}}' | "$HOOK")"
  else
    tool=Agent
    SIM_OUT="$(jq -n --arg t "$(jq -r '.agent_definition' "$req")" --arg p "$(jq -r '.dispatch_line' "$req")" --arg tu "$SIM_TU" --arg tp "$MAIN_TR" \
      '{hook_event_name:"PreToolUse", session_id:"sess-main", transcript_path:$tp, tool_name:"Agent", tool_use_id:$tu, tool_input:{subagent_type:$t, description:"sim", prompt:$p}}' | "$HOOK")"
  fi
  SIM_LAST_TOOL="$tool"
  [ "$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = allow ] || { echo "sim: dispatch 거부됨: $SIM_OUT" >&2; return 1; }
  prompt="$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.updatedInput | (.prompt // .message)')"
  aid="$(jq -r '.resume_agent_id // empty' "$req")"; [ -n "$aid" ] || aid="agent$RANDOM$RANDOM"
  SIM_LAST_AGENT="$aid"; tr="$TMP/transcripts/agent-$aid.jsonl"
  model="$(jq -r '.model' "$req")"; effort="$(jq -r '.effort' "$req")"
  [ "$(jq -r '.state' "$req")" = DISPATCHING ] || { echo "sim: PreToolUse 뒤 state 가 DISPATCHING 이 아님($(jq -r '.state' "$req"))" >&2; return 1; }
  if [ -n "${SIM_DENY:-}" ]; then
    jq -nc --arg tu "$SIM_TU" --arg t "$SIM_DENY" '{type:"user", sessionId:"sess-main", toolDenialKind:"permission-rule",
      permissionDecision:{decision:"reject", source:"hook", reasonType:"hook", reasonCode:"hook:PreToolUse"}, toolUseResult:("Error: " + $t),
      message:{role:"user", content:[{type:"tool_result", is_error:true, tool_use_id:$tu, content:$t}]}}' >> "$MAIN_TR"
    return 0
  fi
  if [ "$tool" = Agent ]; then
    jq -n --arg tu "$SIM_TU" --arg a "$aid" --arg m "$model" --argjson i "$(printf '%s' "$SIM_OUT" | jq -c '.hookSpecificOutput.updatedInput')" \
      '{hook_event_name:"PostToolUse", session_id:"sess-main", tool_name:"Agent", tool_use_id:$tu, tool_input:$i, tool_response:{isAsync:true, status:"async_launched", agentId:$a, resolvedModel:$m, canContinueAgent:true}}' | "$HOOK"
  else
    jq -n --arg tu "$SIM_TU" --arg a "$aid" --argjson i "$(printf '%s' "$SIM_OUT" | jq -c '.hookSpecificOutput.updatedInput')" \
      '{hook_event_name:"PostToolUse", session_id:"sess-main", tool_name:"SendMessage", tool_use_id:$tu, tool_input:$i, tool_response:{success:true, message:("Resuming agent " + $a), resumedAgentId:$a, revivedAgentId:$a}}' | "$HOOK"
  fi
  [ "$(jq -r '.state' "$req")" = DISPATCHED ] || { echo "sim: PostToolUse 뒤 state 가 DISPATCHED 가 아님($(jq -r '.state' "$req"))" >&2; return 1; }
  [ -z "${SIM_SIDE:-}" ] || ( eval "$SIM_SIDE" )
  { if [ "$tool" = SendMessage ]; then
      jq -nc --arg p "$prompt" --arg a "$aid" '{type:"user", isMeta:true, agentId:$a, sessionId:"sess-main", message:{role:"user", content:("The coordinator sent a message while you were working:\n" + $p + "\n" + "\n\nAddress this before completing your current task.")}}'
    else
      jq -nc --arg p "$prompt" --arg a "$aid" '{type:"user", agentId:$a, sessionId:"sess-main", message:{role:"user", content:$p}}'
    fi
    jq -nc --arg a "$aid" --arg m "$model" --arg e "$effort" --arg r "$report" --arg n "$RANDOM" \
      '{type:"assistant", agentId:$a, sessionId:"sess-main", requestedModel:$m, effort:$e, message:{id:("m-" + $a + "-" + $n), model:$m, stop_reason:"tool_use", usage:{input_tokens:5, cache_read_input_tokens:2000, cache_creation_input_tokens:0, output_tokens:70}, content:[{type:"tool_use", name:"SubagentHandback", input:{message:$r}}]}}'
  } >> "$tr"
  jq -n --arg a "$aid" --arg t "$(jq -r '.agent_definition' "$req")" --arg tp "$tr" \
    '{hook_event_name:"SubagentStop", session_id:"sess-main", agent_id:$a, agent_type:$t, agent_transcript_path:$tp, stop_hook_active:false}' | "$HOOK"
  [ "$(jq -r '.state' "$req")" = RESULT_READY ] || { echo "sim: 캡처되지 않음(state $(jq -r '.state' "$req"))" >&2; return 1; }
}
expect_req() { # role slot-suffix intent name   (slot = ROLE|<suffix>)
  [ "$RC" = 42 ] || fail "$4: exit 42 가 아님 (rc $RC, status $(status) / $(reason))"
  [ "$(req_get '.slot')" = "$1|$2" ] || fail "$4: 요청의 호출 지점이 다름: $(req_get '.slot') (기대 $1|$2)"
  [ "$(req_get '.session_intent')" = "$3" ] || fail "$4: session_intent 가 $3 가 아님: $(req_get '.session_intent')"
}
idle_rerun() { # name — 결과 없는 재실행: 같은 요청, 요청 수 불변
  local id n; id="$(req_get '.request_id')"; n="$(req_count)"
  run
  [ "$RC" = 42 ] && [ "$(req_get '.request_id')" = "$id" ] && [ "$(req_count)" = "$n" ] || fail "$1: 결과 없는 재실행이 같은 요청을 재제시하지 않음 (rc $RC, 요청 $n→$(req_count)개, $(status) / $(reason))"
}

# ================= P1. 전 역할 native 종단 =================
run; expect_req VALIDATOR "|design-validator-round-01" NEW "P1/design 검증자"
idle_rerun "P1/design 검증자"
sim_agent "$PASS_JSON" || fail "P1: design 검증자 dispatch 실패"
run; expect_req VALIDATOR "|impl-validator-round-01" NEW "P1/impl 검증자"
sim_agent "$PASS_JSON" || fail "P1: impl 검증자 dispatch 실패"
run; expect_req WORKER "01-core|worker" NEW "P1/워커 unit"
SIM_SIDE='echo "BAD token by worker" >> src/a.txt' sim_agent "$DONE_JSON" || fail "P1: 워커 dispatch 실패"; worker_agent="$SIM_LAST_AGENT"
# unit 수용 → targeted test → review: 빠른 검사 위반 → check-fix 워커 요청(unit 밖 호출 지점, 같은 워커 Agent 재개)
run; expect_req WORKER "check-fix|check-fix-01" RESUME "P1/check-fix"
[ "$(req_get '.resume_agent_id')" = "$worker_agent" ] || fail "P1: check-fix 가 같은 워커 Agent 재개가 아님"
jq -e '.active==true and .tag=="check-fix-01"' .agent-work/check-fix.pending.json >/dev/null || fail "P1: check-fix 진행 기록이 없음"
before_cf="$(cat .agent-work/check-fix-01-before.tree)"
idle_rerun "P1/check-fix"
[ "$(cat .agent-work/check-fix-01-before.tree)" = "$before_cf" ] && [ -z "$(ls .agent-work/check-fix-01-before.tree.prev-* 2>/dev/null)" ] || fail "P1: 결과 없는 재실행이 check-fix 호출 전 기록을 옮기거나 덮어씀"
SIM_SIDE="grep -v BAD src/a.txt > $TMP/a.clean; cat $TMP/a.clean > src/a.txt" sim_agent "$DONE_JSON" || fail "P1: check-fix dispatch 실패"
run; expect_req REVIEWER "|impl-review-a01-round-01" NEW "P1/리뷰어 R1"
jq -e '.active==false' .agent-work/check-fix.pending.json >/dev/null 2>&1 && [ -f .agent-work/check-fix-01-result.json ] && [ "$(jq -r '.fast_check_retries' .agent-work/run-state.json)" = 1 ] \
  || fail "P1: check-fix 턴이 확정되지 않음(진행 기록·결과·한도)"
idle_rerun "P1/리뷰어 R1"
[ "$(ls -d .agent-work/reviews/impl-attempt-* | wc -l | tr -d ' ')" = 1 ] || fail "P1: 리뷰어 Round 1 재실행이 attempt 를 올림: $(ls -d .agent-work/reviews/impl-attempt-*)"
sim_agent "$(issue FIX_CODE CONTRACT_VIOLATION "" "[]")" || fail "P1: 리뷰어 R1 dispatch 실패"; reviewer_agent="$SIM_LAST_AGENT"
run; expect_req FIXER "|impl-fix-a01-round-01" NEW "P1/수정자"
idle_rerun "P1/수정자"
SIM_SIDE='echo "fixed by fixer" >> src/a.txt; echo "- [fix round 1] R-01 ACCEPT: src/a.txt" >> .agent-work/decisions.md' sim_agent "수정했다." || fail "P1: 수정자 dispatch 실패"
run; expect_req REVIEWER "|impl-review-a01-round-02" RESUME "P1/리뷰어 R2"
[ "$(req_get '.resume_agent_id')" = "$reviewer_agent" ] || fail "P1: 리뷰어 Round 2 가 같은 Agent 재개가 아님"
grep -q '수정자 호출 중 작업 트리 변경 흔적 감지' "$TMP/run.log" && fail "P1: 수정자의 native 재실행 pass 가 '호출 중 죽음'으로 오판됨"
sim_agent "$APPROVE_JSON" || fail "P1: 리뷰어 R2 dispatch 실패"
run; [ "$RC" = 0 ] && [ "$(status)" = DONE ] || fail "P1: DONE 이 아님 (rc $RC, $(status) / $(reason))"
[ ! -s "$CLI_LOG" ] || fail "P1(R01): claude/codex CLI 가 불림: $(cat "$CLI_LOG")"
roles="$(jq -sr '[.[] | .role] | group_by(.) | map("\(.[0])=\(length)") | join(",")' .agent-work/usage.jsonl)"
[ "$roles" = "FIXER=1,REVIEWER=2,VALIDATOR=2,WORKER=2" ] || fail "P1: 역할별 native 호출 수가 다름: $roles"
[ "$(jq -sr '[.[] | .backend] | unique | join(",")' .agent-work/usage.jsonl)" = claude_native ] || fail "P1: native 가 아닌 usage 행이 있음"
[ "$(grep -c '^full-test$' "$MOCK_LOG")" = 1 ] && [ "$(grep -c '^unit-test$' "$MOCK_LOG")" = 1 ] || fail "P1: targeted test·최종 테스트가 1회씩이 아님: $(cat "$MOCK_LOG")"
pass "P1. R01 종단 — 검증자×2·워커·check-fix·리뷰어 R1·수정자·리뷰어 R2 가 전부 native 로 DONE, 결과 없는 재실행은 같은 요청(리뷰어 attempt 유지), CLI 0회"

# ---- P2·P3 공용: 리뷰어 Round 1 요청이 대기 중인 시점까지 다시 만든다(빠른 검사 없이) ----
to_reviewer_r1() {
  cd "$TMP/repo" || exit 1
  git checkout -q -- src
  rm -rf .agent-work/units .agent-work/implementation-context.json .agent-work/*.lock.json .agent-work/worker-baseline.tree .agent-work/worker-result.json .agent-work/review-impl.json \
    .agent-work/approved.fingerprint .agent-work/reviews/impl-attempt-* .agent-work/reviews/invalid-review.json .agent-work/.session-* .agent-work/worker-session.json .agent-work/usage.jsonl \
    .agent-work/check-fix* .agent-work/fast-check .agent-work/doc-gap-resume.json .agent-work/notify-done.sent .agent-work/post-run-report.json .agent-work/state.json "$ND"
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
  : > "$MOCK_LOG"; : > "$CLI_LOG"
  run; expect_req WORKER "01-core|worker" NEW "$1/워커"
  SIM_SIDE='echo "worker line" >> src/a.txt' sim_agent "$DONE_JSON" || fail "$1: 워커 dispatch 실패"; worker_agent="$SIM_LAST_AGENT"
  run; expect_req REVIEWER "|impl-review-a01-round-01" NEW "$1/리뷰어 R1"
}

# ================= P2. R20 리뷰어 출력 계약 위반 =================
to_reviewer_r1 P2
sim_agent "{\"schema_version\":$RV,\"verdict\":\"APPROVE\",\"issues\":[{\"id\":\"R-01\"}]}" || fail "P2: dispatch 실패"
run; [ "$RC" = 2 ] && [ "$(reason)" = REVIEW_OUTPUT_INVALID ] || fail "P2: 무효 출력이 REVIEW_OUTPUT_INVALID 가 아님 (rc $RC, $(reason))"
jq -e '.active==true and (.errors|length)>0' .agent-work/reviews/invalid-review.json >/dev/null || fail "P2: invalid-review.json 진단이 없음"
[ ! -e .agent-work/approved.fingerprint ] && [ ! -e .agent-work/.session-reviewer-a01.native.json ] || fail "P2: 무효 출력이 승인되거나 세션이 확정됨"
n="$(req_count)"
run; [ "$RC" = 2 ] && [ "$(reason)" = REVIEW_OUTPUT_INVALID ] && [ "$(req_count)" = "$n" ] && [ ! -e "$ND/pending.json" ] \
  || fail "P2: 재실행이 리뷰어를 다시 부르거나 다른 사유로 끝남 (rc $RC, $(reason), 요청 $n→$(req_count)개)"
pass "P2. R20 — native 리뷰어의 계약 위반 출력 → REVIEW_OUTPUT_INVALID, 재실행은 새 요청 0개로 같은 진단"

# ================= P4. 수정자 실행 중 계약 입력·decisions.md 변경 =================
# 수정자 프롬프트는 문서·리뷰 JSON 을 경로로만 가리킨다 — 재실행 pass 의 프롬프트 해시는 내용 변경을 못 본다. 요청에 저장한 불변 입력 지문으로 대조한다.
to_fixer() { # name
  to_reviewer_r1 "$1"
  sim_agent "$(issue FIX_CODE CONTRACT_VIOLATION "" "[]")" || fail "$1: 리뷰어 R1 dispatch 실패"
  run; expect_req FIXER "|impl-fix-a01-round-01" NEW "$1/수정자"
  [ -n "$(req_get '.input_fingerprint')" ] || fail "$1: 수정자 요청에 입력 지문이 없음"
}
LOOP=".claude/skills/feature/scripts/impl-review-loop.sh"
fixer_stale() { # name expected-detail-regex [direct]
  # direct: 리뷰 루프 단독 실행(exit 43). 계약 문서가 바뀌면 feature-run 은 리뷰 단계에 닿기 전에 impl 합의 PASS 무효 → NATIVE_PENDING_MISMATCH 로 먼저 멈추므로,
  #         수정자 호출 지점의 입력 지문 대조는 루프를 직접 불러 본다(러너 경로의 선행 차단은 아래에서 따로 확인).
  local id n rc_want=2; id="$(req_get '.request_id')"; n="$(req_count)"
  if [ "${3:-}" = direct ]; then rc_want=43; RC=0; bash "$LOOP" > "$TMP/run.log" 2>&1 || RC=$?; else run; fi
  [ "$RC" = "$rc_want" ] && grep -q 'NATIVE_RESULT_REJECTED(NATIVE_STALE_REQUEST)' "$TMP/run.log" \
    || fail "$1: 수정자 결과가 NATIVE_STALE_REQUEST 로 불수용되지 않음 (rc $RC)"
  [ -z "$2" ] || grep -qE "$2" "$TMP/run.log" || fail "$1: 불수용 사유에 '$2' 가 없음"
  [ ! -e .agent-work/.session-fixer-a01.native.json ] && [ "$(jq -r '.next_step' .agent-work/review-impl.json)" = FIXER_PENDING ] && [ ! -s "$CLI_LOG" ] \
    || fail "$1: 불수용인데 수정자 세션 확정·다음 라운드 전환·CLI 호출이 생김"
  grep -q 'fixed by fixer' src/a.txt || fail "$1: 수정자 변경이 자동 원복됨"
  # 재실행: 모델 0회로 같은 요청·같은 사유(문서가 바뀐 direct 사례는 러너의 다른 선행 게이트가 먼저 멈출 수 있어 루프 단독으로 다시 본다)
  if [ "${3:-}" = direct ]; then RC=0; bash "$LOOP" > "$TMP/run.log" 2>&1 || RC=$?; else run; fi
  [ "$RC" = "$rc_want" ] && grep -q 'NATIVE_RESULT_REJECTED(NATIVE_STALE_REQUEST)' "$TMP/run.log" && [ "$(req_get '.request_id')" = "$id" ] && [ "$(req_get '.state')" = REJECTED ] && [ "$(req_count)" = "$n" ] \
    || fail "$1: 불수용 뒤 재실행이 새 요청을 만들거나 다른 결과 (rc $RC, 요청 $n→$(req_count)개)"
}
FIX_SIDE='echo "fixed by fixer" >> src/a.txt; echo "- [fix round 1] R-01 ACCEPT: src/a.txt:L3" >> .agent-work/decisions.md'
# 시드에는 [USER-QUESTION] 줄을 넣지 않는다 — 사용자 결정은 합의 PASS 지문의 입력이라 impl 합의부터 다시 돌게 된다.
printf -- '- [impl round 1] 기존 기록 → A\n- 기존 메모\n' > .agent-work/decisions.md
cp .agent-work/decisions.md "$TMP/decisions.seed"
# (a) 계약 문서 변경
for doc in approach.md design.md implementation.md request.md; do
  cp "$TMP/decisions.seed" .agent-work/decisions.md; cp ".agent-work/$doc" "$TMP/doc.bak"
  to_fixer "P4/$doc"
  SIM_SIDE="$FIX_SIDE" sim_agent "수정했다." || fail "P4/$doc: 수정자 dispatch 실패"
  printf '\n- 요청 뒤에 바뀐 계약 (%s)\n' "$doc" >> ".agent-work/$doc"
  fixer_stale "P4/$doc" "" direct
  cp "$TMP/doc.bak" ".agent-work/$doc"
done
# (b) 고칠 리뷰 JSON 변경
cp "$TMP/decisions.seed" .agent-work/decisions.md
to_fixer "P4/review"
SIM_SIDE="$FIX_SIDE" sim_agent "수정했다." || fail "P4/review: 수정자 dispatch 실패"
rv=.agent-work/reviews/impl-attempt-01/reviewer-round-01.json
jq '.issues[0].required_outcome="요청 뒤에 바뀐 요구"' "$rv" > "$TMP/rv.tmp" && cat "$TMP/rv.tmp" > "$rv"
fixer_stale "P4/review" ""
# (c) decisions.md 기존 줄 변경 / (d) 사용자 결정 줄 추가 / (e) 다른 라운드 기록 / (f) 개행 없는 마지막 줄에 이어 붙임
dec_case() { # name seed-printf-format side detail-regex [direct]
  printf -- "$2" > .agent-work/decisions.md
  to_fixer "$1"
  SIM_SIDE="$3" sim_agent "수정했다." || fail "$1: 수정자 dispatch 실패"
  fixer_stale "$1" "$4" "${5:-}"
}
SEED='- [impl round 1] 기존 기록 → A\n- 기존 메모\n'
dec_case "P4/기존 줄 변경" "$SEED" "$FIX_SIDE; sed -i.bak 's/→ A/→ B/' .agent-work/decisions.md; rm -f .agent-work/decisions.md.bak" '기존 내용'
dec_case "P4/기존 줄 삭제" "$SEED" "echo 'fixed by fixer' >> src/a.txt; echo '- [fix round 1] R-01 ACCEPT: src/a.txt:L3' > .agent-work/decisions.md" '기존 내용'
dec_case "P4/사용자 결정 추가" "$SEED" "$FIX_SIDE; echo '- [USER-QUESTION][scope=impl] 수정자가 지어낸 결정 → B' >> .agent-work/decisions.md" '사용자 결정 줄' direct   # 러너 경로에서는 사용자 결정 추가가 합의 PASS 지문을 먼저 깨뜨린다
dec_case "P4/다른 라운드 기록" "$SEED" "$FIX_SIDE; echo '- [fix round 2] R-01 ACCEPT: src/a.txt:L3' >> .agent-work/decisions.md" '이번 라운드'
dec_case "P4/개행 없는 줄 이어 붙임" '- [impl round 1] 기존 기록 → A' "echo 'fixed by fixer' >> src/a.txt; printf ' 그리고 B\n- [fix round 1] R-01 ACCEPT: src/a.txt:L3\n' >> .agent-work/decisions.md" '마지막 줄'
# (g) 정상: 기존 내용 유지 + 이번 라운드 ACCEPT·REJECT·DEFER + 형식 없는 보고 메모 → 수용, 다음 라운드 리뷰어로
cp "$TMP/decisions.seed" .agent-work/decisions.md
to_fixer "P4/정상"
SIM_SIDE="$FIX_SIDE; printf -- '- [fix round 1] R-02 REJECT: approach.md:L1 — 문서에 없는 계약\n- [fix round 01] R-03 DEFER: 범위 밖 변경은 자동 원복 금지\n\n- 테스트 실행 방법을 몰라 실행하지 않음\n' >> .agent-work/decisions.md" sim_agent "수정했다." || fail "P4/정상: 수정자 dispatch 실패"
run; expect_req REVIEWER "|impl-review-a01-round-02" RESUME "P4/정상 → 리뷰어 R2"
[ -f .agent-work/.session-fixer-a01.native.json ] || fail "P4/정상: 수정자 세션이 확정되지 않음"
[ "$(head -c "$(wc -c < "$TMP/decisions.seed" | tr -d ' ')" .agent-work/decisions.md)" = "$(cat "$TMP/decisions.seed")" ] || fail "P4/정상: 기존 decisions 내용이 달라짐"
# (h) 정상: 빈 decisions.md 에서 시작(빈 prefix)
: > .agent-work/decisions.md
to_fixer "P4/빈 decisions"
SIM_SIDE="$FIX_SIDE" sim_agent "수정했다." || fail "P4/빈 decisions: 수정자 dispatch 실패"
run; expect_req REVIEWER "|impl-review-a01-round-02" RESUME "P4/빈 decisions → 리뷰어 R2"
: > .agent-work/decisions.md
pass "P4. 수정자 실행 중 계약 문서·리뷰 JSON 변경, decisions.md 기존 내용 변경·사용자 결정 추가·다른 라운드 기록 → NATIVE_STALE_REQUEST(자동 원복·재호출·세션 확정 없음), 정상 ACCEPT/REJECT/DEFER·메모 추가는 수용"

# ================= P3. R22 리뷰어 DOC_GAP → 사용자 결정 → review-gap 워커 =================
to_reviewer_r1 P3
sim_agent "$(issue DOC_GAP UNDECIDED_APPROACH "Map 과 선형 탐색 중 무엇인가" '["Map","선형 탐색"]')" || fail "P3: dispatch 실패"
run; [ "$RC" = 2 ] && [ "$(reason)" = REVIEW_DOC_GAP ] || fail "P3: DOC_GAP 이 REVIEW_DOC_GAP 이 아님 (rc $RC, $(reason))"
tag="$(jq -r '.gaps[0].tag' .agent-work/doc-gap-resume.json)"
n="$(req_count)"
run; [ "$RC" = 2 ] && [ "$(req_count)" = "$n" ] || fail "P3: 답 없는 재실행이 모델을 부름 (rc $RC, 요청 $n→$(req_count)개)"
printf -- '- [USER-QUESTION][scope=impl][%s] Map 과 선형 탐색 중 무엇인가 → Map\n' "$tag" >> .agent-work/decisions.md
printf '\n## 결정 R-01 (REQUIRED)\nMap 을 쓴다.\n' >> .agent-work/approach.md
run; expect_req WORKER "review-gap|review-gap" RESUME "P3/review-gap 워커"
[ "$(req_get '.resume_agent_id')" = "$worker_agent" ] || fail "P3: review-gap 워커가 같은 워커 Agent 재개가 아님"
grep -q 'REVIEW GAP CONTEXT\|사용자 결정' "$(req_get '.prompt_path')" || fail "P3: review-gap payload 에 사용자 결정 문맥이 없음"
idle_rerun "P3/review-gap 워커"
SIM_SIDE='echo "gap decision applied" >> src/a.txt' sim_agent "$DONE_JSON" || fail "P3: review-gap dispatch 실패"
run; expect_req REVIEWER "|impl-review-a02-round-01" NEW "P3/새 리뷰 시도"
[ "$(jq -r '.next_step' .agent-work/doc-gap-resume.json)" = REVIEW_PENDING ] && [ -f .agent-work/review-gap-result.json ] || fail "P3: review-gap 워커 완료가 기록되지 않음"
sim_agent "$APPROVE_JSON" || fail "P3: 리뷰어 dispatch 실패"
run; [ "$RC" = 0 ] && [ "$(status)" = DONE ] || fail "P3: DONE 이 아님 (rc $RC, $(status) / $(reason))"
[ ! -s "$CLI_LOG" ] || fail "P3: claude/codex CLI 가 불림: $(cat "$CLI_LOG")"
[ "$(jq -sr '[.[] | select(.role=="VALIDATOR" or .role=="DESIGNER")] | length' .agent-work/usage.jsonl)" = 0 ] || fail "P3: DOC_GAP 해결에 검증자·디자이너가 다시 불림"
pass "P3. R22 — native 리뷰어 DOC_GAP → 사용자 결정 → review-gap 워커(같은 Agent 재개, unit 밖 호출 지점) → 새 리뷰 시도 APPROVE → DONE, 검증자·디자이너 0회"

echo "[SMOKE OK] native pipeline"
