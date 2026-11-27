#!/usr/bin/env bash
# =============================================================
# native Agent 백그라운드 대기 중 중간 종료 캡처 스모크 (모델 호출 0회 — SubagentStop 훅 입력·Agent 전사 fixture + 실제 러너 경로)
# 결함(2026-11-26 runtime-split unit 01): native 워커의 foreground Bash 명령이 180초를 넘겨 Claude Code 가 백그라운드로 옮겼고, 워커는 그 완료를 기다리며 턴을 끝냈다.
# 그때 발화한 SubagentStop 에서 훅이 대기 텍스트를 final_message 보고로 캡처해 RESULT_READY 로 올렸고(전이는 한 번뿐), 명령이 끝난 뒤의 진짜 보고(SubagentHandback)는 버려졌다.
# 기대: SubagentStop 은 턴 종료일 뿐 완료의 증거가 아니다 — SubagentHandback 이 아닌 보고 후보는, 인계 뒤 띄운 백그라운드 명령에 종결 알림이 없거나(STOP_BACKGROUND_PENDING)
#       마지막 종결 알림 뒤의 새 보고가 없으면(STOP_BACKGROUND_REPORT_PENDING) 캡처하지 않고 요청 상태도 그대로 둔다. 같은 요청·같은 Agent 의 실제 최종 보고만 기존 게이트로 한 번 수용한다.
# 전사 레코드 모양(Bash tool_use/tool_result 의 'Command was moved to the background (ID: …)'·'Command running in background with ID: …',
# type user·isMeta·origin.kind task-notification 레코드 안 <task-notification> 블록의 <task-id>/<tool-use-id>/<status>, SubagentHandback tool_use)은
# Claude Code 2.1.332 실제 전사와 같다(2026-11-26). 종결 status 값(completed·failed·killed·stopped)은 실제 전사에서 관측한 값 전부다.
# 1부(G1~G11·G13·G15): 실제 훅 엔트리포인트에 SubagentStop 입력을 넣는다. 2부(G8·G12·G14): 실제 run_readonly_json_role → native 브리지 → 훅 → 소비 경로.
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-native-bg-$$"
mkdir -p "$TMP"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }
trap 'rm -rf "$TMP"' EXIT
unset CLAUDE_CODE_SUBAGENT_MODEL_FORCE CLAUDE_CODE_EFFORT_LEVEL NTFY_TOPIC
# 메인 Claude Code 프로세스 pid — 이 세션 안에서 돌리면 물려받는다. 남겨 두면 방금 만든 임시 agent 정의가 그 프로세스보다 새것이라 러너의 등록 증거 게이트(NATIVE_AGENT_RESTART_REQUIRED)가 멈춘다. 그 게이트는 tests/smoke-native-agent-definitions.sh 가 본다
unset CLAUDE_PID
# 요청에 결속되기 전의 훅 흔적(예: TRANSCRIPT_UNREADABLE)은 $CLAUDE_PROJECT_DIR/.agent-work 로 간다 — Claude Code 세션 안에서 돌려도 실제 프로젝트에 남지 않게 임시 디렉터리로 돌린다.
export CLAUDE_PROJECT_DIR="$TMP/claude-project-dir"
HOOK="$PROJECT_SRC/.claude/hooks/feature_native_agent.sh"
[ -x "$HOOK" ] || fail "훅이 없거나 실행 비트가 없음: $HOOK"
export FEATURE_NATIVE_REPORT_WAIT_TRIES=1
SID="sess-main"
RESULT_JSON='{"status":"DONE","undecided":[],"delegated_choices":[]}'
RESUME_PRE=$'The coordinator sent a message while you were working:\n'
RESUME_SUF=$'\n\nAddress this before completing your current task.'

# =============================================================
# 1부 — 훅 단위 fixture
# =============================================================
N=0; CASE=""; REQ=""; TR=""; AID=""; M=0
new_case() { # name [NEW|RESUME] [DISPATCHED|DISPATCHING]
  N=$((N + 1)); CASE="$TMP/hook/$1"; AID="agentbg$N"
  local d="$CASE/.agent-work/native-agent" id="native-bg-$N"
  mkdir -p "$d/requests" "$d/results"
  REQ="$d/requests/$id.json"; TR="$CASE/agent-$AID.jsonl"; : > "$TR"
  jq -n --arg p "$REQ" --arg id "$id" --arg sid "$SID" --arg aid "$AID" --arg intent "${2:-NEW}" --arg st "${3:-DISPATCHED}" \
    '{version:1, backend:"claude_native", request_id:$id, request_path:$p, role:"WORKER", state:$st, session_intent:$intent,
      agent_definition:"feature-worker", owner_session_id:$sid, dispatch_sha256:"x"}
     + (if $intent == "RESUME" then {resume_agent_id:$aid} else {} end)
     + (if $st == "DISPATCHED" then {dispatched_agent_id:$aid} else {} end)' > "$REQ"
  jq -n --arg p "$REQ" --arg id "$id" '{version:1, request_id:$id, request_path:$p, role:"WORKER"}' > "$d/pending.json"
}
rec_prompt() { # [request-path]
  jq -nc --arg r "${1:-$REQ}" '{type:"user", message:{role:"user", content:("FEATURE-NATIVE-REQUEST " + $r + "\nunit prompt body")}}' >> "$TR"
}
rec_resume_prompt() { # 재개(SendMessage) 메시지: isMeta user 레코드, 하네스 고정 포장
  jq -nc --arg c "${RESUME_PRE}FEATURE-NATIVE-REQUEST $REQ
resume prompt body${RESUME_SUF}" '{type:"user", isMeta:true, message:{role:"user", content:$c}}' >> "$TR"
}
asst() { # stop-reason content-json
  M=$((M + 1))
  jq -nc --arg a "$AID" --arg s "$SID" --arg id "m$M" --arg sr "$1" --argjson c "$2" \
    '{type:"assistant", agentId:$a, sessionId:$s, requestedModel:"claude-opus-5-5", effort:"medium",
      message:{id:$id, model:"claude-opus-5-5", stop_reason:$sr, usage:{input_tokens:1, cache_read_input_tokens:1, cache_creation_input_tokens:1, output_tokens:10}, content:$c}}' >> "$TR"
}
rec_tool_use() { asst tool_use "$(jq -nc --arg tu "$1" --arg n "$2" '[{type:"tool_use", id:$tu, name:$n, input:{command:"bash tests/run-smokes.sh"}}]')"; }
rec_tool_result() { jq -nc --arg tu "$1" --arg t "$2" '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:$tu, content:$t}]}}' >> "$TR"; }
rec_tool_result_s() { # tool-use-id text background-task-id — 실제 전사의 구조화 필드 toolUseResult.backgroundTaskId 를 함께 쓴다
  jq -nc --arg tu "$1" --arg t "$2" --arg b "$3" '{type:"user", toolUseResult:{stdout:"", stderr:"", interrupted:false, isImage:false, noOutputExpected:false, backgroundTaskId:$b},
    message:{role:"user", content:[{type:"tool_result", tool_use_id:$tu, content:$t}]}}' >> "$TR"
}
timeout_text() { printf 'Command did not complete within its 120s timeout and was moved to the background (ID: %s). Output is being written to: /tmp/tasks/%s.output' "$1" "$1"; }
rec_end_turn() { asst end_turn "$(jq -nc --arg t "$1" 'if $t == "" then [] else [{type:"text", text:$t}] end')"; }
rec_handback() { asst tool_use "$(jq -nc --arg r "$1" --arg id "hb$((M + 1))" '[{type:"tool_use", id:$id, name:"SubagentHandback", input:{message:$r}}]')"; }
moved_text() { printf 'Command was moved to the background (ID: %s) after running for 180s. Output is being written to: /tmp/tasks/%s.output. You will be notified when it completes.' "$1" "$1"; }
bg_text() { printf 'Command running in background with ID: %s. Output is being written to: /tmp/tasks/%s.output' "$1" "$1"; }
launch_moved() { rec_tool_use "$1" Bash; rec_tool_result "$1" "$(moved_text "$2")"; }   # tool-use-id task-id
block() { # task-id tool-use-id status — 빈 인자는 그 태그를 넣지 않는다
  printf '<task-notification>\n'
  [ -z "$1" ] || printf '<task-id>%s</task-id>\n' "$1"
  [ -z "$2" ] || printf '<tool-use-id>%s</tool-use-id>\n' "$2"
  printf '<output-file>/tmp/tasks/%s.output</output-file>\n' "${1:-x}"
  [ -z "$3" ] || printf '<status>%s</status>\n' "$3"
  printf '<summary>Background command completed (exit code 0)</summary>\n</task-notification>'
}
rec_note_raw() { # body [record-shape: meta(기본)|plain|nonmeta]
  local b="[SYSTEM NOTIFICATION - NOT USER INPUT]

$1"
  case "${2:-meta}" in
    meta)    jq -nc --arg b "$b" '{type:"user", isMeta:true, origin:{kind:"task-notification", producer:"session-task"}, message:{role:"user", content:$b}}' >> "$TR";;
    nonmeta) jq -nc --arg b "$b" '{type:"user", origin:{kind:"task-notification", producer:"session-task"}, message:{role:"user", content:$b}}' >> "$TR";;
    plain)   jq -nc --arg b "$b" '{type:"user", message:{role:"user", content:$b}}' >> "$TR";;
  esac
}
rec_note() { rec_note_raw "$(block "$1" "${2:-}" "${3:-completed}")"; }   # task-id [tool-use-id] [status]
subagent_stop() {
  jq -n --arg tp "$TR" --arg a "$AID" --arg s "$SID" \
    '{hook_event_name:"SubagentStop", agent_type:"feature-worker", agent_id:$a, session_id:$s, agent_transcript_path:$tp, last_assistant_message:"closing"}' | "$HOOK"
}
state() { jq -r '.state' "$REQ"; }
cap() { echo "$(dirname "$(dirname "$REQ")")/results/$(jq -r '.request_id' "$REQ").capture.json"; }
msg() { echo "$(dirname "$(dirname "$REQ")")/results/$(jq -r '.request_id' "$REQ").message.txt"; }
trace_file() { echo "$(dirname "$(dirname "$REQ")")/hook-trace.jsonl"; }
last_trace() { jq -c 'select(.event=="SubagentStop")' "$(trace_file)" 2>/dev/null | tail -1; }
captured_count() { jq -c 'select(.reason=="CAPTURED")' "$(trace_file)" 2>/dev/null | wc -l | tr -d ' '; }
held() { # tag reason expected-pending-json [expected-state]
  [ "$(state)" = "${4:-DISPATCHED}" ] || fail "$1: 보류여야 하는데 state 가 $(state)"
  [ ! -e "$(cap)" ] && [ ! -e "$(msg)" ] || fail "$1: 보류여야 하는데 결과 파일이 쓰임: $(cat "$(msg)" 2>/dev/null)"
  last_trace | jq -e --arg r "$2" --argjson p "$3" '.reason == $r and .detail.background_pending == $p' >/dev/null \
    || fail "$1: 보류 흔적이 기대($2 $3)와 다름: $(last_trace)"
}
captured() { # tag source [expected-text]
  [ "$(state)" = RESULT_READY ] || fail "$1: 캡처돼야 하는데 state $(state): $(last_trace)"
  jq -e --arg s "$2" '.report_status == "OK" and .report_source == $s' "$(cap)" >/dev/null || fail "$1: 보고 출처가 $2 가 아님: $(jq -c '{report_status,report_source}' "$(cap)")"
  [ -z "${3:-}" ] || [ "$(cat "$(msg)")" = "$3" ] || fail "$1: 캡처된 보고 원문이 기대와 다름: $(cat "$(msg)")"
}

# ---------- G1·G2 자동 이동된 명령의 대기 종료 → 보류 / 완료 뒤 실제 Handback 만 1회 캡처 ----------
new_case g1; rec_prompt
launch_moved tu_batch2 bwlu68rt3
rec_end_turn "Waiting for the second batch of the targeted smokes to finish."
subagent_stop
held G1 STOP_BACKGROUND_PENDING '["bwlu68rt3"]'
pass "G1. 자동 이동된 백그라운드 명령을 기다리며 끝난 턴: DISPATCHED 유지·결과 파일 없음·STOP_BACKGROUND_PENDING"
rec_note bwlu68rt3 tu_batch2
rec_tool_use tu_read Read; rec_tool_result tu_read "1	PASS tests/smoke-foo.sh"
rec_handback "$RESULT_JSON"
subagent_stop
captured G2 SubagentHandback "$RESULT_JSON"
sum="$(shasum "$(cap)" | cut -d' ' -f1)"
subagent_stop   # 중복 SubagentStop
[ "$(shasum "$(cap)" | cut -d' ' -f1)" = "$sum" ] && [ "$(captured_count)" = 1 ] && [ "$(last_trace | jq -r '.reason')" = STATE_RESULT_READY ] \
  || fail "G2: 중복 SubagentStop 이 캡처를 다시 쓰거나 RESULT_READY 전이가 1회가 아님($(captured_count))"
pass "G2. 종결 알림 뒤 같은 요청·같은 Agent 의 SubagentHandback 원문만 캡처, RESULT_READY 1회(중복 이벤트 무시)"

# ---------- G3 run_in_background + task-id 만 있는 종결 알림 ----------
new_case g3; rec_prompt
rec_tool_use tu_bg Bash; rec_tool_result tu_bg "$(bg_text bxifv792j)"
rec_end_turn "Waiting for the background run."
subagent_stop
held G3 STOP_BACKGROUND_PENDING '["bxifv792j"]'
rec_note bxifv792j
rec_end_turn "$RESULT_JSON"
subagent_stop
captured G3 final_message "$RESULT_JSON"
new_case g3s; rec_prompt
rec_tool_use tu_s1 Bash; rec_tool_result_s tu_s1 "$(bg_text bstruct01)" bstruct01                                    # 구조화 ID + 문구(일반적인 run_in_background)
rec_tool_use tu_s2 Bash; rec_tool_result_s tu_s2 "smoke output line
$(timeout_text btimeout2)" btimeout2                                                                                    # 출력 뒤에 붙은 시간 초과 문구 — 구조화 ID 로만 알 수 있다
rec_tool_use tu_s3 Bash; rec_tool_result tu_s3 "$(timeout_text btimeout3)"                                             # 구조화 ID 없는 시간 초과 문구(첫머리)
rec_end_turn "Waiting."
subagent_stop
held G3-structured STOP_BACKGROUND_PENDING '["bstruct01","btimeout2","btimeout3"]'
pass "G3. run_in_background 도 같은 보류 — task-id 만 있는 종결 알림으로 결속되면 해소, 그 뒤의 새 end_turn 은 종전대로 final_message. 구조화 ID(toolUseResult.backgroundTaskId)를 우선 쓰고, 없으면 시간 초과 이동 문구도 인식"

# ---------- G4 명시적 Handback + pending ----------
new_case g4; rec_prompt
rec_tool_use tu_bg4 Bash; rec_tool_result tu_bg4 "$(bg_text bv7zk2gh3)"
rec_handback "$RESULT_JSON"
subagent_stop
captured G4 SubagentHandback "$RESULT_JSON"
pass "G4. 백그라운드가 남아 있어도 SubagentHandback 은 기존대로 보고(Handback 우선 계약 보존 — 이후 재개·소스 수정 위험은 이 테스트가 증명하지 않는다)"

# ---------- G5 거짓 실행 증거 ----------
new_case g5; rec_prompt
rec_tool_use tu_r5 Read; rec_tool_result tu_r5 "$(bg_text bnotbash1)"                       # Bash 가 아닌 도구
rec_tool_use tu_b5 Bash; rec_tool_result tu_b5 "log line: $(moved_text bnotfirst)"           # 첫머리가 아닌 문구
rec_tool_result tu_unknown "$(moved_text bnotooluse)"                                         # 어떤 tool_use 에도 결속되지 않은 결과
rec_end_turn "note: $(bg_text bintext01)"                                                     # 일반 assistant 텍스트
jq -nc --arg t "$(moved_text bplainusr)" '{type:"user", message:{role:"user", content:$t}}' >> "$TR"   # 일반 user 텍스트
M=$((M + 1))                                                                                   # id 없는 tool_use·tool_result(기존 fixture 모양)
jq -nc --arg a "$AID" --arg s "$SID" --arg id "m$M" '{type:"assistant", agentId:$a, sessionId:$s, requestedModel:"claude-opus-5-5", effort:"medium",
  message:{id:$id, model:"claude-opus-5-5", stop_reason:"tool_use", usage:{input_tokens:1, cache_read_input_tokens:1, cache_creation_input_tokens:1, output_tokens:1}, content:[{type:"tool_use", name:"Bash", input:{}}]}}' >> "$TR"
jq -nc --arg t "$(moved_text bnoid8888)" '{type:"user", message:{role:"user", content:[{type:"tool_result", content:$t}]}}' >> "$TR"
rec_tool_use tu_r6 Read; rec_tool_result_s tu_r6 "file" bnotbash2                                                     # Bash 가 아닌 도구 결과의 구조화 ID
asst tool_use '[{"type":"tool_use","id":"tu_m1","name":"Bash","input":{}},{"type":"tool_use","id":"tu_m2","name":"Bash","input":{}}]'
jq -nc '{type:"user", toolUseResult:{stdout:"", backgroundTaskId:"bambig001"}, message:{role:"user", content:[{type:"tool_result", tool_use_id:"tu_m1", content:"ok"}, {type:"tool_result", tool_use_id:"tu_m2", content:"ok"}]}}' >> "$TR"   # 결과 둘인 레코드의 구조화 ID — 어느 결과의 것인지 모른다
rec_end_turn "$RESULT_JSON"
subagent_stop
captured G5 final_message "$RESULT_JSON"
pass "G5. Bash 외 도구(문구·구조화 ID)·결속 안 된 tool_use_id·일반 텍스트·첫머리가 아닌 문구·id 없는 레코드·결과 둘인 레코드의 구조화 ID 는 실행 증거가 아니다(종전 final_message 경로)"

# ---------- G6 앞선 인계의 기록 — NEW / RESUME ----------
new_case g6n NEW
rec_prompt "$TMP/old/native-agent/requests/native-old-1.json"
launch_moved tu_old bprevturn
rec_end_turn "Waiting (previous request)."
rec_prompt
rec_end_turn "$RESULT_JSON"
subagent_stop
captured G6-NEW final_message "$RESULT_JSON"
new_case g6r RESUME
rec_prompt "$TMP/old/native-agent/requests/native-old-2.json"
launch_moved tu_prev bprevres1
rec_end_turn "Waiting (previous turn)."
rec_resume_prompt
rec_note bprevres1 tu_prev            # 앞선 턴의 명령이 재개 뒤에 끝났다는 알림 — 현재 요청의 실행이 아니다
rec_end_turn "$RESULT_JSON"
subagent_stop
captured G6-RESUME final_message "$RESULT_JSON"
jq -e '.prompt_wrapper == "coordinator_message"' "$(cap)" >/dev/null || fail "G6-RESUME: 재개 포장이 인식되지 않음"
new_case g6r2 RESUME
rec_prompt "$TMP/old/native-agent/requests/native-old-3.json"
launch_moved tu_same bsametask
rec_note bsametask tu_same            # 앞선 턴에서 이미 끝난 같은 task 의 알림
rec_resume_prompt
launch_moved tu_same2 bsametask       # 현재 요청에서 새로 띄운 같은 task id(가상의 재사용) — 인계 전 알림으로 끝나지 않는다
rec_end_turn "Waiting again."
subagent_stop
held G6-RESUME2 STOP_BACKGROUND_PENDING '["bsametask"]'
pass "G6. 마지막 인계(NEW·RESUME 모두) 뒤의 실행·알림만 본다 — 앞선 요청·턴의 실행과 알림을 섞지 않는다"

# ---------- G7 텍스트 없는 대기 종료 ----------
new_case g7; rec_prompt
launch_moved tu_bg7 bnotext77
rec_end_turn ""
subagent_stop
held G7 STOP_BACKGROUND_PENDING '["bnotext77"]'
rec_note bnotext77 tu_bg7
rec_handback "$RESULT_JSON"
subagent_stop
captured G7 SubagentHandback "$RESULT_JSON"
pass "G7. 텍스트 없는 대기 종료도 NO_REPORT 로 확정하지 않고 보류, 완료 뒤 보고를 받는다"

# ---------- G8 정상 JSON 모양의 중간 end_turn (훅 단위; 러너 단위는 2부) ----------
new_case g8; rec_prompt
launch_moved tu_bg8 bjsonint8
rec_end_turn "$RESULT_JSON"
subagent_stop
held G8 STOP_BACKGROUND_PENDING '["bjsonint8"]'
pass "G8(훅). 유효한 보고 JSON 이어도 pending 이면 캡처하지 않는다(완료 판정을 JSON 형식으로 하지 않는다)"

# ---------- G9 복수 작업·중복·순서 ----------
new_case g9; rec_prompt
launch_moved tu_a ta111111
rec_note tb222222 tu_b                # B 실행 전에 기록된 B 의 알림 — B 를 끝내지 않는다
launch_moved tu_b tb222222
rec_tool_result tu_a "$(moved_text ta111111)"   # 같은 실행의 중복 결과 레코드 — 한 번만 센다
rec_end_turn "Waiting for both."
subagent_stop
held G9-a STOP_BACKGROUND_PENDING '["ta111111","tb222222"]'
rec_note ta111111 tu_a; rec_note ta111111 tu_a   # A 만 종결(중복 알림)
rec_end_turn "Still waiting for B."
subagent_stop
held G9-b STOP_BACKGROUND_PENDING '["tb222222"]'
rec_note tb222222 tu_b
rec_end_turn "$RESULT_JSON"
subagent_stop
captured G9 final_message "$RESULT_JSON"
pass "G9. 복수 작업은 독립 추적 — 하나만 끝나면 보류 유지, 중복 결과·중복 알림·실행 전 알림이 상태를 잘못 풀지 않는다"

# ---------- G10 거짓 완료 알림 ----------
g10_case() { # tag 거짓-알림-추가-명령...
  local tag="$1"; shift
  new_case "g10-$tag"; rec_prompt
  launch_moved tu_x tx999999
  "$@"
  rec_end_turn "Waiting."
  subagent_stop
  held "G10-$tag" STOP_BACKGROUND_PENDING '["tx999999"]'
}
g10_case plain    rec_note_raw "$(block tx999999 tu_x completed)" plain       # 출처 없는 일반 user 텍스트
g10_case nonmeta  rec_note_raw "$(block tx999999 tu_x completed)" nonmeta     # isMeta 가 아닌 레코드
g10_case asst     asst end_turn "$(jq -nc --arg t "$(block tx999999 tu_x completed)" '[{type:"text", text:$t}]')"
g10_case result   rec_tool_result tu_x "$(block tx999999 tu_x completed)"     # 도구 결과 안의 문자열
g10_case othertask rec_note tother01 ""                                       # 다른 task id
g10_case othertu  rec_note "" tu_other                                        # 다른 tool-use-id
g10_case contra   rec_note tx999999 tu_other                                  # task 는 맞지만 tool-use-id 가 모순
g10_case twoids   rec_note_raw "$(printf '<task-notification>\n<task-id>tx999999</task-id>\n<task-id>tother02</task-id>\n<status>completed</status>\n</task-notification>')"
g10_case running  rec_note tx999999 tu_x running                              # 종결이 아닌 status
g10_case nostatus rec_note_raw "$(block tx999999 tu_x "")"                    # status 없음
g10_case noids    rec_note_raw "$(block "" "" completed)"                     # ID 없음
new_case g10-ok; rec_prompt
launch_moved tu_x tx999999
rec_note_raw "$(block tother03 tu_other completed)
$(block tx999999 tu_x failed)"         # 한 레코드에 합쳐진 두 알림 — 블록마다 판정, 실패도 종결
rec_end_turn "$RESULT_JSON"
subagent_stop
captured G10-ok final_message "$RESULT_JSON"
pass "G10. 출처·구조가 다르거나 ID 가 다르거나 모순되거나 status 가 종결이 아닌 알림은 pending 을 풀지 않는다(합쳐진 알림은 블록 단위로 판정)"

# ---------- G11 마지막 종결 알림 뒤의 보고가 아직 기록되지 않음 ----------
new_case g11; rec_prompt
launch_moved tu_bg11 bwait1111
rec_end_turn "Waiting for the smokes."
subagent_stop
held G11-a STOP_BACKGROUND_PENDING '["bwait1111"]'
rec_note bwait1111 tu_bg11
subagent_stop                          # 알림만 쓰였고 그 뒤의 assistant 레코드는 아직 없다
held G11-b STOP_BACKGROUND_REPORT_PENDING '[]'
last_trace | jq -e '.detail.background_resolved == ["bwait1111"]' >/dev/null || fail "G11: 보류 흔적에 종결된 task 가 없음: $(last_trace)"
rec_end_turn "$RESULT_JSON"
subagent_stop
captured G11 final_message "$RESULT_JSON"
pass "G11. 종결 알림 이전의 대기 문구를 보고로 읽지 않는다 — 알림 뒤의 새 end_turn 이 기록된 뒤에만 캡처"

# ---------- G15 보류 중 제한된 재읽기: 종결 알림·보고가 SubagentStop 뒤에 쓰이는 경우 ----------
# SubagentStop 은 전사의 마지막 레코드가 쓰이기 전에 발화할 수 있다(기존 R 시나리오의 경쟁과 같다). 보류 사유가 남아 있는 동안에도 기존 재읽기 한도 안에서 다시 읽어,
# 그 안에 보고가 기록되면 같은 SubagentStop 에서 캡처한다(다음 이벤트가 없어도 놓치지 않는다). 레코드는 한 번의 쓰기로 덧붙인다.
late_lines() { # agent-id msg-id task-id tool-use-id kind(handback|final) report
  jq -nc --arg b "$(block "$3" "$4" completed)" '{type:"user", isMeta:true, origin:{kind:"task-notification", producer:"session-task"}, message:{role:"user", content:$b}}'
  if [ "$5" = handback ]; then
    jq -nc --arg a "$1" --arg s "$SID" --arg id "$2" --arg r "$6" '{type:"assistant", agentId:$a, sessionId:$s, requestedModel:"claude-opus-5-5", effort:"medium",
      message:{id:$id, model:"claude-opus-5-5", stop_reason:"tool_use", usage:{input_tokens:1, cache_read_input_tokens:1, cache_creation_input_tokens:1, output_tokens:10}, content:[{type:"tool_use", id:("hb" + $id), name:"SubagentHandback", input:{message:$r}}]}}'
  else
    jq -nc --arg a "$1" --arg s "$SID" --arg id "$2" --arg r "$6" '{type:"assistant", agentId:$a, sessionId:$s, requestedModel:"claude-opus-5-5", effort:"medium",
      message:{id:$id, model:"claude-opus-5-5", stop_reason:"end_turn", usage:{input_tokens:1, cache_read_input_tokens:1, cache_creation_input_tokens:1, output_tokens:10}, content:[{type:"text", text:$r}]}}'
  fi
}
new_case g15a; rec_prompt
launch_moved tu_l1 blate0001
rec_end_turn "Waiting for the smokes."
lines="$(late_lines "$AID" late1 blate0001 tu_l1 handback "$RESULT_JSON")"
( sleep 1; printf '%s\n' "$lines" >> "$TR" ) &
FEATURE_NATIVE_REPORT_WAIT_TRIES=10 subagent_stop
wait
captured G15-handback SubagentHandback "$RESULT_JSON"
jq -e '.report_wait_tries >= 1' "$(cap)" >/dev/null || fail "G15: 재읽기 없이 캡처됨(지연 기록을 기다리지 않음)"
new_case g15b; rec_prompt
launch_moved tu_l2 blate0002
rec_end_turn "Waiting for the smokes."
lines="$(late_lines "$AID" late2 blate0002 tu_l2 final "$RESULT_JSON")"
( sleep 1; printf '%s\n' "$lines" >> "$TR" ) &
FEATURE_NATIVE_REPORT_WAIT_TRIES=10 subagent_stop
wait
captured G15-final final_message "$RESULT_JSON"
new_case g15c; rec_prompt
launch_moved tu_l3 blate0003
rec_end_turn "Waiting for the smokes."
FEATURE_NATIVE_REPORT_WAIT_TRIES=3 subagent_stop          # 한도 안에 아무것도 쓰이지 않으면 보류로 끝난다(무한 대기 없음)
held G15-timeout STOP_BACKGROUND_PENDING '["blate0003"]'
pass "G15. 보류 중에도 기존 제한된 재읽기로 늦게 쓰인 종결 알림·보고(Handback·end_turn)를 같은 SubagentStop 에서 받고, 한도를 넘기면 보류로 끝난다"

# ---------- G13 백그라운드가 없던 요청의 기존 경로 ----------
new_case g13a; rec_prompt
rec_tool_use tu_f Read; rec_tool_result tu_f "file"
rec_end_turn "$RESULT_JSON"
subagent_stop
captured G13-final final_message "$RESULT_JSON"
new_case g13b; rec_prompt
rec_tool_use tu_g Read                 # end_turn 없이 멈춘 전사(보고 없음)
subagent_stop
[ "$(state)" = RESULT_READY ] && jq -e '.report_status == "NO_REPORT" and .report_source == null and .message_path == null' "$(cap)" >/dev/null \
  || fail "G13: 보고 없는 종료가 종전처럼 NO_REPORT 로 기록되지 않음(state $(state))"
pass "G13. 백그라운드가 없던 요청의 final_message·NO_REPORT 경로는 종전과 같다"

# =============================================================
# 2부 — 실제 러너 경로(run_readonly_json_role → native-agent-bridge → 훅 → 소비)
# =============================================================
R="$TMP/runner"
mkdir -p "$R/bin" "$R/repo/.claude/hooks" "$R/repo/.claude/skills" "$R/transcripts"
cp -R "$SKILL_SRC" "$R/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$R/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$R/repo/.claude/hooks/core_rules.md"
cp "$HOOK" "$R/repo/.claude/hooks/" || fail "훅 복사 실패"
RHOOK="$R/repo/.claude/hooks/feature_native_agent.sh"
cat > "$R/bin/claude" <<'EOS'
#!/usr/bin/env bash
echo "claude $*" >> "$CLI_LOG"; exit 9
EOS
cat > "$R/bin/codex" <<'EOS'
#!/usr/bin/env bash
echo "codex $*" >> "$CLI_LOG"; exit 9
EOS
chmod +x "$R/bin/claude" "$R/bin/codex"
export CLI_LOG="$R/cli.log"; : > "$CLI_LOG"
CFG="$R/repo/.claude/skills/feature/config.sh"
for e in "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$R/bin/claude\"|" "s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$R/bin/codex\"|" \
         's|^TEST_CMD="CHANGE_ME"|TEST_CMD="true"|' 's|^LINT_CMD="CHANGE_ME"|LINT_CMD="true"|' 's|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND="native"|' \
         's|^DESIGN_REVISION_MODEL=.*|DESIGN_REVISION_MODEL="claude-fable-5-2"|' 's|^VALIDATOR_MODEL=.*|VALIDATOR_MODEL="claude-opus-5-5"|' \
         's|^WORKER_MODEL=.*|WORKER_MODEL="claude-opus-5-5"|' 's|^REVIEWER_MODEL=.*|REVIEWER_MODEL="claude-sonnet-5-5"|' 's|^FIXER_MODEL=.*|FIXER_MODEL="claude-sonnet-5-5"|' \
         's|^VALIDATOR_PROFILE=.*|VALIDATOR_PROFILE="none"|'; do
  sed -i.bak "$e" "$CFG" && rm -f "$CFG.bak" || fail "config 수정 실패: $e"
done
# 러너 진입: 설정·런타임 로더가 따로 있는 배치(scripts/lib/bootstrap.sh)면 그것을, 아니면 종전처럼 config.sh 를 source 한다.
# 계약 버전도 파일을 grep 하지 않고 로더를 source 해서 읽는다 — 상수가 어느 파일에 있든 같은 값이다.
LOADER="$CFG"; [ ! -f "$R/repo/.claude/skills/feature/scripts/lib/bootstrap.sh" ] || LOADER="$R/repo/.claude/skills/feature/scripts/lib/bootstrap.sh"
export CLAUDE_CODE_SESSION_ID="$SID"
cd "$R/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && echo "base" > src/u01.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
: > .agent-work/decisions.md
MOCK_CONTRACT="$( ( source "$LOADER" >/dev/null 2>&1; printf '%s' "${VALIDATOR_CONTRACT_VERSION:-}" ) )"
[ -n "$MOCK_CONTRACT" ] || fail "러너 로더($LOADER)에서 VALIDATOR_CONTRACT_VERSION 을 읽지 못함"
PASS_JSON="{\"schema_version\":$MOCK_CONTRACT,\"verdict\":\"PASS\",\"blocking_issues\":[]}"
RND="$R/repo/.agent-work/native-agent"
SCHEMA=".claude/skills/feature/schemas/spec-review.schema.json"
MAIN_TR="$R/transcripts/main.jsonl"; : > "$MAIN_TR"
RC=0
role_ro() { # session-key label out
  RC=0; ( set -e; source "$LOADER"; run_readonly_json_role VALIDATOR "$1" "$2" "$SCHEMA" "$3" "smoke prompt for $2" "" ) > "$R/last.log" 2>&1 || RC=$?
}
r_req() { jq -r '.request_path' "$RND/pending.json"; }
r_get() { jq -r "$1" "$(r_req)"; }
r_count() { ls "$RND/requests"/*.json 2>/dev/null | wc -l | tr -d ' '; }
PRE_OUT=""
r_pre() { # tool-use-id → PRE_OUT
  PRE_OUT="$(jq -n --arg t "$(r_get '.agent_definition')" --arg p "$(r_get '.dispatch_line')" --arg tu "$1" --arg tp "$MAIN_TR" \
    '{hook_event_name:"PreToolUse", session_id:"sess-main", transcript_path:$tp, tool_name:"Agent", tool_use_id:$tu, tool_input:{subagent_type:$t, description:"sim", prompt:$p}}' | "$RHOOK")"
}
r_post() { # tool-use-id agent-id
  jq -n --arg tu "$1" --arg a "$2" --arg tp "$MAIN_TR" --argjson i "$(printf '%s' "$PRE_OUT" | jq -c '.hookSpecificOutput.updatedInput')" \
    '{hook_event_name:"PostToolUse", session_id:"sess-main", transcript_path:$tp, tool_name:"Agent", tool_use_id:$tu, tool_input:$i,
      tool_response:{isAsync:true, status:"async_launched", agentId:$a, description:"sim", resolvedModel:"claude-opus-5-5", canContinueAgent:true}}' | "$RHOOK"
}
RA=""; RTR=""; RMODEL=""; RM=0
r_agent() { RA="$1"; RTR="$R/transcripts/agent-$1.jsonl"; : > "$RTR"; RMODEL="${2:-$(r_get '.model')}"; }
r_prompt() { jq -nc --arg p "$(cat "$(r_get '.prompt_path')")" --arg a "$RA" '{type:"user", agentId:$a, sessionId:"sess-main", message:{role:"user", content:$p}}' >> "$RTR"; }
r_asst() { # stop-reason content-json
  RM=$((RM + 1))
  jq -nc --arg a "$RA" --arg m "$RMODEL" --arg e "$(r_get '.effort')" --arg id "rm$RM" --arg sr "$1" --argjson c "$2" \
    '{type:"assistant", agentId:$a, sessionId:"sess-main", requestedModel:$m, effort:$e,
      message:{id:$id, model:$m, stop_reason:$sr, usage:{input_tokens:2, cache_read_input_tokens:100, cache_creation_input_tokens:0, output_tokens:10}, content:$c}}' >> "$RTR"
}
r_launch() { # tool-use-id task-id
  r_asst tool_use "$(jq -nc --arg tu "$1" '[{type:"tool_use", id:$tu, name:"Bash", input:{command:"bash tests/run-smokes.sh"}}]')"
  jq -nc --arg tu "$1" --arg t "$(moved_text "$2")" '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:$tu, content:$t}]}}' >> "$RTR"
}
r_note() { jq -nc --arg b "$(block "$1" "$2" completed)" '{type:"user", isMeta:true, origin:{kind:"task-notification", producer:"session-task"}, message:{role:"user", content:$b}}' >> "$RTR"; }
r_stop() { jq -n --arg a "$RA" --arg tp "$RTR" '{hook_event_name:"SubagentStop", session_id:"sess-main", agent_id:$a, agent_type:"feature-validator", agent_transcript_path:$tp, stop_hook_active:false}' | "$RHOOK"; }
r_cap() { echo "$RND/results/$1.capture.json"; }
r_last_trace() { jq -c 'select(.event=="SubagentStop")' "$RND/hook-trace.jsonl" 2>/dev/null | tail -1; }
no_effects() { # tag out — 결과 파일·usage·세션·CLI 호출이 없어야 한다
  [ ! -e "$2" ] || fail "$1: 보류 중인데 역할 결과 파일이 생김"
  [ ! -s .agent-work/usage.jsonl ] || fail "$1: 보류 중인데 usage 가 기록됨: $(cat .agent-work/usage.jsonl)"
  [ -z "$(ls .agent-work/.session-* 2>/dev/null)" ] || fail "$1: 보류 중인데 세션 원장이 생김: $(ls .agent-work/.session-*)"
  [ ! -s "$CLI_LOG" ] || fail "$1: CLI 가 호출됨: $(cat "$CLI_LOG")"
}

# ---------- G12·G8·G14 경합·조기 재실행·결과 수용 ----------
role_ro "validator-bg-a" "design-validator-round-01" "$R/v1.json"
[ "$RC" = 42 ] && [ "$(r_get '.state')" = PREPARED ] || { cat "$R/last.log"; fail "G12: 요청이 발행되지 않음 (rc $RC)"; }
ID1="$(r_get '.request_id')"
r_pre toolu_g12
[ "$(printf '%s' "$PRE_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = allow ] && [ "$(r_get '.state')" = DISPATCHING ] || fail "G12: dispatch 가 허용되지 않음: $PRE_OUT"
r_agent agentg12
r_prompt; r_launch rtu_g12 btask1212; r_asst end_turn "$(jq -nc --arg t "$PASS_JSON" '[{type:"text", text:$t}]')"   # G8: 유효한 PASS JSON 인 중간 종료
r_stop                                   # SubagentStop 이 PostToolUse 보다 먼저 왔다(DISPATCHING)
[ "$(r_get '.state')" = DISPATCHING ] && [ ! -e "$(r_cap "$ID1")" ] && [ "$(r_last_trace | jq -r '.reason')" = STOP_BACKGROUND_PENDING ] \
  || fail "G12: DISPATCHING 에서 보류되지 않음(state $(r_get '.state')): $(r_last_trace)"
role_ro "validator-bg-b" "design-validator-round-01" "$R/v1.json"    # DISPATCHING 중 조기 재실행
[ "$RC" = 42 ] && [ "$(r_get '.request_id')" = "$ID1" ] && [ "$(r_count)" = 1 ] && [ "$(r_get '.state')" = DISPATCHING ] \
  || { cat "$R/last.log"; fail "G12: DISPATCHING 보류 중 재실행이 같은 요청 대기(exit 42)가 아님 (rc $RC, 요청 $(r_count)개)"; }
no_effects G12-dispatching "$R/v1.json"
r_post toolu_g12 agentg12
[ "$(r_get '.state')" = DISPATCHED ] || fail "G12: 보류 뒤 PostToolUse 가 DISPATCHED 로 올리지 않음($(r_get '.state'))"
role_ro "validator-bg-c" "design-validator-round-01" "$R/v1.json"    # DISPATCHED 중 조기 재실행
[ "$RC" = 42 ] && [ "$(r_get '.request_id')" = "$ID1" ] && [ "$(r_count)" = 1 ] && [ "$(r_get '.state')" = DISPATCHED ] \
  || { cat "$R/last.log"; fail "G12: DISPATCHED 보류 중 재실행이 같은 요청 대기(exit 42)가 아님 (rc $RC)"; }
no_effects G12-dispatched "$R/v1.json"
r_pre toolu_g12b
[ "$(printf '%s' "$PRE_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] && [ "$(r_get '.dispatch_attempt.tool_use_id')" = toolu_g12 ] \
  || fail "G12: 보류 중인 요청의 두 번째 dispatch 가 거부되지 않음"
pass "G8·G12. 유효한 JSON 중간 종료도 DISPATCHING/DISPATCHED 그대로 — 조기 재실행은 같은 요청 exit 42, 결과·usage·세션·CLI·추가 dispatch 0"
r_note btask1212 rtu_g12
r_asst tool_use "$(jq -nc --arg r "$PASS_JSON" '[{type:"tool_use", id:"hbg12", name:"SubagentHandback", input:{message:$r}}]')"
r_stop
[ "$(r_get '.state')" = RESULT_READY ] && jq -e '.report_status == "OK" and .report_source == "SubagentHandback"' "$(r_cap "$ID1")" >/dev/null \
  || fail "G12: 종결 뒤 Handback 이 캡처되지 않음(state $(r_get '.state')): $(r_last_trace)"
sum="$(shasum "$(r_cap "$ID1")" | cut -d' ' -f1)"
r_stop; r_post toolu_g12 agentg12        # 뒤늦은 중복 SubagentStop·PostToolUse
[ "$(r_get '.state')" = RESULT_READY ] && [ "$(shasum "$(r_cap "$ID1")" | cut -d' ' -f1)" = "$sum" ] \
  && [ "$(jq -c 'select(.reason=="CAPTURED")' "$RND/hook-trace.jsonl" | wc -l | tr -d ' ')" = 1 ] || fail "G12: 중복·지연 훅이 캡처를 덮어씀"
role_ro "validator-bg-d" "design-validator-round-01" "$R/v1.json"
[ "$RC" = 0 ] && [ "$(jq -r '.verdict' "$R/v1.json")" = PASS ] || { cat "$R/last.log"; fail "G14: 실제 최종 보고가 기존 게이트로 수용되지 않음 (rc $RC)"; }
[ "$(jq -r '.state' "$RND/requests/$ID1.json")" = CONSUMED ] && [ ! -e "$RND/pending.json" ] || fail "G14: 수용 뒤 요청이 CONSUMED 가 아님"
[ "$(wc -l < .agent-work/usage.jsonl | tr -d ' ')" = 1 ] || fail "G14: usage 행이 1개가 아님: $(cat .agent-work/usage.jsonl)"
# 인계 뒤 API 요청 3개(Bash 호출·중간 종료·Handback) 전부가 한 번씩 — 중간 종료 때문에 앞선 usage 를 잃거나 두 번 세지 않는다
jq -e --arg id "$ID1" '.request_id == $id and .agent_id == "agentg12" and .num_turns == 3 and .output == 30 and .input_uncached == 6 and .cache_read == 300 and .context_last_turn == 102' .agent-work/usage.jsonl >/dev/null \
  || fail "G14: usage 가 인계 뒤 전체 요청을 한 번씩 집계하지 않음: $(cat .agent-work/usage.jsonl)"
r_stop
[ "$(jq -r '.state' "$RND/requests/$ID1.json")" = CONSUMED ] || fail "G14: 소비된 요청의 상태가 늦은 SubagentStop 으로 바뀜"
[ ! -s "$CLI_LOG" ] || fail "G14: CLI 가 호출됨: $(cat "$CLI_LOG")"
pass "G12·G14. 종결 뒤 같은 요청·같은 Agent 의 Handback 만 1회 캡처·수용(CONSUMED), usage 1행·중복 없음, 늦은 훅은 무시"

# ---------- G14 기존 결속 실패는 보류 뒤에도 그대로 거부 ----------
role_ro "validator-bg-e" "design-validator-round-02" "$R/v2.json"
[ "$RC" = 42 ] || { cat "$R/last.log"; fail "G14: 두 번째 요청이 발행되지 않음 (rc $RC)"; }
ID2="$(r_get '.request_id')"
r_pre toolu_g14; r_post toolu_g14 agentg14
r_agent agentg14 claude-sonnet-5-5                                    # 요청과 다른 모델로 돈 Agent
r_prompt; r_launch rtu_g14 btask1414; r_asst end_turn "$(jq -nc '[{type:"text", text:"Waiting."}]')"
r_stop
[ "$(r_get '.state')" = DISPATCHED ] && [ ! -e "$(r_cap "$ID2")" ] || fail "G14: 모델이 다른 Agent 의 중간 종료가 보류되지 않음"
r_note btask1414 rtu_g14
r_asst tool_use "$(jq -nc --arg r "$PASS_JSON" '[{type:"tool_use", id:"hbg14", name:"SubagentHandback", input:{message:$r}}]')"
r_stop
role_ro "validator-bg-f" "design-validator-round-02" "$R/v2.json"
[ "$RC" = 43 ] && grep -q NATIVE_MODEL_MISMATCH "$R/last.log" && [ ! -e "$R/v2.json" ] || { cat "$R/last.log"; fail "G14: 보류 뒤 캡처된 다른 모델의 결과가 거부되지 않음 (rc $RC)"; }
pass "G14. 보류 뒤 캡처된 결과도 기존 결속 검사(모델 불일치 → NATIVE_MODEL_MISMATCH)를 그대로 받는다"

echo "smoke-native-background-capture: 전부 통과"
