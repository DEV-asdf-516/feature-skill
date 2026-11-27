#!/usr/bin/env bash
# =============================================================
# .claude/skills/feature/scripts/lib/backend/session.sh
# CLI 독립 세션 정책·claude 세션 인자/확정·session_exists·role_contract_version·codex 세션 어댑터·role_session_accept.
# scripts/lib/bootstrap.sh 가 정해진 순서로 source 한다 — 직접 실행하지 않는다.
# (분리 전 config.sh 기준 384–576)
# =============================================================

# =============================================================
# CLI 독립 세션 정책 — 세션의 수명은 역할·실행 경계(session key)가 정하고, Claude/Codex CLI 는 그 정책을 수행하는 어댑터다.
# 세션 key 는 역할이 아니라 실행 경계 단위다: stage/attempt(designer-design, reviewer-a01, fixer-a01) 또는 Feature(워커: feature-worker —
# scripts/worker-invoke.sh 가 unit·test-fix·worker-fix·review-gap 전부에 같은 세션을 쓰고 worker-session.json 저널로 전제를 고정한다).
# 모델·CLI 이름으로 정책을 추론하지 않는다 — 같은 key 로 두 번째 호출이 오면 그 key 의 '수용된' 세션을 잇고, key 가 바뀌면 fresh 다.
# 예외: 합의 루프의 검증자는 호출마다 고유한 이름(validator-<target>-round-NN-<invocation id>)을 받아 항상 fresh 다 — 수정 뒤 재검증이 이전 판정 대화에 anchoring 되지 않게 한다. 도구가 resume 을 지원해도 의도적으로 재사용하지 않는다.
# 같은 stage/attempt 안의 라운드·재시도만 이어가고(저장소 재탐색 없이 프롬프트 캐시 활용), 다른 stage/attempt 로는
# 대화 문맥을 넘기지 않는다 — 상태 전달은 문서·JSON·체크포인트·지문으로만 한다. 넓은 세션은 turn 마다 누적 문맥을
# 통째로 cache read 하므로 비용이 stage 수에 비례해 커진다. 이전 대화는 사실 참고일 뿐이다 —
# 평가·승인 판정은 항상 코드·문서·JSON·지문으로 하며 세션에 쌓인 발화는 승인 증거가 아니다.
# 저장 형식(두 어댑터, 같은 key 공간):
#   claude: $WORK_DIR/.session-<key>        평문 session UUID. 첫 호출 --session-id <새 UUID>(.new 스테이징), 이후 --resume.
#   codex : $WORK_DIR/.session-<key>.codex.json  세션 원장 {version,key,role,cli,model,effort,contract_version,thread_id,...}.
#           legacy_exec(version 1, backend 필드 없음): thread_id 는 최초 실행 이벤트 JSONL 의 thread.started 에서만 취득한다(--last·최근 세션·역할명 자동 검색 금지).
#           app_server (version 2, backend:"app_server"): thread_id 는 이 호출의 thread/start 응답에서만 취득한다. 호출별 기록은 .session-<key>.codex-turn.json
#           (scripts/codex-app-server.sh). 두 형식은 같은 경로를 쓰되 서로의 원장을 잇지 않는다 — backend 가 다르면 SESSION_BACKEND_MISMATCH 로 멈춘다.
# 확정 시점: 두 어댑터 모두 invocation 이 유효한 결과를 내면 스테이징(.new)까지만 하고, 호출자가 결과를 수용
# (role_session_accept — 스키마·계약·일관성 게이트 통과 뒤)해야 확정된다. 수용되지 않은 세션은 다음 실행에서 잇지 않는다.
# 새 피처 시작 시 $WORK_DIR/.session-* 를 지워야 이전 피처 문맥이 섞이지 않는다(원장·marker 도 같은 glob 에 걸린다).
claude_session_args() {
  local role="$1"
  local id_file="$WORK_DIR/.session-$role"
  if [ -f "$id_file" ]; then
    printf -- '--resume %s' "$(cat "$id_file")"
  else
    local new_id
    new_id="$(uuidgen | tr 'A-Z' 'a-z')"
    printf '%s' "$new_id" > "$id_file.new"
    printf -- '--session-id %s' "$new_id"
  fi
}

# 호출 '성공' 직후에만 세션 ID 확정. 첫 호출이 실패하면 .new 가 확정되지 않아
# 다음 실행이 존재하지 않는 세션을 --resume 하는 사고를 막는다.
claude_session_commit() {
  local id_file="$WORK_DIR/.session-$1"
  if [ -f "$id_file.new" ]; then mv "$id_file.new" "$id_file"; fi
}

# 이 key 의 '확정된' 세션이 있는가 (claude 평문 파일 또는 codex 원장). 다른 스크립트가 "후속 턴인가"를 판단할 때 이 predicate 만 쓴다 —
# 저장 형식(.session-<key> / .session-<key>.codex.json)은 어댑터 내부 사정이다.
session_exists() { # key
  [ -f "$WORK_DIR/.session-$1" ] || [ -f "$WORK_DIR/.session-$1.codex.json" ] || [ -f "$WORK_DIR/.session-$1.native.json" ]
}

# 역할이 결속되는 계약 버전 — 원장의 세션이 '어느 계약 아래의 대화'인지 기록·대조한다. 계약이 바뀌면 이전 세션은 무효다.
role_contract_version() { # ROLE → 버전 문자열(계약 없는 역할은 빈 값)
  case "$1" in
    VALIDATOR) printf '%s' "$VALIDATOR_CONTRACT_VERSION";;
    REVIEWER|FIXER) printf '%s' "$REVIEWER_CONTRACT_VERSION";;   # 리뷰어 계약은 수정자 프롬프트까지 포함한다(config.sh 리뷰어 계약 버전 주석)
    *) printf '';;
  esac
}

# ---------- codex 세션 어댑터 ----------
CODEX_SESSION_LEDGER_VERSION=1
codex_session_ledger() { printf '%s' "$WORK_DIR/.session-$1.codex.json"; }
# resume 중복 전송 방지 marker: resume 호출 직전에 기록하고 호출자가 결과를 수용해야 지운다.
# 호출이 스레드에 메시지를 추가했지만 결과가 수용되지 않은 채 끝나면 marker 가 남아, 다음 실행이 같은 스레드에
# 프롬프트를 무작정 재전송(리뷰 중복·상태 오독)하는 것을 모델 호출 0회로 막는다 — 자동 resume 도 자동 fresh 도 하지 않는다.
codex_resume_marker() { printf '%s' "$WORK_DIR/.session-$1.resume-pending.json"; }
codex_resume_marker_write() { # key invocation_id label
  local marker; marker="$(codex_resume_marker "$1")"
  jq -n --arg key "$1" --arg inv "$2" --arg label "$3" --arg now "$(date '+%FT%T%z')" \
    '{key:$key, invocation_id:$inv, label:$label, recorded_at:$now}' > "$marker.tmp" && mv "$marker.tmp" "$marker"
}

# 설치된 codex 가 resume 계약(exec resume + --json/--output-schema/-o)을 지원하는지 — 미지원이면 스키마·출력 계약을
# 조용히 포기하거나 새 세션으로 대체하지 않고 ENV_ERROR 로 중단한다(CLI 업그레이드가 복구 경로).
# resume 서브커맨드에 --sandbox 플래그가 없는 버전(0.159.x)은 -c sandbox_mode=... 로 같은 샌드박스 의미를 전달한다(플래그가 있으면 둘 다).
CODEX_RESUME_CHECKED=""
CODEX_RESUME_HAS_SANDBOX_FLAG=0
codex_resume_cli_check() {
  local help opt
  [ -z "$CODEX_RESUME_CHECKED" ] || return "$CODEX_RESUME_CHECKED"
  if ! help="$("$CODEX_BIN" exec resume --help 2>&1)"; then
    echo "[FAIL] ENV_ERROR: '$CODEX_BIN exec resume --help' 실패 — 설치된 codex 가 exec resume 을 지원하지 않음. 새 세션으로 자동 전환하지 않는다(CLI 업그레이드 또는 중단)." >&2
    CODEX_RESUME_CHECKED=1; return 1
  fi
  for opt in --json --output-schema --output-last-message; do
    case "$help" in *"$opt"*) ;; *)
      echo "[FAIL] ENV_ERROR: 설치된 codex exec resume 이 '$opt' 를 지원하지 않음 — 스키마/출력 계약 없이 진행하지 않는다." >&2
      CODEX_RESUME_CHECKED=1; return 1;;
    esac
  done
  case "$help" in *"--sandbox"*) CODEX_RESUME_HAS_SANDBOX_FLAG=1;; esac
  CODEX_RESUME_CHECKED=0
}

codex_events_thread_ids() { # events.jsonl → thread.started 의 고유 thread id 목록(한 줄 하나, 깨진 줄 무시)
  jq -R -r 'fromjson? | select(type=="object" and .type=="thread.started") | (.thread_id // empty)' "$1" 2>/dev/null | sort -u
}

# 호출 전 결정: 같은 key 의 '수용된' 원장이 있으면 resume, 없으면 new. 원장이 현재 role 설정(model/effort/계약/프로젝트 루트)과
# 다르면 자동으로 fresh 로 돌아가지 않고 명시적으로 중단한다 — attempt/계약이 바뀌면 호출자가 새 key 를 쓰는 것이 정상 경로다.
# 전역 출력: CODEX_SESSION_MODE(new|resume), CODEX_SESSION_ID.
codex_session_begin() { # ROLE key model effort
  local role="$1" key="$2" model="$3" effort="$4" ledger marker
  ledger="$(codex_session_ledger "$key")"; marker="$(codex_resume_marker "$key")"
  CODEX_SESSION_MODE=new; CODEX_SESSION_ID=""
  if [ -f "$marker" ]; then
    echo "[STOP] SESSION_RESUME_UNCERTAIN: 직전 codex resume 호출($key)의 결과 수용이 확인되지 않음 — 같은 스레드에 프롬프트를 재전송하지 않는다. 이벤트 로그·결과 파일로 중복 여부를 확인한 뒤 $marker 를 삭제하고 재실행(자동 resume·자동 fresh 없음)." >&2
    return 1
  fi
  # 같은 key 가 다른 CLI(claude 평문 세션)에 결속돼 있으면 조용히 fresh codex 세션으로 돌지 않는다 — CLI 변경은 새 key(새 attempt/--new)가 정상 경로.
  if [ -f "$WORK_DIR/.session-$key" ] || [ -f "$WORK_DIR/.session-$key.native.json" ]; then
    echo "[FAIL] SESSION_CLI_MISMATCH: key '$key' 는 claude 세션($WORK_DIR/.session-$key 또는 native Agent 원장 .native.json)에 결속돼 있는데 지금은 codex 로 라우팅된다($role) — 자동 fresh 전환 없이 중단. 설정을 되돌리거나 새 attempt/단계(--new)로 시작." >&2
    return 1
  fi
  # 같은 key 가 Codex App Server backend 의 세션·호출 기록에 결속돼 있으면 codex exec 로 잇지 않는다(반대 방향 검사는 scripts/codex-app-server.sh 의 codex_app_begin).
  if [ -f "$WORK_DIR/.session-$key.codex-turn.json" ] || { [ -f "$ledger" ] && jq -e '.backend=="app_server"' "$ledger" >/dev/null 2>&1; }; then
    echo "[FAIL] SESSION_BACKEND_MISMATCH: key '$key' 는 Codex App Server backend 의 세션(원장 $ledger 또는 호출 기록 $WORK_DIR/.session-$key.codex-turn.json)에 결속돼 있는데 지금은 codex exec(legacy_exec)로 라우팅된다($role) — 자동 전환 없이 중단. config.sh CODEX_BACKEND 를 되돌리거나 새 attempt/단계(--new)로 시작." >&2
    return 1
  fi
  # 이전 invocation 이 스테이징만 하고 수용되지 못한 원장(.new)은 이번 호출의 것이 아니다 — 이번 스테이징이 생략돼도(thread id 미확정)
  # 호출자의 accept 가 옛 .new 를 확정하는 일이 없도록 호출 시작 시 제거한다(스테이징은 invocation 전용).
  rm -f "$ledger.new"
  [ -f "$ledger" ] || return 0
  jq -e --argjson v "$CODEX_SESSION_LEDGER_VERSION" --arg key "$key" --arg role "$role" \
    '.version==$v and .key==$key and .role==$role and .cli=="codex" and (.thread_id|type=="string" and length>0)' "$ledger" >/dev/null 2>&1 \
    || { echo "[FAIL] codex 세션 원장이 깨졌거나 key/role 이 다름: $ledger — 자동 새 세션 전환 없이 중단(원장 확인 후 삭제·재실행)." >&2; return 1; }
  jq -e --arg model "$model" --arg effort "$effort" --arg cv "$(role_contract_version "$role")" --arg root "$PROJECT_ROOT" \
    '.model==$model and .effort==$effort and ((.contract_version // "")|tostring)==$cv and .project_root==$root' "$ledger" >/dev/null 2>&1 \
    || { echo "[FAIL] SESSION_LEDGER_MISMATCH: $key 원장(model/effort/contract/project_root)이 현재 설정과 다름 — 설정을 되돌리거나 새 attempt/단계로 시작한다(자동 resume·자동 fresh 없음)." >&2; return 1; }
  CODEX_SESSION_MODE=resume
  CODEX_SESSION_ID="$(jq -r '.thread_id' "$ledger")"
}

# 신규 세션 스테이징: 이번 invocation 의 이벤트 JSONL 에서 thread.started.thread_id 가 정확히 하나일 때만 원장 .new 를 쓴다.
# 0개·복수는 세션 확정 금지(1) — 호출부는 WARN 후 세션 없이 진행하고, 세션 재사용이 계약인 호출자의 role_session_accept 가 명시적 오류를 낸다.
codex_session_stage() { # ROLE key model effort events_jsonl
  local role="$1" key="$2" model="$3" effort="$4" events="$5" ids n ledger
  ids="$(codex_events_thread_ids "$events")"
  n="$(printf '%s\n' "$ids" | grep -c . || true)"
  if [ "$n" -ne 1 ]; then
    echo "[FAIL] codex 이벤트 JSONL 의 thread.started.thread_id 가 유일하지 않음(개수 $n): $events — 세션 확정 금지." >&2
    return 1
  fi
  ledger="$(codex_session_ledger "$key")"
  jq -n --argjson v "$CODEX_SESSION_LEDGER_VERSION" --arg key "$key" --arg role "$role" --arg model "$model" --arg effort "$effort" \
    --arg cv "$(role_contract_version "$role")" --arg root "$PROJECT_ROOT" --arg tid "$ids" --arg now "$(date '+%FT%T%z')" \
    '{version:$v, key:$key, role:$role, cli:"codex", model:$model, effort:$effort, contract_version:$cv, project_root:$root,
      thread_id:$tid, created_at:$now, last_accepted_label:"", last_accepted_at:""}' \
    > "$ledger.new.tmp" && mv "$ledger.new.tmp" "$ledger.new"
}

# 재개 호출 대조: 이번 invocation 의 이벤트에 thread id 가 보이면 원장의 ID 와 같아야 한다(복수·불일치 1). 없으면 통과(확인 가능할 때만 대조).
codex_session_check_resumed() { # key events_jsonl
  local ids n
  ids="$(codex_events_thread_ids "$2")"
  n="$(printf '%s\n' "$ids" | grep -c . || true)"
  [ "$n" -eq 0 ] && return 0
  [ "$n" -eq 1 ] && [ "$ids" = "$(jq -r '.thread_id' "$(codex_session_ledger "$1")")" ]
}

# claude 어댑터 진입 가드: 같은 key 가 codex 원장에 결속돼 있으면 조용히 fresh claude 세션을 만들지 않는다(SESSION_CLI_MISMATCH).
# codex 쪽 대칭 검사는 codex_session_begin 안에 있다. 거부된 스테이징(.new)·pending marker 는 수용된 세션이 아니므로 보지 않는다
# (marker 는 확정 원장이 있을 때만 생기므로 원장 검사가 함께 덮는다).
claude_session_cli_guard() { # ROLE key
  local ledger; ledger="$(codex_session_ledger "$2")"
  if [ -f "$WORK_DIR/.session-$2.native.json" ]; then
    echo "[FAIL] SESSION_CLI_MISMATCH: key '$2' 는 native Agent 세션($WORK_DIR/.session-$2.native.json)에 결속돼 있는데 지금은 claude CLI(legacy_cli)로 라우팅된다($1) — 자동 fresh 전환 없이 중단. 설정을 되돌리거나 새 attempt/단계(--new)로 시작." >&2
    return 1
  fi
  [ -f "$ledger" ] || return 0
  echo "[FAIL] SESSION_CLI_MISMATCH: key '$2' 는 codex 세션 원장($ledger)에 결속돼 있는데 지금은 claude 로 라우팅된다($1) — 자동 fresh 전환 없이 중단. 설정을 되돌리거나 새 attempt/단계(--new)로 시작." >&2
  return 1
}

# 호출자가 결과를 수용한 뒤에만 세션 확정 — claude 는 .new session id 커밋, codex 는 원장 .new 확정 + resume marker 해제.
# 재사용하지 않는 역할(합의 루프 검증자)은 호출마다 고유 key 를 쓰고 accept 를 부르지 않는다 — 스테이징은 커밋되지 않고 다음 key 와 만나지도 않는다.
role_session_accept() { # ROLE key [label]
  local role="$1" key="$2" label="${3:-}" cli ledger
  cli="$(role_cli "$role")" || return 1
  # native Agent: typed 원장(.session-<key>.native.json)의 .new 를 확정한다 — 검증 계약(게이트 통과 뒤에만 accept)은 세 backend 공통이다.
  if [ "$(role_backend "$role")" = claude_native ]; then native_session_accept "$role" "$key" "$label"; return $?; fi
  # Codex App Server: 원장 .new 확정 + 호출 기록의 수용 표시(scripts/codex-app-server.sh). 불명 상태의 호출 기록은 수용으로도 풀리지 않는다 — 원장을 건드리지 않고 실패한다.
  if [ "$(role_backend "$role")" = codex_app_server ]; then codex_app_session_accept "$role" "$key" "$label"; return $?; fi
  case "$cli" in
    claude) claude_session_commit "$key" ;;
    codex)
      ledger="$(codex_session_ledger "$key")"
      if [ -f "$ledger.new" ]; then mv "$ledger.new" "$ledger"; fi
      # accept 를 부른다는 것은 이 key 의 세션 재사용이 계약이라는 뜻이다 — 확정할 세션이 없으면(첫 호출의 thread.started 미확정)
      # 조용히 넘어가 다음 라운드가 소리 없이 fresh 로 돌지 않게 명시적 오류를 낸다(GOAL: 세션 확정 금지 + 명시적 오류).
      [ -f "$ledger" ] || { echo "[FAIL] $key: 확정할 codex 세션이 없음 — 이번 호출의 이벤트 JSONL 에서 thread.started.thread_id 를 얻지 못했다." >&2; return 1; }
      jq --arg label "$label" --arg now "$(date '+%FT%T%z')" '.last_accepted_label=$label | .last_accepted_at=$now' \
        "$ledger" > "$ledger.tmp" && mv "$ledger.tmp" "$ledger"
      rm -f "$(codex_resume_marker "$key")"
      ;;
  esac
}
