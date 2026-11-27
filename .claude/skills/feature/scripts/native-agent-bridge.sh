#!/usr/bin/env bash
# =============================================================
# Native Agent bridge — Shell ↔ 대화형 메인 Claude Code 세션의 네이티브 Agent 인계
# 파일 경로: .claude/skills/feature/scripts/native-agent-bridge.sh   (source 전용 — 로더(scripts/lib/bootstrap.sh)가 읽는다. 단독 실행은 맨 아래 'redispatch'/'discard' 뿐이고, 그 진입은 프로세스당 한 번만 돈다)
#
# Shell 은 현재 대화형 세션의 Agent 도구를 직접 부를 수 없다. 그래서 claude_native 로 라우팅된 역할 호출은 두 번에 나뉜다:
#   1차 실행  PREPARE  : 요청(requests/<id>.json) + 완전히 렌더링한 payload(requests/<id>.prompt.txt) + pending.json 을 원자적으로 쓰고
#                        exit $NATIVE_EXIT_REQUIRED(42) 로 최상위 러너까지 나간다. 이 시점에 모델 결과가 있다고 보지 않는다.
#   (메인)    DISPATCH : 메인 Claude Code 가 pending.json 의 dispatch 한 줄을 Agent(신규) / SendMessage(재개) 에 그대로 넘긴다.
#                        PreToolUse 훅(.claude/hooks/feature_native_agent.sh)이 요청을 검증하고 payload 원문으로 입력을 바꿔 넣는다(메인은 프롬프트를 옮겨 적지 않는다).
#   (훅)      CAPTURE  : SubagentStop 훅이 그 Agent 의 전사(agent_transcript_path)에서 원문 보고·agent id·실제 모델/effort·usage 를 읽어 results/<id>.capture.json 에 남긴다.
#   2차 실행  ACCEPT   : 같은 러너 명령 재실행 → 같은 호출 지점이 pending 을 만나 결속(요청 id·payload 해시·부모 세션·모델·effort·정의 해시·worktree·지문)을 검사하고,
#                        통과한 결과만 기존 CLI 경로와 같은 산출물($out / $raw)로 물질화한 뒤 호출자의 기존 게이트로 돌려준다.
# 상태: PREPARED → DISPATCHING → DISPATCHED → RESULT_READY → CONSUMED,  결속 실패는 REJECTED(자동 복구·자동 재호출·자동 fresh 없음).
#   DISPATCHING = PreToolUse 훅이 dispatch 시도를 기록했다(tool_use_id·메인 세션·전사 경로). 실행의 증거가 아니다 — 다른 PreToolUse 훅·권한 규칙이
#                 같은 호출을 거부했을 수 있다. DISPATCHED 는 PostToolUse 가 같은 tool_use_id 의 실행 성공을 확인했을 때만 된다.
#   DISPATCHING 에서 재실행하면 러너가 메인 전사에서 그 tool_use_id 의 도구 결과를 읽어 판정한다(native_dispatch_evidence):
#     거부 확인(DENIED)  → exit 43 NATIVE_DISPATCH_DENIED(요청 state 불변). 사용자 결정 뒤 'redispatch'(같은 요청을 PREPARED 로) 또는 'discard'.
#     Agent 정의 미발견("Agent type … not found")은 거부 종류가 함께 있어도 DENIED 가 아니다 — 실행 전 거부가 증명되지 않으므로 UNKNOWN(대기·재전송 금지).
#     그 밖(UNKNOWN/EXECUTED) → exit 42 로 대기. 실행 여부 불명인 요청은 다시 보내지 않는다(훅이 두 번째 dispatch 를 거부한다).
#   SubagentStop 은 PostToolUse 보다 먼저 올 수 있다 — DISPATCHING 에서도 전사 결속을 거쳐 RESULT_READY 가 된다.
# 메인이 요약·재작성한 텍스트는 어디에서도 결과 원본으로 읽지 않는다 — 읽는 것은 Claude Code 가 쓴 전사와 훅 페이로드뿐이다.
#
# 종료 코드(기존 0/1/2/3/4/5/6/7 과 겹치지 않는다):
#   42 NATIVE_AGENT_REQUIRED   메인이 dispatch 하고(또는 완료를 기다리고) 같은 명령을 재실행한다. 실패도 사용자 질문도 아니다.
#   43 NATIVE_RESULT_REJECTED  캡처된 결과·pending 이 현재 요청과 결속되지 않는다. 러너가 NEED_USER 로 바꿔 돌려준다.
# =============================================================

NATIVE_EXIT_REQUIRED=42
NATIVE_EXIT_REJECTED=43
NATIVE_REQUEST_VERSION=1
NATIVE_SESSION_LEDGER_VERSION=1
NATIVE_MANAGED_MARKER='# managed-by: feature-skill native-agent — 직접 고치지 않는다(config.sh 의 모델·effort 로 러너가 다시 쓴다)'

native_dir() { printf '%s' "$PROJECT_ROOT/$WORK_DIR/native-agent"; }
native_pending_file() { printf '%s' "$(native_dir)/pending.json"; }
native_sha256_file() { sha256_stdin < "$1"; }
native_bridge_file() { printf '%s' "${BASH_SOURCE[0]}"; }
native_skill_dir() { printf '%s' "$FEATURE_SKILL_DIR"; }

native_agent_name() { # ROLE → agent 정의 이름
  case "$1" in
    DESIGNER) printf 'feature-designer';; VALIDATOR) printf 'feature-validator';; WORKER) printf 'feature-worker';;
    REVIEWER) printf 'feature-reviewer';; FIXER) printf 'feature-fixer';; *) return 1;;
  esac
}

# 호출 지점 식별자(slot): 재실행이 같은 호출 지점에 돌아왔는지 판정한다. label 의 실행 시각(-YYYYMMDD-HHMMSS)과 검증자 key 의 invocation id 는
# 재실행마다 바뀌므로 넣지 않는다. 워커는 unit·태그가 같아도 label 이 같으므로 호출자가 NATIVE_SLOT_SCOPE(unit id)를 준다.
native_slot() { # ROLE label
  printf '%s|%s|%s' "$1" "${NATIVE_SLOT_SCOPE:-}" "$(printf '%s' "$2" | sed -E 's/-[0-9]{8}-[0-9]{6}$//')"
}

native_pending_field() { jq -r "$1" "$(native_pending_file)" 2>/dev/null; }
native_request_file() { native_pending_field '.request_path // empty'; }
native_request_field() { local f; f="$(native_request_file)"; [ -n "$f" ] && [ -f "$f" ] && jq -r "$1" "$f" 2>/dev/null; }
native_pending_present() { [ -f "$(native_pending_file)" ]; }

# 이 호출 지점의 요청이 진행 중인가(재실행 pass) — 편집 역할 호출자가 호출 전 상태를 다시 계산하지 않고 요청에 저장된 값(native_pre_get)을 쓰게 한다.
native_resume_active() { # ROLE label
  native_pending_backend_guard   # 요청이 남아 있는데 그 역할이 더는 native 가 아니면 '호출 전' 구간을 다시 돌리기 전에 멈춘다(호출 전 기준 파일을 덮어쓰지 않는다)
  [ "$(role_backend "$1" 2>/dev/null)" = claude_native ] || return 1
  native_pending_present || return 1
  [ "$(native_pending_field '.slot')" = "$(native_slot "$1" "$2")" ]
}
# 워커 호출 지점 판정(러너의 재개 판정용): 진행 중인 native 요청이 WORKER 의 것이고 scope(unit id 또는 verify-fix/check-fix/review-gap)·tag 가 맞는가.
# slot = "WORKER|<scope>|<tag>" (native_slot). 인자를 생략하면 그 항목은 보지 않는다.
native_worker_pending() { # [scope] [tag]
  native_pending_present || return 1
  [ "$(native_pending_field '.role')" = WORKER ] || return 1
  local slot; slot="$(native_pending_field '.slot')"
  [ -z "${1:-}" ] || [ "$(printf '%s' "$slot" | cut -d'|' -f2)" = "$1" ] || return 1
  [ -z "${2:-}" ] || [ "$(printf '%s' "$slot" | cut -d'|' -f3)" = "$2" ]
}
native_worker_pending_scope() { native_pending_field '.slot' | cut -d'|' -f2; }
native_worker_pending_tag() { native_pending_field '.slot' | cut -d'|' -f3; }
# 호출 전 상태 운반: 1차 실행에서 put(스테이징 파일) → PREPARE 가 요청의 pre_state 로 접는다. 재실행 pass 에서는 get.
# 다른 backend(codex / legacy claude CLI)에서는 put 이 스테이징 파일만 쓰고 아무도 읽지 않는다(동작 불변).
native_pre_put() { # KEY VALUE
  [ "${NATIVE_PRE_ENABLED:-0}" = 1 ] || return 0
  mkdir -p "$(native_dir)/pre.staging" && printf '%s' "$2" > "$(native_dir)/pre.staging/$1"
}
native_pre_begin() { # ROLE — 이 역할이 native 일 때만 운반을 켠다(이전 호출 지점의 스테이징은 비운다)
  NATIVE_PRE_ENABLED=0
  [ "$(role_backend "$1" 2>/dev/null)" = claude_native ] || return 0
  NATIVE_PRE_ENABLED=1
  mkdir -p "$(native_dir)/pre.staging" || return 1
  find "$(native_dir)/pre.staging" -type f -exec rm -f {} +
}
native_pre_get() { # KEY → 값(없으면 1)
  local f; f="$(native_request_file)"
  [ -n "$f" ] && jq -e --arg k "$1" '.pre_state | has($k)' "$f" >/dev/null 2>&1 || return 1
  jq -r --arg k "$1" '.pre_state[$k]' "$f"
}
native_pre_collect_json() {
  local d k out='{}'; d="$(native_dir)/pre.staging"
  [ -d "$d" ] || { printf '{}'; return 0; }
  for k in "$d"/*; do
    [ -f "$k" ] || continue
    out="$(printf '%s' "$out" | jq -c --arg k "$(basename "$k")" --rawfile v "$k" '. + {($k): $v}')" || return 1
  done
  printf '%s' "$out"
}

# 스킬 지문: 프롬프트 템플릿·스키마·agent 템플릿·이 브리지·계약 버전. 요청 발행 뒤 이것이 바뀌면 캡처된 결과는 낡은 계약의 것이다(불수용).
native_skill_fingerprint() {
  local sd; sd="$(native_skill_dir)"
  { find "$sd/prompts" "$sd/schemas" "$sd/agents" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(native_sha256_file "$f")" "${f#$sd/}"; done
    printf 'bridge %s\n' "$(native_sha256_file "$(native_bridge_file)")"
    printf 'versions %s %s %s %s\n' "${FEATURE_RUNTIME_CONTRACT_VERSION:-}" "${VALIDATOR_CONTRACT_VERSION:-}" "${REVIEWER_CONTRACT_VERSION:-}" "${REVIEW_CHECKER_VERSION:-}"
  } | sha256_stdin
}

# ---------- agent 정의 ----------
# 정의 파일은 메인 Claude Code 세션이 실제로 읽는 프로젝트(원본 저장소)의 .claude/agents/ 에 둔다 — 피처 worktree 가 아니다.
# 원본 저장소 = 이 스킬이 설치된 프로젝트(실행 엔진 위치). 피처 worktree 로 PROJECT_ROOT 가 바뀌어도 이 값은 그대로다.
native_origin_root() { printf '%s' "${FEATURE_ORIGIN_ROOT:-$(cd "$FEATURE_SKILL_DIR/../../.." && pwd)}"; }
native_agents_dir() { printf '%s' "${FEATURE_NATIVE_AGENTS_DIR:-$(native_origin_root)/.claude/agents}"; }
native_definition_render() { # ROLE model effort → stdout
  local tmpl; tmpl="$(native_skill_dir)/agents/$(native_agent_name "$1").md"
  [ -f "$tmpl" ] || { echo "[FAIL] native agent 템플릿 없음: $tmpl — install.sh 를 다시 실행하라" >&2; return 1; }
  NATIVE_MODEL="$2" NATIVE_EFFORT="$3" NATIVE_MANAGED_MARKER="$NATIVE_MANAGED_MARKER" envsubst '${NATIVE_MODEL} ${NATIVE_EFFORT} ${NATIVE_MANAGED_MARKER}' < "$tmpl"
}
# 매 요청 직전: 설치된 정의가 지금의 모델·effort 로 렌더링한 것과 같은지 대조한다. 없거나(또는 이 스킬이 관리하는 파일이 낡았으면) 다시 쓴다.
# 사용자가 만든 같은 이름의 파일(관리 표식 없음)은 덮어쓰지 않고 중단한다. 다시 쓴 정의가 실제로 적용됐는지는 여기서 주장하지 않는다 —
# 수용 단계가 전사에서 관측한 모델·effort 를 요청과 대조한다(다르면 불수용).
NATIVE_DEF_PATH=""; NATIVE_DEF_SHA=""; NATIVE_DEF_WRITTEN=""   # NATIVE_DEF_WRITTEN: 이번 실행이 정의 파일을 새로 만들었으면 created, 고쳐 썼으면 updated
native_definition_ensure() { # ROLE model effort
  local name dir want cur; name="$(native_agent_name "$1")" || return 1
  dir="$(native_agents_dir)"; NATIVE_DEF_PATH="$dir/$name.md"; NATIVE_DEF_WRITTEN=""
  want="$(native_definition_render "$1" "$2" "$3")" || return 1
  if [ -f "$NATIVE_DEF_PATH" ]; then
    cur="$(cat "$NATIVE_DEF_PATH")"
    if [ "$cur" != "$want" ]; then
      grep -Fq "$NATIVE_MANAGED_MARKER" "$NATIVE_DEF_PATH" \
        || { echo "[FAIL] NATIVE_AGENT_DEFINITION_CONFLICT: $NATIVE_DEF_PATH 는 이 스킬이 관리하는 파일이 아니다(관리 표식 없음) — 덮어쓰지 않는다. 그 파일을 다른 이름으로 옮기거나 지운 뒤 재실행" >&2; return 1; }
      printf '%s\n' "$want" > "$NATIVE_DEF_PATH.tmp" && mv "$NATIVE_DEF_PATH.tmp" "$NATIVE_DEF_PATH" || return 1
      NATIVE_DEF_WRITTEN=updated
      echo "[native] agent 정의 갱신: $NATIVE_DEF_PATH (model $2, effort $3) — 실제 적용 여부는 결과 수용 때 관측값으로 대조한다" >&2
    fi
  else
    mkdir -p "$dir" && printf '%s\n' "$want" > "$NATIVE_DEF_PATH.tmp" && mv "$NATIVE_DEF_PATH.tmp" "$NATIVE_DEF_PATH" || return 1
    NATIVE_DEF_WRITTEN=created
    echo "[native] agent 정의 생성: $NATIVE_DEF_PATH (model $2, effort $3)" >&2
  fi
  NATIVE_DEF_SHA="$(native_sha256_file "$NATIVE_DEF_PATH")"
}

# 런타임 모델·effort 를 바꾸는 전역 설정은 요청을 만들기 전에 막는다(관측 대조는 수용 단계에서 한 번 더).
native_env_precheck() { # model effort
  if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL_FORCE:-}" ] && [ "${CLAUDE_CODE_SUBAGENT_MODEL_FORCE}" != 0 ]; then
    echo "[FAIL] NATIVE_MODEL_OVERRIDE: CLAUDE_CODE_SUBAGENT_MODEL_FORCE 가 켜져 있다 — agent 정의의 model($1)이 무시된다. 끄고 메인 세션을 다시 시작한 뒤 재실행" >&2; return 1
  fi
  if [ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ] && [ "${CLAUDE_CODE_EFFORT_LEVEL}" != "$2" ]; then
    echo "[FAIL] NATIVE_EFFORT_OVERRIDE: CLAUDE_CODE_EFFORT_LEVEL=${CLAUDE_CODE_EFFORT_LEVEL} 가 agent 정의의 effort($2)보다 우선한다 — 해제하고 메인 세션을 다시 시작한 뒤 재실행" >&2; return 1
  fi
}

# ---------- 세션(backend 별 typed record — claude CLI 평문 파일·codex 원장과 섞지 않는다) ----------
native_session_ledger() { printf '%s' "$WORK_DIR/.session-$1.native.json"; }
NATIVE_SESSION_MODE=NEW; NATIVE_SESSION_AGENT_ID=""
native_session_begin() { # ROLE key model effort def_sha
  local role="$1" key="$2" ledger; ledger="$(native_session_ledger "$key")"
  NATIVE_SESSION_MODE=NEW; NATIVE_SESSION_AGENT_ID=""
  if [ -f "$WORK_DIR/.session-$key" ] || [ -f "$WORK_DIR/.session-$key.codex.json" ]; then
    echo "[FAIL] SESSION_CLI_MISMATCH: key '$key' 는 CLI 세션(claude -p 또는 codex)에 결속돼 있는데 지금은 native Agent 로 라우팅된다($role) — 묵시적 마이그레이션 없이 중단. 진행 중인 피처는 기존 backend 로 마치거나(config.sh CLAUDE_BACKEND 를 시작 시점 값으로) 새 attempt/단계(--new)로 시작" >&2
    return 1
  fi
  [ -f "$ledger" ] || return 0
  jq -e --argjson v "$NATIVE_SESSION_LEDGER_VERSION" --arg key "$key" --arg role "$role" \
    '.version==$v and .key==$key and .role==$role and .backend=="claude_native" and (.agent_id|type=="string" and length>0) and (.parent_session_id|type=="string" and length>0)' "$ledger" >/dev/null 2>&1 \
    || { echo "[FAIL] native 세션 원장이 깨졌거나 key/role 이 다름: $ledger — 자동 새 Agent 전환 없이 중단" >&2; return 1; }
  jq -e --arg model "$3" --arg effort "$4" --arg cv "$(role_contract_version "$role")" --arg root "$PROJECT_ROOT" --arg def "$5" \
    '.model==$model and .effort==$effort and ((.contract_version // "")|tostring)==$cv and .project_root==$root and .agent_definition_sha256==$def' "$ledger" >/dev/null 2>&1 \
    || { echo "[FAIL] SESSION_LEDGER_MISMATCH: $key native 원장(model/effort/contract/project_root/agent 정의)이 현재 설정과 다름 — 설정을 되돌리거나 새 attempt/단계로 시작한다(자동 재개·자동 fresh 없음)" >&2; return 1; }
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ "$(jq -r '.parent_session_id' "$ledger")" != "$CLAUDE_CODE_SESSION_ID" ]; then
    echo "[STOP] NATIVE_PARENT_SESSION_LOST: key '$key' 의 Agent($(jq -r '.agent_id' "$ledger"))는 메인 세션 $(jq -r '.parent_session_id' "$ledger") 에 결속돼 있는데 지금 메인 세션은 $CLAUDE_CODE_SESSION_ID 다 — 다른 세션에서는 그 Agent 를 재개할 수 없다. 묵시적 fresh Agent 를 만들지 않는다. 원래 세션을 재개(claude --resume)해 재실행하거나, 사용자가 재시작 방식(--new 등)을 명시하라" >&2
    return 1
  fi
  NATIVE_SESSION_MODE=RESUME
  NATIVE_SESSION_AGENT_ID="$(jq -r '.agent_id' "$ledger")"
}
native_session_stage() { # ROLE key model effort def_sha agent_id parent_session
  local ledger; ledger="$(native_session_ledger "$2")"
  jq -n --argjson v "$NATIVE_SESSION_LEDGER_VERSION" --arg key "$2" --arg role "$1" --arg model "$3" --arg effort "$4" --arg def "$5" \
    --arg aid "$6" --arg parent "$7" --arg cv "$(role_contract_version "$1")" --arg root "$PROJECT_ROOT" --arg now "$(date '+%FT%T%z')" \
    '{version:$v, key:$key, role:$role, backend:"claude_native", model:$model, effort:$effort, contract_version:$cv, project_root:$root,
      agent_definition_sha256:$def, agent_id:$aid, parent_session_id:$parent, created_at:$now, last_accepted_label:"", last_accepted_at:""}' \
    > "$ledger.new.tmp" && mv "$ledger.new.tmp" "$ledger.new"
}
native_session_accept() { # ROLE key label
  local ledger; ledger="$(native_session_ledger "$2")"
  if [ -f "$ledger.new" ]; then mv "$ledger.new" "$ledger"; fi
  [ -f "$ledger" ] || { echo "[FAIL] $2: 확정할 native Agent 세션이 없음 — 이번 호출의 캡처에서 agent id 를 얻지 못했다" >&2; return 1; }
  jq --arg label "$3" --arg now "$(date '+%FT%T%z')" '.last_accepted_label=$label | .last_accepted_at=$now' "$ledger" > "$ledger.tmp" && mv "$ledger.tmp" "$ledger"
}

# 원본 저장소(메인 세션의 cwd 일 수 있다)의 tracked+untracked 상태 지문 — Agent 가 worktree 대신 원본을 고쳤는지 본다. worktree 와 같으면 빈 값.
native_origin_state() {
  local o; o="$(native_origin_root)"
  [ "$o" != "$PROJECT_ROOT" ] || { printf ''; return 0; }
  git -C "$o" rev-parse --show-toplevel >/dev/null 2>&1 || { printf ''; return 0; }
  { git -C "$o" rev-parse HEAD 2>/dev/null; git -C "$o" status --porcelain=v1 --untracked-files=all -- . ':(exclude).claude/agents' 2>/dev/null
    git -C "$o" diff 2>/dev/null; } | sha256_stdin
}

native_write_json() { # path  (stdin → 원자 쓰기)
  cat > "$1.tmp" && mv "$1.tmp" "$1"
}
# 요청 파일 잠금 — 훅(feature_native_agent.sh 의 req_lock)과 같은 규약: <요청 파일>.lock 디렉터리, 1분 넘은 잠금은 죽은 프로세스의 것으로 보고 치운다.
native_req_lock() { # request-file
  local l="$1.lock" i=0
  while ! mkdir "$l" 2>/dev/null; do
    if [ -n "$(find "$l" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$l" 2>/dev/null; continue; fi
    i=$((i + 1)); [ "$i" -lt 200 ] || return 1
    sleep 0.05
  done
}
native_req_unlock() { rmdir "$1.lock" 2>/dev/null || true; }
native_request_set() { # jq-filter [jq args...]  — 현재 pending 요청 갱신(원자, 훅과 직렬화)
  local f filter="$1" rc=0; shift; f="$(native_request_file)"
  native_req_lock "$f" || { echo "[FAIL] native 요청 파일 잠금 실패: $f.lock" >&2; return 1; }
  jq "$@" "$filter" "$f" > "$f.$$.tmp" && mv "$f.$$.tmp" "$f" || rc=1
  native_req_unlock "$f"
  return "$rc"
}

# ---------- dispatch 시도의 실행 여부 판정 ----------
# DISPATCHING 요청(PreToolUse 는 지났고 PostToolUse·SubagentStop 은 아직 없다)에 대해, 그 시도가 실행됐는지를 증거로만 가린다.
# 근거는 Claude Code 가 쓴 것뿐이다: 훅이 기록한 tool_use_id 와 메인 세션 전사(dispatch_attempt.transcript_path)의 그 도구 결과 레코드, subagent 전사.
#   DENIED   그 tool_use_id 의 tool_result 가 is_error 이고 toolDenialKind 가 알려진 '실행 전 거부' 종류다 → 도구(모델)는 실행되지 않았다.
#            (Claude Code 2.1.330 실측: 다른 PreToolUse 훅의 거부 = toolDenialKind "permission-rule", 내용 "PreToolUse:Agent hook error: …")
#   EXECUTED 실행된 흔적이 있다(캡처, PostToolUse 기록, 이 요청의 프롬프트를 받은 subagent 전사, 오류가 아닌 도구 결과).
#   UNKNOWN  그 밖 전부 — 전사 없음·결과 레코드 없음·모르는 형태의 오류. 불명은 거부가 아니다.
# 판정 순서: 실행 증거(EXECUTED) → Agent 정의 미발견 오류(UNKNOWN, NATIVE_EVID_REASON=AGENT_TYPE_NOT_FOUND) → 알려진 실행 전 거부(DENIED) → 그 밖(UNKNOWN).
#   "Agent type '<이름>' not found" 는 Agent 정의 로딩 실패다. 그 호출이 DISPATCHING 으로 기록된 뒤라면(PreToolUse 는 지났다) 다른 훅·도구 검증의 순서가 얽혀
#   메시지만으로 '실행 전 거부가 확정됐다'고 말할 수 없다 — 알려진 toolDenialKind 가 같은 레코드에 있어도 재전송 가능(DENIED)으로 올리지 않는다.
#   문구는 그 tool_use_id 의 tool_result 내용(잘라 내기 전 전체)에서만 찾는다. 레코드 단위 오류 필드(toolUseResult)는 그 레코드의 tool_result 가 하나뿐일 때만
#   같은 호출의 것으로 본다. 전사의 다른 도구 결과·다른 턴에 같은 문구가 있어도 영향이 없다. agent 이름·따옴표 모양은 가리지 않는다.
#   거부 정보(toolDenialKind · permissionDecision)도 레코드 단위 필드다 — 같은 규칙으로, 그 레코드의 tool_result 가 하나뿐일 때만 이 호출의 거부 증거로 쓴다.
#   tool_result 가 여럿인 레코드에서는 그 거부가 다른 도구 호출의 것일 수 있으므로 쓰지 않는다(DENIED 로 올리지 않는다 → UNKNOWN, 재전송 불가).
NATIVE_DENIAL_KINDS='["permission-rule","user-rejected","automode-blocked","automode-unavailable"]'
NATIVE_EVID=""; NATIVE_EVID_DETAIL=""; NATIVE_EVID_REASON=""
native_dispatch_evidence() {
  local req tu tp rec sub
  req="$(native_request_file)"; NATIVE_EVID=UNKNOWN; NATIVE_EVID_DETAIL=""; NATIVE_EVID_REASON=""
  tu="$(jq -r '.dispatch_attempt.tool_use_id // ""' "$req")"; tp="$(jq -r '.dispatch_attempt.transcript_path // ""' "$req")"
  if [ -f "$(native_capture_file)" ]; then NATIVE_EVID=EXECUTED; NATIVE_EVID_DETAIL="결과 캡처 파일이 있다"; return 0; fi
  if jq -e '.post_tool.launch_confirmed == true' "$req" >/dev/null 2>&1; then
    NATIVE_EVID=EXECUTED; NATIVE_EVID_DETAIL="PostToolUse 가 이 호출의 실행 성공을 기록했다"; return 0
  fi
  [ -n "$tu" ] || { NATIVE_EVID_DETAIL="dispatch 시도에 tool_use_id 가 기록되지 않았다"; return 0; }
  if [ -n "$tp" ] && [ -d "${tp%.jsonl}/subagents" ]; then
    sub="$(grep -lF "FEATURE-NATIVE-REQUEST $req" "${tp%.jsonl}/subagents"/*.jsonl 2>/dev/null | head -1 || true)"
    if [ -n "$sub" ]; then NATIVE_EVID=EXECUTED; NATIVE_EVID_DETAIL="이 요청의 프롬프트를 받은 subagent 전사가 있다: $sub"; return 0; fi
  fi
  [ -n "$tp" ] && [ -f "$tp" ] || { NATIVE_EVID_DETAIL="메인 세션 전사(${tp:-미기록})를 읽을 수 없다"; return 0; }
  # 그 tool_use_id 의 도구 결과 레코드(마지막 것). 큰 전사를 통째로 파싱하지 않도록 먼저 줄을 거른다.
  rec="$(grep -F "\"$tu\"" "$tp" 2>/dev/null | jq -c --arg tu "$tu" 'select(.type=="user" and (.message.content|type)=="array")
      | ([.message.content[] | select(.type=="tool_result")] | length) as $n
      | (.message.content[] | select(.type=="tool_result" and .tool_use_id==$tu)) as $r
      | ($r.content | if type=="string" then . else tostring end) as $full
      | (if $n == 1 and .toolUseResult != null then (.toolUseResult | if type=="string" then . else tostring end) else "" end) as $rec_err
      | {is_error:($r.is_error == true), results:$n,
         kind:(if $n == 1 then (.toolDenialKind // null) else null end), decision:(if $n == 1 then (.permissionDecision // null) else null end),
         agent_type_not_found:([$full, $rec_err] | any(test("agent type.{0,200}not found"; "i"))),
         text:($full | .[0:600])}' 2>/dev/null | tail -1 || true)"   # 단독 실행은 set -e·pipefail 이다 — 줄이 없어도 여기서 죽지 않는다
  [ -n "$rec" ] || { NATIVE_EVID_DETAIL="메인 세션 전사에 tool_use_id $tu 의 도구 결과가 아직 없다$(jq -r 'if .post_tool != null then " (PostToolUse 는 실행 확인으로 볼 수 없는 응답을 기록했다 — 형태 \(.post_tool.response_shape), 키 \(.post_tool.response_keys|tostring))" else "" end' "$req")"; return 0; }
  if printf '%s' "$rec" | jq -e '.is_error and .agent_type_not_found' >/dev/null 2>&1; then
    NATIVE_EVID_REASON=AGENT_TYPE_NOT_FOUND
    NATIVE_EVID_DETAIL="tool_use_id $tu 의 도구 결과가 Agent 정의 미발견 오류다(toolDenialKind $(printf '%s' "$rec" | jq -r '.kind // "없음"')) — 정의 로딩 실패이며 실행 전 거부가 증명되지 않는다. 거부 종류가 함께 있어도 재전송 가능한 거부로 보지 않는다(실행 여부 불명): $(printf '%s' "$rec" | jq -r '.text')"
  elif printf '%s' "$rec" | jq -e --argjson kinds "$NATIVE_DENIAL_KINDS" '.is_error and (.kind as $k | $kinds | index($k) != null)' >/dev/null 2>&1; then
    NATIVE_EVID=DENIED
    NATIVE_EVID_DETAIL="$(printf '%s' "$rec" | jq -r '"거부 종류 \(.kind)" + (if .decision != null then " / \(.decision.source // "?"):\(.decision.reasonCode // "?")" else "" end) + " — \(.text)"')"
  elif printf '%s' "$rec" | jq -e '.is_error' >/dev/null 2>&1; then
    NATIVE_EVID_DETAIL="tool_use_id $tu 의 도구 결과가 오류인데 알려진 '실행 전 거부' 종류가 아니다(toolDenialKind $(printf '%s' "$rec" | jq -r 'if .results > 1 then "판정 불가 — 같은 레코드에 도구 결과가 \(.results)개라 레코드 단위 거부 정보가 이 호출의 것인지 알 수 없다" else (.kind // "없음") end')) — 실행 여부 불명: $(printf '%s' "$rec" | jq -r '.text')"
  else
    NATIVE_EVID=EXECUTED; NATIVE_EVID_DETAIL="메인 세션 전사의 도구 결과가 성공이다 — 실행됐는데 PostToolUse 훅이 기록하지 못했다"
  fi
}
# 단독 복구 명령의 표기. 명령은 그 요청이 속한 프로젝트 루트(피처 worktree)에서 돌아야 한다 — 메인 세션의 cwd 는 보통 원본 저장소이므로 cd 를 함께 적는다.
native_recovery_cmd() { # redispatch|discard request-id
  printf 'cd %q && bash %q %s %s' "$PROJECT_ROOT" "$(native_bridge_file)" "$1" "$2"
}
# 요청 state 를 바꾸지 않는 중단(43): 낡은 것은 요청이 아니라 바깥 조건(설정·다른 훅의 거부)이다.
native_stop_keep_state() { # code detail recovery-line
  echo "[STOP] NATIVE_RESULT_REJECTED($1): $2" >&2
  echo "       요청: $(native_request_file) — 요청 state 는 바꾸지 않았다. 모델 호출 0회. 자동 재호출·자동 원복·자동 fresh 없음." >&2
  echo "       복구(사용자 결정 뒤): $3" >&2
  printf '%s\n' "$1: $2" > "$(native_dir)/last-rejection.txt" 2>/dev/null || true
  ! declare -F native_on_rejected >/dev/null || native_on_rejected "$1" "$2"
  exit "$NATIVE_EXIT_REJECTED"
}
# DISPATCHING 요청 위에서의 재실행: 거부가 확인되면 사용자에게 올리고(재시도·정리는 명시적 명령), 아니면 대기한다. 어느 쪽도 같은 요청을 스스로 다시 보내지 않는다.
native_dispatch_unconfirmed() {
  native_dispatch_evidence
  [ "$NATIVE_EVID" = DENIED ] || native_stop_required
  local id; id="$(native_request_field '.request_id')"
  native_stop_keep_state NATIVE_DISPATCH_DENIED \
    "native 요청 $id($(native_request_field '.role'), $(native_request_field '.model'))의 dispatch 가 실행 전에 거부됐다 — $(native_request_field '.dispatch_attempt.tool') tool_use_id $(native_request_field '.dispatch_attempt.tool_use_id'): $NATIVE_EVID_DETAIL. Agent 는 실행되지 않았다(모델 호출 아님). 같은 원인이면 다시 보내도 같은 거부가 난다 — 거부 원인을 사용자에게 그대로 보고한다. 다른 Agent 종류·다른 모델·claude -p 로 대체하지 않고, 거부한 훅을 끄지 않는다" \
    "거부 원인을 해소했으면 $(native_recovery_cmd redispatch "$id") — 같은 요청을 PREPARED 로 되돌린다(같은 dispatch 한 줄을 한 번 더 보낼 수 있다). 요청을 버리려면 $(native_recovery_cmd discard "$id")"
}

# ---------- 종료 ----------
native_print_dispatch() {
  local f; f="$(native_request_file)"
  # 하위 루프가 42 로 끝나 상위 러너가 다시 출력하는 경우에도 판정 근거가 비지 않게 한다.
  [ "$(jq -r '.state' "$f" 2>/dev/null)" != DISPATCHING ] || [ -n "${NATIVE_EVID:-}" ] || native_dispatch_evidence
  jq -r '"[NATIVE_AGENT_REQUIRED] request \(.request_id) — \(.role) / \(.model) / effort \(.effort) / state \(.state)\n" +
    (if .state=="PREPARED" then
       (if .session_intent=="NEW"
        then "  메인 Claude Code 가 할 일: Agent 도구를 정확히 한 번 호출한다 — subagent_type: \(.agent_definition), description: \"feature \(.role|ascii_downcase) \(.request_id)\", prompt 는 아래 한 줄 그대로.\n"
        else "  메인 Claude Code 가 할 일: SendMessage 도구를 정확히 한 번 호출한다 — to: \(.resume_agent_id) (이미 이 피처에 결속된 \(.agent_definition) Agent 의 재개), message 는 아래 한 줄 그대로.\n" end)
       + "    \(.dispatch_line)\n"
       + "  금지: model 인자·isolation 지정, 한 줄의 수정·요약, 다른 Agent 로의 대체, 같은 요청의 두 번째 호출. 프롬프트 본문은 PreToolUse 훅이 \(.prompt_path) 에서 넣는다.\n"
       + "  Agent 가 끝났다는 알림(또는 foreground 완료)을 받은 뒤 같은 feature-run 명령을 재실행한다. 결과를 직접 옮겨 적거나 요약해 넘기지 않는다."
       + "\n  도구 호출 자체가 오류·거부로 돌아오면(다른 훅의 거부 포함) 다시 보내지 않는다 — 바로 같은 feature-run 명령을 재실행해 러너의 판정(거부 확인 / 실행 여부 불명)을 받는다."
       + (if .agent_definition_written != null then
            "\n  [주의] agent 정의 파일(\(.agent_definition_path))을 이번 실행이 \(if .agent_definition_written=="created" then "새로 만들었다" else "고쳐 썼다" end). "
            + "도구가 \"Agent type \(.agent_definition) not found\" 로 돌아오면(세션 시작 때 .claude/agents/ 가 없었던 경우 — Claude Code 2.1.330 실측) 다시 보내지 말고 같은 feature-run 명령을 재실행해 요청 state 를 확인한다. "
            + "state 가 PREPARED 그대로일 때만(PreToolUse 훅이 그 호출을 기록하지 않았다) 사용자에게 Claude Code 세션 재시작(같은 대화 재개)을 요청한 뒤 이 dispatch 를 한 번 보낸다. "
            + "state 가 DISPATCHING 이면 실행 여부 불명이다 — 세션을 재시작한 뒤에도 다시 보내지 않고 러너가 낸 판정 근거를 사용자에게 보고한다. 다른 Agent 종류로 대체하지 않는다."
          else "" end)
     elif .state=="DISPATCHING" then
       "  dispatch 를 시도했지만(\(.dispatch_attempt.tool // "?") tool_use_id \(.dispatch_attempt.tool_use_id // "?"), \(.dispatch_attempt.at // "?")) 실행 확인(PostToolUse)도 결과 캡처도 없다 — 실행 여부 불명.\n" +
       "  판정 근거: \($evid) — \($evdetail)\n" +
       (if $evreason=="AGENT_TYPE_NOT_FOUND" then
          "  [Agent 정의 미발견] 도구가 \(.agent_definition) 정의를 찾지 못했다고 답했다(정의 파일 \(.agent_definition_path) — 세션 시작 뒤에 생겼거나 바뀐 정의는 Claude Code 세션을 재시작해야 읽힌다). " +
          "이 요청은 이미 DISPATCHING 이다: 세션을 재시작한 뒤에도 같은 dispatch 를 다시 보내지 않는다. 모델이 실행됐는지(진행 중인 Agent·작업 트리 변경)를 사용자와 확인하고, 사용자 결정 뒤 discard 로만 정리한다(작업 트리가 호출 전 tree 와 같아야 하고, 거부가 확인되지 않았다는 경고가 붙는다). redispatch 는 거부 증거가 없어 거절된다.\n"
        else "" end) +
       "  다시 호출하지 않는다(훅이 같은 요청의 두 번째 dispatch 를 거부한다). 방금 호출이 background 로 시작됐으면 완료 알림을 기다린 뒤 같은 명령을 재실행한다.\n" +
       "  도구 호출이 오류로 돌아왔거나 Agent 가 끝났는데도 이 상태면 그 사실과 위 근거를 사용자에게 보고한다(자동 재호출·자동 fresh 없음). 정리는 사용자 결정 뒤 discard 뿐이다."
     elif .state=="DISPATCHED" then
       "  실행이 확인됐고(\(.dispatched_at // "?"), agent \(.dispatched_agent_id // "?")) 결과가 아직 캡처되지 않았다 — 다시 호출하지 않는다. Agent 완료 알림을 기다린 뒤 같은 명령을 재실행한다.\n" +
       "  Agent 가 끝났는데도 이 상태면 SubagentStop 훅(.claude/hooks/feature_native_agent.sh)이 등록돼 있는지 확인하고 사용자에게 보고한다(자동 재호출·자동 fresh 없음)."
     else "  결과 캡처됨 — 같은 명령을 재실행하면 Shell 이 검증·수용한다." end) +
    "\n  요청: \(.request_path)"' --arg evid "${NATIVE_EVID:-}" --arg evdetail "${NATIVE_EVID_DETAIL:-}" --arg evreason "${NATIVE_EVID_REASON:-}" "$f"
}
native_stop_required() {
  native_print_dispatch
  ! declare -F native_on_required >/dev/null || native_on_required "$(native_request_field '.request_id')" "$(native_request_field '.state')"
  exit "$NATIVE_EXIT_REQUIRED"
}
native_reject() { # code detail
  local f; f="$(native_request_file)"
  if [ -n "$f" ] && [ -f "$f" ]; then
    native_request_set '.state="REJECTED" | .rejection={code:$c, detail:$d, at:$now}' --arg c "$1" --arg d "$2" --arg now "$(date '+%FT%T%z')" || true
  fi
  echo "[STOP] NATIVE_RESULT_REJECTED($1): $2" >&2
  echo "       요청: ${f:-?} — 결과를 수용하지 않았고 자동 재호출·자동 원복·자동 fresh 도 하지 않는다. 그대로 재실행하면 모델 호출 0회로 같은 사유로 멈춘다." >&2
  echo "       복구(사용자 결정 뒤): $(native_recovery_cmd discard '<request_id>') — 작업 트리가 호출 전 상태일 때만 요청을 치운다(아니면 변경을 먼저 확인·정리)." >&2
  printf '%s\n' "$1: $2" > "$(native_dir)/last-rejection.txt" 2>/dev/null || true
  ! declare -F native_on_rejected >/dev/null || native_on_rejected "$1" "$2"
  exit "$NATIVE_EXIT_REJECTED"
}
# 처리되지 않은 native 요청이 남아 있는데 그 요청의 역할이 지금은 claude_native 로 라우팅되지 않는다(요청 발행 뒤 모델·CLAUDE_BACKEND·<ROLE>_CLI 변경).
# 호출 지점(slot)이 같아도 멈춘다 — 그대로 두면 dispatch 됐을 수 있는 Agent 와 별개로 CLI 가 같은 호출을 한 번 더 한다.
# 요청 state 는 건드리지 않는다: 낡은 것은 요청이 아니라 설정이므로, 설정을 되돌려 재실행하면 같은 요청이 그대로 이어진다(REJECTED 로 굳히지 않는다).
native_pending_backend_guard() {
  native_pending_present || return 0
  local prole be code=NATIVE_PENDING_BACKEND_CHANGED detail
  prole="$(native_pending_field '.role')"
  be="$(role_backend "$prole" 2>/dev/null)" || be=""
  [ "$be" != claude_native ] || return 0
  detail="처리되지 않은 native 요청($(native_pending_field '.request_id'), $prole, 호출 지점 '$(native_pending_field '.slot')', state $(native_request_field '.state'))이 있는데 지금 $prole 의 backend 는 '${be:-판정 불가}' 다(요청은 claude_native / $(native_request_field '.model')) — 요청 발행 뒤 모델·CLAUDE_BACKEND 가 바뀌었다. 남은 요청 위에서 다른 backend 를 호출하지 않는다. 설정을 요청 발행 시점으로 되돌려 재실행하면 같은 요청이 이어지고, backend 변경이 의도라면 사용자 결정 뒤 요청을 discard 한다"
  echo "[STOP] NATIVE_RESULT_REJECTED($code): $detail" >&2
  echo "       요청: $(native_request_file) — 요청 state 는 바꾸지 않았다. 모델 호출 0회. 자동 재호출·자동 원복·자동 fresh 없음." >&2
  echo "       복구(사용자 결정 뒤): 설정 원복 후 재실행, 또는 $(native_recovery_cmd discard '<request_id>') — 작업 트리가 호출 전 상태일 때만 요청을 치운다." >&2
  printf '%s\n' "$code: $detail" > "$(native_dir)/last-rejection.txt" 2>/dev/null || true
  ! declare -F native_on_rejected >/dev/null || native_on_rejected "$code" "$detail"
  exit "$NATIVE_EXIT_REJECTED"
}
# 모든 backend 의 역할 호출이 시작할 때 부른다: 다른 호출 지점의 native 요청이 남아 있으면 그 위에서 새 모델 호출을 하지 않는다.
# 같은 호출 지점이어도 그 요청의 역할이 더는 native 가 아니면 멈춘다(native_pending_backend_guard).
native_pending_guard() { # ROLE label
  native_pending_present || return 0
  native_pending_backend_guard
  [ "$(native_pending_field '.slot')" = "$(native_slot "$1" "$2")" ] && return 0
  native_reject NATIVE_PENDING_MISMATCH "처리되지 않은 native 요청($(native_pending_field '.request_id'), 호출 지점 '$(native_pending_field '.slot')', state $(native_request_field '.state'))이 있는데 러너가 다른 호출 지점('$(native_slot "$1" "$2")')에 도달했다 — 그 사이 문서·설정·체크포인트가 바뀌었다. 낡은 요청 위에서 새 호출을 하지 않는다"
}

# 역할 payload(= conventions + 역할 프롬프트 + 출력 계약). PREPARE 와 재실행 pass 의 대조가 같은 함수를 쓴다.
native_role_payload() { # prompt conv schema
  local p="$1"
  [ -z "$2" ] || p="$2"$'\n\n'"$1"
  [ -z "$3" ] || p="$p
[OUTPUT CONTRACT]
마지막 응답은 아래 JSON Schema 를 만족하는 JSON 객체 하나뿐이어야 한다 — 앞뒤 설명·머리말·코드 펜스 없이 객체만. Shell 이 이 스키마와 기존 계약 검사로 그대로 검증하며, 어긋난 출력은 고쳐 쓰지 않고 거부한다.
$(cat "$3")
[/OUTPUT CONTRACT]"
  printf '%s' "$p"
}

# ---------- PREPARE ----------
native_prepare() { # mode ROLE session label prompt conv schema
  local mode="$1" role="$2" session="$3" label="$4" prompt="$5" conv="$6" schema="$7"
  local model effort id dir req payload_file role_payload pre_tree origin_state pre_state
  model="$(role_model "$role")"; effort="$(role_effort "$role")"
  native_env_precheck "$model" "$effort" || return 1
  native_definition_ensure "$role" "$model" "$effort" || return 1
  native_session_begin "$role" "$session" "$model" "$effort" "$NATIVE_DEF_SHA" || return 1
  dir="$(native_dir)"; mkdir -p "$dir/requests" "$dir/results" || return 1
  id="native-$(new_invocation_id)"; req="$dir/requests/$id.json"; payload_file="$dir/requests/$id.prompt.txt"
  pre_tree="$(snapshot_worktree_tree)" || { echo "[FAIL] native 요청: 호출 전 tree 스냅샷 실패" >&2; return 1; }
  origin_state="$(native_origin_state)"
  pre_state="$(native_pre_collect_json)" || return 1
  role_payload="$(native_role_payload "$prompt" "$conv" "$schema")" || return 1
  { printf 'FEATURE-NATIVE-REQUEST %s\n' "$req"
    printf '[feature-skill 인계 요청 — request_id %s / role %s / worktree_root %s]\n' "$id" "$role" "$PROJECT_ROOT"
    printf '이 요청 하나만 수행한다. 아래 역할 프롬프트의 모든 상대 경로(%s/… 포함)는 worktree_root 기준이다 — 파일 도구에는 worktree_root 를 붙인 절대 경로를 쓰고, Bash 는 매 호출을 "cd %s && …" 로 시작한다. worktree_root 밖(원본 저장소 포함)의 파일은 만들거나 고치지 않는다. 하위 Agent·백그라운드 작업·git commit/push 금지.\n' "$WORK_DIR" "$PROJECT_ROOT"
    # 재개된 Agent 는 이전 턴의 파일 읽기 기록을 잃는다(2.1.330 실측: 재개 턴의 Edit 가 "File has not been read yet" 로 실패했는데도 완료를 보고) — 매 요청에 명시한다.
    printf '파일을 고치기 전에는 이번 요청 안에서 그 파일을 다시 Read 한다(이전 요청에서 읽은 기록은 이어지지 않는다). 도구 호출이 오류로 끝났으면 원인을 고쳐 다시 수행하고, 끝내 반영하지 못한 변경을 완료로 보고하지 않는다.\n'
    printf '[/FEATURE-NATIVE-REQUEST]\n\n'
    printf '%s\n' "$role_payload"
  } > "$payload_file.tmp" && mv "$payload_file.tmp" "$payload_file" || return 1
  jq -n --argjson v "$NATIVE_REQUEST_VERSION" --arg id "$id" --arg feature "${FEATURE_ID:-}" --arg root "$PROJECT_ROOT" --arg origin "$(native_origin_root)" \
    --arg role "$role" --arg mode "$mode" --arg model "$model" --arg effort "$effort" --arg agent "$(native_agent_name "$role")" \
    --arg defpath "$NATIVE_DEF_PATH" --arg defsha "$NATIVE_DEF_SHA" --arg defw "$NATIVE_DEF_WRITTEN" --arg session "$session" --arg intent "$NATIVE_SESSION_MODE" --arg resume "$NATIVE_SESSION_AGENT_ID" \
    --arg slot "$(native_slot "$role" "$label")" --arg label "$label" --arg ppath "$payload_file" --arg psha "$(printf '%s' "$role_payload" | sha256_stdin)" \
    --arg dsha "$(native_sha256_file "$payload_file")" --arg schema "$schema" --arg ssha "$([ -z "$schema" ] || native_sha256_file "$schema")" \
    --arg skill "$(native_skill_fingerprint)" --arg infp "${NATIVE_INPUT_FP:-}" --arg pre "$pre_tree" --arg ostate "$origin_state" \
    --arg owner "${CLAUDE_CODE_SESSION_ID:-}" --arg req "$req" --argjson prestate "$pre_state" --arg now "$(date '+%FT%T%z')" \
    '{version:$v, request_id:$id, state:"PREPARED", feature_id:$feature, worktree_root:$root, origin_root:$origin, role:$role, mode:$mode,
      backend:"claude_native", model:$model, effort:$effort, agent_definition:$agent, agent_definition_path:$defpath, agent_definition_sha256:$defsha, agent_definition_written:(if $defw=="" then null else $defw end),
      session_key:$session, session_intent:$intent, resume_agent_id:(if $resume=="" then null else $resume end), slot:$slot, label:$label,
      request_path:$req, prompt_path:$ppath, prompt_sha256:$psha, dispatch_sha256:$dsha, dispatch_line:("FEATURE-NATIVE-DISPATCH " + $req),
      schema_path:(if $schema=="" then null else $schema end), schema_sha256:(if $ssha=="" then null else $ssha end),
      skill_fingerprint:$skill, input_fingerprint:$infp, pre_tree:$pre, origin_state:$ostate,
      owner_session_id:(if $owner=="" then null else $owner end), pre_state:$prestate, created_at:$now}' | native_write_json "$req" || return 1
  # 요청 파일이 먼저, pending 포인터가 나중 — 포인터가 가리키는 요청은 항상 완전하다.
  jq -n --arg id "$id" --arg req "$req" --arg slot "$(native_slot "$role" "$label")" --arg role "$role" --arg now "$(date '+%FT%T%z')" \
    '{version:1, request_id:$id, request_path:$req, slot:$slot, role:$role, created_at:$now}' | native_write_json "$(native_pending_file)" || return 1
}

# ---------- ACCEPT ----------
native_capture_file() { printf '%s' "$(native_dir)/results/$(native_request_field '.request_id').capture.json"; }
# 결속 검사: 하나라도 어긋나면 불수용(43). 보고 내용의 스키마·계약은 여기서 보지 않는다 — 호출자의 기존 게이트가 본다.
native_verify_binding() { # mode ROLE session label prompt conv schema
  local mode="$1" role="$2" session="$3" label="$4" prompt="$5" conv="$6" schema="$7" req cap v
  req="$(native_request_file)"; cap="$(native_capture_file)"
  [ -f "$cap" ] || native_reject NATIVE_CAPTURE_MISSING "요청 state 는 RESULT_READY 인데 캡처 파일($cap)이 없다"
  jq -e '.version==1 and (.request_id|type=="string") and (.agent_id|type=="string" and length>0)' "$cap" >/dev/null 2>&1 \
    || native_reject NATIVE_CAPTURE_INVALID "캡처 파일 형식이 다르거나 agent id 가 없다: $cap"
  [ "$(jq -r '.request_id' "$cap")" = "$(jq -r '.request_id' "$req")" ] || native_reject NATIVE_REQUEST_ID_MISMATCH "캡처의 request_id 가 pending 요청과 다르다"
  [ "$(jq -r '.dispatch_sha256_observed' "$cap")" = "$(jq -r '.dispatch_sha256' "$req")" ] \
    || native_reject NATIVE_PROMPT_HASH_MISMATCH "Agent 가 실제로 받은 프롬프트의 해시($(jq -r '.dispatch_sha256_observed' "$cap"))가 요청의 payload 해시와 다르다 — 프롬프트가 바뀌거나 옮겨 적혔다"
  [ "$(native_sha256_file "$(jq -r '.prompt_path' "$req")")" = "$(jq -r '.dispatch_sha256' "$req")" ] \
    || native_reject NATIVE_PROMPT_HASH_MISMATCH "요청의 payload 파일이 발행 뒤 바뀌었다: $(jq -r '.prompt_path' "$req")"
  [ "$(jq -r '.worktree_root' "$req")" = "$PROJECT_ROOT" ] || native_reject NATIVE_WORKTREE_MISMATCH "요청의 worktree_root($(jq -r '.worktree_root' "$req"))가 지금 러너의 작업 트리($PROJECT_ROOT)와 다르다"
  [ "$(jq -r '.role' "$req")" = "$role" ] && [ "$(jq -r '.session_key' "$req")" = "$session" -o "$role" = VALIDATOR ] \
    || native_reject NATIVE_SESSION_MISMATCH "요청의 role/session key($(jq -r '.role + "/" + .session_key' "$req"))가 이 호출($role/$session)과 다르다"
  [ "$(jq -r '.agent_type' "$cap")" = "$(jq -r '.agent_definition' "$req")" ] || native_reject NATIVE_AGENT_TYPE_MISMATCH "결과를 낸 Agent 종류($(jq -r '.agent_type' "$cap"))가 요청($(jq -r '.agent_definition' "$req"))과 다르다"
  v="$(jq -r '.owner_session_id // ""' "$req")"
  [ -n "$v" ] && [ "$(jq -r '.session_id' "$cap")" = "$v" ] || native_reject NATIVE_OWNER_SESSION_MISMATCH "결과를 낸 메인 세션($(jq -r '.session_id' "$cap"))이 요청을 소유한 세션(${v:-미기록})과 다르다"
  [ -z "${CLAUDE_CODE_SESSION_ID:-}" ] || [ "$CLAUDE_CODE_SESSION_ID" = "$v" ] || native_reject NATIVE_OWNER_SESSION_MISMATCH "지금 러너를 실행한 메인 세션($CLAUDE_CODE_SESSION_ID)이 요청을 소유한 세션($v)과 다르다 — 다른 세션의 결과를 가져오지 않는다"
  if [ "$(jq -r '.session_intent' "$req")" = RESUME ]; then
    [ "$(jq -r '.agent_id' "$cap")" = "$(jq -r '.resume_agent_id' "$req")" ] || native_reject NATIVE_SESSION_MISMATCH "재개 요청인데 결과를 낸 agent id($(jq -r '.agent_id' "$cap"))가 결속된 Agent($(jq -r '.resume_agent_id' "$req"))와 다르다"
  fi
  v="$(jq -r '.post_tool.agent_id // ""' "$req")"
  [ -z "$v" ] || [ "$v" = "$(jq -r '.agent_id' "$cap")" ] || native_reject NATIVE_SESSION_MISMATCH "PostToolUse 가 보고한 agent id($v)와 전사의 agent id($(jq -r '.agent_id' "$cap"))가 다르다"
  # 실제 모델·effort: 전사에서 관측한 값이 요청과 정확히 같아야 한다. 관측하지 못했으면 정확성을 보장할 수 없으므로 수용하지 않는다.
  jq -e --arg m "$(jq -r '.model' "$req")" '(.models_observed|type=="array" and length==1) and .models_observed[0]==$m' "$cap" >/dev/null 2>&1 \
    || native_reject NATIVE_MODEL_MISMATCH "요청 모델 $(jq -r '.model' "$req") / 전사에서 관측한 모델 $(jq -c '.models_observed' "$cap") — fallback·전역 override·정의 미적용 가능성. 관측 불가도 불수용이다"
  jq -e --arg e "$(jq -r '.effort' "$req")" '(.efforts_observed|type=="array" and length==1) and .efforts_observed[0]==$e' "$cap" >/dev/null 2>&1 \
    || native_reject NATIVE_EFFORT_MISMATCH "요청 effort $(jq -r '.effort' "$req") / 전사에서 관측한 effort $(jq -c '.efforts_observed' "$cap")"
  [ "$(jq -r '.model' "$req")" = "$(role_model "$role")" ] && [ "$(jq -r '.effort' "$req")" = "$(role_effort "$role")" ] \
    || native_reject NATIVE_STALE_REQUEST "요청 발행 뒤 config.sh 의 $role 모델/effort 가 바뀌었다(요청 $(jq -r '.model + "/" + .effort' "$req") → 현재 $(role_model "$role")/$(role_effort "$role"))"
  [ -f "$(jq -r '.agent_definition_path' "$req")" ] && [ "$(native_sha256_file "$(jq -r '.agent_definition_path' "$req")")" = "$(jq -r '.agent_definition_sha256' "$req")" ] \
    || native_reject NATIVE_STALE_REQUEST "요청 발행 뒤 agent 정의 파일($(jq -r '.agent_definition_path' "$req"))이 바뀌었다"
  [ "$(native_skill_fingerprint)" = "$(jq -r '.skill_fingerprint' "$req")" ] \
    || native_reject NATIVE_STALE_REQUEST "요청 발행 뒤 스킬(프롬프트·스키마·agent 템플릿·브리지·계약 버전)이 바뀌었다 — 낡은 계약의 결과다"
  [ "${NATIVE_INPUT_FP:-}" = "$(jq -r '.input_fingerprint' "$req")" ] \
    || native_reject NATIVE_STALE_REQUEST "요청 발행 뒤 이 호출의 입력 지문(문서·작업 트리)이 바뀌었다 — 낡은 입력에 대한 결과다${NATIVE_INPUT_FP_DETAIL:+ ($NATIVE_INPUT_FP_DETAIL)}"
  if [ -n "$prompt" ]; then
    local role_payload; role_payload="$(native_role_payload "$prompt" "$conv" "$schema")"
    [ "$(printf '%s' "$role_payload" | sha256_stdin)" = "$(jq -r '.prompt_sha256' "$req")" ] \
      || native_reject NATIVE_STALE_REQUEST "지금 렌더링한 역할 프롬프트가 요청에 실린 것과 다르다 — 요청 발행 뒤 프롬프트 입력(템플릿·문서 경로·라운드 문맥)이 바뀌었다"
  fi
  v="$(native_origin_state)"
  [ "$v" = "$(jq -r '.origin_state' "$req")" ] \
    || native_reject NATIVE_WORKTREE_CONFUSION "요청 발행 뒤 원본 저장소($(native_origin_root))의 작업 상태가 바뀌었다 — Agent 가 피처 worktree($PROJECT_ROOT) 대신 원본을 고쳤을 수 있다. 변경을 확인하라(자동 원복 없음)"
  if [ "$mode" = readonly ]; then
    v="$(snapshot_worktree_tree)" || native_reject NATIVE_CAPTURE_INVALID "작업 트리 스냅샷 실패"
    [ "$v" = "$(jq -r '.pre_tree' "$req")" ] \
      || native_reject NATIVE_READONLY_VIOLATION "읽기 전용 역할($role) 호출 전후로 작업 트리가 다르다(전 $(jq -r '.pre_tree' "$req") / 후 $v) — 판정을 수용하지 않는다"
  fi
}
# 보고 원문 → JSON 객체. 메시지 전체가 객체이거나, 메시지 전체가 ```json 펜스 하나일 때만 인정한다(그 밖의 추출·수리 없음).
native_message_json() { # message-file out
  jq -Rs -e '
    (gsub("^\\s+|\\s+$"; "")) as $t
    | (if ($t|test("^```(json)?\\s*\\n")) and ($t|test("\\n```$")) then ($t | sub("^```(json)?\\s*\\n"; "") | sub("\\n```$"; "")) else $t end)
    | fromjson | select(type=="object")' "$1" > "$2.tmp" 2>/dev/null && mv "$2.tmp" "$2"
}
native_log_usage() { # role model label inv rc status
  local cap rates usage chk est='{"estimated_cost_usd":null,"assumptions":null}' basis=null
  cap="$(native_capture_file)"
  usage="$(jq -c '.usage // {}' "$cap")" || usage='{}'
  # 관측 판정(scripts/lib/telemetry.sh 의 claude_native_usage_check): 일부 요청의 usage 누락·필수 필드 누락·음수는 partial — 토큰·비용을 0 이나 부분 합으로 적지 않는다.
  #   context_last_turn 은 이 판정과 따로 간다: 훅이 마지막 본 모델 호출의 usage 만으로 검증해 잰 값(capture.context_last_turn_source 가 있다)은
  #   비용 관측이 partial 이어도 그대로 남긴다 — 워커 세션 교체 판단의 실측값이라, 비용을 모른다고 같이 버리면 교체가 멈춘다. 출처는 context_source 에 적는다.
  #   출처 표식이 없는 캡처(옛 훅 — 누락 필드를 0 으로 읽어 계산했다)의 값은 판정이 transcript 일 때만 쓴다.
  chk="$(claude_native_usage_check "$usage")" || chk='{"status":"unavailable","error":"USAGE_CHECK_FAILED","detail":"usage 판정 실패"}'
  # native subagent 는 비용을 보고하지 않는다 — 전사에서 읽은 토큰을 가격표(scripts/lib/telemetry.sh 의 claude_model_pricing)로 환산한다. 가격표에 없는 모델·환산할 수 없는 usage 는 unknown(0 달러 아님).
  if rates="$(claude_model_pricing "$2")"; then
    est="$(claude_native_estimate_cost "$usage" "$rates")" || est='{"estimated_cost_usd":null,"assumptions":null}'
    basis="\"$CLAUDE_PRICING_BASIS\""
  elif [ "$(printf '%s' "$chk" | jq -r '.status')" != transcript ]; then
    est="$(printf '%s' "$chk" | jq -c '{estimated_cost_usd:null, assumptions:.detail}')"
  fi
  jq -nc --slurpfile c "$cap" --argjson est "$est" --argjson chk "$chk" --argjson basis "$basis" --arg label "$3" --arg role "$1" --arg model "$2" --arg inv "$4" --argjson rc "$5" --arg st "$6" \
    --argjson v "${USAGE_SCHEMA_VERSION:-1}" --arg now "$(date '+%FT%T%z')" --arg req "$(native_request_field '.request_id')" '
    $c[0] as $c | (if $chk.status == "transcript" then ($c.usage // {}) else {} end) as $u
    | (if ($c.context_last_turn | type) != "number" then {tokens:null, source:null}
       elif ($c.context_last_turn_source | type) == "string" then {tokens:$c.context_last_turn, source:$c.context_last_turn_source}
       elif $chk.status == "transcript" then {tokens:$c.context_last_turn, source:"last_request_usage"}
       else {tokens:null, source:null} end) as $ctx
    | { schema_version: $v, invocation_id: $inv, label: $label, role: $role, cli: "claude_native", backend: "claude_native", model: $model,
        effort: ($c.efforts_observed[0] // null), session: $c.agent_id, request_id: $req, agent_id: $c.agent_id, parent_session_id: $c.session_id,
        cost_usd: null, cost_kind: (if $est.estimated_cost_usd == null then "unknown" else "estimated" end), estimated_cost_usd: $est.estimated_cost_usd,
        pricing_basis: (if $est.estimated_cost_usd == null then null else $basis end), pricing_assumptions: $est.assumptions, long_context_turns: null,
        input_uncached: ($u.input_tokens // null), cache_read: ($u.cache_read_input_tokens // null), cache_write: ($u.cache_creation_input_tokens // null),
        output: ($u.output_tokens // null), reasoning_output: null,
        input_effective: (if $u.input_tokens == null then null else ($u.input_tokens + $u.cache_read_input_tokens + $u.cache_creation_input_tokens) end),
        input_per_turn: null, context_last_turn: $ctx.tokens, context_source: $ctx.source, context_window: null, tokens_total: null,
        num_turns: ($u.api_requests // null), duration_ms: null, duration_api_ms: null,
        exit_code: $rc, success: ($rc == 0), usage_observation_status: $chk.status,
        usage_error: ([(if $st == "" then empty else $st end), ($chk.error // empty)] | if length == 0 then null else join("+") end),
        raw_log: $c.agent_transcript_path, source: "claude-native-transcript", recorded_at: $now }' >> "$WORK_DIR/usage.jsonl"
}
native_consume() {
  local dir id; dir="$(native_dir)"; id="$(native_request_field '.request_id')"
  native_request_set '.state="CONSUMED" | .consumed_at=$now' --arg now "$(date '+%FT%T%z')" || return 1
  mkdir -p "$dir/consumed" && mv "$(native_pending_file)" "$dir/consumed/$id.pending.json"
}

# ---------- 공용 진입점: run_readonly_json_role / run_edit_role 이 claude_native 일 때 위임한다 ----------
#   mode=readonly : 결과 JSON → $out, 캡처 사본 → $out.raw.   mode=edit : 보고 원문 → $raw, 스키마가 있으면 결과 JSON → $out.
#   반환 0 = 이번 재실행에서 캡처된 결과를 물질화했다(호출자의 기존 게이트가 이어서 판정).  반환 1 = Agent 는 돌았지만 쓸 수 있는 보고가 없다(CLI 실패와 같은 의미).
#   요청이 없거나 결과가 아직 없으면 반환하지 않고 exit 42, 결속 실패는 exit 43.
NATIVE_LAST_REQUEST_ID=""
native_role_call() { # mode ROLE session label prompt conv schema out raw
  local mode="$1" role="$2" session="$3" label="$4" prompt="$5" conv="$6" schema="$7" out="$8" raw="$9"
  local state cap msg inv status rc=0
  native_pending_guard "$role" "$label"
  if ! native_pending_present; then
    native_prepare "$mode" "$role" "$session" "$label" "$prompt" "$conv" "$schema" || return 1
    native_stop_required
  fi
  state="$(native_request_field '.state')"
  case "$state" in
    PREPARED|DISPATCHED) native_stop_required;;
    DISPATCHING) native_dispatch_unconfirmed;;
    REJECTED) native_reject "$(native_request_field '.rejection.code')" "$(native_request_field '.rejection.detail') (이전 실행에서 이미 불수용 — 재검증하지 않는다)";;
    RESULT_READY) ;;
    *) native_reject NATIVE_REQUEST_INVALID "알 수 없는 요청 state '$state'";;
  esac
  native_verify_binding "$mode" "$role" "$session" "$label" "$prompt" "$conv" "$schema"
  cap="$(native_capture_file)"; msg="$(jq -r '.message_path // ""' "$cap")"
  inv="$(native_request_field '.request_id')"; NATIVE_LAST_REQUEST_ID="$inv"
  status="$(jq -r '.report_status' "$cap")"
  if [ "$mode" = readonly ]; then cp "$cap" "$out.raw"; else cp "$cap" "$raw.capture.json"; fi
  if [ "$status" != OK ] || [ ! -s "$msg" ]; then
    echo "[FAIL] native Agent($role, request $inv)가 쓸 수 있는 보고 없이 끝났다(report_status $status) — 부분 텍스트를 성공 보고로 받지 않는다" >&2
    rc=1; status="NATIVE_REPORT_$status"
  else
    [ "$mode" = readonly ] || cp "$msg" "$raw"
    if [ -n "$schema" ]; then
      if ! native_message_json "$msg" "$out"; then
        echo "[FAIL] native Agent($role, request $inv)의 보고가 JSON 객체가 아니다: $msg — 추출·수리하지 않는다" >&2
        rc=1; status=NATIVE_REPORT_NOT_JSON
      else status=""; fi
    else status=""; fi
  fi
  native_log_usage "$role" "$(role_model "$role")" "$label" "$inv" "$rc" "$status" || echo "[WARN] native usage 기록 실패" >&2
  # 세션 스테이징: 확정은 호출자의 role_session_accept 다(스키마·계약 게이트 뒤). 재개 요청은 원장이 이미 있다.
  if [ "$(native_request_field '.session_intent')" = NEW ]; then
    native_session_stage "$role" "$session" "$(role_model "$role")" "$(role_effort "$role")" "$(native_request_field '.agent_definition_sha256')" \
      "$(jq -r '.agent_id' "$cap")" "$(jq -r '.session_id' "$cap")" || { echo "[FAIL] native 세션 스테이징 실패" >&2; return 1; }
  fi
  native_consume || { echo "[FAIL] native 요청 소비 기록 실패" >&2; return 1; }
  return "$rc"
}

# ---------- 단독 실행: redispatch / discard (사용자 결정 뒤의 명시적 수리) ----------
# 사용:
#   bash native-agent-bridge.sh redispatch <request_id>   거부가 확인된 dispatch 시도를 이력으로 옮기고 같은 요청을 PREPARED 로 되돌린다.
#        조건: state DISPATCHING + 그 시도의 거부가 메인 전사에서 확인됨(native_dispatch_evidence == DENIED) + 작업 트리·원본 저장소가 요청 발행 시점 그대로.
#        요청 id·session_intent·payload 는 그대로다 — 새 요청도 새 Agent(fresh)도 만들지 않는다. 불명·실행됨이면 거부한다.
#   bash native-agent-bridge.sh discard <request_id>      요청을 버린다(재실행하면 같은 호출 지점이 새 요청을 발행한다).
#        작업 트리가 요청의 호출 전 tree 와 같을 때만 pending 을 abandoned/ 로 옮긴다 — Agent 가 남긴 변경 위에서 조용히 새 요청을 만들지 않는다.
#
# 프로젝트 루트(= .agent-work 가 있는 곳) 선택 — native_standalone_project_root 한 곳에서 정한다:
#   ① FEATURE_PROJECT_ROOT 가 있으면 그 경로(명시가 우선). 상대 경로면 실행한 디렉터리 기준으로 풀어 절대 경로로 확정한 뒤에 쓴다.
#   ② 없으면 현재 디렉터리가 속한 git worktree 의 루트. 다만 그 worktree 가 이 스킬이 설치된 저장소와 **같은 저장소**(git common dir 일치)일 때만이다.
#      설치 저장소의 main working tree 자신이면 로더의 기본값을 그대로 쓴다(종전 동작).
#   ③ 다른 저장소·git 밖에서는 멈춘다 — 설치 위치(원본)의 .agent-work 로 조용히 넘어가지 않고, 무관한 저장소의 .agent-work 도 건드리지 않는다.
#   이 판정은 단독 복구 명령에만 쓴다. 로더를 source 하는 다른 사용처(러너·하위 루프·집계 도구)의 PROJECT_ROOT 기본값과 러너의 경로 재바인딩은 그대로다.
#   agent 정의 위치와 원본 상태 검사(native_origin_root / FEATURE_ORIGIN_ROOT)는 프로젝트 루트와 별개이며 바뀌지 않는다. 다른 worktree 의 요청은 찾지 않는다.
# 진입은 프로세스당 한 번이다: 아래에서 로더를 source 하면 로더가 이 파일을 다시 source 한다(절대 경로 실행이면 그때도 BASH_SOURCE[0] == $0).
#   재진입은 함수 정의만 다시 읽고 명령 처리는 하지 않는다. NATIVE_BRIDGE_MAIN_PID 는 export 하지 않는다(부모 프로세스에서 물려받은 값은 pid 가 달라 무시된다).
_native_git_common_dir() { # dir → 그 저장소의 git common dir(물리 경로)
  ( cd "$1" 2>/dev/null && c="$(git rev-parse --git-common-dir 2>/dev/null)" && cd "$c" 2>/dev/null && pwd -P )
}
NATIVE_STANDALONE_ROOT=""; NATIVE_STANDALONE_ROOT_EXPLICIT=0
native_standalone_project_root() { # install-root → NATIVE_STANDALONE_ROOT (+ NATIVE_STANDALONE_ROOT_EXPLICIT). 실패하면 사유를 stderr 에 내고 1
  local install="$1" top c_top c_install
  NATIVE_STANDALONE_ROOT=""; NATIVE_STANDALONE_ROOT_EXPLICIT=0
  if [ -n "${FEATURE_PROJECT_ROOT:-}" ]; then
    [ -d "$FEATURE_PROJECT_ROOT" ] || { echo "[FAIL] FEATURE_PROJECT_ROOT 가 디렉터리가 아니다: $FEATURE_PROJECT_ROOT" >&2; return 1; }
    top="$(git -C "$FEATURE_PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)" && [ "$(cd "$top" && pwd -P)" = "$(cd "$FEATURE_PROJECT_ROOT" && pwd -P)" ] \
      || { echo "[FAIL] FEATURE_PROJECT_ROOT($FEATURE_PROJECT_ROOT)가 git working tree 의 루트가 아니다 — 프로젝트(피처 worktree) 루트를 지정하라" >&2; return 1; }
    # 적힌 문자열이 아니라 확정한 절대 경로(git toplevel — 러너의 재바인딩과 같은 형태)를 쓴다. 상대 경로를 그대로 두면 아래의 cd 뒤에 다른 디렉터리를 가리킨다.
    NATIVE_STANDALONE_ROOT="$top"; NATIVE_STANDALONE_ROOT_EXPLICIT=1; return 0
  fi
  top="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "[FAIL] 현재 디렉터리($(pwd))가 git working tree 안이 아니다 — 어느 프로젝트의 요청인지 정할 수 없다. 요청이 속한 피처 worktree 루트에서 실행하거나 FEATURE_PROJECT_ROOT 로 지정하라(설치 위치 $install 의 요청으로 넘어가지 않는다)" >&2; return 1; }
  if [ "$(cd "$top" && pwd -P)" = "$(cd "$install" && pwd -P)" ]; then NATIVE_STANDALONE_ROOT="$install"; return 0; fi
  c_top="$(_native_git_common_dir "$top")"; c_install="$(_native_git_common_dir "$install")"
  if [ -z "$c_top" ] || [ -z "$c_install" ] || [ "$c_top" != "$c_install" ]; then
    echo "[FAIL] 현재 디렉터리의 저장소($top)는 이 스킬이 설치된 저장소($install)의 worktree 가 아니다(git common dir: ${c_top:-확인 불가} / ${c_install:-확인 불가}) — 무관한 저장소의 .agent-work 를 건드리지 않고, 설치 저장소의 요청으로 넘어가지도 않는다. 요청이 속한 worktree 루트에서 실행하거나 FEATURE_PROJECT_ROOT 로 명시하라" >&2
    return 1
  fi
  NATIVE_STANDALONE_ROOT="$top"
}
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${NATIVE_BRIDGE_MAIN_PID:-}" != "$$" ]; then
  NATIVE_BRIDGE_MAIN_PID=$$
  set -euo pipefail
  NATIVE_BRIDGE_STANDALONE=1
  _usage="사용법: bash $0 {redispatch|discard} <request_id>   (요청이 속한 프로젝트·피처 worktree 루트에서 실행하거나 FEATURE_PROJECT_ROOT 로 지정)"
  case "${1:-}" in redispatch|discard) [ -n "${2:-}" ] || { echo "$_usage" >&2; exit 1; };;
    *) echo "$_usage" >&2; exit 1;; esac
  _skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
  native_standalone_project_root "$(cd "$_skill_dir/../../.." && pwd)" || exit 1
  # 스냅샷·세션 원장·산출물 경로($WORK_DIR 상대)는 현재 디렉터리 기준이다 — 정한 루트로 옮겨 PROJECT_ROOT 기준 경로와 같은 트리를 보게 한다.
  cd "$NATIVE_STANDALONE_ROOT" || { echo "[FAIL] 프로젝트 루트로 이동 실패: $NATIVE_STANDALONE_ROOT" >&2; exit 1; }
  # 설치 저장소 자신이면 로더의 기본값(종전 문자열)을 그대로 둔다. worktree 면 러너의 재바인딩과 같은 값(git toplevel)을 넘긴다. export 하지 않는다.
  # 명시한 FEATURE_PROJECT_ROOT 는 확정한 절대 경로로 바꿔 넘긴다(상대 경로는 cd 뒤에 뜻이 달라진다).
  if [ "$NATIVE_STANDALONE_ROOT_EXPLICIT" = 1 ] || [ "$(pwd -P)" != "$(cd "$_skill_dir/../../.." && pwd -P)" ]; then FEATURE_PROJECT_ROOT="$NATIVE_STANDALONE_ROOT"; fi
  source "$_skill_dir/scripts/lib/bootstrap.sh"
  native_pending_present || { echo "[FAIL] pending native 요청이 없다: $(native_pending_file) (프로젝트 루트 $PROJECT_ROOT — 다른 worktree 의 요청이면 그 worktree 루트에서 실행하거나 FEATURE_PROJECT_ROOT 로 지정)" >&2; exit 1; }
  [ "$(native_pending_field '.request_id')" = "$2" ] || { echo "[FAIL] 요청 ID 불일치: 프로젝트 루트 $PROJECT_ROOT 의 pending 요청은 $(native_pending_field '.request_id') 다 — '$2' 가 아니다(다른 worktree 의 요청을 찾아 처리하지 않는다)" >&2; exit 1; }
  cur="$(snapshot_worktree_tree)"
  state="$(native_request_field '.state')"
  if [ "$1" = redispatch ]; then
    [ "$state" = DISPATCHING ] || { echo "[FAIL] 요청 state 가 $state 다 — redispatch 는 실행이 확인되지 않은 dispatch 시도(DISPATCHING)에만 쓴다. PREPARED 는 그대로 dispatch 하면 되고, 실행이 확인된 요청(DISPATCHED 이후)은 다시 보내지 않는다" >&2; exit 1; }
    native_dispatch_evidence
    [ "$NATIVE_EVID" = DENIED ] || { echo "[FAIL] 이 dispatch 시도의 거부가 확인되지 않았다($NATIVE_EVID: $NATIVE_EVID_DETAIL) — 실행됐을 수 있는 요청은 다시 보내지 않는다. 요청을 버리려면 사용자 결정 뒤 discard" >&2; exit 1; }
    [ "$cur" = "$(native_request_field '.pre_tree')" ] \
      || { echo "[FAIL] 작업 트리($cur)가 요청의 호출 전 tree($(native_request_field '.pre_tree'))와 다르다 — 거부된 호출인데 변경이 있다. 요청의 호출 전 상태가 더는 맞지 않으므로 다시 보내지 않는다(변경을 확인한 뒤 discard)" >&2; exit 1; }
    [ "$(native_origin_state)" = "$(native_request_field '.origin_state')" ] \
      || { echo "[FAIL] 요청 발행 뒤 원본 저장소($(native_origin_root))의 작업 상태가 바뀌었다 — 다시 보내도 수용 단계가 NATIVE_WORKTREE_CONFUSION 으로 거부한다. 변경을 확인한 뒤 discard" >&2; exit 1; }
    native_request_set '.dispatch_history=((.dispatch_history // []) + [.dispatch_attempt + {outcome:"DENIED", denial:$d, released_at:$now}])
        | del(.dispatch_attempt) | del(.last_denial) | del(.post_tool) | .state="PREPARED"' --arg d "$NATIVE_EVID_DETAIL" --arg now "$(date '+%FT%T%z')"
    echo "[OK] native 요청 $2 의 거부된 dispatch 시도를 이력으로 옮기고 PREPARED 로 되돌렸다 — 같은 요청(같은 id·같은 payload·session_intent $(native_request_field '.session_intent'))이다."
    echo "     확인된 거부: $NATIVE_EVID_DETAIL"
    echo "     거부 원인이 해소됐을 때만 같은 dispatch 한 줄을 한 번 보낸다. 해소되지 않았으면 같은 거부가 다시 난다."
    exit 0
  fi
  [ "$cur" = "$(native_request_field '.pre_tree')" ] \
    || { echo "[FAIL] 작업 트리($cur)가 요청의 호출 전 tree($(native_request_field '.pre_tree'))와 다르다 — Agent 가 남긴 변경이 있다. git diff $(native_request_field '.pre_tree') $cur 로 확인하고 사용자가 정리한 뒤 다시 실행(자동 원복 없음)" >&2; exit 1; }
  case "$state" in
    DISPATCHING|DISPATCHED)
      native_dispatch_evidence
      [ "$NATIVE_EVID" = DENIED ] || echo "[WARN] 요청 state 가 $state 이고 거부가 확인되지 않았다($NATIVE_EVID: $NATIVE_EVID_DETAIL) — Agent 가 아직 돌고 있을 수 있다. 그 Agent 가 나중에 남기는 변경은 이 요청과 무관한 변경으로 잡힌다." >&2;;
  esac
  native_request_set '.state="ABANDONED" | .abandoned_at=$now | .abandoned_from_state=$from' --arg now "$(date '+%FT%T%z')" --arg from "$state"
  mkdir -p "$(native_dir)/abandoned" && mv "$(native_pending_file)" "$(native_dir)/abandoned/$2.pending.json"
  echo "[OK] native 요청 $2 를 치웠다 — 재실행하면 같은 호출 지점이 새 요청을 발행한다."
fi
