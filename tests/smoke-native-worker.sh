#!/usr/bin/env bash
# =============================================================
# native Agent 워커 스모크 (모델 호출 0회 — 실제 feature-run.sh + 훅 입력·Agent 전사 fixture + mock codex)
# WORKER 만 claude 모델(CLAUDE_BACKEND=native)로 두고 나머지 역할은 codex mock 으로 고정한다. "메인 세션 + Claude Code" 는 sim_agent 가 흉내 낸다
# (tests/smoke-native-bridge.sh 와 같은 방식 — 전사·훅 페이로드 모양은 Claude Code 2.1.330 실모델 POC 에서 관측한 것).
#
# 사례
#   A. R16 + verify worker-fix : unit 01→02→03 을 exit 42 를 거쳐 진행 — 01 은 NEW Agent, 02·03 은 같은 agent id 의 RESUME(SendMessage).
#        결과 없는 재실행은 같은 요청 재제시(테스트·검사 재실행 없음). 최종 TEST_CMD 1회 실패 → verify worker-fix 요청(unit 밖 호출 지점) → 수용 → 재리뷰 → DONE.
#        워커에 claude -p / codex CLI 0회.
#   B. 범위 위반 : native 워커가 feature-scope 밖 파일을 바꿈 → SCOPE_VIOLATION (호출 전 tree 는 요청에 저장된 값 — 재실행 pass 가 덮어쓰지 않는다), 자동 원복 없음.
#   C. R15 : 코드를 바꾸고 쓸 수 있는 결과 없이 끝남 → WORKER_OUTCOME_UNCERTAIN, 가드 기록, 재실행도 새 요청 0개로 같은 사유.
#   D. test-fix : targeted test 실패 → test-fix-01 요청(같은 Agent 재개) → 결과 없는 재실행이 테스트를 다시 돌리지 않음 → 수용 뒤 재검증.
#   E. R18 : 세대 교체 — 유효한 worker-handoff.json 뒤에는 NEW Agent 요청, 재실행 pass 가 handoff 의 source tree 대조에 걸리지 않음. handoff 변조 → WORKER_SESSION_MISMATCH(새 Agent 없음).
#   F. R17 : 원장이 다른 메인 세션에 결속 → WORKER_SESSION_MISMATCH, 요청 미발행.
#   G. R27 : backend 필드 없는(= claude -p 로 시작한) 저널 → WORKER_SESSION_MISMATCH, 묵시적 마이그레이션 없음.
#   H. 워커 실행 중 계약 문서(approach.md·decisions.md·design.md) 변경 → NATIVE_STALE_REQUEST(입력 지문 대조 — 재실행 pass 는 프롬프트를 다시 조립하지 않는다).
#   I. 워커 요청 대기 중 WORKER_MODEL 을 codex 모델로 변경 → NATIVE_PENDING_BACKEND_CHANGED, CLI 0회, 설정 원복 시 같은 요청 수용.
# check-fix·review-gap 호출 지점의 native 재실행 pass 는 tests/smoke-native-pipeline.sh 가 실행한다.
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-native-worker-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks" "$TMP/transcripts" "$TMP/state"
fail() { echo "[SMOKE FAIL] $*" >&2; [ ! -f "$TMP/run.log" ] || tail -25 "$TMP/run.log" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }
trap 'rm -rf "$TMP"' EXIT
unset CLAUDE_CODE_SUBAGENT_MODEL_FORCE CLAUDE_CODE_EFFORT_LEVEL NTFY_TOPIC WORKER_SESSION_ROTATE_INPUT_TOKENS
export CLAUDE_CODE_SESSION_ID="sess-main" FEATURE_LIVE_TEE=1

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
cp "$PROJECT_SRC/.claude/hooks/feature_native_agent.sh" "$TMP/repo/.claude/hooks/" || fail "훅 복사 실패"
HOOK="$TMP/repo/.claude/hooks/feature_native_agent.sh"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
export CLI_LOG="$TMP/cli.log" MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/state"; : > "$CLI_LOG"; : > "$MOCK_LOG"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_CONTRACT="$CONTRACT" MOCK_REVIEW_CONTRACT="$REVIEW_CONTRACT"
# claude CLI 는 어떤 경우에도 불리면 안 된다. codex mock 은 스키마로 역할을 판별한다(검증자 PASS / 리뷰어 APPROVE) — 워커 스키마로 불리면 실패.
cat > "$TMP/bin/claude" <<'EOS'
#!/usr/bin/env bash
echo "claude $*" >> "$CLI_LOG"; exit 9
EOS
cat > "$TMP/bin/codex" <<'EOS'
#!/usr/bin/env bash
out=""; schema=""; help=0
while [ "$#" -gt 0 ]; do case "$1" in
  --help) help=1; shift;; -o) out="$2"; shift 2;; --output-schema) schema="$(cat "$2")"; shift 2;; *) shift;;
esac; done
[ "$help" = 0 ] || { echo "usage: codex exec resume [--json] [--output-schema] [--output-last-message] [--sandbox]"; exit 0; }
printf '{"type":"thread.started","thread_id":"mock-thread-%s"}\n' "$$"
case "$schema" in
  *'"blocking_issues"'*) echo "codex validator" >> "$CLI_LOG"; printf '{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}\n' "$MOCK_CONTRACT" > "$out";;
  *'"context_updates"'*) echo "codex WORKER" >> "$CLI_LOG"; exit 9;;
  *'"issues"'*) echo "codex reviewer" >> "$CLI_LOG"; printf '{"schema_version":%s,"verdict":"APPROVE","issues":[]}\n' "$MOCK_REVIEW_CONTRACT" > "$out";;
  *) echo "codex other" >> "$CLI_LOG";;
esac
printf '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1}}\n'
EOS
cat > "$TMP/bin/full-test" <<'EOS'
#!/usr/bin/env bash
echo full-test >> "$MOCK_LOG"
[ ! -f "$MOCK_STATE/fail-full" ] || { rm -f "$MOCK_STATE/fail-full"; echo "full test failed"; exit 1; }
EOS
chmod +x "$TMP/bin/claude" "$TMP/bin/codex" "$TMP/bin/full-test"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"$TMP/bin/full-test\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"true\"|; \
  s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"native\"|; s|^WORKER_MODEL=.*|WORKER_MODEL=\"claude-opus-5-5\"|; s|^DESIGN_REVISION_MODEL=.*|DESIGN_REVISION_MODEL=\"gpt-6-sol\"|; \
  s|^VALIDATOR_MODEL=.*|VALIDATOR_MODEL=\"gpt-6.2-astra\"|; s|^REVIEWER_MODEL=.*|REVIEWER_MODEL=\"gpt-5.6-sol\"|; s|^FIXER_MODEL=.*|FIXER_MODEL=\"gpt-5.6-sol\"|" "$CFG" && rm -f "$CFG.bak"

cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && for u in 01 02 03; do echo "base $u" > "src/u$u.txt"; done; echo "outside base" > src/outside.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
printf '\n## 01\nunit 01 contract\n\n## 02\nunit 02 contract\n\n## 03\nunit 03 contract\n' >> .agent-work/implementation.md
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/u01.txt","src/u02.txt","src/u03.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
for u in 01 02 03; do
  printf '%s\n' '#!/usr/bin/env bash' "echo test-$u >> \"$MOCK_LOG\"" "[ ! -f \"$MOCK_STATE/fail-test-$u\" ] || { rm -f \"$MOCK_STATE/fail-test-$u\"; echo \"unit $u test failed\"; exit 1; }" > "$TMP/bin/test-$u"
  chmod +x "$TMP/bin/test-$u"
done
cat > .agent-work/implementation-units.json <<EOF
{"version":1,"units":[
 {"id":"01-intake","title":"접수","goal":"unit 01","requirements":["REQ-01"],"scope":{"files":["src/u01.txt"],"new_file_roots":[]},"references":["implementation.md#01"],"targeted_test":"$TMP/bin/test-01"},
 {"id":"02-drop","title":"Drop","goal":"unit 02","requirements":["REQ-02"],"scope":{"files":["src/u02.txt"],"new_file_roots":[]},"references":["implementation.md#02"],"targeted_test":"$TMP/bin/test-02"},
 {"id":"03-reassign","title":"재배정","goal":"unit 03","requirements":["REQ-03"],"scope":{"files":["src/u03.txt"],"new_file_roots":[]},"references":["implementation.md#03"],"targeted_test":"$TMP/bin/test-03"}
]}
EOF
for t in design impl; do
  bash .claude/skills/feature/scripts/consensus-loop.sh "$t" > "$TMP/consensus-$t.log" 2>&1 || { cat "$TMP/consensus-$t.log"; fail "픽스처: $t 합의 PASS 체크포인트 생성 실패"; }
done
: > "$CLI_LOG"

RUN=".claude/skills/feature/scripts/feature-run.sh"
ND="$TMP/repo/.agent-work/native-agent"
DONE_JSON='{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}'
RC=0
run() { RC=0; bash "$RUN" > "$TMP/run.log" 2>&1 || RC=$?; }
reason() { jq -r '.reason' .agent-work/run-state.json; }
status() { jq -r '.status' .agent-work/run-state.json; }
req_file() { jq -r '.request_path' "$ND/pending.json"; }
req_get() { jq -r "$1" "$(req_file)"; }
req_count() { ls "$ND/requests"/*.json 2>/dev/null | wc -l | tr -d ' '; }
discard() { bash .claude/skills/feature/scripts/native-agent-bridge.sh discard "$(req_get '.request_id')" > "$TMP/discard.log" 2>&1 || { cat "$TMP/discard.log"; fail "discard 실패"; }; }
reset_tree() { # 테스트 환경 정리 — 파이프라인 동작 아님
  git checkout -q -- src
  rm -rf .agent-work/units .agent-work/implementation-context.json .agent-work/implementation-units.lock.json .agent-work/feature-scope.lock.json .agent-work/worker-baseline.tree \
    .agent-work/worker-result.json .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/reviews/impl-attempt-* .agent-work/.session-* \
    .agent-work/worker-session.json .agent-work/worker-handoff.json .agent-work/usage.jsonl .agent-work/worker-outcome.guard.json .agent-work/worker-*.tree "$ND" "$MOCK_STATE"/fail-*
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
  : > "$MOCK_LOG"; : > "$CLI_LOG"
}

# ---- 메인 세션 + Claude Code 흉내 (smoke-native-bridge.sh 와 같은 모양) ----
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
    jq -nc --arg a "$aid" --arg m "$model" --arg e "$effort" \
      '{type:"assistant", agentId:$a, sessionId:"sess-main", requestedModel:$m, effort:$e, message:{id:("m1-" + ($a)), model:$m, stop_reason:"tool_use", usage:{input_tokens:10, cache_read_input_tokens:1000, cache_creation_input_tokens:100, output_tokens:50}, content:[{type:"tool_use", name:"Edit", input:{}}]}}'
    jq -nc --arg a "$aid" --arg m "$model" --arg e "$effort" --arg r "$report" \
      '{type:"assistant", agentId:$a, sessionId:"sess-main", requestedModel:$m, effort:$e, message:{id:("m2-" + ($a)), model:$m, stop_reason:"tool_use", usage:{input_tokens:5, cache_read_input_tokens:2000, cache_creation_input_tokens:0, output_tokens:70}, content:[{type:"tool_use", name:"SubagentHandback", input:{message:$r}}]}}'
  } >> "$tr"
  jq -n --arg a "$aid" --arg t "$(jq -r '.agent_definition' "$req")" --arg tp "$tr" \
    '{hook_event_name:"SubagentStop", session_id:"sess-main", agent_id:$a, agent_type:$t, agent_transcript_path:$tp, stop_hook_active:false}' | "$HOOK"
  [ "$(jq -r '.state' "$req")" = RESULT_READY ] || { echo "sim: 캡처되지 않음(state $(jq -r '.state' "$req"))" >&2; return 1; }
}
expect_req() { # scope tag intent  — 방금 러너가 exit 42 로 낸 요청
  [ "$RC" = 42 ] || fail "$4: exit 42 가 아님 (rc $RC, status $(status) / $(reason))"
  [ "$(status)" = NATIVE_AGENT_REQUIRED ] || fail "$4: run-state status 가 NATIVE_AGENT_REQUIRED 가 아님: $(status)"
  [ "$(req_get '.slot')" = "WORKER|$1|$2" ] || fail "$4: 요청의 호출 지점이 다름: $(req_get '.slot') (기대 WORKER|$1|$2)"
  [ "$(req_get '.session_intent')" = "$3" ] || fail "$4: session_intent 가 $3 가 아님: $(req_get '.session_intent')"
}

# ================= A. R16 unit 1→2→3 + verify worker-fix =================
reset_tree; touch "$MOCK_STATE/fail-full"
run; expect_req 01-intake worker NEW "A/unit01"
[ -f .claude/agents/feature-worker.md ] && grep -q '^model: claude-opus-5-5$' .claude/agents/feature-worker.md || fail "A: feature-worker 정의가 WORKER_MODEL 로 생성되지 않음"
grep -q 'REQ-01' "$(req_get '.prompt_path')" && grep -q '"context_updates"' "$(req_get '.prompt_path')" && grep -q 'core rules\|CORE RULES' "$(req_get '.prompt_path')" \
  || fail "A: payload 에 unit 계약·워커 규칙·결과 스키마가 없음"
id1="$(req_get '.request_id')"
run; expect_req 01-intake worker NEW "A/unit01 재실행"
[ "$(req_get '.request_id')" = "$id1" ] && [ "$(req_count)" = 1 ] && [ ! -s "$MOCK_LOG" ] || fail "A: 결과 없는 재실행이 새 요청을 만들거나 테스트를 돌림 (요청 $(req_count)개, calls: $(cat "$MOCK_LOG"))"
SIM_SIDE='echo "worker 01" >> src/u01.txt' sim_agent "$DONE_JSON" || fail "A: unit01 dispatch 실패"
agent1="$SIM_LAST_AGENT"; [ "$SIM_LAST_TOOL" = Agent ] || fail "A: unit01 이 Agent 호출이 아님"
run; expect_req 02-drop worker RESUME "A/unit02"
[ "$(req_get '.resume_agent_id')" = "$agent1" ] || fail "A: unit02 가 같은 Agent 재개가 아님"
[ -f .agent-work/units/01-intake/done.json ] && [ "$(grep -c '^test-01$' "$MOCK_LOG")" = 1 ] || fail "A: unit01 완료·targeted test 1회가 아님"
jq -e --arg a "$agent1" '.backend=="claude_native" and .session_bound==true' .agent-work/worker-session.json >/dev/null \
  && [ "$(jq -r '.agent_id' .agent-work/.session-feature-worker.native.json)" = "$agent1" ] || fail "A: 저널(backend·결속)·native 원장이 맞지 않음"
SIM_SIDE='echo "worker 02" >> src/u02.txt' sim_agent "$DONE_JSON" || fail "A: unit02 dispatch 실패"
[ "$SIM_LAST_TOOL" = SendMessage ] && [ "$SIM_LAST_AGENT" = "$agent1" ] || fail "A: unit02 가 SendMessage 재개가 아님"
run; expect_req 03-reassign worker RESUME "A/unit03"
SIM_SIDE='echo "worker 03" >> src/u03.txt' sim_agent "$DONE_JSON" || fail "A: unit03 dispatch 실패"
# unit 03 수용 → review(codex APPROVE) → verify: TEST_CMD 1회 실패 → worker-fix 요청(unit 밖 호출 지점)
run; expect_req verify-fix worker RESUME "A/verify-fix"
[ "$(grep -c '^full-test$' "$MOCK_LOG")" = 1 ] && [ "$(jq -r '.test_retries' .agent-work/run-state.json)" = 1 ] || fail "A: verify 실패 1회·test_retries 1 이 아님"
[ "$(seq 1 3 | while read -r n; do :; done; grep -c '^test-0' "$MOCK_LOG")" = 3 ] || fail "A: targeted test 가 unit 당 1회가 아님: $(cat "$MOCK_LOG")"
idv="$(req_get '.request_id')"
run; expect_req verify-fix worker RESUME "A/verify-fix 재실행"
[ "$(req_get '.request_id')" = "$idv" ] && [ "$(grep -c '^full-test$' "$MOCK_LOG")" = 1 ] && [ "$(jq -r '.test_retries' .agent-work/run-state.json)" = 1 ] \
  || fail "A: 결과 없는 재실행이 TEST_CMD 를 다시 돌리거나 한도를 또 올림 (full-test $(grep -c '^full-test$' "$MOCK_LOG")회, test_retries $(jq -r '.test_retries' .agent-work/run-state.json))"
SIM_SIDE='echo "fix after verify" >> src/u03.txt' sim_agent "$DONE_JSON" || fail "A: verify-fix dispatch 실패"
run; [ "$RC" = 0 ] && [ "$(status)" = DONE ] || fail "A: verify worker-fix 수용 뒤 DONE 이 아님 (rc $RC, $(status) / $(reason))"
[ "$(grep -c '^full-test$' "$MOCK_LOG")" = 2 ] || fail "A: 최종 TEST_CMD 가 실패 1 + 통과 1 이 아님"
! grep -q '^claude\|codex WORKER' "$CLI_LOG" || fail "A(R01): 워커에 CLI 가 불림: $(cat "$CLI_LOG")"
[ "$(jq -sr '[.[] | select(.role=="WORKER")] | length' .agent-work/usage.jsonl)" = 4 ] \
  && [ "$(jq -sr '[.[] | select(.role=="WORKER") | .agent_id] | unique | length' .agent-work/usage.jsonl)" = 1 ] \
  && [ "$(jq -sr '[.[] | select(.role=="WORKER") | .cost_kind] | unique | join(",")' .agent-work/usage.jsonl)" = unknown ] \
  || fail "A: WORKER usage 4행·agent id 1개·비용 unknown 이 아님"
pass "A. R16 — unit 01(NEW)→02→03(같은 Agent 재개) + verify worker-fix 가 exit 42 를 거쳐 DONE, 결과 없는 재실행은 같은 요청 재제시, 워커 CLI 0회"

# ================= B. 범위 위반 =================
reset_tree
run; expect_req 01-intake worker NEW "B"
before="$(req_get '.pre_state.before_tree')"
SIM_SIDE='echo "worker 01" >> src/u01.txt; echo leak >> src/outside.txt' sim_agent "$DONE_JSON" || fail "B: dispatch 실패"
run; [ "$RC" = 2 ] && [ "$(reason)" = SCOPE_VIOLATION ] || fail "B: 범위 밖 변경이 SCOPE_VIOLATION 으로 멈추지 않음 (rc $RC, $(reason))"
[ "$(cat .agent-work/units/01-intake/worker-before.tree)" = "$before" ] || fail "B: 재실행 pass 가 호출 전 tree 기록을 덮어씀"
grep -q leak src/outside.txt || fail "B: 변경이 자동 원복됨"
pass "B. native 워커의 범위 밖 변경 → SCOPE_VIOLATION (호출 전 tree 는 요청에 저장된 값 그대로, 자동 원복 없음)"

# ================= C. R15 결과 없이 코드만 바꿈 =================
reset_tree
run; expect_req 01-intake worker NEW "C"
SIM_SIDE='echo "half done" >> src/u01.txt' sim_agent "작업을 일부 했다. JSON 은 없다." || fail "C: dispatch 실패"
run; [ "$RC" = 2 ] && [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] || fail "C: 결과 없는 변경이 WORKER_OUTCOME_UNCERTAIN 이 아님 (rc $RC, $(reason))"
jq -e '.active==true' .agent-work/worker-outcome.guard.json >/dev/null 2>&1 || fail "C: worker-outcome 가드가 기록되지 않음"
grep -q 'half done' src/u01.txt || fail "C: 변경이 자동 원복됨"
n="$(req_count)"
run; [ "$RC" = 2 ] && [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] && [ "$(req_count)" = "$n" ] && [ ! -e "$ND/pending.json" ] \
  || fail "C: 미복구 재실행이 새 요청을 만들거나 다른 사유로 끝남 (rc $RC, $(reason), 요청 $(req_count)개)"
[ ! -e .agent-work/.session-feature-worker.native.json ] || fail "C: 수용되지 않은 턴의 세션이 확정됨"
pass "C. R15 — 유효 결과 없이 코드 변경 → WORKER_OUTCOME_UNCERTAIN, 가드 기록, 자동 재호출·원복·세션 확정 없음"

# ================= D. test-fix 턴 =================
reset_tree; touch "$MOCK_STATE/fail-test-01"
run; expect_req 01-intake worker NEW "D"
SIM_SIDE='echo "worker 01" >> src/u01.txt' sim_agent "$DONE_JSON" || fail "D: dispatch 실패"
run; expect_req 01-intake test-fix-01 RESUME "D/test-fix"
[ "$(grep -c '^test-01$' "$MOCK_LOG")" = 1 ] || fail "D: targeted test 1회 실패 뒤가 아님"
run; expect_req 01-intake test-fix-01 RESUME "D/test-fix 재실행"
[ "$(grep -c '^test-01$' "$MOCK_LOG")" = 1 ] || fail "D: 결과 없는 재실행이 targeted test 를 다시 돌림"
SIM_SIDE='echo "fix 01" >> src/u01.txt' sim_agent "$DONE_JSON" || fail "D: test-fix dispatch 실패"
run; expect_req 02-drop worker RESUME "D/unit02"
[ "$(grep -c '^test-01$' "$MOCK_LOG")" = 2 ] && [ -f .agent-work/units/01-intake/done.json ] && [ -f .agent-work/units/01-intake/test-fix-01-result.json ] \
  || fail "D: 수정 턴 수용 뒤 재검증(총 2회)·unit 완료가 아님"
pass "D. test-fix — targeted test 실패 → test-fix-01 요청(같은 Agent 재개), 결과 없는 재실행은 테스트를 다시 돌리지 않음, 수용 뒤 재검증"

# ================= E. R18 세대 교체 =================
reset_tree
export WORKER_SESSION_ROTATE_INPUT_TOKENS=100   # sim 의 마지막 턴 컨텍스트(2005) ≥ 100 → unit 경계마다 교체
run; expect_req 01-intake worker NEW "E"
SIM_SIDE='echo "worker 01" >> src/u01.txt' sim_agent "$DONE_JSON" || fail "E: dispatch 실패"; agent_e1="$SIM_LAST_AGENT"
run; expect_req 02-drop worker NEW "E/unit02(새 세대)"
jq -e '.generation==2 and .next_unit=="02-drop"' .agent-work/worker-handoff.json >/dev/null && [ -f .agent-work/.session-feature-worker.native.json.gen1 ] \
  && [ "$(jq -r '.generation' .agent-work/worker-session.json)" = 2 ] || fail "E: handoff·은퇴한 원장(.gen1)·세대 2 가 아님"
SIM_SIDE='echo "worker 02" >> src/u02.txt' sim_agent "$DONE_JSON" || fail "E: 새 세대 dispatch 실패"
[ "$SIM_LAST_TOOL" = Agent ] && [ "$SIM_LAST_AGENT" != "$agent_e1" ] || fail "E: 새 세대가 새 Agent 가 아님"
run; [ "$RC" = 42 ] && [ -f .agent-work/units/02-drop/done.json ] || fail "E: 새 세대의 재실행 pass 가 handoff 의 source tree 대조 등에 걸림 (rc $RC, $(status) / $(reason))"
# handoff 변조: unit 03 의 (또 새 세대) 요청을 치우고 handoff 를 깨뜨린다 → 검증 없는 fresh Agent 금지
discard; n="$(req_count)"; echo '{}' > .agent-work/worker-handoff.json
run; [ "$RC" = 2 ] && [ "$(reason)" = WORKER_SESSION_MISMATCH ] && [ "$(req_count)" = "$n" ] && [ ! -e "$ND/pending.json" ] \
  || fail "E: 변조된 handoff 로 fresh Agent 요청이 나감 (rc $RC, $(reason), 요청 $(req_count)개)"
unset WORKER_SESSION_ROTATE_INPUT_TOKENS
pass "E. R18 — 유효한 handoff 뒤에만 새 Agent(재실행 pass 는 source tree 대조에 안 걸림), 변조된 handoff → WORKER_SESSION_MISMATCH"

# ================= F. R17 부모 세션 소실 =================
reset_tree
run; expect_req 01-intake worker NEW "F"
SIM_SIDE='echo "worker 01" >> src/u01.txt' sim_agent "$DONE_JSON" || fail "F: dispatch 실패"
run; expect_req 02-drop worker RESUME "F/unit02"
discard; n="$(req_count)"
RC=0; CLAUDE_CODE_SESSION_ID=sess-other bash "$RUN" > "$TMP/run.log" 2>&1 || RC=$?
[ "$RC" = 2 ] && [ "$(reason)" = WORKER_SESSION_MISMATCH ] && [ "$(req_count)" = "$n" ] && [ ! -e "$ND/pending.json" ] \
  || fail "F: 다른 메인 세션에서 요청이 발행됨 (rc $RC, $(reason))"
pass "F. R17 — 워커 Agent 가 다른 메인 세션에 결속 → WORKER_SESSION_MISMATCH, 묵시적 fresh Agent 없음"

# ================= G. R27 claude -p 저널의 묵시적 마이그레이션 금지 =================
reset_tree
run; expect_req 01-intake worker NEW "G"
discard; n="$(req_count)"
jq 'del(.backend)' .agent-work/worker-session.json > "$TMP/j.json" && cp "$TMP/j.json" .agent-work/worker-session.json   # backend 필드 없는 저널 = claude -p 로 시작한 피처
run; [ "$RC" = 2 ] && [ "$(reason)" = WORKER_SESSION_MISMATCH ] && [ "$(req_count)" = "$n" ] || fail "G: claude -p 저널이 native 로 묵시적 이관됨 (rc $RC, $(reason))"
grep -q 'backend claude_cli→claude_native' "$TMP/run.log" || fail "G: 중단 사유에 backend 불일치가 없음"
pass "G. R27 — claude -p 로 시작한 워커 저널 → native 로 자동 이관하지 않고 WORKER_SESSION_MISMATCH"

# ================= H. 워커 실행 중 계약 문서 변경 =================
# 재실행 pass 는 프롬프트를 다시 조립하지 않는다 — 요청 발행 때 저장한 불변 입력 지문(문서·결정·범위·unit 선언·워커 규칙)과 수용 직전 값을 대조한다.
for doc in approach.md decisions.md design.md; do
  reset_tree
  cp ".agent-work/$doc" "$TMP/doc.bak"
  run; expect_req 01-intake worker NEW "H/$doc"
  idh="$(req_get '.request_id')"
  [ -n "$(req_get '.input_fingerprint')" ] || fail "H: 워커 요청에 입력 지문이 없음"
  SIM_SIDE='echo "worker 01" >> src/u01.txt' sim_agent "$DONE_JSON" || fail "H/$doc: dispatch 실패"
  printf '\n- 요청 뒤에 바뀐 계약 (%s)\n' "$doc" >> ".agent-work/$doc"
  run; [ "$RC" = 2 ] && [ "$(reason)" = NATIVE_RESULT_REJECTED ] && grep -q 'NATIVE_STALE_REQUEST' "$TMP/run.log" \
    || fail "H/$doc: 워커 실행 중 바뀐 계약 문서의 결과가 수용됨 (rc $RC, $(status) / $(reason))"
  [ ! -e .agent-work/units/01-intake/done.json ] && [ ! -e .agent-work/.session-feature-worker.native.json ] && [ ! -s "$MOCK_LOG" ] && [ ! -s "$CLI_LOG" ] \
    || fail "H/$doc: 불수용인데 unit 완료·세션 확정·테스트·CLI 호출이 생김"
  grep -q 'worker 01' src/u01.txt || fail "H/$doc: 변경이 자동 원복됨"
  run; [ "$RC" = 2 ] && [ "$(req_get '.request_id')" = "$idh" ] && [ "$(req_count)" = 1 ] || fail "H/$doc: 불수용 뒤 재실행이 새 요청을 만듦 (rc $RC, 요청 $(req_count)개)"
  cp "$TMP/doc.bak" ".agent-work/$doc"
done
# 범위 안 소스 변경만 있는 정상 턴은 지문에 걸리지 않는다(A 가 확인). implementation-units.json 변경은 기존 UNITS_MANIFEST_CHANGED 게이트가 먼저 멈춘다.
pass "H. 워커 실행 중 approach.md·decisions.md·design.md 변경 → NATIVE_STALE_REQUEST 불수용(자동 원복·재호출·세션 확정 없음)"

# ================= I. 워커 요청 대기 중 backend 변경 =================
reset_tree
run; expect_req 01-intake worker NEW "I"
idi="$(req_get '.request_id')"; before="$(req_get '.pre_state.before_tree')"
SIM_SIDE='echo "worker 01" >> src/u01.txt' sim_agent "$DONE_JSON" || fail "I: dispatch 실패"
cp "$CFG" "$TMP/cfg.bak"
sed 's|^WORKER_MODEL=.*|WORKER_MODEL="gpt-6-luna"|' "$TMP/cfg.bak" > "$CFG"
run; [ "$RC" = 2 ] && [ "$(reason)" = NATIVE_RESULT_REJECTED ] && grep -q 'NATIVE_PENDING_BACKEND_CHANGED' "$TMP/run.log" \
  || fail "I: 워커 모델을 codex 로 바꾼 재실행이 남은 native 요청 위에서 진행함 (rc $RC, $(status) / $(reason))"
[ ! -s "$CLI_LOG" ] && [ "$(req_get '.request_id')" = "$idi" ] && [ "$(req_get '.state')" = RESULT_READY ] && [ "$(req_count)" = 1 ] \
  || fail "I: CLI 가 호출되거나 요청 state 가 바뀜 (cli: $(cat "$CLI_LOG"), state $(req_get '.state'))"
[ "$(cat .agent-work/units/01-intake/worker-before.tree)" = "$before" ] || fail "I: backend 변경 중단이 호출 전 tree 기록을 덮어씀"
cp "$TMP/cfg.bak" "$CFG"
run; expect_req 02-drop worker RESUME "I/설정 원복 뒤 unit02"
[ -f .agent-work/units/01-intake/done.json ] || fail "I: 설정 원복 뒤 같은 요청의 결과가 수용되지 않음"
pass "I. 워커 native 요청 대기 중 WORKER_MODEL 을 codex 로 변경 → CLI 0회로 중단(호출 전 기준 보존), 설정 원복 시 같은 요청 수용"

# ================= J. 다른 PreToolUse 훅이 워커 dispatch 를 거부 =================
# 이 스킬의 훅은 allow 했지만 다른 PreToolUse 훅이 같은 호출을 거부했다 — Agent 는 실행되지 않았다.
# 러너는 그 요청을 DISPATCHED 로 굳혀 영원히 기다리지 않고, 거부를 확인해 사용자에게 올린다. 재시도는 명시적 redispatch 뒤의 같은 요청이다(새 Agent·CLI 없음).
reset_tree; BR=".claude/skills/feature/scripts/native-agent-bridge.sh"
run; expect_req 01-intake worker NEW "J"
idj="$(req_get '.request_id')"; before="$(req_get '.pre_state.before_tree')"
SIM_DENY='PreToolUse:Agent hook error: Subagent policy: parent cannot spawn same tier' sim_agent "" || fail "J: dispatch 흉내 실패"
[ "$(req_get '.state')" = DISPATCHING ] || fail "J: 거부된 호출이 DISPATCHING 이 아님: $(req_get '.state')"
run; [ "$RC" = 2 ] && [ "$(reason)" = NATIVE_RESULT_REJECTED ] && grep -q 'NATIVE_DISPATCH_DENIED' "$TMP/run.log" && grep -q 'parent cannot spawn same tier' "$TMP/run.log" \
  || { tail -20 "$TMP/run.log"; fail "J: 거부된 워커 dispatch 가 NEED_USER(NATIVE_DISPATCH_DENIED)로 올라오지 않음 (rc $RC, $(status) / $(reason))"; }
[ ! -s "$CLI_LOG" ] && [ "$(req_get '.request_id')" = "$idj" ] && [ "$(req_get '.state')" = DISPATCHING ] && [ "$(req_count)" = 1 ] && [ ! -e .agent-work/units/01-intake/done.json ] \
  || fail "J: CLI 가 호출됐거나 요청이 바뀜 (cli: $(cat "$CLI_LOG"), state $(req_get '.state'), 요청 $(req_count)개)"
[ "$(cat .agent-work/units/01-intake/worker-before.tree)" = "$before" ] || fail "J: 거부 중단이 호출 전 tree 기록을 덮어씀"
run; [ "$RC" = 2 ] && [ "$(reason)" = NATIVE_RESULT_REJECTED ] && [ "$(req_count)" = 1 ] || fail "J: 거부 뒤 재실행이 같은 사유로 멈추지 않음 (rc $RC, $(reason))"
( bash "$BR" redispatch "$idj" ) > "$TMP/redispatch.log" 2>&1 || { cat "$TMP/redispatch.log"; fail "J: redispatch 실패"; }
run; expect_req 01-intake worker NEW "J/redispatch 뒤"
[ "$(req_get '.request_id')" = "$idj" ] && [ "$(req_get '.state')" = PREPARED ] && [ "$(req_count)" = 1 ] || fail "J: redispatch 뒤 같은 요청이 PREPARED 로 재제시되지 않음"
SIM_SIDE='echo "worker 01" >> src/u01.txt' sim_agent "$DONE_JSON" || fail "J: 재시도 dispatch 실패"; agentj="$SIM_LAST_AGENT"
run; expect_req 02-drop worker RESUME "J/unit02"
[ -f .agent-work/units/01-intake/done.json ] && [ "$(req_get '.resume_agent_id')" = "$agentj" ] || fail "J: 재시도한 요청의 결과가 수용되지 않았거나 unit02 가 같은 Agent 재개가 아님"
# 재개(SendMessage) dispatch 가 거부돼도 같은 Agent 의 재개로 남는다 — fresh Agent·새 요청으로 바뀌지 않는다
idj2="$(req_get '.request_id')"
SIM_DENY='PreToolUse:SendMessage hook error: blocked by another hook' sim_agent "" || fail "J: 재개 dispatch 흉내 실패"
run; [ "$RC" = 2 ] && [ "$(reason)" = NATIVE_RESULT_REJECTED ] && grep -q 'NATIVE_DISPATCH_DENIED' "$TMP/run.log" || fail "J: 거부된 재개 dispatch 가 NEED_USER 가 아님 (rc $RC, $(reason))"
( bash "$BR" redispatch "$idj2" ) > "$TMP/redispatch.log" 2>&1 || { cat "$TMP/redispatch.log"; fail "J: 재개 요청 redispatch 실패"; }
run; expect_req 02-drop worker RESUME "J/재개 redispatch 뒤"
[ "$(req_get '.request_id')" = "$idj2" ] && [ "$(req_get '.resume_agent_id')" = "$agentj" ] || fail "J: redispatch 뒤 재개 대상이 바뀜"
SIM_SIDE='echo "worker 02" >> src/u02.txt' sim_agent "$DONE_JSON" || fail "J: 재개 재시도 dispatch 실패"
run; [ "$RC" = 42 ] || fail "J: 재개 재시도 뒤 다음 요청이 발행되지 않음 (rc $RC, $(status) / $(reason))"
[ -f .agent-work/units/02-drop/done.json ] && [ ! -s "$CLI_LOG" ] || fail "J: unit02 가 완료되지 않았거나 CLI 가 호출됨"
pass "J. 다른 PreToolUse 훅이 워커 dispatch 를 거부 → NATIVE_DISPATCH_DENIED(NEED_USER, 요청·호출 전 기준 보존), 명시적 redispatch 뒤 같은 요청·같은 Agent 로 이어짐"

echo "[SMOKE OK] native worker — check-fix·review-gap 호출 지점은 tests/smoke-native-pipeline.sh"
