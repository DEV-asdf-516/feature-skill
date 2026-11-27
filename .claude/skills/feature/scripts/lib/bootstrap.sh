#!/usr/bin/env bash
# =============================================================
# .claude/skills/feature/scripts/lib/bootstrap.sh — feature 스킬의 단일 런타임 로더
# 사용: source "<스킬>/scripts/lib/bootstrap.sh" (인자 없음, 실행 파일이 아니다).
# 순서(고정): 경로 초기화 → 필수 모듈 검사 → config.sh 존재·소유권 판정(source 전) → config.sh(사용자 설정) →
#   런타임 모듈(runtime → backend/session → backend/router → contract/scope → contract/unit → contract/consensus → contract/review →
#   state/escalation → state/doc-gap → telemetry) → 브리지·App Server 연결 → 설정 가드.
# 부작용은 함수·변수 정의와 브리지·App Server source 뿐이다(파일·디렉터리 생성, cwd 변경, export, trap 없음).
# 실패는 stderr 의 [FAIL] … + exit 1 이다 — source 한 셸이 끝난다(종전 config.sh 가드와 같은 실패 의미).
# 필수 source(config-layout·config.sh·모듈·브리지·App Server)가 0 이 아닌 값을 돌려주면(문법 오류, return N, 마지막 명령의 실패) 로드는 계속되지 않는다.
#   종료 모습은 호출자의 셸 옵션에 따라 다르다: set -e 없음 → 로더의 [FAIL] + exit 1 / set -e(러너) → 그 source 줄에서 셸이 원래 종료 코드로 곧바로 끝난다
#   (예: return 7 → exit 7, 문법 오류 → bash 의 오류 메시지와 그 코드. 로더의 [FAIL] 은 나오지 않는다 — 종전 config.sh 와 같다). 셸 옵션을 바꿔 둘을 맞추지 않는다.
#   `source … || …` / `if source …` 로 쓰지 않는다 — 그 문맥은 sourced 파일 안의 set -e 를 끌 수 있다(bash 판마다 다름).
#   set -e 없는 호출자의 config.sh '중간' 명령 실패는 잡지 않는다(마지막 명령의 상태만 보인다).
# =============================================================
FEATURE_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_ROOT="${FEATURE_PROJECT_ROOT:-$(cd "$FEATURE_SKILL_DIR/../../.." && pwd)}"
_feature_rt_mods="runtime.sh backend/session.sh backend/router.sh contract/scope.sh contract/unit.sh contract/consensus.sh contract/review.sh state/escalation.sh state/doc-gap.sh telemetry.sh"
for _feature_rt_mod in config-layout.sh $_feature_rt_mods; do
  [ -f "$FEATURE_SKILL_DIR/scripts/lib/$_feature_rt_mod" ] || { echo "[FAIL] 필수 런타임 모듈 없음: $FEATURE_SKILL_DIR/scripts/lib/$_feature_rt_mod — scripts/ 가 불완전하다(부분·혼합 설치). install.sh 를 다시 실행하라" >&2; exit 1; }
done
[ -f "$FEATURE_SKILL_DIR/config.sh" ] || { echo "[FAIL] config.sh 없음: $FEATURE_SKILL_DIR/config.sh — install.sh 로 설치한 스킬인지 확인하라" >&2; exit 1; }
source "$FEATURE_SKILL_DIR/scripts/lib/config-layout.sh"; _feature_rt_rc=$?
[ "$_feature_rt_rc" -eq 0 ] || { echo "[FAIL] 런타임 모듈을 읽는 중 실패(종료 코드 $_feature_rt_rc): $FEATURE_SKILL_DIR/scripts/lib/config-layout.sh — scripts/ 가 손상됐다. install.sh 를 다시 실행하라" >&2; exit 1; }
_feature_rt_rc=0; _feature_rt_bad="$(feature_config_runtime_lines "$FEATURE_SKILL_DIR/config.sh")" || _feature_rt_rc=$?
case "$_feature_rt_rc" in
  0) ;;
  1) { echo "[FAIL] config.sh 에 런타임 소유 줄이 있다(분리 이전 설정 — 혼합 설치 방지): $FEATURE_SKILL_DIR/config.sh"
       printf '%s\n' "$_feature_rt_bad" | sed -n '1,20p' | sed 's/^/         /'
       echo "       config.sh 는 사용자 설정 전용이다. README '설치' 의 구 설치 이관 절차를 따른 뒤 install.sh 를 다시 실행하라(구 config.sh 의 코드는 실행하지 않았다)"; } >&2
     exit 1 ;;
  *) echo "[FAIL] config.sh 를 읽을 수 없다: $FEATURE_SKILL_DIR/config.sh" >&2; exit 1 ;;
esac
unset _feature_rt_bad
source "$FEATURE_SKILL_DIR/config.sh"; _feature_rt_rc=$?
[ "$_feature_rt_rc" -eq 0 ] || { echo "[FAIL] config.sh 를 읽는 중 실패(종료 코드 $_feature_rt_rc — 문법 오류, return N, 또는 마지막 명령의 실패): $FEATURE_SKILL_DIR/config.sh 를 고쳐라(마지막 명령은 0 으로 끝나야 한다. 예: '[ -f F ] && source F' 대신 'if [ -f F ]; then source F; fi')" >&2; exit 1; }
# 설정 전용 config.sh 에는 설정 줄이 빠져 있을 수 있다. 로드 중에 읽히는 설정 — 아래 설정 가드가 검사하는 12개, 가드의 CORE_RULES_FILE,
# 모듈 최상위가 읽는 WORK_DIR — 이 정의되지 않았으면 빈 값으로 정의해, set -u 진입점에서도 셸의 unbound variable 이 아니라 가드의 [FAIL] 로 끝나게 한다.
# 셸 옵션은 바꾸지 않는다. 모두 정의돼 있으면 아무것도 하지 않는다(성공한 로드의 변수는 그대로다). 빠진 이름은 가드 뒤에서 한 번 더 확인한다.
_feature_rt_missing=""
for _feature_rt_name in DESIGN_REVISION_MODEL DESIGNER_EFFORT VALIDATOR_MODEL VALIDATOR_EFFORT WORKER_MODEL WORKER_EFFORT REVIEWER_MODEL REVIEWER_EFFORT \
    FIXER_MODEL FIXER_EFFORT TEST_CMD LINT_CMD CORE_RULES_FILE WORK_DIR; do
  declare -p "$_feature_rt_name" >/dev/null 2>&1 || { printf -v "$_feature_rt_name" '%s' ''; _feature_rt_missing="$_feature_rt_missing $_feature_rt_name"; }
done
unset _feature_rt_name
for _feature_rt_mod in $_feature_rt_mods; do
  source "$FEATURE_SKILL_DIR/scripts/lib/$_feature_rt_mod"; _feature_rt_rc=$?
  [ "$_feature_rt_rc" -eq 0 ] || { echo "[FAIL] 런타임 모듈을 읽는 중 실패(종료 코드 $_feature_rt_rc): $FEATURE_SKILL_DIR/scripts/lib/$_feature_rt_mod — scripts/ 가 손상됐거나 혼합 설치다. install.sh 를 다시 실행하라" >&2; exit 1; }
done
unset _feature_rt_mod _feature_rt_mods

# native Agent 인계(브리지)는 scripts/ 에 있다 — 런타임 모듈(scripts/lib/)과 버전이 어긋나지 않게 런타임 계약 표식(2)으로 묶여 있다.
# 러너(feature-run.sh)는 시작할 때 이 파일의 존재를 확인한다(혼합 설치 → ENV_ERROR). 로더만 source 하는 도구(usage 집계 등)를 위해
# 파일이 없으면 여기서 죽지 않고, native 요청을 만들 수 없다는 사실만 호출 시점에 명시적으로 실패시킨다(CLI 로 대체하지 않는다).
if [ -f "$FEATURE_SKILL_DIR/scripts/native-agent-bridge.sh" ]; then
  source "$FEATURE_SKILL_DIR/scripts/native-agent-bridge.sh"; _feature_rt_rc=$?
  [ "$_feature_rt_rc" -eq 0 ] || { echo "[FAIL] native Agent 브리지를 읽는 중 실패(종료 코드 $_feature_rt_rc): $FEATURE_SKILL_DIR/scripts/native-agent-bridge.sh — scripts/ 가 손상됐다. install.sh 를 다시 실행하라" >&2; exit 1; }
else
  native_pending_guard() { return 0; }
  native_pending_backend_guard() { return 0; }
  native_resume_active() { return 1; }
  native_pre_begin() { return 0; }
  native_pre_put() { return 0; }
  native_role_call() { echo "[FAIL] native Agent 브리지 없음: $FEATURE_SKILL_DIR/scripts/native-agent-bridge.sh — scripts/ 와 config.sh 가 서로 다른 버전이다(혼합 설치). install.sh 를 다시 실행하라" >&2; return 1; }
  native_session_accept() { native_role_call; }
fi

# Codex App Server backend(런타임 연결부)도 scripts/ 에 있다 — 런타임 계약 표식(3)으로 런타임 모듈(scripts/lib/)과 묶여 있다. 파일이 없으면(혼합 설치)
# 여기서 죽지 않고, Codex 역할을 App Server 로 부르는 시점에 명시적으로 실패시킨다(codex exec 로 대체하지 않는다).
if [ -f "$FEATURE_SKILL_DIR/scripts/codex-app-server.sh" ]; then
  source "$FEATURE_SKILL_DIR/scripts/codex-app-server.sh"; _feature_rt_rc=$?
  [ "$_feature_rt_rc" -eq 0 ] || { echo "[FAIL] Codex App Server 연결부를 읽는 중 실패(종료 코드 $_feature_rt_rc): $FEATURE_SKILL_DIR/scripts/codex-app-server.sh — scripts/ 가 손상됐다. install.sh 를 다시 실행하라" >&2; exit 1; }
else
  codex_app_run_readonly() { echo "[FAIL] Codex App Server 런타임 없음: $FEATURE_SKILL_DIR/scripts/codex-app-server.sh — scripts/ 와 config.sh 가 서로 다른 버전이다(혼합 설치). install.sh 를 다시 실행하라(codex exec 로 대체하지 않는다)" >&2; return 1; }
  codex_app_run_edit() { codex_app_run_readonly; }
  codex_app_session_accept() { codex_app_run_readonly; }
  codex_app_stop_if_uncertain() { return 0; }   # 런타임이 없으면 App Server 호출 기록을 판정할 수 없다 — 호출 자체가 위에서 명시적으로 실패한다
fi
unset _feature_rt_rc

# =============================================================
# 가드: 설정이 틀리면 이 로더를 source 하는 스크립트를 즉시 중단
# =============================================================
# 예외 하나: 프로젝트 명령(TEST_CMD/LINT_CMD)을 실행하지 않는 단독 명령 — codex-app-server.sh 의 조회 명령(status·preflight·hooks)과
# native-agent-bridge.sh 의 prepare-agents(agent 정의 파일만 쓴다) — 은 그 두 값의 CHANGE_ME 를 넘어간다. 설치 직후(또는 스킬 원본 저장소)에도 훅 판정·호출 기록을 볼 수 있어야 하고,
# agent 정의는 Claude Code 세션을 시작하기 전(설치 때)에 있어야 한다. 모델·effort 의 CHANGE_ME 와 빈 값은 그대로 거부한다.
# 조건은 둘 다다: ① 이 프로세스가 실행한 스크립트(호출 스택의 맨 아래)가 이 스킬의 scripts/codex-app-server.sh 또는 scripts/native-agent-bridge.sh 자신이고
# ② 그 스크립트가 위 명령일 때만 적는 표식이 자기 pid 다.
# 표식만으로는 호출자를 증명하지 못한다 — 변수는 환경·BASH_ENV 로 어느 스크립트에나 심을 수 있다. 실행 스크립트의 경로(BASH_SOURCE)는 그렇게 바꿀 수 없으므로
# 러너·하위 루프·config.sh 를 source 하는 다른 스크립트는 표식이 있어도 이 예외를 얻지 못한다. 경로는 절대 경로만 인정한다(단독 진입이 절대 경로로 다시 실행한다 —
# 상대 경로는 그 진입의 cd 뒤에 다른 파일을 가리킬 수 있다).
_config_guard_cmds="$TEST_CMD$LINT_CMD"
if [ "${FEATURE_CONFIG_QUERY_ONLY_PID:-}" = "$$" ]; then
  case "${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}" in
    /*) if [ "${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}" -ef "$FEATURE_SKILL_DIR/scripts/codex-app-server.sh" ] \
           || [ "${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}" -ef "$FEATURE_SKILL_DIR/scripts/native-agent-bridge.sh" ]; then _config_guard_cmds=""; fi ;;
  esac
fi
case "$DESIGN_REVISION_MODEL$DESIGNER_EFFORT$VALIDATOR_MODEL$VALIDATOR_EFFORT$WORKER_MODEL$WORKER_EFFORT$REVIEWER_MODEL$REVIEWER_EFFORT$FIXER_MODEL$FIXER_EFFORT$_config_guard_cmds" in
  *CHANGE_ME*) echo "[FAIL] config.sh 의 CHANGE_ME 항목을 먼저 채우세요." >&2; exit 1;;
esac
unset _config_guard_cmds
for required_value in \
  "$DESIGN_REVISION_MODEL" "$DESIGNER_EFFORT" \
  "$VALIDATOR_MODEL" "$VALIDATOR_EFFORT" \
  "$WORKER_MODEL" "$WORKER_EFFORT" \
  "$REVIEWER_MODEL" "$REVIEWER_EFFORT" \
  "$FIXER_MODEL" "$FIXER_EFFORT" \
  "$TEST_CMD" "$LINT_CMD"; do
  [ -n "$required_value" ] || { echo "[FAIL] config.sh 역할별 모델/effort 및 프로젝트 명령은 비워둘 수 없습니다." >&2; exit 1; }
done
for _role in DESIGNER VALIDATOR WORKER REVIEWER FIXER; do role_backend "$_role" >/dev/null || exit 1; done; unset _role
[ -f "$CORE_RULES_FILE" ] || { echo "[FAIL] core_rules.md 없음: $CORE_RULES_FILE" >&2; exit 1; }
[ -z "$_feature_rt_missing" ] || { echo "[FAIL] config.sh 에 필수 설정이 없습니다:$_feature_rt_missing — 설치 템플릿(config.sh.new 또는 소스 저장소의 config.sh)에서 그 줄을 옮겨 채우세요." >&2; exit 1; }
unset _feature_rt_missing
