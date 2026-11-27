#!/usr/bin/env bash
# =============================================================
# 종단 스모크: Codex App Server + Claude native Agent 혼합 (모델 호출 0회 — 실제 feature-run.sh, 가짜 App Server, 훅 입력·Agent 전사 fixture)
# 파일 경로: tests/smoke-codex-app-server-pipeline.sh
#
# 역할 배치(기본 backend 그대로 — CODEX_BACKEND=app_server, CLAUDE_BACKEND=native):
#   검증자 gpt-6-astra · 워커 gpt-6-luna · 리뷰어 gpt-5.6-sol  → 하네스가 직접 띄운 codex app-server (읽기 전용 / 편집 / 재개 세 형태)
#   수정자 claude-sonnet-5-5 · 디자이너 claude-fable-5-2       → 메인 세션의 native Agent (exit 42 인계)
# 사례
#   E0. design 검증자의 turn/start 응답 전에 서버가 죽음 → ENV_ERROR, 재실행은 key 가 바뀌어도 모델 0회(CODEX_TURN_UNCERTAIN) → reconcile 로 복구 → 재실행이 새 turn 없이 그 결과를 쓴다.
#   E1. design 검증자(PASS — E0 에서 복구) → impl 검증자(PASS) → 워커 unit 01(편집, agents.enabled=false) → 워커 unit 02(같은 thread 재개) → Unit 정적 검사 → targeted test
#       → 리뷰어 Round 1(REQUEST_CHANGES) → native 수정자 요청(exit 42) → 수정자 → 리뷰어 Round 2(같은 thread 재개, APPROVE) → verify → DONE.
#       검증자가 PASS 하므로 디자이너 차례는 없다(native 디자이너는 tests/smoke-native-bridge.sh 가 본다).
#       native 요청이 대기 중인 재실행은 Codex turn 을 다시 보내지 않는다. codex exec · claude CLI 는 0회.
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-appserver-pipeline-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks" "$TMP/transcripts" "$TMP/state"
fail() { echo "[SMOKE FAIL] $*" >&2; [ ! -f "$TMP/run.log" ] || tail -30 "$TMP/run.log" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }
trap 'rm -rf "$TMP"' EXIT
command -v node >/dev/null 2>&1 || fail "node 가 없다 — Codex App Server backend 스모크는 Node.js 18+ 가 필요하다"
unset CODEX_APP_GUARD_REVIEWED_SHA256   # 사용자 환경에 등록된 가드 지문이 사례(배포본 지문 하나만 통과)를 흐리지 않게 한다
unset CLAUDE_CODE_SUBAGENT_MODEL_FORCE CLAUDE_CODE_EFFORT_LEVEL NTFY_TOPIC WORKER_SESSION_ROTATE_INPUT_TOKENS FAKE_SCENARIO FAKE_APP_EDIT_CMD
# 메인 Claude Code 프로세스 pid — 이 세션 안에서 돌리면 물려받는다. 남겨 두면 방금 만든 임시 agent 정의가 그 프로세스보다 새것이라 러너의 등록 증거 게이트(NATIVE_AGENT_RESTART_REQUIRED)가 멈춘다. 그 게이트는 tests/smoke-native-agent-definitions.sh 가 본다
unset CLAUDE_PID
export CLAUDE_CODE_SESSION_ID="sess-main" FEATURE_LIVE_TEE=1

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
cp "$PROJECT_SRC/.claude/hooks/feature_native_agent.sh" "$TMP/repo/.claude/hooks/" || fail "훅 복사 실패"
HOOK="$TMP/repo/.claude/hooks/feature_native_agent.sh"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
LOADER="$TMP/repo/.claude/skills/feature/scripts/lib/bootstrap.sh"
RUNTIME_LIB="$TMP/repo/.claude/skills/feature/scripts/lib/runtime.sh"
export CLI_LOG="$TMP/cli.log" MOCK_LOG="$TMP/calls.log" FAKE_LOG="$TMP/fake.log" FAKE_STATE="$TMP/state"; : > "$CLI_LOG"; : > "$MOCK_LOG"; : > "$FAKE_LOG"
V="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$RUNTIME_LIB" | cut -d= -f2 | cut -d' ' -f1)"
RV="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$RUNTIME_LIB" | cut -d= -f2 | cut -d' ' -f1)"
# claude CLI 는 호출을 기록하고 실패하는 stub(불리면 사례가 깨진다). codex 는 가짜 App Server — exec 가 불리면 FAKE_LOG 에 "EXEC" 가 남는다.
printf '%s\n' '#!/usr/bin/env bash' "echo \"claude \$*\" >> \"$CLI_LOG\"; exit 9" > "$TMP/bin/claude"
printf '#!/usr/bin/env bash\nexec node "%s" "$@"\n' "$PROJECT_SRC/tests/fake-codex-app-server.mjs" > "$TMP/bin/codex"
printf '%s\n' '#!/usr/bin/env bash' "echo full-test >> \"$MOCK_LOG\"" > "$TMP/bin/full-test"
chmod +x "$TMP/bin/claude" "$TMP/bin/codex" "$TMP/bin/full-test"
# 새 설치의 기본 backend 를 그대로 쓴다 — CODEX_BACKEND · CLAUDE_BACKEND 줄은 고치지 않는다.
grep -q '^CODEX_BACKEND="app_server"' "$CFG" && grep -q '^CLAUDE_BACKEND="native"' "$CFG" || fail "소스 config.sh 의 기본 backend 가 app_server / native 가 아니다"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"$TMP/bin/full-test\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"true\"|; \
  s|^DESIGN_REVISION_MODEL=.*|DESIGN_REVISION_MODEL=\"claude-fable-5-2\"|; s|^VALIDATOR_MODEL=.*|VALIDATOR_MODEL=\"gpt-6-astra\"|; s|^WORKER_MODEL=.*|WORKER_MODEL=\"gpt-6-luna\"|; \
  s|^REVIEWER_MODEL=.*|REVIEWER_MODEL=\"gpt-5.6-sol\"|; s|^FIXER_MODEL=.*|FIXER_MODEL=\"claude-sonnet-5-5\"|; s|^VALIDATOR_PROFILE=.*|VALIDATOR_PROFILE=\"none\"|; \
  s|^UNIT_CHECK_CMD=.*|UNIT_CHECK_CMD=\"tools/unit-check.sh\"|" "$CFG" && rm -f "$CFG.bak"

cd "$TMP/repo" || exit 1
ROOT="$(pwd)"
git init -q
printf '.agent-work/\n.claude/\n.codex/\n' > .gitignore
# 편집 역할의 필수 훅 게이트: 훅이 부를 스크립트가 작업 루트에 있어야 한다(등록·활성·신뢰 상태는 가짜 서버의 hooks/list 가 돌려준다).
mkdir -p .codex/hooks && cp "$PROJECT_SRC/.codex/hooks/worker_guard.sh" .codex/hooks/worker_guard.sh   # 실제 가드를 쓴다 — 게이트가 선언이 아니라 본문의 지문을 배포본과 대조한다
printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash .codex/hooks/worker_guard.sh"}]}]}}\n' > .codex/hooks.json
mkdir -p src tools && printf 'line 1\nline 2\n' > src/a.txt && printf 'b 1\n' > src/b.txt
cat > tools/unit-check.sh <<EOS
#!/usr/bin/env bash
echo unit-check >> "$MOCK_LOG"
exit 0
EOS
chmod +x tools/unit-check.sh
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
printf '\n## 01\nunit 01 contract\n\n## 02\nunit 02 contract\n' >> .agent-work/implementation.md
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/a.txt","src/b.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
cat > .agent-work/implementation-units.json <<EOF
{"version":1,"units":[{"id":"01-core","title":"core","goal":"unit 01","requirements":["REQ-01"],"scope":{"files":["src/a.txt"],"new_file_roots":[]},"references":["implementation.md#01"],"targeted_test":"echo unit-test >> $MOCK_LOG"},
 {"id":"02-more","title":"more","goal":"unit 02","requirements":["REQ-02"],"scope":{"files":["src/b.txt"],"new_file_roots":[]},"references":["implementation.md#02"],"targeted_test":"echo unit-test >> $MOCK_LOG"}]}
EOF

# 가짜 서버의 turn 순서별 최종 메시지: 1 design 검증자 · 2 impl 검증자 · 3 워커 unit 01 · 4 워커 unit 02 · 5 리뷰어 R1 · 6 리뷰어 R2
printf '{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}' "$V" > "$FAKE_STATE/reply-1.txt"
cp "$FAKE_STATE/reply-1.txt" "$FAKE_STATE/reply-2.txt"
printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}' > "$FAKE_STATE/reply-3.txt"
printf 'echo "worker line" >> src/a.txt\n' > "$FAKE_STATE/edit-3.sh"
cp "$FAKE_STATE/reply-3.txt" "$FAKE_STATE/reply-4.txt"
printf 'echo "worker line 2" >> src/b.txt\n' > "$FAKE_STATE/edit-4.sh"
printf '{"schema_version":%s,"verdict":"REQUEST_CHANGES","issues":[{"id":"R-01","action":"FIX_CODE","category":"CONTRACT_VIOLATION","evidence_type":"DIRECT_MISMATCH","basis_refs":["approach.md:L1"],"code_refs":["src/a.txt:L1-L1"],"reachable_scenario":"","impact":"i","why_blocks_now":"x","required_outcome":"y","origin":"ROUND_1","previous_issue_id":"","fix_ref":"","user_question":"","options":[]}]}' "$RV" > "$FAKE_STATE/reply-5.txt"
printf '{"schema_version":%s,"verdict":"APPROVE","issues":[]}' "$RV" > "$FAKE_STATE/reply-6.txt"

RUN=".claude/skills/feature/scripts/feature-run.sh"
ND="$TMP/repo/.agent-work/native-agent"
RC=0
run() { RC=0; bash "$RUN" > "$TMP/run.log" 2>&1 || RC=$?; }
reason() { jq -r '.reason' .agent-work/run-state.json; }
status() { jq -r '.status' .agent-work/run-state.json; }
req_file() { jq -r '.request_path' "$ND/pending.json"; }
req_get() { jq -r "$1" "$(req_file)"; }
turns() { grep -c '^rpc turn/start ' "$FAKE_LOG" || true; }

# 메인 세션 + Claude Code 흉내(tests/smoke-native-pipeline.sh 의 sim_agent 와 같은 훅 입력·전사 모양 — 신규 Agent 호출만 쓴다)
MAIN_TR="$TMP/transcripts/main-sess-main.jsonl"; : > "$MAIN_TR"
sim_agent() { # report-text   환경: SIM_SIDE(Agent 부작용 명령)
  local req report="$1" out prompt aid tr model effort tu="toolu_sim_1"
  req="$(req_file)"
  out="$(jq -n --arg t "$(jq -r '.agent_definition' "$req")" --arg p "$(jq -r '.dispatch_line' "$req")" --arg tu "$tu" --arg tp "$MAIN_TR" \
    '{hook_event_name:"PreToolUse", session_id:"sess-main", transcript_path:$tp, tool_name:"Agent", tool_use_id:$tu, tool_input:{subagent_type:$t, description:"sim", prompt:$p}}' | "$HOOK")"
  [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" = allow ] || { echo "sim: dispatch 거부됨: $out" >&2; return 1; }
  prompt="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.prompt')"
  aid="agent$RANDOM$RANDOM"; tr="$TMP/transcripts/agent-$aid.jsonl"
  model="$(jq -r '.model' "$req")"; effort="$(jq -r '.effort' "$req")"
  jq -n --arg tu "$tu" --arg a "$aid" --arg m "$model" --argjson i "$(printf '%s' "$out" | jq -c '.hookSpecificOutput.updatedInput')" \
    '{hook_event_name:"PostToolUse", session_id:"sess-main", tool_name:"Agent", tool_use_id:$tu, tool_input:$i, tool_response:{isAsync:true, status:"async_launched", agentId:$a, resolvedModel:$m, canContinueAgent:true}}' | "$HOOK"
  [ "$(jq -r '.state' "$req")" = DISPATCHED ] || { echo "sim: PostToolUse 뒤 state 가 DISPATCHED 가 아님($(jq -r '.state' "$req"))" >&2; return 1; }
  [ -z "${SIM_SIDE:-}" ] || ( eval "$SIM_SIDE" )
  { jq -nc --arg p "$prompt" --arg a "$aid" '{type:"user", agentId:$a, sessionId:"sess-main", message:{role:"user", content:$p}}'
    jq -nc --arg a "$aid" --arg m "$model" --arg e "$effort" --arg r "$report" --arg n "$RANDOM" \
      '{type:"assistant", agentId:$a, sessionId:"sess-main", requestedModel:$m, effort:$e, message:{id:("m-" + $a + "-" + $n), model:$m, stop_reason:"tool_use", usage:{input_tokens:5, cache_read_input_tokens:2000, cache_creation_input_tokens:0, output_tokens:70}, content:[{type:"tool_use", name:"SubagentHandback", input:{message:$r}}]}}'
  } >> "$tr"
  jq -n --arg a "$aid" --arg t "$(jq -r '.agent_definition' "$req")" --arg tp "$tr" \
    '{hook_event_name:"SubagentStop", session_id:"sess-main", agent_id:$a, agent_type:$t, agent_transcript_path:$tp, stop_hook_active:false}' | "$HOOK"
  [ "$(jq -r '.state' "$req")" = RESULT_READY ] || { echo "sim: 캡처되지 않음(state $(jq -r '.state' "$req"))" >&2; return 1; }
}

# ================= E0. 검증자 호출 중 서버 종료 → 재실행 모델 0회 → 조회 복구 =================
# 합의 루프의 검증자는 호출마다 key 가 다르다(validator-<target>-round-NN-<invocation id>). 재실행이 새 key 로 같은 프롬프트를 다시 보내면 안 된다.
RC=0; FAKE_SCENARIO=crash_before_turn_response bash "$RUN" > "$TMP/run.log" 2>&1 || RC=$?
[ "$RC" = 1 ] && [ "$(turns)" -eq 1 ] || fail "E0: 응답 전에 죽은 검증자 호출이 ENV_ERROR(exit 1)가 아님 (rc $RC, turn $(turns))"
run
[ "$RC" = 1 ] && [ "$(turns)" -eq 1 ] && grep -q 'CODEX_TURN_UNCERTAIN' "$TMP/run.log" || fail "E0: 재실행이 검증자 turn 을 다시 보냈거나 다른 사유로 멈춤 (rc $RC, turn $(turns))"
grep '\[SKILL REFERENCE\]' "$TMP/run.log" | grep -q 'references/codex-app-server.md' || fail "E0: 중단 안내([SKILL REFERENCE])에 codex-app-server.md 가 없음"
vrec="$(ls .agent-work/.session-validator-design-round-01-*.codex-turn.json)"; [ "$(printf '%s\n' "$vrec" | wc -l | tr -d ' ')" = 1 ] || fail "E0: 검증자 호출 기록이 1개가 아님: $vrec"
vkey="$(basename "$vrec")"; vkey="${vkey#.session-}"; vkey="${vkey%.codex-turn.json}"
[ "$(bash .claude/skills/feature/scripts/codex-app-server.sh reconcile "$vkey" 2>/dev/null | jq -r .verdict)" = RECOVERED ] || fail "E0: reconcile 이 완료 결과를 복구하지 못함"
[ "$(turns)" -eq 1 ] || fail "E0: reconcile 이 새 turn 을 보냈다"
pass "E0. 검증자 turn/start 응답 소실 → ENV_ERROR, key 가 바뀐 재실행도 모델 0회, reconcile 로 복구(새 turn 없음)"

# ================= E1. Codex App Server(검증자·워커·리뷰어) + native 수정자 종단 =================
# 1차 실행: Codex 역할은 Shell 이 직접 실행하므로 한 번의 실행으로 design 검증(E0 에서 복구한 결과 재사용) → impl 검증 → 워커 unit 2개 → 검사 → 리뷰어 Round 1 까지 가고,
# native 수정자 요청에서 exit 42 로 돌아온다.
run
[ "$RC" = 42 ] || fail "E1: 1차 실행이 native 수정자 요청(exit 42)에서 멈추지 않음 (rc $RC, $(status) / $(reason))"
[ "$(req_get '.slot')" = "FIXER||impl-fix-a01-round-01" ] && [ "$(req_get '.session_intent')" = NEW ] || fail "E1: 대기 중인 요청이 수정자가 아님: $(req_get '.slot')"
[ "$(turns)" -eq 5 ] || fail "E1: 여기까지의 Codex turn 이 5회(design 검증자 1[E0, 재사용] · impl 검증자 1 · 워커 2 · 리뷰어 1)가 아님: $(turns) — $(grep '^rpc turn/start' "$FAKE_LOG")"
[ "$(grep -c '^rpc thread/start ' "$FAKE_LOG")" -eq 4 ] || fail "E1: 새 thread 가 4개(검증자 2·워커 1·리뷰어 1)가 아님: $(grep '^rpc thread/' "$FAKE_LOG")"
# 워커 unit 02 는 unit 01 의 thread 를 재개한다(Feature 당 단일 워커 세션) — 편집 sandbox·모델, 그리고 사용량 기준도 직전 호출 기록에서 이어진다
[ "$(grep -c '^rpc thread/resume ' "$FAKE_LOG")" -eq 1 ] && grep -q '^rpc thread/resume thread=thr-3 model=gpt-6-luna sandbox=workspace-write approval=never excludeTurns=true' "$FAKE_LOG" \
  || fail "E1: 워커 unit 02 가 unit 01 의 thread 를 재개하지 않음: $(grep '^rpc thread/resume' "$FAKE_LOG")"
grep '^rpc turn/start ' "$FAKE_LOG" | sed -n 4p | grep -q 'thread=thr-3 turn=turn-4 ' || fail "E1: 워커 두 번째 turn 이 같은 thread 가 아님"
grep -q 'worker line' src/a.txt && grep -q 'worker line 2' src/b.txt || fail "E1: 워커(App Server 편집 역할)의 변경이 작업 트리에 없음"
[ "$(grep -c '^unit-check$' "$MOCK_LOG")" -ge 2 ] && [ "$(grep -c '^unit-test$' "$MOCK_LOG")" -eq 2 ] || fail "E1: Unit 정적 검사·targeted test 가 unit 마다 돌지 않음: $(cat "$MOCK_LOG")"# 역할별 프로세스 정책: 워커만 workspace-write + agents.enabled=false, 검증자·리뷰어는 read-only
[ "$(grep -c '^spawn .*agents.enabled=false' "$FAKE_LOG")" -eq 2 ] && ! grep '^spawn .*agents.enabled=false' "$FAKE_LOG" | grep -vq 'sandbox_mode="workspace-write" .*model="gpt-6-luna"' \
  || fail "E1: 워커 프로세스 정책 불일치(신규·재개 두 호출 모두 workspace-write + agents.enabled=false 여야 한다): $(grep '^spawn' "$FAKE_LOG")"
[ "$(grep -c '^spawn app-server -c sandbox_mode="read-only" -c approval_policy="never" -c model=' "$FAKE_LOG")" -eq 3 ] || fail "E1: 검증자·리뷰어가 read-only 프로세스가 아님"
grep '^rpc thread/start ' "$FAKE_LOG" | grep -vq "cwd=$ROOT\$" && fail "E1: thread 의 cwd 가 작업 루트가 아님: $(grep '^rpc thread/start' "$FAKE_LOG")"
jq -e '.backend=="codex_app_server" and .cli=="codex" and .session_bound==true' .agent-work/worker-session.json >/dev/null || fail "E1: 워커 저널이 App Server backend·결속이 아님: $(cat .agent-work/worker-session.json)"
jq -e '.backend=="app_server" and .role=="WORKER" and .sandbox=="workspace-write" and .thread_id=="thr-3"' .agent-work/.session-feature-worker.codex.json >/dev/null || fail "E1: 워커 원장 불일치"
[ "$(jq -r .state .agent-work/.session-feature-worker.codex-turn.json)" = ACCEPTED ] || fail "E1: 워커 호출 기록이 ACCEPTED 가 아님"
# 결과 없는 재실행: native 요청을 재제시할 뿐 Codex turn 을 다시 보내지 않는다
id="$(req_get '.request_id')"
run
[ "$RC" = 42 ] && [ "$(req_get '.request_id')" = "$id" ] && [ "$(turns)" -eq 5 ] || fail "E1: native 요청 대기 중 재실행이 Codex turn 을 다시 보냈거나 다른 요청을 냄 (rc $RC, turn $(turns))"
SIM_SIDE='echo "fixed by fixer" >> src/a.txt; echo "- [fix round 1] R-01 ACCEPT: src/a.txt" >> .agent-work/decisions.md' sim_agent "수정했다." || fail "E1: 수정자 dispatch 실패"
# 2차 실행: 수정자 결과 수용 → 리뷰어 Round 2 가 Round 1 의 thread 를 재개 → APPROVE → verify → DONE
run
[ "$RC" = 0 ] && [ "$(status)" = DONE ] || fail "E1: DONE 이 아님 (rc $RC, $(status) / $(reason))"
[ "$(turns)" -eq 6 ] && [ "$(grep -c '^rpc thread/start ' "$FAKE_LOG")" -eq 4 ] || fail "E1: 리뷰어 Round 2 가 turn 1회·새 thread 0개가 아님"
grep -q '^rpc thread/resume thread=thr-4 .*sandbox=read-only' "$FAKE_LOG" && grep '^rpc turn/start ' "$FAKE_LOG" | tail -1 | grep -q 'thread=thr-4 ' || fail "E1: 리뷰어 Round 2 가 Round 1 의 thread 를 재개하지 않음: $(grep '^rpc thread/resume' "$FAKE_LOG")"
jq -e '.backend=="app_server" and .thread_id=="thr-4" and .last_accepted_label=="impl-review-a01-round-02"' .agent-work/.session-reviewer-a01.codex.json >/dev/null || fail "E1: 리뷰어 원장 불일치"
[ -f .agent-work/.session-fixer-a01.native.json ] || fail "E1: 수정자 native 세션이 확정되지 않음"
roles="$(jq -sr '[.[] | "\(.role):\(.backend)"] | group_by(.) | map("\(.[0])=\(length)") | join(",")' .agent-work/usage.jsonl)"
[ "$roles" = "FIXER:claude_native=1,REVIEWER:codex_app_server=2,VALIDATOR:codex_app_server=2,WORKER:codex_app_server=2" ] || fail "E1: 역할·backend 별 usage 행이 다름(호출 1개 = 행 1개): $roles"
# 응답이 소실된 design 검증자 호출만 unknown(0 아님)이고, 나머지 다섯은 호출별 증분이다 — 재개 호출(워커 unit 02 · 리뷰어 R2)도 누적값이 아니라 1000 이다
jq -s -e '[.[] | select(.backend=="codex_app_server")] | (map(select(.usage_observation_status=="complete" and .input_effective==1000)) | length)==5
  and (map(select(.usage_observation_status!="complete" and .input_effective==null and .estimated_cost_usd==null)) | length)==1' .agent-work/usage.jsonl >/dev/null || fail "E1: App Server 사용량 행 불일치: $(jq -c '{role,label,usage_observation_status,input_effective,usage_error}' .agent-work/usage.jsonl)"
( source "$LOADER"; usage_summary ) | jq -e '.invocations==7 and .by_source["codex-app-server"].invocations==6 and .by_cli.claude_native.invocations==1 and .cost_unknown_invocations==1' >/dev/null || fail "E1: usage_summary 가 두 backend 를 함께 집계하지 않음"
[ "$(grep -c '^full-test$' "$MOCK_LOG")" = 1 ] || fail "E1: 최종 테스트가 1회가 아님: $(cat "$MOCK_LOG")"
! grep -q '^EXEC ' "$FAKE_LOG" || fail "E1: codex exec 가 호출됨: $(grep '^EXEC' "$FAKE_LOG")"
[ ! -s "$CLI_LOG" ] || fail "E1: claude CLI 가 불림: $(cat "$CLI_LOG")"
[ -z "$(ls .agent-work/.session-*.resume-pending.json 2>/dev/null)" ] || fail "E1: App Server 모드에서 codex exec 의 resume marker 가 생김"
pass "E1. Codex 검증자×2 → Codex 워커 unit 01(신규) · unit 02(같은 thread 재개) → Unit 검사·targeted test → Codex 리뷰어 R1 → native 수정자 → 리뷰어 R2(같은 thread 재개) → verify → DONE — codex exec 0회, claude CLI 0회"

echo "[SMOKE OK] codex app-server pipeline"
