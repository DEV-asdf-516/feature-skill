#!/usr/bin/env bash
# =============================================================
# native Agent 정의 사전 준비 · 등록 증거 게이트 스모크 (모델 호출 0회 — mock CLI, 가짜 "메인 Claude Code" 프로세스)
# 실제 Claude Code 는 부르지 않는다. 메인 프로세스는 sleep 프로세스로 흉내 내고(CLAUDE_PID), 정의 파일의 수정 시각을 앞당겨
# "그 프로세스가 시작할 때 이미 있던 정의"를 만든다(세션 재시작의 흉내).
#   P1~P6  prepare-agents 단독 명령: native 역할만 쓴다 · 멱등 · 관리 표식 없는 파일 보존 · legacy_cli 무기록 · 설정 가드 예외의 범위 · 러너와 같은 정의(재기록 없음)
#   G1~G6  요청 발행 직전 게이트(native_prepare): 등록 증거 있음 → 발행(42) / 프로세스보다 새 정의·이번 실행이 쓴 정의 → 요청 없이 43(NATIVE_AGENT_RESTART_REQUIRED) /
#          CLAUDE_PID 없음·죽은 pid·형식 오류 → 판정하지 않고 종전대로 발행
#   F1~F4  피처 시작 일괄 준비(native_definitions_preflight): 등록됨 → 통과 / 새로 쓴 정의 → 멈춤 / PREPARED 요청은 그 정의만 확인 / DISPATCHED 이후는 쓰지도 멈추지도 않음
#   L1     합의 루프 단독 실행(feature-run.sh 없음): 남은 PREPARED 요청의 정의가 메인 프로세스보다 새것이면 다시 안내하지 않고 43, 재시작 뒤 같은 요청을 안내
#   D1~D3  PREPARED 요청의 정의 파일이 없거나 요청 발행 때와 내용이 다르면 CLAUDE_PID 와 무관하게 dispatch 전에 43 · 발행 때 설정의 prepare-agents 로 복구 → 재시작 뒤 통과
#   R1~R2  실제 feature-run.sh: 유료 호출(Codex 검증자) 전에 NEED_USER NATIVE_AGENT_RESTART_REQUIRED, "재시작" 뒤 같은 명령은 게이트를 지나 검증자를 부른다
# Claude Code 의 실제 등록 동작(세션 도중 만든 정의의 감지 여부)은 이 스모크가 검증하지 않는다 — 게이트는 그 동작에 기대지 않는 대리 증거다.
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-native-defs-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks"
TMP="$(cd "$TMP" && pwd)"   # TMPDIR 끝의 '/' 로 생기는 '//' 를 없앤다 — 로더는 cd·pwd 로 정한 경로를 보고한다
FAKE_PID=""
cleanup() { [ -z "$FAKE_PID" ] || kill "$FAKE_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { echo "[SMOKE FAIL] $*" >&2; [ ! -f "$TMP/last.log" ] || sed -n '1,40p' "$TMP/last.log" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }
# 이 세션의 메인 Claude Code pid(CLAUDE_PID)를 물려받지 않는다 — 사례마다 명시한다
unset CLAUDE_PID CLAUDE_CODE_SUBAGENT_MODEL_FORCE CLAUDE_CODE_EFFORT_LEVEL NTFY_TOPIC FEATURE_PROJECT_ROOT FEATURE_ORIGIN_ROOT FEATURE_NATIVE_AGENTS_DIR FEATURE_CONFIG_QUERY_ONLY_PID
export CLAUDE_CODE_SESSION_ID="sess-main" FEATURE_LIVE_TEE=1

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
cp "$PROJECT_SRC/.claude/hooks/feature_native_agent.sh" "$TMP/repo/.claude/hooks/" || fail "훅 복사 실패"
SK="$TMP/repo/.claude/skills/feature"
CFG="$SK/config.sh"; LOADER="$SK/scripts/lib/bootstrap.sh"; BRIDGE="$SK/scripts/native-agent-bridge.sh"
AGENTS="$TMP/repo/.claude/agents"
export CLI_LOG="$TMP/cli.log"; : > "$CLI_LOG"
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
setcfg() { local e; for e in "$@"; do sed -i.bak "$e" "$CFG" && rm -f "$CFG.bak" || fail "config 수정 실패: $e"; done; }
setcfg "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|" "s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|" "s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|" \
  's|^TEST_CMD=.*|TEST_CMD="true"|' 's|^LINT_CMD=.*|LINT_CMD="true"|' 's|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND="native"|' \
  's|^DESIGN_REVISION_MODEL=.*|DESIGN_REVISION_MODEL="claude-fable-5-2"|' 's|^VALIDATOR_MODEL=.*|VALIDATOR_MODEL="claude-opus-5-5"|' 's|^VALIDATOR_EFFORT=.*|VALIDATOR_EFFORT="medium"|' \
  's|^WORKER_MODEL=.*|WORKER_MODEL="claude-opus-5-5"|' 's|^REVIEWER_MODEL=.*|REVIEWER_MODEL="gpt-5.6-sol"|' 's|^FIXER_MODEL=.*|FIXER_MODEL="claude-sonnet-5-5"|' \
  's|^VALIDATOR_PROFILE=.*|VALIDATOR_PROFILE="none"|'
export MOCK_CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$SK/scripts/lib/runtime.sh" | cut -d= -f2 | cut -d' ' -f1)"

cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && echo "base" > src/a.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
: > .agent-work/decisions.md
ND="$TMP/repo/.agent-work/native-agent"
SCHEMA=".claude/skills/feature/schemas/spec-review.schema.json"
NATIVE_DEFS="feature-designer.md feature-validator.md feature-worker.md feature-fixer.md"   # REVIEWER 는 gpt(codex) — 정의를 쓰지 않는다

RC=0
# 정의 파일의 수정 시각: age = 한 시간 전(그 프로세스가 시작할 때 이미 있었다), freshen = 지금
age() { python3 -c 'import os,sys,time; t=time.time()-3600; [os.utime(p,(t,t)) for p in sys.argv[1:]]' "$@" || fail "수정 시각 조정 실패: $*"; }
freshen() { python3 -c 'import os,sys,time; t=time.time(); [os.utime(p,(t,t)) for p in sys.argv[1:]]' "$@" || fail "수정 시각 조정 실패: $*"; }
age_all() { local f; for f in $NATIVE_DEFS; do age "$AGENTS/$f"; done; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
mtimes() { local f; for f in $NATIVE_DEFS; do printf '%s ' "$(mtime "$AGENTS/$f")"; done; }
prep() { RC=0; bash "$BRIDGE" prepare-agents > "$TMP/last.log" 2>&1 || RC=$?; }
role_ro() { # key label  [env 는 호출자가 앞에 붙인다]
  RC=0; ( set -e; source "$LOADER"; run_readonly_json_role VALIDATOR "$1" "$2" "$SCHEMA" "$TMP/out.json" "smoke prompt for $2" "" ) > "$TMP/last.log" 2>&1 || RC=$?
}
pf() { RC=0; ( set -e; source "$LOADER"; native_definitions_preflight ) > "$TMP/last.log" 2>&1 || RC=$?; }
req_file() { jq -r '.request_path' "$ND/pending.json"; }
req_count() { ls "$ND/requests"/*.json 2>/dev/null | wc -l | tr -d ' '; }
reset_native() { rm -rf "$ND" .agent-work/.session-* .agent-work/usage.jsonl; }
rejection_code() { cut -d: -f1 "$ND/last-rejection.txt" 2>/dev/null; }

# ---------- P1~P6: prepare-agents ----------
prep
[ "$RC" = 0 ] || fail "P1: prepare-agents rc=$RC"
for f in $NATIVE_DEFS; do
  [ -f "$AGENTS/$f" ] || fail "P1: $f 를 만들지 않음"
  grep -Fq 'managed-by: feature-skill native-agent' "$AGENTS/$f" || fail "P1: $f 에 관리 표식 없음"
done
[ ! -e "$AGENTS/feature-reviewer.md" ] || fail "P1: codex 로 라우팅되는 REVIEWER 의 정의를 썼다"
grep -q '^model: claude-fable-5-2$' "$AGENTS/feature-designer.md" && grep -q '^model: claude-sonnet-5-5$' "$AGENTS/feature-fixer.md" && grep -q '^effort: high$' "$AGENTS/feature-fixer.md" \
  || fail "P1: 정의의 model·effort 가 config.sh 값이 아님"
[ "$(grep -c ': created$' "$TMP/last.log")" = 4 ] || fail "P1: created 보고가 4줄이 아님"
grep -q 'REVIEWER gpt-5.6-sol → codex_cli: native 가 아니다' "$TMP/last.log" || fail "P1: native 아닌 역할의 보고 없음"
grep -q '^\[ACTION\] 이 프로젝트에서 이미 열려 있는 Claude Code 세션은' "$TMP/last.log" || fail "P1: CLAUDE_PID 없이 정의를 썼는데 재시작 안내가 없음"
pass "P1: native 로 라우팅되는 역할(4개)만 config.sh 의 model·effort 로 정의를 쓰고, codex 역할은 건너뛰며, 열려 있는 세션의 재시작을 안내한다"

before="$(mtimes)"
prep
[ "$RC" = 0 ] && [ "$(grep -c ': unchanged$' "$TMP/last.log")" = 4 ] && [ "$(mtimes)" = "$before" ] || fail "P2: 재실행이 멱등이 아님(rc=$RC)"
grep -q '이번에 새로 쓰거나 고친 정의 0개' "$TMP/last.log" && ! grep -q '^\[ACTION\]' "$TMP/last.log" || fail "P2: 바뀐 것 없는 재실행이 재시작을 안내함"
pass "P2: 재실행은 파일을 다시 쓰지 않는다(4개 unchanged, 수정 시각 불변, 재시작 안내 없음)"

cp "$AGENTS/feature-fixer.md" "$TMP/fixer.saved"
printf -- '---\nname: feature-fixer\ndescription: user file\n---\nmine\n' > "$AGENTS/feature-fixer.md"
cp "$AGENTS/feature-fixer.md" "$TMP/fixer.user"
prep
[ "$RC" = 1 ] || fail "P3: 관리 표식 없는 파일이 있는데 rc=$RC"
cmp -s "$AGENTS/feature-fixer.md" "$TMP/fixer.user" || fail "P3: 사용자 파일을 덮어썼다"
grep -q NATIVE_AGENT_DEFINITION_CONFLICT "$TMP/last.log" && grep -q 'FIXER claude-sonnet-5-5 / effort high: 실패' "$TMP/last.log" || fail "P3: 충돌 보고 없음"
grep -q 'WORKER claude-opus-5-5 / effort medium → .*: unchanged$' "$TMP/last.log" || fail "P3: 한 역할의 실패가 나머지 처리를 멈췄다"
cp "$TMP/fixer.saved" "$AGENTS/feature-fixer.md"; prep
[ "$RC" = 0 ] || fail "P3: 복구 뒤 rc=$RC"
pass "P3: 관리 표식 없는 같은 이름의 파일은 덮어쓰지 않고 rc 1(나머지 역할은 계속 처리)"

setcfg 's|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND="legacy_cli"|'
RC=0; FEATURE_NATIVE_AGENTS_DIR="$TMP/agents-legacy" bash "$BRIDGE" prepare-agents > "$TMP/last.log" 2>&1 || RC=$?
setcfg 's|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND="native"|'
[ "$RC" = 0 ] && grep -q 'native 로 라우팅되는 역할이 없다 — 아무것도 쓰지 않았다' "$TMP/last.log" && [ ! -e "$TMP/agents-legacy" ] || fail "P4: legacy_cli 에서 rc=$RC 또는 정의를 썼다"
pass "P4: CLAUDE_BACKEND=legacy_cli 면 아무것도 쓰지 않는다"

setcfg 's|^TEST_CMD=.*|TEST_CMD="CHANGE_ME"|' 's|^LINT_CMD=.*|LINT_CMD="CHANGE_ME"|'
prep; [ "$RC" = 0 ] || fail "P5: TEST_CMD/LINT_CMD 가 CHANGE_ME 인 설치 직후에 prepare-agents rc=$RC"
RC=0; ( cd "$SK/scripts" && bash native-agent-bridge.sh prepare-agents ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 0 ] || fail "P5: 상대 경로 실행(절대 경로 재실행)이 설정 가드 예외를 얻지 못함 rc=$RC"
RC=0; bash -c 'FEATURE_CONFIG_QUERY_ONLY_PID=$$; source "$1"' _ "$LOADER" > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" != 0 ] && grep -q CHANGE_ME "$TMP/last.log" || fail "P5: 다른 스크립트가 표식만으로 CHANGE_ME 가드를 넘었다"
# BASH_ENV 로 표식을 '자기 pid' 로 심어도(가드의 두 조건 중 하나를 위조) discard 는 표식을 지우고 들어가므로 CHANGE_ME 에서 멈춰야 한다
printf 'FEATURE_CONFIG_QUERY_ONLY_PID=$$\n' > "$TMP/bashenv"
RC=0; ( cd "$TMP/repo" && BASH_ENV="$TMP/bashenv" bash "$BRIDGE" discard native-x ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" != 0 ] && grep -q CHANGE_ME "$TMP/last.log" || fail "P5: discard 가 설정 가드 예외를 얻었다"
setcfg 's|^WORKER_MODEL=.*|WORKER_MODEL="CHANGE_ME"|'
prep; [ "$RC" = 1 ] && grep -q CHANGE_ME "$TMP/last.log" || fail "P5: 모델이 CHANGE_ME 인데 prepare-agents rc=$RC"
setcfg 's|^WORKER_MODEL=.*|WORKER_MODEL="claude-opus-5-5"|' 's|^TEST_CMD=.*|TEST_CMD="true"|' 's|^LINT_CMD=.*|LINT_CMD="true"|'
pass "P5: prepare-agents 는 TEST_CMD/LINT_CMD 의 CHANGE_ME 만 넘어간다(상대 경로 실행 포함) — 모델 CHANGE_ME·다른 스크립트·discard 는 그대로 거부"

out="$( ( source "$LOADER"; native_definition_ensure WORKER claude-opus-5-5 medium; printf '%s|%s|%s' "$NATIVE_DEF_WRITTEN" "$NATIVE_DEF_SHA" "$NATIVE_DEF_PATH" ) 2>&1 )"
[ "${out%%|*}" = "" ] || fail "P6: prepare-agents 가 쓴 정의를 러너의 ensure 가 다시 썼다: $out"
sha="$(shasum -a 256 "$AGENTS/feature-worker.md" 2>/dev/null | awk '{print $1}')"; [ -n "$sha" ] || sha="$(sha256sum "$AGENTS/feature-worker.md" | awk '{print $1}')"
[ "$(printf '%s' "$out" | cut -d'|' -f2)" = "$sha" ] && [ "${out##*|}" -ef "$AGENTS/feature-worker.md" ] || fail "P6: 정의 해시·경로 불일치: $out"
pass "P6: prepare-agents 의 정의는 요청 발행 때의 ensure 가 그대로 받는다(재기록 없음 — 세션 원장의 정의 해시가 어긋나지 않는다)"

# ---------- G1~G6: 요청 발행 직전 게이트 ----------
sleep 600 & FAKE_PID=$!
disown "$FAKE_PID" 2>/dev/null || true   # 정리 때의 kill 알림(Terminated)을 출력에 남기지 않는다
age_all
CLAUDE_PID="$FAKE_PID" role_ro v-g1 smoke-g1
[ "$RC" = 42 ] && [ -f "$ND/pending.json" ] && [ "$(jq -r '.state' "$(req_file)")" = PREPARED ] && [ "$(jq -r '.agent_definition_written' "$(req_file)")" = null ] \
  || fail "G1: 프로세스 시작 전에 있던 정의인데 요청을 발행하지 않음(rc=$RC)"
pass "G1: 정의가 메인 프로세스보다 먼저 있었으면(등록 증거) 종전대로 요청을 발행한다(exit 42, PREPARED)"
reset_native

freshen "$AGENTS/feature-validator.md"
CLAUDE_PID="$FAKE_PID" role_ro v-g2 smoke-g2
[ "$RC" = 43 ] || fail "G2: 프로세스보다 새 정의인데 rc=$RC"
[ "$(rejection_code)" = NATIVE_AGENT_RESTART_REQUIRED ] && grep -q 'feature-validator.md(수정 ' "$ND/last-rejection.txt" || fail "G2: 사유 코드·대상 정의 없음: $(cat "$ND/last-rejection.txt" 2>/dev/null)"
[ ! -f "$ND/pending.json" ] && [ "$(req_count)" = 0 ] && [ ! -s "$CLI_LOG" ] || fail "G2: 요청을 발행했거나 CLI 를 불렀다"
grep -q '^\[STOP\] NATIVE_AGENT_RESTART_REQUIRED: ' "$TMP/last.log" && grep -q '요청은 발행하지 않았다' "$TMP/last.log" || fail "G2: 중단 안내 없음"
pass "G2: 메인 프로세스보다 나중에 쓰인 정의 → 요청을 만들지 않고 exit 43 NATIVE_AGENT_RESTART_REQUIRED(pending·requests 없음, CLI 0회)"
reset_native

age_all; setcfg 's|^VALIDATOR_EFFORT=.*|VALIDATOR_EFFORT="high"|'
CLAUDE_PID="$FAKE_PID" role_ro v-g3 smoke-g3
[ "$RC" = 43 ] && [ "$(rejection_code)" = NATIVE_AGENT_RESTART_REQUIRED ] && grep -q 'feature-validator.md(이번 실행이 고쳐 씀)' "$ND/last-rejection.txt" || fail "G3: 이번 실행이 고친 정의인데 rc=$RC / $(cat "$ND/last-rejection.txt" 2>/dev/null)"
grep -q '^effort: high$' "$AGENTS/feature-validator.md" && [ ! -f "$ND/pending.json" ] || fail "G3: 정의를 고쳐 쓰지 않았거나 요청을 발행했다"
pass "G3: 설정 변경으로 이번 실행이 정의를 고쳐 썼으면 요청 없이 멈춘다(정의는 새 값으로 디스크에 남는다 — 재시작 뒤 그대로 통과)"
reset_native
setcfg 's|^VALIDATOR_EFFORT=.*|VALIDATOR_EFFORT="medium"|'; prep; [ "$RC" = 0 ] || fail "G3: 복구 rc=$RC"

freshen "$AGENTS/feature-validator.md"
role_ro v-g4 smoke-g4
[ "$RC" = 42 ] && [ -f "$ND/pending.json" ] || fail "G4: CLAUDE_PID 가 없으면 종전대로 발행해야 하는데 rc=$RC"
reset_native
setcfg 's|^VALIDATOR_EFFORT=.*|VALIDATOR_EFFORT="high"|'
role_ro v-g4b smoke-g4b
[ "$RC" = 42 ] && grep -q 'CLAUDE_PID 가 없어(또는 그 프로세스를 볼 수 없어) 방금 쓴 agent 정의' "$TMP/last.log" \
  && grep -q '러너가 메인 Claude Code 프로세스(CLAUDE_PID)를 확인하지 못해' "$TMP/last.log" || fail "G4: 방금 쓴 정의를 판정 없이 발행할 때 안내가 없음(rc=$RC)"
# 그 요청을 재시작한 세션(정의가 프로세스보다 먼저 있음)에서 재실행하면 게이트를 지나고, '확인하지 못했다' 주의는 더 붙이지 않는다
age "$AGENTS/feature-validator.md"
CLAUDE_PID="$FAKE_PID" role_ro v-g4b smoke-g4b
[ "$RC" = 42 ] && grep -q '^\[NATIVE_AGENT_REQUIRED\]' "$TMP/last.log" && ! grep -q '\[주의\]' "$TMP/last.log" && [ "$(req_count)" = 1 ] \
  || fail "G4: 등록 증거를 확인한 재실행에도 '등록 여부를 보지 않았다' 주의를 붙였거나 요청이 바뀜(rc=$RC)"
pass "G4: CLAUDE_PID 가 없으면(터미널 단독 실행) 판정하지 않고 발행한다 — 방금 쓴 정의면 dispatch 전 재시작 확인을 안내하고, 증거를 확인한 재실행에서는 그 주의를 뺀다"
reset_native
setcfg 's|^VALIDATOR_EFFORT=.*|VALIDATOR_EFFORT="medium"|'; prep

( : ) & dead_pid=$!; wait "$dead_pid" 2>/dev/null
freshen "$AGENTS/feature-validator.md"
CLAUDE_PID="$dead_pid" role_ro v-g5 smoke-g5
[ "$RC" = 42 ] || fail "G5: 죽은 CLAUDE_PID 에서 rc=$RC"
reset_native
pass "G5: CLAUDE_PID 의 프로세스를 볼 수 없으면 판정하지 않는다(발행)"
CLAUDE_PID="abc" role_ro v-g6 smoke-g6
[ "$RC" = 42 ] || fail "G6: 형식이 틀린 CLAUDE_PID 에서 rc=$RC"
reset_native
pass "G6: 형식이 틀린 CLAUDE_PID 도 판정하지 않는다(발행)"

# ---------- F1~F4: 피처 시작 일괄 준비 ----------
age_all; before="$(mtimes)"
CLAUDE_PID="$FAKE_PID" pf
[ "$RC" = 0 ] && [ "$(mtimes)" = "$before" ] && [ ! -f "$ND/last-rejection.txt" ] || fail "F1: 모든 정의가 등록됐는데 rc=$RC 또는 파일을 다시 씀"
pass "F1: 모든 native 정의가 메인 프로세스보다 먼저 있었으면 통과한다(쓰기 없음)"

RC=0; ( export CLAUDE_PID="$FAKE_PID" FEATURE_NATIVE_AGENTS_DIR="$TMP/agents-f2"; set -e; source "$LOADER"; native_definitions_preflight ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 43 ] && [ "$(rejection_code)" = NATIVE_AGENT_RESTART_REQUIRED ] || fail "F2: 정의를 새로 쓴 일괄 준비가 멈추지 않음(rc=$RC)"
[ "$(grep -o '(이번 실행이 새로 만듦)' "$ND/last-rejection.txt" | wc -l | tr -d ' ')" = 4 ] && [ "$(ls "$TMP/agents-f2" | wc -l | tr -d ' ')" = 4 ] || fail "F2: 네 정의를 모두 쓰고 보고하지 않음"
[ ! -f "$ND/pending.json" ] || fail "F2: 요청을 발행했다"
RC=0; ( export CLAUDE_PID="$FAKE_PID" FEATURE_NATIVE_AGENTS_DIR="$TMP/agents-f2"; set -e; source "$LOADER"; native_definitions_preflight ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 43 ] && grep -q 'feature-designer.md(수정 ' "$ND/last-rejection.txt" || fail "F2: 재시작 없이 다시 실행했는데 통과함(rc=$RC)"
for f in $NATIVE_DEFS; do age "$TMP/agents-f2/$f"; done
RC=0; ( export CLAUDE_PID="$FAKE_PID" FEATURE_NATIVE_AGENTS_DIR="$TMP/agents-f2"; set -e; source "$LOADER"; native_definitions_preflight ) > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 0 ] || fail "F2: 재시작(정의가 프로세스보다 먼저 있음) 뒤에도 rc=$RC"
pass "F2: 정의 디렉터리가 없던 세션 — 일괄로 네 정의를 쓰고 요청 전에 멈춘다. 재시작 없이 재실행하면 다시 멈추고, 재시작 뒤에는 통과한다"
reset_native

freshen "$AGENTS/feature-validator.md"
role_ro v-f3 smoke-f3
[ "$RC" = 42 ] && [ "$(jq -r '.state' "$(req_file)")" = PREPARED ] || fail "F3: 준비 — 요청 발행 실패(rc=$RC)"
f3_req="$(req_file)"
CLAUDE_PID="$FAKE_PID" pf
[ "$RC" = 43 ] && [ "$(rejection_code)" = NATIVE_AGENT_RESTART_REQUIRED ] && grep -q 'PREPARED 그대로 둔다' "$ND/last-rejection.txt" || fail "F3: PREPARED 요청의 정의가 프로세스보다 새것인데 rc=$RC"
[ "$(req_file)" = "$f3_req" ] && [ "$(jq -r '.state' "$f3_req")" = PREPARED ] && [ "$(req_count)" = 1 ] || fail "F3: 요청을 바꾸거나 새로 만들었다"
age "$AGENTS/feature-validator.md"
CLAUDE_PID="$FAKE_PID" pf
[ "$RC" = 0 ] || fail "F3: 재시작 뒤 PREPARED 요청이 통과하지 못함(rc=$RC)"
pass "F3: 처리되지 않은 PREPARED 요청은 쓰지 않고 그 요청의 정의만 본다 — 증거가 없으면 요청을 PREPARED 그대로 두고 멈춘다"

jq '.state="DISPATCHED"' "$f3_req" > "$f3_req.tmp" && mv "$f3_req.tmp" "$f3_req"
setcfg 's|^VALIDATOR_EFFORT=.*|VALIDATOR_EFFORT="high"|'
freshen "$AGENTS/feature-designer.md"
cp "$AGENTS/feature-validator.md" "$TMP/validator.before"
rm -f "$ND/last-rejection.txt"   # F3 의 중단 기록 — 이번 판정만 본다
CLAUDE_PID="$FAKE_PID" pf
[ "$RC" = 0 ] && cmp -s "$AGENTS/feature-validator.md" "$TMP/validator.before" && [ ! -f "$ND/last-rejection.txt" ] || fail "F4: DISPATCHED 요청이 있는데 정의를 쓰거나 멈췄다(rc=$RC)"
pass "F4: DISPATCHING 이후 요청이 있으면 정의를 쓰지도, 재시작을 요구하지도 않는다(돌고 있을 수 있는 Agent 를 건드리지 않는다)"
setcfg 's|^VALIDATOR_EFFORT=.*|VALIDATOR_EFFORT="medium"|'
reset_native

# ---------- L1: 합의 루프 단독 실행 — 남은 PREPARED 요청도 같은 게이트를 받는다 ----------
# feature-run.sh 를 거치지 않으면 native_definitions_preflight 가 없다. 같은 호출 지점의 재실행이 PREPARED 요청의 dispatch 를 다시 안내하기 전에 막아야 한다.
cp -R .agent-work "$TMP/agent-work.before-l1"
LOOP=".claude/skills/feature/scripts/consensus-loop.sh"
loop_run() { RC=0; bash "$LOOP" design > "$TMP/last.log" 2>&1 || RC=$?; }
age_all; freshen "$AGENTS/feature-validator.md"; : > "$CLI_LOG"
loop_run   # CLAUDE_PID 없음(터미널 단독) — 판정 없이 요청 발행
[ "$RC" = 42 ] && [ "$(jq -r '.role' "$(req_file)")" = VALIDATOR ] && [ "$(jq -r '.state' "$(req_file)")" = PREPARED ] || fail "L1: 준비 — 합의 루프가 검증자 요청을 발행하지 않음(rc=$RC)"
l1_req="$(req_file)"; l1_id="$(jq -r '.request_id' "$l1_req")"
CLAUDE_PID="$FAKE_PID" loop_run
[ "$RC" = 43 ] && [ "$(rejection_code)" = NATIVE_AGENT_RESTART_REQUIRED ] && grep -q 'PREPARED 그대로 둔다' "$ND/last-rejection.txt" && grep -q 'feature-validator.md(수정 ' "$ND/last-rejection.txt" \
  || fail "L1: 단독 합의 루프의 재실행이 등록 증거 없는 정의로 PREPARED 요청을 다시 안내함(rc=$RC, $(cat "$ND/last-rejection.txt" 2>/dev/null))"
! grep -q '^\[NATIVE_AGENT_REQUIRED\]' "$TMP/last.log" || fail "L1: 멈추면서 dispatch 안내를 함께 냈다"
[ "$(req_file)" = "$l1_req" ] && [ "$(jq -r '.state' "$l1_req")" = PREPARED ] && [ "$(req_count)" = 1 ] && [ ! -s "$CLI_LOG" ] || fail "L1: 요청을 바꾸거나 새로 만들었거나 CLI 를 불렀다"
age "$AGENTS/feature-validator.md"; rm -f "$ND/last-rejection.txt"
CLAUDE_PID="$FAKE_PID" loop_run
[ "$RC" = 42 ] && grep -q "^\[NATIVE_AGENT_REQUIRED\] request $l1_id " "$TMP/last.log" && [ "$(req_count)" = 1 ] && [ ! -f "$ND/last-rejection.txt" ] \
  || fail "L1: '재시작' 뒤 같은 PREPARED 요청의 dispatch 안내로 돌아오지 않음(rc=$RC)"
pass "L1: 합의 루프 단독 실행 — 남은 PREPARED 요청의 정의가 메인 프로세스보다 새것이면 다시 안내하지 않고 43(요청 PREPARED 그대로·CLI 0회), 재시작 뒤 같은 요청을 안내"
rm -rf .agent-work && cp -R "$TMP/agent-work.before-l1" .agent-work

# ---------- D1~D3: PREPARED 요청의 정의가 없거나 요청 발행 때와 다르면 dispatch 전에 멈춘다(CLAUDE_PID 무관, 요청 PREPARED 유지) ----------
sha_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }
reset_native; age_all
role_ro v-d1 smoke-d1
[ "$RC" = 42 ] && [ "$(jq -r '.state' "$(req_file)")" = PREPARED ] || fail "D1: 준비 — 요청 발행 실패(rc=$RC)"
d_req="$(req_file)"; d_sha="$(jq -r '.agent_definition_sha256' "$d_req")"
mv "$AGENTS/feature-validator.md" "$TMP/validator.d1"
pf   # CLAUDE_PID 없음(터미널 단독)에서도 멈춰야 한다 — 없는 정의는 어느 세션에서도 dispatch 되지 않는다
[ "$RC" = 43 ] && [ "$(rejection_code)" = NATIVE_AGENT_RESTART_REQUIRED ] && grep -q '요청이 가리키는 agent 정의 파일이 없다' "$ND/last-rejection.txt" && grep -q 'prepare-agents' "$ND/last-rejection.txt" \
  || fail "D1: 정의 파일이 없는데 피처 시작 확인이 통과함(rc=$RC, $(cat "$ND/last-rejection.txt" 2>/dev/null))"
CLAUDE_PID="$FAKE_PID" role_ro v-d1 smoke-d1
[ "$RC" = 43 ] && ! grep -q '^\[NATIVE_AGENT_REQUIRED\]' "$TMP/last.log" || fail "D1: 정의 파일이 없는데 같은 호출 지점의 재실행이 dispatch 를 안내함(rc=$RC)"
[ "$(req_file)" = "$d_req" ] && [ "$(jq -r '.state' "$d_req")" = PREPARED ] && [ "$(req_count)" = 1 ] && [ ! -e "$AGENTS/feature-validator.md" ] && [ ! -s "$CLI_LOG" ] \
  || fail "D1: 요청을 바꾸거나 정의를 스스로 썼거나 CLI 를 불렀다"
pass "D1: PREPARED 요청의 정의 파일이 없으면 피처 시작·재실행 모두 dispatch 전에 43(요청 PREPARED 그대로, 정의를 쓰지 않음, 복구 명령 안내)"
prep; [ "$RC" = 0 ] && [ "$(sha_of "$AGENTS/feature-validator.md")" = "$d_sha" ] || fail "D2: 요청 발행 때 설정의 prepare-agents 가 같은 정의를 복구하지 않음(rc=$RC)"
CLAUDE_PID="$FAKE_PID" pf
[ "$RC" = 43 ] && grep -q 'feature-validator.md(수정 ' "$ND/last-rejection.txt" || fail "D2: 복구한(세션보다 새) 정의인데 재시작 없이 통과함(rc=$RC)"
age "$AGENTS/feature-validator.md"; rm -f "$ND/last-rejection.txt"
CLAUDE_PID="$FAKE_PID" pf
[ "$RC" = 0 ] && [ ! -f "$ND/last-rejection.txt" ] || fail "D2: 복구·재시작 뒤에도 통과하지 못함(rc=$RC)"
pass "D2: 요청 발행 때 설정으로 prepare-agents 를 다시 돌리면 같은 정의가 복구되고, 재시작 뒤 통과한다"
setcfg 's|^VALIDATOR_EFFORT=.*|VALIDATOR_EFFORT="high"|'; prep; [ "$RC" = 0 ] || fail "D3: 준비 rc=$RC"
age "$AGENTS/feature-validator.md"
pf
[ "$RC" = 43 ] && grep -q '내용이 요청 발행 때와 다르다' "$ND/last-rejection.txt" && [ "$(jq -r '.state' "$d_req")" = PREPARED ] \
  || fail "D3: 요청 발행 뒤 정의 내용이 바뀌었는데 dispatch 전에 멈추지 않음(rc=$RC, $(cat "$ND/last-rejection.txt" 2>/dev/null))"
setcfg 's|^VALIDATOR_EFFORT=.*|VALIDATOR_EFFORT="medium"|'; prep; age "$AGENTS/feature-validator.md"; rm -f "$ND/last-rejection.txt"
CLAUDE_PID="$FAKE_PID" pf
[ "$RC" = 0 ] || fail "D3: 설정을 되돌려 정의를 복구한 뒤에도 통과하지 못함(rc=$RC)"
pass "D3: 요청 발행 뒤 정의 내용이 바뀌면(설정 변경 + prepare-agents) 등록 증거가 있어도 dispatch 전에 43 — 수용 단계까지 가서 Agent 를 헛돌리지 않는다"
reset_native

# ---------- R1~R2: 실제 feature-run.sh ----------
# 검증자를 codex(유료 호출)로 돌린다 — 게이트가 그 호출보다 먼저 멈춰야 한다
setcfg 's|^VALIDATOR_MODEL=.*|VALIDATOR_MODEL="gpt-6-astra"|'
: > "$CLI_LOG"
RUN=".claude/skills/feature/scripts/feature-run.sh"
RC=0; CLAUDE_PID="$FAKE_PID" FEATURE_NATIVE_AGENTS_DIR="$TMP/agents-r" bash "$RUN" > "$TMP/last.log" 2>&1 || RC=$?
[ "$RC" = 2 ] && [ "$(jq -r '.status' .agent-work/run-state.json)" = NEED_USER ] && [ "$(jq -r '.reason' .agent-work/run-state.json)" = NATIVE_AGENT_RESTART_REQUIRED ] \
  || fail "R1: 러너가 NEED_USER NATIVE_AGENT_RESTART_REQUIRED 로 멈추지 않음(rc=$RC, $(jq -c '{status,reason}' .agent-work/run-state.json 2>/dev/null))"
[ ! -s "$CLI_LOG" ] || fail "R1: 게이트 전에 CLI 를 불렀다: $(cat "$CLI_LOG")"
grep -q '\[SKILL REFERENCE\] NEED_USER(NATIVE_AGENT_RESTART_REQUIRED) — .*references/native-agent.md' "$TMP/last.log" || fail "R1: 참조 문서 안내 없음"
[ "$(ls "$TMP/agents-r" | wc -l | tr -d ' ')" = 3 ] && [ ! -f "$ND/pending.json" ] || fail "R1: native 역할 셋(디자이너·워커·수정자)의 정의를 쓰지 않았거나 요청을 발행했다"
[ "$(jq -r '.stage' .agent-work/run-state.json)" = design ] || fail "R1: 재개 stage 를 보존하지 않음"
pass "R1: 실제 러너 — 처음 쓰는 정의 3개를 일괄로 쓰고, Codex 검증자 호출 전에 NEED_USER NATIVE_AGENT_RESTART_REQUIRED(stage 보존·참조 문서 안내)"
for f in "$TMP/agents-r"/*.md; do age "$f"; done
RC=0; CLAUDE_PID="$FAKE_PID" FEATURE_NATIVE_AGENTS_DIR="$TMP/agents-r" bash "$RUN" > "$TMP/last.log" 2>&1 || RC=$?
[ "$(jq -r '.reason' .agent-work/run-state.json)" != NATIVE_AGENT_RESTART_REQUIRED ] && grep -q codex "$CLI_LOG" \
  || fail "R2: 재시작 뒤에도 게이트를 지나지 못함(rc=$RC, $(jq -c '{status,reason}' .agent-work/run-state.json 2>/dev/null))"
pass "R2: '재시작' 뒤(정의가 프로세스보다 먼저 있음) 같은 명령은 게이트를 지나 검증자를 부른다(rc=$RC, $(jq -r '.status' .agent-work/run-state.json))"

echo "[SMOKE] native Agent 정의 사전 준비·등록 증거 게이트 — 전부 통과"
