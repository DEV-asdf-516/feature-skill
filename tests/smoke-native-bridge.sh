#!/usr/bin/env bash
# =============================================================
# native Agent bridge 스모크 (모델 호출 0회 — 훅 입력·Agent 전사 fixture + mock CLI)
# 실제 Claude Code·Codex 는 부르지 않는다. "메인 세션 + Claude Code" 는 sim_agent 가 흉내 낸다:
#   pending.json 의 dispatch 한 줄 → PreToolUse 훅(검증·프롬프트 주입) → PostToolUse 훅(실행 확인) → [가짜 Agent 부작용] → 전사 fixture 작성 → SubagentStop 훅(캡처)
# PostToolUse 응답 모양(Agent: isAsync/status async_launched/agentId/resolvedModel, SendMessage 재개: success/resumedAgentId)과
# 다른 PreToolUse 훅이 거부한 호출의 메인 전사 레코드(tool_result is_error + toolDenialKind "permission-rule" + permissionDecision)도 2.1.330 실측 모양이다.
# 전사 fixture 의 레코드 모양(type/isMeta/message.model/effort/requestedModel/usage/stop_reason, SubagentHandback tool_use)과 SubagentStop 페이로드 필드는
# Claude Code 2.1.330 에서 실제로 관측한 것과 같다(2026-11-23). Agent/SendMessage 의 updatedInput 적용·SendMessage 재개의 훅 이벤트는 실모델 미검증이다.
#
# dispatch 상태 전이(D1~D6): 다른 훅의 거부 / PostToolUse 누락·중복·지연 / SubagentStop 선도착 / 실행 여부 불명 상태의 중복 dispatch 차단 / SendMessage 재개의 실행 확인
# GOAL R 시나리오 대응(이 파일이 실행하는 것): R01 R02 R03 R04 R05 R06 R07 R08 R09 R10 R11 R12 R13 R14 R17 R19 R23 R24(하위 루프 종료 코드) R25 R26 R27 R28
# 워커(R15 R16 R18 과 워커 쪽 R17·R27)는 tests/smoke-native-worker.sh 가 실제 feature-run.sh 로 실행한다. native 조건의 R20·R22 와 리뷰 루프 종단은 tests/smoke-native-pipeline.sh, R21 은 codex 경로(tests/smoke-codex-resume.sh)
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-native-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks" "$TMP/transcripts"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }
trap 'rm -rf "$TMP"' EXIT
unset CLAUDE_CODE_SUBAGENT_MODEL_FORCE CLAUDE_CODE_EFFORT_LEVEL NTFY_TOPIC
# 메인 Claude Code 프로세스 pid — 이 세션 안에서 돌리면 물려받는다. 남겨 두면 방금 만든 임시 agent 정의가 그 프로세스보다 새것이라 러너의 등록 증거 게이트(NATIVE_AGENT_RESTART_REQUIRED)가 멈춘다. 그 게이트는 tests/smoke-native-agent-definitions.sh 가 본다
unset CLAUDE_PID
export CLAUDE_CODE_SESSION_ID="sess-main"

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
cp "$PROJECT_SRC/.claude/hooks/feature_native_agent.sh" "$TMP/repo/.claude/hooks/" || fail "훅 복사 실패"
HOOK="$TMP/repo/.claude/hooks/feature_native_agent.sh"
# Claude Code 는 훅을 경로로 직접 실행한다(bash <file> 이 아니다) — 실행 비트가 없으면 훅이 조용히 돌지 않아 dispatch 검증·캡처가 통째로 빠진다(2026-11-23 실모델 POC 에서 관측).
[ -x "$PROJECT_SRC/.claude/hooks/feature_native_agent.sh" ] || fail "훅에 실행 비트가 없음: .claude/hooks/feature_native_agent.sh"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
LOADER="$TMP/repo/.claude/skills/feature/scripts/lib/bootstrap.sh"
RUNTIME_LIB="$TMP/repo/.claude/skills/feature/scripts/lib/runtime.sh"
# 어떤 CLI 도 불리면 안 되는 구간이 있으므로 두 CLI 모두 호출을 기록하는 mock 으로 둔다.
cat > "$TMP/bin/claude" <<'EOS'
#!/usr/bin/env bash
echo "claude $*" >> "$CLI_LOG"; exit 9
EOS
cat > "$TMP/bin/codex" <<'EOS'
#!/usr/bin/env bash
out=""; while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
echo "codex" >> "$CLI_LOG"
printf '{"type":"thread.started","thread_id":"mock-thread-%s"}\n' "$$"
[ -z "$out" ] || printf '{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}\n' "$MOCK_CONTRACT" > "$out"
EOS
chmod +x "$TMP/bin/claude" "$TMP/bin/codex"
export CLI_LOG="$TMP/cli.log"; : > "$CLI_LOG"
setcfg() { # sed-expr...  (config 사본 수정)
  local e; for e in "$@"; do sed -i.bak "$e" "$CFG" && rm -f "$CFG.bak" || fail "config 수정 실패: $e"; done
}
setcfg "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|" "s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|" 's|^TEST_CMD="CHANGE_ME"|TEST_CMD="true"|' 's|^LINT_CMD="CHANGE_ME"|LINT_CMD="true"|' \
  's|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND="native"|' 's|^DESIGN_REVISION_MODEL=.*|DESIGN_REVISION_MODEL="claude-fable-5-2"|' 's|^VALIDATOR_MODEL=.*|VALIDATOR_MODEL="claude-opus-5-5"|' \
  's|^WORKER_MODEL=.*|WORKER_MODEL="claude-opus-5-5"|' 's|^REVIEWER_MODEL=.*|REVIEWER_MODEL="claude-sonnet-5-5"|' 's|^FIXER_MODEL=.*|FIXER_MODEL="claude-sonnet-5-5"|' \
  's|^VALIDATOR_PROFILE=.*|VALIDATOR_PROFILE="none"|'
export MOCK_CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$RUNTIME_LIB" | cut -d= -f2 | cut -d' ' -f1)"

cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && echo "base" > src/u01.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
: > .agent-work/decisions.md
ND="$TMP/repo/.agent-work/native-agent"
SCHEMA=".claude/skills/feature/schemas/spec-review.schema.json"
PASS_JSON="{\"schema_version\":$MOCK_CONTRACT,\"verdict\":\"PASS\",\"blocking_issues\":[]}"
BLOCK_JSON="{\"schema_version\":$MOCK_CONTRACT,\"verdict\":\"BLOCK\",\"blocking_issues\":[{\"id\":\"B-01\",\"action\":\"REVISE_DOC\",\"category\":\"REQUIREMENT_CONTRADICTION\",\"change_relation\":\"INTRODUCED_BY_FEATURE\",\"evidence_type\":\"DIRECT_MISMATCH\",\"basis_refs\":[\"design.md:L1\"],\"conflict_refs\":[\"design.md:L1\"],\"code_refs\":[],\"reachable_scenario\":\"\",\"impact\":\"x\",\"why_blocks_now\":\"y\",\"minimum_contract_needed\":\"z\",\"user_question\":\"\",\"options\":[],\"origin\":\"ROUND_1\",\"previous_issue_id\":\"\",\"revision_ref\":\"\"}]}"

# 역할 호출을 서브셸에서: 종료 코드(0/1/42/43)를 그대로 본다.
RC=0
role_ro() { # ROLE key label out  [env 는 호출자가 앞에 붙인다]
  RC=0; ( set -e; source "$LOADER"; run_readonly_json_role "$1" "$2" "$3" "$SCHEMA" "$4" "smoke prompt for $3" "" ) > "$TMP/last.log" 2>&1 || RC=$?
}
role_accept() { ( set -e; source "$LOADER"; role_session_accept "$1" "$2" smoke ) >> "$TMP/last.log" 2>&1; }
req_file() { jq -r '.request_path' "$ND/pending.json"; }
req_get() { jq -r "$1" "$(req_file)"; }
req_count() { ls "$ND/requests"/*.json 2>/dev/null | wc -l | tr -d ' '; }
reset_native() { rm -rf "$ND" .agent-work/.session-* .agent-work/usage.jsonl; }

# ---- 메인 세션 + Claude Code 흉내 ----
# 환경: SIM_SESSION(메인 세션 id) SIM_MODEL SIM_EFFORT SIM_HANDBACK(1=보고를 SubagentHandback 으로) SIM_SIDE(Agent 부작용 명령) SIM_TAMPER(1=프롬프트 변조)
#       SIM_STOP(0=SubagentStop 미발생) SIM_AGENT_ID SIM_TOOL(강제 도구)
#       SIM_POST(기본 1=PostToolUse 를 dispatch 직후에 보낸다 / 0=누락 / late=SubagentStop 뒤에 / dup=직후에 두 번)
# 도구 호출마다 tool_use_id 가 다르다(SIM_TU) — 실제 Claude Code 와 같다. 메인 세션 전사는 MAIN_TR 이다(훅이 transcript_path 로 받는다).
SIM_OUT=""; SIM_LAST_AGENT=""; SIM_SEQ=0; SIM_TU=""; SIM_PRE_TOOL=""
MAIN_TR="$TMP/transcripts/main-sess-main.jsonl"; : > "$MAIN_TR"
sim_pre() { # → 훅 출력(JSON)을 SIM_OUT 에
  local req tool intent
  req="$(req_file)"; intent="$(jq -r '.session_intent' "$req")"
  tool="${SIM_TOOL:-$([ "$intent" = RESUME ] && echo SendMessage || echo Agent)}"
  SIM_SEQ=$((SIM_SEQ + 1)); SIM_TU="toolu_sim_$SIM_SEQ"; SIM_PRE_TOOL="$tool"
  if [ "$tool" = Agent ]; then
    SIM_OUT="$(jq -n --arg s "${SIM_SESSION:-sess-main}" --arg t "$(jq -r '.agent_definition' "$req")" --arg p "$(jq -r '.dispatch_line' "$req")" --arg tu "$SIM_TU" --arg tp "$MAIN_TR" ${SIM_EXTRA_INPUT:+--argjson x "$SIM_EXTRA_INPUT"} \
      '{hook_event_name:"PreToolUse", session_id:$s, transcript_path:$tp, tool_name:"Agent", tool_use_id:$tu, tool_input:({subagent_type:$t, description:"sim", prompt:$p} + ($ARGS.named.x // {}))}' | "$HOOK")"
  else
    SIM_OUT="$(jq -n --arg s "${SIM_SESSION:-sess-main}" --arg to "${SIM_TO:-$(jq -r '.resume_agent_id' "$req")}" --arg p "$(jq -r '.dispatch_line' "$req")" --arg tu "$SIM_TU" --arg tp "$MAIN_TR" \
      '{hook_event_name:"PreToolUse", session_id:$s, transcript_path:$tp, tool_name:"SendMessage", tool_use_id:$tu, tool_input:{to:$to, message:$p}}' | "$HOOK")"
  fi
}
# PostToolUse: 직전 sim_pre 의 호출이 실행에 성공했다(입력은 훅이 주입한 뒤의 것). 환경: SIM_POST_TU(다른 tool_use_id) SIM_POST_SESSION SIM_POST_RESPONSE(응답 JSON 통째로)
sim_post() { # agent-id [model]
  local resp input
  if [ "$SIM_PRE_TOOL" = Agent ]; then
    resp="$(jq -nc --arg a "$1" --arg m "${2:-}" '{isAsync:true, status:"async_launched", agentId:$a, description:"sim", resolvedModel:$m, canContinueAgent:true}')"
  else
    resp="$(jq -nc --arg a "$1" '{success:true, message:("Resuming agent " + $a), resumedAgentId:$a, revivedAgentId:$a}')"
  fi
  input="$(printf '%s' "$SIM_OUT" | jq -c '.hookSpecificOutput.updatedInput')"
  jq -n --arg s "${SIM_POST_SESSION:-${SIM_SESSION:-sess-main}}" --arg tool "$SIM_PRE_TOOL" --arg tu "${SIM_POST_TU:-$SIM_TU}" --arg tp "$MAIN_TR" --argjson i "$input" --argjson r "${SIM_POST_RESPONSE:-$resp}" \
    '{hook_event_name:"PostToolUse", session_id:$s, transcript_path:$tp, tool_name:$tool, tool_use_id:$tu, tool_input:$i, tool_response:$r}' | "$HOOK"
}
# 메인 전사에 그 tool_use_id 의 도구 결과를 남긴다. kind 가 있으면 '실행 전 거부'(다른 PreToolUse 훅 등), 없으면 성공 결과다.
sim_main_result() { # tool_use_id [toolDenialKind text]
  if [ -n "${2:-}" ]; then
    jq -nc --arg tu "$1" --arg k "$2" --arg t "$3" '{type:"user", sessionId:"sess-main", toolDenialKind:$k,
      permissionDecision:(if $k=="permission-rule" then {decision:"reject", source:"hook", reasonType:"hook", reasonCode:"hook:PreToolUse"} else null end),
      toolUseResult:("Error: " + $t), message:{role:"user", content:[{type:"tool_result", is_error:true, tool_use_id:$tu, content:$t}]}}' >> "$MAIN_TR"
  else
    jq -nc --arg tu "$1" '{type:"user", sessionId:"sess-main", toolUseResult:{status:"async_launched"}, message:{role:"user", content:[{type:"tool_result", tool_use_id:$tu, content:"launched"}]}}' >> "$MAIN_TR"
  fi
}
sim_agent() { # report-text
  local req report="$1" prompt aid tr model effort
  req="$(req_file)"
  sim_pre
  [ "$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = allow ] || { echo "sim: dispatch 거부됨: $SIM_OUT" >&2; return 1; }
  prompt="$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.updatedInput | (.prompt // .message)')"
  [ "${SIM_TAMPER:-0}" != 1 ] || prompt="$prompt
(메인이 덧붙인 한 줄)"
  aid="${SIM_AGENT_ID:-$(jq -r '.resume_agent_id // empty' "$req")}"; [ -n "$aid" ] || aid="agent$RANDOM$RANDOM"
  SIM_LAST_AGENT="$aid"; tr="$TMP/transcripts/agent-$aid.jsonl"
  model="${SIM_MODEL:-$(jq -r '.model' "$req")}"; effort="${SIM_EFFORT:-$(jq -r '.effort' "$req")}"
  case "${SIM_POST:-1}" in 1) sim_post "$aid" "$model";; dup) sim_post "$aid" "$model"; sim_post "$aid" "$model";; esac
  case "${SIM_POST:-1}" in 1|dup) [ "$(jq -r '.state' "$req")" = DISPATCHED ] || { echo "sim: PostToolUse 뒤 state 가 DISPATCHED 가 아님($(jq -r '.state' "$req"))" >&2; return 1; };; esac
  [ -z "${SIM_SIDE:-}" ] || ( eval "$SIM_SIDE" )
  [ "${SIM_STOP:-1}" = 1 ] || return 0
  # 재개(SendMessage)된 Agent 의 전사에는 메시지가 isMeta user 레코드로, 하네스의 고정 문구에 싸여 남는다(Claude Code 2.1.330 실모델 POC 에서 관측한 모양 그대로).
  local is_resume=0; [ "$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.updatedInput | has("message")')" != true ] || is_resume=1
  { if [ "$is_resume" = 1 ]; then
      jq -nc --arg p "$prompt" --arg a "$aid" --arg s "${SIM_SESSION:-sess-main}" \
        '{type:"user", isMeta:true, agentId:$a, sessionId:$s, isSidechain:true, message:{role:"user", content:("The coordinator sent a message while you were working:\n" + $p + "\n" + "\n\nAddress this before completing your current task.")}}'
    else
      jq -nc --arg p "$prompt" --arg a "$aid" --arg s "${SIM_SESSION:-sess-main}" '{type:"user", agentId:$a, sessionId:$s, isSidechain:true, message:{role:"user", content:$p}}'
    fi
    jq -nc --arg a "$aid" '{type:"user", isMeta:true, agentId:$a, message:{role:"user", content:"<meta reminder>"}}'
    jq -nc --arg a "$aid" --arg s "${SIM_SESSION:-sess-main}" --arg m "$model" --arg e "$effort" \
      '{type:"assistant", agentId:$a, sessionId:$s, requestedModel:$m, effort:$e, message:{id:"msg_1", model:$m, stop_reason:"tool_use", usage:{input_tokens:10, cache_read_input_tokens:1000, cache_creation_input_tokens:100, output_tokens:50}, content:[{type:"tool_use", name:"Read", input:{}}]}}'
    jq -nc --arg a "$aid" '{type:"user", agentId:$a, message:{role:"user", content:[{type:"tool_result", content:"file"}]}}'
    if [ "${SIM_HANDBACK:-0}" = 1 ]; then
      jq -nc --arg a "$aid" --arg s "${SIM_SESSION:-sess-main}" --arg m "$model" --arg e "$effort" --arg r "$report" \
        '{type:"assistant", agentId:$a, sessionId:$s, requestedModel:$m, effort:$e, message:{id:"msg_2", model:$m, stop_reason:"tool_use", usage:{input_tokens:5, cache_read_input_tokens:2000, cache_creation_input_tokens:0, output_tokens:70}, content:[{type:"tool_use", name:"SubagentHandback", input:{message:$r}}]}}'
    else
      jq -nc --arg a "$aid" --arg s "${SIM_SESSION:-sess-main}" --arg m "$model" --arg e "$effort" --arg r "$report" \
        '{type:"assistant", agentId:$a, sessionId:$s, requestedModel:$m, effort:$e, message:{id:"msg_2", model:$m, stop_reason:"end_turn", usage:{input_tokens:5, cache_read_input_tokens:2000, cache_creation_input_tokens:0, output_tokens:70}, content:[{type:"text", text:$r}]}}'
    fi
  } >> "$tr"
  sim_stop "$aid" "$(jq -r '.agent_definition' "$req")"
  [ "${SIM_POST:-1}" != late ] || sim_post "$aid" "$model"
}
sim_stop() { # agent-id agent-type
  jq -n --arg s "${SIM_SESSION:-sess-main}" --arg a "$1" --arg t "$2" --arg tp "$TMP/transcripts/agent-$1.jsonl" --arg lam "${SIM_CLOSING:-}" \
    '{hook_event_name:"SubagentStop", session_id:$s, agent_id:$a, agent_type:$t, agent_transcript_path:$tp, stop_hook_active:false} + (if $lam=="" then {} else {last_assistant_message:$lam} end)' | "$HOOK"
}

# ================= R04 지원하지 않는 모델 / 모델·CLI override 충돌 =================
r="$(bash -c 'source "$1"; REVIEWER_CLI=codex role_backend REVIEWER' _ "$LOADER" 2>&1)" && fail "R04: claude 모델 + REVIEWER_CLI=codex 가 통과함: $r"
printf '%s' "$r" | grep -q ROLE_CLI_CONFLICT || fail "R04: 충돌 오류 코드 없음: $r"
r="$(bash -c 'source "$1"; WORKER_MODEL=gpt-6-luna WORKER_CLI=claude role_backend WORKER' _ "$LOADER" 2>&1)" && fail "R04: gpt 모델 + WORKER_CLI=claude 가 통과함"
r="$(bash -c 'source "$1"; WORKER_MODEL=mystery-1 role_backend WORKER' _ "$LOADER" 2>&1)" && fail "R04: 이름으로 판정할 수 없는 모델이 통과함"
r="$(bash -c 'source "$1"; CLAUDE_BACKEND=sdk role_backend VALIDATOR' _ "$LOADER" 2>&1)" && fail "R04: 알 수 없는 CLAUDE_BACKEND 가 통과함"
[ ! -e "$ND/pending.json" ] && [ ! -s "$CLI_LOG" ] || fail "R04: 오류인데 요청·CLI 호출이 생김"
pass "R04. 모델·CLI override 충돌 / 미지원 모델 / 알 수 없는 backend → 명시적 오류, 호출 없음"

# ================= R01 R02 R03 모델 기준 라우팅 =================
r="$(bash -c 'source "$1"; for x in DESIGNER VALIDATOR WORKER REVIEWER FIXER; do printf "%s " "$(role_backend $x)"; done' _ "$LOADER")"
[ "$r" = "claude_native claude_native claude_native claude_native claude_native " ] || fail "R01: 다섯 역할이 모두 native 가 아님: $r"
r="$(bash -c 'source "$1"; DESIGN_REVISION_MODEL=gpt-6-sol VALIDATOR_MODEL=gpt-6.2-astra WORKER_MODEL=o4-mini REVIEWER_MODEL=codex-x FIXER_MODEL=gpt-5.6-sol; for x in DESIGNER VALIDATOR WORKER REVIEWER FIXER; do printf "%s " "$(role_backend $x)"; done' _ "$LOADER")"
[ "$r" = "codex_cli codex_cli codex_cli codex_cli codex_cli " ] || fail "R02: 다섯 역할이 모두 codex 가 아님: $r"
r="$(bash -c 'source "$1"; VALIDATOR_MODEL=gpt-6.2-astra REVIEWER_MODEL=gpt-5.6-sol; a="$(for x in DESIGNER VALIDATOR WORKER REVIEWER FIXER; do printf "%s " "$(role_backend $x)"; done)"; VALIDATOR_MODEL=claude-opus-5-5 WORKER_MODEL=gpt-6-luna; printf "%s| " "$a"; for x in DESIGNER VALIDATOR WORKER REVIEWER FIXER; do printf "%s " "$(role_backend $x)"; done' _ "$LOADER")"
[ "$r" = "claude_native codex_cli claude_native codex_cli claude_native | claude_native claude_native codex_cli codex_cli claude_native " ] || fail "R03: 교차 변경 라우팅 불일치: $r"
r="$(bash -c 'source "$1"; CLAUDE_BACKEND=legacy_cli; printf "%s %s" "$(role_backend VALIDATOR)" "$(REVIEWER_CLI=codex role_backend REVIEWER)"' _ "$LOADER")"
[ "$r" = "claude_cli codex_cli" ] || fail "R03: legacy_cli 가 종전 의미가 아님: $r"
# R02 실행 확인: codex 모델이면 native 요청 0개, codex CLI 1회
RC=0; ( set -e; source "$LOADER"; VALIDATOR_MODEL=gpt-6.2-astra; run_readonly_json_role VALIDATOR "validator-x-$RANDOM" "design-validator-round-01" "$SCHEMA" "$TMP/codex-out.json" "p" "" ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 0 ] && [ "$(grep -c '^codex' "$CLI_LOG")" = 1 ] && [ ! -e "$ND/pending.json" ] || { cat "$TMP/last.log"; fail "R02: codex 역할이 기존 CLI 경로로 가지 않음 (rc $RC)"; }
: > "$CLI_LOG"; rm -f .agent-work/usage.jsonl
pass "R01·R02·R03. 역할이 아니라 모델이 backend 를 정한다(native / codex CLI / 명시적 legacy_cli)"

# ================= R12 전역 effort·model override 사전 검사 =================
RC=0; ( set -e; source "$LOADER"; CLAUDE_CODE_EFFORT_LEVEL=low run_readonly_json_role VALIDATOR k "design-validator-round-01" "$SCHEMA" "$TMP/o.json" p "" ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 1 ] && grep -q NATIVE_EFFORT_OVERRIDE "$TMP/last.log" && [ ! -e "$ND/pending.json" ] || { cat "$TMP/last.log"; fail "R12: CLAUDE_CODE_EFFORT_LEVEL 불일치가 요청 전에 막히지 않음 (rc $RC)"; }
RC=0; ( set -e; source "$LOADER"; CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 run_readonly_json_role VALIDATOR k "design-validator-round-01" "$SCHEMA" "$TMP/o.json" p "" ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 1 ] && grep -q NATIVE_MODEL_OVERRIDE "$TMP/last.log" && [ ! -e "$ND/pending.json" ] || fail "R12: CLAUDE_CODE_SUBAGENT_MODEL_FORCE 가 요청 전에 막히지 않음"
pass "R12. 전역 model/effort override → 요청 발행 전 중단"

# ================= R05 요청 뒤 재실행, 결과 없음 =================
role_ro VALIDATOR "validator-design-01-aaa" "design-validator-round-01" "$TMP/v1.json"
[ "$RC" = 42 ] || { cat "$TMP/last.log"; fail "R05: 첫 호출이 exit 42 가 아님 (rc $RC)"; }
id1="$(req_get '.request_id')"; [ "$(req_get '.state')" = PREPARED ] || fail "R05: 요청 state 가 PREPARED 가 아님"
grep -q "FEATURE-NATIVE-DISPATCH $(req_file)" "$TMP/last.log" || fail "R05: dispatch 한 줄이 출력되지 않음"
[ -f ".claude/agents/feature-validator.md" ] && grep -q '^model: claude-opus-5-5$' .claude/agents/feature-validator.md && grep -q '^effort: medium$' .claude/agents/feature-validator.md \
  || fail "R05: agent 정의가 full model ID·effort 로 생성되지 않음"
head -1 "$(req_get '.prompt_path')" | grep -q "^FEATURE-NATIVE-REQUEST $(req_file)$" || fail "R05: payload 첫 줄이 요청 경로가 아님"
grep -q 'smoke prompt for design-validator-round-01' "$(req_get '.prompt_path')" && grep -q '"blocking_issues"' "$(req_get '.prompt_path')" || fail "R05: payload 에 역할 프롬프트·스키마 원문이 없음"
role_ro VALIDATOR "validator-design-01-bbb" "design-validator-round-01" "$TMP/v1.json"
[ "$RC" = 42 ] && [ "$(req_get '.request_id')" = "$id1" ] && [ "$(req_count)" = 1 ] || fail "R05: 재실행이 같은 pending 을 재제시하지 않음 (rc $RC, 요청 $(req_count)개)"
pass "R05. 결과 없는 재실행 → 같은 pending 재제시, 새 요청·새 Agent 없음"

# ================= R25 일반 Agent 호출에 간섭하지 않음 =================
out="$(jq -n '{hook_event_name:"PreToolUse", session_id:"s", tool_name:"Agent", tool_input:{subagent_type:"Explore", prompt:"find things"}}' | "$HOOK")"
[ -z "$out" ] || fail "R25: 일반 Agent 호출에 훅이 출력함: $out"
out="$(jq -n --arg tp "$TMP/transcripts/none.jsonl" '{hook_event_name:"SubagentStop", session_id:"s", agent_id:"x", agent_type:"Explore", agent_transcript_path:$tp}' | "$HOOK")"
[ -z "$out" ] && [ ! -d "$ND/results" -o -z "$(ls "$ND/results" 2>/dev/null)" ] || fail "R25: 일반 subagent 종료에 훅이 반응함"
out="$(jq -n '{hook_event_name:"PreToolUse", session_id:"s", tool_name:"Agent", tool_input:{subagent_type:"feature-worker", prompt:"그냥 구현해"}}' | "$HOOK")"
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] || fail "R25: 요청 없는 feature agent 직접 호출이 거부되지 않음"
[ "$(req_get '.state')" = PREPARED ] || fail "R25: 무관한 이벤트가 요청 상태를 바꿈"
pass "R25. 일반 Agent·subagent 이벤트는 무출력 통과, 요청 없는 feature agent 직접 호출만 거부"

# ================= dispatch 인자 검증 + R08 async_launched =================
SIM_EXTRA_INPUT='{"model":"opus"}' sim_pre
[ "$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] && [ "$(req_get '.state')" = PREPARED ] || fail "R08: model 별칭 override 가 거부되지 않음"
SIM_SESSION=sess-other sim_pre
[ "$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] || fail "R08: 다른 메인 세션의 선점이 거부되지 않음"
SIM_STOP=0 SIM_AGENT_ID=agentbg1 sim_agent "$PASS_JSON" || fail "R08: 정상 dispatch 가 거부됨"
[ "$(req_get '.state')" = DISPATCHED ] && [ "$(req_get '.post_tool.status')" = async_launched ] && [ "$(req_get '.post_tool.launch_confirmed')" = true ] \
  && [ "$(req_get '.dispatched_agent_id')" = agentbg1 ] && [ "$(req_get '.post_tool.tool_use_id')" = "$(req_get '.dispatch_attempt.tool_use_id')" ] \
  || fail "R08: async_launched 뒤 state 가 DISPATCHED 가 아니거나 tool_use_id·agent id 가 결속되지 않음: $(req_get '.state')"
role_ro VALIDATOR "validator-design-01-ccc" "design-validator-round-01" "$TMP/v1.json"
[ "$RC" = 42 ] && grep -q '실행이 확인됐고' "$TMP/last.log" && [ ! -e "$TMP/v1.json" ] || { cat "$TMP/last.log"; fail "R08: async_launched 를 완료로 처리함 (rc $RC)"; }
sim_pre
[ "$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] || fail "R06: 이미 dispatch 된 요청의 두 번째 호출이 거부되지 않음"
pass "R08. async_launched 는 완료가 아니다 — 대기 상태 재제시, 재dispatch 거부(model override·다른 세션 선점도 거부)"

# ================= R09 R06 R26 완료 원문 수용 =================
# 위에서 dispatch 된 Agent(agentbg1)가 이제 끝났다: 전사 작성 + SubagentStop
prompt="$(cat "$(req_get '.prompt_path')")"
{ jq -nc --arg p "$prompt" '{type:"user", agentId:"agentbg1", sessionId:"sess-main", message:{role:"user", content:$p}}'
  jq -nc --arg r "$PASS_JSON" '{type:"assistant", agentId:"agentbg1", sessionId:"sess-main", requestedModel:"claude-opus-5-5", effort:"medium", message:{id:"m1", model:"claude-opus-5-5", stop_reason:"end_turn", usage:{input_tokens:3, cache_read_input_tokens:500, cache_creation_input_tokens:20, output_tokens:40, cache_creation:{ephemeral_5m_input_tokens:12, ephemeral_1h_input_tokens:8}, speed:"standard", inference_geo:"global"}, content:[{type:"text", text:$r}]}}'
} > "$TMP/transcripts/agent-agentbg1.jsonl"
sim_stop agentbg1 feature-validator
[ "$(req_get '.state')" = RESULT_READY ] || fail "R09: SubagentStop 뒤 state 가 RESULT_READY 가 아님"
cap="$ND/results/$id1.capture.json"; sum1="$(shasum "$cap" | cut -d' ' -f1)"
sim_stop agentbg1 feature-validator   # 이중 훅
[ "$(shasum "$cap" | cut -d' ' -f1)" = "$sum1" ] || fail "R06: 중복 SubagentStop 이 캡처를 다시 씀"
role_ro VALIDATOR "validator-design-01-ddd" "design-validator-round-01" "$TMP/v1.json"
[ "$RC" = 0 ] && [ "$(jq -r '.verdict' "$TMP/v1.json")" = PASS ] || { cat "$TMP/last.log"; fail "R09: 캡처된 결과가 수용되지 않음 (rc $RC)"; }
[ ! -e "$ND/pending.json" ] && [ "$(jq -r '.state' "$ND/requests/$id1.json")" = CONSUMED ] || fail "R06: 수용 뒤 요청이 CONSUMED 가 아님"
sim_stop agentbg1 feature-validator   # 소비 뒤의 늦은 중복 이벤트
[ "$(jq -r '.state' "$ND/requests/$id1.json")" = CONSUMED ] || fail "R06: 소비된 요청의 상태가 다시 바뀜"
[ "$(wc -l < .agent-work/usage.jsonl | tr -d ' ')" = 1 ] || fail "R26: usage 행이 1개가 아님"
jq -e --arg id "$id1" '.backend=="claude_native" and .role=="VALIDATOR" and .model=="claude-opus-5-5" and .effort=="medium" and .request_id==$id and .agent_id=="agentbg1" and .cost_usd==null and .context_last_turn==523 and .output==40' .agent-work/usage.jsonl >/dev/null \
  || fail "R26: usage 행이 backend/role/model/effort/request/agent 를 담지 않거나 비용을 0 으로 위장함: $(cat .agent-work/usage.jsonl)"
# native subagent 는 비용을 보고하지 않는다 — 전사의 토큰을 Claude 가격표(API 표준 요금)로 환산한 추정치를 적는다(reported 아님).
#   claude-opus-5-5: 입력 3×$4 + 캐시 읽기 500×$0.20 + 캐시 쓰기 5분 12×$5 + 1시간 8×$8 + 출력 40×$20 = $1036 / 1M
jq -e '.cost_kind=="estimated" and ((.estimated_cost_usd - 0.001036) | fabs) < 1e-12 and .pricing_basis=="anthropic-api-standard-2026-11-24" and .usage_observation_status=="transcript"
  and .input_uncached==3 and .cache_read==500 and .cache_write==20 and (.pricing_assumptions|test("실제 청구액 아님"))' .agent-work/usage.jsonl >/dev/null \
  || fail "R26: native 호출의 비용 추정이 가격표 환산과 다름: $(cat .agent-work/usage.jsonl)"
# 전사에서 토큰을 읽은 호출은 '사용량 미관측'이 아니다. 보고 줄은 추정 비용에 포함하고 추정 불가 0건으로 적는다
r26_line="$( ( source "$LOADER"; usage_cost_report_line ) )"
case "$r26_line" in *"추정 비용(codex·claude native) \$0.001 (API 표준 요금 기준 환산, estimated)"*"추정 불가 0건(사용량 미관측 0건"*"claude_native=1건(reported \$0, estimated \$0.001, unknown 0)"*) ;;
  *) fail "R26: 비용 보고 줄이 native 추정 비용을 싣지 않거나 관측된 호출을 미관측으로 셈: $r26_line";; esac
# 환산할 수 없는 경우는 0 달러가 아니라 unknown: 캐시 쓰기의 TTL 구분 없음 · fast mode · US 전용 추론 · 가격표에 없는 모델(프롬프트 길이별 요금인 haiku 포함)
r26_est() { ( source "$LOADER"; claude_native_estimate_cost "$1" "$(claude_model_pricing claude-opus-5-5)" | jq -r '.estimated_cost_usd' ); }
[ "$(r26_est '{"input_tokens":3,"cache_read_input_tokens":500,"cache_creation_input_tokens":20,"output_tokens":40}')" = null ] || fail "R26: 캐시 쓰기 TTL 구분이 없는데 단가를 추측해 추정함"
[ "$(r26_est '{"input_tokens":3,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":40,"speeds":["fast"]}')" = null ] || fail "R26: fast mode 요청을 표준 요금으로 추정함"
[ "$(r26_est '{"input_tokens":3,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":40,"inference_geos":["us"]}')" = null ] || fail "R26: US 전용 추론 요청을 표준 요금으로 추정함"
[ "$(r26_est '{"input_tokens":1000000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0,"speeds":["standard"],"inference_geos":["global"]}')" = 4 ] || fail "R26: 입력 1M 토큰의 추정이 $4 가 아님"
# 불완전한 usage 는 정상 추정치로 기록하지 않는다: 필수 토큰 필드 누락·숫자 아님·음수, 일부 API 요청의 usage 누락 → unknown + partial(누락을 0 으로 읽지 않는다)
r26_full='"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0'
r26_chk() { ( source "$LOADER"; claude_native_usage_check "$1" | jq -r '[.status, (.error // "")] | join(" ")' ); }
for r26_bad in '{"input_tokens":1000,"cache_read_input_tokens":500,"cache_creation_input_tokens":0}' \
               '{"input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":40}' \
               '{"input_tokens":1000,"cache_read_input_tokens":500,"output_tokens":40}' \
               '{"input_tokens":-500,"cache_read_input_tokens":500,"cache_creation_input_tokens":0,"output_tokens":40}' \
               '{"input_tokens":"1000","cache_read_input_tokens":500,"cache_creation_input_tokens":0,"output_tokens":40}' \
               '{"cache_read_input_tokens":500,"cache_creation_input_tokens":0,"output_tokens":40}' \
               "{$r26_full,\"cache_write_5m_input_tokens\":-1,\"cache_write_1h_input_tokens\":1}" \
               "{$r26_full,\"usage_incomplete_requests\":1}"; do
  [ "$(r26_est "$r26_bad")" = null ] && [ "$(r26_chk "$r26_bad")" = "partial USAGE_FIELDS_INCOMPLETE" ] || fail "R26: 불완전한 usage 를 추정했거나 partial 로 판정하지 않음: $r26_bad → $(r26_est "$r26_bad") / $(r26_chk "$r26_bad")"
done
r26_bad="{$r26_full,\"api_requests\":2,\"usage_missing_requests\":1}"
[ "$(r26_est "$r26_bad")" = null ] && [ "$(r26_chk "$r26_bad")" = "partial USAGE_REQUESTS_MISSING" ] || fail "R26: usage 가 없는 API 요청이 있는데 추정함: $(r26_est "$r26_bad") / $(r26_chk "$r26_bad")"
r26_bad="{$r26_full,\"api_requests\":2,\"usage_side_iteration_requests\":1}"
[ "$(r26_est "$r26_bad")" = null ] && [ "$(r26_chk "$r26_bad")" = "partial USAGE_ITERATIONS_EXCLUDED" ] || fail "R26: 합계에 없는 보조 모델 호출(usage.iterations)이 있는데 추정함: $(r26_est "$r26_bad") / $(r26_chk "$r26_bad")"
r26_bad="{$r26_full,\"api_requests\":1,\"usage_unidentified_records\":2}"
[ "$(r26_est "$r26_bad")" = null ] && [ "$(r26_chk "$r26_bad")" = "partial USAGE_REQUEST_ID_MISSING" ] || fail "R26: message.id 없는 레코드가 있는데 추정함: $(r26_est "$r26_bad") / $(r26_chk "$r26_bad")"
[ "$(r26_chk '{}')" = "unavailable " ] && [ "$(r26_chk 'null')" = "unavailable " ] && [ "$(r26_est '{}')" = null ] || fail "R26: usage 가 없는 캡처가 unavailable 이 아님"
[ "$(r26_chk "{$r26_full}")" = "transcript " ] || fail "R26: 완전한 usage 가 transcript 로 판정되지 않음"
# speed·inference_geo 미보고는 표준 요금으로 가정해 추정하되 그 가정을 적는다. 둘 다 보고된 요청만이면 가정 문구가 없다
r26_asm() { ( source "$LOADER"; claude_native_estimate_cost "$1" "$(claude_model_pricing claude-opus-5-5)" | jq -r '.assumptions' ); }
[ "$(r26_est "{$r26_full}")" = 0.004 ] || fail "R26: speed·geo 미보고 요청의 추정이 표준 요금 환산이 아님"
case "$(r26_asm "{$r26_full}")" in *"speed 미보고 요청은 standard 로 가정"*"inference_geo 미보고 요청은 표준 요금"*) ;; *) fail "R26: speed·geo 미보고 가정이 assumptions 에 없음: $(r26_asm "{$r26_full}")";; esac
case "$(r26_asm "{$r26_full,\"speeds\":[\"standard\",\"unreported\"],\"inference_geos\":[\"global\"]}")" in *"speed 미보고"*) ;; *) fail "R26: 일부 요청의 speed 미보고 가정이 빠짐";; esac
case "$(r26_asm "{$r26_full,\"speeds\":[\"standard\"],\"inference_geos\":[\"global\"]}")" in *"미보고"*) fail "R26: 보고된 speed·geo 에 가정 문구가 붙음";; esac
( source "$LOADER"; claude_model_pricing claude-haiku-5-5 >/dev/null || claude_model_pricing claude-opus-5-5-20260101 >/dev/null ) && fail "R26: 가격표에 없는 모델(길이별 요금·날짜 접미사 ID)에 가격을 돌려줌"
( source "$LOADER"; printf '{"cli":"claude_native","cost_usd":null,"estimated_cost_usd":null,"usage_observation_status":"unavailable"}\n' > "$TMP/r26.usage"; [ "$(usage_summary "$TMP/r26.usage" | jq -r '.usage_unobserved_invocations')" = 1 ] ) \
  || fail "R26: 전사에 usage 가 없는 native 호출이 미관측으로 세어지지 않음"
[ ! -e .agent-work/.session-validator-design-01-ddd.native.json ] || fail "R19: accept 하지 않은 검증자 세션이 확정됨"
pass "R09·R06·R26. completed 원문만 수용(1회), 중복 훅 무시, usage 는 관측값 + 비용 unknown"

# ================= R10 SubagentHandback 모드 =================
role_ro VALIDATOR "validator-design-02-a" "design-validator-round-02" "$TMP/v2.json"; [ "$RC" = 42 ] || fail "R10: 요청 발행 실패"
SIM_HANDBACK=1 SIM_CLOSING='{"verdict":"BLOCK","note":"closing text"}' sim_agent "$PASS_JSON" || fail "R10: dispatch 실패"
jq -e '.report_source=="SubagentHandback" and .closing_text_ignored>0' "$ND/results/$(req_get '.request_id').capture.json" >/dev/null || fail "R10: 보고 출처가 SubagentHandback 이 아님"
role_ro VALIDATOR "validator-design-02-b" "design-validator-round-02" "$TMP/v2.json"
[ "$RC" = 0 ] && [ "$(jq -r '.verdict' "$TMP/v2.json")" = PASS ] || { cat "$TMP/last.log"; fail "R10: Handback 의 message 가 결과로 쓰이지 않음 (rc $RC)"; }
[ "$(jq -r '.agent_id' "$ND/requests/$id1.json" 2>/dev/null)" != "$SIM_LAST_AGENT" ] || true
pass "R10. SubagentHandback 의 실제 message 만 결과 — SubagentStop closing text 로 대체하지 않음"

# ================= 보고 레코드가 SubagentStop 보다 늦게 쓰이는 경우(실모델 POC 에서 관측한 경쟁) =================
role_ro VALIDATOR "validator-design-05-a" "design-validator-round-05" "$TMP/v5r.json"; [ "$RC" = 42 ] || fail "지연 보고: 요청 발행 실패"
sim_pre; sim_post agentlate claude-opus-5-5; late_prompt="$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.updatedInput.prompt')"
{ jq -nc --arg p "$late_prompt" '{type:"user", agentId:"agentlate", sessionId:"sess-main", message:{role:"user", content:$p}}'
  jq -nc '{type:"assistant", agentId:"agentlate", sessionId:"sess-main", requestedModel:"claude-opus-5-5", effort:"medium", message:{id:"l1", model:"claude-opus-5-5", stop_reason:"tool_use", usage:{input_tokens:1, output_tokens:1}, content:[{type:"tool_use", name:"Read", input:{}}]}}'
} > "$TMP/transcripts/agent-agentlate.jsonl"
( sleep 1; jq -nc --arg r "$PASS_JSON" '{type:"assistant", agentId:"agentlate", sessionId:"sess-main", requestedModel:"claude-opus-5-5", effort:"medium", message:{id:"l2", model:"claude-opus-5-5", stop_reason:"tool_use", usage:{input_tokens:1, output_tokens:1}, content:[{type:"tool_use", name:"SubagentHandback", input:{message:$r}}]}}' >> "$TMP/transcripts/agent-agentlate.jsonl" ) &
sim_stop agentlate feature-validator; wait
jq -e '.report_status=="OK" and .report_source=="SubagentHandback" and .report_wait_tries>=1' "$ND/results/$(req_get '.request_id').capture.json" >/dev/null \
  || fail "지연 보고: 전사에 늦게 쓰인 보고를 기다리지 않고 NO_REPORT 로 캡처함: $(cat "$ND/results/$(req_get '.request_id').capture.json")"
role_ro VALIDATOR "validator-design-05-b" "design-validator-round-05" "$TMP/v5r.json"; [ "$RC" = 0 ] || { cat "$TMP/last.log"; fail "지연 보고: 수용 실패 (rc $RC)"; }
# 끝까지 보고가 없으면 NO_REPORT — 성공으로 받지 않는다
role_ro VALIDATOR "validator-design-06-a" "design-validator-round-06" "$TMP/v6r.json"; [ "$RC" = 42 ] || fail "무보고: 요청 발행 실패"
sim_pre; sim_post agentnone claude-opus-5-5; late_prompt="$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.updatedInput.prompt')"
jq -nc --arg p "$late_prompt" '{type:"user", agentId:"agentnone", sessionId:"sess-main", message:{role:"user", content:$p}}' > "$TMP/transcripts/agent-agentnone.jsonl"
jq -nc '{type:"assistant", agentId:"agentnone", sessionId:"sess-main", requestedModel:"claude-opus-5-5", effort:"medium", message:{id:"n1", model:"claude-opus-5-5", stop_reason:"tool_use", usage:{input_tokens:1, output_tokens:1}, content:[{type:"tool_use", name:"Read", input:{}}]}}' >> "$TMP/transcripts/agent-agentnone.jsonl"
FEATURE_NATIVE_REPORT_WAIT_TRIES=2 sim_stop agentnone feature-validator
role_ro VALIDATOR "validator-design-06-b" "design-validator-round-06" "$TMP/v6r.json"
[ "$RC" = 1 ] && grep -q 'report_status NO_REPORT' "$TMP/last.log" && [ ! -e "$TMP/v6r.json" ] || { cat "$TMP/last.log"; fail "무보고: 보고 없는 실행이 성공으로 처리됨 (rc $RC)"; }
pass "보고 레코드 지연 → 기다려 캡처 / 끝까지 없으면 NO_REPORT(성공 아님)"

# ================= U1 불완전한 usage 의 종단 경로: 훅이 누락을 세고, usage 행은 unknown + partial(완료 판정은 그대로) =================
u1_row() { jq -c --arg l "$1" 'select(.label==$l)' .agent-work/usage.jsonl; }
# 위 지연 보고 사례의 전사는 usage 에 cache_read·cache_creation 필드가 없다 → 필수 필드 누락. 결과는 수용됐고(위 rc 0) 비용만 unknown 이다
[ "$(u1_row design-validator-round-05 | jq -r '[.cost_kind, .estimated_cost_usd, .usage_observation_status, .usage_error, .input_uncached, .output, .num_turns, .context_last_turn, .success] | @csv')" = '"unknown",,"partial","USAGE_FIELDS_INCOMPLETE",,,,,true' ] \
  || fail "U1: 필수 필드가 없는 usage 가 추정 비용·토큰으로 기록됨: $(u1_row design-validator-round-05)"
# 실패한 호출의 사유(report 상태)는 usage 진단 코드에 덮이지 않는다
[ "$(u1_row design-validator-round-06 | jq -r '[.cost_kind, .usage_observation_status, .usage_error, .success] | @csv')" = '"unknown","partial","NATIVE_REPORT_NO_REPORT+USAGE_FIELDS_INCOMPLETE",false' ] \
  || fail "U1: 보고 실패 사유와 usage 진단 코드가 함께 남지 않음: $(u1_row design-validator-round-06)"
# assistant 메시지 2개 중 하나에 usage 가 없다 → API 요청 2건·usage 누락 1건으로 센다(요청 1건만 관측한 것으로 집계하지 않는다)
role_ro VALIDATOR "validator-design-41-a" "design-validator-round-41" "$TMP/v41.json"; [ "$RC" = 42 ] || fail "U1: 요청 발행 실패"
sim_pre; sim_post agentmiss claude-opus-5-5; u1_prompt="$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.updatedInput.prompt')"
{ jq -nc --arg p "$u1_prompt" '{type:"user", agentId:"agentmiss", sessionId:"sess-main", message:{role:"user", content:$p}}'
  jq -nc '{type:"assistant", agentId:"agentmiss", sessionId:"sess-main", requestedModel:"claude-opus-5-5", effort:"medium", message:{id:"u1", model:"claude-opus-5-5", stop_reason:"tool_use", usage:{input_tokens:3, cache_read_input_tokens:500, cache_creation_input_tokens:20, output_tokens:40, cache_creation:{ephemeral_5m_input_tokens:12, ephemeral_1h_input_tokens:8}, speed:"standard", inference_geo:"global"}, content:[{type:"tool_use", name:"Read", input:{}}]}}'
  jq -nc --arg r "$PASS_JSON" '{type:"assistant", agentId:"agentmiss", sessionId:"sess-main", requestedModel:"claude-opus-5-5", effort:"medium", message:{id:"u2", model:"claude-opus-5-5", stop_reason:"end_turn", content:[{type:"text", text:$r}]}}'
} > "$TMP/transcripts/agent-agentmiss.jsonl"
sim_stop agentmiss feature-validator
jq -e '.report_status=="OK" and .usage.api_requests==2 and .usage.usage_missing_requests==1 and .usage.usage_incomplete_requests==0 and .usage.input_tokens==3' "$ND/results/$(req_get '.request_id').capture.json" >/dev/null \
  || fail "U1: 훅이 usage 없는 요청을 세지 않음: $(jq -c '.usage' "$ND/results/$(req_get '.request_id').capture.json")"
role_ro VALIDATOR "validator-design-41-b" "design-validator-round-41" "$TMP/v41.json"
[ "$RC" = 0 ] && [ "$(jq -r '.verdict' "$TMP/v41.json")" = PASS ] || { cat "$TMP/last.log"; fail "U1: usage 가 불완전하다는 이유로 결과 수용이 바뀜 (rc $RC)"; }
[ "$(u1_row design-validator-round-41 | jq -r '[.cost_kind, .estimated_cost_usd, .pricing_basis, .usage_observation_status, .usage_error, .input_uncached, .cache_read, .output, .success] | @csv')" = '"unknown",,,"partial","USAGE_REQUESTS_MISSING",,,,true' ] \
  && u1_row design-validator-round-41 | jq -e '.pricing_assumptions | test("2건 중 1건의 usage 가 전사에 없다")' >/dev/null \
  || fail "U1: usage 가 없는 요청이 있는데 추정 비용·토큰이 기록됨: $(u1_row design-validator-round-41)"
# 토큰 필드가 숫자가 아니거나 음수인 전사: 훅의 요약(jq 한 벌)이 죽지 않고 보고를 캡처하며, 그 요청을 불완전으로 센다
role_ro VALIDATOR "validator-design-42-a" "design-validator-round-42" "$TMP/v42.json"; [ "$RC" = 42 ] || fail "U1: 요청 발행 실패(42)"
sim_pre; sim_post agentneg claude-opus-5-5; u1_prompt="$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.updatedInput.prompt')"
{ jq -nc --arg p "$u1_prompt" '{type:"user", agentId:"agentneg", sessionId:"sess-main", message:{role:"user", content:$p}}'
  jq -nc --arg r "$PASS_JSON" '{type:"assistant", agentId:"agentneg", sessionId:"sess-main", requestedModel:"claude-opus-5-5", effort:"medium", message:{id:"g1", model:"claude-opus-5-5", stop_reason:"end_turn", usage:{input_tokens:-500, cache_read_input_tokens:"n/a", cache_creation_input_tokens:0, output_tokens:40, cache_creation:"n/a"}, content:[{type:"text", text:$r}]}}'
} > "$TMP/transcripts/agent-agentneg.jsonl"
sim_stop agentneg feature-validator
jq -e '.report_status=="OK" and .usage.api_requests==1 and .usage.usage_incomplete_requests==1' "$ND/results/$(req_get '.request_id').capture.json" >/dev/null \
  || fail "U1: 비정상 토큰 필드가 있는 전사를 캡처하지 못했거나 불완전으로 세지 않음: $(cat "$ND/results/$(req_get '.request_id').capture.json" 2>/dev/null)"
role_ro VALIDATOR "validator-design-42-b" "design-validator-round-42" "$TMP/v42.json"; [ "$RC" = 0 ] || { cat "$TMP/last.log"; fail "U1: 수용 실패(42) (rc $RC)"; }
[ "$(u1_row design-validator-round-42 | jq -r '[.cost_kind, .estimated_cost_usd, .usage_observation_status, .usage_error, .input_uncached] | @csv')" = '"unknown",,"partial","USAGE_FIELDS_INCOMPLETE",' ] \
  || fail "U1: 음수·비숫자 토큰이 추정 비용으로 기록됨: $(u1_row design-validator-round-42)"
# 요청 안에 보조 모델 호출(advisor_message)이 있다: 그 토큰(입력 96060·출력 10356)은 요청 합계(입력 4·출력 411)에 없다 → 합계만으로 추정하지 않는다. type message 뿐인 iterations 는 정상이다
# 컨텍스트는 비용과 따로 잰다: 마지막 본 모델 호출(iterations 의 마지막 type message)의 입력 2 + 97610 이 그대로 남는다
role_ro VALIDATOR "validator-design-43-a" "design-validator-round-43" "$TMP/v43.json"; [ "$RC" = 42 ] || fail "U1: 요청 발행 실패(43)"
sim_pre; sim_post agentadv claude-opus-5-5; u1_prompt="$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.updatedInput.prompt')"
{ jq -nc --arg p "$u1_prompt" '{type:"user", agentId:"agentadv", sessionId:"sess-main", message:{role:"user", content:$p}}'
  jq -nc '{type:"assistant", agentId:"agentadv", sessionId:"sess-main", requestedModel:"claude-opus-5-5", effort:"medium", message:{id:"a1", model:"claude-opus-5-5", stop_reason:"tool_use", usage:{input_tokens:2, cache_read_input_tokens:100, cache_creation_input_tokens:0, output_tokens:10, cache_creation:{ephemeral_5m_input_tokens:0, ephemeral_1h_input_tokens:0}, speed:"standard", inference_geo:"global", iterations:[{type:"message", input_tokens:2, output_tokens:10, cache_read_input_tokens:100, cache_creation_input_tokens:0}]}, content:[{type:"tool_use", name:"Read", input:{}}]}}'
  jq -nc --arg r "$PASS_JSON" '{type:"assistant", agentId:"agentadv", sessionId:"sess-main", requestedModel:"claude-opus-5-5", effort:"medium", message:{id:"a2", model:"claude-opus-5-5", stop_reason:"end_turn", usage:{input_tokens:4, cache_read_input_tokens:186251, cache_creation_input_tokens:0, output_tokens:411, cache_creation:{ephemeral_5m_input_tokens:0, ephemeral_1h_input_tokens:0}, speed:"standard", inference_geo:"global", iterations:[{type:"message", input_tokens:2, output_tokens:121, cache_read_input_tokens:88641, cache_creation_input_tokens:0}, {type:"advisor_message", model:"claude-fable-5-2", input_tokens:96060, output_tokens:10356, cache_read_input_tokens:0, cache_creation_input_tokens:0}, {type:"message", input_tokens:2, output_tokens:290, cache_read_input_tokens:97610, cache_creation_input_tokens:0}]}, content:[{type:"text", text:$r}]}}'
} > "$TMP/transcripts/agent-agentadv.jsonl"
sim_stop agentadv feature-validator
jq -e '.report_status=="OK" and .usage.api_requests==2 and .usage.usage_side_iteration_requests==1 and .usage.usage_missing_requests==0 and .usage.usage_incomplete_requests==0' "$ND/results/$(req_get '.request_id').capture.json" >/dev/null \
  || fail "U1: 훅이 보조 모델 호출이 있는 요청을 세지 않음: $(jq -c '.usage' "$ND/results/$(req_get '.request_id').capture.json")"
role_ro VALIDATOR "validator-design-43-b" "design-validator-round-43" "$TMP/v43.json"; [ "$RC" = 0 ] || { cat "$TMP/last.log"; fail "U1: 수용 실패(43) (rc $RC)"; }
[ "$(u1_row design-validator-round-43 | jq -r '[.cost_kind, .estimated_cost_usd, .usage_observation_status, .usage_error, .output, .context_last_turn, .success] | @csv')" = '"unknown",,"partial","USAGE_ITERATIONS_EXCLUDED",,97612,true' ] \
  && [ "$(u1_row design-validator-round-43 | jq -r '.context_source')" = last_message_iteration ] \
  || fail "U1: 합계에 없는 보조 모델 호출이 있는데 추정 비용이 기록됐거나, 마지막 본 모델 호출의 컨텍스트(2 + 97610 — 요청 합계 186255 아님)가 남지 않음: $(u1_row design-validator-round-43)"
# message.id 가 없거나 문자열이 아닌 assistant 레코드: 서로 다른 요청 2건이 한 요청으로 묶여 마지막 토큰만 남으면 안 된다 → 묶지 않고 세기만 한다(요약 jq 가 죽지 않고 보고는 캡처)
role_ro VALIDATOR "validator-design-44-a" "design-validator-round-44" "$TMP/v44.json"; [ "$RC" = 42 ] || fail "U1: 요청 발행 실패(44)"
sim_pre; sim_post agentnoid claude-opus-5-5; u1_prompt="$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.updatedInput.prompt')"
{ jq -nc --arg p "$u1_prompt" '{type:"user", agentId:"agentnoid", sessionId:"sess-main", message:{role:"user", content:$p}}'
  jq -nc '{type:"assistant", agentId:"agentnoid", sessionId:"sess-main", requestedModel:"claude-opus-5-5", effort:"medium", message:{model:"claude-opus-5-5", stop_reason:"tool_use", usage:{input_tokens:3, cache_read_input_tokens:500, cache_creation_input_tokens:0, output_tokens:40, cache_creation:{ephemeral_5m_input_tokens:0, ephemeral_1h_input_tokens:0}, speed:"standard", inference_geo:"global"}, content:[{type:"tool_use", name:"Read", input:{}}]}}'
  jq -nc --arg r "$PASS_JSON" '{type:"assistant", agentId:"agentnoid", sessionId:"sess-main", requestedModel:"claude-opus-5-5", effort:"medium", message:{id:7, model:"claude-opus-5-5", stop_reason:"end_turn", usage:{input_tokens:5, cache_read_input_tokens:600, cache_creation_input_tokens:0, output_tokens:50, cache_creation:{ephemeral_5m_input_tokens:0, ephemeral_1h_input_tokens:0}, speed:"standard", inference_geo:"global"}, content:[{type:"text", text:$r}]}}'
} > "$TMP/transcripts/agent-agentnoid.jsonl"
sim_stop agentnoid feature-validator
jq -e '.report_status=="OK" and .usage.api_requests==0 and .usage.usage_unidentified_records==2 and .usage.input_tokens==0' "$ND/results/$(req_get '.request_id').capture.json" >/dev/null \
  || fail "U1: 훅이 message.id 없는 레코드를 세지 않았거나 한 요청으로 묶음: $(cat "$ND/results/$(req_get '.request_id').capture.json" 2>/dev/null)"
role_ro VALIDATOR "validator-design-44-b" "design-validator-round-44" "$TMP/v44.json"; [ "$RC" = 0 ] || { cat "$TMP/last.log"; fail "U1: 수용 실패(44) (rc $RC)"; }
[ "$(u1_row design-validator-round-44 | jq -r '[.cost_kind, .estimated_cost_usd, .usage_observation_status, .usage_error, .input_uncached, .output, .num_turns, .context_last_turn, .success] | @csv')" = '"unknown",,"partial","USAGE_REQUEST_ID_MISSING",,,,605,true' ] \
  || fail "U1: message.id 없는 요청이 정상 관측으로 기록됐거나, 마지막 레코드 자체의 usage 로 정해지는 컨텍스트(5 + 600)가 남지 않음: $(u1_row design-validator-round-44)"
[ "$( ( source "$LOADER"; usage_summary | jq -r '[.usage_unobserved_invocations >= 5, .estimated_cost_usd < 0.01] | @csv' ) )" = 'true,true' ] || fail "U1: 불완전 관측 행이 미관측 집계에 들어가지 않음"
pass "U1. 불완전한 usage(필수 필드 누락·음수·비숫자·일부 요청의 usage 누락·합계에 없는 보조 모델 호출·message.id 없는 레코드) → 비용 unknown·관측 partial·토큰 null, 결과 수용은 불변. context_last_turn 은 마지막 본 모델 호출의 usage 가 검증될 때만 따로 남는다"

# ================= R11 다른 모델로 fallback =================
role_ro VALIDATOR "validator-design-03-a" "design-validator-round-03" "$TMP/v3.json"; [ "$RC" = 42 ] || fail "R11: 요청 발행 실패"
id3="$(req_get '.request_id')"
SIM_MODEL=claude-sonnet-5-5 sim_agent "$PASS_JSON" || fail "R11: dispatch 실패"
role_ro VALIDATOR "validator-design-03-b" "design-validator-round-03" "$TMP/v3.json"
[ "$RC" = 43 ] && grep -q NATIVE_MODEL_MISMATCH "$TMP/last.log" && [ ! -e "$TMP/v3.json" ] || { cat "$TMP/last.log"; fail "R11: 다른 모델의 결과가 불수용되지 않음 (rc $RC)"; }
role_ro VALIDATOR "validator-design-03-c" "design-validator-round-03" "$TMP/v3.json"
[ "$RC" = 43 ] && [ "$(req_get '.request_id')" = "$id3" ] && [ "$(req_get '.state')" = REJECTED ] || fail "R11: 불수용 뒤 재실행이 같은 사유로 멈추지 않음(자동 복구 금지)"
# 다른 호출 지점에 도달해도 낡은 요청 위에서 새 호출을 하지 않는다
role_ro REVIEWER "reviewer-a01" "impl-review-a01-round-01" "$TMP/r1.json"
[ "$RC" = 43 ] && grep -q NATIVE_PENDING_MISMATCH "$TMP/last.log" || fail "R07: 다른 호출 지점이 낡은 pending 위에서 진행함 (rc $RC)"
( bash .claude/skills/feature/scripts/native-agent-bridge.sh discard "$id3" ) > "$TMP/last.log" 2>&1 || { cat "$TMP/last.log"; fail "R11: 명시적 discard 실패"; }
[ ! -e "$ND/pending.json" ] && [ "$(jq -r '.state' "$ND/requests/$id3.json")" = ABANDONED ] || fail "R11: discard 가 요청을 치우지 않음"
pass "R11. 요청과 다른 모델의 결과 → 불수용, 재실행도 모델 0회로 같은 사유, 복구는 명시적 discard 뿐"

# ================= R29 요청 대기 중 backend 변경 =================
# 같은 호출 지점(slot)이어도, 남은 native 요청의 역할이 더는 claude_native 가 아니면 CLI 를 부르지 않는다. 요청 state 는 그대로 두므로 설정을 되돌리면 같은 요청이 이어진다.
: > "$CLI_LOG"
role_ro VALIDATOR "validator-design-07-a" "design-validator-round-07" "$TMP/v7.json"; [ "$RC" = 42 ] || fail "R29: 요청 발행 실패"
id7="$(req_get '.request_id')"
RC=0; ( set -e; source "$LOADER"; VALIDATOR_MODEL=gpt-6.2-astra; run_readonly_json_role VALIDATOR "validator-design-07-b" "design-validator-round-07" "$SCHEMA" "$TMP/v7.json" "p" "" ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 43 ] && grep -q NATIVE_PENDING_BACKEND_CHANGED "$TMP/last.log" && [ ! -s "$CLI_LOG" ] && [ ! -e "$TMP/v7.json" ] \
  || { cat "$TMP/last.log"; fail "R29: 모델을 codex 로 바꾼 같은 호출 지점이 남은 native 요청 위에서 CLI 를 호출함 (rc $RC, cli: $(cat "$CLI_LOG"))"; }
RC=0; ( set -e; source "$LOADER"; CLAUDE_BACKEND=legacy_cli; run_readonly_json_role VALIDATOR "validator-design-07-c" "design-validator-round-07" "$SCHEMA" "$TMP/v7.json" "p" "" ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 43 ] && grep -q NATIVE_PENDING_BACKEND_CHANGED "$TMP/last.log" && [ ! -s "$CLI_LOG" ] \
  || { cat "$TMP/last.log"; fail "R29: CLAUDE_BACKEND=legacy_cli 로 바꾼 같은 호출 지점이 claude -p 를 호출함 (rc $RC, cli: $(cat "$CLI_LOG"))"; }
[ "$(req_get '.request_id')" = "$id7" ] && [ "$(req_get '.state')" = PREPARED ] || fail "R29: backend 변경 중단이 요청 state 를 바꿈: $(req_get '.state')"
# 설정을 되돌리면 같은 요청이 그대로 이어진다
role_ro VALIDATOR "validator-design-07-d" "design-validator-round-07" "$TMP/v7.json"
[ "$RC" = 42 ] && [ "$(req_get '.request_id')" = "$id7" ] || fail "R29: 설정 원복 뒤 같은 요청이 이어지지 않음 (rc $RC)"
sim_agent "$PASS_JSON" || fail "R29: dispatch 실패"
# 결과가 캡처된 뒤(RESULT_READY)에 backend 가 바뀌어도 같다 — 수용도 CLI 호출도 하지 않는다
RC=0; ( set -e; source "$LOADER"; VALIDATOR_MODEL=gpt-6.2-astra; run_readonly_json_role VALIDATOR "validator-design-07-e" "design-validator-round-07" "$SCHEMA" "$TMP/v7.json" "p" "" ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 43 ] && grep -q NATIVE_PENDING_BACKEND_CHANGED "$TMP/last.log" && [ ! -s "$CLI_LOG" ] && [ ! -e "$TMP/v7.json" ] && [ "$(req_get '.state')" = RESULT_READY ] \
  || { cat "$TMP/last.log"; fail "R29: RESULT_READY 요청 위에서 backend 변경이 통과함 (rc $RC)"; }
role_ro VALIDATOR "validator-design-07-f" "design-validator-round-07" "$TMP/v7.json"; [ "$RC" = 0 ] && [ -s "$TMP/v7.json" ] || { cat "$TMP/last.log"; fail "R29: 설정 원복 뒤 수용 실패 (rc $RC)"; }
pass "R29. native 요청 대기 중 backend 변경(codex 모델·legacy_cli) → 같은 호출 지점이어도 CLI 0회로 중단, 요청 보존, 설정 원복 시 이어짐"

# ================= R07 프롬프트 해시·세션 mismatch =================
role_ro VALIDATOR "validator-design-04-a" "design-validator-round-04" "$TMP/v4.json"; [ "$RC" = 42 ] || fail "R07: 요청 발행 실패"
SIM_TAMPER=1 sim_agent "$PASS_JSON" || fail "R07: dispatch 실패"
role_ro VALIDATOR "validator-design-04-b" "design-validator-round-04" "$TMP/v4.json"
[ "$RC" = 43 ] && grep -q NATIVE_PROMPT_HASH_MISMATCH "$TMP/last.log" || { cat "$TMP/last.log"; fail "R07: 변조된 프롬프트의 결과가 불수용되지 않음 (rc $RC)"; }
( bash .claude/skills/feature/scripts/native-agent-bridge.sh discard "$(req_get '.request_id')" ) >/dev/null 2>&1 || fail "R07: discard 실패"
role_ro VALIDATOR "validator-design-04-c" "design-validator-round-04" "$TMP/v4.json"; [ "$RC" = 42 ] || fail "R07: 요청 재발행 실패"
sim_agent "$PASS_JSON" || fail "R07: dispatch 실패"
RC=0; ( set -e; source "$LOADER"; CLAUDE_CODE_SESSION_ID=sess-other run_readonly_json_role VALIDATOR k "design-validator-round-04" "$SCHEMA" "$TMP/v4.json" "smoke prompt for design-validator-round-04" "" ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 43 ] && grep -q NATIVE_OWNER_SESSION_MISMATCH "$TMP/last.log" || { cat "$TMP/last.log"; fail "R07: 다른 메인 세션이 결과를 가져감 (rc $RC)"; }
reset_native
pass "R07. 프롬프트 해시·소유 세션·호출 지점 불일치 → 불수용, 자동 복구 없음"

# ================= R13 읽기 전용 역할 =================
for a in feature-validator feature-reviewer; do
  grep -qx 'tools: Read, Grep, Glob' ".claude/skills/feature/agents/$a.md" && grep -qx 'permissionMode: dontAsk' ".claude/skills/feature/agents/$a.md" \
    || fail "R13: $a 정의의 도구가 읽기 전용(Read, Grep, Glob / dontAsk)이 아님"
done
for a in feature-designer feature-fixer feature-worker; do
  grep -E '^tools:' ".claude/skills/feature/agents/$a.md" | grep -Eq 'Agent|ScheduleWakeup|Task' && fail "R13: $a 정의가 하위 Agent·예약 도구를 허용함"
done
role_ro REVIEWER "reviewer-a01" "impl-review-a01-round-01" "$TMP/r1.json"; [ "$RC" = 42 ] || fail "R13: 요청 발행 실패"
SIM_SIDE='echo tampered >> src/u01.txt' sim_agent "$PASS_JSON" || fail "R13: dispatch 실패"
role_ro REVIEWER "reviewer-a01" "impl-review-a01-round-01" "$TMP/r1.json"
[ "$RC" = 43 ] && grep -q NATIVE_READONLY_VIOLATION "$TMP/last.log" && [ ! -e "$TMP/r1.json" ] || { cat "$TMP/last.log"; fail "R13: 읽기 전용 역할이 트리를 바꿨는데 판정이 수용됨 (rc $RC)"; }
git checkout -q -- src/u01.txt; reset_native
pass "R13. 검증자·리뷰어 정의는 쓰기 도구 없음 + 호출 전후 tree 가 다르면 판정 불수용"

# ================= R19 R17 세션 경계 =================
role_ro REVIEWER "reviewer-a01" "impl-review-a01-round-01" "$TMP/r1.json"; [ "$RC" = 42 ] && [ "$(req_get '.session_intent')" = NEW ] || fail "R19: 첫 리뷰가 NEW 가 아님"
sim_agent "$PASS_JSON" || fail "R19: dispatch 실패"; rev_agent="$SIM_LAST_AGENT"
role_ro REVIEWER "reviewer-a01" "impl-review-a01-round-01" "$TMP/r1.json"; [ "$RC" = 0 ] || { cat "$TMP/last.log"; fail "R19: 리뷰 결과 수용 실패"; }
[ ! -e .agent-work/.session-reviewer-a01.native.json ] || fail "R19: accept 전에 세션이 확정됨"
role_accept REVIEWER reviewer-a01 || fail "R19: role_session_accept 실패"
jq -e --arg a "$rev_agent" '.backend=="claude_native" and .agent_id==$a and .parent_session_id=="sess-main" and .model=="claude-sonnet-5-5"' .agent-work/.session-reviewer-a01.native.json >/dev/null \
  || fail "R19: native 세션 원장이 agent id·부모 세션·모델을 담지 않음"
role_ro REVIEWER "reviewer-a01" "impl-review-a01-round-02" "$TMP/r2.json"
[ "$RC" = 42 ] && [ "$(req_get '.session_intent')" = RESUME ] && [ "$(req_get '.resume_agent_id')" = "$rev_agent" ] || fail "R19: 같은 attempt 의 다음 라운드가 같은 Agent 재개가 아님"
grep -q "SendMessage" "$TMP/last.log" || fail "R19: 재개 안내가 SendMessage 가 아님"
SIM_TOOL=Agent sim_pre
[ "$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] || fail "R19: 재개 요청을 새 Agent 로 여는 것이 거부되지 않음(묵시적 fresh)"
SIM_TO=someone-else sim_pre
[ "$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] || fail "R19: 다른 Agent 로의 재개가 거부되지 않음"
sim_agent "$PASS_JSON" || fail "R19: SendMessage 재개 dispatch 실패"
[ "$SIM_LAST_AGENT" = "$rev_agent" ] || fail "R19: 재개가 다른 agent id 로 감"
jq -e '.prompt_wrapper=="coordinator_message" and .prompt_record_is_meta==true' "$ND/results/$(req_get '.request_id').capture.json" >/dev/null || fail "R19: 재개 메시지(isMeta + 하네스 포장)가 인식되지 않음"
role_ro REVIEWER "reviewer-a01" "impl-review-a01-round-02" "$TMP/r2.json"; [ "$RC" = 0 ] || { cat "$TMP/last.log"; fail "R19: 재개 결과 수용 실패 (전사의 이전 턴과 섞였을 수 있다)"; }
grep -q '"reason":"CAPTURED"' "$ND/hook-trace.jsonl" || fail "R19: 훅 흔적(hook-trace.jsonl)에 캡처 기록이 없음"
role_ro REVIEWER "reviewer-a02" "impl-review-a02-round-01" "$TMP/r3.json"
[ "$RC" = 42 ] && [ "$(req_get '.session_intent')" = NEW ] || fail "R19: attempt 가 바뀌었는데 fresh Agent 가 아님"
( bash .claude/skills/feature/scripts/native-agent-bridge.sh discard "$(req_get '.request_id')" ) >/dev/null 2>&1 || fail "discard 실패"
role_ro VALIDATOR "validator-design-01-x" "design-validator-round-01" "$TMP/v5.json"; [ "$(req_get '.session_intent')" = NEW ] || fail "R19: 검증자가 fresh 가 아님"
( bash .claude/skills/feature/scripts/native-agent-bridge.sh discard "$(req_get '.request_id')" ) >/dev/null 2>&1 || fail "discard 실패"
# R17: 부모 세션이 바뀜(/clear·세션 교체) → 묵시적 fresh 금지
RC=0; ( set -e; source "$LOADER"; CLAUDE_CODE_SESSION_ID=sess-new run_readonly_json_role REVIEWER reviewer-a01 "impl-review-a01-round-03" "$SCHEMA" "$TMP/r4.json" p "" ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 1 ] && grep -q NATIVE_PARENT_SESSION_LOST "$TMP/last.log" && [ ! -e "$ND/pending.json" ] || { cat "$TMP/last.log"; fail "R17: 부모 세션 소실인데 요청이 발행됨 (rc $RC)"; }
pass "R19·R17. 검증자 매회 fresh / 리뷰어 attempt 단위 재개(SendMessage, 같은 agent id) / 부모 세션 소실 시 묵시적 fresh 금지"

# ================= R27 이전 backend 세션의 묵시적 마이그레이션 금지 =================
echo "11111111-2222-3333-4444-555555555555" > .agent-work/.session-reviewer-a09
role_ro REVIEWER "reviewer-a09" "impl-review-a09-round-01" "$TMP/r9.json"
[ "$RC" = 1 ] && grep -q SESSION_CLI_MISMATCH "$TMP/last.log" && [ ! -e "$ND/pending.json" ] && [ -f .agent-work/.session-reviewer-a09 ] || { cat "$TMP/last.log"; fail "R27: claude -p 세션이 native 로 묵시적 이관됨 (rc $RC)"; }
RC=0; ( set -e; source "$LOADER"; CLAUDE_BACKEND=legacy_cli; run_readonly_json_role REVIEWER reviewer-a01 "impl-review-a01-round-03" "$SCHEMA" "$TMP/r9.json" p "" ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 1 ] && grep -q SESSION_CLI_MISMATCH "$TMP/last.log" && [ ! -s "$CLI_LOG" ] || { cat "$TMP/last.log"; fail "R27: native 세션이 claude -p 로 묵시적 이관됨 (rc $RC)"; }
reset_native
pass "R27. 진행 중인 claude -p ↔ native 세션은 서로 자동 이관되지 않음(상태 보존)"

# ================= D1 다른 PreToolUse 훅이 거부한 호출 =================
# PreToolUse 훅들은 병렬로 돌고 하나라도 거부하면 도구는 실행되지 않는다. 이 스킬의 훅은 allow 를 돌려줬지만 그것은 실행의 증거가 아니다.
# (2026-11-23 실모델 종단에서 관측: 다른 PreToolUse 훅이 Agent 호출을 거부했는데 요청이 DISPATCHED 로 굳어 "완료 대기"에서 영원히 멈췄다.)
reset_native; : > "$CLI_LOG"; BR=".claude/skills/feature/scripts/native-agent-bridge.sh"
DENY_TEXT='PreToolUse:Agent hook error: Subagent policy: parent cannot spawn same tier'
role_ro VALIDATOR "validator-design-11-a" "design-validator-round-11" "$TMP/d1.json"; [ "$RC" = 42 ] || fail "D1: 요청 발행 실패"
idd="$(req_get '.request_id')"
sim_pre; tu1="$SIM_TU"
[ "$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = allow ] || fail "D1: 이 스킬의 훅이 정상 dispatch 를 거부함"
[ "$(req_get '.state')" = DISPATCHING ] && [ "$(req_get '.dispatch_attempt.tool_use_id')" = "$tu1" ] && [ "$(req_get '.dispatch_attempt.session_id')" = sess-main ] && [ "$(req_get '.dispatched_at // ""')" = "" ] \
  || fail "D1: PreToolUse 가 요청을 DISPATCHED 로 확정했거나 시도(tool_use_id·세션)를 기록하지 않음: state $(req_get '.state')"
# 거부 증거가 아직 없다(전사에 도구 결과 없음) → 불명: 대기(42), redispatch 불가, 두 번째 dispatch 거부
role_ro VALIDATOR "validator-design-11-b" "design-validator-round-11" "$TMP/d1.json"
[ "$RC" = 42 ] && grep -q '실행 여부 불명' "$TMP/last.log" && [ "$(req_get '.state')" = DISPATCHING ] || { cat "$TMP/last.log"; fail "D1: 증거 없는 DISPATCHING 재실행이 대기(42)가 아님 (rc $RC)"; }
( bash "$BR" redispatch "$idd" ) > "$TMP/last.log" 2>&1 && fail "D1: 거부가 확인되지 않았는데 redispatch 가 통과함"
grep -q '거부가 확인되지 않았다' "$TMP/last.log" && [ "$(req_get '.state')" = DISPATCHING ] || { cat "$TMP/last.log"; fail "D1: 불명 상태의 redispatch 거부 사유가 다르거나 state 가 바뀜"; }
sim_pre
[ "$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] && [ "$(req_get '.dispatch_attempt.tool_use_id')" = "$tu1" ] \
  || fail "D1: 실행 여부 불명 상태에서 같은 요청의 두 번째 dispatch 가 거부되지 않았거나 앞선 시도 기록이 바뀜"
# 다른 훅의 거부가 메인 전사에 남았다 → 재실행은 모델·CLI 0회로 NATIVE_DISPATCH_DENIED(43), 요청 state 불변, 새 요청 없음
sim_main_result "$tu1" permission-rule "$DENY_TEXT"
role_ro VALIDATOR "validator-design-11-c" "design-validator-round-11" "$TMP/d1.json"
[ "$RC" = 43 ] && grep -q 'NATIVE_DISPATCH_DENIED' "$TMP/last.log" && grep -q 'parent cannot spawn same tier' "$TMP/last.log" && grep -q "redispatch $idd" "$TMP/last.log" \
  && [ "$(req_get '.state')" = DISPATCHING ] && [ "$(req_get '.request_id')" = "$idd" ] && [ "$(req_count)" = 1 ] && [ ! -s "$CLI_LOG" ] && [ ! -e "$TMP/d1.json" ] \
  || { cat "$TMP/last.log"; fail "D1: 거부된 dispatch 가 NATIVE_DISPATCH_DENIED 로 올라오지 않음 (rc $RC, state $(req_get '.state'), 요청 $(req_count)개)"; }
role_ro VALIDATOR "validator-design-11-d" "design-validator-round-11" "$TMP/d1.json"
[ "$RC" = 43 ] && [ "$(req_count)" = 1 ] || fail "D1: 거부 뒤 재실행이 같은 사유로 멈추지 않음(자동 재전송·자동 fresh 금지) (rc $RC)"
sim_pre
[ "$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] || fail "D1: 거부가 확인됐어도 명시적 redispatch 전에는 다시 보낼 수 없어야 함"
# 명시적 재시도: 같은 요청(id·payload·intent)이 PREPARED 로 — 새 요청도 fresh Agent 도 아니다
sha_before="$(req_get '.dispatch_sha256')"
( bash "$BR" redispatch "$idd" ) > "$TMP/last.log" 2>&1 || { cat "$TMP/last.log"; fail "D1: 거부가 확인된 요청의 redispatch 실패"; }
[ "$(req_get '.state')" = PREPARED ] && [ "$(req_get '.request_id')" = "$idd" ] && [ "$(req_get '.session_intent')" = NEW ] && [ "$(req_get '.dispatch_sha256')" = "$sha_before" ] \
  && [ "$(req_get '.dispatch_history|length')" = 1 ] && [ "$(req_get '.dispatch_history[0].tool_use_id')" = "$tu1" ] && [ "$(req_get '.dispatch_history[0].outcome')" = DENIED ] && [ "$(req_get '.dispatch_attempt // "none"')" = none ] \
  || fail "D1: redispatch 가 같은 요청을 PREPARED 로 되돌리지 않았거나 시도 이력을 남기지 않음: $(req_get '{state, dispatch_history}|tostring')"
role_ro VALIDATOR "validator-design-11-e" "design-validator-round-11" "$TMP/d1.json"; [ "$RC" = 42 ] && [ "$(req_count)" = 1 ] || fail "D1: redispatch 뒤 재실행이 같은 요청을 재제시하지 않음 (rc $RC)"
sim_agent "$PASS_JSON" || fail "D1: 재시도 dispatch 실패"
[ "$(req_get '.dispatch_attempt.n')" = 2 ] && [ "$(req_get '.dispatch_attempt.tool_use_id')" != "$tu1" ] || fail "D1: 재시도가 새 시도(n=2, 새 tool_use_id)로 기록되지 않음"
role_ro VALIDATOR "validator-design-11-f" "design-validator-round-11" "$TMP/d1.json"
[ "$RC" = 0 ] && [ "$(jq -r '.verdict' "$TMP/d1.json")" = PASS ] && [ "$(jq -r '.state' "$ND/requests/$idd.json")" = CONSUMED ] || { cat "$TMP/last.log"; fail "D1: 재시도한 요청의 결과 수용 실패 (rc $RC)"; }
# 명시적 정리: 거부된 요청을 버린다(재시도 대신)
role_ro VALIDATOR "validator-design-12-a" "design-validator-round-12" "$TMP/d1b.json"; [ "$RC" = 42 ] || fail "D1: 요청 발행 실패"
idd2="$(req_get '.request_id')"; sim_pre; sim_main_result "$SIM_TU" user-rejected "The user doesn't want to proceed with this tool use."
role_ro VALIDATOR "validator-design-12-b" "design-validator-round-12" "$TMP/d1b.json"; [ "$RC" = 43 ] && grep -q 'NATIVE_DISPATCH_DENIED' "$TMP/last.log" || fail "D1: 사용자 거절(user-rejected)이 거부로 판정되지 않음 (rc $RC)"
( bash "$BR" discard "$idd2" ) > "$TMP/last.log" 2>&1 || { cat "$TMP/last.log"; fail "D1: 거부된 요청의 discard 실패"; }
[ ! -e "$ND/pending.json" ] && [ "$(jq -r '.state + "/" + .abandoned_from_state' "$ND/requests/$idd2.json")" = "ABANDONED/DISPATCHING" ] || fail "D1: discard 가 요청을 치우지 않음"
# 모르는 형태의 오류(거부 종류 없음)는 거부가 아니다 — 불명으로 남는다
role_ro VALIDATOR "validator-design-12-c" "design-validator-round-12" "$TMP/d1b.json"; [ "$RC" = 42 ] || fail "D1: 요청 재발행 실패"
idd3="$(req_get '.request_id')"; sim_pre
jq -nc --arg tu "$SIM_TU" '{type:"user", sessionId:"sess-main", message:{role:"user", content:[{type:"tool_result", is_error:true, tool_use_id:$tu, content:"Agent crashed after launch"}]}}' >> "$MAIN_TR"
role_ro VALIDATOR "validator-design-12-d" "design-validator-round-12" "$TMP/d1b.json"
[ "$RC" = 42 ] && grep -q "알려진 '실행 전 거부' 종류가 아니다" "$TMP/last.log" || { cat "$TMP/last.log"; fail "D1: 거부 종류 없는 도구 오류가 불명(42)으로 남지 않음 (rc $RC)"; }
( bash "$BR" redispatch "$idd3" ) > /dev/null 2>&1 && fail "D1: 거부 종류 없는 오류에 redispatch 가 통과함"
( bash "$BR" discard "$idd3" ) > "$TMP/last.log" 2>&1 && grep -q 'Agent 가 아직 돌고 있을 수 있다' "$TMP/last.log" || { cat "$TMP/last.log"; fail "D1: 불명 요청의 discard 가 실패했거나 경고가 없음"; }
[ ! -s "$CLI_LOG" ] || fail "D1: CLI 가 호출됨: $(cat "$CLI_LOG")"
pass "D1. 다른 PreToolUse 훅이 거부한 호출 → DISPATCHED 로 굳지 않음, 거부 확인 시 43(state 불변)·명시적 redispatch(같은 요청)/discard, 불명은 재전송 불가"

# ================= D2 PostToolUse 누락 + 다른 호출의 이벤트 + 실행 확인으로 볼 수 없는 응답 =================
reset_native
role_ro VALIDATOR "validator-design-13-a" "design-validator-round-13" "$TMP/d2.json"; [ "$RC" = 42 ] || fail "D2: 요청 발행 실패"
idp="$(req_get '.request_id')"; sim_pre; tu2="$SIM_TU"
SIM_POST_TU=toolu_someone_else sim_post agentx claude-opus-5-5
[ "$(req_get '.state')" = DISPATCHING ] && [ "$(req_get '.post_tool // "none"')" = none ] || fail "D2: 다른 tool_use_id 의 PostToolUse 가 요청 상태를 바꿈"
SIM_POST_SESSION=sess-other sim_post agentx claude-opus-5-5
[ "$(req_get '.state')" = DISPATCHING ] && [ "$(req_get '.post_tool // "none"')" = none ] || fail "D2: 다른 메인 세션의 PostToolUse 가 요청 상태를 바꿈"
grep -q '"reason":"POST_TOOL_USE_ID_MISMATCH"' "$ND/hook-trace.jsonl" && grep -q '"reason":"POST_SESSION_MISMATCH"' "$ND/hook-trace.jsonl" || fail "D2: 무시한 PostToolUse 의 흔적이 없음"
SIM_POST_RESPONSE='{"status":"async_launched"}' sim_post agentx claude-opus-5-5
[ "$(req_get '.state')" = DISPATCHING ] && [ "$(req_get '.post_tool.launch_confirmed')" = false ] || fail "D2: agentId 없는 응답이 실행 확인으로 처리됨"
SIM_POST_RESPONSE='"Error: something"' sim_post agentx claude-opus-5-5
[ "$(req_get '.state')" = DISPATCHING ] && [ "$(req_get '.post_tool.response_shape')" = string ] || fail "D2: 문자열 오류 응답이 실행 확인으로 처리됨"
role_ro VALIDATOR "validator-design-13-b" "design-validator-round-13" "$TMP/d2.json"
[ "$RC" = 42 ] && grep -q '실행 여부 불명' "$TMP/last.log" && [ "$(req_count)" = 1 ] || { cat "$TMP/last.log"; fail "D2: PostToolUse 누락 상태의 재실행이 불명 대기(42)가 아님 (rc $RC)"; }
sim_pre; [ "$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] && [ "$(req_get '.dispatch_attempt.tool_use_id')" = "$tu2" ] || fail "D2: PostToolUse 누락 상태의 중복 dispatch 가 차단되지 않음"
grep -q '"reason":"DUPLICATE_DISPATCH_BLOCKED"' "$ND/hook-trace.jsonl" || fail "D2: 중복 dispatch 차단 흔적이 없음"
# 전사에는 성공 결과가 있는데 PostToolUse 가 없었다 → 실행됨: 재전송 불가, 대기
sim_main_result "$tu2"
( bash "$BR" redispatch "$idp" ) > "$TMP/last.log" 2>&1 && fail "D2: 실행된 요청에 redispatch 가 통과함"
grep -q 'EXECUTED' "$TMP/last.log" || { cat "$TMP/last.log"; fail "D2: 성공 도구 결과가 EXECUTED 로 판정되지 않음"; }
pass "D2. PostToolUse 누락 → 실행 여부 불명(대기·중복 dispatch 차단·redispatch 불가), 다른 tool_use_id·다른 세션·불완전 응답은 상태를 바꾸지 못함"

# ================= D3 SubagentStop 선도착 + PostToolUse 지연·중복 =================
# 위 요청(DISPATCHING, PostToolUse 없음)의 Agent 가 끝났다. 먼저 결속되지 않는 종료 이벤트들 — 캡처도 상태 변경도 없어야 한다.
d3_prompt="$(cat "$(req_get '.prompt_path')")"
mk_tr() { # agent-id session
  { jq -nc --arg p "$d3_prompt" --arg a "$1" --arg s "$2" '{type:"user", agentId:$a, sessionId:$s, message:{role:"user", content:$p}}'
    jq -nc --arg r "$PASS_JSON" --arg a "$1" --arg s "$2" '{type:"assistant", agentId:$a, sessionId:$s, requestedModel:"claude-opus-5-5", effort:"medium", message:{id:"d3", model:"claude-opus-5-5", stop_reason:"end_turn", usage:{input_tokens:3, output_tokens:4}, content:[{type:"text", text:$r}]}}'
  } > "$TMP/transcripts/agent-$1.jsonl"
}
mk_tr agentd3 sess-main
SIM_SESSION=sess-other sim_stop agentd3 feature-validator
[ "$(req_get '.state')" = DISPATCHING ] && [ ! -e "$ND/results/$idp.capture.json" ] || fail "D3: 다른 메인 세션의 SubagentStop 이 결과를 캡처함"
sim_stop agentd3 feature-reviewer
[ "$(req_get '.state')" = DISPATCHING ] && [ ! -e "$ND/results/$idp.capture.json" ] || fail "D3: 다른 Agent 종류의 SubagentStop 이 결과를 캡처함"
cp "$TMP/transcripts/agent-agentd3.jsonl" "$TMP/transcripts/agent-agentimp.jsonl"; sim_stop agentimp feature-validator
[ "$(req_get '.state')" = DISPATCHING ] && [ ! -e "$ND/results/$idp.capture.json" ] || fail "D3: 전사의 agent id 와 다른 agent 의 SubagentStop 이 결과를 캡처함"
# 결속되는 종료 이벤트가 PostToolUse 보다 먼저 왔다 → 캡처한다
sim_stop agentd3 feature-validator
[ "$(req_get '.state')" = RESULT_READY ] && [ "$(req_get '.captured_from_state')" = DISPATCHING ] && [ "$(jq -r '.captured_from_state' "$ND/results/$idp.capture.json")" = DISPATCHING ] \
  || fail "D3: PostToolUse 보다 먼저 온 SubagentStop 이 캡처되지 않음: state $(req_get '.state')"
capsum="$(shasum "$ND/results/$idp.capture.json" | cut -d' ' -f1)"
# 늦은 PostToolUse: RESULT_READY 를 덮어쓰지 않는다(보조 기록만, 처음 한 번)
SIM_PRE_TOOL=Agent; SIM_TU="$tu2"; SIM_OUT="$(jq -nc --arg p "$d3_prompt" '{hookSpecificOutput:{updatedInput:{subagent_type:"feature-validator", prompt:$p}}}')"
sim_post agentd3 claude-opus-5-5
[ "$(req_get '.state')" = RESULT_READY ] && [ "$(req_get '.post_tool.late')" = true ] && [ "$(req_get '.post_tool.agent_id')" = agentd3 ] && [ "$(req_get '.dispatched_at // ""')" = "" ] \
  || fail "D3: 늦은 PostToolUse 가 RESULT_READY 를 덮어썼거나 보조 기록이 없음: state $(req_get '.state')"
reqsum="$(shasum "$(req_file)" | cut -d' ' -f1)"
sim_post agentother claude-opus-5-5   # 중복(내용이 다른) 늦은 이벤트
[ "$(shasum "$(req_file)" | cut -d' ' -f1)" = "$reqsum" ] && [ "$(shasum "$ND/results/$idp.capture.json" | cut -d' ' -f1)" = "$capsum" ] || fail "D3: 중복된 늦은 PostToolUse 가 요청·캡처를 다시 씀"
role_ro VALIDATOR "validator-design-13-c" "design-validator-round-13" "$TMP/d2.json"
[ "$RC" = 0 ] && [ "$(jq -r '.verdict' "$TMP/d2.json")" = PASS ] || { cat "$TMP/last.log"; fail "D3: SubagentStop 선도착 요청의 결과 수용 실패 (rc $RC)"; }
SIM_PRE_TOOL=Agent sim_post agentd3 claude-opus-5-5
[ "$(jq -r '.state' "$ND/requests/$idp.json")" = CONSUMED ] || fail "D3: 소비된 요청을 늦은 PostToolUse 가 바꿈"
# 늦은 PostToolUse 의 agent id 가 전사와 다르면 수용하지 않는다(기존 결속 검사)
role_ro VALIDATOR "validator-design-14-a" "design-validator-round-14" "$TMP/d3.json"; [ "$RC" = 42 ] || fail "D3: 요청 발행 실패"
SIM_POST=0 SIM_AGENT_ID=agentd4 sim_agent "$PASS_JSON" || fail "D3: dispatch 실패"
[ "$(req_get '.state')" = RESULT_READY ] || fail "D3: PostToolUse 없는 완료가 캡처되지 않음"
sim_post agentwrong claude-opus-5-5
role_ro VALIDATOR "validator-design-14-b" "design-validator-round-14" "$TMP/d3.json"
[ "$RC" = 43 ] && grep -q NATIVE_SESSION_MISMATCH "$TMP/last.log" || { cat "$TMP/last.log"; fail "D3: PostToolUse 의 agent id 와 전사의 agent id 가 다른 결과가 수용됨 (rc $RC)"; }
( bash "$BR" discard "$(req_get '.request_id')" ) >/dev/null 2>&1 || fail "D3: discard 실패"
# 정상 순서 + PostToolUse 중복: DISPATCHED 는 한 번만 기록된다. 실행이 확인된 뒤에는 다른 agent 의 종료가 캡처되지 않는다.
role_ro VALIDATOR "validator-design-14-c" "design-validator-round-14" "$TMP/d3.json"; [ "$RC" = 42 ] || fail "D3: 요청 재발행 실패"
idq="$(req_get '.request_id')"; sim_pre; sim_post agentd5 claude-opus-5-5
[ "$(req_get '.state')" = DISPATCHED ] || fail "D3: 정상 PostToolUse 가 DISPATCHED 로 올리지 않음"
reqsum="$(shasum "$(req_file)" | cut -d' ' -f1)"; sim_post agentd5 claude-opus-5-5; sim_post agentd6 claude-opus-5-5
[ "$(shasum "$(req_file)" | cut -d' ' -f1)" = "$reqsum" ] || fail "D3: 중복 PostToolUse 가 DISPATCHED 요청을 다시 씀"
( bash "$BR" redispatch "$idq" ) >/dev/null 2>&1 && fail "D3: 실행이 확인된(DISPATCHED) 요청에 redispatch 가 통과함"
d3_prompt="$(cat "$(req_get '.prompt_path')")"; mk_tr agentd6 sess-main; sim_stop agentd6 feature-validator
[ "$(req_get '.state')" = DISPATCHED ] || fail "D3: PostToolUse 가 결속한 agent 와 다른 agent 의 SubagentStop 이 캡처됨"
mk_tr agentd5 sess-main; sim_stop agentd5 feature-validator
role_ro VALIDATOR "validator-design-14-d" "design-validator-round-14" "$TMP/d3.json"; [ "$RC" = 0 ] || { cat "$TMP/last.log"; fail "D3: 정상 순서 결과 수용 실패 (rc $RC)"; }
SIM_POST=late; role_ro VALIDATOR "validator-design-15-a" "design-validator-round-15" "$TMP/d3b.json"; sim_agent "$PASS_JSON" || fail "D3: late dispatch 실패"
role_ro VALIDATOR "validator-design-15-b" "design-validator-round-15" "$TMP/d3b.json"; [ "$RC" = 0 ] || fail "D3: PostToolUse 지연 요청 수용 실패 (rc $RC)"
SIM_POST=dup; role_ro VALIDATOR "validator-design-16-a" "design-validator-round-16" "$TMP/d3c.json"; sim_agent "$PASS_JSON" || fail "D3: dup dispatch 실패"
role_ro VALIDATOR "validator-design-16-b" "design-validator-round-16" "$TMP/d3c.json"; [ "$RC" = 0 ] || fail "D3: PostToolUse 중복 요청 수용 실패 (rc $RC)"
unset SIM_POST
# PREPARED 요청(dispatch 를 검증한 적 없음)의 종료 이벤트는 캡처하지 않는다
role_ro VALIDATOR "validator-design-17-a" "design-validator-round-17" "$TMP/d3d.json"; [ "$RC" = 42 ] || fail "D3: 요청 발행 실패"
d3_prompt="$(cat "$(req_get '.prompt_path')")"; mk_tr agentd7 sess-main; sim_stop agentd7 feature-validator
[ "$(req_get '.state')" = PREPARED ] && [ ! -e "$ND/results/$(req_get '.request_id').capture.json" ] || fail "D3: PREPARED 요청에 SubagentStop 이 결과를 캡처함"
reset_native
pass "D3. SubagentStop 선도착 → 전사 결속(세션·agent 종류·agent id) 통과분만 캡처, 늦은·중복 PostToolUse 는 RESULT_READY 를 덮어쓰지 않음"

# ================= D4 SendMessage 재개의 실행 확인 =================
role_ro REVIEWER "reviewer-b01" "impl-review-b01-round-01" "$TMP/d4.json"; [ "$RC" = 42 ] || fail "D4: 요청 발행 실패"
sim_agent "$PASS_JSON" || fail "D4: NEW dispatch 실패"; d4_agent="$SIM_LAST_AGENT"
role_ro REVIEWER "reviewer-b01" "impl-review-b01-round-01" "$TMP/d4.json"; [ "$RC" = 0 ] || fail "D4: R1 수용 실패"; role_accept REVIEWER reviewer-b01 || fail "D4: accept 실패"
role_ro REVIEWER "reviewer-b01" "impl-review-b01-round-02" "$TMP/d4b.json"; [ "$RC" = 42 ] && [ "$(req_get '.session_intent')" = RESUME ] || fail "D4: 재개 요청 발행 실패"
idr="$(req_get '.request_id')"; sim_pre; tur="$SIM_TU"
[ "$(req_get '.state')" = DISPATCHING ] && [ "$(req_get '.dispatch_attempt.tool')" = SendMessage ] || fail "D4: SendMessage PreToolUse 가 시도를 기록하지 않음"
# success:true 만으로는 재개의 증거가 아니다(다른 세션으로 보낸 메시지의 응답 모양)
SIM_POST_RESPONSE='{"success":true,"message":"queued in another session inbox","msg_id":"x"}' sim_post "$d4_agent"
[ "$(req_get '.state')" = DISPATCHING ] && [ "$(req_get '.post_tool.launch_confirmed')" = false ] || fail "D4: resumedAgentId 없는 success 응답이 실행 확인으로 처리됨"
SIM_POST_RESPONSE='{"success":true,"message":"Resuming agent","resumedAgentId":"someone-else"}' sim_post "$d4_agent"
[ "$(req_get '.state')" = DISPATCHING ] || fail "D4: 다른 Agent 를 재개한 응답이 실행 확인으로 처리됨"
# 다른 훅이 SendMessage 를 거부했다 → 43, 명시적 redispatch 뒤에도 같은 Agent 의 재개다(fresh 로 바뀌지 않는다)
( bash "$BR" redispatch "$idr" ) >/dev/null 2>&1 && fail "D4: 거부 확인 없는 재개 요청에 redispatch 가 통과함"
sim_main_result "$tur" permission-rule 'PreToolUse:SendMessage hook error: blocked by another hook'
role_ro REVIEWER "reviewer-b01" "impl-review-b01-round-02" "$TMP/d4b.json"; [ "$RC" = 43 ] && grep -q NATIVE_DISPATCH_DENIED "$TMP/last.log" || { cat "$TMP/last.log"; fail "D4: 거부된 SendMessage 가 43 으로 올라오지 않음 (rc $RC)"; }
( bash "$BR" redispatch "$idr" ) > "$TMP/last.log" 2>&1 || { cat "$TMP/last.log"; fail "D4: redispatch 실패"; }
[ "$(req_get '.state')" = PREPARED ] && [ "$(req_get '.session_intent')" = RESUME ] && [ "$(req_get '.resume_agent_id')" = "$d4_agent" ] && [ "$(req_get '.post_tool // "none"')" = none ] || fail "D4: redispatch 뒤 재개 대상이 바뀜(묵시적 fresh)"
SIM_TOOL=Agent sim_pre; [ "$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] && [ "$(req_get '.state')" = PREPARED ] || fail "D4: 거부 뒤 재개 요청을 새 Agent 로 여는 것이 거부되지 않음"
sim_pre; sim_post "$d4_agent"
[ "$(req_get '.state')" = DISPATCHED ] && [ "$(req_get '.post_tool.status')" = resumed ] && [ "$(req_get '.dispatched_agent_id')" = "$d4_agent" ] || fail "D4: 정상 재개 응답(resumedAgentId 일치)이 DISPATCHED 로 올리지 않음: $(req_get '.state')"
( bash "$BR" discard "$idr" ) >/dev/null 2>&1 || fail "D4: discard 실패"
role_ro REVIEWER "reviewer-b01" "impl-review-b01-round-02" "$TMP/d4b.json"; [ "$RC" = 42 ] && [ "$(req_get '.session_intent')" = RESUME ] && [ "$(req_get '.resume_agent_id')" = "$d4_agent" ] || fail "D4: discard 뒤 새 요청이 같은 Agent 의 재개가 아님(세션 보존 실패)"
sim_agent "$PASS_JSON" || fail "D4: 재개 dispatch 실패"
role_ro REVIEWER "reviewer-b01" "impl-review-b01-round-02" "$TMP/d4b.json"; [ "$RC" = 0 ] || { cat "$TMP/last.log"; fail "D4: 재개 결과 수용 실패 (rc $RC)"; }
[ ! -s "$CLI_LOG" ] || fail "D4: CLI 가 호출됨"
reset_native
pass "D4. SendMessage 재개 — success 만으로는 미확인, resumedAgentId 가 결속된 Agent 일 때만 DISPATCHED, 거부·정리 뒤에도 같은 Agent 재개(세션 원장 보존)"

# ================= R28 스킬·프롬프트·입력 지문 변경 뒤의 pending 결과 =================
role_ro VALIDATOR "validator-design-01-a" "design-validator-round-01" "$TMP/v6.json"; [ "$RC" = 42 ] || fail "R28: 요청 발행 실패"
sim_agent "$PASS_JSON" || fail "R28: dispatch 실패"
cp .claude/skills/feature/prompts/fixer.md "$TMP/fixer.md.keep"; echo "<!-- changed -->" >> .claude/skills/feature/prompts/fixer.md
role_ro VALIDATOR "validator-design-01-b" "design-validator-round-01" "$TMP/v6.json"
[ "$RC" = 43 ] && grep -q NATIVE_STALE_REQUEST "$TMP/last.log" && [ ! -e "$TMP/v6.json" ] || { cat "$TMP/last.log"; fail "R28: 스킬 변경 뒤 낡은 결과가 수용됨 (rc $RC)"; }
cp "$TMP/fixer.md.keep" .claude/skills/feature/prompts/fixer.md; reset_native
RC=0; ( set -e; source "$LOADER"; NATIVE_INPUT_FP=fp-1 run_readonly_json_role VALIDATOR k "design-validator-round-01" "$SCHEMA" "$TMP/v6.json" "smoke prompt" "" ) > "$TMP/last.log" 2>&1 || RC=$?
sim_agent "$PASS_JSON" || fail "R28: dispatch 실패"
RC=0; ( set -e; source "$LOADER"; NATIVE_INPUT_FP=fp-2 run_readonly_json_role VALIDATOR k "design-validator-round-01" "$SCHEMA" "$TMP/v6.json" "smoke prompt" "" ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 43 ] && grep -q '입력 지문' "$TMP/last.log" || { cat "$TMP/last.log"; fail "R28: 입력 지문 변경 뒤 낡은 결과가 수용됨 (rc $RC)"; }
reset_native
pass "R28. 요청 발행 뒤 스킬·프롬프트·입력 지문이 바뀌면 낡은 결과 거부"

# ================= R23 피처 worktree 와 원본 저장소가 다름 =================
mkdir -p "$TMP/origin" && ( cd "$TMP/origin" && git init -q && echo o > o.txt && git add -A && git -c user.email=s@t -c user.name=s commit -qm o ) || fail "R23: 원본 저장소 준비 실패"
export FEATURE_ORIGIN_ROOT="$TMP/origin"
role_ro VALIDATOR "validator-design-01-a" "design-validator-round-01" "$TMP/v7.json"; [ "$RC" = 42 ] || { cat "$TMP/last.log"; fail "R23: 요청 발행 실패"; }
[ "$(req_get '.worktree_root')" = "$(pwd -P)" -o "$(req_get '.worktree_root')" = "$(pwd)" ] && [ -f "$TMP/origin/.claude/agents/feature-validator.md" ] || fail "R23: worktree_root·agent 정의 위치가 틀림"
grep -q "worktree_root $(req_get '.worktree_root')" "$(req_get '.prompt_path')" || fail "R23: payload 가 worktree_root 를 전달하지 않음"
SIM_SIDE="echo wrong >> $TMP/origin/o.txt" sim_agent "$PASS_JSON" || fail "R23: dispatch 실패"
role_ro VALIDATOR "validator-design-01-b" "design-validator-round-01" "$TMP/v7.json"
[ "$RC" = 43 ] && grep -q NATIVE_WORKTREE_CONFUSION "$TMP/last.log" || { cat "$TMP/last.log"; fail "R23: 원본 저장소가 바뀌었는데 결과가 수용됨 (rc $RC)"; }
unset FEATURE_ORIGIN_ROOT; reset_native
pass "R23. Agent 가 worktree 대신 원본 저장소를 고치면 결과 불수용(경로 혼선 중단)"

# ================= R14 R24 합의 루프 종단: 검증자(native) BLOCK → 디자이너(native) → 검증자 PASS =================
LOOP=".claude/skills/feature/scripts/consensus-loop.sh"
loop() { RC=0; FEATURE_LIVE_TEE=1 bash "$LOOP" design > "$TMP/loop.log" 2>&1 || RC=$?; }
loop; [ "$RC" = 42 ] && [ "$(req_get '.role')" = VALIDATOR ] || { cat "$TMP/loop.log"; fail "R24: 합의 루프가 검증자 요청에서 exit 42 로 나오지 않음 (rc $RC)"; }
loop; [ "$RC" = 42 ] && [ "$(req_count)" = 1 ] || fail "R24: 결과 없는 재실행이 새 요청을 만들거나 다른 코드로 끝남 (rc $RC)"
sim_agent "$BLOCK_JSON" || fail "종단: 검증자 dispatch 실패"
loop; [ "$RC" = 42 ] && [ "$(req_get '.role')" = DESIGNER ] && [ "$(req_get '.mode')" = edit ] || { cat "$TMP/loop.log"; fail "종단: BLOCK 뒤 디자이너 요청이 발행되지 않음 (rc $RC)"; }
[ "$(req_get '.pre_state.designer_tree_before')" = "$(req_get '.pre_tree')" ] || fail "종단: 디자이너 호출 전 상태가 요청에 저장되지 않음"
SIM_SIDE='echo revised >> .agent-work/design.md; echo "- [round 1] ACCEPT B-01" >> .agent-work/decisions.md' sim_agent "문서를 수정했다." || fail "종단: 디자이너 dispatch 실패"
loop; [ "$RC" = 42 ] && [ "$(req_get '.role')" = VALIDATOR ] && grep -q 'round 1\] ACCEPT B-01' "$TMP/loop.log" || { cat "$TMP/loop.log"; fail "종단: 디자이너 결과 수용 뒤 Round 2 검증자 요청이 아님 (rc $RC)"; }
grep -q '문서 변경 흔적 감지' "$TMP/loop.log" && fail "종단: native 재실행 pass 가 '호출 중 죽음'으로 오판돼 scope 가드를 건너뜀"
sim_agent "$PASS_JSON" || fail "종단: Round 2 검증자 dispatch 실패"
loop; [ "$RC" = 0 ] && [ "$(jq -r '.status' .agent-work/state.json)" = PASS ] || { cat "$TMP/loop.log"; fail "종단: Round 2 PASS 로 합의가 끝나지 않음 (rc $RC)"; }
[ "$(wc -l < .agent-work/usage.jsonl | tr -d ' ')" = 3 ] && [ ! -s "$CLI_LOG" ] || fail "R01: 합의 3회 호출 중 claude -p/codex CLI 가 불렸거나 usage 행 수가 다름: $(cat "$CLI_LOG")"
[ -f .agent-work/.session-designer-design.native.json ] || fail "종단: 디자이너 stage 세션이 native 원장으로 확정되지 않음"
pass "R24·R01. 합의 루프가 native 요청을 exit 42 로 올리고, 재실행으로 BLOCK→디자이너→PASS 까지 claude -p 0회로 진행"
# R14: 디자이너가 합의 문서 밖 source 를 바꿈
rm -rf .agent-work/consensus-design.json .agent-work/reviews "$ND"; mkdir -p .agent-work/reviews
loop; [ "$RC" = 42 ] || fail "R14: 검증자 요청 실패"; sim_agent "$BLOCK_JSON" || fail "R14: dispatch 실패"
loop; [ "$RC" = 42 ] && [ "$(req_get '.role')" = DESIGNER ] || { cat "$TMP/loop.log"; fail "R14: 디자이너 요청 실패 (rc $RC)"; }
SIM_SIDE='echo revised2 >> .agent-work/design.md; echo hacked >> src/u01.txt' sim_agent "수정했다." || fail "R14: dispatch 실패"
loop; [ "$RC" = 2 ] && grep -q DESIGNER_SCOPE_VIOLATION "$TMP/loop.log" && [ "$(jq -r '.status' .agent-work/state.json)" = DESIGNER_SCOPE_VIOLATION ] \
  || { cat "$TMP/loop.log"; fail "R14: 디자이너의 source 변경이 DESIGNER_SCOPE_VIOLATION 으로 멈추지 않음 (rc $RC)"; }
grep -q hacked src/u01.txt || fail "R14: 변경이 자동 원복됨"
pass "R14. native 디자이너가 합의 문서 밖 source 를 바꾸면 DESIGNER_SCOPE_VIOLATION 유지(자동 원복 없음)"

# ================= S1~S3 단독 복구 명령: 절대 경로 재진입 · worktree 루트 격리 · Agent 정의 미발견 =================
# 제한 시간은 python subprocess 로 건다(macOS 에 timeout 실행 파일이 없을 수 있다). 124 = 제한 시간 초과(무한 재귀·멈춤).
cat > "$TMP/bin/run_to.py" <<'EOS'
import subprocess, sys
try:
    r = subprocess.run(sys.argv[3:], cwd=sys.argv[2], timeout=float(sys.argv[1]), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    sys.stdout.buffer.write(r.stdout); sys.exit(r.returncode)
except subprocess.TimeoutExpired as e:
    sys.stdout.buffer.write(e.stdout or b""); print("RUN_TO_TIMEOUT"); sys.exit(124)
EOS
run_to() { # cwd cmd...  → RC, 출력은 $TMP/last.log (FEATURE_PROJECT_ROOT 는 호출자가 env 로 줄 때만 있다)
  local cwd="$1"; shift; RC=0
  env -u FEATURE_PROJECT_ROOT ${RUN_TO_ENV:+"$RUN_TO_ENV"} python3 "$TMP/bin/run_to.py" 30 "$cwd" "$@" > "$TMP/last.log" 2>&1 || RC=$?
}
dir_sum() { ( cd "$1" && find . -type f ! -name '.snapshot-index.*' | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(shasum -a 256 < "$f" | cut -d' ' -f1)" "$f"; done ) | shasum -a 256 | cut -d' ' -f1; }
ABS_BR="$TMP/repo/.claude/skills/feature/scripts/native-agent-bridge.sh"
REPO_PHYS="$(pwd -P)"
unset FEATURE_PROJECT_ROOT FEATURE_ORIGIN_ROOT

# ---- S1 [A] 절대 경로 단독 실행이 끝난다(재진입 없음) ----
reset_native; : > "$CLI_LOG"
git checkout -q -- src/u01.txt   # 앞 사례(R14)가 남긴 source 변경을 걷어 낸다
# source 만 한 호출자는 복구 명령을 실행하지 않는다(위치 인자가 discard 여도)
role_ro VALIDATOR "validator-design-21-a" "design-validator-round-21" "$TMP/s1.json"; [ "$RC" = 42 ] || { cat "$TMP/last.log"; fail "S1: 요청 발행 실패"; }
ids1="$(req_get '.request_id')"
run_to "$TMP/repo" bash -c 'f="$1"; set -- discard "$2"; source "$f"; echo SOURCED-CONFIG' _ "$LOADER" "$ids1"
[ "$RC" = 0 ] && grep -q SOURCED-CONFIG "$TMP/last.log" && [ -f "$ND/pending.json" ] && [ "$(req_get '.state')" = PREPARED ] || { cat "$TMP/last.log"; fail "S1: config.sh 를 source 만 했는데 복구 명령이 실행됨 (rc $RC)"; }
run_to "$TMP/repo" bash -c 'f="$1"; set -- discard "$2"; source "$f"; declare -F native_role_call >/dev/null && echo SOURCED-BRIDGE' _ "$ABS_BR" "$ids1"
[ "$RC" = 0 ] && grep -q SOURCED-BRIDGE "$TMP/last.log" && [ -f "$ND/pending.json" ] || { cat "$TMP/last.log"; fail "S1: 브리지를 source 만 했는데 복구 명령이 실행됨 (rc $RC)"; }
# 조건 불충분(다른 요청 id)은 절대 경로에서도 거부한다
run_to "$TMP/repo" bash "$ABS_BR" discard native-nope
[ "$RC" = 1 ] && grep -q '요청 ID 불일치' "$TMP/last.log" && [ -f "$ND/pending.json" ] || { cat "$TMP/last.log"; fail "S1: 절대 경로 discard 가 다른 요청 id 를 거부하지 않음 (rc $RC)"; }
# 절대 경로 discard 는 제한 시간 안에 exit 0 으로 끝나고 요청을 ABANDONED 로 치운다
run_to "$TMP/repo" bash "$ABS_BR" discard "$ids1"
[ "$RC" = 0 ] && [ ! -e "$ND/pending.json" ] && [ "$(jq -r '.state + "/" + .abandoned_from_state' "$ND/requests/$ids1.json")" = "ABANDONED/PREPARED" ] && [ -f "$ND/abandoned/$ids1.pending.json" ] \
  || { tail -5 "$TMP/last.log"; fail "S1: 절대 경로 discard 가 끝나지 않았거나(124=제한 시간) 요청을 치우지 않음 (rc $RC)"; }
# 상대 경로도 같은 결과
role_ro VALIDATOR "validator-design-21-b" "design-validator-round-21" "$TMP/s1.json"; [ "$RC" = 42 ] || fail "S1: 요청 재발행 실패"
ids1b="$(req_get '.request_id')"
run_to "$TMP/repo" bash "$BR" discard "$ids1b"
[ "$RC" = 0 ] && [ ! -e "$ND/pending.json" ] && [ "$(jq -r '.state' "$ND/requests/$ids1b.json")" = ABANDONED ] || { tail -5 "$TMP/last.log"; fail "S1: 상대 경로 discard 결과가 절대 경로와 다름 (rc $RC)"; }
# 호출 전 tree 가 다르면 절대 경로에서도 거부한다(검증 생략 없음)
role_ro VALIDATOR "validator-design-21-c" "design-validator-round-21" "$TMP/s1.json"; [ "$RC" = 42 ] || fail "S1: 요청 재발행 실패"
ids1c="$(req_get '.request_id')"; echo drift >> src/u01.txt
run_to "$TMP/repo" bash "$ABS_BR" discard "$ids1c"
[ "$RC" = 1 ] && grep -q '호출 전 tree' "$TMP/last.log" && [ -f "$ND/pending.json" ] || { cat "$TMP/last.log"; fail "S1: 작업 트리가 달라졌는데 절대 경로 discard 가 통과함 (rc $RC)"; }
git checkout -q -- src/u01.txt
# 실행 전 거부가 확인된 DISPATCHING 요청의 절대 경로 redispatch: 같은 id·payload·session intent 로 PREPARED. 거부 확인 전에는 거부한다
sim_pre; tus1="$SIM_TU"; psha="$(req_get '.dispatch_sha256')"; pint="$(req_get '.session_intent')"
run_to "$TMP/repo" bash "$ABS_BR" redispatch "$ids1c"
[ "$RC" = 1 ] && grep -q '거부가 확인되지 않았다' "$TMP/last.log" && [ "$(req_get '.state')" = DISPATCHING ] || { cat "$TMP/last.log"; fail "S1: 거부 증거 없는 절대 경로 redispatch 가 통과함 (rc $RC)"; }
sim_main_result "$tus1" permission-rule "$DENY_TEXT"
run_to "$TMP/repo" bash "$ABS_BR" redispatch "$ids1c"
[ "$RC" = 0 ] && [ "$(req_get '.state')" = PREPARED ] && [ "$(req_get '.request_id')" = "$ids1c" ] && [ "$(req_get '.dispatch_sha256')" = "$psha" ] && [ "$(req_get '.session_intent')" = "$pint" ] \
  && [ "$(req_get '.dispatch_history[0].outcome')" = DENIED ] && [ "$(req_count)" = 3 ] \
  || { tail -5 "$TMP/last.log"; fail "S1: 절대 경로 redispatch 가 끝나지 않았거나 같은 요청을 PREPARED 로 되돌리지 않음 (rc $RC, state $(req_get '.state'))"; }
# 저장소를 가리키는 심볼릭 링크 경로로 실행해도 끝난다
ln -s "$TMP/repo" "$TMP/repo-link"
run_to "$TMP/repo-link" bash "$TMP/repo-link/.claude/skills/feature/scripts/native-agent-bridge.sh" discard "$ids1c"
[ "$RC" = 0 ] && [ ! -e "$ND/pending.json" ] || { tail -5 "$TMP/last.log"; fail "S1: 심볼릭 링크 경로의 discard 실패 (rc $RC)"; }
[ ! -s "$CLI_LOG" ] || fail "S1: CLI 가 호출됨: $(cat "$CLI_LOG")"
pass "S1. 단독 discard/redispatch: 절대·상대·심볼릭 링크 경로 모두 제한 시간 안에 종료, 요청 id·호출 전 tree·거부 증거 검사 유지, source 만 한 호출자는 부작용 없음"

# ---- S2 [B] 피처 worktree 와 원본의 .agent-work 격리 ----
reset_native
git worktree add -q "$TMP/wt" -b feature/s2 HEAD || fail "S2: worktree 생성 실패"
mkdir -p "$TMP/wt/.claude/hooks" "$TMP/wt/.agent-work/reviews" && cp "$TMP/repo/.claude/hooks/core_rules.md" "$TMP/wt/.claude/hooks/" || fail "S2: worktree 준비 실패"
WND="$TMP/wt/.agent-work/native-agent"
# 원본과 worktree 에 서로 다른 pending 요청을 둔다(러너의 재바인딩과 같은 값 = worktree 의 git toplevel)
role_ro VALIDATOR "validator-design-22-o" "design-validator-round-22" "$TMP/s2o.json"; [ "$RC" = 42 ] || fail "S2: 원본 요청 발행 실패"
id_origin="$(req_get '.request_id')"
WT_TOP="$(git -C "$TMP/wt" rev-parse --show-toplevel)"
RC=0; ( cd "$TMP/wt" && set -e && FEATURE_PROJECT_ROOT="$WT_TOP" && export FEATURE_PROJECT_ROOT && source "$LOADER" && run_readonly_json_role VALIDATOR "validator-design-22-w" "design-validator-round-22" "$TMP/repo/$SCHEMA" "$TMP/s2w.json" "smoke prompt wt" "" ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 42 ] && [ -f "$WND/pending.json" ] || { cat "$TMP/last.log"; fail "S2: worktree 요청 발행 실패 (rc $RC)"; }
id_wt="$(jq -r '.request_id' "$WND/pending.json")"
[ "$id_wt" != "$id_origin" ] && [ "$(jq -r '.worktree_root' "$WND/requests/$id_wt.json")" = "$WT_TOP" ] || fail "S2: 두 요청이 구분되지 않음"
# agent 정의는 원본(메인 세션이 읽는 곳)에만 있다 — worktree 에 만들지 않는다
[ -f "$TMP/repo/.claude/agents/feature-validator.md" ] && [ ! -e "$TMP/wt/.claude/agents" ] || fail "S2: agent 정의 위치가 원본이 아님"
[ "$(jq -r '.agent_definition_path' "$WND/requests/$id_wt.json")" -ef "$TMP/repo/.claude/agents/feature-validator.md" ] || fail "S2: worktree 요청의 agent 정의 경로가 원본이 아님: $(jq -r '.agent_definition_path' "$WND/requests/$id_wt.json")"
sum_origin="$(dir_sum "$TMP/repo/.agent-work")"; sum_wt="$(dir_sum "$TMP/wt/.agent-work")"
# FEATURE_PROJECT_ROOT 없이 worktree 루트에서 절대 경로로: 원본 id 는 '요청 ID 불일치'로 거부, 원본·worktree 모두 그대로
run_to "$TMP/wt" bash "$ABS_BR" discard "$id_origin"
[ "$RC" = 1 ] && grep -q '요청 ID 불일치' "$TMP/last.log" && grep -q "$id_wt" "$TMP/last.log" || { cat "$TMP/last.log"; fail "S2: worktree 에서 원본 id 를 준 discard 가 요청 ID 불일치로 거부되지 않음 (rc $RC)"; }
[ "$(dir_sum "$TMP/repo/.agent-work")" = "$sum_origin" ] && [ "$(dir_sum "$TMP/wt/.agent-work")" = "$sum_wt" ] || fail "S2: 거부된 discard 가 .agent-work 를 바꿈"
# 무관한 저장소·git 밖에서는 멈춘다(어느 .agent-work 도 건드리지 않는다)
run_to "$TMP/origin" bash "$ABS_BR" discard "$id_origin"
[ "$RC" = 1 ] && grep -q 'worktree 가 아니다' "$TMP/last.log" && [ ! -e "$TMP/origin/.agent-work" ] || { cat "$TMP/last.log"; fail "S2: 무관한 저장소에서 실행한 discard 가 명시적으로 멈추지 않음 (rc $RC)"; }
run_to "$TMP/bin" bash "$ABS_BR" discard "$id_origin"
[ "$RC" = 1 ] && grep -q 'git working tree 안이 아니다' "$TMP/last.log" || { cat "$TMP/last.log"; fail "S2: git 밖에서 실행한 discard 가 설치 위치로 넘어감 (rc $RC)"; }
[ "$(dir_sum "$TMP/repo/.agent-work")" = "$sum_origin" ] && [ "$(dir_sum "$TMP/wt/.agent-work")" = "$sum_wt" ] || fail "S2: 거부된 실행이 .agent-work 를 바꿈"
# worktree 를 가리키는 심볼릭 링크 경로에서 worktree id: worktree 요청만 치워지고 원본은 byte 단위로 그대로
ln -s "$TMP/wt" "$TMP/wt-link"
run_to "$TMP/wt-link" bash "$ABS_BR" discard "$id_wt"
[ "$RC" = 0 ] && [ ! -e "$WND/pending.json" ] && [ "$(jq -r '.state' "$WND/requests/$id_wt.json")" = ABANDONED ] || { cat "$TMP/last.log"; fail "S2: worktree 루트에서 worktree 요청의 discard 실패 (rc $RC)"; }
[ "$(dir_sum "$TMP/repo/.agent-work")" = "$sum_origin" ] && [ "$(jq -r '.request_id' "$ND/pending.json")" = "$id_origin" ] && [ "$(req_get '.state')" = PREPARED ] || fail "S2: worktree 의 discard 가 원본 .agent-work 를 바꿈"
# 명시한 FEATURE_PROJECT_ROOT 가 현재 디렉터리보다 우선한다(worktree 에서 실행해도 원본 요청을 다룬다)
RUN_TO_ENV="FEATURE_PROJECT_ROOT=$TMP/repo" run_to "$TMP/wt" bash "$ABS_BR" discard "$id_wt"
[ "$RC" = 1 ] && grep -q '요청 ID 불일치' "$TMP/last.log" && grep -q "$id_origin" "$TMP/last.log" || { cat "$TMP/last.log"; fail "S2: 명시한 FEATURE_PROJECT_ROOT 가 우선하지 않음 (rc $RC)"; }
RUN_TO_ENV="FEATURE_PROJECT_ROOT=$TMP/repo" run_to "$TMP/wt" bash "$ABS_BR" discard "$id_origin"
[ "$RC" = 0 ] && [ ! -e "$ND/pending.json" ] && [ "$(jq -r '.state' "$ND/requests/$id_origin.json")" = ABANDONED ] || { cat "$TMP/last.log"; fail "S2: 명시한 FEATURE_PROJECT_ROOT 의 요청을 치우지 못함 (rc $RC)"; }
# 상대 경로 FEATURE_PROJECT_ROOT 는 실행한 디렉터리 기준의 절대 경로로 확정된다(cd 뒤에 <루트>/<상대 경로>/.agent-work 를 보지 않는다)
role_ro VALIDATOR "validator-design-22-r" "design-validator-round-22" "$TMP/s2r.json"; [ "$RC" = 42 ] || fail "S2: 원본 요청 재발행 실패"
id_rel="$(req_get '.request_id')"
RUN_TO_ENV="FEATURE_PROJECT_ROOT=repo" run_to "$TMP" bash "$ABS_BR" discard native-nope
[ "$RC" = 1 ] && grep -q "요청 ID 불일치: 프로젝트 루트 $(git -C "$TMP/repo" rev-parse --show-toplevel) 의 pending 요청은 $id_rel" "$TMP/last.log" \
  || { cat "$TMP/last.log"; fail "S2: 상대 경로 FEATURE_PROJECT_ROOT 가 절대 경로로 확정되지 않음 (rc $RC)"; }
RUN_TO_ENV="FEATURE_PROJECT_ROOT=repo" run_to "$TMP" bash "$ABS_BR" discard "$id_rel"
[ "$RC" = 0 ] && [ ! -e "$ND/pending.json" ] && [ "$(jq -r '.state' "$ND/requests/$id_rel.json")" = ABANDONED ] && [ ! -e "$TMP/repo/repo" ] \
  || { cat "$TMP/last.log"; fail "S2: 상대 경로 FEATURE_PROJECT_ROOT 의 요청을 치우지 못함 (rc $RC)"; }
RUN_TO_ENV="FEATURE_PROJECT_ROOT=../repo" run_to "$TMP/bin" bash "$ABS_BR" discard "$id_rel"
[ "$RC" = 1 ] && grep -q "pending native 요청이 없다: .* (프로젝트 루트 $(git -C "$TMP/repo" rev-parse --show-toplevel) " "$TMP/last.log" || { cat "$TMP/last.log"; fail "S2: '../' 상대 경로 FEATURE_PROJECT_ROOT 가 절대 경로로 확정되지 않음 (rc $RC)"; }
RUN_TO_ENV="FEATURE_PROJECT_ROOT=$TMP/bin" run_to "$TMP/wt" bash "$ABS_BR" discard "$id_origin"
[ "$RC" = 1 ] && grep -q 'git working tree 의 루트가 아니다' "$TMP/last.log" || { cat "$TMP/last.log"; fail "S2: 잘못된 FEATURE_PROJECT_ROOT 가 거부되지 않음 (rc $RC)"; }
# 원본 저장소에서 실행한 종전 동작(상대 경로, 변수 없음)은 그대로다 — S1 과 R11 이 확인한다
git worktree remove --force "$TMP/wt" >/dev/null 2>&1 || true
pass "S2. 단독 복구의 프로젝트 루트: worktree 루트에서 절대 경로 실행은 그 worktree 의 요청만 다룸(원본 byte 불변), 원본 id 는 요청 ID 불일치, 무관한 저장소·git 밖은 중단, 명시한 FEATURE_PROJECT_ROOT 우선(상대 경로는 절대 경로로 확정), agent 정의는 원본"

# ---- S3 [C] "Agent type … not found" 는 거부 종류가 함께 있어도 UNKNOWN ----
reset_native; : > "$CLI_LOG"; : > "$MAIN_TR"
mv .claude/agents/feature-validator.md "$TMP/s3.def.moved" || fail "S3: 정의 파일 준비 실패"   # 이번 요청이 정의를 새로 쓰게 한다
role_ro VALIDATOR "validator-design-23-a" "design-validator-round-23" "$TMP/s3.json"; [ "$RC" = 42 ] || fail "S3: 요청 발행 실패"
ids3="$(req_get '.request_id')"
# PREPARED 안내: 정의를 이번 실행이 새로 썼다(CLAUDE_PID 없음 — 등록 증거 게이트가 판정하지 않은 경로) — 무조건 재전송 문장이 없고 state 별 안내가 있다:
# dispatch 전이면 재시작 뒤 그 요청을 한 번(PREPARED 유지), not found 로 이미 돌아왔으면 DISPATCHING(실행 여부 불명) — 다시 보내지 않는다
grep -q 'agent 정의 파일' "$TMP/last.log" && grep -q '러너가 메인 Claude Code 프로세스(CLAUDE_PID)를 확인하지 못해' "$TMP/last.log" \
  && grep -q '요청은 PREPARED 그대로 남고, 재시작한 세션에서 이 dispatch 를 한 번 보낸다' "$TMP/last.log" && grep -q '(DISPATCHING) 실행 여부 불명으로 남는다 — 세션을 재시작한 뒤에도 다시 보내지 않고' "$TMP/last.log" \
  || { cat "$TMP/last.log"; fail "S3: PREPARED 안내에 state 별 not found 복구 안내가 없음"; }
grep -q '같은 dispatch 를 다시 보낸다' "$TMP/last.log" && fail "S3: 런타임 출력에 무조건 재전송 안내가 남아 있음"
grep -q '같은 dispatch 를 다시 보낸다' .claude/skills/feature/references/native-agent.md && fail "S3: references/native-agent.md 에 무조건 재전송 안내가 남아 있음"
sim_pre; tus3="$SIM_TU"; [ "$(req_get '.state')" = DISPATCHING ] || fail "S3: DISPATCHING 이 아님"
sim_main_result "$tus3" permission-rule "Agent type 'feature-validator' not found. Available agents: general-purpose"
role_ro VALIDATOR "validator-design-23-b" "design-validator-round-23" "$TMP/s3.json"
[ "$RC" = 42 ] && [ "$(req_get '.state')" = DISPATCHING ] && [ "$(req_count)" = 1 ] && grep -q 'Agent 정의 미발견' "$TMP/last.log" && grep -q 'UNKNOWN' "$TMP/last.log" \
  && ! grep -q NATIVE_DISPATCH_DENIED "$TMP/last.log" && grep -q '다시 보내지 않는다' "$TMP/last.log" \
  || { cat "$TMP/last.log"; fail "S3: not found + 거부 종류가 UNKNOWN(42, DISPATCHING 유지)이 아님 (rc $RC, state $(req_get '.state'), 요청 $(req_count)개)"; }
run_to "$TMP/repo" bash "$ABS_BR" redispatch "$ids3"
[ "$RC" = 1 ] && grep -q '거부가 확인되지 않았다(UNKNOWN' "$TMP/last.log" && [ "$(req_get '.state')" = DISPATCHING ] || { cat "$TMP/last.log"; fail "S3: not found 요청의 redispatch 가 거부되지 않음 (rc $RC)"; }
sim_pre
[ "$(printf '%s' "$SIM_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] && [ "$(req_get '.dispatch_attempt.tool_use_id')" = "$tus3" ] || fail "S3: DISPATCHING 요청의 두 번째 dispatch 가 거부되지 않음"
[ ! -s "$CLI_LOG" ] && [ ! -e .agent-work/.session-validator-design-23-a.native.json ] || fail "S3: CLI fallback 또는 새 Agent 세션이 생김"
# 따옴표·agent 이름이 달라도 같은 판정이다(레코드 단위 오류 필드만 있어도)
evid() { ( set -e; source "$LOADER"; native_dispatch_evidence; printf '%s/%s' "$NATIVE_EVID" "$NATIVE_EVID_REASON" ); }
: > "$MAIN_TR"
jq -nc --arg tu "$tus3" '{type:"user", sessionId:"sess-main", toolDenialKind:"user-rejected", toolUseResult:"Error: Agent type \"my-custom-agent\" not found", message:{role:"user", content:[{type:"tool_result", is_error:true, tool_use_id:$tu, content:"tool failed"}]}}' >> "$MAIN_TR"
[ "$(evid)" = "UNKNOWN/AGENT_TYPE_NOT_FOUND" ] || fail "S3: 레코드 오류 필드의 not found 가 UNKNOWN 이 아님: $(evid)"
# 다른 tool_use_id 의 not found 는 영향이 없다 — 이 호출의 알려진 거부는 DENIED 그대로(다른 레코드)
: > "$MAIN_TR"
sim_main_result "toolu_other_1" permission-rule "Agent type 'feature-validator' not found"
sim_main_result "$tus3" permission-rule "$DENY_TEXT"
[ "$(evid)" = "DENIED/" ] || fail "S3: 다른 tool_use_id 의 not found 가 이 호출의 판정을 바꿈: $(evid)"
: > "$MAIN_TR"
jq -nc --arg tu "$tus3" --arg t "$DENY_TEXT" '{type:"user", sessionId:"sess-main", toolDenialKind:"permission-rule", toolUseResult:"Error: Agent type x not found",
  message:{role:"user", content:[{type:"tool_result", is_error:true, tool_use_id:"toolu_other_2", content:"Agent type x not found"}, {type:"tool_result", is_error:true, tool_use_id:$tu, content:$t}]}}' >> "$MAIN_TR"
[ "$(evid)" = "UNKNOWN/" ] || fail "S3: tool_result 가 여럿인 레코드의 레코드 단위 거부 정보를 이 호출의 거부 증거로 씀(다른 tool_result 의 not found 문구는 무영향이어야 함): $(evid)"
# 다른 도구의 거부가 같은 레코드에 있고 이 Agent 호출은 실행 뒤 오류다 — 레코드 단위 거부 정보는 이 호출에 결속되지 않으므로 DENIED 가 아니다(재전송 불가)
: > "$MAIN_TR"
jq -nc --arg tu "$tus3" --arg t "$DENY_TEXT" '{type:"user", sessionId:"sess-main", toolDenialKind:"permission-rule",
  permissionDecision:{decision:"reject", source:"hook", reasonType:"hook", reasonCode:"hook:PreToolUse"},
  message:{role:"user", content:[{type:"tool_result", is_error:true, tool_use_id:"toolu_other_3", content:$t}, {type:"tool_result", is_error:true, tool_use_id:$tu, content:"Agent crashed after launch"}]}}' >> "$MAIN_TR"
[ "$(evid)" = "UNKNOWN/" ] || fail "S3: 다른 도구의 거부(같은 레코드)를 이 Agent 호출의 거부 증거로 씀: $(evid)"
run_to "$TMP/repo" bash "$ABS_BR" redispatch "$ids3"
[ "$RC" = 1 ] && grep -q '거부가 확인되지 않았다(UNKNOWN' "$TMP/last.log" && grep -q '도구 결과가 2개' "$TMP/last.log" && [ "$(req_get '.state')" = DISPATCHING ] \
  || { cat "$TMP/last.log"; fail "S3: 다른 도구의 거부만 있는 요청의 redispatch 가 거부되지 않음 (rc $RC)"; }
# 이 호출 하나만 담긴 레코드의 알려진 거부는 종전대로 DENIED(43)
: > "$MAIN_TR"
sim_main_result "$tus3" permission-rule "$DENY_TEXT"
[ "$(evid)" = "DENIED/" ] || fail "S3: 단일 tool_result 레코드의 알려진 거부가 DENIED 가 아님: $(evid)"
role_ro VALIDATOR "validator-design-23-c" "design-validator-round-23" "$TMP/s3.json"
[ "$RC" = 43 ] && grep -q NATIVE_DISPATCH_DENIED "$TMP/last.log" && grep -q "cd .* && bash .* redispatch $ids3" "$TMP/last.log" || { cat "$TMP/last.log"; fail "S3: 알려진 다른 훅 거부가 43(DENIED)으로 올라오지 않음 (rc $RC)"; }
# 거부 종류 없는 오류는 UNKNOWN(사유 없음), 성공 결과·캡처 증거는 not found 문구가 있어도 EXECUTED
: > "$MAIN_TR"
jq -nc --arg tu "$tus3" '{type:"user", sessionId:"sess-main", message:{role:"user", content:[{type:"tool_result", is_error:true, tool_use_id:$tu, content:"Agent crashed after launch"}]}}' >> "$MAIN_TR"
[ "$(evid)" = "UNKNOWN/" ] || fail "S3: 거부 종류 없는 오류가 UNKNOWN 이 아님: $(evid)"
: > "$MAIN_TR"
sim_main_result "$tus3" permission-rule "Agent type 'feature-validator' not found"
mkdir -p "$ND/results" && echo '{}' > "$ND/results/$ids3.capture.json"
[ "$(evid)" = "EXECUTED/" ] || fail "S3: 캡처 증거가 있는데 not found 문구로 판정이 바뀜: $(evid)"
mv "$ND/results/$ids3.capture.json" "$TMP/s3.capture.moved"
: > "$MAIN_TR"; sim_main_result "$tus3"
[ "$(evid)" = "EXECUTED/" ] || fail "S3: 성공 도구 결과가 EXECUTED 가 아님: $(evid)"
: > "$MAIN_TR"
sim_main_result "$tus3" permission-rule "Agent type 'feature-validator' not found"
run_to "$TMP/repo" bash "$ABS_BR" discard "$ids3"
[ "$RC" = 0 ] && grep -q 'Agent 가 아직 돌고 있을 수 있다' "$TMP/last.log" && [ ! -e "$ND/pending.json" ] || { cat "$TMP/last.log"; fail "S3: not found 요청의 사용자 결정 discard 가 실패했거나 경고가 없음 (rc $RC)"; }
reset_native; : > "$MAIN_TR"
pass "S3. Agent 정의 미발견은 거부 종류가 함께 있어도 UNKNOWN: 대기(42)·DISPATCHING 유지·redispatch 거부·중복 dispatch 0회, 다른 훅 거부는 DENIED 유지, 다른 tool_use_id 의 문구·거부 정보는 무영향(여러 tool_result 레코드의 거부는 UNKNOWN)"

# ================= 러너 연결(정적) =================
RUN=".claude/skills/feature/scripts/feature-run.sh"
[ "$(grep -c 'native_propagate_rc "\$rc"' "$RUN")" = 3 ] && grep -q "0|2|3|42) ;;" "$RUN" || fail "R24: feature-run 이 하위 루프의 42/43 을 세 stage 모두에서 올리지 않음"
echo "[SMOKE OK] native bridge — 워커 호출 지점은 tests/smoke-native-worker.sh"
