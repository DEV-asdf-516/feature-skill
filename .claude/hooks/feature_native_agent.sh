#!/usr/bin/env bash
# =============================================================
# feature-skill native Agent 훅 — dispatch 검증·프롬프트 주입(PreToolUse) / 실행 확인(PostToolUse) / 원문 결과 캡처(SubagentStop)
# 등록(.claude/settings.json): PreToolUse·PostToolUse matcher "Agent|SendMessage", SubagentStop(matcher 없음 또는 "feature-.*").
# 러너 쪽 계약은 .claude/skills/feature/scripts/native-agent-bridge.sh 머리말 참고.
#
# 간섭 범위: feature 전용 요청(FEATURE-NATIVE-DISPATCH 한 줄 / feature-* agent 종류)만 다룬다. 그 밖의 Agent·SendMessage 호출과
# 다른 subagent 의 종료에는 아무 출력 없이 exit 0 이다(일반 Claude Code 사용을 건드리지 않는다).
# 결과 원본은 Claude Code 가 쓴 전사(agent_transcript_path)에서만 읽는다:
#   · SubagentHandback 도구 호출이 있으면 그 호출의 input.message 가 보고다(SubagentStop 의 last_assistant_message 는 closing text 일 뿐 — 보고로 쓰지 않는다).
#   · 없으면 stop_reason=end_turn 인 마지막 assistant 메시지의 text.
#   · 요청↔Agent 결속은 이벤트 순서 추측이 아니라 내용이다: 그 Agent 가 마지막으로 받은 프롬프트의 첫 줄(요청 경로)과 전체 해시.
#
# 요청 상태 전이(이 훅이 쓰는 것):
#   PREPARED ──PreToolUse(검증 통과)──▶ DISPATCHING   dispatch 를 '시도'했다는 기록일 뿐이다. PreToolUse 훅들은 병렬로 돌고 하나라도 거부하면
#                                                   도구가 실행되지 않는다 — 이 훅의 allow 는 실행의 증거가 아니다(다른 훅의 거부를 이 훅은 볼 수 없다).
#   DISPATCHING ──PostToolUse(같은 tool_use_id·세션·도구, 실행 성공 응답)──▶ DISPATCHED
#   DISPATCHING|DISPATCHED ──SubagentStop(전사 결속 통과)──▶ RESULT_READY      SubagentStop 이 PostToolUse 보다 먼저 올 수 있다(foreground Agent).
#   늦은·중복 PostToolUse 는 상태를 바꾸지 않는다(보조 기록만). 다른 호출의 이벤트(tool_use_id·세션·agent id 불일치)는 흔적만 남기고 무시한다.
#   DISPATCHING 에서 PostToolUse 가 끝내 오지 않으면 '실행 여부 불명'이다 — 이 훅은 같은 요청의 두 번째 dispatch 를 거부한다.
#   거부 확인과 재시도(redispatch)·정리(discard)는 러너(native-agent-bridge.sh)가 메인 전사의 증거로 판정한다.
# =============================================================
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
payload="$(cat)"
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null)" || exit 0
FEATURE_AGENT_RE='^feature-(designer|validator|worker|reviewer|fixer)$'
REQUEST_PATH_RE='^/.*/native-agent/requests/native-[A-Za-z0-9-]+\.json$'

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }
now() { date '+%FT%T%z'; }
req_update() { # request-file jq-filter [args...]
  local f="$1" filter="$2"; shift 2
  jq "$@" "$filter" "$f" > "$f.hook.$$.tmp" && mv "$f.hook.$$.tmp" "$f"
}
# 요청 파일의 '상태 읽기 → 판정 → 쓰기'는 잠금 안에서 한다: PostToolUse 와 SubagentStop(보고 대기 중)·러너의 수용이 겹칠 수 있다.
# 러너(native-agent-bridge.sh 의 native_req_lock)와 같은 규약이다 — <요청 파일>.lock 디렉터리, 1분 넘은 잠금은 죽은 프로세스의 것으로 보고 치운다.
LOCK_HELD=""
req_lock() { # request-file
  local l="$1.lock" i=0
  while ! mkdir "$l" 2>/dev/null; do
    if [ -n "$(find "$l" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$l" 2>/dev/null; continue; fi
    i=$((i + 1)); [ "$i" -lt 200 ] || return 1
    sleep 0.05
  done
  LOCK_HELD="$l"
}
req_unlock() { [ -z "$LOCK_HELD" ] || rmdir "$LOCK_HELD" 2>/dev/null; LOCK_HELD=""; }
trap req_unlock EXIT
deny() { # reason [request-file]
  [ -z "${2:-}" ] || [ ! -f "${2:-}" ] || req_update "$2" '.last_denial={reason:$r, at:$now}' --arg r "$1" --arg now "$(now)" 2>/dev/null || true
  jq -n --arg r "feature-skill native bridge: $1" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
  exit 0
}
# 요청 파일이 이 브리지가 쓴 형태이고 pending 포인터가 가리키는 바로 그 요청인지
request_valid() { # request-file
  local f="$1" pend
  [[ "$f" =~ $REQUEST_PATH_RE ]] && [ -f "$f" ] || return 1
  jq -e --arg f "$f" '.version==1 and .backend=="claude_native" and .request_path==$f and (.request_id|type=="string")' "$f" >/dev/null 2>&1 || return 1
  pend="$(dirname "$(dirname "$f")")/pending.json"
  [ -f "$pend" ] && [ "$(jq -r '.request_path // ""' "$pend" 2>/dev/null)" = "$f" ]
}

# feature 전용 Agent 의 이벤트인데 요청에 결속하지 못한 경우의 흔적(JSONL). 일반 Agent·subagent 이벤트는 여기 오지 않는다.
# 캡처가 왜 없었는지(이벤트 미발화 / 프롬프트 미인식 / 상태 불일치)를 사후에 가릴 수 있어야 한다 — 조용한 exit 만으로는 구분되지 않는다.
trace() { # reason [request-file]
  local dir="${FEATURE_NATIVE_HOOK_TRACE_DIR:-}"
  if [ -z "$dir" ]; then
    if [ -n "${2:-}" ] && [ -f "${2:-}" ]; then dir="$(dirname "$(dirname "$2")")"; else dir="${CLAUDE_PROJECT_DIR:-.}/.agent-work/native-agent"; fi
  fi
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s' "$payload" | jq -c --arg r "$1" --arg now "$(now)" --arg req "${2:-}" \
    '{at:$now, event:.hook_event_name, reason:$r, request:$req, agent_id:(.agent_id // null), agent_type:(.agent_type // null), session_id:(.session_id // null), transcript:(.agent_transcript_path // null)}' \
    >> "$dir/hook-trace.jsonl" 2>/dev/null || true
}
# 재개(SendMessage)된 Agent 가 받는 메시지는 전사에 isMeta user 레코드로, 하네스가 앞뒤에 고정 문구를 붙인 형태로 남는다(Claude Code 2.1.330 실측).
# 알려진 포장만 벗긴다 — 모르는 포장은 벗기지 않고 전체 해시를 그대로 기록해 러너가 불수용하게 한다(추측으로 맞추지 않는다).
RESUME_WRAP_PRE='The coordinator sent a message while you were working:
'
RESUME_WRAP_SUF='

Address this before completing your current task.'

case "$event" in
  PreToolUse)
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // ""')"
    case "$tool" in
      Agent) field=prompt;;
      SendMessage) field="$(printf '%s' "$payload" | jq -r 'if (.tool_input.message|type)=="string" then "message" elif (.tool_input.content|type)=="string" then "content" else "" end')";;
      *) exit 0;;
    esac
    [ -n "$field" ] || exit 0
    text="$(printf '%s' "$payload" | jq -r --arg f "$field" '.tool_input[$f] // ""')"
    subagent="$(printf '%s' "$payload" | jq -r '.tool_input.subagent_type // ""')"
    line="$(printf '%s\n' "$text" | head -1)"
    if [[ "$line" != "FEATURE-NATIVE-DISPATCH "* ]]; then
      # feature 전용 Agent 는 러너가 발행한 요청으로만 실행한다 — 메인이 임의 프롬프트로 직접 부르는 것을 막는다. 그 밖의 호출은 통과.
      if [ "$tool" = Agent ] && [[ "$subagent" =~ $FEATURE_AGENT_RE ]]; then
        deny "$subagent 는 feature-run.sh 가 발행한 요청(pending.json 의 dispatch 한 줄)으로만 실행한다"
      fi
      exit 0
    fi
    req="${line#FEATURE-NATIVE-DISPATCH }"
    [ "$(printf '%s' "$text" | grep -c '')" -le 1 ] || deny "dispatch 는 한 줄이어야 한다 — 내용을 덧붙이거나 고치지 않는다" "$req"
    request_valid "$req" || deny "요청 파일이 없거나 현재 pending 요청이 아니다: $req"
    req_lock "$req" || deny "요청 파일 잠금을 얻지 못했다(다른 훅·러너가 쓰는 중) — 잠시 뒤 같은 feature-run 명령을 재실행해 상태를 확인"
    state="$(jq -r '.state' "$req")"
    # DISPATCHING = 앞선 dispatch 시도가 기록됐고 실행 여부가 확인되지 않았다. 거부가 확인되기 전에는 같은 요청을 다시 보내지 않는다
    # (실제로 실행됐다면 두 번째 호출은 같은 작업을 두 번 시킨다). 앞선 시도의 기록은 건드리지 않는다.
    if [ "$state" = DISPATCHING ]; then
      trace DUPLICATE_DISPATCH_BLOCKED "$req"
      jq -n --arg r "feature-skill native bridge: 이 요청은 이미 dispatch 를 시도했고(tool_use_id $(jq -r '.dispatch_attempt.tool_use_id // "?"' "$req")) 실행 여부가 확인되지 않았다 — 다시 보내지 않는다. 같은 feature-run 명령을 재실행하면 러너가 그 시도의 거부·실행 여부를 판정해 다음 행동을 알려 준다" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
      exit 0
    fi
    [ "$state" = PREPARED ] || deny "요청 state 가 $state 다 — 이미 dispatch 됐거나 끝난 요청은 다시 호출하지 않는다(같은 feature-run 명령을 재실행해 상태를 확인)" "$req"
    tool_use_id="$(printf '%s' "$payload" | jq -r '.tool_use_id // ""')"
    [ -n "$tool_use_id" ] || deny "훅 입력에 tool_use_id 가 없어 이 호출의 실행 확인(PostToolUse)을 결속할 수 없다" "$req"
    intent="$(jq -r '.session_intent' "$req")"; session_id="$(printf '%s' "$payload" | jq -r '.session_id // ""')"
    owner="$(jq -r '.owner_session_id // ""' "$req")"
    [ -n "$session_id" ] || deny "훅 입력에 session_id 가 없어 요청 소유 세션을 결속할 수 없다" "$req"
    [ -z "$owner" ] || [ "$owner" = "$session_id" ] || deny "이 요청은 다른 메인 세션($owner)의 것이다 — 선점하지 않는다" "$req"
    payload_file="$(jq -r '.prompt_path' "$req")"
    [ -f "$payload_file" ] && [ "$(sha256_of < "$payload_file")" = "$(jq -r '.dispatch_sha256' "$req")" ] || deny "payload 파일이 없거나 요청 발행 뒤 바뀌었다: $payload_file" "$req"
    if [ "$tool" = Agent ]; then
      [ "$intent" = NEW ] || deny "이 요청은 기존 Agent($(jq -r '.resume_agent_id' "$req"))의 재개다 — Agent 가 아니라 SendMessage 로 보낸다(묵시적 fresh Agent 금지)" "$req"
      [ "$subagent" = "$(jq -r '.agent_definition' "$req")" ] || deny "subagent_type 은 $(jq -r '.agent_definition' "$req") 여야 한다(받은 값: ${subagent:-없음})" "$req"
      printf '%s' "$payload" | jq -e '(.tool_input.model // "") == "" and (.tool_input.isolation // "") == ""' >/dev/null \
        || deny "model·isolation 인자를 주지 않는다 — 모델은 agent 정의(full model ID)가 정하고, 작업 위치는 기존 피처 worktree 다" "$req"
    else
      [ "$intent" = RESUME ] || deny "이 요청은 새 Agent 호출이다 — SendMessage 가 아니라 Agent(subagent_type $(jq -r '.agent_definition' "$req"))로 보낸다" "$req"
      [ "$(printf '%s' "$payload" | jq -r '.tool_input.to // ""')" = "$(jq -r '.resume_agent_id' "$req")" ] \
        || deny "재개 대상(to)은 $(jq -r '.resume_agent_id' "$req") 여야 한다" "$req"
    fi
    # 여기서는 DISPATCHED 로 올리지 않는다 — 시도만 기록한다. 실행 확인은 PostToolUse(같은 tool_use_id)·SubagentStop(전사) 몫이다.
    # transcript_path(메인 세션 전사)는 러너가 이 tool_use_id 의 도구 결과(거부/실행)를 확인할 때 읽는다.
    req_update "$req" '.state="DISPATCHING" | .owner_session_id=$sid | del(.last_denial)
        | .dispatch_attempt={n:((.dispatch_history // [])|length + 1), tool:$tool, tool_use_id:$tu, session_id:$sid, transcript_path:(if $tp=="" then null else $tp end), at:$now}' \
      --arg now "$(now)" --arg tool "$tool" --arg tu "$tool_use_id" --arg sid "$session_id" --arg tp "$(printf '%s' "$payload" | jq -r '.transcript_path // ""')" \
      || deny "요청 상태 기록 실패" "$req"
    req_unlock
    printf '%s' "$payload" | jq --arg f "$field" --rawfile p "$payload_file" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"allow", permissionDecisionReason:"feature-skill native request", updatedInput:(.tool_input + {($f): $p})}}'
    exit 0;;

  PostToolUse)
    # 실행 확인: 이 요청의 dispatch 시도(같은 tool_use_id·메인 세션·도구)가 실제로 실행에 성공했을 때만 DISPATCHING → DISPATCHED.
    # async_launched 는 완료가 아니다 — 완료·보고는 SubagentStop 캡처가 정한다. 늦은·중복 이벤트는 상태를 바꾸지 않는다.
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // ""')"
    case "$tool" in Agent|SendMessage) ;; *) exit 0;; esac
    # 요청 파일의 위치는 입력의 첫 줄에서만 얻는다(주입 뒤의 payload 첫 줄 또는 주입 전 dispatch 한 줄) — 결속 판정은 아래의 tool_use_id·세션·도구다.
    line="$(printf '%s' "$payload" | jq -r '(.tool_input.prompt // .tool_input.message // .tool_input.content // "") | if type=="string" then split("\n")[0] else "" end')"
    case "$line" in
      "FEATURE-NATIVE-REQUEST "*) req="${line#FEATURE-NATIVE-REQUEST }";;
      "FEATURE-NATIVE-DISPATCH "*) req="${line#FEATURE-NATIVE-DISPATCH }";;
      *) exit 0;;
    esac
    request_valid "$req" || { trace POST_REQUEST_NOT_PENDING "$req"; exit 0; }
    req_lock "$req" || { trace POST_LOCK_TIMEOUT "$req"; exit 0; }
    state="$(jq -r '.state' "$req")"
    tu="$(printf '%s' "$payload" | jq -r '.tool_use_id // ""')"
    # 다른 호출의 이벤트는 이 요청의 상태도 보조 기록도 바꾸지 못한다.
    [ -n "$tu" ] && [ "$tu" = "$(jq -r '.dispatch_attempt.tool_use_id // ""' "$req")" ] || { trace POST_TOOL_USE_ID_MISMATCH "$req"; exit 0; }
    [ "$(printf '%s' "$payload" | jq -r '.session_id // ""')" = "$(jq -r '.owner_session_id // ""' "$req")" ] || { trace POST_SESSION_MISMATCH "$req"; exit 0; }
    [ "$tool" = "$(jq -r '.dispatch_attempt.tool // ""' "$req")" ] || { trace POST_TOOL_MISMATCH "$req"; exit 0; }
    # 응답 형태는 도구마다 다르다(Claude Code 2.1.330 실측):
    #   Agent(background)  {isAsync:true, status:"async_launched", agentId, resolvedModel, …}
    #   SendMessage(재개)  {success:true, message:"Resuming agent …", resumedAgentId, …}   — status·agentId 가 없다.
    #   success:true 만으로는 재개의 증거가 아니다(다른 세션으로 보낸 메시지도 success:true 다) → resumedAgentId 가 결속된 Agent 여야 한다.
    # 그 밖의 형태(오류 문자열, 모르는 status)는 실행 확인으로 치지 않는다 — 형태만 기록하고 상태는 그대로 둔다.
    resp="$(printf '%s' "$payload" | jq -c '.tool_response as $r
      | (if ($r|type)=="string" then (try ($r|fromjson) catch null) else $r end) as $o
      | if ($o|type)=="object" then {shape:"object", keys:($o|keys), status:($o.status // null), success:($o.success // null),
            agent_id:($o.agentId // null), resumed_agent_id:($o.resumedAgentId // null), resolved_model:($o.resolvedModel // null)}
        else {shape:($r|type), keys:[], status:null, success:null, agent_id:null, resumed_agent_id:null, resolved_model:null} end' 2>/dev/null)" \
      || { trace POST_RESPONSE_UNREADABLE "$req"; exit 0; }
    if [ "$tool" = Agent ]; then
      confirmed="$(printf '%s' "$resp" | jq -r '.status=="async_launched" and (.agent_id|type=="string" and length>0)')"
    else
      confirmed="$(printf '%s' "$resp" | jq -r --arg want "$(jq -r '.resume_agent_id // ""' "$req")" '.success==true and ($want|length>0) and .resumed_agent_id==$want')"
    fi
    post_filter='.post_tool={status:($r.status // (if $ok and $tool=="SendMessage" then "resumed" else null end)), agent_id:($r.agent_id // $r.resumed_agent_id), resolved_model:$r.resolved_model,
        tool:$tool, tool_use_id:$tu, launch_confirmed:$ok, late:$late, response_shape:$r.shape, response_keys:$r.keys, at:$now}'
    case "$state" in
      DISPATCHING)
        if [ "$confirmed" = true ]; then
          req_update "$req" "$post_filter"' | .state="DISPATCHED" | .dispatched_at=$now | .dispatched_agent_id=.post_tool.agent_id' \
            --argjson r "$resp" --argjson ok true --argjson late false --arg tool "$tool" --arg tu "$tu" --arg now "$(now)" || trace POST_WRITE_FAILED "$req"
        else
          req_update "$req" "$post_filter" --argjson r "$resp" --argjson ok false --argjson late false --arg tool "$tool" --arg tu "$tu" --arg now "$(now)" || true
          trace POST_LAUNCH_UNCONFIRMED "$req"
        fi;;
      RESULT_READY)
        # SubagentStop 이 먼저 캡처했다 — 늦은 PostToolUse 는 RESULT_READY 를 덮어쓰지 않는다. 실행 확인 기록이 아직 없을 때 한 번만
        # 보조 기록으로 남긴다(러너의 수용 검사가 이 agent id 를 전사의 agent id 와 대조한다).
        if jq -e '.post_tool.launch_confirmed != true' "$req" >/dev/null 2>&1; then
          req_update "$req" "$post_filter" --argjson r "$resp" --argjson ok "$confirmed" --argjson late true --arg tool "$tool" --arg tu "$tu" --arg now "$(now)" || true
          trace POST_LATE_RECORDED "$req"
        else trace POST_DUPLICATE_IGNORED "$req"; fi;;
      *) trace "POST_IGNORED_STATE_$state" "$req";;
    esac
    exit 0;;

  SubagentStop)
    agent_type="$(printf '%s' "$payload" | jq -r '.agent_type // ""')"
    [[ "$agent_type" =~ $FEATURE_AGENT_RE ]] || exit 0
    transcript="$(printf '%s' "$payload" | jq -r '.agent_transcript_path // ""')"
    [ -f "$transcript" ] || { trace TRANSCRIPT_MISSING; exit 0; }
    # 이 Agent 가 마지막으로 받은 인계 프롬프트와 그 뒤의 레코드만 본다 — 재개된 Agent 의 이전 턴을 섞지 않는다.
    # 인계 프롬프트 = 문자열 content 의 user 레코드 중 'FEATURE-NATIVE-REQUEST <경로>' 줄을 가진 마지막 것. 신규 호출은 비-meta 레코드의 첫 줄,
    # 재개(SendMessage)는 isMeta 레코드의 포장 안쪽이다 — isMeta 여부로 거르지 않는다(시스템 리마인더 같은 다른 meta 레코드는 그 줄이 없다).
    read_summary() { jq -sc '
      def num0: if type=="number" then . else 0 end;
      def objf($k): if type=="object" then .[$k] else null end;
      (to_entries | map(select(.value.type=="user" and (.value.message.content|type)=="string" and (.value.message.content|test("(^|\\n)FEATURE-NATIVE-REQUEST /")))) | last) as $p
      | if $p == null then {prompt:null} else
          ([.[$p.key+1:][] | select(.type=="assistant")]) as $a
          | ([$a[] | .message.content[]? | select(.type=="tool_use" and .name=="SubagentHandback") | .input.message] | last) as $hb
          | ($a | last) as $last
          | { prompt: $p.value.message.content, prompt_is_meta: ($p.value.isMeta == true),
              models: ([$a[] | .message.model // empty] | unique),
              requested_models: ([$a[] | .requestedModel // empty] | unique),
              efforts: ([$a[] | .effort // empty] | unique),
              session_ids: ([$a[] | .sessionId // empty] | unique),
              agent_ids: ([$a[] | .agentId // empty] | unique),
              report: (if ($hb|type)=="string" then {source:"SubagentHandback", text:$hb}
                       elif $last != null and $last.message.stop_reason=="end_turn" then {source:"final_message", text:([$last.message.content[]? | select(.type=="text") | .text] | join(""))}
                       else null end),
              last_stop_reason: ($last.message.stop_reason // null),
              # usage: API 요청(message id)별 마지막 usage 를 합산한다. 누락을 0 으로 숨기지 않는다 —
              #   usage 가 없는 요청 수(usage_missing_requests)와 네 토큰 필드 중 하나라도 없거나 숫자가 아니거나 음수인 요청 수(usage_incomplete_requests)를 같이 남긴다.
              #   usage.iterations 에 본 요청(type message)이 아닌 항목(advisor_message 등 보조 모델 호출)이 있는 요청 수(usage_side_iteration_requests)도 센다 —
              #   그 항목의 토큰은 요청의 usage 합계에 들어 있지 않다(Claude Code 2.1.330 실제 전사에서 확인: 합계 = type message 항목의 합).
              #   message.id 가 비어 있지 않은 문자열이 아닌 assistant 레코드 수(usage_unidentified_records)도 센다 — id 없이는 어느 레코드가 같은 요청인지 알 수 없어
              #   요청 단위로 묶지 않는다(id 없는 레코드를 한 요청으로 묶으면 마지막 것만 남아 과소 집계된다). 합계에는 id 가 있는 요청만 들어간다.
              #   넷 중 하나라도 0 이 아니면 러너가 이 호출의 비용을 추정하지 않는다(unknown). 완료 판정·보고 수용과는 무관한 telemetry 다.
              usage: (([$a[] | {id:.message.id, u:.message.usage}] | map(select((.id|type)=="string" and (.id|length) > 0)) | group_by(.id) | map(last.u)) as $reqs
                     | ([$a[] | select(((.message.id|type)=="string" and (.message.id|length) > 0) | not)]) as $unid
                     | ($reqs | map(select(type=="object"))) as $obs
                     | if ($obs|length)==0 and ([$unid[] | select((.message.usage|type)=="object")] | length)==0 then null else {api_requests:($reqs|length), usage_missing_requests:(($reqs|length) - ($obs|length)),
                          usage_unidentified_records:($unid|length),
                          usage_incomplete_requests:($obs | map(select([.input_tokens, .output_tokens, .cache_read_input_tokens, .cache_creation_input_tokens] | all(type=="number" and . >= 0) | not)) | length),
                          usage_side_iteration_requests:($obs | map(select((.iterations|type)=="array" and any(.iterations[]; (type=="object" and .type=="message") | not))) | length),
                          input_tokens:($obs|map(.input_tokens|num0)|add // 0), cache_read_input_tokens:($obs|map(.cache_read_input_tokens|num0)|add // 0),
                          cache_creation_input_tokens:($obs|map(.cache_creation_input_tokens|num0)|add // 0), output_tokens:($obs|map(.output_tokens|num0)|add // 0),
                          cache_write_5m_input_tokens:($obs|map(.cache_creation|objf("ephemeral_5m_input_tokens")|num0)|add),
                          cache_write_1h_input_tokens:($obs|map(.cache_creation|objf("ephemeral_1h_input_tokens")|num0)|add),
                          speeds:($obs|map(.speed // "unreported")|unique), inference_geos:($obs|map(.inference_geo // "unreported")|unique)} end),
              # context: 마지막 본 모델 호출이 실제로 넣은 입력(컨텍스트 창 점유량) — 워커 세션 교체 판단의 실측값이다. 위 usage(비용 관측)와 따로 잰다:
              #   앞선 요청의 usage 가 불완전하거나 보조 모델 호출이 있어 비용을 추정할 수 없어도, 마지막 호출의 입력은 그 호출의 usage 만으로 정해진다.
              #   마지막 assistant 레코드의 usage 만 본다(앞선 요청으로 거슬러 올라가지 않는다 — 옛 값을 현재 컨텍스트처럼 쓰지 않는다).
              #   usage.iterations 에 항목이 있으면 그중 마지막 type message 항목을 쓴다 — 보조 모델 호출이 낀 요청의 usage 합계는 본 모델 호출 여러 번의 합이라
              #   컨텍스트 크기가 아니다(실제 전사: 합계의 캐시 읽기 186251 = 88641 + 97610, 마지막 호출의 입력은 2 + 97610). 그 항목이 없거나 불완전하면 합계로 대신하지 않고 null 이다.
              #   iterations 가 없으면(또는 빈 배열) 요청 = 본 모델 호출 1회이므로 usage 자체를 쓴다. 세 입력 필드(input·cache_read·cache_creation)가 전부 0 이상의 숫자일 때만 값이 있다 — 누락을 0 으로 읽지 않는다.
              context: ($last.message.usage
                        | if type != "object" then null
                          elif .iterations == null or .iterations == [] then {src:"last_request_usage", u:.}
                          elif (.iterations|type) != "array" then null
                          else {src:"last_message_iteration", u:([.iterations[] | select(type=="object" and .type=="message")] | last)} end
                        | if . == null or (.u|type) != "object" then null
                          elif ([.u.input_tokens, .u.cache_read_input_tokens, .u.cache_creation_input_tokens] | all(type=="number" and . >= 0)) | not then null
                          else {tokens:(.u.input_tokens + .u.cache_read_input_tokens + .u.cache_creation_input_tokens), source:.src} end),
              compacted: (any(.[$p.key+1:][]; .type=="system" and .subtype=="compact_boundary")) }
        end' "$transcript" 2>/dev/null; }
    # SubagentStop 은 전사의 마지막 레코드(보고를 담은 SubagentHandback 호출·최종 메시지)가 디스크에 쓰이기 전에 발화할 수 있다
    # (Claude Code 2.1.330 실모델 POC: 보고 레코드 timestamp 와 훅 실행이 같은 초 — 캡처에는 앞의 두 요청만 있었다).
    # 보고가 아직 없으면 잠깐 기다리며 다시 읽는다. 끝까지 없으면 NO_REPORT 로 남긴다(러너가 성공 보고로 받지 않는다) — 추측으로 채우지 않는다.
    summary=""; tries=0
    while :; do
      summary="$(read_summary)" || { trace TRANSCRIPT_UNREADABLE; exit 0; }
      printf '%s' "$summary" | jq -e '.report != null and ((.report.text // "")|length) > 0' >/dev/null 2>&1 && break
      tries=$((tries + 1)); [ "$tries" -lt "${FEATURE_NATIVE_REPORT_WAIT_TRIES:-20}" ] || break
      sleep 0.5
    done
    line="$(printf '%s' "$summary" | jq -r '.prompt // ""' | grep -m1 '^FEATURE-NATIVE-REQUEST /' || true)"
    [ -n "$line" ] || { trace NO_REQUEST_PROMPT; exit 0; }
    req="${line#FEATURE-NATIVE-REQUEST }"
    request_valid "$req" || { trace REQUEST_NOT_PENDING "$req"; exit 0; }
    req_lock "$req" || { trace STOP_LOCK_TIMEOUT "$req"; exit 0; }
    # 중복 이벤트: 이미 캡처된(또는 끝난) 요청은 다시 쓰지 않는다 — RESULT_READY 로의 전이는 한 번뿐이다.
    # DISPATCHING 도 받는다: SubagentStop 은 PostToolUse 보다 먼저 올 수 있다(foreground Agent 는 도구가 끝나야 PostToolUse 가 온다).
    # PREPARED 는 받지 않는다 — 이 훅이 dispatch 를 검증한 적 없는 요청의 결과다.
    from_state="$(jq -r '.state' "$req")"
    case "$from_state" in DISPATCHING|DISPATCHED) ;; *) trace "STATE_$from_state" "$req"; exit 0;; esac
    # 전사 결속(정체성): 이 종료 이벤트가 이 요청을 dispatch 한 메인 세션의, 이 요청이 지정한 Agent 의 것인가. 어긋나면 다른 호출의 이벤트다 —
    # 캡처하지 않고 요청 상태도 바꾸지 않는다. (프롬프트 해시·모델·effort 같은 '내용' 불일치는 캡처에 그대로 기록해 러너가 불수용한다.)
    stop_agent="$(printf '%s' "$payload" | jq -r '.agent_id // ""')"
    [ -n "$stop_agent" ] || { trace STOP_NO_AGENT_ID "$req"; exit 0; }
    [ "$(printf '%s' "$payload" | jq -r '.session_id // ""')" = "$(jq -r '.owner_session_id // ""' "$req")" ] || { trace STOP_SESSION_MISMATCH "$req"; exit 0; }
    [ "$agent_type" = "$(jq -r '.agent_definition // ""' "$req")" ] || { trace STOP_AGENT_TYPE_MISMATCH "$req"; exit 0; }
    printf '%s' "$summary" | jq -e --arg a "$stop_agent" '.agent_ids | all(. == $a)' >/dev/null 2>&1 || { trace STOP_TRANSCRIPT_AGENT_MISMATCH "$req"; exit 0; }
    if [ "$(jq -r '.session_intent' "$req")" = RESUME ]; then
      [ "$stop_agent" = "$(jq -r '.resume_agent_id // ""' "$req")" ] || { trace STOP_AGENT_MISMATCH "$req"; exit 0; }
    fi
    bound_agent="$(jq -r '.dispatched_agent_id // ""' "$req")"
    [ -z "$bound_agent" ] || [ "$bound_agent" = "$stop_agent" ] || { trace STOP_AGENT_MISMATCH "$req"; exit 0; }
    # 알려진 재개 포장이면 벗긴 본문이 Agent 가 받은 payload 다. 그 밖에는 메시지 전체가 payload 여야 한다.
    # (명령 치환이 끝의 개행을 지우지 않도록 표식 문자를 붙였다 뗀다 — 해시는 바이트 단위다.)
    wrapper=none
    prompt="$(printf '%s' "$summary" | jq -j --arg pre "$RESUME_WRAP_PRE" --arg suf "$RESUME_WRAP_SUF" \
      '.prompt as $m | if ($m|startswith($pre)) and ($m|endswith($suf)) then ($m|ltrimstr($pre)|rtrimstr($suf)) else $m end'; printf x)"; prompt="${prompt%x}"
    printf '%s' "$summary" | jq -e --arg pre "$RESUME_WRAP_PRE" --arg suf "$RESUME_WRAP_SUF" '(.prompt|startswith($pre)) and (.prompt|endswith($suf))' >/dev/null 2>&1 && wrapper=coordinator_message
    id="$(jq -r '.request_id' "$req")"; results="$(dirname "$(dirname "$req")")/results"
    mkdir -p "$results" || exit 0
    msg="$results/$id.message.txt"; cap="$results/$id.capture.json"
    report_status=OK
    printf '%s' "$summary" | jq -e '.report != null and ((.report.text // "")|length) > 0' >/dev/null 2>&1 || report_status=NO_REPORT
    if [ "$report_status" = OK ]; then printf '%s' "$summary" | jq -j '.report.text' > "$msg.$$.tmp" && mv "$msg.$$.tmp" "$msg" || exit 0; else msg=""; fi
    # 전사의 프롬프트는 payload 파일에서 마지막 개행이 빠진 형태일 수 있다 — 두 형태 모두 계산해 요청의 해시와 같은 쪽을 기록한다(다르면 원문 해시 그대로 → 러너가 불수용).
    want="$(jq -r '.dispatch_sha256' "$req")"
    observed="$(printf '%s' "$prompt" | sha256_of)"
    [ "$observed" = "$want" ] || { alt="$(printf '%s\n' "$prompt" | sha256_of)"; [ "$alt" != "$want" ] || observed="$alt"; }
    printf '%s' "$summary" | jq --arg id "$id" --arg aid "$stop_agent" --arg at "$agent_type" \
      --arg sid "$(printf '%s' "$payload" | jq -r '.session_id // ""')" --arg tp "$transcript" --arg obs "$observed" --arg wrap "$wrapper" --arg msg "$msg" --arg st "$report_status" \
      --arg closing "$(printf '%s' "$payload" | jq -r '.last_assistant_message // ""')" --arg now "$(now)" --argjson tries "$tries" --arg from "$from_state" \
      '{version:1, request_id:$id, agent_id:$aid, agent_type:$at, session_id:$sid, agent_transcript_path:$tp,
        transcript_session_ids:.session_ids, transcript_agent_ids:.agent_ids,
        dispatch_sha256_observed:$obs, prompt_wrapper:$wrap, prompt_record_is_meta:.prompt_is_meta, models_observed:.models, requested_models_observed:.requested_models, efforts_observed:.efforts,
        report_status:$st, report_source:(.report.source // null), message_path:(if $msg=="" then null else $msg end),
        last_stop_reason:.last_stop_reason, closing_text_ignored:($closing|length), usage:.usage, context_last_turn:(.context.tokens // null), context_last_turn_source:(.context.source // null),
        compaction_observed:.compacted, report_wait_tries:$tries, captured_from_state:$from, captured_at:$now}' > "$cap.$$.tmp" && mv "$cap.$$.tmp" "$cap" || exit 0
    req_update "$req" '.state="RESULT_READY" | .result_ready_at=$now | .captured_from_state=$from' --arg now "$(now)" --arg from "$from_state" || true
    req_unlock
    trace CAPTURED "$req"
    exit 0;;
esac
exit 0
