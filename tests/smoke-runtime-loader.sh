#!/usr/bin/env bash
# =============================================================
# 스모크: 런타임 로더(scripts/lib/bootstrap.sh) 계약 — 실제 LLM·CLI 호출 없음, 임시 저장소
# 파일 경로: tests/smoke-runtime-loader.sh
# 사용법: bash tests/smoke-runtime-loader.sh
#
# 사례(각 사례는 config.sh·모듈을 원본 사본에서 되돌린 뒤 시작한다):
#   L1. 소스 저장소의 config.sh 가 소유권 규칙(feature_config_runtime_lines)을 통과한다 — 반환 0·출력 없음
#   L2. 설정 전용 config 로드: rc 0·출력 없음, 핵심 함수 정의, 버전 상수 = runtime.sh 값, PROJECT_ROOT·FEATURE_SKILL_DIR 논리 경로, git 상태·.agent-work 불변
#   L3. 구 설정(런타임 함수 이름의 정의 줄 — `이름()`·앞 공백 + `function 이름`) → source 전 거부(rc 1·위반 줄 번호), 구 config 의 코드가 실행되지 않는다
#   L4. 런타임 소유 대입 8개(하나는 export 형태) 각각 → L3 과 같은 결과
#   L5. 오탐 없음: 함수 모양의 주석·괄호가 든 설정 값은 통과하고 config 가 실제로 source 된다.
#       여러 줄 설정 문자열 안의 함수 모양 줄(`run_checks() {`)·런타임 이름이 아닌 사용자 함수도 통과하고, 그 문자열 값이 그대로 남는다
#   L5b. 기록된 한계: 여러 줄 문자열이라도 줄 첫머리가 런타임 소유 대입(`PROJECT_ROOT=… ./run-lint`)이면 거부된다(줄 단위 판정 — 실패 쪽으로 닫힌다, 줄 번호 표시)
#   L5c. config 경로가 판정을 바꾸지 않는다: 백슬래시·`이름=` 으로 시작하는 상대 경로·공백·`-` 시작 경로(절대·상대)의 구 설정 → 같은 위반 줄·rc 1, 빈 config → 0
#   L5d. 거부하는 함수 이름 집합 = bash 가 scripts/lib/ 에서 실제로 정의하는 함수(bootstrap 대체 정의 포함, function 키워드 세 모양 포함) —
#        모듈 안 awk 함수 이름(fname 등)의 사용자 함수는 통과하고 config 가 로드된다
#   L10. 읽기 실패에서 로드가 계속되지 않는다: set -e 없는 호출자에서 config.sh 의 문법 오류·return 7·실패한 마지막 명령, 모듈·브리지 문법 오류 → 로더의 [FAIL]·rc 1.
#        set -e 호출자는 셸이 그 자리에서 원래 종료 코드로 끝난다(return 7 → rc 7·로더 [FAIL] 없음 / config.sh 중간의 실패 명령 → 뒤 명령 미실행 — 조건문 source 로 errexit 가 꺼지지 않았다)
#   L6. 필수 모듈 하나 누락 → rc 1·누락 경로, config 미실행 / 되돌리면 다시 rc 0
#   L7. 종전 설정 가드 유지: CHANGE_ME · 빈 값 거부
#   L8. 단독 진입이 로더를 쓴다: codex-app-server.sh status 는 조회 예외로 가드를 지나고, 같은 표식을 심은 일반 source 는 막힌다.
#       native-agent-bridge.sh discard 는 런타임을 읽은 뒤의 판정으로 끝난다
#   L9. set -u 진입점(set -euo pipefail)에서 설정 줄이 빠진 설정 전용 config: unbound variable 이 아니라 가드의 [FAIL]·rc 1
#       (모델 줄 누락 → 비워둘 수 없습니다 / CORE_RULES_FILE 누락 → core_rules.md 없음 / WORK_DIR 누락 → 필수 설정이 없습니다),
#       정상 로드 뒤 호출 셸의 set -u 상태가 그대로다(켜진 셸·꺼진 셸 모두)
# =============================================================
set -u
unset FEATURE_PROJECT_ROOT FEATURE_ORIGIN_ROOT FEATURE_CONFIG_QUERY_ONLY_PID
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-loader-$$"
mkdir -p "$TMP/repo/.claude/hooks" "$TMP/good"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }
trap 'rm -rf "$TMP"' EXIT

ROOT="$(cd "$TMP/repo" && pwd)"   # 논리 경로 — 임시 디렉터리의 심볼릭 링크를 물리 경로로 바꾸지 않는다
SK="$ROOT/.claude/skills/feature"
mkdir -p "$ROOT/.claude/skills" && cp -R "$SKILL_SRC" "$SK" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$ROOT/.claude/hooks/" 2>/dev/null || echo "core rules" > "$ROOT/.claude/hooks/core_rules.md"
CFG="$SK/config.sh"
LOADER="$SK/scripts/lib/bootstrap.sh"
RUNTIME_LIB="$SK/scripts/lib/runtime.sh"
sed -i.bak 's/^TEST_CMD="CHANGE_ME"/TEST_CMD="true"/; s/^LINT_CMD="CHANGE_ME"/LINT_CMD="true"/' "$CFG" && rm -f "$CFG.bak"
cp "$CFG" "$TMP/good/config.sh"
MARK="$TMP/old-config-ran"
reset_case() { cp "$TMP/good/config.sh" "$CFG"; rm -f "$MARK"; }
load() { ( cd "$ROOT" && bash -c 'source "$1"' _ "$LOADER" ) > "$TMP/out" 2> "$TMP/err"; echo $?; }

cd "$ROOT" || exit 1
git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init || fail "임시 저장소 준비 실패"

# ===== L1 =====
l1="$(bash -c 'source "$1"; feature_config_runtime_lines "$2"' _ "$SKILL_SRC/scripts/lib/config-layout.sh" "$SKILL_SRC/config.sh")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$l1" ] || fail "L1: 소스 config.sh 가 소유권 규칙을 통과하지 못함(rc $rc): $l1"
pass "L1: 소스 config.sh 는 사용자 설정 전용(feature_config_runtime_lines 반환 0·출력 없음)"

# ===== L2 =====
reset_case
before="$(git status --porcelain)"
rc="$(load)"
[ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] || { cat "$TMP/out" "$TMP/err"; fail "L2: 설정 전용 config 로드가 rc 0·무출력이 아님(rc $rc)"; }
probe="$(cd "$ROOT" && bash -c '
  source "$1"
  for f in role_backend run_readonly_json_role run_edit_role role_session_accept session_exists consensus_pass_current unit_contract_current doc_gap_pending \
           user_escalation_resolved_current usage_summary native_role_call codex_app_run_readonly feature_config_runtime_lines; do
    declare -F "$f" >/dev/null || echo "MISSING $f"
  done
  for v in FEATURE_RUNTIME_CONTRACT_VERSION VALIDATOR_CONTRACT_VERSION REVIEWER_CONTRACT_VERSION REVIEW_CHECKER_VERSION CONSENSUS_CHECKPOINT_VERSION REVIEW_CHECKPOINT_VERSION; do
    echo "$v=${!v:-}"
  done
  echo "PROJECT_ROOT=$PROJECT_ROOT"; echo "FEATURE_SKILL_DIR=$FEATURE_SKILL_DIR"' _ "$LOADER")" || fail "L2: 로더 source 실패"
echo "$probe" | grep '^MISSING' && fail "L2: 핵심 함수가 정의되지 않음"
for v in FEATURE_RUNTIME_CONTRACT_VERSION VALIDATOR_CONTRACT_VERSION REVIEWER_CONTRACT_VERSION REVIEW_CHECKER_VERSION CONSENSUS_CHECKPOINT_VERSION REVIEW_CHECKPOINT_VERSION; do
  want="$(grep -E "^$v=" "$RUNTIME_LIB" | cut -d= -f2 | cut -d' ' -f1)"
  [ -n "$want" ] && echo "$probe" | grep -qx "$v=$want" || fail "L2: $v 가 runtime.sh 의 값($want)과 다름: $(echo "$probe" | grep "^$v=")"
done
echo "$probe" | grep -qx "PROJECT_ROOT=$ROOT" || fail "L2: PROJECT_ROOT 가 저장소 루트의 논리 경로($ROOT)가 아님: $(echo "$probe" | grep '^PROJECT_ROOT=')"
echo "$probe" | grep -qx "FEATURE_SKILL_DIR=$SK" || fail "L2: FEATURE_SKILL_DIR 가 스킬 루트의 논리 경로($SK)가 아님: $(echo "$probe" | grep '^FEATURE_SKILL_DIR=')"
[ "$(git status --porcelain)" = "$before" ] && [ ! -e "$ROOT/.agent-work" ] || fail "L2: 로드가 작업 트리를 바꿨거나 .agent-work 를 만들었다"
pass "L2: 설정 전용 config 로드 — rc 0·무출력, 핵심 함수·버전 상수·논리 경로, 부작용 없음"

# ===== L3 =====
for def in 'render_prompt() { :; }' '  function role_backend { :; }'; do
  reset_case
  printf '%s\ntouch "%s"\n' "$def" "$MARK" >> "$CFG"
  line="$(grep -nxF -- "$def" "$CFG" | cut -d: -f1)"
  rc="$(load)"
  [ "$rc" -eq 1 ] && grep -q 'config.sh 에 런타임 소유 줄이 있다' "$TMP/err" && grep -qF "$line:$def" "$TMP/err" && [ ! -e "$MARK" ] \
    || { cat "$TMP/err"; fail "L3: 런타임 함수 정의($def)가 든 구 설정이 source 전에 거부되지 않음(rc $rc, 표식 $( [ -e "$MARK" ] && echo 있음 || echo 없음))"; }
done
pass "L3: 구 설정(런타임 함수 이름의 정의 — 이름() / 앞 공백 + function 이름) → source 전 거부(rc 1·위반 줄 번호), 구 config 미실행"

# ===== L4 =====
for name in FEATURE_RUNTIME_CONTRACT_VERSION VALIDATOR_CONTRACT_VERSION REVIEWER_CONTRACT_VERSION REVIEW_CHECKER_VERSION CONSENSUS_CHECKPOINT_VERSION REVIEW_CHECKPOINT_VERSION PROJECT_ROOT "export FEATURE_SKILL_DIR"; do
  reset_case
  printf '%s=1\ntouch "%s"\n' "$name" "$MARK" >> "$CFG"
  line="$(grep -n "^$name=1\$" "$CFG" | cut -d: -f1)"
  rc="$(load)"
  [ "$rc" -eq 1 ] && grep -q 'config.sh 에 런타임 소유 줄이 있다' "$TMP/err" && grep -q "$line:$name=1" "$TMP/err" && [ ! -e "$MARK" ] \
    || { cat "$TMP/err"; fail "L4: '$name=' 대입이 든 구 설정이 source 전에 거부되지 않음(rc $rc)"; }
done
pass "L4: 런타임 소유 대입 8개(export 형태 포함) 각각 → source 전 거부, 구 config 미실행"

# ===== L5 =====
reset_case
printf '# legacy() { :; }\nSMOKE_NOTE="value (with) parens()"\ntouch "%s"\n' "$MARK" >> "$CFG"
rc="$(load)"
[ "$rc" -eq 0 ] && [ -e "$MARK" ] || { cat "$TMP/err"; fail "L5: 함수 모양의 주석·괄호가 든 설정 값이 거부됐거나 config 가 source 되지 않음(rc $rc)"; }
# 여러 줄 설정 문자열 안의 함수 모양 줄 + 런타임 이름이 아닌 사용자 함수(외부 리뷰가 재현한 오탐)
reset_case
sed -i.bak '/^TEST_CMD=/d' "$CFG" && rm -f "$CFG.bak"
printf "TEST_CMD='\nrun_checks() {\n    ./gradlew test\n}\nrun_checks\n'\nmy_project_helper() { :; }\nfunction other_project_helper { :; }\ntouch \"%s\"\n" "$MARK" >> "$CFG"
rc="$(load)"
[ "$rc" -eq 0 ] && [ -e "$MARK" ] || { cat "$TMP/err"; fail "L5: 여러 줄 문자열 안의 함수 모양 줄·사용자 함수가 든 config 가 거부됨(rc $rc)"; }
got="$( cd "$ROOT" && bash -c 'source "$1"; printf "%s|" "$TEST_CMD"; declare -F my_project_helper other_project_helper | tr "\n" " "' _ "$LOADER" )"
[ "$got" = "$(printf '\nrun_checks() {\n    ./gradlew test\n}\nrun_checks\n|my_project_helper other_project_helper ')" ] || fail "L5: 로드 뒤 TEST_CMD 값·사용자 함수가 그대로가 아님: [$got]"
pass "L5: 오탐 없음 — 주석·괄호 값·여러 줄 문자열 안의 함수 모양 줄·사용자 함수는 통과, config 가 실제로 source 되고 값이 그대로"

# ===== L5b (기록된 한계) =====
reset_case
printf "LINT_CMD='\nPROJECT_ROOT=\$(pwd) ./run-lint\n'\ntouch \"%s\"\n" "$MARK" >> "$CFG"
line="$(grep -n '^PROJECT_ROOT=\$(pwd) ./run-lint$' "$CFG" | cut -d: -f1)"
rc="$(load)"
[ -n "$line" ] && [ "$rc" -eq 1 ] && grep -qF "$line:PROJECT_ROOT=\$(pwd) ./run-lint" "$TMP/err" && [ ! -e "$MARK" ] \
  || { cat "$TMP/err"; fail "L5b: 줄 첫머리가 런타임 소유 대입인 문자열 줄이 줄 번호와 함께 거부되지 않음(rc $rc) — 한계를 바꿨다면 README·config-layout.sh 의 기록도 바꿔라"; }
pass "L5b: 기록된 한계 — 여러 줄 문자열 안이라도 줄 첫머리가 런타임 소유 대입이면 거부(줄 $line 표시, 실패 쪽으로 닫힘)"

# ===== L5c (config 경로가 판정을 바꾸지 않는다) =====
# 백슬래시가 든 절대 경로(awk -v 이스케이프), `이름=` 으로 시작하는 상대 경로(awk 의 변수 대입 operand), 공백·`-` 로 시작하는 경로.
# 경로를 awk 인자로 넘기던 판정기는 앞의 둘을 판정 없이 통과(0)시켰다.
L5C="$TMP/l5c"; mkdir -p "$L5C/a=b" "$L5C/sp ace"
for rel in 'back\slash.sh' 'a=b/config.sh' 'sp ace/config.sh' '-dash.sh'; do
  printf 'X=1\nrender_prompt() { :; }\n' > "$L5C/$rel"
  for p in "$L5C/$rel" "$rel"; do
    got="$( cd "$L5C" && bash -c 'source "$1"; feature_config_runtime_lines "$2"; echo "rc=$?"' _ "$SK/scripts/lib/config-layout.sh" "$p" )"
    [ "$got" = "$(printf '2:render_prompt() { :; }\nrc=1')" ] || fail "L5c: 경로 '$p' 의 구 설정이 줄 2 위반(rc 1)으로 판정되지 않음: [$got]"
  done
done
: > "$L5C/empty.sh"
got="$( cd "$L5C" && bash -c 'source "$1"; feature_config_runtime_lines "$2"; echo "rc=$?"' _ "$SK/scripts/lib/config-layout.sh" "empty.sh" )"
[ "$got" = "rc=0" ] || fail "L5c: 빈 config 의 판정이 0 이 아님: [$got]"
pass "L5c: config 경로(백슬래시·'이름=' 상대 경로·공백·'-' 시작, 절대·상대)와 무관하게 같은 판정(줄 2 위반·rc 1), 빈 config 는 0"

# ===== L5d (런타임 이름 = bash 가 정의하는 함수) =====
# 판별기가 거부하는 함수 이름은 scripts/lib/ 를 bash 로 읽었을 때 실제로 정의되는 함수와 정확히 같아야 한다.
# 모듈 안 awk 프로그램의 함수(config-layout.sh 의 fname 등)는 bash 함수가 아니다 — 옛 판별기는 그 이름의 사용자 함수(`fname() { :; }`)를 거부했다.
# 시험용 모듈 하나를 잠시 더해 bash `function` 키워드 정의 세 모양(중괄호·빈 괄호·줄 끝)은 모이고 매개변수 있는 awk 함수는 빠지는지도 같이 본다.
LIB="$SK/scripts/lib"
cat > "$LIB/zz-smoke-l5d.sh" <<'EOF'
function smoke_kw_brace {
  :
}
function smoke_kw_parens() { :; }
function smoke_kw_eol
{ :; }
SMOKE_AWK_PROG='
function smoke_awk_fn(a, b) { return a }
'
EOF
mods=(); for m in "$LIB"/*.sh "$LIB"/*/*.sh; do [ "$(basename "$m")" = bootstrap.sh ] || mods+=("$m"); done
truth_mods="$(env -i PATH="$PATH" bash --norc --noprofile -c 'for m in "$@"; do source "$m" || exit 1; done; declare -F | sed "s/^declare -f //"' _ "${mods[@]}")" \
  || fail "L5d: lib 모듈을 bash 로 읽지 못함"
# bootstrap.sh 의 대체 정의는 브리지·App Server 파일이 없을 때만 생긴다 — 두 파일을 잠시 치우고 로드해 bash 가 정의한 함수를 모은다
reset_case
mv "$SK/scripts/native-agent-bridge.sh" "$TMP/bridge.aside" && mv "$SK/scripts/codex-app-server.sh" "$TMP/appserver.aside" || fail "L5d: 브리지·App Server 를 치우지 못함"
# env -i — 호출자가 export 한 함수(예: run-smokes.sh 의 run_one)가 상속돼 bash 정의 집합에 섞이지 않게 한다
truth_boot="$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" bash --norc --noprofile -c 'source "$1" >/dev/null 2>&1 || exit 1; declare -F | sed "s/^declare -f //"' _ "$LOADER")"; trc=$?
mv "$TMP/bridge.aside" "$SK/scripts/native-agent-bridge.sh" && mv "$TMP/appserver.aside" "$SK/scripts/codex-app-server.sh" || fail "L5d: 브리지·App Server 복원 실패"
[ "$trc" -eq 0 ] || fail "L5d: 브리지·App Server 없이 로더가 로드되지 않음(rc $trc)"
truth="$(printf '%s\n%s\n' "$truth_mods" "$truth_boot" | sed '/^$/d' | sort -u)"
cands="$( { grep -ohE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)|function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$LIB"/*.sh "$LIB"/*/*.sh \
  | sed -E 's/^function[[:space:]]+//; s/[[:space:]]*\(\)$//'; printf '%s\n' "$truth"; } | sort -u)"
for n in fname smoke_awk_fn; do
  printf '%s\n' "$cands" | grep -qx "$n" || fail "L5d: 후보에 awk 함수 이름 $n 이 없음(사례가 비었다)"
  printf '%s\n' "$truth" | grep -qx "$n" && fail "L5d: bash 정의 집합에 awk 함수 이름 $n 이 있음(전제 깨짐)"
done
for n in smoke_kw_brace smoke_kw_parens smoke_kw_eol render_prompt native_role_call; do
  printf '%s\n' "$truth" | grep -qx "$n" || fail "L5d: bash 정의 집합에 $n 이 없음(전제 깨짐)"
done
printf '%s\n' "$cands" | sed 's/$/() { :; }/' > "$TMP/l5d-config.sh"
got="$(bash -c 'source "$1"; feature_config_runtime_lines "$2"' _ "$LIB/config-layout.sh" "$TMP/l5d-config.sh" \
  | sed -E 's/^[0-9]+:([A-Za-z_][A-Za-z0-9_]*)\(\) \{ :; \}$/\1/' | sort -u)"
rm -f "$LIB/zz-smoke-l5d.sh"
[ "$got" = "$truth" ] || fail "L5d: 판별기가 거부한 함수 이름이 bash 가 정의하는 함수와 다름 — $(diff <(printf '%s\n' "$truth") <(printf '%s\n' "$got") | sed -n '1,12p' | tr '\n' ' ')"
reset_case
printf 'fname() { :; }\nbashfname() { :; }\nsmoke_awk_fn() { :; }\ntouch "%s"\n' "$MARK" >> "$CFG"
rc="$(load)"
[ "$rc" -eq 0 ] && [ -e "$MARK" ] || { cat "$TMP/err"; fail "L5d: awk 함수 이름과 같은 사용자 함수가 든 config 가 로드되지 않음(rc $rc)"; }
pass "L5d: 판별기가 거부하는 함수 이름 = bash 가 lib 모듈에서 정의하는 함수($(printf '%s\n' "$truth" | wc -l | tr -d ' ')개, function 키워드 세 모양 포함) — awk 함수 이름(fname 등)의 사용자 함수는 로드됨"

# ===== L6 =====
reset_case
printf 'touch "%s"\n' "$MARK" >> "$CFG"
mv "$SK/scripts/lib/contract/unit.sh" "$TMP/unit.sh.aside"
rc="$(load)"
mv "$TMP/unit.sh.aside" "$SK/scripts/lib/contract/unit.sh"
[ "$rc" -eq 1 ] && grep -q "필수 런타임 모듈 없음: $SK/scripts/lib/contract/unit.sh" "$TMP/err" && [ ! -e "$MARK" ] \
  || { cat "$TMP/err"; fail "L6: 모듈 누락이 로드 전에 거부되지 않음(rc $rc)"; }
rc="$(load)"
[ "$rc" -eq 0 ] || { cat "$TMP/err"; fail "L6: 모듈을 되돌렸는데 로드 실패(rc $rc)"; }
pass "L6: 필수 모듈 누락 → rc 1·누락 경로, config 미실행 / 되돌리면 rc 0"

# ===== L7 =====
reset_case
sed -i.bak 's/^TEST_CMD=.*/TEST_CMD="CHANGE_ME"/' "$CFG" && rm -f "$CFG.bak"
rc="$(load)"
[ "$rc" -eq 1 ] && grep -q 'CHANGE_ME 항목을 먼저' "$TMP/err" || { cat "$TMP/err"; fail "L7: CHANGE_ME 가 남은 설정이 가드에 막히지 않음(rc $rc)"; }
reset_case
sed -i.bak 's/^WORKER_MODEL=.*/WORKER_MODEL=""/' "$CFG" && rm -f "$CFG.bak"
rc="$(load)"
[ "$rc" -eq 1 ] && grep -q '비워둘 수 없습니다' "$TMP/err" || { cat "$TMP/err"; fail "L7: 빈 WORKER_MODEL 이 가드에 막히지 않음(rc $rc)"; }
pass "L7: 종전 설정 가드 유지 — CHANGE_ME·빈 값 거부"

# ===== L8 =====
reset_case
sed -i.bak 's/^TEST_CMD=.*/TEST_CMD="CHANGE_ME"/' "$CFG" && rm -f "$CFG.bak"
( cd "$ROOT" && bash "$SK/scripts/codex-app-server.sh" status ) > "$TMP/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'CHANGE_ME 항목을 먼저' "$TMP/out" || { cat "$TMP/out"; fail "L8: codex-app-server.sh status 가 조회 예외로 가드를 지나지 못함(rc $rc)"; }
( cd "$ROOT" && bash -c 'FEATURE_CONFIG_QUERY_ONLY_PID=$$; source "$1"' _ "$LOADER" ) > "$TMP/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q 'CHANGE_ME 항목을 먼저' "$TMP/out" || { cat "$TMP/out"; fail "L8: 자기 pid 표식을 심은 일반 source 가 가드를 지났다(rc $rc)"; }
reset_case
( cd "$ROOT" && bash "$SK/scripts/native-agent-bridge.sh" discard nope ) > "$TMP/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q 'pending native 요청이 없다' "$TMP/out" || { cat "$TMP/out"; fail "L8: native-agent-bridge.sh discard 가 런타임을 읽은 뒤의 판정으로 끝나지 않음(rc $rc)"; }
pass "L8: 단독 진입이 로더를 쓴다 — App Server status 조회 예외·표식만 심은 source 차단·브리지 discard 판정"

# ===== L9 =====
load_nounset() { ( cd "$ROOT" && bash -c 'set -euo pipefail; source "$1"' _ "$LOADER" ) > "$TMP/out" 2> "$TMP/err"; echo $?; }
for l9 in 'WORKER_MODEL:비워둘 수 없습니다' 'CORE_RULES_FILE:core_rules.md 없음' 'WORK_DIR:필수 설정이 없습니다: WORK_DIR'; do
  reset_case
  grep -q "^${l9%%:*}=" "$CFG" || fail "L9: 기준 config 에 ${l9%%:*} 줄이 없다(사례 전제)"
  sed -i.bak "/^${l9%%:*}=/d" "$CFG" && rm -f "$CFG.bak"
  rc="$(load_nounset)"
  [ "$rc" -eq 1 ] && grep -q "${l9#*:}" "$TMP/err" && ! grep -q 'unbound variable' "$TMP/err" \
    || { cat "$TMP/err"; fail "L9: ${l9%%:*} 줄이 빠진 config 를 set -u 로 source 했을 때 가드의 [FAIL] 이 아님(rc $rc)"; }
done
reset_case
r="$( ( cd "$ROOT" && bash -c 'set -u; source "$1"; case "$-" in *u*) echo on;; *) echo off;; esac' _ "$LOADER" ) 2>&1 )"
[ "$r" = on ] || fail "L9: set -u 셸에서 정상 로드 뒤 set -u 가 유지되지 않음: $r"
r="$( ( cd "$ROOT" && bash -c 'set +u; source "$1"; case "$-" in *u*) echo on;; *) echo off;; esac' _ "$LOADER" ) 2>&1 )"
[ "$r" = off ] || fail "L9: set -u 가 꺼진 셸에서 정상 로드 뒤 set -u 가 켜짐: $r"
r="$( ( cd "$ROOT" && bash -c 'set -u; source "$1"; compgen -v | grep "^_feature_rt_" || true' _ "$LOADER" ) 2>&1 )"
[ -z "$r" ] || fail "L9: 정상 로드 뒤 로더 임시 변수가 남음: $r"
pass "L9: set -u 진입점의 설정 줄 누락 → 가드 [FAIL]·rc 1(unbound variable 아님), 로더는 호출 셸의 set -u 를 바꾸지 않고 임시 변수를 남기지 않음"

# ===== L10 =====
for l10 in 'if then fi:종료 코드 ' 'return 7:종료 코드 7 ' '[ -f /nonexistent-smoke-loader ] && SMOKE_X=1:종료 코드 1 '; do   # 문법 오류의 종료 코드는 bash 판마다 다를 수 있어 값을 보지 않는다
  reset_case
  printf '%s\n' "${l10%%:*}" >> "$CFG"
  rc="$(load)"
  [ "$rc" -eq 1 ] && grep -q "\[FAIL\] config.sh 를 읽는 중 실패(${l10#*:}" "$TMP/err" \
    || { cat "$TMP/err"; fail "L10: config.sh 끝의 '${l10%%:*}' 가 set -e 없는 호출자에서 [FAIL]·rc 1 로 닫히지 않음(rc $rc)"; }
done
for l10 in scripts/lib/telemetry.sh:'런타임 모듈을 읽는 중 실패' scripts/native-agent-bridge.sh:'native Agent 브리지를 읽는 중 실패' scripts/codex-app-server.sh:'Codex App Server 연결부를 읽는 중 실패'; do
  reset_case
  cp "$SK/${l10%%:*}" "$TMP/module.keep"
  printf '\nif then fi\n' >> "$SK/${l10%%:*}"
  rc="$(load)"
  cp "$TMP/module.keep" "$SK/${l10%%:*}"
  [ "$rc" -eq 1 ] && grep -q "\[FAIL\] ${l10#*:}" "$TMP/err" && grep -qF "$SK/${l10%%:*}" "$TMP/err" \
    || { cat "$TMP/err"; fail "L10: ${l10%%:*} 문법 오류가 set -e 없는 호출자에서 [FAIL]·rc 1 로 닫히지 않음(rc $rc)"; }
done
# 정적 확인: 로더의 필수 source 는 전부 무조건 형태(`source "<경로>"; _feature_rt_rc=$?`)다. `source … ||` · `if source …` · `! source …` 는 sourced 파일 안의
# set -e 를 끈다 — bash 3.2 는 source 에 대해서는 끄지 않아 아래 동적 사례로는 그 회귀가 드러나지 않으므로(bash 판마다 다르다) 형태를 직접 본다.
bad_src="$(grep -nE '(^|[^_[:alnum:]])(source|\.)[[:space:]]+"\$FEATURE_SKILL_DIR' "$LOADER" | grep -vE '^[0-9]+:[[:space:]]*source "\$FEATURE_SKILL_DIR/[^"]*"; _feature_rt_rc=\$\?$' || true)"
n_src="$(grep -cE '^[[:space:]]*source "\$FEATURE_SKILL_DIR/[^"]*"; _feature_rt_rc=\$\?$' "$LOADER")"
[ -z "$bad_src" ] && [ "$n_src" -eq 5 ] || fail "L10: 로더의 source 가 무조건 형태가 아니거나 개수(기대 5: config-layout·config·모듈 루프·브리지·App Server)가 다름($n_src): $bad_src"
reset_case
printf 'return 7\n' >> "$CFG"
( cd "$ROOT" && bash -c 'set -e; source "$1"; echo LOADED' _ "$LOADER" ) > "$TMP/out" 2> "$TMP/err"; rc=$?
[ "$rc" -eq 7 ] && ! grep -q '\[FAIL\]' "$TMP/err" && ! grep -q LOADED "$TMP/out" || { cat "$TMP/err"; fail "L10: set -e 호출자에서 config.sh 의 return 7 이 셸의 즉시 종료(rc 7·로더 [FAIL] 없음)가 아님(rc $rc) — 문서(README·bootstrap.sh 머리말)와 함께 맞춰라"; }
reset_case
printf 'false\ntouch "%s"\n' "$MARK" >> "$CFG"
( cd "$ROOT" && bash -c 'set -e; source "$1"; echo LOADED' _ "$LOADER" ) > "$TMP/out" 2> "$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$MARK" ] && ! grep -q LOADED "$TMP/out" || fail "L10: set -e 호출자에서 config.sh 중간의 실패 명령 뒤가 실행됨(rc $rc, 표식 $( [ -e "$MARK" ] && echo 있음 || echo 없음)) — 조건문 source 로 errexit 가 꺼졌다"
reset_case
rc="$(load)"; [ "$rc" -eq 0 ] || { cat "$TMP/err"; fail "L10: 되돌린 뒤 정상 로드 실패(rc $rc)"; }
pass "L10: config.sh 문법 오류·return 7·실패한 마지막 명령, 모듈·브리지·App Server 문법 오류 → set -e 없으면 로더 [FAIL]·rc 1 / set -e 호출자는 셸이 원래 코드로 즉시 종료(return 7 → rc 7, config 중간 실패 뒤 미실행)"

echo "[SMOKE OK] runtime loader"
