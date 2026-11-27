#!/usr/bin/env bash
# =============================================================
# .claude/skills/feature/scripts/lib/backend/router.sh
# 역할 → CLI/backend 라우팅(role_cli·role_backend·role_bin·require_role_bins)·run_readonly_json_role·워커 CLI 도구 제한·run_edit_role·role_raw_diag_tail.
# scripts/lib/bootstrap.sh 가 정해진 순서로 source 한다 — 직접 실행하지 않는다.
# (분리 전 config.sh 기준 577–887)
# =============================================================

# =============================================================
# 역할 → CLI 라우팅과 공통 호출 헬퍼
# 역할별 CLI 를 스크립트에 고정하지 않는다. 모델 ID(또는 <ROLE>_CLI 명시)로 claude/codex 를 고르고,
# 역할이 요구하는 실행 형태(읽기 전용+스키마 JSON / 편집)를 두 CLI 의 플래그로 각각 옮긴다.
# =============================================================
cli_for_model() { # model → claude|codex (이름으로 정할 수 없으면 1)
  case "$1" in
    claude*)                 printf 'claude' ;;
    gpt-*|o[0-9]*|codex*)    printf 'codex' ;;
    *)                       return 1 ;;
  esac
}
role_model()  { local v="${1}_MODEL"; [ "$1" = DESIGNER ] && v=DESIGN_REVISION_MODEL; printf '%s' "${!v}"; } # DESIGNER 역할은 DESIGN_REVISION_MODEL 을 읽는다
role_effort() { local v="${1}_EFFORT"; printf '%s' "${!v}"; }
role_cli() { # ROLE(DESIGNER|VALIDATOR|WORKER|REVIEWER|FIXER) → claude|codex
  local role="$1" override_var="${1}_CLI" override model
  override="${!override_var:-}"; model="$(role_model "$role")"
  if [ -n "$override" ]; then
    case "$override" in
      claude|codex) ;;
      *) echo "[FAIL] config.sh $override_var='$override' — claude 또는 codex 만 허용" >&2; return 1 ;;
    esac
    # native 라우팅에서는 모델 이름이 backend 를 정한다 — 이름으로 판정되는 모델을 반대 CLI 로 강제하는 모순된 재정의를 조용히 받지 않는다.
    # (이름으로 판정할 수 없는 모델에 대한 명시 지정은 그대로 허용한다. legacy_cli 는 종전 의미 그대로다.)
    if [ "${CLAUDE_BACKEND:-legacy_cli}" = native ]; then
      local by_name; by_name="$(cli_for_model "$model" || true)"
      if [ -n "$by_name" ] && [ "$by_name" != "$override" ]; then
        echo "[FAIL] ROLE_CLI_CONFLICT: $role 모델 '$model' 은 이름으로 $by_name 인데 config.sh $override_var='$override' 가 반대로 강제한다 — 모델 기준 라우팅(CLAUDE_BACKEND=native)에서는 허용하지 않는다. $override_var 를 비우거나 모델을 바꿔라" >&2
        return 1
      fi
    fi
    printf '%s' "$override"; return 0
  fi
  cli_for_model "$model" \
    || { echo "[FAIL] 모델 '$model'($role) 의 CLI 를 이름으로 정하지 못함 — config.sh 에 $override_var=claude|codex 를 지정" >&2; return 1; }
}
# 실행 backend: 모델(→ role_cli)과 CLAUDE_BACKEND 가 정한다. 역할 이름으로 분기하지 않는다.
#   codex_cli        = `codex exec` / `codex exec resume` (CODEX_BACKEND=legacy_exec — 이 줄이 없는 예전 config.sh 포함)
#   codex_app_server = 하네스가 직접 띄운 `codex app-server` JSON-RPC (CODEX_BACKEND=app_server)
# role_cli 는 모델 계열(claude|codex)만 답한다 — 실행 수단은 반드시 이 함수로 가린다(codex 라는 이유로 exec 경로에 들어가지 않게).
role_backend() { # ROLE → claude_native | claude_cli | codex_cli | codex_app_server
  local cli; cli="$(role_cli "$1")" || return 1
  case "$cli" in
    codex)
      case "${CODEX_BACKEND:-legacy_exec}" in
        app_server) printf 'codex_app_server' ;;
        legacy_exec) printf 'codex_cli' ;;
        *) echo "[FAIL] config.sh CODEX_BACKEND='${CODEX_BACKEND}' — app_server 또는 legacy_exec 만 허용" >&2; return 1 ;;
      esac ;;
    claude)
      case "${CLAUDE_BACKEND:-legacy_cli}" in
        native) printf 'claude_native' ;;
        legacy_cli) printf 'claude_cli' ;;
        *) echo "[FAIL] config.sh CLAUDE_BACKEND='${CLAUDE_BACKEND}' — native 또는 legacy_cli 만 허용" >&2; return 1 ;;
      esac ;;
  esac
}
role_bin() { # ROLE → 실행 파일 (native Agent 는 실행 파일이 없다 — 빈 값)
  case "$(role_backend "$1")" in claude_cli) printf '%s' "$CLAUDE_BIN" ;; codex_cli|codex_app_server) printf '%s' "$CODEX_BIN" ;; claude_native) printf '' ;; *) return 1 ;; esac
}
require_role_bins() { # ROLE... [+ 공용 도구...] : 설정된 역할이 실제로 쓰는 CLI 만 설치 확인
  local item bin
  for item in "$@"; do
    case "$item" in
      DESIGNER|VALIDATOR|WORKER|REVIEWER|FIXER)
        bin="$(role_bin "$item")" || return 1
        # Codex App Server backend 는 codex 바이너리에 더해 Node.js 런타임이 필요하다(프로토콜 지원 여부는 호출 직전의 사전 검사가 본다)
        if [ "$(role_backend "$item")" = codex_app_server ]; then
          command -v "${CODEX_APP_SERVER_NODE_BIN:-node}" >/dev/null 2>&1 \
            || { echo "[FAIL] '${CODEX_APP_SERVER_NODE_BIN:-node}' 미설치 (${item} — Codex App Server backend 는 Node.js 18+ 가 필요하다. codex exec 로 대체하지 않는다)" >&2; return 1; }
        fi ;;
      *) bin="$item" ;;
    esac
    [ -n "$bin" ] || continue   # native Agent 로 라우팅된 역할은 CLI 설치를 요구하지 않는다
    command -v "$bin" >/dev/null 2>&1 || { echo "[FAIL] '$bin' 미설치 (${item})" >&2; return 1; }
  done
}

# 읽기 전용·스키마 강제 JSON 역할(검증자·리뷰어).
#   결과 JSON → $out. 부산물: claude 는 $out.raw(전체 응답, structured_output 추출 전), codex 는 $out.events.jsonl(--json stdout) + $out.stderr.log.
#   conventions: 프롬프트에 이미 들어 있으면 "" 를 넘긴다. claude 는 --append-system-prompt, codex 는 프롬프트 앞 블록으로 붙인다.
#   두 CLI 모두 같은 session_name(key) 이면 '수용된' 세션을 이어간다(claude --resume / codex exec resume). 호출자가 호출마다 다른 이름을 주면
#   fresh 다(합의 루프의 검증자). 세션 확정은 호출자의 role_session_accept 가 한다 — 이 함수는 스테이징까지만.
#   두 CLI 모두 invocation 마다 usage.jsonl 에 행 1개(log_role_usage).
RUN_READONLY_INVOCATION_ID=""   # 마지막 run_readonly_json_role 의 invocation id — 호출자가 무효 출력 기록(invalid-review.json)에 남긴다
run_readonly_json_role() { # ROLE session_name usage_label schema_file out_json prompt conventions
  local role="$1" session="$2" label="$3" schema="$4" out="$5" prompt="$6" conv="$7" model effort cli rc=0 inv
  model="$(role_model "$role")"; effort="$(role_effort "$role")"; cli="$(role_cli "$role")" || return 1
  # native Agent backend: 요청 발행(exit 42) 또는 캡처된 결과의 검증·물질화. 반환했다면 $out 은 이번 요청의 결과다(스키마·계약 검사는 호출자 그대로).
  if [ "$(role_backend "$role")" = claude_native ]; then
    native_role_call readonly "$role" "$session" "$label" "$prompt" "$conv" "$schema" "$out" "" || return 1
    RUN_READONLY_INVOCATION_ID="$NATIVE_LAST_REQUEST_ID"
    return 0
  fi
  native_pending_guard "$role" "$label"   # 다른 호출 지점의 native 요청이 남아 있으면 그 위에서 CLI 를 부르지 않는다(없으면 no-op)
  # Codex App Server backend: 같은 인자·같은 $out·같은 종료 의미로 런타임에 위임한다(scripts/codex-app-server.sh). 아래 codex exec 분기는 legacy_exec 전용이다.
  # 부산물은 $out.appserver.jsonl(서버 stdout 원문) · $out.appserver.sent.jsonl · $out.stderr.log — codex exec 의 $out.events.jsonl 과 형식이 달라 이름을 나눈다.
  if [ "$(role_backend "$role")" = codex_app_server ]; then
    codex_app_run_readonly "$role" "$session" "$label" "$schema" "$out" "$prompt" "$conv"; return $?
  fi
  inv="$(new_invocation_id)"; RUN_READONLY_INVOCATION_ID="$inv"
  case "$cli" in
    codex)
      [ -z "$conv" ] || prompt="$conv"$'\n\n'"$prompt"
      # 세션 정책은 key 가 정한다: 같은 key 의 수용된 원장이 있으면 그 thread 로 exec resume, 없으면 새 exec (역할·CLI 이름으로 추론하지 않음).
      codex_session_begin "$role" "$session" "$model" "$effort" || return 1
      # invocation 전용 임시 -o 경로: 이번 호출이 만든 파일은 이것 하나뿐이다. 이전 실행·픽스처가 $out 에 남긴 파일을 이번 결과로 오인하지 않고,
      # 내용·mtime 으로 provenance 를 추론하지도 않는다(같은 JSON 을 다시 써도 새 결과다). usable 할 때만 $out 으로 atomic move.
      local tmp_out="$out.invocation-$inv.tmp"
      rm -f "$tmp_out"
      # --json: stdout 은 이벤트 JSONL(usage telemetry 원천, $out.events.jsonl), stderr 는 진단($out.stderr.log) — 한 파일에 섞으면 JSONL 이 깨진다.
      # structured result 는 계속 invocation 전용 -o 파일만 인정한다(telemetry 와 result provenance 는 별개) — resume 이어도 이전 결과를 새 결과로 오인하지 않는다.
      if [ "$CODEX_SESSION_MODE" = resume ]; then
        # 저장된 thread_id 로만 resume(--last·자동 검색 금지). 읽기 전용 샌드박스·스키마 강제·모델/effort·stdout/stderr 분리를 신규 호출과 동일하게 유지한다.
        codex_resume_cli_check || return 1
        local sandbox_args=(-c 'sandbox_mode="read-only"')
        [ "$CODEX_RESUME_HAS_SANDBOX_FLAG" -eq 1 ] && sandbox_args+=(--sandbox read-only)
        codex_resume_marker_write "$session" "$inv" "$label" || return 1
        "$CODEX_BIN" exec resume "$CODEX_SESSION_ID" --json -m "$model" -c "model_reasoning_effort=\"$effort\"" \
          "${sandbox_args[@]}" --output-schema "$schema" -o "$tmp_out" \
          "$prompt" > "$out.events.jsonl" 2> "$out.stderr.log" || rc=$?
      else
        "$CODEX_BIN" exec --json -m "$model" -c "model_reasoning_effort=\"$effort\"" --sandbox read-only \
          --output-schema "$schema" -o "$tmp_out" \
          "$prompt" > "$out.events.jsonl" 2> "$out.stderr.log" || rc=$?
      fi
      log_role_usage codex "$role" "$model" "$label" "$out.events.jsonl" "$rc" "$inv"   # raw exit code 그대로 (exit_code/success 위조 없음)
      if ! { [ -s "$tmp_out" ] && jq -e 'type=="object"' "$tmp_out" >/dev/null 2>&1; }; then
        rm -f "$tmp_out"
        if [ "$CODEX_SESSION_MODE" = resume ]; then
          # 스레드에 메시지가 전달됐을 수 있다 — 새 세션으로 자동 전환하지 않고 marker 를 유지해 다음 실행도 모델 호출 0회로 멈춘다.
          echo "[FAIL] codex resume 실행 실패 또는 결과 JSON 없음 (exit $rc, $role/$session) — 자동 새 세션 전환 없음. resume marker 유지: $(codex_resume_marker "$session")" >&2
        else
          echo "[FAIL] codex 실행 실패 또는 결과 JSON 없음 (exit $rc, 모델 '$model', $role 확인)" >&2
        fi
        tail -20 "$out.stderr.log" >&2; return 1
      fi
      if [ "$rc" -ne 0 ]; then
        # rc ≠ 0 이어도 이번 호출이 파싱 가능한 결과 JSON 을 썼으면 즉시 폐기하지 않는다 — 호출자의 schema/contract 검사가 최종 게이트다.
        # (codex 는 작업을 정상 완료한 뒤 프로세스 종료코드가 간헐적으로 1 이 되는 사례가 있다.)
        echo "[WARN] CLI_EXIT_STATUS_MISMATCH: $role codex exited $rc, but current invocation produced a JSON result ($tmp_out); using it subject to the caller's schema/contract checks" >&2
        record_cli_anomaly "$role" codex "$label" "$rc" STRUCTURED_RESULT "$out"
      fi
      if [ "$CODEX_SESSION_MODE" = resume ]; then
        codex_session_check_resumed "$session" "$out.events.jsonl" \
          || { rm -f "$tmp_out"; echo "[FAIL] codex resume($session) 이벤트의 thread id 가 원장과 다름 — 이번 호출 결과 불수용(marker 유지, 자동 재실행 없음)." >&2; return 1; }
      else
        # 신규 세션: thread.started.thread_id 가 유일할 때만 스테이징. 유일하지 않으면 세션 확정 금지(WARN) — 결과 자체는 유효할 수 있으므로
        # 여기서 버리지 않고, 세션 재사용이 계약인 호출자의 role_session_accept 가 "확정할 세션 없음"으로 명시적 오류를 낸다.
        # 재사용하지 않는 역할(호출마다 고유 key)은 accept 를 부르지 않으므로 영향이 없다.
        codex_session_stage "$role" "$session" "$model" "$effort" "$out.events.jsonl" 2>/dev/null \
          || echo "[WARN] codex 호출($session)의 thread.started.thread_id 미확정 — 세션 원장 스테이징 생략(이 key 는 세션을 잇지 못한다)" >&2
      fi
      mv "$tmp_out" "$out"
      ;;
    claude)
      claude_session_cli_guard "$role" "$session" || return 1
      local session_args conv_args=()
      [ -z "$conv" ] || conv_args=(--append-system-prompt "$conv")
      session_args=$(claude_session_args "$session")
      # FEATURE_ROLE_CHILD=1: 프로젝트 UserPromptSubmit 훅(inject_conventions.sh)이 conventions 를 다시 넣지 않게 한다 — 여기서 이미 명시 전달.
      FEATURE_ROLE_CHILD=1 "$CLAUDE_BIN" -p $session_args --model "$model" --effort "$effort" \
        ${conv_args[@]+"${conv_args[@]}"} \
        --tools "Read,Grep,Glob" \
        --disallowedTools "Bash,Edit,Write,NotebookEdit" \
        --json-schema "$(cat "$schema")" --output-format json \
        "$prompt" \
        > "$out.raw" || rc=$?
      log_role_usage claude "$role" "$model" "$label" "$out.raw" "$rc" "$inv"
      [ "$rc" -eq 0 ] || { echo "[FAIL] claude 실행 실패 (모델 '$model', $role 확인)" >&2; return 1; }
      # 세션 확정(.new 커밋)은 호출자의 role_session_accept 가 한다 — 스키마·계약 검사에 떨어진 호출의 세션을 잇지 않는다.
      jq -e '.structured_output' "$out.raw" > "$out" \
        || { echo "[FAIL] 응답에 structured_output 없음: $out.raw" >&2; return 1; }
      ;;
  esac
}

# ---------- 워커 CLI 도구 제한 (role=WORKER 에만, SH 강제) ----------
# 워커가 CLI 관리형 하위 Agent·내장 백그라운드 실행을 쓰면 한 invocation 에 result 이벤트가 여러 개 남고(claude) 결과 판정이 깨진다
# (2026-10 Unit 13: result 10개 → 약 $17 작업 폐기). 프롬프트 지시가 아니라 CLI 인자·child 환경변수로 막는다 — 최초 호출·resume·
# handoff 뒤 새 세대 모두 같은 run_edit_role 경로를 지나므로 정책이 같다. 배열로 조립하고 eval 은 쓰지 않는다.
#   claude: --disallowedTools Agent,ScheduleWakeup + child 환경변수 CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 CLAUDE_CODE_DISABLE_AGENT_VIEW=1.
#           SendMessage 는 금지하지 않는다. Monitor 등 무관한 도구도 임의로 막지 않는다. --allowedTools 는 독점 허용 목록이 아니므로 Agent 차단을 대체하지 못한다.
#   codex : exec / exec resume 모두 -c 'agents.enabled=false' (전역 ~/.codex/config.toml 은 건드리지 않는다). 다른 -c 보다 뒤에 두어
#           호출별 설정이 덮어쓰지 못하게 한다.
# 설치된 CLI 가 이 옵션을 거부하면 그 호출은 그대로 실패한다 — 제한을 풀거나 무제한으로 재실행하지 않는다.
# 이 제한이 막는 것은 CLI 관리형 하위 Agent 와 내장 백그라운드 기능이다. 워커가 일반 Bash 에서 `&`/nohup/별도 CLI 를 직접 띄우는 것까지
# OS 수준에서 막지는 않으며, 그걸 위한 프로세스 감시는 두지 않는다(런너의 shell 게이트·result 유일성 판정이 사후에 잡는다).
WORKER_CLAUDE_DISALLOWED_TOOLS="Agent,ScheduleWakeup"   # 아래 run_edit_role 이 배열로 조립한다(bash 3.2 호환 — mapfile 미사용)

# 편집 역할(디자이너·수정자·워커). 원문 출력을 $raw(claude) 또는 $raw.events.jsonl + $raw.stderr.log(codex) 에 남기고 CLI 종료 코드를 그대로 돌려준다(호출자가 set +e 로 받는다).
#   schema_file/out_json 이 비어 있지 않으면 스키마 강제 JSON 을 out_json 에 남긴다(워커). claude 는 structured_output 을 추출한다.
#   conventions 는 run_readonly_json_role 과 같다. 나머지 인자는 claude 에만 붙는 추가 플래그(예: --allowedTools Bash).
#   role=WORKER 면 위 워커 CLI 도구 제한이 두 CLI 모두에 붙는다(DESIGNER/FIXER 는 그대로).
#   [Added] 전역 출력: RUN_EDIT_ROLE_CLI_RC = CLI 프로세스의 실제 종료 코드(반환값과 다를 수 있다 — claude result 판정 실패 시 반환값은 1 이지만 CLI rc 는 그대로 남긴다),
#   RUN_EDIT_ROLE_RESULT_DIAG = claude result 판정 진단(CLAUDE_RESULT_MISSING|MULTIPLE|INVALID, 정상이면 빈 값). 호출자가 가드·보고에 쓴다.
RUN_EDIT_ROLE_CLI_RC=0; RUN_EDIT_ROLE_RESULT_DIAG=""; RUN_EDIT_ROLE_INVOCATION_ID=""
run_edit_role() { # ROLE session_name usage_label raw_out prompt conventions schema_file out_json [claude_extra_args...]
  local role="$1" session="$2" label="$3" raw="$4" prompt="$5" conv="$6" schema="$7" out="$8"; shift 8
  local model effort cli rc=0 inv
  RUN_EDIT_ROLE_CLI_RC=0; RUN_EDIT_ROLE_RESULT_DIAG=""; RUN_EDIT_ROLE_INVOCATION_ID=""
  model="$(role_model "$role")"; effort="$(role_effort "$role")"; cli="$(role_cli "$role")" || return 1
  # native Agent backend: 도구 제한은 agent 정의(tools allowlist — Agent·ScheduleWakeup 없음)가 강제하므로 claude 전용 추가 인자("$@")는 쓰지 않는다.
  # 반환값은 CLI rc 와 같은 의미다(0 = 보고 수신, 1 = Agent 는 돌았지만 쓸 수 있는 보고 없음) — 호출자의 기존 게이트·가드가 그대로 판정한다.
  if [ "$(role_backend "$role")" = claude_native ]; then
    native_role_call edit "$role" "$session" "$label" "$prompt" "$conv" "$schema" "$out" "$raw" || rc=$?
    RUN_EDIT_ROLE_INVOCATION_ID="$NATIVE_LAST_REQUEST_ID"; RUN_EDIT_ROLE_CLI_RC="$rc"
    [ "$rc" -eq 0 ] || RUN_EDIT_ROLE_RESULT_DIAG="NATIVE_REPORT_UNUSABLE"
    # 세션 확정 시점은 claude CLI 경로와 같다: 스키마 없는 편집 역할(디자이너·수정자)은 보고를 받은 호출(rc 0)에서 확정하고,
    # 스키마 역할(워커)은 호출자의 role_session_accept 가 결과 검증 뒤에 확정한다.
    if [ "$rc" -eq 0 ] && [ -z "$schema" ]; then native_session_accept "$role" "$session" "$label" || return 1; fi
    return "$rc"
  fi
  native_pending_guard "$role" "$label"
  # Codex App Server backend: 런타임에 위임한다. 워커의 하위 Agent 금지(agents.enabled=false)는 그 호출의 자식 프로세스 인자로만 들어가 다른 역할에 새지 않는다.
  # 반환값: 0 완료 / 10 turn/start 전 실패(모델 0회) / 20 turn 실패 / 30 완료 여부 불명 / 1 호출 전 중단. claude 전용 추가 인자("$@")는 쓰지 않는다.
  # 30(불명)은 '끝났지만 종료 코드만 비정상'이 아니다 — 호출자는 범위 안 변경이 있어도 다음 검증자·리뷰어로 넘기지 않는다(codex_app_stop_if_uncertain).
  if [ "$(role_backend "$role")" = codex_app_server ]; then
    codex_app_run_edit "$role" "$session" "$label" "$raw" "$prompt" "$conv" "$schema" "$out"; return $?
  fi
  inv="$(new_invocation_id)"; RUN_EDIT_ROLE_INVOCATION_ID="$inv"   # CLI 실행 전 preflight 실패(위 return 1)는 invocation 이 아니다
  # [Added] 워커 전용 CLI 정책 — 배열로 조립(eval 없음). 다른 역할은 빈 배열.
  local policy_args=() policy_env=()
  if [ "$role" = WORKER ]; then
    case "$cli" in
      claude) policy_args=(--disallowedTools "$WORKER_CLAUDE_DISALLOWED_TOOLS"); policy_env=(CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 CLAUDE_CODE_DISABLE_AGENT_VIEW=1) ;;
      codex)  policy_args=(-c 'agents.enabled=false') ;;
    esac
  fi
  case "$cli" in
    codex)
      [ -z "$conv" ] || prompt="$conv"$'\n\n'"$prompt"
      # 읽기 전용 역할과 같은 세션 어댑터를 쓴다(역할별 복사 구현 없음). 수용된 같은 key 원장이 있을 때만 resume — 호출마다 고유 key 를
      # 쓰거나 호출자가 accept 하지 않는 역할(현재 워커·디자이너)은 기존처럼 항상 새 exec 다.
      codex_session_begin "$role" "$session" "$model" "$effort" || return 1
      local schema_args=()
      [ -z "$schema" ] || schema_args=(--output-schema "$schema" -o "$out")
      # --json stdout(이벤트 JSONL) 과 stderr 를 분리한다 — tee 로 합치면 JSONL 이 깨지고 pipe rc 가 섞인다. raw codex rc 를 그대로 돌려준다.
      # 워커 정책(-c agents.enabled=false)은 resume/new 양쪽에 같은 위치(다른 -c 뒤)로 들어간다.
      if [ "$CODEX_SESSION_MODE" = resume ]; then
        codex_resume_cli_check || return 1
        local sandbox_args=(-c 'sandbox_mode="workspace-write"')
        [ "$CODEX_RESUME_HAS_SANDBOX_FLAG" -eq 1 ] && sandbox_args+=(--sandbox workspace-write)
        codex_resume_marker_write "$session" "$inv" "$label" || return 1
        "$CODEX_BIN" exec resume "$CODEX_SESSION_ID" --json -m "$model" -c "model_reasoning_effort=\"$effort\"" \
          "${sandbox_args[@]}" ${policy_args[@]+"${policy_args[@]}"} ${schema_args[@]+"${schema_args[@]}"} "$prompt" > "$raw.events.jsonl" 2> "$raw.stderr.log" || rc=$?
      else
        "$CODEX_BIN" exec --json -m "$model" -c "model_reasoning_effort=\"$effort\"" --sandbox workspace-write \
          ${policy_args[@]+"${policy_args[@]}"} ${schema_args[@]+"${schema_args[@]}"} "$prompt" > "$raw.events.jsonl" 2> "$raw.stderr.log" || rc=$?
      fi
      log_role_usage codex "$role" "$model" "$label" "$raw.events.jsonl" "$rc" "$inv"
      RUN_EDIT_ROLE_CLI_RC="$rc"
      if [ "$CODEX_SESSION_MODE" = resume ]; then
        # 불일치면 이번 호출의 -o 결과도 제거한다 — 호출자(run_worker 의 "rc≠0 + 유효 결과" 복구 경로)가
        # 어느 스레드의 것인지 모르는 결과를 수용하지 못하게 한다. 작업 트리 변경은 원복하지 않는다(worker-outcome 가드가 판정).
        codex_session_check_resumed "$session" "$raw.events.jsonl" \
          || { [ -z "$schema" ] || rm -f "$out"; echo "[FAIL] codex resume($session) 이벤트의 thread id 가 원장과 다름 — 이번 호출 결과 불수용(marker 유지)." >&2; return 1; }
      else
        # 편집 역할의 신규 세션: 결과 게이트(worker_result_valid·지문·write-set)는 호출자에 있으므로 thread id 미확정이 호출 실패는 아니다 —
        # 이 key 는 세션을 잇지 않을 뿐이다(WARN). 읽기 전용 역할의 strict 규칙과 의도적으로 다르다.
        codex_session_stage "$role" "$session" "$model" "$effort" "$raw.events.jsonl" 2>/dev/null \
          || echo "[WARN] codex 편집 호출($session)의 thread.started.thread_id 미확정 — 세션 원장 스테이징 생략(재사용 없음)" >&2
      fi
      ;;
    claude)
      claude_session_cli_guard "$role" "$session" || return 1
      local session_args conv_args=() schema_args=()
      [ -z "$conv" ] || conv_args=(--append-system-prompt "$conv")
      [ -z "$schema" ] || schema_args=(--json-schema "$(cat "$schema")")
      session_args=$(claude_session_args "$session")
      # stream-json: model 호출(assistant 메시지)마다 usage 가 오므로 '마지막 턴의 실제 컨텍스트'(context_last_turn)를 잴 수 있다.
      # 유일한 result 이벤트는 --output-format json 의 결과와 같은 객체다 — 그걸 $raw 로 뽑아 아래 소비자(structured_output·usage)는 그대로 둔다.
      # [Modified] 워커 정책: child 프로세스에만 환경변수(env …)와 --disallowedTools 를 붙인다. 다른 역할은 두 배열이 비어 있어 인자가 같다.
      env ${policy_env[@]+"${policy_env[@]}"} FEATURE_ROLE_CHILD=1 "$CLAUDE_BIN" -p $session_args --model "$model" --effort "$effort" --permission-mode acceptEdits \
        ${conv_args[@]+"${conv_args[@]}"} \
        ${schema_args[@]+"${schema_args[@]}"} \
        "$@" ${policy_args[@]+"${policy_args[@]}"} --verbose --output-format stream-json \
        "$prompt" \
        > "$raw.stream.jsonl" || rc=$?
      # [Modified] result 이벤트가 정확히 하나일 때만 $raw 를 만든다. 0개·복수·파싱 실패는 명시적 오류(CLAUDE_RESULT_*)이며 중간의 유효해 보이는
      # 이벤트를 골라 승인하지 않는다 — $raw 가 없으면 아래 structured_output 추출이 실패하고 호출자(run_worker)는 "rc≠0 + 유효 결과 없음" 경로
      # (작업 트리가 바뀌었으면 WORKER_OUTCOME_UNCERTAIN 가드, 아니면 실행 실패)를 탄다. 원본 stream.jsonl·CLI rc·호출 전후 tree 는 그대로 남는다.
      # CLI 가 0 으로 끝났어도 결과가 유일하지 않으면 성공으로 돌려주지 않는다(세션도 확정하지 않는다). 같은 작업을 자동 재호출하지 않는다.
      RUN_EDIT_ROLE_CLI_RC="$rc"
      if claude_stream_extract_result "$raw.stream.jsonl" "$raw" "$role/$label"; then
        log_role_usage claude "$role" "$model" "$label" "$raw" "$RUN_EDIT_ROLE_CLI_RC" "$inv"   # exit_code 는 CLI 의 실제 값
      else
        RUN_EDIT_ROLE_RESULT_DIAG="$CLAUDE_RESULT_DIAG"
        [ "$rc" -ne 0 ] || rc=1
        # [Added: GOAL-6] 결과를 판정할 수 없어도 실제로 시작한 invocation 이므로 usage 행 1개(cost unknown)를 남긴다 — 숨은 0건 금지, 모델 재호출 없음
        log_claude_usage_unavailable "$label" "$role" "$model" "$raw.stream.jsonl" "$RUN_EDIT_ROLE_CLI_RC" "$inv" "$CLAUDE_RESULT_DIAG"
      fi
      # [Modified: 리뷰 2] 세션 확정은 결과 검증 뒤에만 — 스키마 역할(워커)은 여기서 확정하지 않고 호출자의 role_session_accept 가
      # worker_result_valid 통과 뒤에 확정한다(codex 원장 .new 와 같은 2단계). 첫 턴의 결과가 무효면 .session-<key>.new 만 남고 다음 실행은
      # 그 대화를 잇지 않는다(실패 세션 격리). 이미 확정된 세션의 후속 턴이 무효로 끝난 경우는 되돌릴 수 없으므로 재개 프롬프트의
      # 서열(문서 → 현재 코드 → 세션 기억)이 그 턴의 기억을 덮는다. 스키마 없는 편집 역할(디자이너·수정자)은 종전처럼 rc 0 에서 확정한다.
      [ "$rc" -ne 0 ] || [ -n "$schema" ] || claude_session_commit "$session"
      # [Modified] 스키마 역할: 유일한 result($raw)가 있으면 CLI rc 와 무관하게 structured_output 을 꺼낸다 — codex 의 -o 파일과 같은 의미다.
      # rc≠0 + 유일하고 유효한 결과를 수용할지는 호출자의 CLI_EXIT_STATUS_MISMATCH 판정이 정한다(세션 확정도 호출자의 accept). structured_output 이 없으면 out 을 남기지 않는다.
      if [ -n "$schema" ] && [ -f "$raw" ]; then
        jq -e '.structured_output' "$raw" > "$out" 2>/dev/null || { rm -f "$out"; [ "$rc" -ne 0 ] || rc=1; }
      fi
      ;;
  esac
  return "$rc"
}
# 편집 역할 실패 진단용 tail: codex 는 $raw.stderr.log, claude 는 $raw.
role_raw_diag_tail() { # raw
  if [ -f "$1.stderr.log" ]; then tail -20 "$1.stderr.log"; elif [ -f "$1" ]; then tail -20 "$1"; fi
}
