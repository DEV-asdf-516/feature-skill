#!/usr/bin/env bash
# =============================================================
# Codex App Server backend — Shell 쪽 연결부 (로더(scripts/lib/bootstrap.sh)가 source 한다)
# 파일 경로: .claude/skills/feature/scripts/codex-app-server.sh
#
# Codex 모델 역할(gpt-*/o*/codex*)을 `codex exec` 대신 하네스가 직접 띄운 `codex app-server`(stdio JSON-RPC)로 실행한다.
# 프로토콜 전송·이벤트 수집은 scripts/codex-app-server.mjs(Node.js 18+, 외부 패키지 없음)가 하고, 이 파일은
#   · 모델 0회 사전 검사(설치된 codex 의 프로토콜 스키마에서 필요한 메서드·필드 확인)
#   · 호출 전 기록(turn record)과 재전송 차단 게이트
#   · 세션 원장(.session-<key>.codex.json, backend=app_server) 스테이징·확정
#   · 사용량 행(usage.jsonl) 기록
# 을 맡는다. run_readonly_json_role / run_edit_role 의 인자·출력 경로·종료 의미는 그대로다(scripts/lib/backend/router.sh 가 backend 로 위임한다).
#
# native Agent 인계(exit 42/43)와 다르다: Shell 이 자식 프로세스를 직접 띄울 수 있으므로 2-pass 가 없다. 대신 요청·응답·수용 사이를 파일로 남긴다.
#
# 호출 기록(turn record): $WORK_DIR/.session-<key>.codex-turn.json — key 마다 '가장 최근 호출' 하나. 지난 기록은 $WORK_DIR/codex-app-server/<key>/ 로 옮긴다.
#   PREPARED          Shell 이 전송 의도를 기록했다(모델 0회)
#   THREAD_READY      thread/start 또는 thread/resume 성공, turn/start 미전송(모델 0회)
#   SEND_UNCONFIRMED  turn/start 를 쓰기 직전에 기록 — 여기서부터는 turn 이 실행됐을 수 있다
#   RUNNING           turn/start 응답 수신(turn id 확정)
#   RESULT_READY      turn/completed(status=completed) + 이 turn 의 최종 agentMessage 를 invocation 전용 파일에 썼다
#   CONSUMED          Shell 이 결과를 호출자의 경로($out)로 넘겼다(호출자 게이트는 아직)
#   ACCEPTED          호출자가 role_session_accept 로 수용했다
#   TURN_FAILED       turn 이 failed/interrupted 로 끝났다(결과 없음이 확정)
#   REJECTED          turn 은 끝났지만 결과를 쓸 수 없다(최종 메시지 없음·JSON 아님·승인 요청·모델 reroute)
#   FAILED_BEFORE_SEND turn/start 를 보내기 전에 실패했다(모델 0회가 확정)
#   UNKNOWN           전송 뒤 서버 종료·timeout·스트림 손상 — turn 의 실행·완료 여부를 모른다
# 재실행 판정(모델 호출 전):
#   SEND_UNCONFIRMED · RUNNING · UNKNOWN  → CODEX_TURN_UNCERTAIN 으로 멈춘다(새 turn·fresh thread 없음). status / reconcile 로 확인한다.
#   RESULT_READY                         → 읽기 전용 역할이고 입력 지문이 같으면 새 turn 없이 그 결과를 쓴다. 그 외는 CODEX_TURN_RESULT_UNCONSUMED 로 멈춘다.
#   CONSUMED · TURN_FAILED · REJECTED    → 읽기 전용 역할의 재개(resume) 호출이었다면 SESSION_RESUME_UNCERTAIN(수용되지 않은 응답 위에 같은 thread 로 다시 보내지 않는다).
#   PREPARED · THREAD_READY · FAILED_BEFORE_SEND · ACCEPTED → 진행.
#
# 직접 실행(조회·수리 — 모델 호출 0회):
#   bash .claude/skills/feature/scripts/codex-app-server.sh status [key]
#   bash .claude/skills/feature/scripts/codex-app-server.sh reconcile <key>
#   bash .claude/skills/feature/scripts/codex-app-server.sh discard <key>     사용자가 확인을 마친 불명 기록을 보관 디렉터리로 옮긴다(자동으로 부르지 않는다)
#   bash .claude/skills/feature/scripts/codex-app-server.sh preflight
#   bash .claude/skills/feature/scripts/codex-app-server.sh hooks             편집 역할의 필수 훅 게이트를 이 작업 루트에 대해 판정만 한다(hooks/list — thread·turn 없음, 설정 변경 없음)
#                                                                             가드 스크립트는 실행하지 않는다(지문 대조만)
#   기록이 속한 프로젝트·피처 worktree 루트에서 실행한다(또는 FEATURE_PROJECT_ROOT 지정). 상대·절대·심볼릭 링크 경로 어느 것으로 불러도 같다.
# =============================================================

CODEX_APP_LEDGER_VERSION=2
CODEX_APP_RECORD_VERSION=1
CODEX_APP_PREFLIGHT_VERSION=3   # 사전 검사 캐시의 형식·판정 기준. 올리면 예전 캐시(하위 Agent 금지 검증 능력·hooks/list 지원 여부 미기록 포함)를 다시 만든다
CODEX_APP_NODE_MIN_MAJOR=18
# 워커 자식 프로세스에만 붙이는 설정 덮어쓰기(-c). 사용자 전역 설정(~/.codex/config.toml)은 읽기만 하고 바꾸지 않는다.
#   agents.enabled=false            하위 Agent 도구 금지
#   features.multi_agent_v2=false   켜져 있으면 agents.enabled=false 를 무시하는 경로 — 이 프로세스에서만 끈다
#   features.multi_agent=false      V1 fallback 경로
# 전달만으로 믿지 않는다: 런타임이 같은 프로세스에서 유효 설정(config/read)과 기능 상태(experimentalFeature/list)를 읽어
# 셋 모두 false 인 것을 확인한 뒤에만 turn/start 를 보낸다(scripts/codex-app-server.mjs verifyAgentsPolicy). 확인하지 못하면 모델 호출 전에 멈춘다.
CODEX_APP_WORKER_POLICY_OVERRIDES="agents.enabled=false features.multi_agent_v2=false features.multi_agent=false"
# 편집 역할(워커·수정자·디자이너)의 필수 훅 — 작업 보호(커밋·푸시·index 조작·삭제 차단)를 맡는 프로젝트 훅이다. 읽기 전용 역할에는 적용하지 않는다.
# 파일이 있다는 것만으로는 훅이 돈다고 볼 수 없다: codex 는 신뢰하지 않은 프로젝트의 훅을 로드하지 않고, 프로젝트를 신뢰했어도 검토되지 않은 훅 정의는 돌리지 않는다.
# 그래서 런타임이 그 호출의 app-server 프로세스에서 hooks/list 를 읽어 등록·활성·신뢰 상태를 확인한 뒤에만 turn/start 를 보낸다
# (scripts/codex-app-server.mjs verifyRequiredHook — thread 를 만들기 전과 thread 를 연 뒤). 확인하지 못하면 FAILED_BEFORE_SEND(모델 0회)다.
# 하네스는 판정만 한다: ~/.codex/config.toml 수정·trust 승인·훅 우회 옵션은 쓰지 않는다. 신뢰 설정은 사용자가 관리한다.
CODEX_APP_HOOK_GATE_VERSION=3                             # 런타임의 HOOK_GATE_VERSION 과 같아야 한다(게이트 없는 런타임과 섞인 설치를 호출 전에 가린다)
CODEX_APP_REQUIRED_HOOK_EVENT="preToolUse"
CODEX_APP_REQUIRED_HOOK_SCRIPT=".codex/hooks/worker_guard.sh"
CODEX_APP_REQUIRED_HOOK_SOURCE=".codex/hooks.json"
CODEX_APP_REQUIRED_HOOK_COMMAND="bash .codex/hooks/worker_guard.sh"   # hooks.json 의 command 와 글자 그대로 같아야 한다(부분 일치·matcher 가 붙은 훅은 통과가 아니다)
CODEX_APP_REQUIRED_HOOK_CONTRACT="WORKER_GUARD_CONTRACT=3"   # 가드 스크립트가 선언해야 하는 계약 세대 줄. 1 세대(줄 없음)는 git 전역 옵션·섞인 삭제·apply_patch 삭제·해석 실패 시 허용으로,
                                                             # 2 세대는 허용 접두사 뒤의 변수·글로브 대상, 프로젝트 밖으로의 이동(mv · apply_patch 의 Move to), 가드 파일 수정으로 우회된다.
                                                             # 선언만으로는 통과가 아니다 — 런타임이 파일 지문을 아래 검토된 지문 목록과 대조한다.
# 가드 스크립트의 검토된 지문(sha256). 게이트는 가드를 실행해 보지 않는다 — 훅 신뢰가 확인되기 전에 sandbox 밖에서 작업 루트의 스크립트를 돌리면
# 그 파일이 변조돼 있을 때 조회 명령(hooks)만으로 임의 코드가 사용자 권한으로 실행된다. 대신 본문의 지문을 대조한다(읽기만 한다).
#   CODEX_APP_REQUIRED_HOOK_SHA256   : 이 스킬이 배포하는 .codex/hooks/worker_guard.sh 의 지문. 가드를 고치면 같이 고친다(tests/smoke-codex-app-server.sh G3 가 어긋남을 잡는다).
#   CODEX_APP_GUARD_REVIEWED_SHA256  : 프로젝트에 맞게 고쳐 쓴 가드를 사용자가 직접 검토한 뒤 등록하는 지문(공백으로 여러 개). config.sh 의 사용자 설정 영역이나 환경 변수로 준다.
#                                      이 파일은 그 값을 덮어쓰지 않는다. 하네스·오케스트레이터가 대신 등록하지 않는다 — 등록은 "이 본문을 읽고 승인했다"는 사용자의 표시다.
# 가드의 판정 회귀는 tests/smoke-worker-guard.sh(무과금, 훅 입력 JSON 을 직접 넣는다)가 본다.
CODEX_APP_REQUIRED_HOOK_SHA256="5a125676316fe4a1fb0c86f02403e09e5c67bad602f19e8023f06f28e614e4da"
# 대량 델타 알림은 결과가 아니다 — 서버가 지원하는 것만 골라 수신을 끈다(사전 검사가 스키마와 교집합을 낸다).
CODEX_APP_OPT_OUT_CANDIDATES="item/agentMessage/delta item/plan/delta item/reasoning/summaryTextDelta item/reasoning/summaryPartAdded item/reasoning/textDelta item/commandExecution/outputDelta item/fileChange/outputDelta item/fileChange/patchUpdated turn/diff/updated"

codex_app_node_bin() { printf '%s' "${CODEX_APP_SERVER_NODE_BIN:-node}"; }
codex_app_runtime() { printf '%s' "$FEATURE_SKILL_DIR/scripts/codex-app-server.mjs"; }
codex_app_turn_record() { printf '%s' "$WORK_DIR/.session-$1.codex-turn.json"; }
codex_app_archive_dir() { printf '%s' "$WORK_DIR/codex-app-server/$1"; }
codex_app_preflight_cache() { printf '%s' "$WORK_DIR/.codex-app-server-preflight.json"; }
codex_app_sha_file() { if [ -n "$1" ] && [ -f "$1" ]; then sha256_stdin < "$1"; else printf 'none'; fi; }
codex_app_timeout_ms() { # 변수이름 기본값(초) → ms (정수가 아니면 1)
  local v="${!1:-$2}"
  case "$v" in ''|*[!0-9]*) echo "[FAIL] ENV_ERROR: $1='$v' — 0 이상의 정수(초)여야 한다" >&2; return 1;; esac
  printf '%s' "$((v * 1000))"
}

# ---------- 사전 검사 (모델 0회) ----------
# 설치된 codex 가 내는 프로토콜 스키마에서 이 런타임이 쓰는 메서드·필드를 확인한다. 특정 버전의 필드를 가정하지 않고, 없으면 실행 전에 멈춘다(무스키마·exec 대체 없음).
# 결과는 codex 버전 문자열에 묶어 $WORK_DIR 에 캐시한다(같은 버전이면 스키마를 다시 만들지 않는다).
CODEX_APP_PREFLIGHT_DONE=""
codex_app_preflight() {
  local node codex_version cache tmp methods notes missing="" m f opt="" has_reconcile=true has_usage=true has_policy=true has_hooks=true
  [ -z "$CODEX_APP_PREFLIGHT_DONE" ] || return "$CODEX_APP_PREFLIGHT_DONE"
  CODEX_APP_PREFLIGHT_DONE=1
  node="$(codex_app_node_bin)"
  command -v "$node" >/dev/null 2>&1 \
    || { echo "[FAIL] ENV_ERROR: CODEX_APP_SERVER_NODE_MISSING — '$node' 를 찾을 수 없다. Codex App Server backend 는 Node.js ${CODEX_APP_NODE_MIN_MAJOR}+ 가 필요하다(config.sh CODEX_APP_SERVER_NODE_BIN). codex exec 로 대체하지 않는다." >&2; return 1; }
  "$node" -e "process.exit(Number(process.versions.node.split('.')[0]) >= $CODEX_APP_NODE_MIN_MAJOR ? 0 : 1)" 2>/dev/null \
    || { echo "[FAIL] ENV_ERROR: CODEX_APP_SERVER_NODE_TOO_OLD — $("$node" --version 2>/dev/null) 는 지원하지 않는다(Node.js ${CODEX_APP_NODE_MIN_MAJOR}+ 필요)." >&2; return 1; }
  [ -f "$(codex_app_runtime)" ] \
    || { echo "[FAIL] ENV_ERROR: Codex App Server 런타임 없음: $(codex_app_runtime) — scripts/ 가 서로 다른 버전이다(혼합 설치). install.sh 를 다시 실행하라" >&2; return 1; }
  command -v "$CODEX_BIN" >/dev/null 2>&1 || { echo "[FAIL] ENV_ERROR: '$CODEX_BIN' 미설치 — Codex App Server backend 는 로컬 codex 바이너리(\`codex app-server\`)를 그대로 쓴다." >&2; return 1; }
  codex_version="$("$CODEX_BIN" --version 2>/dev/null | head -1)"
  [ -n "$codex_version" ] || { echo "[FAIL] ENV_ERROR: '$CODEX_BIN --version' 이 버전을 내지 않는다 — 프로토콜 호환성을 확인할 수 없다." >&2; return 1; }
  cache="$(codex_app_preflight_cache)"
  mkdir -p "$WORK_DIR" || return 1
  if [ -f "$cache" ] && jq -e --arg b "$CODEX_BIN" --arg v "$codex_version" --argjson rv "$CODEX_APP_RECORD_VERSION" --argjson pv "$CODEX_APP_PREFLIGHT_VERSION" \
      '.record_version==$rv and .preflight_version==$pv and .codex_bin==$b and .codex_version==$v and .ok==true' "$cache" >/dev/null 2>&1; then
    CODEX_APP_PREFLIGHT_DONE=0; return 0
  fi
  "$CODEX_BIN" app-server --help >/dev/null 2>&1 \
    || { echo "[FAIL] ENV_ERROR: CODEX_APP_SERVER_UNSUPPORTED — '$CODEX_BIN app-server --help' 실패($codex_version). 이 codex 는 app-server 를 지원하지 않는다. codex 를 업그레이드하거나, 진행 중인 예전 피처를 마치는 용도라면 config.sh CODEX_BACKEND=\"legacy_exec\" 를 명시하라(자동 대체 없음)." >&2; return 1; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/feature-codex-schema-XXXXXX")" || return 1
  if ! "$CODEX_BIN" app-server generate-json-schema --out "$tmp" >/dev/null 2>"$tmp/.err"; then
    echo "[FAIL] ENV_ERROR: CODEX_APP_SERVER_SCHEMA_UNAVAILABLE — '$CODEX_BIN app-server generate-json-schema' 실패($codex_version): $(head -c 300 "$tmp/.err")" >&2
    rm -rf "$tmp"; return 1
  fi
  methods="$(jq -r '.oneOf[]?.properties.method.enum[]?' "$tmp/ClientRequest.json" 2>/dev/null)"
  notes="$(jq -r '.oneOf[]?.properties.method.enum[]?' "$tmp/ServerNotification.json" 2>/dev/null)"
  for m in initialize thread/start thread/resume turn/start; do
    printf '%s\n' "$methods" | grep -qxF "$m" || missing="$missing request:$m"
  done
  for m in turn/completed item/completed; do
    printf '%s\n' "$notes" | grep -qxF "$m" || missing="$missing notification:$m"
  done
  for f in "v2/TurnStartParams.json:outputSchema" "v2/TurnStartParams.json:effort" "v2/TurnStartParams.json:model" "v2/TurnStartParams.json:clientUserMessageId" \
           "v2/ThreadStartParams.json:ephemeral" "v2/ThreadStartParams.json:sandbox" "v2/ThreadStartParams.json:approvalPolicy" "v2/ThreadStartParams.json:cwd" \
           "v2/ThreadResumeParams.json:excludeTurns" "v2/ThreadResumeParams.json:sandbox"; do
    jq -e --arg k "${f#*:}" '.properties | has($k)' "$tmp/${f%%:*}" >/dev/null 2>&1 || missing="$missing field:${f%%:*}#${f#*:}"
  done
  for m in thread/read thread/turns/list thread/items/list; do printf '%s\n' "$methods" | grep -qxF "$m" || has_reconcile=false; done
  printf '%s\n' "$notes" | grep -qxF "thread/tokenUsage/updated" || has_usage=false
  for m in config/read experimentalFeature/list; do printf '%s\n' "$methods" | grep -qxF "$m" || has_policy=false; done
  printf '%s\n' "$methods" | grep -qxF "hooks/list" || has_hooks=false
  for m in $CODEX_APP_OPT_OUT_CANDIDATES; do ! printf '%s\n' "$notes" | grep -qxF "$m" || opt="$opt $m"; done
  rm -rf "$tmp"
  if [ -n "$missing" ]; then
    echo "[FAIL] ENV_ERROR: CODEX_APP_SERVER_PROTOCOL_UNSUPPORTED — 설치된 codex($codex_version)의 app-server 프로토콜에 이 런타임이 요구하는 항목이 없다:$missing. 스키마 없는 실행이나 codex exec 로 대체하지 않는다 — codex 를 업그레이드하라." >&2
    return 1
  fi
  jq -n --argjson rv "$CODEX_APP_RECORD_VERSION" --argjson pv "$CODEX_APP_PREFLIGHT_VERSION" --argjson policy "$has_policy" --argjson hooks "$has_hooks" --arg b "$CODEX_BIN" --arg v "$codex_version" --arg nv "$("$node" --version 2>/dev/null)" --arg opt "$opt" \
    --argjson rec "$has_reconcile" --argjson usage "$has_usage" --arg now "$(date '+%FT%T%z')" \
    '{record_version:$rv, preflight_version:$pv, ok:true, codex_bin:$b, codex_version:$v, node_version:$nv, opt_out_notifications:($opt | split(" ") | map(select(length>0))),
      capabilities:{reconcile:$rec, token_usage:$usage, agents_policy_verify:$policy, hooks_list:$hooks}, agents_policy:null, checked_at:$now}' > "$cache.tmp" && mv "$cache.tmp" "$cache" || return 1
  [ "$has_usage" = true ] || echo "[WARN] 설치된 codex($codex_version)는 thread/tokenUsage/updated 알림이 없다 — 사용량은 unknown 으로 기록된다(0 이 아니다)." >&2
  CODEX_APP_PREFLIGHT_DONE=0
}
# 워커의 하위 Agent 금지 — 호출 전(모델 0회) 두 가지를 본다. 어느 것도 통과하지 못하면 워커를 띄우지 않는다.
#   ① 설치된 codex 의 app-server 가 유효 설정·기능 상태 조회(config/read · experimentalFeature/list)를 지원하는가.
#      지원하지 않으면 금지가 실제로 적용됐는지 확인할 방법이 없다 → CODEX_APP_SERVER_AGENTS_POLICY_UNVERIFIABLE.
#   ② 덮어쓰기 키(CODEX_APP_WORKER_POLICY_OVERRIDES)를 설치된 codex 가 설정 키로 받는가(--strict-config --print-startup-config).
#      키가 거부되면 CODEX_APP_SERVER_AGENTS_POLICY_UNSUPPORTED. 사용자 config.toml 자체가 strict 검사에 걸려 키만 따로 가릴 수 없는 경우는
#      여기서 통과시키되 판정을 미루는 것이지 금지를 건너뛰는 것이 아니다 — 실제 적용 여부는 런타임이 워커 프로세스 안에서 유효 값을 읽어 확정하고,
#      읽지 못하거나 false 가 아니면 turn/start 전에 멈춘다(FAILED_BEFORE_SEND — CODEX_APP_SERVER_AGENTS_POLICY_NOT_ENFORCED / _UNVERIFIED).
codex_app_agents_policy_check() {
  local cache verdict o args=(); cache="$(codex_app_preflight_cache)"
  jq -e '.capabilities.agents_policy_verify==true' "$cache" >/dev/null 2>&1 \
    || { echo "[FAIL] ENV_ERROR: CODEX_APP_SERVER_AGENTS_POLICY_UNVERIFIABLE — 설치된 codex 의 app-server 에 config/read · experimentalFeature/list 가 없어 워커의 하위 Agent 금지가 실제로 적용됐는지 확인할 수 없다. 확인 없이 워커를 실행하지 않는다(codex 업그레이드 또는 중단)." >&2; return 1; }
  verdict="$(jq -r '.agents_policy // ""' "$cache" 2>/dev/null)"
  if [ -z "$verdict" ]; then
    for o in $CODEX_APP_WORKER_POLICY_OVERRIDES; do args+=(-c "$o"); done
    if ! "$CODEX_BIN" app-server --strict-config --print-startup-config >/dev/null 2>&1; then verdict=deferred
    elif "$CODEX_BIN" app-server "${args[@]}" --strict-config --print-startup-config >/dev/null 2>&1; then verdict=verified
    else verdict=unsupported; fi
    jq --arg v "$verdict" '.agents_policy=$v' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache" || return 1
  fi
  case "$verdict" in
    verified) return 0 ;;
    deferred) echo "[INFO] 워커 하위 Agent 금지의 설정 키 사전 확인을 건너뛴다('$CODEX_BIN app-server --strict-config --print-startup-config' 가 사용자 설정에서 실패) — 적용 여부는 워커 프로세스의 유효 설정으로 확정하고, 확인되지 않으면 turn/start 전에 멈춘다." >&2; return 0 ;;
    *) echo "[FAIL] ENV_ERROR: CODEX_APP_SERVER_AGENTS_POLICY_UNSUPPORTED — 설치된 codex 가 워커의 하위 Agent 금지 설정($CODEX_APP_WORKER_POLICY_OVERRIDES)을 설정 키로 받지 않는다. 금지 없이 워커를 실행하지 않는다(codex 업그레이드 또는 중단)." >&2; return 1 ;;
  esac
}

# 편집 역할의 필수 훅 사양(JSON) — 호출 기록에 넣어 런타임이 대조한다.
#   source_paths: 그 훅 정의가 나와야 하는 hooks.json. 작업 루트의 것과, 작업 루트가 linked git worktree 면 원본 저장소(main worktree)의 것.
#     codex 는 linked worktree 에서 프로젝트 신뢰를 원본 저장소에서 물려받고, 훅 정의도 원본의 hooks.json 을 sourcePath·신뢰 key 로 돌려준다(codex-cli 0.169.1 관측).
#     command 는 상대 경로라 실제로 도는 스크립트는 작업 루트의 사본이다 — 그 파일이 있는지는 런타임이 따로 본다.
#   list_supported: 설치된 codex 에 hooks/list 가 있는가(사전 검사 캐시). 없으면 런타임이 서버를 띄우기 전에 멈춘다.
codex_app_main_worktree_root() { # → 원본 저장소 루트(= 공용 .git 디렉터리의 부모). 판정할 수 없으면 1
  local c; c="$(git -C "$PROJECT_ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$c" in /*) ;; *) c="$PROJECT_ROOT/$c" ;; esac
  c="$(cd "$c" 2>/dev/null && pwd -P)" || return 1
  [ "$(basename "$c")" = .git ] || return 1
  dirname "$c"
}
codex_app_required_hook_json() {
  local main="" supported=false
  main="$(codex_app_main_worktree_root)" || main=""
  jq -e '.capabilities.hooks_list==true' "$(codex_app_preflight_cache)" >/dev/null 2>&1 && supported=true
  jq -nc --arg ev "$CODEX_APP_REQUIRED_HOOK_EVENT" --arg script "$CODEX_APP_REQUIRED_HOOK_SCRIPT" --arg src "$CODEX_APP_REQUIRED_HOOK_SOURCE" \
    --arg root "$PROJECT_ROOT" --arg main "$main" --argjson sup "$supported" --arg contract "$CODEX_APP_REQUIRED_HOOK_CONTRACT" --arg cmd "$CODEX_APP_REQUIRED_HOOK_COMMAND" \
    --arg shas "$CODEX_APP_REQUIRED_HOOK_SHA256 ${CODEX_APP_GUARD_REVIEWED_SHA256:-}" \
    '{event:$ev, script:$script, command:$cmd, script_contract:$contract,
      reviewed_sha256:($shas | ascii_downcase | [scan("[^[:space:]]+")] | map(select(test("^[0-9a-f]{64}$"))) | unique), source_paths:([$root + "/" + $src] + (if $main != "" then [$main + "/" + $src] else [] end) | unique), list_supported:$sup}'
}
# 필수 훅 게이트로 멈췄을 때의 안내 — 판정과 사용자가 할 일만 적는다(하네스는 신뢰 설정을 바꾸지 않는다).
codex_app_hook_gate_help() { # record
  local reason; reason="$(codex_app_record_field "$1" '.hook_gate.reason // ""')"
  echo "       필수 훅: $CODEX_APP_REQUIRED_HOOK_EVENT 의 $CODEX_APP_REQUIRED_HOOK_SCRIPT (정의: $CODEX_APP_REQUIRED_HOOK_SOURCE) — 편집 역할(워커·수정자·디자이너)은 이 훅이 등록·활성·신뢰 상태일 때만 실행한다. 판정: ${reason:-?}" >&2
  case "$reason" in
    missing|script_missing|source_mismatch)
      echo "       확인할 것: 작업 루트($PROJECT_ROOT)에 $CODEX_APP_REQUIRED_HOOK_SOURCE · $CODEX_APP_REQUIRED_HOOK_SCRIPT 가 있는지, 그 프로젝트가 codex 에 trusted 로 등록돼 있는지(미신뢰 프로젝트의 훅은 목록에 나오지 않는다)." >&2 ;;
    script_outdated)
      echo "       확인할 것: 작업 루트의 $CODEX_APP_REQUIRED_HOOK_SCRIPT 가 옛 세대다($CODEX_APP_REQUIRED_HOOK_CONTRACT 선언 없음). install.sh 는 기존 가드를 덮어쓰지 않고 새 버전을 같은 경로의 .new 로 둔다 — 그 파일을 확인해 직접 병합한다. codex 의 훅 신뢰는 hooks.json 의 정의에만 걸린다(스크립트 본문이 바뀌어도 신뢰 상태는 그대로다) — 병합한 본문은 직접 검토한다." >&2 ;;
    script_unreviewed)
      echo "       확인할 것: 작업 루트의 $CODEX_APP_REQUIRED_HOOK_SCRIPT 본문이 배포본과 다르고 등록된 지문에도 없다(현재 지문: $(codex_app_sha_file "$PROJECT_ROOT/$CODEX_APP_REQUIRED_HOOK_SCRIPT")). 게이트는 이 스크립트를 실행하지 않고 지문만 대조한다." >&2
      echo "         · 고친 적이 없다면: 같은 경로의 .new(install.sh 가 둔 새 배포본) 또는 스킬 원본 저장소의 가드와 비교해 병합한다." >&2
      echo "         · 프로젝트에 맞게 고쳐 쓴 가드라면: 본문을 직접 검토한 뒤 그 지문을 config.sh 의 CODEX_APP_GUARD_REVIEWED_SHA256 에 등록한다(공백으로 여러 개). 판정 회귀는 tests/smoke-worker-guard.sh 로 본다." >&2
      echo "         · 하네스·오케스트레이터는 지문을 대신 등록하지 않는다." >&2 ;;
    command_mismatch)
      echo "       확인할 것: $CODEX_APP_REQUIRED_HOOK_SOURCE 의 그 훅 command 가 '$CODEX_APP_REQUIRED_HOOK_COMMAND' 와 글자 그대로 같아야 한다(뒤에 다른 명령을 붙이거나 종료 코드를 바꾸는 형태는 통과가 아니다). 정의를 고치면 codex 에서 다시 검토·신뢰해야 한다." >&2 ;;
    matcher_scoped)
      echo "       확인할 것: $CODEX_APP_REQUIRED_HOOK_SOURCE 의 그 훅 항목에서 matcher 를 뺀다(matcher 가 있으면 일부 도구 호출에만 걸린다). 정의를 고치면 codex 에서 다시 검토·신뢰해야 한다." >&2 ;;
    untrusted|modified|disabled|async|trust_unknown)
      echo "       확인할 것: codex 에서 그 훅 정의를 직접 검토해 신뢰·활성 상태로 둔다(codex 는 검토되지 않았거나 신뢰한 뒤 바뀐 훅을 돌리지 않는다). linked worktree 의 훅 정의·신뢰 key 는 원본 저장소의 hooks.json 이다." >&2 ;;
    list_unsupported)
      echo "       확인할 것: codex 를 hooks/list 가 있는 버전으로 올린다." >&2 ;;
  esac
  echo "       다시 판정(모델 호출 0회 · thread 없음 · 설정 변경 없음): $(codex_app_cli_hint hooks "")" >&2
  echo "       하네스는 ~/.codex/config.toml 을 고치거나 trust 를 대신 승인하지 않고, 훅을 우회하는 옵션으로 실행하지도 않는다. CODEX_BACKEND 를 바꿔 우회하지 않는다." >&2
}

# ---------- 기록 갱신 (Shell 쪽 전이: CONSUMED / ACCEPTED / DISCARDED) ----------
codex_app_record_field() { jq -r "$2" "$1" 2>/dev/null; } # record jq-filter
codex_app_set_state() { # record state [jq-추가식]
  local extra="${3:-.}"
  jq --arg s "$2" --arg now "$(date -u '+%FT%TZ')" "(.state=\$s | .updated_at=\$now | .history += [{state:\$s, at:\$now}]) | $extra" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
codex_app_archive_record() { # key record → 보관 경로로 옮긴다(삭제하지 않는다)
  local dir inv dest; dir="$(codex_app_archive_dir "$1")"; inv="$(codex_app_record_field "$2" '.invocation_id // "unknown"')"
  mkdir -p "$dir" || return 1
  dest="$dir/$inv.json"; [ ! -e "$dest" ] || dest="$dir/$inv.$(date '+%s').json"
  mv "$2" "$dest"
}
# 단독 명령의 표기. 기록은 프로젝트 루트(피처 worktree)마다 따로이고 경로($WORK_DIR 상대)는 현재 디렉터리 기준이다 — 메인 세션의 cwd 는 보통 원본 저장소이므로 cd 를 함께 적는다.
codex_app_cli_hint() { # verb key
  printf 'cd %q && bash %q %s %s' "$PROJECT_ROOT" "$FEATURE_SKILL_DIR/scripts/codex-app-server.sh" "$1" "$2"
}
codex_app_uncertain_help() { # key record
  echo "       확인: $(codex_app_cli_hint status "$1")      (기록·thread id·turn id·원본 로그 경로)" >&2
  echo "             $(codex_app_cli_hint reconcile "$1")   (조회 전용 — 저장된 thread 에서 완료 여부를 확인하고, 증거가 있으면 기존 결과를 복구한다. 새 turn 없음)" >&2
  echo "       확인을 마친 뒤에만: $(codex_app_cli_hint discard "$1")  (기록을 $(codex_app_archive_dir "$1")/ 로 옮긴다 — 그 뒤의 재실행은 새 turn 을 보낸다)" >&2
  echo "       기록: $2" >&2
}
# 편집 역할(워커·디자이너·수정자)의 호출이 '완료 여부 불명'으로 남아 있으면 멈춘다 — 호출자(합의 루프·리뷰 루프)가 다음 검증자·리뷰어로 넘기기 전과 재실행 진입 때 부른다.
# 완료가 확인된 실패(TURN_FAILED/REJECTED)와 다르다: 그쪽은 turn 이 끝난 것이 확인됐으므로 남은 변경을 독립 검증자에게 넘기는 종전 경로(CLI_EXIT_STATUS_MISMATCH)가 그대로다.
# 불명(SEND_UNCONFIRMED · RUNNING · UNKNOWN)은 turn 이 아직 돌고 있을 수도 있다 — 작업 트리가 계속 바뀔 수 있는 상태에서 세션 확정·검증자·리뷰어 호출로 가지 않는다.
# 호출 기록 파일만 본다(지금의 backend 설정과 무관 — 기록이 없으면 no-op). 변경·기록·체크포인트는 그대로 두고 반환 1.
codex_app_stop_if_uncertain() { # key-glob where
  local f st
  for f in "$WORK_DIR"/.session-$1.codex-turn.json; do
    [ -f "$f" ] || continue
    jq -e '.role_kind=="edit"' "$f" >/dev/null 2>&1 || continue
    st="$(codex_app_record_field "$f" '.state // ""')"
    case "$st" in
      SEND_UNCONFIRMED|RUNNING|UNKNOWN)
        echo "[STOP] CODEX_TURN_UNCERTAIN: 편집 역할 $(codex_app_record_field "$f" '.role')의 Codex 호출(key $(codex_app_record_field "$f" '.key'), invocation $(codex_app_record_field "$f" '.invocation_id'), 상태 $st — $2)이 실행·완료됐는지 알 수 없다. turn 이 아직 돌고 있을 수 있으므로 작업 트리 변경이 범위 안이어도 세션 확정·다음 검증자/리뷰어 호출로 넘어가지 않는다(완료가 확인된 실패의 CLI_EXIT_STATUS_MISMATCH 복구 대상이 아님). 변경·기록·체크포인트는 그대로 둔다 — 그 전의 재실행은 모델 호출 0회로 같은 사유로 멈춘다." >&2
        codex_app_uncertain_help "$(codex_app_record_field "$f" '.key')" "$f"
        return 1 ;;
    esac
    # turn 은 끝났지만 그 turn 이 가드 스크립트·훅 정의를 바꿨다 — 나머지 도구 호출이 검사 없이 돌았을 수 있으므로 '완료가 확인된 실패'의 전달 경로를 타지 않는다.
    if [ "$(codex_app_record_field "$f" '.outcome.code // ""')" = CODEX_APP_SERVER_HOOK_FILES_CHANGED ]; then
      echo "[STOP] CODEX_APP_SERVER_HOOK_FILES_CHANGED: 편집 역할 $(codex_app_record_field "$f" '.role')의 Codex 호출(key $(codex_app_record_field "$f" '.key'), invocation $(codex_app_record_field "$f" '.invocation_id') — $2) 전후로 가드 스크립트 또는 훅 정의가 바뀌었다: $(codex_app_record_field "$f" '.hook_files.changed | join(", ")'). 그 turn 의 변경은 가드 없이 만들어졌을 수 있다 — 범위 안이어도 세션 확정·다음 검증자/리뷰어 호출로 넘어가지 않는다. 변경·기록·체크포인트는 그대로 둔다(자동 원복 없음)." >&2
      echo "       사용자가 그 파일과 작업 트리 변경을 확인한 뒤에만: $(codex_app_cli_hint discard "$(codex_app_record_field "$f" '.key')")" >&2
      echo "       기록: $f" >&2
      return 1
    fi
  done
  return 0
}
# 읽기 전용 역할의 사전·사후 스냅샷. 값이 없거나 계산에 실패하면 '바뀌지 않았다'로 읽지 않는다 — 호출자가 명시적으로 거부한다.
codex_app_snapshot_tree() { # → tree id (40/64 hex) / 실패 1
  local t; t="$(snapshot_worktree_tree 2>/dev/null)" || return 1
  case "$t" in ''|*[!0-9a-f]*) return 1;; esac
  [ "${#t}" -ge 40 ] || return 1
  printf '%s' "$t"
}
codex_app_snapshot_index() { # → index 지문 / 실패 1 (compute_index_fingerprint 는 파이프라 git 실패가 빈 입력의 해시로 '성공'한다 — git 을 먼저 따로 확인한다)
  local i
  git ls-files --stage >/dev/null 2>&1 || return 1
  i="$(compute_index_fingerprint 2>/dev/null)" || return 1
  [ -n "$i" ] || return 1
  printf '%s' "$i"
}

# 완료 결과를 남긴 기록(RESULT_READY)을 이번 호출의 결과로 써도 되는가 — 읽기 전용 역할이고 입력 지문(역할·모델·effort·sandbox·root·prompt·schema·thread)이 같고 결과 파일이 기록한 지문과 같을 때만.
codex_app_result_reusable() { # record role model effort sandbox prompt_sha schema_sha mode thread
  local f
  jq -e --arg role "$2" --arg model "$3" --arg effort "$4" --arg sandbox "$5" --arg root "$PROJECT_ROOT" --arg ps "$6" --arg ss "$7" --arg mode "$8" --arg tid "$9" \
    '.role==$role and .role_kind=="readonly" and .model==$model and .effort==$effort and .sandbox==$sandbox and .project_root==$root
     and .prompt_sha256==$ps and .schema_sha256==$ss and .mode==$mode and ($mode=="new" or .thread_id==$tid)' "$1" >/dev/null 2>&1 || return 1
  f="$(codex_app_record_field "$1" '.result_tmp')"
  [ -s "$f" ] && [ "$(sha256_stdin < "$f")" = "$(codex_app_record_field "$1" '.final_message.sha256')" ]
}

# ---------- 호출 전 게이트 + 전송 의도 기록 ----------
# 전역 출력: CODEX_APP_REC(기록 경로) CODEX_APP_INV(invocation id) CODEX_APP_MODE(new|resume) CODEX_APP_THREAD(resume 대상) CODEX_APP_REUSE(1 = 저장된 완료 결과 재사용, 모델 0회)
#           CODEX_APP_GATE_CODE(멈춘 사유 코드 — 호출자 진단용)
codex_app_begin() { # ROLE kind(readonly|edit) key label schema base prompt
  local role="$1" kind="$2" key="$3" label="$4" schema="$5" base="$6" prompt="$7"
  local model effort sandbox ledger rec st cv prompt_sha schema_sha inv baseline='null' opt disable_agents=false rpc_ms turn_ms pid prev_mode prev_kind required_hook='null'
  model="$(role_model "$role")"; effort="$(role_effort "$role")"; cv="$(role_contract_version "$role")"
  case "$kind" in readonly) sandbox="read-only";; edit) sandbox="workspace-write";; *) echo "[FAIL] codex_app_begin: kind '$kind'" >&2; return 1;; esac
  # 읽기 전용 역할: 호출 전 작업 트리·index 를 먼저 잰다 — sandbox(read-only)가 1차 강제이고, 호출 뒤 대조가 2차 확인이다(native Agent 의 NATIVE_READONLY_VIOLATION 과 같은 뜻).
  # 둘 중 하나라도 재지 못하면 사후 대조가 성립하지 않으므로 기록·서버·turn 을 만들기 전에 멈춘다(검사를 건너뛴 채 실행하지 않는다).
  local pre_tree="" pre_index=""
  if [ "$kind" = readonly ]; then
    if ! pre_tree="$(codex_app_snapshot_tree)" || ! pre_index="$(codex_app_snapshot_index)"; then
      CODEX_APP_REC=""; CODEX_APP_INV=""; CODEX_APP_REUSE=0; CODEX_APP_GATE_CODE=CODEX_APP_SERVER_READONLY_SNAPSHOT_FAILED
      echo "[FAIL] ENV_ERROR: CODEX_APP_SERVER_READONLY_SNAPSHOT_FAILED — 읽기 전용 역할($role/$key) 호출 전 작업 트리 또는 git index 스냅샷을 만들지 못했다. 사후 대조 없이 실행하지 않는다(모델 호출 0회). git 상태를 확인한 뒤 재실행." >&2
      return 1
    fi
  fi
  ledger="$(codex_session_ledger "$key")"; rec="$(codex_app_turn_record "$key")"
  CODEX_APP_REC="$rec"; CODEX_APP_INV=""; CODEX_APP_MODE=new; CODEX_APP_THREAD=""; CODEX_APP_REUSE=0; CODEX_APP_GATE_CODE=""
  # 같은 key 가 다른 실행 수단에 결속돼 있으면 조용히 옮겨 가지 않는다 — backend 변경은 새 key(새 attempt/--new)가 정상 경로다.
  if [ -f "$WORK_DIR/.session-$key" ] || [ -f "$WORK_DIR/.session-$key.native.json" ]; then
    CODEX_APP_GATE_CODE=SESSION_CLI_MISMATCH
    echo "[FAIL] SESSION_CLI_MISMATCH: key '$key' 는 claude 세션($WORK_DIR/.session-$key 또는 native Agent 원장 .native.json)에 결속돼 있는데 지금은 Codex App Server 로 라우팅된다($role) — 자동 전환 없이 중단. 설정을 되돌리거나 새 attempt/단계(--new)로 시작." >&2
    return 1
  fi
  if [ -f "$(codex_resume_marker "$key")" ]; then
    CODEX_APP_GATE_CODE=SESSION_BACKEND_MISMATCH
    echo "[FAIL] SESSION_BACKEND_MISMATCH: key '$key' 에 codex exec(legacy_exec) 의 resume marker($(codex_resume_marker "$key"))가 남아 있다 — 옛 backend 의 미확인 호출 위에서 App Server 로 넘어가지 않는다. config.sh CODEX_BACKEND=\"legacy_exec\" 로 그 피처를 마치거나 새 attempt/단계(--new)로 시작." >&2
    return 1
  fi
  rm -f "$ledger.new"   # 스테이징은 invocation 전용이다 — 이전 호출이 남긴 미수용 스테이징을 이번 accept 가 확정하지 않게 한다
  prompt_sha="$(printf '%s' "$prompt" | sha256_stdin)"; schema_sha="$(codex_app_sha_file "$schema")"
  if [ -f "$ledger" ]; then
    if ! jq -e '.backend=="app_server"' "$ledger" >/dev/null 2>&1; then
      CODEX_APP_GATE_CODE=SESSION_BACKEND_MISMATCH
      echo "[FAIL] SESSION_BACKEND_MISMATCH: key '$key' 의 세션 원장($ledger)은 codex exec(legacy_exec) 로 만든 것이다 — App Server 로 자동 이관하지 않는다. config.sh CODEX_BACKEND=\"legacy_exec\" 로 그 피처를 마치거나 새 attempt/단계(--new)로 시작." >&2
      return 1
    fi
    jq -e --argjson v "$CODEX_APP_LEDGER_VERSION" --arg key "$key" --arg role "$role" \
      '.version==$v and .key==$key and .role==$role and .cli=="codex" and (.thread_id|type=="string" and length>0)' "$ledger" >/dev/null 2>&1 \
      || { CODEX_APP_GATE_CODE=SESSION_LEDGER_INVALID; echo "[FAIL] codex 세션 원장이 깨졌거나 key/role/버전이 다름: $ledger — 자동 새 세션 전환 없이 중단(원장 확인 뒤 사용자가 정리)." >&2; return 1; }
    jq -e --arg model "$model" --arg effort "$effort" --arg cv "$cv" --arg root "$PROJECT_ROOT" --arg sandbox "$sandbox" --arg ss "$schema_sha" \
      '.model==$model and .effort==$effort and ((.contract_version // "")|tostring)==$cv and .project_root==$root and .sandbox==$sandbox and .schema_sha256==$ss' "$ledger" >/dev/null 2>&1 \
      || { CODEX_APP_GATE_CODE=SESSION_LEDGER_MISMATCH; echo "[FAIL] SESSION_LEDGER_MISMATCH: $key 원장(model/effort/contract/project_root/sandbox/schema)이 현재 설정과 다름 — 설정을 되돌리거나 새 attempt/단계로 시작한다(자동 resume·자동 fresh·thread fork 없음)." >&2; return 1; }
    CODEX_APP_MODE=resume; CODEX_APP_THREAD="$(jq -r '.thread_id' "$ledger")"
  fi
  # ---- 같은 호출 지점(역할 + label)의 다른 key 기록 ----
  # 호출마다 고유 key 를 쓰는 역할(합의 루프의 검증자 — validator-<target>-round-NN-<invocation id>)은 재실행 때 key 가 바뀐다. key 만 보면 직전 호출의
  # 불명 기록을 지나쳐 같은 프롬프트를 다시 보내게 되므로, 같은 역할·같은 label 의 기록도 같은 규칙으로 본다(label 은 호출 지점마다 고정이다).
  local sib sib_state sib_key
  for sib in "$WORK_DIR"/.session-*.codex-turn.json; do
    [ -f "$sib" ] && [ "$sib" != "$rec" ] || continue
    jq -e --arg role "$role" --arg label "$label" '.role==$role and .label==$label' "$sib" >/dev/null 2>&1 || continue
    sib_state="$(codex_app_record_field "$sib" '.state // ""')"; sib_key="$(codex_app_record_field "$sib" '.key // ""')"
    case "$sib_state" in
      SEND_UNCONFIRMED|RUNNING|UNKNOWN)
        CODEX_APP_GATE_CODE=CODEX_TURN_UNCERTAIN
        echo "[STOP] CODEX_TURN_UNCERTAIN: 같은 호출 지점($role / $label)의 직전 Codex 호출(key $sib_key, invocation $(codex_app_record_field "$sib" '.invocation_id'), 상태 $sib_state)의 turn 이 실행·완료됐는지 알 수 없다 — thread $(codex_app_record_field "$sib" '.thread_id // "?"') / turn $(codex_app_record_field "$sib" '.turn_id // "미확정"'). key 가 달라도 같은 프롬프트를 다시 보내지 않는다(모델 호출 0회)." >&2
        codex_app_uncertain_help "$sib_key" "$sib"; return 1 ;;
      RESULT_READY)
        if [ "$kind" = readonly ] && [ "$CODEX_APP_MODE" = new ] && codex_app_result_reusable "$sib" "$role" "$model" "$effort" "$sandbox" "$prompt_sha" "$schema_sha" new ""; then
          CODEX_APP_REC="$sib"; CODEX_APP_REUSE=1; CODEX_APP_INV="$(codex_app_record_field "$sib" '.invocation_id')"
          echo "[INFO] codex app-server($role / $label): 직전 호출($CODEX_APP_INV, key $sib_key)이 완료 결과를 남기고 멈췄다 — 입력 지문이 같아 새 turn 없이 그 결과를 호출자 검사로 넘긴다." >&2
          return 0
        fi
        CODEX_APP_GATE_CODE=CODEX_TURN_RESULT_UNCONSUMED
        echo "[STOP] CODEX_TURN_RESULT_UNCONSUMED: 같은 호출 지점($role / $label)의 직전 Codex 호출(key $sib_key)은 turn 을 완료했지만 그 결과가 호출자 검사를 거치지 않았고, 이번 호출의 입력 지문이 그 호출과 다르다 — 새 turn 을 보내지 않는다(모델 호출 0회)." >&2
        codex_app_uncertain_help "$sib_key" "$sib"; return 1 ;;
    esac
  done
  # ---- 직전 호출 기록 판정 ----
  if [ -f "$rec" ]; then
    st="$(codex_app_record_field "$rec" '.state // ""')"; prev_mode="$(codex_app_record_field "$rec" '.mode // ""')"; prev_kind="$(codex_app_record_field "$rec" '.role_kind // ""')"
    # 직전 호출이 가드 스크립트·훅 정의를 바꿨다(REJECTED 지만 '완료가 확인된 실패'로 이어 가지 않는다) — 그 turn 의 변경은 가드 없이 만들어졌을 수 있다.
    # 사용자가 확인하고 discard 하기 전에는 어느 역할이든 이 key 로 새 turn 을 보내지 않는다(워커는 루프의 codex_app_stop_if_uncertain 을 거치지 않으므로 여기서 막는다).
    if [ "$(codex_app_record_field "$rec" '.outcome.code // ""')" = CODEX_APP_SERVER_HOOK_FILES_CHANGED ]; then
      CODEX_APP_GATE_CODE=CODEX_APP_SERVER_HOOK_FILES_CHANGED
      echo "[STOP] CODEX_APP_SERVER_HOOK_FILES_CHANGED: 직전 Codex 호출($key, invocation $(codex_app_record_field "$rec" '.invocation_id')) 전후로 가드 스크립트 또는 훅 정의가 바뀌었다: $(codex_app_record_field "$rec" '.hook_files.changed | join(", ")'). 그 turn 의 작업 트리 변경을 확인하기 전에는 새 turn 을 보내지 않는다(모델 호출 0회, 자동 원복 없음)." >&2
      echo "       사용자가 그 파일과 작업 트리 변경을 확인한 뒤에만: $(codex_app_cli_hint discard "$key")" >&2
      echo "       기록: $rec" >&2
      return 1
    fi
    case "$st" in
      PREPARED|THREAD_READY)
        # 그 기록을 쥔 Shell(runner_pid) 또는 런타임(runtime_pid)이 살아 있으면 아직 진행 중인 호출이다
        pid="$(codex_app_record_field "$rec" '.runtime_pid // ""')"
        { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || pid="$(codex_app_record_field "$rec" '.runner_pid // ""')"
        if [ -n "$pid" ] && [ "$pid" != "$$" ] && kill -0 "$pid" 2>/dev/null; then
          CODEX_APP_GATE_CODE=CODEX_TURN_IN_PROGRESS
          echo "[STOP] CODEX_TURN_IN_PROGRESS: key '$key' 의 Codex 호출($(codex_app_record_field "$rec" '.invocation_id'))을 다른 실행(pid $pid)이 준비 중이다 — 같은 key 로 두 번째 호출을 만들지 않는다." >&2
          return 1
        fi
        echo "[INFO] codex app-server($key): 직전 호출 기록이 $st 에서 멈췄다 — turn/start 미전송(모델 0회)이 기록으로 확정돼 새 호출로 이어 간다." >&2 ;;
      FAILED_BEFORE_SEND|ACCEPTED) ;;
      SEND_UNCONFIRMED|RUNNING|UNKNOWN)
        CODEX_APP_GATE_CODE=CODEX_TURN_UNCERTAIN
        echo "[STOP] CODEX_TURN_UNCERTAIN: 직전 Codex 호출($key, invocation $(codex_app_record_field "$rec" '.invocation_id'), 상태 $st)의 turn 이 실행·완료됐는지 알 수 없다 — thread $(codex_app_record_field "$rec" '.thread_id // "?"') / turn $(codex_app_record_field "$rec" '.turn_id // "미확정"'). 같은 프롬프트를 다시 보내지 않고 fresh thread 도 만들지 않는다(모델 호출 0회)." >&2
        codex_app_uncertain_help "$key" "$rec"; return 1 ;;
      RESULT_READY)
        if [ "$kind" = readonly ] && codex_app_result_reusable "$rec" "$role" "$model" "$effort" "$sandbox" "$prompt_sha" "$schema_sha" "$CODEX_APP_MODE" "$CODEX_APP_THREAD"; then
          CODEX_APP_REUSE=1; CODEX_APP_INV="$(codex_app_record_field "$rec" '.invocation_id')"
          echo "[INFO] codex app-server($key): 직전 호출($CODEX_APP_INV)이 완료 결과를 남기고 멈췄다 — 입력 지문(prompt·schema·모델·thread)이 같아 새 turn 없이 그 결과를 호출자 검사로 넘긴다." >&2
          return 0
        fi
        CODEX_APP_GATE_CODE=CODEX_TURN_RESULT_UNCONSUMED
        echo "[STOP] CODEX_TURN_RESULT_UNCONSUMED: 직전 Codex 호출($key, invocation $(codex_app_record_field "$rec" '.invocation_id'))은 turn 을 완료했지만 그 결과가 호출자 검사를 거치지 않았다(결과: $(codex_app_record_field "$rec" '.result_tmp')). $([ "$kind" = edit ] && echo '편집 역할은 호출 전 기준(tree·index)을 다시 세울 수 없어 자동으로 잇지 않는다' || echo '이번 호출의 입력 지문이 그 호출과 다르다') — 새 turn 을 보내지 않는다(모델 호출 0회)." >&2
        codex_app_uncertain_help "$key" "$rec"; return 1 ;;
      CONSUMED|TURN_FAILED|REJECTED)
        if [ "$prev_kind" = readonly ] && [ "$prev_mode" = resume ] && [ "$kind" = readonly ] && [ "$CODEX_APP_MODE" = resume ]; then
          CODEX_APP_GATE_CODE=SESSION_RESUME_UNCERTAIN
          echo "[STOP] SESSION_RESUME_UNCERTAIN: 직전 Codex 재개 호출($key, invocation $(codex_app_record_field "$rec" '.invocation_id'), 상태 $st)의 결과가 수용되지 않았다 — 같은 thread 에 프롬프트를 다시 보내지 않는다(자동 resume·자동 fresh 없음)." >&2
          codex_app_uncertain_help "$key" "$rec"; return 1
        fi ;;
      *)
        CODEX_APP_GATE_CODE=CODEX_TURN_RECORD_INVALID
        echo "[STOP] CODEX_TURN_RECORD_INVALID: 호출 기록($rec)을 읽을 수 없거나 모르는 상태('$st')다 — 불명 상태로 보고 새 turn 을 보내지 않는다." >&2
        codex_app_uncertain_help "$key" "$rec"; return 1 ;;
    esac
    # 사용량 기준(thread 누적값): 같은 thread 의 직전 호출이 마지막 누적값을 실제로 관측했을 때만 넘긴다. 없으면 이번 호출의 사용량은 unknown 이다.
    if [ "$CODEX_APP_MODE" = resume ]; then
      baseline="$(jq -c --arg tid "$CODEX_APP_THREAD" 'if .thread_id==$tid and (.usage.final_total|type)=="object" and (.usage.error==null) and (.state|IN("CONSUMED","ACCEPTED","TURN_FAILED","REJECTED"))
                   then {thread_id, invocation_id, total:.usage.final_total} else null end' "$rec" 2>/dev/null)" || baseline='null'
      [ -n "$baseline" ] || baseline='null'
    fi
    codex_app_archive_record "$key" "$rec" || { echo "[FAIL] 직전 호출 기록 보관 실패: $rec" >&2; return 1; }
  fi
  # ---- 전송 의도 기록(PREPARED) — 모델 요청보다 먼저 디스크에 남긴다 ----
  inv="$(new_invocation_id)"; CODEX_APP_INV="$inv"
  [ "$role" != WORKER ] || disable_agents=true
  # 편집 역할 전부(워커·수정자·디자이너)에 필수 훅 사양을 싣는다. 사양을 만들지 못해도 호출을 건너뛰게 두지 않는다 — null 로 남기면 런타임이 사양 없음으로 멈춘다.
  if [ "$kind" = edit ]; then required_hook="$(codex_app_required_hook_json)" && [ -n "$required_hook" ] || required_hook='null'; fi
  opt="$(jq -c '.opt_out_notifications // []' "$(codex_app_preflight_cache)" 2>/dev/null)"; [ -n "$opt" ] || opt='[]'
  rpc_ms="$(codex_app_timeout_ms CODEX_APP_SERVER_RPC_TIMEOUT_SEC 120)" || return 1
  turn_ms="$(codex_app_timeout_ms CODEX_APP_SERVER_TURN_TIMEOUT_SEC 0)" || return 1
  mkdir -p "$(dirname "$base")" || return 1
  printf '%s' "$prompt" > "$base.invocation-$inv.prompt.txt" || return 1
  jq -n --argjson v "$CODEX_APP_RECORD_VERSION" --arg inv "$inv" --arg key "$key" --arg role "$role" --arg kind "$kind" --arg label "$label" \
    --arg mode "$CODEX_APP_MODE" --arg tid "$CODEX_APP_THREAD" --arg root "$PROJECT_ROOT" --arg model "$model" --arg effort "$effort" --arg sandbox "$sandbox" \
    --arg cv "$cv" --argjson da "$disable_agents" --arg schema "$schema" --arg ss "$schema_sha" --arg pf "$base.invocation-$inv.prompt.txt" --arg ps "$prompt_sha" \
    --argjson pb "$(printf '%s' "$prompt" | wc -c | tr -d ' ')" --arg rt "$base.invocation-$inv.result.tmp" --arg ev "$base.appserver.jsonl" --arg sl "$base.appserver.sent.jsonl" \
    --arg el "$base.stderr.log" --arg bin "$CODEX_BIN" --arg cver "$(jq -r '.codex_version // ""' "$(codex_app_preflight_cache)" 2>/dev/null)" --argjson opt "$opt" \
    --argjson rpc "$rpc_ms" --argjson turn "$turn_ms" --argjson base "$baseline" --argjson pid "$$" --arg pt "$pre_tree" --arg pi "$pre_index" --arg ov "$CODEX_APP_WORKER_POLICY_OVERRIDES" --argjson rh "$required_hook" --arg now "$(date -u '+%FT%TZ')" '
    { version:$v, backend:"app_server", state:"PREPARED", invocation_id:$inv, key:$key, role:$role, role_kind:$kind, label:$label,
      mode:$mode, thread_id:(if $tid=="" then null else $tid end), turn_id:null, project_root:$root, model:$model, effort:$effort, sandbox:$sandbox,
      approval_policy:"never", contract_version:$cv, disable_agents:$da, required_hook:$rh,
      agents_policy_overrides:(if $da then ($ov | split(" ") | map(select(length>0))) else [] end), schema_file:(if $schema=="" then null else $schema end), schema_sha256:$ss,
      prompt_file:$pf, prompt_sha256:$ps, prompt_bytes:$pb, result_tmp:$rt, events_log:$ev, sent_log:$sl, stderr_log:$el,
      codex_bin:$bin, codex_version:$cver, opt_out_notifications:$opt, timeouts:{rpc_ms:$rpc, turn_ms:$turn, shutdown_ms:5000},
      usage_baseline:$base, runner_pid:$pid, pre_tree:(if $pt=="" then null else $pt end), pre_index:(if $pi=="" then null else $pi end),
      created_at:$now, updated_at:$now, history:[{state:"PREPARED", at:$now}] }' > "$rec.new-$inv" || return 1
  # 원자적 생성: 그 사이 다른 실행이 같은 key 의 기록을 만들었으면 덮어쓰지 않고 멈춘다.
  if ! ln "$rec.new-$inv" "$rec" 2>/dev/null; then
    rm -f "$rec.new-$inv"; CODEX_APP_GATE_CODE=CODEX_TURN_IN_PROGRESS
    echo "[STOP] CODEX_TURN_IN_PROGRESS: key '$key' 의 호출 기록($rec)이 방금 다른 실행에 의해 만들어졌다 — 같은 key 로 두 번째 호출을 만들지 않는다." >&2
    return 1
  fi
  rm -f "$rec.new-$inv"
}

# ---------- 사용량 행 (invocation 1개 = 행 1개) ----------
# App Server 의 thread/tokenUsage/updated 는 thread 누적값이다 — 런타임이 '이 호출의 turn' 이벤트만 골라 (마지막 누적 − 기준 누적)으로 낸 값만 쓴다.
# 기준이 없거나 이벤트가 손상·누락됐으면 토큰·비용은 null(unknown)이다. 0 으로 적지 않고, codex exec 이벤트 파서(log_codex_usage)에 넣지도 않는다.
# context_last_turn(마지막 모델 요청의 입력 = 컨텍스트 점유)은 비용 판정과 따로 관측된 대로 남긴다.
codex_app_log_usage() { # record node_rc
  local rec="$1" rc="$2" inv label role model u status err est='{"estimated_cost_usd":null,"long_context_turns":null,"assumptions":null}' basis='null' rates turns
  inv="$(codex_app_record_field "$rec" '.invocation_id')"; label="$(codex_app_record_field "$rec" '.label')"
  role="$(codex_app_record_field "$rec" '.role')"; model="$(codex_app_record_field "$rec" '.model')"
  # turn/start 를 보내지 않은 호출(FAILED_BEFORE_SEND)은 모델 호출이 아니다 — 행을 만들지 않는다.
  [ "$(codex_app_record_field "$rec" '.state')" != FAILED_BEFORE_SEND ] || return 0
  if [ -f "$WORK_DIR/usage.jsonl" ] && jq -e --arg inv "$inv" 'select(.invocation_id==$inv)' "$WORK_DIR/usage.jsonl" >/dev/null 2>&1; then return 0; fi   # 같은 호출을 두 번 적지 않는다
  u="$(jq -c '.usage // {status:"unavailable", error:"USAGE_EVENTS_MISSING", delta:null, context_last_turn:null, context_window:null, baseline_provenance:null}' "$rec" 2>/dev/null)"
  [ -n "$u" ] || u='{"status":"unavailable","error":"USAGE_EVENTS_MISSING","delta":null,"context_last_turn":null,"context_window":null,"baseline_provenance":null}'
  status="$(printf '%s' "$u" | jq -r '.status')"; err="$(printf '%s' "$u" | jq -r '.error // ""')"
  if [ "$status" = complete ]; then
    turns="$(printf '%s' "$u" | jq -c '[.delta | {i:.inputTokens, c:.cachedInputTokens, w:.cacheWriteInputTokens, w12:0, o:.outputTokens, r:.reasoningOutputTokens}]')"
    if rates="$(codex_model_pricing "$model")"; then
      est="$(codex_estimate_cost "$turns" "$rates")" || est='{"estimated_cost_usd":null,"long_context_turns":null,"assumptions":null}'
      basis="\"$CODEX_PRICING_BASIS\""
    fi
  else
    echo "[WARN] codex app-server 사용량 미확정($err, 관측 $status) — unknown 행으로 기록(비용·토큰 null, 0 아님): $(codex_app_record_field "$rec" '.events_log')" >&2
  fi
  jq -nc --arg label "$label" --arg role "$role" --arg model "$model" --arg inv "$inv" --argjson u "$u" --argjson est "$est" --argjson basis "$basis" \
    --arg tid "$(codex_app_record_field "$rec" '.thread_id // ""')" --arg raw "$(codex_app_record_field "$rec" '.events_log')" \
    --argjson rc "$rc" --argjson v "$USAGE_SCHEMA_VERSION" --arg now "$(date '+%FT%T%z')" '
    ($u.status == "complete") as $ok
    | (if $ok then $u.delta else null end) as $d
    | (if $ok then ([$d.inputTokens - $d.cachedInputTokens - $d.cacheWriteInputTokens, 0] | max) else null end) as $uncached
    | { schema_version:$v, invocation_id:$inv, label:$label, role:$role, cli:"codex", backend:"codex_app_server", model:$model,
        session:(if $tid=="" then null else $tid end),
        cost_usd:null, cost_kind:(if $ok and $est.estimated_cost_usd != null then "estimated" else "unknown" end),
        estimated_cost_usd:(if $ok then $est.estimated_cost_usd else null end),
        pricing_basis:(if $ok and $est.estimated_cost_usd != null then $basis else null end),
        pricing_assumptions:(if $ok and $est.assumptions != null
          then ($est.assumptions + ["usage=thread_total_delta(thread/tokenUsage/updated total; baseline=\($u.baseline_provenance))"]) else null end),
        long_context_turns:(if $ok then $est.long_context_turns else null end),
        input_uncached:$uncached, cache_read:(if $ok then $d.cachedInputTokens else null end), cache_write:(if $ok then $d.cacheWriteInputTokens else null end),
        output:(if $ok then $d.outputTokens else null end), reasoning_output:(if $ok then $d.reasoningOutputTokens else null end),
        input_effective:(if $ok then $d.inputTokens else null end), input_per_turn:null,
        context_last_turn:($u.context_last_turn // null), context_window:($u.context_window // null),
        tokens_total:(if $ok then ($d.inputTokens + $d.outputTokens) else null end),
        num_turns:(if $ok then 1 else null end), duration_ms:null, duration_api_ms:null,
        exit_code:$rc, success:($rc == 0),
        usage_observation_status:$u.status, usage_error:($u.error // null), raw_log:(if $ok then null else $raw end),
        source:"codex-app-server", recorded_at:$now }' >> "$WORK_DIR/usage.jsonl"
}

# ---------- 실행 (사전 검사 → 게이트 → 런타임 → 사용량) ----------
# 반환 0 = 호출 기록이 종결 상태에 도달했다(성공이라는 뜻이 아니다 — CODEX_APP_STATE 를 본다). 반환 1 = 호출 전에 멈췄다(모델 0회).
# 전역 출력: CODEX_APP_STATE CODEX_APP_RC(런타임 종료 코드) CODEX_APP_CODE(결과 코드) CODEX_APP_RESULT_TMP
codex_app_invoke() { # ROLE kind key label schema base prompt
  local role="$1" rec rc=0
  CODEX_APP_STATE=""; CODEX_APP_RC=1; CODEX_APP_CODE=""; CODEX_APP_RESULT_TMP=""; CODEX_APP_INV=""; CODEX_APP_GATE_CODE=""
  codex_app_preflight || { CODEX_APP_GATE_CODE=CODEX_APP_SERVER_PREFLIGHT_FAILED; return 1; }
  if [ "$role" = WORKER ]; then codex_app_agents_policy_check || { CODEX_APP_GATE_CODE=CODEX_APP_SERVER_AGENTS_POLICY_UNSUPPORTED; return 1; }; fi
  # 편집 역할: 런타임이 필수 훅 게이트를 가진 세대인지 먼저 본다. 게이트 없는 런타임은 기록의 required_hook 을 읽지 않고 그대로 turn 을 보낸다(조용한 통과).
  if [ "$2" = edit ] && ! grep -q "^const HOOK_GATE_VERSION = '$CODEX_APP_HOOK_GATE_VERSION';" "$(codex_app_runtime)" 2>/dev/null; then
    CODEX_APP_GATE_CODE=CODEX_APP_SERVER_HOOK_GATE_UNVERIFIABLE
    echo "[FAIL] ENV_ERROR: CODEX_APP_SERVER_HOOK_GATE_UNVERIFIABLE — 런타임($(codex_app_runtime))이 필수 훅 게이트(세대 $CODEX_APP_HOOK_GATE_VERSION)를 갖고 있지 않다. scripts/ 가 서로 다른 버전이다(혼합 설치) — 훅 확인 없이 편집 역할($role)을 실행하지 않는다. install.sh 를 다시 실행하라." >&2
    return 1
  fi
  codex_app_begin "$@" || return 1
  rec="$CODEX_APP_REC"
  if [ "$CODEX_APP_REUSE" = 1 ]; then
    rc=0
  else
    "$(codex_app_node_bin)" "$(codex_app_runtime)" run "$rec" || rc=$?
  fi
  CODEX_APP_RC="$rc"
  CODEX_APP_STATE="$(codex_app_record_field "$rec" '.state // ""')"
  CODEX_APP_CODE="$(codex_app_record_field "$rec" '.outcome.code // ""')"
  CODEX_APP_RESULT_TMP="$(codex_app_record_field "$rec" '.result_tmp // ""')"
  # 런타임이 기록을 닫지 못하고 죽었으면(SIGKILL 등) 기록은 진행 중 상태로 남는다 — 그 자체가 불명이고 다음 실행이 같은 판정으로 멈춘다.
  codex_app_log_usage "$rec" "$rc" || echo "[WARN] codex app-server 사용량 행 기록 실패: $rec" >&2
  return 0
}
codex_app_failure_message() { # role session
  local rec="$CODEX_APP_REC" detail; detail="$(codex_app_record_field "$rec" '.outcome.detail // ""')"
  case "$CODEX_APP_STATE" in
    FAILED_BEFORE_SEND) echo "[FAIL] codex app-server 실행 실패 — turn/start 전송 전(모델 호출 0회): ${CODEX_APP_CODE} ${detail} ($1/$2). codex exec 로 대체하지 않는다." >&2 ;;
    TURN_FAILED|REJECTED) echo "[FAIL] codex app-server turn 이 쓸 수 있는 결과 없이 끝남: ${CODEX_APP_CODE} ${detail} ($1/$2, thread $(codex_app_record_field "$rec" '.thread_id // "?"'), turn $(codex_app_record_field "$rec" '.turn_id // "?"')). 자동 재전송·모델 전환 없음." >&2 ;;
    *) echo "[FAIL] codex app-server 호출의 완료 여부 불명: 상태 ${CODEX_APP_STATE:-기록 없음} ${CODEX_APP_CODE} ${detail} ($1/$2). 재실행은 모델 호출 0회로 멈춘다(CODEX_TURN_UNCERTAIN)." >&2
       codex_app_uncertain_help "$2" "$rec" ;;
  esac
  case "$CODEX_APP_CODE" in CODEX_APP_SERVER_HOOK_GATE_*) codex_app_hook_gate_help "$rec" ;; esac
  [ ! -f "$(codex_app_record_field "$rec" '.stderr_log')" ] || tail -20 "$(codex_app_record_field "$rec" '.stderr_log')" >&2
}
# 정상 완료한 turn 뒤에 서버 프로세스가 비정상 종료한 경우 — 종료 코드만으로 turn 을 실패로 보지 않지만 숨기지도 않는다(CLI_EXIT_STATUS_MISMATCH 의 App Server 정의).
codex_app_exit_anomaly_note() { # role label evidence
  local rec="$CODEX_APP_REC" code
  jq -e '.server.exit_anomaly==true' "$rec" >/dev/null 2>&1 || return 0
  code="$(codex_app_record_field "$rec" '.server.exit_code // 1')"
  echo "[WARN] CLI_EXIT_STATUS_MISMATCH: $1 codex app-server 프로세스가 exit $code(signal $(codex_app_record_field "$rec" '.server.signal // "none"'))로 끝났지만, 이 호출의 turn 은 status=completed 로 끝났고 결속된 최종 메시지가 있다 — 호출자의 schema/contract 검사를 조건으로 사용한다" >&2
  record_cli_anomaly "$1" codex_app_server "$2" "$code" STRUCTURED_RESULT "$3"
}
# 신규 thread 의 세션 원장 스테이징(.new) — 확정은 호출자의 role_session_accept 다.
codex_app_stage_ledger() { # ROLE key
  local rec="$CODEX_APP_REC" ledger tid; ledger="$(codex_session_ledger "$2")"
  [ "$(codex_app_record_field "$rec" '.mode')" = new ] || return 0
  tid="$(codex_app_record_field "$rec" '.thread_id // ""')"; [ -n "$tid" ] || return 1
  jq -n --argjson v "$CODEX_APP_LEDGER_VERSION" --arg key "$2" --arg now "$(date '+%FT%T%z')" --slurpfile r "$rec" '
    $r[0] as $x | {version:$v, backend:"app_server", key:$key, role:$x.role, cli:"codex", model:$x.model, effort:$x.effort, sandbox:$x.sandbox,
      contract_version:$x.contract_version, project_root:$x.project_root, schema_sha256:$x.schema_sha256, thread_id:$x.thread_id, codex_version:$x.codex_version,
      created_by_invocation:$x.invocation_id, created_at:$now, last_accepted_label:"", last_accepted_at:"", last_accepted_invocation:"", last_accepted_turn_id:""}' \
    > "$ledger.new.tmp" && mv "$ledger.new.tmp" "$ledger.new"
}

# 읽기 전용·스키마 강제 역할(검증자·리뷰어). 결과 JSON → $out, 원본: $out.appserver.jsonl(서버 stdout) · $out.appserver.sent.jsonl · $out.stderr.log.
codex_app_run_readonly() { # ROLE session label schema out prompt conv
  local role="$1" session="$2" label="$3" schema="$4" out="$5" prompt="$6" conv="$7"
  [ -z "$conv" ] || prompt="$conv"$'\n\n'"$prompt"
  [ -n "$schema" ] && [ -f "$schema" ] || { echo "[FAIL] codex app-server 읽기 전용 역할($role)에 schema 파일이 없다: '$schema' — 무스키마로 실행하지 않는다." >&2; return 1; }
  codex_app_invoke "$role" readonly "$session" "$label" "$schema" "$out" "$prompt" || { RUN_READONLY_INVOCATION_ID=""; return 1; }
  RUN_READONLY_INVOCATION_ID="$CODEX_APP_INV"
  if [ "$CODEX_APP_STATE" != RESULT_READY ]; then codex_app_failure_message "$role" "$session"; return 1; fi
  if ! { [ -s "$CODEX_APP_RESULT_TMP" ] && jq -e 'type=="object"' "$CODEX_APP_RESULT_TMP" >/dev/null 2>&1; }; then
    codex_app_set_state "$CODEX_APP_REC" REJECTED '.outcome={code:"CODEX_APP_SERVER_RESULT_NOT_JSON", detail:"결과 파일이 JSON 객체가 아니다"}'
    echo "[FAIL] codex app-server 결과 JSON 없음 ($role/$session): $CODEX_APP_RESULT_TMP" >&2; return 1
  fi
  # 읽기 전용 역할이 작업 트리·index 를 바꿨으면 그 판정을 수용하지 않는다(자동 원복 없음 — 변경은 그대로 두고 멈춘다).
  # 대조할 수 없는 경우도 수용하지 않는다: 기록에 호출 전 값이 없거나(예전 기록·손상) 호출 뒤 스냅샷이 실패하면 '바뀌지 않았다'가 아니라 '확인하지 못했다'다.
  local pre_tree pre_index post_tree post_index
  pre_tree="$(codex_app_record_field "$CODEX_APP_REC" '.pre_tree // ""')"; pre_index="$(codex_app_record_field "$CODEX_APP_REC" '.pre_index // ""')"
  if [ -z "$pre_tree" ] || [ -z "$pre_index" ] || ! post_tree="$(codex_app_snapshot_tree)" || ! post_index="$(codex_app_snapshot_index)"; then
    codex_app_set_state "$CODEX_APP_REC" REJECTED '.outcome={code:"CODEX_APP_SERVER_READONLY_SNAPSHOT_FAILED", detail:"읽기 전용 역할 호출 전후의 작업 트리·git index 를 대조할 수 없다(호출 전 값 없음 또는 호출 뒤 스냅샷 실패)"}'
    echo "[FAIL] CODEX_APP_SERVER_READONLY_SNAPSHOT_FAILED: 읽기 전용 역할($role/$session) 호출 전후의 작업 트리·git index 를 대조할 수 없다(호출 전 tree '${pre_tree:-없음}' / index '${pre_index:+있음}') — 확인하지 못한 판정은 수용하지 않는다. 결과 원문: $CODEX_APP_RESULT_TMP" >&2
    return 1
  fi
  if [ "$post_tree" != "$pre_tree" ] || [ "$post_index" != "$pre_index" ]; then
    codex_app_set_state "$CODEX_APP_REC" REJECTED '.outcome={code:"CODEX_APP_SERVER_READONLY_VIOLATION", detail:"읽기 전용 역할 호출 전후로 작업 트리 또는 git index 가 다르다"}'
    echo "[FAIL] CODEX_APP_SERVER_READONLY_VIOLATION: 읽기 전용 역할($role/$session) 호출 전후로 작업 트리 또는 git index 가 다르다(tree 전 $pre_tree / 후 $post_tree, index $([ "$post_index" = "$pre_index" ] && echo 같음 || echo 다름)) — 판정을 수용하지 않는다. 자동 원복 없음: 변경을 확인하라(같은 작업 트리의 다른 세션 변경일 수도 있다). 결과 원문: $CODEX_APP_RESULT_TMP" >&2
    return 1
  fi
  codex_app_exit_anomaly_note "$role" "$label" "$out"
  codex_app_stage_ledger "$role" "$session" \
    || echo "[WARN] codex app-server 호출($session)의 thread id 미확정 — 세션 원장 스테이징 생략(이 key 는 세션을 잇지 못한다)" >&2
  mv "$CODEX_APP_RESULT_TMP" "$out" || return 1
  codex_app_set_state "$CODEX_APP_REC" CONSUMED
}
# 편집 역할(디자이너·수정자·워커). 런타임 종료 코드를 그대로 돌려준다(0 완료 / 10 미전송 / 20 turn 실패 / 30 불명 / 1 호출 전 중단).
codex_app_run_edit() { # ROLE session label raw prompt conv schema out
  local role="$1" session="$2" label="$3" raw="$4" prompt="$5" conv="$6" schema="$7" out="$8"
  [ -z "$conv" ] || prompt="$conv"$'\n\n'"$prompt"
  if ! codex_app_invoke "$role" edit "$session" "$label" "$schema" "$raw" "$prompt"; then
    RUN_EDIT_ROLE_CLI_RC=1; RUN_EDIT_ROLE_RESULT_DIAG="${CODEX_APP_GATE_CODE:-CODEX_APP_SERVER_NOT_STARTED}"; return 1
  fi
  RUN_EDIT_ROLE_INVOCATION_ID="$CODEX_APP_INV"; RUN_EDIT_ROLE_CLI_RC="$CODEX_APP_RC"
  # turn 이 끝난 것이 확인된 호출이면 thread id 를 스테이징해 둔다 — 편집 결과를 넘길지는 호출자의 게이트가 정한다(rc≠0 + 범위 안 변경 → 독립 검증자에게 전달).
  # 완료 여부 불명(UNKNOWN · RUNNING · SEND_UNCONFIRMED)은 스테이징하지 않는다: 확인되지 않은 호출의 thread 를 세션으로 확정할 길을 만들지 않는다.
  case "$CODEX_APP_STATE" in
    RESULT_READY|TURN_FAILED|REJECTED)
      codex_app_stage_ledger "$role" "$session" || echo "[WARN] codex app-server 편집 호출($session)의 thread id 미확정 — 세션 원장 스테이징 생략(재사용 없음)" >&2 ;;
  esac
  if [ "$CODEX_APP_STATE" != RESULT_READY ]; then
    RUN_EDIT_ROLE_RESULT_DIAG="${CODEX_APP_CODE:-CODEX_TURN_UNCERTAIN}"
    codex_app_failure_message "$role" "$session"
    [ "$CODEX_APP_RC" -ne 0 ] || CODEX_APP_RC=30
    RUN_EDIT_ROLE_CLI_RC="$CODEX_APP_RC"; return "$CODEX_APP_RC"
  fi
  codex_app_exit_anomaly_note "$role" "$label" "${out:-$raw}"
  if [ -n "$schema" ]; then
    mv "$CODEX_APP_RESULT_TMP" "$out" || return 1
  else
    mv "$CODEX_APP_RESULT_TMP" "$raw.last-message.txt" || return 1   # 스키마 없는 편집 역할의 최종 메시지(진단용 — 판정에는 쓰지 않는다)
  fi
  codex_app_set_state "$CODEX_APP_REC" CONSUMED || return 1
  return 0
}
# 호출자가 결과를 수용한 뒤에만 세션 확정 — 원장 .new 를 확정하고 수용 기록을 남긴다.
# 호출 기록의 상태를 원장보다 먼저 본다: 이 key 의 가장 최근 호출이 '완료 여부 불명'이거나 호출자에게 넘어간 적 없는 상태면 원장을 건드리지 않고 실패한다
# (수용은 불명을 풀지 못한다 — 원장만 확정되면 다음 단계가 확인되지 않은 실행의 변경 위에서 돈다).
#   CONSUMED → ACCEPTED / TURN_FAILED · REJECTED → 완료가 확인된 실패를 호출자가 넘기기로 한 것(accepted_by_caller) / ACCEPTED · FAILED_BEFORE_SEND → 기록 그대로
#   RESULT_READY → 결과 파일이 이미 호출자 경로로 옮겨졌을 때만(옮긴 직후 CONSUMED 표시 전에 Shell 이 죽은 경우 — turn 완료는 확인돼 있다) CONSUMED 와 같이 본다
#   SEND_UNCONFIRMED · RUNNING · UNKNOWN → CODEX_TURN_UNCERTAIN / 그 밖(PREPARED · THREAD_READY · 결과가 남아 있는 RESULT_READY · 모르는 값) → 수용할 결과가 없다
codex_app_session_accept() { # ROLE key [label]
  local key="$2" label="${3:-}" ledger rec st="" inv="" turn=""
  ledger="$(codex_session_ledger "$key")"; rec="$(codex_app_turn_record "$key")"
  if [ -f "$rec" ]; then
    st="$(codex_app_record_field "$rec" '.state // ""')"
    if [ "$(codex_app_record_field "$rec" '.outcome.code // ""')" = CODEX_APP_SERVER_HOOK_FILES_CHANGED ]; then
      echo "[FAIL] CODEX_APP_SERVER_HOOK_FILES_CHANGED: $key 의 Codex 호출(invocation $(codex_app_record_field "$rec" '.invocation_id')) 전후로 가드 스크립트 또는 훅 정의가 바뀌었다 — 세션을 확정하지 않는다(원장 변경 없음): $rec" >&2
      return 1
    fi
    case "$st" in
      CONSUMED|TURN_FAILED|REJECTED|ACCEPTED|FAILED_BEFORE_SEND) ;;
      RESULT_READY)
        if [ -e "$(codex_app_record_field "$rec" '.result_tmp // ""')" ]; then
          echo "[FAIL] $key: 호출 기록이 RESULT_READY 이고 결과가 아직 호출자에게 넘어가지 않았다($(codex_app_record_field "$rec" '.result_tmp')) — 세션을 확정하지 않는다(원장 변경 없음): $rec" >&2; return 1
        fi
        st=CONSUMED ;;
      SEND_UNCONFIRMED|RUNNING|UNKNOWN)
        echo "[FAIL] CODEX_TURN_UNCERTAIN: $key 의 Codex 호출(invocation $(codex_app_record_field "$rec" '.invocation_id'), 상태 $st)은 실행·완료 여부가 불명이다 — 세션을 확정하지 않는다(원장 변경 없음)." >&2
        codex_app_uncertain_help "$key" "$rec"; return 1 ;;
      *)
        echo "[FAIL] $key: 호출 기록이 '${st:-읽을 수 없음}' 상태다 — 호출자에게 넘어간 결과가 없어 세션을 확정하지 않는다(원장 변경 없음): $rec" >&2; return 1 ;;
    esac
  fi
  if [ -f "$ledger.new" ]; then mv "$ledger.new" "$ledger" || return 1; fi
  [ -f "$ledger" ] || { echo "[FAIL] $key: 확정할 codex 세션이 없음 — 이번 호출이 thread id 를 얻지 못했다(turn/start 전 실패 포함)." >&2; return 1; }
  if [ -n "$st" ] && [ "$(codex_app_record_field "$rec" '.thread_id // ""')" = "$(jq -r '.thread_id' "$ledger")" ]; then
    inv="$(codex_app_record_field "$rec" '.invocation_id // ""')"; turn="$(codex_app_record_field "$rec" '.turn_id // ""')"
    case "$st" in
      CONSUMED) codex_app_set_state "$rec" ACCEPTED || return 1 ;;
      TURN_FAILED|REJECTED) jq '.accepted_by_caller=true' "$rec" > "$rec.tmp" && mv "$rec.tmp" "$rec" || return 1 ;;
    esac
  fi
  jq --arg label "$label" --arg now "$(date '+%FT%T%z')" --arg inv "$inv" --arg turn "$turn" \
    '.last_accepted_label=$label | .last_accepted_at=$now | .last_accepted_invocation=$inv | .last_accepted_turn_id=$turn' "$ledger" > "$ledger.tmp" && mv "$ledger.tmp" "$ledger"
}

# ---------- 직접 실행: status / reconcile / discard / preflight (모델 호출 0회) ----------
codex_app_cli_status() { # [key]
  local f found=0
  for f in "$WORK_DIR"/.session-${1:-*}.codex-turn.json; do
    [ -f "$f" ] || continue; found=1
    jq -r '"\(.key)  state=\(.state)  role=\(.role)/\(.role_kind)  mode=\(.mode)  invocation=\(.invocation_id)\n  thread=\(.thread_id // "-")  turn=\(.turn_id // "-")  turn_status=\(.turn_status // "-")  outcome=\(.outcome.code // "-") \(.outcome.detail // "")\n  model=\(.model)/\(.effort)  sandbox=\(.sandbox)  prompt_sha256=\(.prompt_sha256[0:12])  label=\(.label)\n  events=\(.events_log)\n  stderr=\(.stderr_log)\n  result=\(.result_tmp)\n  history=\([.history[] | "\(.state)@\(.at)"] | join(" → "))"' "$f"
    echo "  record=$f"
  done
  [ "$found" = 1 ] || echo "Codex App Server 호출 기록 없음($WORK_DIR/.session-${1:-*}.codex-turn.json)"
}
# 단독 명령이 다루는 기록은 지금 정한 프로젝트 루트의 것이어야 한다 — 기록의 경로(결과·원본 로그)는 그 루트 기준이라, 다른 루트에서 처리하면 엉뚱한 트리에 쓴다.
codex_app_cli_record_root_guard() { # record verb
  local rroot a b; rroot="$(codex_app_record_field "$1" '.project_root // ""')"
  [ "$rroot" = "$PROJECT_ROOT" ] && return 0
  # 표기만 다른 같은 디렉터리(심볼릭 링크 경로 — 예: /var ↔ /private/var)는 같은 루트다. 물리 경로로 한 번 더 대조한다.
  if [ -n "$rroot" ] && a="$(cd "$rroot" 2>/dev/null && pwd -P)" && b="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" && [ "$a" = "$b" ]; then return 0; fi
  echo "[FAIL] 호출 기록($1)의 project_root($rroot)가 지금의 프로젝트 루트($PROJECT_ROOT)와 다르다 — $2 를 실행하지 않는다. 그 기록이 속한 프로젝트·피처 worktree 루트에서 실행하거나 FEATURE_PROJECT_ROOT 로 지정하라(다른 루트의 기록을 찾아 처리하지 않는다)." >&2
  return 1
}
codex_app_cli_reconcile() { # key
  local rec; rec="$(codex_app_turn_record "$1")"
  [ -f "$rec" ] || { echo "[FAIL] 호출 기록 없음: $rec (프로젝트 루트 $PROJECT_ROOT — 다른 worktree 의 기록이면 그 루트에서 실행하거나 FEATURE_PROJECT_ROOT 로 지정)" >&2; return 1; }
  codex_app_cli_record_root_guard "$rec" reconcile || return 1
  codex_app_preflight || return 1
  jq -e '.capabilities.reconcile==true' "$(codex_app_preflight_cache)" >/dev/null 2>&1 \
    || { echo "[FAIL] 설치된 codex 의 app-server 가 thread/read · thread/turns/list · thread/items/list 를 모두 지원하지 않는다 — 조회로 확인할 수 없다. status 로 원본 로그를 직접 확인하라." >&2; return 1; }
  "$(codex_app_node_bin)" "$(codex_app_runtime)" reconcile "$rec"
}
codex_app_cli_discard() { # key
  local rec st; rec="$(codex_app_turn_record "$1")"
  [ -f "$rec" ] || { echo "[FAIL] 호출 기록 없음: $rec (프로젝트 루트 $PROJECT_ROOT — 다른 worktree 의 기록이면 그 루트에서 실행하거나 FEATURE_PROJECT_ROOT 로 지정)" >&2; return 1; }
  codex_app_cli_record_root_guard "$rec" discard || return 1
  st="$(codex_app_record_field "$rec" '.state')"
  codex_app_set_state "$rec" DISCARDED_BY_USER || return 1
  codex_app_archive_record "$1" "$rec" || return 1
  echo "호출 기록($1, 직전 상태 $st)을 $(codex_app_archive_dir "$1")/ 로 옮겼다. 다음 실행은 이 key 로 새 turn 을 보낸다 — 직전 turn 이 남긴 작업 트리 변경은 그대로다(원복하지 않았다)."
}
# 필수 훅 게이트를 이 작업 루트에 대해 판정만 한다. initialize 와 hooks/list(cwd 기준)만 보낸다 — thread 를 만들지 않으므로 codex 의 신뢰 등록 같은 부작용이 없다.
# 실제 호출의 게이트는 여기에 더해 thread 를 연 뒤 그 thread 기준으로 한 번 더 본다. 반환: 0 통과 / 1 통과 아님.
codex_app_cli_hooks() {
  local spec out rc=0 rpc_ms
  codex_app_preflight || return 1
  rpc_ms="$(codex_app_timeout_ms CODEX_APP_SERVER_RPC_TIMEOUT_SEC 120)" || return 1
  spec="$(mktemp "${TMPDIR:-/tmp}/feature-codex-hooks-XXXXXX")" || return 1
  jq -n --arg root "$PROJECT_ROOT" --arg bin "$CODEX_BIN" --argjson rh "$(codex_app_required_hook_json)" --argjson rpc "$rpc_ms" \
    '{project_root:$root, codex_bin:$bin, required_hook:$rh, rpc_ms:$rpc}' > "$spec" || return 1
  out="$("$(codex_app_node_bin)" "$(codex_app_runtime)" hooks "$spec")" || rc=$?
  : > "$spec"
  [ -n "$out" ] || { echo "[FAIL] 필수 훅 판정을 얻지 못했다(런타임 종료 $rc)" >&2; return 1; }
  printf '%s\n' "$out" | jq -r '
    "작업 루트: \(.project_root)",
    "필수 훅: \(.required_hook.event) → \(.required_hook.script)   (정의 허용 경로: \(.required_hook.source_paths | join(", ")))",
    "판정: \(if .ok then "PASS" else "FAIL \(.code) [\(.reason)]" end)\(if (.detail // "") != "" then " — \(.detail)" else "" end)",
    ((.observed.candidates // [])[] | "  후보: event=\(.event) source=\(.source) enabled=\(.enabled) trustStatus=\(.trust_status) async=\(.async) matcher=\(.matcher) command=\(.command) key=\(.key)"),
    "  (cwd 기준 조회만 했다. 실제 호출은 thread 를 연 뒤 그 thread 기준으로 한 번 더 확인한다. 이 명령은 설정·신뢰 상태를 바꾸지 않는다)"'
  [ "$rc" = 0 ]
}
# ---------- 단독 진입 ----------
# 진입은 프로세스당 한 번이다: 아래에서 로더를 source 하면 로더가 이 파일을 다시 source 한다. 절대 경로로 실행했으면 그때도 BASH_SOURCE[0] == $0 이라
# 경로 비교만으로는 다시 단독 진입으로 판정해 무한히 재진입한다. CODEX_APP_MAIN_PID 로 한 번만 들어가고, 재진입은 함수 정의만 다시 읽는다
# (export 하지 않는다 — 부모 프로세스에서 물려받은 값은 pid 가 달라 무시된다).
# 프로젝트 루트(= .agent-work 가 있는 곳)는 native 브리지의 단독 명령과 같은 규칙(native_standalone_project_root)으로 정한다:
#   FEATURE_PROJECT_ROOT 명시 > 현재 디렉터리가 속한 git worktree(이 스킬이 설치된 저장소와 같은 저장소일 때만) > 그 밖에는 멈춘다.
#   설치 위치(원본)의 기록으로 조용히 넘어가지 않고, 무관한 저장소의 .agent-work 도 건드리지 않는다.
# 심볼릭 링크로 실행해도 실제 스크립트 위치의 로더를 읽는다(링크의 디렉터리가 아니다).
_codex_app_real_script() { # path → 심볼릭 링크를 끝까지 따라간 스크립트 경로(링크가 아니면 그대로)
  local p="$1" l n=0
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    l="$(readlink "$p")" || return 1
    case "$l" in /*) p="$l";; *) p="$(cd "$(dirname "$p")" && pwd)/$l";; esac
    n=$((n + 1))
  done
  [ ! -L "$p" ] || return 1
  printf '%s' "$p"
}
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${CODEX_APP_MAIN_PID:-}" != "$$" ]; then
  CODEX_APP_MAIN_PID=$$
  set -u
  _codex_app_usage="사용: bash $0 status [key] | reconcile <key> | discard <key> | preflight | hooks   (기록이 속한 프로젝트·피처 worktree 루트에서 실행하거나 FEATURE_PROJECT_ROOT 로 지정)"
  case "${1:-}" in
    status|preflight|hooks) ;;
    reconcile|discard) [ -n "${2:-}" ] || { echo "$_codex_app_usage" >&2; exit 2; } ;;
    *) echo "$_codex_app_usage" >&2; exit 2 ;;
  esac
  _codex_app_script="$(_codex_app_real_script "$0")" || { echo "[FAIL] 스크립트 경로를 확정하지 못했다(심볼릭 링크 순환?): $0" >&2; exit 1; }
  _codex_app_skill_dir="$(cd "$(dirname "$_codex_app_script")/.." && pwd)" || exit 1
  # 실행 경로를 절대 경로로 고정한다: 아래에서 프로젝트 루트로 cd 하므로 상대 경로($0·BASH_SOURCE)는 그 뒤에 다른 파일을 가리킬 수 있고,
  # 설정 가드의 조회 명령 예외는 "실행 중인 스크립트가 이 파일이다"를 절대 경로로만 인정한다. 같은 pid 로 한 번만 다시 실행한다(다시 실행된 쪽은 $0 이 같아 지나간다).
  _codex_app_abs="$_codex_app_skill_dir/scripts/$(basename "$_codex_app_script")"
  if [ "$0" != "$_codex_app_abs" ]; then exec "${BASH:-bash}" "$_codex_app_abs" "$@"; fi
  [ -f "$_codex_app_skill_dir/scripts/lib/bootstrap.sh" ] || { echo "[FAIL] 런타임 로더 없음: $_codex_app_skill_dir/scripts/lib/bootstrap.sh — 이 스크립트는 설치된 스킬의 scripts/ 안에서(또는 그 파일을 가리키는 링크로) 실행한다" >&2; exit 1; }
  [ -f "$_codex_app_skill_dir/scripts/native-agent-bridge.sh" ] || { echo "[FAIL] 스크립트 없음: $_codex_app_skill_dir/scripts/native-agent-bridge.sh (프로젝트 루트 판정) — scripts/ 가 서로 다른 버전이다(혼합 설치). install.sh 를 다시 실행하라" >&2; exit 1; }
  _codex_app_install_root="$(cd "$_codex_app_skill_dir/../../.." && pwd)" || exit 1
  # 루트 판정 함수만 빌려 쓴다(브리지의 단독 진입 블록은 BASH_SOURCE[0] != $0 이라 돌지 않는다). 로더가 브리지를 다시 읽으면 결과 변수가 초기화되므로 값을 옮겨 둔다.
  # shellcheck disable=SC1091
  source "$_codex_app_skill_dir/scripts/native-agent-bridge.sh"
  native_standalone_project_root "$_codex_app_install_root" || exit 1
  _codex_app_root="$NATIVE_STANDALONE_ROOT"; _codex_app_root_explicit="$NATIVE_STANDALONE_ROOT_EXPLICIT"
  cd "$_codex_app_root" || { echo "[FAIL] 프로젝트 루트로 이동 실패: $_codex_app_root" >&2; exit 1; }
  # 설치 저장소 자신이면 로더의 기본값(종전 문자열)을 그대로 둔다. worktree·명시 지정이면 확정한 절대 경로를 넘긴다(export 하지 않는다).
  if [ "$_codex_app_root_explicit" = 1 ] || [ "$(pwd -P)" != "$(cd "$_codex_app_install_root" && pwd -P)" ]; then FEATURE_PROJECT_ROOT="$_codex_app_root"; fi
  # 조회 전용 명령(status·preflight·hooks)은 프로젝트 명령을 실행하지 않는다 — 설정 가드가 TEST_CMD/LINT_CMD 의 CHANGE_ME 를 넘어가게 자기 pid 를 적는다
  # (export 하지 않는다. reconcile·discard 는 호출 기록을 바꾸므로 대상이 아니다 — 그 기록을 만든 실행은 이미 채워진 config.sh 를 지났다).
  # 그 밖의 명령은 표식을 비운다(환경·BASH_ENV 로 들어온 값을 덮어쓴다). 가드는 표식에 더해 실행 중인 스크립트가 이 파일인지도 본다.
  case "$1" in status|preflight|hooks) FEATURE_CONFIG_QUERY_ONLY_PID=$$ ;; *) FEATURE_CONFIG_QUERY_ONLY_PID="" ;; esac
  # shellcheck disable=SC1091
  source "$_codex_app_skill_dir/scripts/lib/bootstrap.sh"
  case "$1" in
    status) codex_app_cli_status "${2:-}" ;;
    reconcile) codex_app_cli_reconcile "$2" ;;
    discard) codex_app_cli_discard "$2" ;;
    preflight) codex_app_preflight && cat "$(codex_app_preflight_cache)" ;;
    hooks) codex_app_cli_hooks ;;
  esac
  exit $?
fi
