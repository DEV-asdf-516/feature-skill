#!/usr/bin/env bash
# =============================================================
# install.sh 스모크 테스트 — LLM CLI 없이 git + jq 만으로 실행
# 사용법: bash tests/install-smoke.sh   (이 저장소 어디서든)
# =============================================================
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
fail() { echo "[FAIL] $1" >&2; exit 1; }
# 계약 버전은 scripts/lib/runtime.sh 에서 읽는다 — 프롬프트 계약이 바뀌어 버전이 오를 때 픽스처가 같이 따라가야 한다
SOURCE_RUNTIME_LIB="$SOURCE_ROOT/.claude/skills/feature/scripts/lib/runtime.sh"
VALIDATOR_CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$SOURCE_RUNTIME_LIB" | cut -d= -f2 | cut -d' ' -f1)"
REVIEWER_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$SOURCE_RUNTIME_LIB" | cut -d= -f2 | cut -d' ' -f1)"
# 합의 PASS 픽스처: 러너의 stage 결정은 파일명이 아니라 consensus-<target>.json 체크포인트(+입력 지문·리뷰 내용)를 본다.
# 가짜 검증자(codex)가 PASS 리뷰를 실제 -o 경로에 쓰게 해 합의 루프를 한 번 돌려 체크포인트를 만든다.
# (read-only 헬퍼는 invocation 전용 임시 -o 만 이번 결과로 인정하므로 미리 깔아 둔 파일·no-op codex 로는 PASS 가 만들어지지 않는다.)
FAKE_PASS_CODEX="$SCRATCH/fake-codex-pass"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'out=""; while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done' \
  '[ -n "$out" ] || exit 9' \
  'printf '\''{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}\n'\'' "$FAKE_PASS_CONTRACT" > "$out"' \
  > "$FAKE_PASS_CODEX"
chmod +x "$FAKE_PASS_CODEX"
fake_consensus_pass() { # target-root design|impl
  local root="$1" t="$2" cfg
  cfg="$root/.claude/skills/feature/config.sh"
  mkdir -p "$root/.agent-work/reviews"
  # impl 은 구현 단위 manifest 가 러너의 진입 조건이다 — 없으면 feature-scope.json 전체를 unit 하나로 두는 최소 manifest 를 만든다
  [ "$t" != impl ] || [ -f "$root/.agent-work/implementation-units.json" ] || fake_units "$root"
  cp "$cfg" "$cfg.fixture-keep"
  sed -i.sedbak "s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$FAKE_PASS_CODEX\"|" "$cfg" && rm -f "$cfg.sedbak"
  (cd "$root" && FAKE_PASS_CONTRACT="$VALIDATOR_CONTRACT" FEATURE_LIVE_TEE=1 bash .claude/skills/feature/scripts/consensus-loop.sh "$t") >/dev/null 2>&1 \
    || { mv "$cfg.fixture-keep" "$cfg"; fail "픽스처: $t 합의 PASS 체크포인트 생성 실패 ($root)"; }
  mv "$cfg.fixture-keep" "$cfg"
}
# 피처 범위 manifest 픽스처 (워커 진입에 필수)
fake_scope() { # target-root file...
  local root="$1"; shift
  printf '%s\n' "$@" | jq -R . | jq -sc '{version:1, files:., new_file_roots:[]}' > "$root/.agent-work/feature-scope.json"
}
# 구현 단위 manifest 픽스처: feature-scope.json 의 files 전체를 unit 하나(01-all)로 — 단일 워커 시절의 동작을 그대로 재현한다
fake_units() { # target-root
  jq -c '{version:1, units:[{id:"01-all", title:"all", goal:"전체", requirements:["REQ-01"], scope:{files:.files, new_file_roots:(.new_file_roots // [])}, references:["implementation.md#all"], targeted_test:"true"}]}' \
    "$1/.agent-work/feature-scope.json" > "$1/.agent-work/implementation-units.json"
}

TARGET="$SCRATCH/target"
TARGET_SKILL="$TARGET/.claude/skills/feature"
TARGET_LOADER="$TARGET_SKILL/scripts/lib/bootstrap.sh"
git init -q "$TARGET"
# 로더는 항상 <스킬>/config.sh 를 읽는다 — 가드(CHANGE_ME)를 지나려면 스킬 디렉터리 사본의 config.sh 를 채우고 그 사본의 로더를 source 한다.
# 대상 config.sh 는 건드리지 않는다. 대상 프로젝트를 봐야 하면 호출 쪽이 FEATURE_PROJECT_ROOT=<대상 루트> 를 준다.
filled_skill_copy() { # skill-dir copy-dir(없는 경로) → stdout: 사본 로더 경로
  mkdir -p "$(dirname "$2")" && cp -R "$1" "$2"
  sed -i.sedbak 's/^TEST_CMD="CHANGE_ME"/TEST_CMD="true"/; s/^LINT_CMD="CHANGE_ME"/LINT_CMD="true"/' "$2/config.sh" && rm -f "$2/config.sh.sedbak"
  printf '%s' "$2/scripts/lib/bootstrap.sh"
}

# ---------- 1. 신규 설치 ----------
bash "$SOURCE_ROOT/install.sh" "$TARGET" >/dev/null
[ -x "$TARGET_SKILL/scripts/consensus-loop.sh" ] || fail "신규 설치: 스크립트 누락/실행권한 없음"
[ -x "$TARGET_SKILL/scripts/feature-run.sh" ] || fail "신규 설치: 러너 누락/실행권한 없음"
[ -f "$TARGET_SKILL/schemas/worker-result.schema.json" ] || fail "신규 설치: 워커 결과 스키마 누락"
[ -x "$TARGET/feature-live" ] || fail "신규 설치: feature-live 누락"
[ -x "$TARGET/.claude/hooks/inject_conventions.sh" ] || fail "신규 설치: conventions 훅 누락/실행권한 없음"
[ -f "$TARGET/.claude/hooks/core_rules.md" ] || fail "신규 설치: core_rules.md 누락"
jq -e '.hooks.UserPromptSubmit and .hooks.PreToolUse' "$TARGET/.claude/settings.json" >/dev/null \
  || fail "신규 설치: settings.json hooks 누락"
# 참조 문서(references/): SKILL.md 가 분기 직전에 읽으라고 가리키는 파일이 전부 설치돼야 한다.
# 목록의 세 출처(SKILL.md 언급 / 소스 references/ 실제 파일 / 러너의 SKILL_REFERENCE_FILES)가 서로 같아야 한다 — 하나만 고치면 여기서 실패한다.
SRC_SKILL="$SOURCE_ROOT/.claude/skills/feature"
refs_in_skill="$(grep -oE 'references/[A-Za-z0-9._-]+\.md' "$SRC_SKILL/SKILL.md" | sed 's|references/||' | sort -u | paste -sd' ' -)"
refs_on_disk="$(cd "$SRC_SKILL/references" && ls *.md | sort | paste -sd' ' -)"
refs_in_runner="$(sed -n 's/^SKILL_REFERENCE_FILES="\(.*\)"$/\1/p' "$SRC_SKILL/scripts/feature-run.sh" | tr ' ' '\n' | sort | paste -sd' ' -)"
[ -n "$refs_in_skill" ] && [ "$refs_in_skill" = "$refs_on_disk" ] && [ "$refs_in_skill" = "$refs_in_runner" ] \
  || fail "참조 문서 목록 불일치 — SKILL.md 언급($refs_in_skill) / references/ 파일($refs_on_disk) / 러너 목록($refs_in_runner)"
for ref in $refs_in_skill; do
  cmp -s "$SRC_SKILL/references/$ref" "$TARGET_SKILL/references/$ref" || fail "신규 설치: 참조 문서 누락/불일치: references/$ref"
done
[ -x "$TARGET/.claude/hooks/compact_recovery.sh" ] || fail "신규 설치: 압축 복구 훅(compact_recovery.sh) 누락/실행권한 없음"
jq -e '[.hooks.SessionStart[]? | select(.matcher == "compact") | .hooks[]? | select(.type == "command" and (.command | endswith("/.claude/hooks/compact_recovery.sh")))] | length == 1' \
  "$TARGET/.claude/settings.json" >/dev/null || fail "신규 설치: settings.json 에 SessionStart(compact) → compact_recovery.sh 미등록"
# CHANGE_ME 가드를 지나려면 값을 채운 스킬 사본의 로더를 쓴다 (대상 설정 파일은 건드리지 않는다)
NEW_COPY_LOADER="$(filled_skill_copy "$TARGET_SKILL" "$SCRATCH/new-install-copy/feature")"
worker_rules="$(FEATURE_PROJECT_ROOT="$TARGET" bash -c 'source "$1"; load_worker_rules' _ "$NEW_COPY_LOADER")" || fail "신규 설치: load_worker_rules 실패"
grep -q '\[WORKER SKILL:' <<< "$worker_rules" && fail "신규 설치: 기본 설정에서 워커 스킬이 주입됨 (WORKER_SKILLS 는 비어 있어야 함)"
echo "[OK] 1. 신규 설치"

# ---------- 1b. 신규 설치 = 설정 전용 config.sh + 런타임 모듈 전부 + 기본 backend native/app_server ----------
cmp -s "$SRC_SKILL/config.sh" "$TARGET_SKILL/config.sh" || fail "신규 설치: 대상 config.sh 가 소스 템플릿과 다름"
( source "$SRC_SKILL/scripts/lib/config-layout.sh"; feature_config_runtime_lines "$TARGET_SKILL/config.sh" >/dev/null ) \
  || fail "신규 설치: 대상 config.sh 가 설정 전용 판정(반환 0)을 통과하지 못함"
diff -r "$SRC_SKILL/scripts/lib" "$TARGET_SKILL/scripts/lib" >/dev/null || fail "신규 설치: 소스 scripts/lib/ 와 대상 scripts/lib/ 가 파일 단위로 다름"
new_backends="$(FEATURE_PROJECT_ROOT="$TARGET" bash -c 'source "$1"; printf "%s|%s" "$(role_backend WORKER)" "$(role_backend VALIDATOR)"' _ "$NEW_COPY_LOADER")"
[ "$new_backends" = "claude_native|codex_app_server" ] || fail "신규 설치: 기본 backend 가 native/app_server 가 아님 ($new_backends)"
echo "[OK] 1b. 신규 설치 — 설정 전용 config·런타임 모듈 전부·기본 backend native/app_server"

# ---------- 2. 재실행 멱등성 ----------
rerun_output="$(bash "$SOURCE_ROOT/install.sh" "$TARGET")"
grep -q WARN <<< "$rerun_output" && fail "재실행: 변경 없는데 WARN 발생"
echo "[OK] 2. 재실행 멱등성"

# ---------- 3. 사용자 수정 보존 (+ .new 생성) ----------
sed -i.sedbak 's/^TEST_CMD=.*/TEST_CMD="npm test"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
printf '# 프로젝트 커스텀 규칙\n' >> "$TARGET/.claude/hooks/core_rules.md"
bash "$SOURCE_ROOT/install.sh" "$TARGET" >/dev/null
grep -q 'npm test' "$TARGET_SKILL/config.sh" || fail "수정 보존: config.sh 덮어써짐"
grep -q '커스텀 규칙' "$TARGET/.claude/hooks/core_rules.md" || fail "수정 보존: core_rules.md 덮어써짐"
[ -f "$TARGET_SKILL/config.sh.new" ] || fail "수정 보존: config.sh.new 미생성"
echo "[OK] 3. 사용자 수정 보존 + .new"

# ---------- 3a. 프로젝트 빠른 검사 설정 줄이 없는 기존 config.sh(이 기능 이전 설치) → 병합 없이 업데이트, 미설정으로 유지 ----------
# 헬퍼는 scripts/fast-check.sh 에 있으므로 옛 config.sh 본문과 섞여도 혼합 설치가 아니다: 사전 검사(헬퍼 이름·버전 상수)를 통과하고,
# 사용자 설정은 그대로이며, 설정 줄을 대신 써 넣지 않는다(미설정 = 검사 생략). 새 스크립트·프롬프트는 설치되고 안내는 INFO 한 번뿐이다.
cp "$TARGET_SKILL/config.sh" "$SCRATCH/config.with-fast-check"
grep -v '^FAST_CHECK_' "$SCRATCH/config.with-fast-check" > "$TARGET_SKILL/config.sh"
legacy_output="$(bash "$SOURCE_ROOT/install.sh" "$TARGET" 2>&1)" || fail "빠른 검사 설정 줄이 없는 기존 config 에서 설치가 실패함: $legacy_output"
grep -q 'npm test' "$TARGET_SKILL/config.sh" || fail "빠른 검사 미설정 config: 사용자 설정(TEST_CMD)이 보존되지 않음"
grep -q '^FAST_CHECK_' "$TARGET_SKILL/config.sh" && fail "빠른 검사 미설정 config: 설치가 사용자 config 에 설정 줄을 써 넣음"
grep -q '^FAST_CHECK_CMD=""$' "$TARGET_SKILL/config.sh.new" || fail "config.sh.new 에 FAST_CHECK_CMD 기본값(빈 값 = 미설정)이 없음"
[ -x "$TARGET_SKILL/scripts/fast-check.sh" ] && [ -f "$TARGET_SKILL/prompts/worker-check-fix.md" ] || fail "빠른 검사 스크립트·프롬프트가 설치되지 않음"
grep -q "\[INFO\] 선택 기능 '프로젝트 빠른 검사' 미설정" <<< "$legacy_output" || fail "빠른 검사 미설정 안내(INFO)가 없음"
grep -q '\[FAIL\]' <<< "$legacy_output" && fail "빠른 검사 미설정 config 를 혼합 설치로 오판함"
# Unit 정적 검사·위험도별 추가 검증도 같다: 설정 줄이 없는 기존 config.sh 는 병합 없이 업데이트되고(혼합 설치 아님), 설정 줄을 대신 써 넣지 않으며, 새 스크립트는 설치된다.
grep -v '^UNIT_CHECK_\|^RISK_VERIFY_' "$SCRATCH/config.with-fast-check" > "$TARGET_SKILL/config.sh"
gates_output="$(bash "$SOURCE_ROOT/install.sh" "$TARGET" 2>&1)" || fail "검증 게이트 설정 줄이 없는 기존 config 에서 설치가 실패함: $gates_output"
grep -q '^UNIT_CHECK_\|^RISK_VERIFY_' "$TARGET_SKILL/config.sh" && fail "검증 게이트 미설정 config: 설치가 사용자 config 에 설정 줄을 써 넣음"
grep -q '^UNIT_CHECK_CMD=""$' "$TARGET_SKILL/config.sh.new" && grep -q '^RISK_VERIFY_CMD=""$' "$TARGET_SKILL/config.sh.new" || fail "config.sh.new 에 UNIT_CHECK_CMD/RISK_VERIFY_CMD 기본값(빈 값 = 미설정)이 없음"
[ -x "$TARGET_SKILL/scripts/post-run-report.sh" ] && grep -q '^unit_check_run()' "$TARGET_SKILL/scripts/fast-check.sh" && grep -q '^risk_verify_run()' "$TARGET_SKILL/scripts/fast-check.sh" \
  || fail "검증 게이트·사후 분석 스크립트가 설치되지 않음"
grep -q "\[INFO\] 선택 기능 'Unit 정적 검사'·'위험도별 추가 검증' 미설정" <<< "$gates_output" || fail "검증 게이트 미설정 안내(INFO)가 없음"
grep -q '\[FAIL\]' <<< "$gates_output" && fail "검증 게이트 미설정 config 를 혼합 설치로 오판함"
cp "$SCRATCH/config.with-fast-check" "$TARGET_SKILL/config.sh"
bash "$SOURCE_ROOT/install.sh" "$TARGET" 2>&1 | grep -q "프로젝트 빠른 검사' 미설정\|'위험도별 추가 검증' 미설정" && fail "설정 줄이 있는 config 인데 미설정 안내가 나옴"
echo "[OK] 3a. 빠른 검사 설정 줄 없는 기존 config — 병합 없이 업데이트·사용자 설정 보존·설정 줄 미삽입·INFO 안내"

# ---------- 3b. 역할별 모델/effort + 선택 conventions 규칙 병합 ----------
sed -i.sedbak 's/^LINT_CMD=.*/LINT_CMD="true"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^WORKER_EFFORT=.*/WORKER_EFFORT="high"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^REVIEWER_EFFORT=.*/REVIEWER_EFFORT="low"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^FIXER_EFFORT=.*/FIXER_EFFORT="high"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
role_efforts="$(bash -c 'source "$1"; printf "%s|%s|%s|%s|%s" "$DESIGNER_EFFORT" "$VALIDATOR_EFFORT" "$WORKER_EFFORT" "$REVIEWER_EFFORT" "$FIXER_EFFORT"' _ "$TARGET_LOADER")"
# 디자이너·검증자 effort 는 소스 config.sh 값을 그대로 기대한다(프로젝트별로 바꾸는 값이라 고정 문자열로 두지 않는다)
src_designer_effort="$(sed -n 's/^DESIGNER_EFFORT="\([^"]*\)".*/\1/p' "$SOURCE_ROOT/.claude/skills/feature/config.sh")"
src_validator_effort="$(sed -n 's/^VALIDATOR_EFFORT="\([^"]*\)".*/\1/p' "$SOURCE_ROOT/.claude/skills/feature/config.sh")"
[ "$role_efforts" = "$src_designer_effort|$src_validator_effort|high|low|high" ] || fail "역할별 effort: config 값이 독립적으로 적용되지 않음 ($role_efforts, 기대 $src_designer_effort|$src_validator_effort|high|low|high)"
conventions_without_file="$(bash -c 'source "$1"; load_project_conventions' _ "$TARGET_LOADER")"
[ -z "$conventions_without_file" ] || fail "규칙 병합: conventions.md가 없는데 내용이 생성됨"
worker_rules_without_conventions="$(bash -c 'source "$1"; load_worker_rules' _ "$TARGET_LOADER")"
grep -q '커스텀 규칙' <<< "$worker_rules_without_conventions" || fail "워커 규칙: core_rules.md 누락"
grep -q '\[PROJECT CONVENTIONS\]' <<< "$worker_rules_without_conventions" \
  && fail "워커 규칙: conventions.md가 없는데 구획이 생성됨"
printf '# 프로젝트 컨벤션\n' > "$TARGET/conventions.md"
conventions_with_file="$(bash -c 'source "$1"; load_project_conventions' _ "$TARGET_LOADER")"
grep -q '\[PROJECT CONVENTIONS\]' <<< "$conventions_with_file" || fail "규칙 병합: conventions 구획 누락"
grep -q '프로젝트 컨벤션' <<< "$conventions_with_file" || fail "규칙 병합: conventions.md 내용 누락"
grep -q '커스텀 규칙' <<< "$conventions_with_file" && fail "규칙 분리: core_rules.md가 비워커 규칙에 포함됨"
# 오케스트레이터 훅: 세션당 첫 프롬프트에만 주입(마커는 TMPDIR), 같은 session_id 재호출·--resume 은 무출력, 다른 세션은 다시 주입.
# 파이프라인 child(FEATURE_ROLE_CHILD=1)는 새 세션이어도 무출력 — run_*_role 이 이미 명시 전달한다. session_id 없는 수동 실행은 매번 주입.
HOOK_TMP="$SCRATCH/hook-tmp"; mkdir -p "$HOOK_TMP"
run_conventions_hook() { # session-json → stdout
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$TARGET" TMPDIR="$HOOK_TMP" bash "$TARGET/.claude/hooks/inject_conventions.sh"
}
orchestrator_rules="$(run_conventions_hook '{"session_id":"orch-1","prompt":"hi"}')"
grep -q '프로젝트 컨벤션' <<< "$orchestrator_rules" || fail "오케스트레이터 규칙: conventions.md 누락"
grep -q '커스텀 규칙' <<< "$orchestrator_rules" && fail "오케스트레이터 규칙: core_rules.md가 주입됨"
[ -z "$(run_conventions_hook '{"session_id":"orch-1","prompt":"second turn"}')" ] || fail "오케스트레이터 규칙: 같은 세션 두 번째 턴에 conventions 가 다시 주입됨"
run_conventions_hook '{"session_id":"orch-2"}' | grep -q '프로젝트 컨벤션' || fail "오케스트레이터 규칙: 다른 세션에 주입되지 않음"
[ -z "$(printf '%s' '{"session_id":"child-1"}' | FEATURE_ROLE_CHILD=1 CLAUDE_PROJECT_DIR="$TARGET" TMPDIR="$HOOK_TMP" bash "$TARGET/.claude/hooks/inject_conventions.sh")" ] \
  || fail "child 중복 주입: FEATURE_ROLE_CHILD=1 인데 훅이 conventions 를 출력함"
[ ! -e "$HOOK_TMP/claude-conventions-injected/child-1" ] || fail "child 중복 주입: child 호출이 세션 마커를 남김"
run_conventions_hook '{}' | grep -q '프로젝트 컨벤션' || fail "오케스트레이터 규칙: session_id 없는 호출이 주입하지 않음"
run_conventions_hook '{}' | grep -q '프로젝트 컨벤션' || fail "오케스트레이터 규칙: session_id 없는 재호출이 주입하지 않음"
# 압축 복구 훅(SessionStart, source=compact): 세션당 1회 주입 정책은 그대로 두고 압축 직후에만 복구 지침을 넣는다.
run_compact_hook() { # project-dir stdin-json [env...] → stdout
  local dir="$1" json="$2"; shift 2
  printf '%s' "$json" | env "$@" CLAUDE_PROJECT_DIR="$dir" TMPDIR="$HOOK_TMP" bash "$dir/.claude/hooks/compact_recovery.sh"
}
(cd "$TARGET" && git add -A >/dev/null 2>&1 && git -c user.email=smoke@test -c user.name=smoke commit -qm fixture >/dev/null 2>&1) || fail "압축 복구 훅: 픽스처 커밋 실패"
compact_out="$(run_compact_hook "$TARGET" '{"session_id":"orch-1","hook_event_name":"SessionStart","source":"compact"}')"
grep -q "$TARGET_SKILL/SKILL.md" <<< "$compact_out" && grep -q "$TARGET_SKILL/references/" <<< "$compact_out" \
  || fail "압축 복구 훅: SKILL.md·references 재확인 지침(절대 경로)이 없음"
# conventions 는 본문이 아니라 경로 + 재확인 지침만 싣는다(훅 출력은 10,000자를 넘으면 잘려 전달된다 — 크기와 무관하게 다시 읽게 한다)
grep -q "$TARGET/conventions.md 를 Read 로" <<< "$compact_out" || fail "압축 복구 훅: 피처 worktree 가 없는데 프로젝트 conventions.md 경로·재확인 지침이 없음"
grep -q '프로젝트 컨벤션' <<< "$compact_out" && fail "압축 복구 훅: conventions 본문을 출력에 실음(경로만 줘야 한다)"
# 큰 conventions.md(10,000자 초과)여도 출력은 한도보다 충분히 작고 본문이 섞이지 않는다
cp "$TARGET/conventions.md" "$SCRATCH/conventions.keep"
awk 'BEGIN { for (i = 0; i < 400; i++) print "- BIG-CONV-RULE 아주 긴 프로젝트 규칙 본문 " i }' >> "$TARGET/conventions.md"
[ "$(wc -m < "$TARGET/conventions.md" | tr -d ' ')" -gt 10000 ] || fail "압축 복구 훅: 큰 conventions 픽스처가 10,000자를 넘지 않음"
compact_big_out="$(run_compact_hook "$TARGET" '{"session_id":"orch-1","source":"compact"}')"
compact_big_chars="$(printf '%s' "$compact_big_out" | wc -m | tr -d ' ')"
[ "$compact_big_chars" -lt 5000 ] || fail "압축 복구 훅: 출력이 ${compact_big_chars}자 — 훅 출력 한도(10,000자)에 가깝다"
grep -q 'BIG-CONV-RULE' <<< "$compact_big_out" && fail "압축 복구 훅: 큰 conventions 본문이 출력에 실림"
grep -q "$TARGET/conventions.md 를 Read 로" <<< "$compact_big_out" || fail "압축 복구 훅: 큰 conventions 에서 경로 안내가 없음"
cp "$SCRATCH/conventions.keep" "$TARGET/conventions.md"
grep -q '커스텀 규칙' <<< "$compact_out" && fail "압축 복구 훅: core_rules.md 가 오케스트레이터에 주입됨"
# 같은 세션의 후속 프롬프트: 압축 뒤에도 UserPromptSubmit 훅은 다시 주입하지 않는다(반복 주입 없음 — 복구는 compact 훅 1회뿐)
[ -z "$(run_conventions_hook '{"session_id":"orch-1","prompt":"after compact"}')" ] || fail "압축 복구 훅: 압축 뒤 UserPromptSubmit 훅이 conventions 를 다시 주입함"
# compact 가 아닌 SessionStart(startup/resume/clear)·source 없는 호출: 무출력(matcher 없이 등록돼도 반복 주입하지 않는다)
for src in startup resume clear; do
  src_json="$(jq -cn --arg s "$src" '{session_id:"orch-1", source:$s}')"
  src_out="$(run_compact_hook "$TARGET" "$src_json")"
  [ -z "$src_out" ] || fail "압축 복구 훅: source=$src 인데 출력함"
done
[ -z "$(run_compact_hook "$TARGET" '{"session_id":"orch-1"}')" ] || fail "압축 복구 훅: source 없는 호출인데 출력함"
# child(FEATURE_ROLE_CHILD=1): 무출력
[ -z "$(run_compact_hook "$TARGET" '{"session_id":"child-1","source":"compact"}' FEATURE_ROLE_CHILD=1)" ] || fail "압축 복구 훅: child 호출에 중복 주입"
# 피처 worktree 가 있으면: 원본 conventions 본문을 넣지 않고(worktree 의 더 최신 규칙을 덮어쓰지 않는다) worktree 사본 경로만 알려 준다
COMPACT_WT="$SCRATCH/target-feature-wt1"
git -C "$TARGET" worktree add -q -b feature/wt1 "$COMPACT_WT" HEAD >/dev/null 2>&1 || fail "압축 복구 훅: 픽스처 worktree 생성 실패"
printf '# worktree 최신 컨벤션 WT-ONLY-RULE\n' > "$COMPACT_WT/conventions.md"
compact_wt_out="$(run_compact_hook "$TARGET" '{"session_id":"orch-1","source":"compact"}')"
grep -q '프로젝트 컨벤션' <<< "$compact_wt_out" && fail "압축 복구 훅: 피처 worktree 가 있는데 원본 conventions 본문을 주입함(잘못된 worktree 규칙 적용)"
grep -q 'WT-ONLY-RULE' <<< "$compact_wt_out" && fail "압축 복구 훅: 임의로 고른 worktree 의 conventions 본문을 주입함"
grep -q "feature-wt1/conventions.md" <<< "$compact_wt_out" && grep -q '임의로 고르지 말고' <<< "$compact_wt_out" \
  || fail "압축 복구 훅: 피처 worktree conventions 경로·재확인 지침이 없음"
# 피처 worktree 가 많아도 후보 목록은 상한까지만 나열하고 출력은 한도보다 충분히 작다
for i in $(seq 2 26); do git -C "$TARGET" worktree add -q -b "feature/wt$i" "$SCRATCH/target-feature-wt$i" HEAD >/dev/null 2>&1 || fail "압축 복구 훅: 픽스처 worktree $i 생성 실패"; done
compact_many_out="$(run_compact_hook "$TARGET" '{"session_id":"orch-1","source":"compact"}')"
[ "$(echo "$compact_many_out" | grep -c '/conventions.md$')" = 20 ] && grep -q '외 6개' <<< "$compact_many_out" \
  || fail "압축 복구 훅: worktree 후보 목록 상한(20개 + 나머지 개수)이 지켜지지 않음"
[ "$(printf '%s' "$compact_many_out" | wc -m | tr -d ' ')" -lt 8000 ] || fail "압축 복구 훅: worktree 가 많을 때 출력이 훅 한도에 가깝다"
for i in $(seq 2 26); do git -C "$TARGET" worktree remove --force "$SCRATCH/target-feature-wt$i" >/dev/null 2>&1; git -C "$TARGET" branch -q -D "feature/wt$i" >/dev/null 2>&1 || true; done
git -C "$TARGET" worktree remove --force "$COMPACT_WT" >/dev/null 2>&1; git -C "$TARGET" branch -q -D feature/wt1 >/dev/null 2>&1 || true
# conventions.md 부재: 스킬 복구 지침만, conventions 블록 없음, exit 0
NOCONV_TARGET="$SCRATCH/noconv"; git init -q "$NOCONV_TARGET"; bash "$SOURCE_ROOT/install.sh" "$NOCONV_TARGET" >/dev/null
noconv_out="$(run_compact_hook "$NOCONV_TARGET" '{"session_id":"x","source":"compact"}')" || fail "압축 복구 훅: conventions.md 부재에서 non-zero 종료"
grep -q 'references/' <<< "$noconv_out" || fail "압축 복구 훅: conventions.md 부재에서 스킬 복구 지침이 없음"
grep -q 'PROJECT CONVENTIONS\|conventions:' <<< "$noconv_out" && fail "압축 복구 훅: conventions.md 가 없는데 conventions 안내가 출력됨"
[ -z "$(printf '%s' '{"session_id":"x"}' | CLAUDE_PROJECT_DIR="$NOCONV_TARGET" TMPDIR="$HOOK_TMP" bash "$NOCONV_TARGET/.claude/hooks/inject_conventions.sh")" ] \
  || fail "conventions 훅: conventions.md 부재인데 출력함"
# run_*_role 의 claude 호출은 FEATURE_ROLE_CHILD=1 을 붙인다 (두 헬퍼 모두)
[ "$(grep -c 'FEATURE_ROLE_CHILD=1 "\$CLAUDE_BIN" -p' "$TARGET_SKILL/scripts/lib/backend/router.sh")" = 2 ] || fail "child 중복 주입: run_readonly_json_role/run_edit_role 의 claude 호출에 FEATURE_ROLE_CHILD=1 누락"
grep -Fq '${WORKER_RULES}' "$TARGET_SKILL/prompts/worker-unit.md" || fail "규칙 전달: unit 워커 프롬프트 누락"
grep -Fq '${WORKER_RULES}' "$TARGET_SKILL/prompts/worker-unit-fix.md" || fail "규칙 전달: unit 수정 프롬프트 누락"
grep -Fq '${PROJECT_CONVENTIONS}' "$TARGET_SKILL/prompts/validator-review-design.md" || fail "규칙 전달: 검증자 conventions 누락"
grep -Fq '${PROJECT_CONVENTIONS}' "$TARGET_SKILL/prompts/validator-review-impl.md" || fail "규칙 전달: impl 검증자 conventions 누락"
# 검증자 프로필 오버레이: 세 프로필 파일이 설치되고, 모델별 기본 매핑·명시 프로필·none·오타 실패가 동작하는지
for ov in compact guided conservative; do
  [ -f "$TARGET_SKILL/prompts/validator-overlays/$ov.md" ] || fail "검증자 오버레이 미설치: $ov.md"
done
overlay_sol="$(bash -c 'source "$1"; VALIDATOR_MODEL=gpt-5.6-sol VALIDATOR_PROFILE=""; load_validator_overlay' _ "$TARGET_LOADER")"
grep -q '^\[VALIDATOR PROFILE: compact\]$' <<< "$overlay_sol" || fail "검증자 프로필: sol 기본값이 compact 가 아님"
# 모델별 기본 매핑: gpt-6-astra 는 guided 여야 한다(매핑 누락으로 conservative 로 떨어지던 문제), 매핑에 없는 모델만 conservative
[ "$(bash -c 'source "$1"; VALIDATOR_MODEL=gpt-6-astra VALIDATOR_PROFILE=""; validator_profile' _ "$TARGET_LOADER")" = guided ] || fail "검증자 프로필: gpt-6-astra 기본값이 guided 가 아님"
[ "$(bash -c 'source "$1"; VALIDATOR_MODEL=gpt-6.2-astra VALIDATOR_PROFILE=""; validator_profile' _ "$TARGET_LOADER")" = guided ] || fail "검증자 프로필: gpt-6.2-astra 기본값이 guided 가 아님"
[ "$(bash -c 'source "$1"; VALIDATOR_MODEL=some-unknown-model VALIDATOR_PROFILE=""; validator_profile' _ "$TARGET_LOADER")" = conservative ] || fail "검증자 프로필: 매핑에 없는 모델의 기본값이 conservative 가 아님"
# 배포 기본값: 명시 프로필 guided · effort medium, 그리고 명시 프로필과 그 모델의 매핑 기본값이 서로 모순되지 않는다
src_validator_profile="$(sed -n 's/^VALIDATOR_PROFILE="\([^"]*\)".*/\1/p' "$SOURCE_ROOT/.claude/skills/feature/config.sh")"
[ "$src_validator_effort" = medium ] || fail "검증자 설정: 배포 VALIDATOR_EFFORT 가 medium 이 아님 ($src_validator_effort)"
[ "$src_validator_profile" = guided ] || fail "검증자 설정: 배포 VALIDATOR_PROFILE 이 guided 가 아님 ($src_validator_profile)"
src_validator_model="$(sed -n 's/^VALIDATOR_MODEL="\([^"]*\)".*/\1/p' "$SOURCE_ROOT/.claude/skills/feature/config.sh")"
[ "$(bash -c 'source "$1"; VALIDATOR_MODEL="$2" VALIDATOR_PROFILE=""; validator_profile' _ "$TARGET_LOADER" "$src_validator_model")" = "$src_validator_profile" ] \
  || fail "검증자 설정: 배포 VALIDATOR_MODEL($src_validator_model)의 매핑 기본값이 명시 VALIDATOR_PROFILE($src_validator_profile)과 다름"
overlay_explicit="$(bash -c 'source "$1"; VALIDATOR_MODEL=gpt-5.6-sol VALIDATOR_PROFILE=guided; load_validator_overlay' _ "$TARGET_LOADER")"
grep -q '^\[VALIDATOR PROFILE: guided\]$' <<< "$overlay_explicit" || fail "검증자 프로필: 명시 VALIDATOR_PROFILE 이 모델 기본값을 덮지 않음"
overlay_none="$(bash -c 'source "$1"; VALIDATOR_PROFILE=none; load_validator_overlay' _ "$TARGET_LOADER")"
[ -z "$overlay_none" ] || fail "검증자 프로필: none 인데 오버레이가 출력됨"
bash -c 'source "$1"; VALIDATOR_PROFILE=no-such-profile; load_validator_overlay' _ "$TARGET_LOADER" >/dev/null 2>&1 \
  && fail "검증자 프로필: 없는 프로필이 조용히 생략됨"
grep -Fq 'VALIDATOR_OVERLAY="$(load_validator_overlay)" || exit 1' "$TARGET_SKILL/scripts/consensus-loop.sh" || fail "검증자 프로필: consensus-loop 오버레이 로딩 누락"
grep -Fq '"$VALIDATOR_OVERLAY"' "$TARGET_SKILL/scripts/consensus-loop.sh" || fail "검증자 프로필: 오버레이가 검증자 프롬프트에 붙지 않음"
# conventions 는 역할 호출 헬퍼(config.sh)로 전달된다 — claude 는 --append-system-prompt, codex 는 프롬프트 앞 블록.
grep -Fq 'run_readonly_json_role REVIEWER "reviewer-a$attempt_tag"' "$TARGET_SKILL/scripts/impl-review-loop.sh" \
  && grep -Eq 'run_readonly_json_role REVIEWER .*"\$PROJECT_CONVENTIONS"' "$TARGET_SKILL/scripts/impl-review-loop.sh" \
  && grep -Fq 'run_edit_role FIXER "fixer-a$attempt_tag"' "$TARGET_SKILL/scripts/impl-review-loop.sh" \
  && grep -Eq 'run_edit_role FIXER .*"\$PROJECT_CONVENTIONS"' "$TARGET_SKILL/scripts/impl-review-loop.sh" \
  && grep -Fq 'run_readonly_json_role VALIDATOR "validator-$TARGET-round-$tag-$(new_invocation_id)"' "$TARGET_SKILL/scripts/consensus-loop.sh" \
  && grep -Fq 'run_edit_role DESIGNER "designer-$TARGET"' "$TARGET_SKILL/scripts/consensus-loop.sh" \
  && grep -Fq -- '--append-system-prompt "$conv"' "$TARGET_SKILL/scripts/lib/backend/router.sh" \
  || fail "규칙 전달: 리뷰어/수정자 conventions 전달 누락 또는 세션 이름이 stage/attempt 단위(합의 검증자는 호출별 fresh)가 아님"
# 컨벤션 파일 경로는 본문과 별개로 리뷰어·수정자 프롬프트에 치환된다(basis_refs 인용용). 본문은 여전히 PROJECT_CONVENTIONS 한 번만.
grep -Fq '${CONVENTIONS_FILE}' "$TARGET_SKILL/prompts/reviewer.md" || fail "컨벤션 경로: reviewer.md 에 \${CONVENTIONS_FILE} 없음"
grep -Fq '${CONVENTIONS_FILE}' "$TARGET_SKILL/prompts/fixer.md" || fail "컨벤션 경로: fixer.md 에 \${CONVENTIONS_FILE} 없음"
grep -Fq 'CONVENTIONS_FILE="$CONVENTIONS_REF"' "$TARGET_SKILL/scripts/impl-review-loop.sh" \
  && [ "$(grep -c 'CONVENTIONS_FILE="$CONVENTIONS_REF"' "$TARGET_SKILL/scripts/impl-review-loop.sh")" = 2 ] \
  || fail "컨벤션 경로: impl-review-loop 가 리뷰어·수정자 render_prompt 에 CONVENTIONS_FILE 을 넘기지 않음"
grep -Fq '${PROJECT_CONVENTIONS}' "$TARGET_SKILL/prompts/reviewer.md" && fail "컨벤션 중복 주입: reviewer.md 가 본문을 다시 치환함"
grep -Fq '${PROJECT_CONVENTIONS}' "$TARGET_SKILL/prompts/fixer.md" && fail "컨벤션 중복 주입: fixer.md 가 본문을 다시 치환함"
# 역할 → CLI 라우팅: 모델 이름으로 claude/codex 를 고르고, <ROLE>_CLI 로 덮어쓸 수 있으며, 알 수 없는 이름은 실패한다.
routing="$(bash -c 'source "$1"
  a=$(REVIEWER_MODEL=gpt-6-astra REVIEWER_CLI="" role_cli REVIEWER)
  b=$(REVIEWER_MODEL=claude-sonnet-5 REVIEWER_CLI="" role_cli REVIEWER)
  c=$(WORKER_MODEL=o4-mini WORKER_CLI="" role_cli WORKER)
  d=$(WORKER_MODEL=mystery-1 WORKER_CLI=claude role_cli WORKER)
  e=$(WORKER_MODEL=mystery-1 WORKER_CLI="" role_cli WORKER 2>/dev/null || echo FAIL)
  f=$(WORKER_MODEL=gpt-5.6-luna WORKER_CLI=gemini role_cli WORKER 2>/dev/null || echo FAIL)
  printf "%s|%s|%s|%s|%s|%s" "$a" "$b" "$c" "$d" "$e" "$f"' _ "$TARGET_LOADER")"
[ "$routing" = "codex|claude|codex|claude|FAIL|FAIL" ] || fail "역할 → CLI 라우팅 오류: $routing"
grep -Fq 'require_role_bins REVIEWER FIXER' "$TARGET_SKILL/scripts/impl-review-loop.sh" || fail "설치 확인이 설정된 역할의 CLI 를 따르지 않음(impl-review-loop)"
grep -Fq 'require_role_bins DESIGNER VALIDATOR WORKER REVIEWER FIXER' "$TARGET_SKILL/scripts/feature-run.sh" || fail "설치 확인이 설정된 역할의 CLI 를 따르지 않음(feature-run)"
grep -Fq '.blocking_issues[]?' "$TARGET_SKILL/scripts/consensus-loop.sh" || fail "관찰성: 상세 blocking 이슈 출력 누락"
grep -q 'decisions_lines_before' "$TARGET_SKILL/scripts/consensus-loop.sh" || fail "관찰성: 신규 결정 출력 누락"
echo "[OK] 3b. 역할별 모델/effort + 역할→CLI 라우팅 + 선택 conventions + 합의 로그"

# ---------- 4. 비호환 구버전 config(구 헬퍼 본문이 섞임) → 활성 코드 교체 전 중단 ----------
printf 'TEST_CMD="npm test"\nLINT_CMD="true"\nrender_prompt() { :; }\n' > "$TARGET_SKILL/config.sh"
printf 'sentinel\n' > "$TARGET_SKILL/scripts/.pre-update-sentinel"
if bash "$SOURCE_ROOT/install.sh" "$TARGET" >/dev/null 2>&1; then
  fail "비호환 config: 중단 없이 성공함"
fi
[ -f "$TARGET_SKILL/scripts/.pre-update-sentinel" ] || fail "비호환 config: 중단 전에 활성 코드가 교체됨"
ls "$TARGET_SKILL"/.install-stage-* >/dev/null 2>&1 && fail "비호환 config: 스테이징 잔여물 남음"
echo "[OK] 4. 비호환 config 사전 중단 (활성 코드 무손상)"

# ---------- 4a. 사용자 설정 + 구 설정 요소 하나가 남은 config → 혼합 설치 차단, 사용자 모델 설정 보존 ----------
# (a) 함수 정의 (b) 런타임 계약 표식 (c) 옛 계약 버전 상수 (d) 경로 초기화 — 넷 다 활성 코드 교체 전에 중단하고 config.sh.new 를 준다
for stale_edit in 'render_prompt() { :; }' 'FEATURE_RUNTIME_CONTRACT_VERSION=3' "VALIDATOR_CONTRACT_VERSION=$((VALIDATOR_CONTRACT - 1))" 'PROJECT_ROOT="$(cd "$FEATURE_SKILL_DIR/../../.." && pwd)"'; do
  { sed -e 's/^WORKER_MODEL=.*/WORKER_MODEL="my-custom-worker-model"/' -e 's/^TEST_CMD=.*/TEST_CMD="npm test"/' "$SRC_SKILL/config.sh"; printf '%s\n' "$stale_edit"; } > "$TARGET_SKILL/config.sh"
  rm -f "$TARGET_SKILL/config.sh.new"
  printf 'sentinel\n' > "$TARGET_SKILL/scripts/.pre-update-sentinel"
  if bash "$SOURCE_ROOT/install.sh" "$TARGET" > "$SCRATCH/mixed.log" 2>&1; then fail "혼합 버전($stale_edit): 옛 본문 config 인데 중단 없이 설치됨"; fi
  grep -q '혼합 설치 방지' "$SCRATCH/mixed.log" || fail "혼합 버전($stale_edit): 중단 사유가 버전 불일치가 아님: $(cat "$SCRATCH/mixed.log")"
  [ -f "$TARGET_SKILL/scripts/.pre-update-sentinel" ] || fail "혼합 버전($stale_edit): 중단 전에 활성 코드가 교체됨"
  ls "$TARGET_SKILL"/.install-stage-* >/dev/null 2>&1 && fail "혼합 버전($stale_edit): 스테이징 잔여물 남음"
  cmp -s "$SOURCE_ROOT/.claude/skills/feature/config.sh" "$TARGET_SKILL/config.sh.new" || fail "혼합 버전($stale_edit): config.sh.new 가 새 버전이 아님"
  grep -q '^WORKER_MODEL="my-custom-worker-model"' "$TARGET_SKILL/config.sh" || fail "혼합 버전($stale_edit): 사용자 모델 설정이 덮어써짐"
done
# 병합(새 본문 + 기존 사용자 설정) 뒤에는 설치되고 사용자 설정이 유지된다
sed -e 's/^WORKER_MODEL=.*/WORKER_MODEL="my-custom-worker-model"/' -e 's/^TEST_CMD=.*/TEST_CMD="npm test"/' "$TARGET_SKILL/config.sh.new" > "$TARGET_SKILL/config.sh"
bash "$SOURCE_ROOT/install.sh" "$TARGET" > "$SCRATCH/mixed.log" 2>&1 || fail "혼합 버전: 병합 뒤 설치 실패: $(cat "$SCRATCH/mixed.log")"
[ ! -f "$TARGET_SKILL/scripts/.pre-update-sentinel" ] && grep -q '^WORKER_MODEL="my-custom-worker-model"' "$TARGET_SKILL/config.sh" || fail "혼합 버전: 병합 뒤 스킬 코드가 갱신되지 않았거나 사용자 설정이 바뀜"
# 러너도 같은 표식을 대조한다(설치를 거치지 않고 스크립트만 복사한 혼합 상태)
grep -q 'REQUIRED_RUNTIME_CONTRACT_VERSION=' "$TARGET_SKILL/scripts/feature-run.sh" \
  && [ "$(sed -n 's/^REQUIRED_RUNTIME_CONTRACT_VERSION=//p' "$TARGET_SKILL/scripts/feature-run.sh")" = "$(sed -n 's/^FEATURE_RUNTIME_CONTRACT_VERSION=//p' "$SOURCE_RUNTIME_LIB")" ] \
  || fail "혼합 버전: feature-run.sh 가 요구하는 런타임 계약 표식이 scripts/lib/runtime.sh 와 다름"
echo "[OK] 4a. 구 설정 요소(함수 정의·런타임 계약 표식·옛 계약 버전·경로 초기화) 남은 config → 혼합 설치 차단 + 사용자 설정 보존"
cp "$TARGET_SKILL/config.sh" "$SCRATCH/config.settings-only"   # 뒤 추가 사례(4a-2·4d·4e)가 되돌아올 설정 전용 상태(사용자 값 포함)

# ---------- 4a-2. backend 줄이 없는 구 설정 → 거부 + .new 에 legacy backend / 방법 (ii) 이관 뒤 설치·종전 의미 유지 ----------
{ grep -v '^CLAUDE_BACKEND=\|^CODEX_BACKEND=' "$SRC_SKILL/config.sh" \
    | sed -e 's/^TEST_CMD=.*/TEST_CMD="${SMOKE_TEST_CMD:-npm test}"/' -e 's/^LINT_CMD=.*/LINT_CMD="true"/' -e 's/^WORKER_MODEL=.*/WORKER_MODEL="claude-sonnet-5-5"/'
  printf '%s\n' 'render_prompt() { :; }'; } > "$TARGET_SKILL/config.sh"
cp "$TARGET_SKILL/config.sh" "$SCRATCH/config.no-backend-old"
rm -f "$TARGET_SKILL/config.sh.new"
printf 'sentinel\n' > "$TARGET_SKILL/scripts/.pre-update-sentinel"
if bash "$SOURCE_ROOT/install.sh" "$TARGET" > "$SCRATCH/nobackend.log" 2>&1; then fail "backend 줄 없는 구 설정: 중단 없이 설치됨"; fi
[ -f "$TARGET_SKILL/scripts/.pre-update-sentinel" ] || fail "backend 줄 없는 구 설정: 중단 전에 활성 코드가 교체됨"
ls "$TARGET_SKILL"/.install-stage-* >/dev/null 2>&1 && fail "backend 줄 없는 구 설정: 스테이징 잔여물 남음"
cmp -s "$TARGET_SKILL/config.sh" "$SCRATCH/config.no-backend-old" || fail "backend 줄 없는 구 설정: 거부했는데 config.sh 가 바뀜"
grep -q '^CLAUDE_BACKEND="legacy_cli"' "$TARGET_SKILL/config.sh.new" && grep -q '^CODEX_BACKEND="legacy_exec"' "$TARGET_SKILL/config.sh.new" \
  || fail "backend 줄 없는 구 설정: config.sh.new 의 backend 줄이 legacy 값이 아님"
( source "$SRC_SKILL/scripts/lib/config-layout.sh"; feature_config_runtime_lines "$TARGET_SKILL/config.sh.new" >/dev/null ) \
  || fail "backend 줄 없는 구 설정: config.sh.new 가 설정 전용 판정을 통과하지 못함"
grep -q 'legacy_cli' "$SCRATCH/nobackend.log" && grep -q 'legacy_exec' "$SCRATCH/nobackend.log" && grep -qF "$TARGET_SKILL/config.sh.pre-runtime-split" "$SCRATCH/nobackend.log" \
  || fail "backend 줄 없는 구 설정: 안내에 두 backend 의 legacy 의미·백업 명령이 없음: $(cat "$SCRATCH/nobackend.log")"
# 방법 (ii): 위반 줄(함수 정의)만 지운다 — backend 줄은 새로 넣지 않는다
grep -vxF 'render_prompt() { :; }' "$SCRATCH/config.no-backend-old" > "$SCRATCH/config.no-backend-migrated"
cp "$SCRATCH/config.no-backend-migrated" "$TARGET_SKILL/config.sh"
bash "$SOURCE_ROOT/install.sh" "$TARGET" > "$SCRATCH/nobackend2.log" 2>&1 || fail "backend 줄 없는 구 설정: 이관 뒤 설치 실패: $(cat "$SCRATCH/nobackend2.log")"
cmp -s "$TARGET_SKILL/config.sh" "$SCRATCH/config.no-backend-migrated" || fail "backend 줄 없는 구 설정: 이관 뒤 설치가 config.sh 를 바꿈"
migrated_load="$(env -u SMOKE_TEST_CMD bash -c 'source "$1"; printf "%s|%s|%s" "$(role_backend WORKER)" "$(role_backend REVIEWER)" "$TEST_CMD"' _ "$TARGET_LOADER")"
[ "$migrated_load" = "claude_cli|codex_cli|npm test" ] || fail "backend 줄 없는 구 설정: 이관 뒤 종전 의미(legacy)·환경 변수 표현식이 유지되지 않음 ($migrated_load)"
migrated_custom="$(SMOKE_TEST_CMD=custom bash -c 'source "$1"; printf "%s" "$TEST_CMD"' _ "$TARGET_LOADER")"
[ "$migrated_custom" = custom ] || fail "backend 줄 없는 구 설정: 이관 뒤 TEST_CMD 의 환경 변수 표현식이 평가되지 않음 ($migrated_custom)"
cp "$SCRATCH/config.settings-only" "$TARGET_SKILL/config.sh"
echo "[OK] 4a-2. backend 줄 없는 구 설정 → 거부·.new 에 legacy backend·안내 / 방법 (ii) 이관 뒤 설치·claude_cli/codex_cli·환경 변수 표현식 유지"

# ---------- 4d. 분리 이후 업데이트 — 런타임·버전 상수만 바뀐 소스는 config.sh 병합 없이 런타임만 갱신 ----------
UPDATE_SOURCE="$SCRATCH/update-source"
cp -R "$SOURCE_ROOT" "$UPDATE_SOURCE"
printf '\n# UPDATE-MODULE-SENTINEL\n' >> "$UPDATE_SOURCE/.claude/skills/feature/scripts/lib/telemetry.sh"
sed -i.sedbak "s/^REVIEWER_CONTRACT_VERSION=$REVIEWER_CONTRACT/REVIEWER_CONTRACT_VERSION=$((REVIEWER_CONTRACT + 1))/" "$UPDATE_SOURCE/.claude/skills/feature/scripts/lib/runtime.sh" \
  && rm -f "$UPDATE_SOURCE/.claude/skills/feature/scripts/lib/runtime.sh.sedbak"
grep -q "^REVIEWER_CONTRACT_VERSION=$((REVIEWER_CONTRACT + 1))" "$UPDATE_SOURCE/.claude/skills/feature/scripts/lib/runtime.sh" || fail "분리 이후 업데이트: 픽스처(계약 버전 +1) 준비 실패"
bash "$UPDATE_SOURCE/install.sh" "$TARGET" > "$SCRATCH/update.log" 2>&1 || fail "분리 이후 업데이트: 설치 실패: $(cat "$SCRATCH/update.log")"
grep -q 'UPDATE-MODULE-SENTINEL' "$TARGET_SKILL/scripts/lib/telemetry.sh" && grep -q "^REVIEWER_CONTRACT_VERSION=$((REVIEWER_CONTRACT + 1))" "$TARGET_SKILL/scripts/lib/runtime.sh" \
  || fail "분리 이후 업데이트: 대상 런타임 모듈이 갱신되지 않음"
cmp -s "$TARGET_SKILL/config.sh" "$SCRATCH/config.settings-only" || fail "분리 이후 업데이트: config.sh 가 바뀜"
grep -qF "[WARN] 기존 파일 보존: $TARGET_SKILL/config.sh" "$SCRATCH/update.log" && fail "분리 이후 업데이트: config.sh 에 대해 병합 경고(WARN)를 냄"
grep -qF "[INFO] 기존 설정 보존: $TARGET_SKILL/config.sh" "$SCRATCH/update.log" || fail "분리 이후 업데이트: config.sh 보존 안내(INFO)가 없음"
bash "$SOURCE_ROOT/install.sh" "$TARGET" >/dev/null 2>&1 || fail "분리 이후 업데이트: 원래 소스로 재설치 실패"
grep -q 'UPDATE-MODULE-SENTINEL' "$TARGET_SKILL/scripts/lib/telemetry.sh" && fail "분리 이후 업데이트: 원래 소스로 되돌리지 못함"
echo "[OK] 4d. 분리 이후 업데이트 — 런타임 모듈 갱신·config.sh 바이트 보존·병합 경고 없음(INFO)"

# ---------- 4e. 설정이 덜 채워진 설정 전용 config → 설치는 성공, 로더의 종전 가드가 사용 시점에 거부 ----------
printf 'TEST_CMD="npm test"\nLINT_CMD="true"\n' > "$TARGET_SKILL/config.sh"
bash "$SOURCE_ROOT/install.sh" "$TARGET" > "$SCRATCH/partial-config.log" 2>&1 || fail "덜 채운 설정 전용 config: 설치 실패: $(cat "$SCRATCH/partial-config.log")"
set +e
bash -c 'source "$1"' _ "$TARGET_LOADER" > "$SCRATCH/partial-load.log" 2>&1
partial_rc=$?
set -e
[ "$partial_rc" = 1 ] && grep -q '비워둘 수 없습니다' "$SCRATCH/partial-load.log" || fail "덜 채운 설정 전용 config: 로더가 가드로 거부하지 않음 (rc $partial_rc): $(cat "$SCRATCH/partial-load.log")"
# 같은 입력을 set -u 진입점(러너)처럼 source 해도 셸의 unbound variable 이 아니라 로더의 [FAIL] 이어야 한다
set +e
bash -c 'set -euo pipefail; source "$1"' _ "$TARGET_LOADER" > "$SCRATCH/partial-load-nounset.log" 2>&1
partial_rc=$?
set -e
[ "$partial_rc" = 1 ] && grep -q '비워둘 수 없습니다' "$SCRATCH/partial-load-nounset.log" && ! grep -q 'unbound variable' "$SCRATCH/partial-load-nounset.log" || fail "덜 채운 설정 전용 config(set -u): 로더가 가드로 거부하지 않음 (rc $partial_rc): $(cat "$SCRATCH/partial-load-nounset.log")"
echo "[OK] 4e. 덜 채운 설정 전용 config — 설치 성공·로더 가드 거부"

# ---------- 4f. 여러 줄 설정 문자열 안의 함수 모양 줄·사용자 함수 → 설정 전용으로 판정, 업데이트 성공·값 보존 ----------
{ grep -v '^TEST_CMD=\|^LINT_CMD=' "$SRC_SKILL/config.sh"
  printf "TEST_CMD='\nrun_checks() {\n    ./gradlew test\n}\nrun_checks\n'\nLINT_CMD=\"true\"\nmy_project_helper() { :; }\n"; } > "$TARGET_SKILL/config.sh"
cp "$TARGET_SKILL/config.sh" "$SCRATCH/config.multiline"
bash "$SOURCE_ROOT/install.sh" "$TARGET" > "$SCRATCH/multiline.log" 2>&1 || fail "여러 줄 설정 문자열 config: 업데이트가 거부됨: $(cat "$SCRATCH/multiline.log")"
cmp -s "$TARGET_SKILL/config.sh" "$SCRATCH/config.multiline" || fail "여러 줄 설정 문자열 config: 업데이트가 config.sh 를 바꿈"
grep -qF "[INFO] 기존 설정 보존: $TARGET_SKILL/config.sh" "$SCRATCH/multiline.log" || fail "여러 줄 설정 문자열 config: 보존 안내(INFO)가 없음"
multiline_got="$(bash -c 'source "$1"; printf "%s|%s" "$TEST_CMD" "$(declare -F my_project_helper)"' _ "$TARGET_LOADER" 2>&1)" || fail "여러 줄 설정 문자열 config: 로더가 거부함: $multiline_got"
[ "$multiline_got" = "$(printf '\nrun_checks() {\n    ./gradlew test\n}\nrun_checks\n|my_project_helper')" ] || fail "여러 줄 설정 문자열 config: 로드 뒤 TEST_CMD·사용자 함수가 그대로가 아님: [$multiline_got]"
echo "[OK] 4f. 여러 줄 설정 문자열 안의 함수 모양 줄·사용자 함수 — 업데이트 성공·config 바이트 보존·로드 뒤 값 보존"

printf 'TEST_CMD="npm test"\nLINT_CMD="true"\nrender_prompt() { :; }\n' > "$TARGET_SKILL/config.sh"   # 뒤 사례(4b)의 전제: 비호환 config 상태로 되돌린다

# ---------- 4b. 세 번째 항목(schemas) 복사 실패 → 앞 항목도 기존 상태 유지 ----------
BROKEN_SOURCE="$SCRATCH/broken-source"
cp -R "$SOURCE_ROOT" "$BROKEN_SOURCE"
printf '\n<!-- BROKEN-SOURCE-SENTINEL -->\n' >> "$BROKEN_SOURCE/.claude/skills/feature/SKILL.md"
rm -rf "$BROKEN_SOURCE/.claude/skills/feature/schemas"
PARTIAL_TARGET="$SCRATCH/partial"
git init -q "$PARTIAL_TARGET"
bash "$SOURCE_ROOT/install.sh" "$PARTIAL_TARGET" >/dev/null
if bash "$BROKEN_SOURCE/install.sh" "$PARTIAL_TARGET" >/dev/null 2>&1; then
  fail "복사 실패: schemas 없는 소스인데 성공함"
fi
grep -q 'BROKEN-SOURCE-SENTINEL' "$PARTIAL_TARGET/.claude/skills/feature/SKILL.md" \
  && fail "복사 실패: 뒤 항목 실패에도 앞 항목(SKILL.md)이 교체됨"
ls "$PARTIAL_TARGET/.claude/skills/feature"/.install-stage-* >/dev/null 2>&1 \
  && fail "복사 실패: 스테이징 잔여물 남음"
echo "[OK] 4b. 항목 일부 복사 실패 시 전체 무손상"

# ---------- 4c. 참조 문서(references/) — 구버전 설치 업데이트 / 소스 누락 시 실패 / 러너의 시작 거부 ----------
# (a) references/ 가 없던 구버전 설치(긴 단일 SKILL.md)의 업데이트: references/ 가 새로 배포되고 SKILL.md 가 진입 문서로 교체된다. 사용자 설정은 보존.
REF_TARGET="$SCRATCH/ref-update"
git init -q "$REF_TARGET"
bash "$SOURCE_ROOT/install.sh" "$REF_TARGET" >/dev/null
REF_SKILL="$REF_TARGET/.claude/skills/feature"
rm -rf "$REF_SKILL/references"; printf '# 구버전 단일 문서 OLD-SKILL-SENTINEL\n' > "$REF_SKILL/SKILL.md"
sed -i.sedbak 's/^TEST_CMD=.*/TEST_CMD="npm test"/' "$REF_SKILL/config.sh" && rm -f "$REF_SKILL/config.sh.sedbak"
printf '# 프로젝트 커스텀 규칙\n' >> "$REF_TARGET/.claude/hooks/core_rules.md"
bash "$SOURCE_ROOT/install.sh" "$REF_TARGET" > "$SCRATCH/ref-update.log" 2>&1 || fail "references 업데이트: 구버전 설치 업데이트 실패: $(cat "$SCRATCH/ref-update.log")"
for ref in $refs_in_skill; do
  cmp -s "$SRC_SKILL/references/$ref" "$REF_SKILL/references/$ref" || fail "references 업데이트: 구버전 설치에 references/$ref 가 배포되지 않음"
done
grep -q 'OLD-SKILL-SENTINEL' "$REF_SKILL/SKILL.md" && fail "references 업데이트: SKILL.md 가 갱신되지 않음"
grep -q 'npm test' "$REF_SKILL/config.sh" && grep -q '커스텀 규칙' "$REF_TARGET/.claude/hooks/core_rules.md" || fail "references 업데이트: 사용자 설정(config.sh·core_rules.md)이 보존되지 않음"
# 설치된 references/ 에 남은 낡은 파일은 교체로 사라진다(디렉터리 단위 교체 — 옛 버전 문서가 섞여 남지 않는다)
printf 'stale\n' > "$REF_SKILL/references/stale-old.md"
bash "$SOURCE_ROOT/install.sh" "$REF_TARGET" >/dev/null 2>&1 || fail "references 업데이트: 재설치 실패"
[ ! -e "$REF_SKILL/references/stale-old.md" ] || fail "references 업데이트: 옛 참조 문서가 섞여 남음"
# (b) 소스에 참조 문서 하나가 없으면: 설치 실패, 성공 메시지 없음, 기존 설치 무손상(SKILL.md·references 그대로)
REF_BROKEN="$SCRATCH/ref-broken-source"
cp -R "$SOURCE_ROOT" "$REF_BROKEN"
printf '\n<!-- REF-BROKEN-SENTINEL -->\n' >> "$REF_BROKEN/.claude/skills/feature/SKILL.md"
rm -f "$REF_BROKEN/.claude/skills/feature/references/exit-states-resume.md"
if bash "$REF_BROKEN/install.sh" "$REF_TARGET" > "$SCRATCH/ref-broken.log" 2>&1; then fail "references 누락: 참조 문서가 빠진 소스인데 설치가 성공함"; fi
grep -q 'references/exit-states-resume.md' "$SCRATCH/ref-broken.log" || fail "references 누락: 누락된 문서 이름이 보고되지 않음: $(cat "$SCRATCH/ref-broken.log")"
grep -q '\[완료' "$SCRATCH/ref-broken.log" && fail "references 누락: 실패했는데 성공 메시지를 출력함"
grep -q 'REF-BROKEN-SENTINEL' "$REF_SKILL/SKILL.md" && fail "references 누락: 실패했는데 SKILL.md 가 교체됨"
[ -s "$REF_SKILL/references/exit-states-resume.md" ] || fail "references 누락: 실패했는데 기존 references 가 손상됨"
ls "$REF_SKILL"/.install-stage-* >/dev/null 2>&1 && fail "references 누락: 스테이징 잔여물 남음"
# references/ 디렉터리 전체가 없는 소스·빈 참조 문서도 같은 실패
rm -rf "$REF_BROKEN/.claude/skills/feature/references"
if bash "$REF_BROKEN/install.sh" "$REF_TARGET" > "$SCRATCH/ref-broken2.log" 2>&1; then fail "references 누락: references/ 없는 소스인데 설치가 성공함"; fi
grep -q '\[완료' "$SCRATCH/ref-broken2.log" && fail "references 누락: references/ 없는 소스에서 성공 메시지를 출력함"
cp -R "$SRC_SKILL/references" "$REF_BROKEN/.claude/skills/feature/references"; : > "$REF_BROKEN/.claude/skills/feature/references/impl-docs.md"
if bash "$REF_BROKEN/install.sh" "$REF_TARGET" > "$SCRATCH/ref-broken3.log" 2>&1; then fail "references 누락: 빈 참조 문서인데 설치가 성공함"; fi
grep -q 'references/impl-docs.md' "$SCRATCH/ref-broken3.log" || fail "references 누락: 빈 참조 문서가 보고되지 않음"
# (c) 설치 뒤 참조 문서가 사라진 대상: 러너가 어떤 단계도 시작하지 않고 exit 1 로 누락을 드러낸다(부트스트랩·finalize 포함, .agent-work 미생성)
sed -i.sedbak 's/^LINT_CMD=.*/LINT_CMD="true"/' "$REF_SKILL/config.sh" && rm -f "$REF_SKILL/config.sh.sedbak"
mv "$REF_SKILL/references/done-finalize.md" "$SCRATCH/done-finalize.keep"
for runner_args in "" "--feature ref-x" "--feature ref-x --finalize"; do
  set +e
  # shellcheck disable=SC2086
  (cd "$REF_TARGET" && bash "$REF_SKILL/scripts/feature-run.sh" $runner_args) > "$SCRATCH/ref-runner.log" 2>&1
  ref_rc=$?
  set -e
  [ "$ref_rc" = 1 ] && grep -q '필수 참조 문서 누락: references/done-finalize.md' "$SCRATCH/ref-runner.log" \
    || fail "references 누락: 러너($runner_args)가 누락을 드러내며 exit 1 하지 않음 (rc $ref_rc): $(cat "$SCRATCH/ref-runner.log")"
  [ ! -e "$REF_TARGET/.agent-work" ] && [ ! -e "$SCRATCH/ref-update-feature-ref-x" ] || fail "references 누락: 러너($runner_args)가 누락 상태에서 작업을 시작함"
done
mv "$SCRATCH/done-finalize.keep" "$REF_SKILL/references/done-finalize.md"
echo "[OK] 4c. references/ — 구버전 설치 업데이트 배포(사용자 설정 보존)·옛 문서 미잔존 / 소스 누락·빈 문서 → 실패(성공 메시지 없음·기존 설치 무손상) / 러너 시작 거부"

# ---------- 5. 잘못된 이벤트에 등록된 훅 → 미등록으로 판정 ----------
WRONG_EVENT_TARGET="$SCRATCH/wrong-event"
git init -q "$WRONG_EVENT_TARGET"
mkdir -p "$WRONG_EVENT_TARGET/.claude"
jq -n '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: "$CLAUDE_PROJECT_DIR/.claude/hooks/pre_bash_guard.sh"}]}]}}' \
  > "$WRONG_EVENT_TARGET/.claude/settings.json"
wrong_event_output="$(bash "$SOURCE_ROOT/install.sh" "$WRONG_EVENT_TARGET")"
grep -q 'PreToolUse 에 pre_bash_guard.sh 미등록' <<< "$wrong_event_output" \
  || fail "훅 이벤트 검사: 잘못된 이벤트 등록을 설치됨으로 오판"
echo "[OK] 5. 훅 이벤트 단위 검사"

# ---------- 5b. 올바른 이벤트 + 가짜 command 문자열 → 미등록으로 판정 ----------
FAKE_COMMAND_TARGET="$SCRATCH/fake-command"
git init -q "$FAKE_COMMAND_TARGET"
mkdir -p "$FAKE_COMMAND_TARGET/.claude"
jq -n '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: "echo disabled pre_bash_guard.sh"}]}]}}' \
  > "$FAKE_COMMAND_TARGET/.claude/settings.json"
fake_command_output="$(bash "$SOURCE_ROOT/install.sh" "$FAKE_COMMAND_TARGET")"
grep -q 'PreToolUse 에 pre_bash_guard.sh 미등록' <<< "$fake_command_output" \
  || fail "훅 command 검사: 비활성 문자열(echo disabled ...)을 설치됨으로 오판"
echo "[OK] 5b. 가짜 command 문자열 미등록 판정"

# ---------- 5c. 레거시 core rules 주입 훅 → 교체 경고 ----------
LEGACY_HOOK_TARGET="$SCRATCH/legacy-hook"
git init -q "$LEGACY_HOOK_TARGET"
mkdir -p "$LEGACY_HOOK_TARGET/.claude"
jq -n '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: "$CLAUDE_PROJECT_DIR/.claude/hooks/inject_core_rules.sh"}]}]}}' \
  > "$LEGACY_HOOK_TARGET/.claude/settings.json"
legacy_hook_output="$(bash "$SOURCE_ROOT/install.sh" "$LEGACY_HOOK_TARGET")"
grep -q '레거시 inject_core_rules.sh' <<< "$legacy_hook_output" \
  || fail "훅 마이그레이션: 레거시 core rules 주입 훅 교체 경고 누락"
grep -q 'inject_conventions.sh로 교체' <<< "$legacy_hook_output" \
  || fail "훅 마이그레이션: 교체 대상 안내 누락"
echo "[OK] 5c. 레거시 core rules 훅 교체 안내"

# ---------- 5d. 구버전 inject_conventions.sh(매 턴 주입) 보존 시 → 교체 경고 + .new ----------
LEGACY_CONV_TARGET="$SCRATCH/legacy-conv"
git init -q "$LEGACY_CONV_TARGET"
mkdir -p "$LEGACY_CONV_TARGET/.claude/hooks"
printf '%s\n' '#!/bin/bash' 'CONVENTIONS_FILE="$CLAUDE_PROJECT_DIR/conventions.md"' '[ -f "$CONVENTIONS_FILE" ] && cat "$CONVENTIONS_FILE"' 'exit 0' \
  > "$LEGACY_CONV_TARGET/.claude/hooks/inject_conventions.sh"
legacy_conv_output="$(bash "$SOURCE_ROOT/install.sh" "$LEGACY_CONV_TARGET")"
grep -q 'inject_conventions.sh 가 구버전(매 턴 주입)' <<< "$legacy_conv_output" || fail "훅 마이그레이션: 구버전 conventions 훅 경고 누락"
[ -f "$LEGACY_CONV_TARGET/.claude/hooks/inject_conventions.sh.new" ] || fail "훅 마이그레이션: inject_conventions.sh.new 미생성"
grep -q 'FEATURE_ROLE_CHILD' "$LEGACY_CONV_TARGET/.claude/hooks/inject_conventions.sh.new" || fail "훅 마이그레이션: .new 가 새 훅이 아님"
grep -q 'FEATURE_ROLE_CHILD' "$LEGACY_CONV_TARGET/.claude/hooks/inject_conventions.sh" && fail "훅 마이그레이션: 보존돼야 할 구버전 훅이 덮어써짐"
grep -q '수동 병합 필요' <<< "$legacy_conv_output" || fail "훅 마이그레이션: 구버전 훅인데 완료 메시지가 수동 병합을 요구하지 않음"
echo "[OK] 5d. 구버전 conventions 훅 → 교체 안내 + .new"

# ---------- 5e. 기존 settings.json 에 SessionStart(compact) 훅 미등록 → 추가 안내(덮어쓰지 않음), 등록돼 있으면 조용 ----------
COMPACT_HOOK_TARGET="$SCRATCH/compact-hook"
git init -q "$COMPACT_HOOK_TARGET"
mkdir -p "$COMPACT_HOOK_TARGET/.claude"
jq 'del(.hooks.SessionStart)' "$SOURCE_ROOT/.claude/settings.json" > "$COMPACT_HOOK_TARGET/.claude/settings.json"
cp "$COMPACT_HOOK_TARGET/.claude/settings.json" "$SCRATCH/compact-settings.before"
compact_hook_output="$(bash "$SOURCE_ROOT/install.sh" "$COMPACT_HOOK_TARGET")"
grep -q 'SessionStart 에 compact_recovery.sh 미등록' <<< "$compact_hook_output" || fail "SessionStart 훅 검사: 미등록 상태를 조용히 정상으로 보고함"
grep -q '"matcher": "compact"' <<< "$compact_hook_output" || fail "SessionStart 훅 검사: 추가할 항목(matcher compact)이 안내되지 않음"
grep -q '수동 병합 필요' <<< "$compact_hook_output" || fail "SessionStart 훅 검사: 수동 병합 필요로 마무리되지 않음"
grep -q 'UserPromptSubmit 에\|PreToolUse 에' <<< "$compact_hook_output" && fail "SessionStart 훅 검사: 등록된 다른 훅까지 미등록으로 보고함"
cmp -s "$COMPACT_HOOK_TARGET/.claude/settings.json" "$SCRATCH/compact-settings.before" || fail "SessionStart 훅 검사: 기존 settings.json 을 수정함"
[ -x "$COMPACT_HOOK_TARGET/.claude/hooks/compact_recovery.sh" ] || fail "SessionStart 훅 검사: 훅 스크립트가 설치되지 않음"
cp "$SOURCE_ROOT/.claude/settings.json" "$COMPACT_HOOK_TARGET/.claude/settings.json"
bash "$SOURCE_ROOT/install.sh" "$COMPACT_HOOK_TARGET" | grep -q 'WARN' && fail "SessionStart 훅 검사: 등록돼 있는데 WARN 발생"
# command 는 같지만 matcher 가 compact 가 아니면(startup 등) 압축 뒤에 실행되지 않는다 — 등록으로 인정하지 않는다
jq '.hooks.SessionStart[0].matcher = "startup"' "$SOURCE_ROOT/.claude/settings.json" > "$COMPACT_HOOK_TARGET/.claude/settings.json"
cp "$COMPACT_HOOK_TARGET/.claude/settings.json" "$SCRATCH/compact-settings.before"
wrong_matcher_output="$(bash "$SOURCE_ROOT/install.sh" "$COMPACT_HOOK_TARGET")"
grep -q 'SessionStart 에 compact_recovery.sh 가 있지만 matcher 가 "compact" 가 아닙니다' <<< "$wrong_matcher_output" || fail "SessionStart 훅 검사: matcher=startup 등록을 정상으로 판정함"
grep -q '"matcher": "compact"' <<< "$wrong_matcher_output" && grep -q '수동 병합 필요' <<< "$wrong_matcher_output" || fail "SessionStart 훅 검사: 잘못된 matcher 에 올바른 항목·수동 병합 안내가 없음"
cmp -s "$COMPACT_HOOK_TARGET/.claude/settings.json" "$SCRATCH/compact-settings.before" || fail "SessionStart 훅 검사: 잘못된 matcher 의 settings.json 을 수정함"
# matcher 가 없는 SessionStart 등록도 같다(모든 source 에서 실행 — 훅이 스스로 걸러 내지만 의도한 등록이 아니다)
jq 'del(.hooks.SessionStart[0].matcher)' "$SOURCE_ROOT/.claude/settings.json" > "$COMPACT_HOOK_TARGET/.claude/settings.json"
no_matcher_output="$(bash "$SOURCE_ROOT/install.sh" "$COMPACT_HOOK_TARGET")"
grep -q 'matcher 가 "compact" 가 아닙니다' <<< "$no_matcher_output" || fail "SessionStart 훅 검사: matcher 없는 등록을 정상으로 판정함"
# compact 를 포함한 대안 목록 matcher 는 등록으로 인정한다
jq '.hooks.SessionStart[0].matcher = "resume|compact"' "$SOURCE_ROOT/.claude/settings.json" > "$COMPACT_HOOK_TARGET/.claude/settings.json"
bash "$SOURCE_ROOT/install.sh" "$COMPACT_HOOK_TARGET" | grep -q 'WARN' && fail "SessionStart 훅 검사: compact 를 포함한 matcher 인데 WARN 발생"
echo "[OK] 5e. SessionStart(compact) 훅 미등록·잘못된 matcher 안내 + settings.json 불변"

# ---------- 6. .gitignore 중복 방지 ----------
duplicate_count="$(grep -c '^\.agent-work/$' "$TARGET/.gitignore")"
[ "$duplicate_count" = "1" ] || fail ".gitignore: .agent-work/ 항목 ${duplicate_count}개 (1개여야 함)"
NO_NEWLINE_TARGET="$SCRATCH/no-newline-gitignore"
git init -q "$NO_NEWLINE_TARGET"
printf 'docs/' > "$NO_NEWLINE_TARGET/.gitignore"
bash "$SOURCE_ROOT/install.sh" "$NO_NEWLINE_TARGET" >/dev/null
[ "$(sed -n '1p' "$NO_NEWLINE_TARGET/.gitignore")" = 'docs/' ] || fail ".gitignore: 기존 마지막 줄이 변경됨"
[ "$(sed -n '2p' "$NO_NEWLINE_TARGET/.gitignore")" = '.agent-work/' ] || fail ".gitignore: 줄바꿈 없이 항목이 이어 붙음"
echo "[OK] 6. .gitignore 중복·줄바꿈 보존"

# ---------- 7. 삭제 가드 동작 검증 (pre_bash_guard / worker_guard) ----------
BASH_GUARD="$TARGET/.claude/hooks/pre_bash_guard.sh"
run_bash_guard() { printf '{"tool_input":{"command":"%s"}}' "$1" | CLAUDE_PROJECT_DIR="$TARGET" bash "$BASH_GUARD"; }
run_bash_guard 'rm -rf src/legacy' 2>/dev/null && fail "삭제 가드: 플래그 없는 rm 이 통과됨"
run_bash_guard 'git rm old_module.py' 2>/dev/null && fail "삭제 가드: 플래그 없는 git rm 이 통과됨"
run_bash_guard 'rm -rf .agent-work/reviews' 2>/dev/null || fail "삭제 가드: .agent-work 예외 경로가 차단됨"
run_bash_guard 'echo removed' 2>/dev/null || fail "삭제 가드: rm 을 포함하지 않는 명령이 차단됨"
touch "$TARGET/.claude/ALLOW_DELETE"
run_bash_guard 'rm src/legacy/old.txt' 2>/dev/null || fail "삭제 가드: ALLOW_DELETE 플래그가 있는데 차단됨"
[ ! -f "$TARGET/.claude/ALLOW_DELETE" ] || fail "삭제 가드: ALLOW_DELETE 플래그가 1회용으로 소모되지 않음"
WORKER_GUARD="$TARGET/.codex/hooks/worker_guard.sh"
printf '{"cwd":"%s","tool_input":{"command":["bash","-lc","rm -rf src/legacy"]}}' "$TARGET" \
  | bash "$WORKER_GUARD" 2>/dev/null && fail "worker 가드: rm 이 통과됨"
printf '{"cwd":"%s","tool_input":{"command":["bash","-lc","rm -rf .agent-work/tmp"]}}' "$TARGET" \
  | bash "$WORKER_GUARD" 2>/dev/null || fail "worker 가드: .agent-work 예외 경로가 차단됨"
printf '{"cwd":"%s","tool_input":{"command":["bash","-lc","git commit -m x"]}}' "$TARGET" \
  | bash "$WORKER_GUARD" 2>/dev/null && fail "worker 가드: 워커 커밋이 통과됨"
printf '{"cwd":"%s","tool_input":{"command":["bash","-lc","git add -A"]}}' "$TARGET" \
  | bash "$WORKER_GUARD" 2>/dev/null && fail "worker 가드: 워커 git add 가 통과됨"
printf '{"cwd":"%s","tool_input":{"command":["bash","-lc","git restore --staged src/a.txt"]}}' "$TARGET" \
  | bash "$WORKER_GUARD" 2>/dev/null && fail "worker 가드: 워커 git restore --staged 가 통과됨"
printf '{"cwd":"%s","tool_input":{"command":["bash","-lc","git restore --source=abc123 --worktree -- src/a.txt"]}}' "$TARGET" \
  | bash "$WORKER_GUARD" 2>/dev/null || fail "worker 가드: 작업 트리 전용 restore 가 차단됨"
echo "[OK] 7. 삭제 가드 (pre_bash_guard / worker_guard)"

# ---------- 8. live.log 아카이브 + 중첩 tee 중복 방지 ----------
LOG_TARGET="$SCRATCH/logging"
LOG_SKILL="$LOG_TARGET/.claude/skills/feature"
git init -q "$LOG_TARGET"
bash "$SOURCE_ROOT/install.sh" "$LOG_TARGET" >/dev/null
sed -i.sedbak 's|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND="legacy_cli"|; s/^CLAUDE_BIN=.*/CLAUDE_BIN="true"/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^CODEX_BACKEND=.*/CODEX_BACKEND="legacy_exec"/; s/^CODEX_BIN=.*/CODEX_BIN="true"/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^TEST_CMD=.*/TEST_CMD="true"/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^LINT_CMD=.*/LINT_CMD="true"/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
# 워커 픽스처가 전부 가짜 codex(CODEX_BIN 교체)이므로 모델 기본값과 무관하게 codex 로 고정한다
sed -i.sedbak 's/^WORKER_CLI=.*/WORKER_CLI="codex"/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
chmod -x "$LOG_TARGET/feature-live"

mkdir -p "$LOG_TARGET/.agent-work"
printf '이전 피처 로그\n' > "$LOG_TARGET/.agent-work/live.log"
printf '이전 산출물\n' > "$LOG_TARGET/.agent-work/previous.txt"
set +e
(cd "$LOG_TARGET" && bash "$LOG_SKILL/scripts/feature-run.sh" --new --archive-as live-regression) >"$LOG_TARGET/.need-docs-design.out" 2>&1
new_rc=$?
set -e
[ "$new_rc" = 3 ] || fail "live.log 아카이브: 새 피처 초기화 종료 코드가 3이 아님 ($new_rc)"
# NEED_DOCS 반환은 worktree conventions.md 를 덧붙인다 — 이 시점엔 conventions.md 가 없으므로 블록이 없어야 한다
grep -q '\[PROJECT CONVENTIONS\]' "$LOG_TARGET/.need-docs-design.out" \
  && fail "NEED_DOCS conventions 주입: conventions.md 가 없는데 블록이 출력됨"
# 로딩 경로: 종료 상태마다 러너가 다음 행동 전에 읽을 참조 문서의 절대 경로를 알려 준다(파일이 실제로 있어야 한다)
ref_hint_ok() { # output-file status-pattern reference-name
  local line path
  line="$(grep "^\[SKILL REFERENCE\] $2" "$1" | tail -1)"
  [ -n "$line" ] || return 1
  path="$(printf '%s' "$line" | grep -oE "/[^ ,]*/references/$3")" || return 1
  [ -s "$path" ]
}
ref_hint_ok "$LOG_TARGET/.need-docs-design.out" 'NEED_DOCS(DESIGN_MISSING)' phase0-design.md \
  || fail "로딩 경로: DESIGN_MISSING 반환에 references/phase0-design.md 안내가 없음: $(grep 'SKILL REFERENCE' "$LOG_TARGET/.need-docs-design.out")"
[ "$(cat "$LOG_TARGET/.agent-work/archive/live-regression/live.log")" = '이전 피처 로그' ] \
  || fail "live.log 아카이브: 이전 로그 내용이 보존되지 않음"
[ -f "$LOG_TARGET/.agent-work/archive/live-regression/previous.txt" ] \
  || fail "live.log 아카이브: 다른 이전 산출물과 같은 디렉터리에 보관되지 않음"
grep -q '이전 피처 로그' "$LOG_TARGET/.agent-work/live.log" \
  && fail "live.log 아카이브: 새 로그에 이전 로그가 계속 누적됨"

printf '# design\n' > "$LOG_TARGET/.agent-work/design.md"
mkdir -p "$LOG_TARGET/.agent-work/reviews"
# 설계 검증자는 PASS 를 실제 -o 경로에 쓰는 가짜 codex 로 돈다(미리 깔아 둔 리뷰 파일은 이번 invocation 의 결과로 인정되지 않는다)
sed -i.sedbak "s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$FAKE_PASS_CODEX\"|" "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
set +e
printf 'SMOKE-CONV-RULE-1: 러너 NEED_DOCS 주입 확인용\n' > "$LOG_TARGET/conventions.md"
(cd "$LOG_TARGET" && FAKE_PASS_CONTRACT="$VALIDATOR_CONTRACT" bash "$LOG_SKILL/scripts/feature-run.sh") >"$LOG_TARGET/.need-docs-impl.out" 2>&1
resume_rc=$?
set -e
[ "$resume_rc" = 3 ] || fail "중첩 tee: 설계 합의 후 구현 문서 대기 종료 코드가 3이 아님 ($resume_rc)"
# IMPL_DOCS_MISSING 반환 출력 끝에 그 worktree 의 conventions.md 본문이 [PROJECT CONVENTIONS] 블록으로 붙어야 한다(오케스트레이터 작성 직전 재대조)
grep -q '\[PROJECT CONVENTIONS\]' "$LOG_TARGET/.need-docs-impl.out" \
  || fail "NEED_DOCS conventions 주입: IMPL_DOCS_MISSING 출력에 [PROJECT CONVENTIONS] 블록 없음"
grep -q 'SMOKE-CONV-RULE-1' "$LOG_TARGET/.need-docs-impl.out" \
  || fail "NEED_DOCS conventions 주입: conventions.md 본문이 출력에 없음"
grep -q 'implementation.md·approach.md 작성 직전' "$LOG_TARGET/.need-docs-impl.out" \
  || fail "NEED_DOCS conventions 주입: 대상 문서 안내(implementation.md·approach.md)가 없음"
ref_hint_ok "$LOG_TARGET/.need-docs-impl.out" 'NEED_DOCS(IMPL_DOCS_MISSING)' impl-docs.md \
  || fail "로딩 경로: IMPL_DOCS_MISSING 반환에 references/impl-docs.md 안내가 없음: $(grep 'SKILL REFERENCE' "$LOG_TARGET/.need-docs-impl.out")"
# impl-docs.md 는 conventions 재대조·material decision 확인 절차를 phase0-design.md(3번·4번)에 위임한다 — 구현 문서 분기도 그 파일을 함께 안내해야 한다
ref_hint_ok "$LOG_TARGET/.need-docs-impl.out" 'NEED_DOCS(IMPL_DOCS_MISSING)' phase0-design.md \
  || fail "로딩 경로: IMPL_DOCS_MISSING 반환에 references/phase0-design.md(conventions 대조 절차) 안내가 없음: $(grep 'SKILL REFERENCE' "$LOG_TARGET/.need-docs-impl.out")"
# 출력을 head/grep 으로 줄여 읽어도 살아남는 [SKILL REFERENCE] 줄에 worktree conventions.md 경로와 직접 Read 지시가 있어야 한다(본문 블록은 잘릴 수 있다)
grep '^\[SKILL REFERENCE\] NEED_DOCS(IMPL_DOCS_MISSING)' "$LOG_TARGET/.need-docs-impl.out" | grep -Fq "[CONVENTIONS]" \
  || fail "로딩 경로: IMPL_DOCS_MISSING 의 [SKILL REFERENCE] 줄에 conventions.md 직접 Read 지시가 없음"
grep '^\[SKILL REFERENCE\] NEED_DOCS(IMPL_DOCS_MISSING)' "$LOG_TARGET/.need-docs-impl.out" | grep -Fq "/conventions.md" \
  || fail "로딩 경로: IMPL_DOCS_MISSING 의 [SKILL REFERENCE] 줄에 worktree conventions.md 경로가 없음"
# conventions.md 가 없던 DESIGN_MISSING 반환에는 그 지시가 붙지 않는다(없는 파일을 읽으라고 하지 않는다)
grep '^\[SKILL REFERENCE\] NEED_DOCS(DESIGN_MISSING)' "$LOG_TARGET/.need-docs-design.out" | grep -Fq "[CONVENTIONS]" \
  && fail "로딩 경로: conventions.md 가 없는데 DESIGN_MISSING 의 [SKILL REFERENCE] 줄에 Read 지시가 붙음"
consensus_start_count="$(grep -c 'consensus-loop design 시작' "$LOG_TARGET/.agent-work/live.log")"
[ "$consensus_start_count" = 1 ] \
  || fail "중첩 tee: consensus-loop 시작 로그가 ${consensus_start_count}회 기록됨 (1회여야 함)"

: > "$LOG_TARGET/.agent-work/live.log"
set +e
(cd "$LOG_TARGET" && FEATURE_LIVE_TEE=1 bash "$LOG_SKILL/scripts/impl-review-loop.sh") \
  >> "$LOG_TARGET/.agent-work/live.log" 2>&1
set -e
impl_start_count="$(grep -c 'impl-review-loop 시작' "$LOG_TARGET/.agent-work/live.log")"
[ "$impl_start_count" = 1 ] \
  || fail "중첩 tee: impl-review-loop 시작 로그가 ${impl_start_count}회 기록됨 (1회여야 함)"

# 워커 원문 로그를 reviews/에 보존하면서 live.log에도 실시간 전달한다.
printf '# implementation\n\n## all\n전체 계약\n' > "$LOG_TARGET/.agent-work/implementation.md"   # unit references(implementation.md#all)가 가리키는 절
printf '# approach\n' > "$LOG_TARGET/.agent-work/approach.md"
fake_scope "$LOG_TARGET" src/x.txt            # impl PASS 지문에 manifest 가 들어가므로 합의보다 먼저 둔다
fake_consensus_pass "$LOG_TARGET" impl
# 워커 원문: codex --json stdout 은 <raw>.events.jsonl, stderr 진단은 <raw>.stderr.log 에 분리 보존된다(live.log 로 tee 하지 않는다 — JSONL 보호).
# 가짜 codex 는 stderr 에 마커를 찍고 호출 횟수를 저장소 밖 카운터에 남긴다. UNDECIDED 는 doc-gap-resume.json(사용자 대기)을 남기므로 다음 사례 전에 치운다.
export FAKE_WORKER_COUNT="$SCRATCH/log-target.worker-calls"
clear_gap() { [ ! -f "$LOG_TARGET/.agent-work/doc-gap-resume.json" ] || mv "$LOG_TARGET/.agent-work/doc-gap-resume.json" "$SCRATCH/doc-gap-resume.$RANDOM$RANDOM.json"; }
FAKE_CODEX="$LOG_TARGET/fake-codex"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -e' \
  '# codex 세션 계약: exec resume --help / thread.started 첫 이벤트(재개면 같은 id)' \
  'RESUME_TID=""' \
  'if [ "$1" = exec ] && [ "$2" = resume ]; then' \
  '  [ "$3" = --help ] && { echo "usage: codex exec resume [--json] [--output-schema] [--output-last-message] [--sandbox]"; exit 0; }' \
  '  RESUME_TID="$3"' \
  'fi' \
  'printf "{\"type\":\"thread.started\",\"thread_id\":\"%s\"}\n" "${RESUME_TID:-mock-thread-$$}"' \
  'output_file=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in -o) output_file="$2"; shift 2;; *) shift;; esac' \
  'done' \
  'printf "WORKER_STREAM_MARKER\\n" >&2; echo called >> "$FAKE_WORKER_COUNT"' \
  'if [ "${FAKE_TAMPER_BASELINE:-0}" = 1 ]; then printf "%s\\n" 4b825dc642cb6eb9a060e54bf8d69288fbee4904 > .agent-work/worker-baseline.tree; echo tampered >> src/existing-under-root.txt; fi' \
  'if [ "${FAKE_TAMPER_BOTH:-0}" = 1 ]; then printf "%s\\n" 4b825dc642cb6eb9a060e54bf8d69288fbee4904 > .agent-work/worker-baseline.tree; for m in .agent-work/feature-scope.json .agent-work/feature-scope.lock.json; do jq -c ".files += [\"src/z.txt\"]" "$m" > "$m.tmp" && mv "$m.tmp" "$m"; done; echo tampered-both >> src/existing-under-root.txt; fi' \
  'printf '\''{"status":"UNDECIDED","undecided":[{"kind":"'"'"'"$FAKE_KIND"'"'"'","location":"test","paths":["src/x.txt"],"decision_needed":"test decision","options":[]}],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}'\'' > "$output_file"' \
  > "$FAKE_CODEX"
chmod +x "$FAKE_CODEX"
sed -i.sedbak "s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$FAKE_CODEX\"|" "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' \
  > "$LOG_TARGET/.agent-work/run-state.json"
: > "$LOG_TARGET/.agent-work/live.log"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >"$SCRATCH/need-user.out" 2>&1
worker_rc=$?
set -e
[ "$worker_rc" = 2 ] || fail "워커 스트리밍: USER_DECISION 종료 코드가 2가 아님 ($worker_rc)"
ref_hint_ok "$SCRATCH/need-user.out" 'NEED_USER(UNDECIDED)' exit-states-resume.md \
  || fail "로딩 경로: NEED_USER(UNDECIDED) 반환에 references/exit-states-resume.md 안내가 없음: $(grep 'SKILL REFERENCE' "$SCRATCH/need-user.out")"
[ -f "$LOG_TARGET/.agent-work/worker-baseline.tree" ] || fail "워커 기준선: 러너가 worker-baseline.tree 를 기록하지 않음"
(cd "$LOG_TARGET" && git cat-file -e "$(cat .agent-work/worker-baseline.tree)") || fail "워커 기준선: tree 객체가 저장소에 없음"
worker_raw="$(ls "$LOG_TARGET"/.agent-work/units/01-all/worker-*.log.stderr.log | tail -1)"   # unit 워커 원문은 units/<id>/ 에 남는다
[ "$(grep -c 'WORKER_STREAM_MARKER' "$worker_raw")" = 1 ] \
  || fail "워커 원문: stderr 진단 로그에 출력이 정확히 1회 보존되지 않음"
[ -f "${worker_raw%.stderr.log}.events.jsonl" ] || fail "워커 원문: --json 이벤트 JSONL 이 stderr 와 분리 보존되지 않음"
grep -q 'WORKER_STREAM_MARKER' "${worker_raw%.stderr.log}.events.jsonl" && fail "워커 원문: stderr 가 이벤트 JSONL 에 섞임"
jq -e '.origin=="worker" and .unit_id=="01-all" and .next_step=="WAITING_USER" and .gaps[0].tag=="worker-gap=01-all#1"' "$LOG_TARGET/.agent-work/doc-gap-resume.json" >/dev/null \
  || fail "워커 USER_DECISION: doc-gap-resume.json(WAITING_USER) 이 기록되지 않음"
clear_gap
# DOC_GAP 만 있어도 impl 재합의(NEED_DOCS/APPROACH_GAP)가 아니라 USER_DECISION 과 같은 사용자 결정 경로(NEED_USER/UNDECIDED, stage doc-gap)다
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > "$LOG_TARGET/.agent-work/run-state.json"
: > "$FAKE_WORKER_COUNT"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=DOC_GAP bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
docgap_rc=$?
set -e
[ "$docgap_rc" = 2 ] || fail "DOC_GAP: 종료 코드가 2(NEED_USER)가 아님 ($docgap_rc)"
[ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = UNDECIDED ] || fail "DOC_GAP: reason 이 UNDECIDED 가 아님 ($(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json"))"
[ "$(jq -r '.stage' "$LOG_TARGET/.agent-work/run-state.json")" = worker ] || fail "DOC_GAP: 재개 stage 가 worker 가 아님(impl 재합의로 되돌리면 안 됨)"
[ -s "$FAKE_WORKER_COUNT" ] || fail "DOC_GAP: 워커가 호출되지 않음"
[ "$(jq -r '.gaps[0].impact' "$LOG_TARGET/.agent-work/doc-gap-resume.json")" = DOC_GAP ] || fail "DOC_GAP: 체크포인트에 kind(진단 정보)가 남지 않음"
clear_gap
# 필수 워커 스킬 누락 → run_worker 가 실제로 중단하고(exit 1) 가짜 codex 를 부르지 않는다 (load_worker_rules 단독 호출로는 잡히지 않는 경로)
sed -i.sedbak 's/^WORKER_SKILLS=.*/WORKER_SKILLS=("missing-skill")/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > "$LOG_TARGET/.agent-work/run-state.json"
: > "$LOG_TARGET/.agent-work/live.log"; : > "$FAKE_WORKER_COUNT"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
missing_skill_rc=$?
set -e
[ "$missing_skill_rc" = 1 ] || fail "필수 워커 스킬 누락: 러너 종료 코드가 1 이 아님 ($missing_skill_rc)"
grep -q "필수 워커 스킬 'missing-skill' 없음" "$LOG_TARGET/.agent-work/live.log" || fail "필수 워커 스킬 누락: 실패 사유가 기록되지 않음"
[ ! -s "$FAKE_WORKER_COUNT" ] || fail "필수 워커 스킬 누락: 워커(codex)가 호출됨"
sed -i.sedbak 's/^WORKER_SKILLS=.*/WORKER_SKILLS=()/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
# worker 단계 진입 시 원본 != lock → exit 2, run-state NEED_USER/SCOPE_MANIFEST_CHANGED, codex 호출 0 (set -e 아래 stop_need_user 도달 확인)
[ -f "$LOG_TARGET/.agent-work/feature-scope.lock.json" ] || fail "scope lock: 러너가 feature-scope.lock.json 을 확정하지 않음"
cp "$LOG_TARGET/.agent-work/feature-scope.json" "$LOG_TARGET/.agent-work/feature-scope.json.orig"
jq -c '.files += ["src/y.txt"]' "$LOG_TARGET/.agent-work/feature-scope.json.orig" > "$LOG_TARGET/.agent-work/feature-scope.json"
# 원본 manifest 는 impl PASS 지문에 포함되므로 러너는 먼저 impl 재합의로 돌아간다(설계된 흐름). 사용자가 재합의를 마친 뒤
# lock 을 지우지 않고 재실행한 상황을 만들기 위해 impl 체크포인트를 다시 만든다 (그동안만 CODEX_BIN=true).
sed -i.sedbak "s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"true\"|" "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
fake_consensus_pass "$LOG_TARGET" impl
sed -i.sedbak "s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$FAKE_CODEX\"|" "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > "$LOG_TARGET/.agent-work/run-state.json"
: > "$LOG_TARGET/.agent-work/live.log"; : > "$FAKE_WORKER_COUNT"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
lock_mismatch_rc=$?
set -e
[ "$lock_mismatch_rc" = 2 ] || fail "scope lock 불일치: 러너 종료 코드가 2 가 아님 ($lock_mismatch_rc)"
[ "$(jq -r '.status' "$LOG_TARGET/.agent-work/run-state.json")" = NEED_USER ] || fail "scope lock 불일치: run-state status 가 NEED_USER 가 아님 ($(jq -r '.status' "$LOG_TARGET/.agent-work/run-state.json"))"
[ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = SCOPE_MANIFEST_CHANGED ] || fail "scope lock 불일치: reason 이 SCOPE_MANIFEST_CHANGED 가 아님"
[ ! -s "$FAKE_WORKER_COUNT" ] || fail "scope lock 불일치: 워커(codex)가 호출됨"
cp "$LOG_TARGET/.agent-work/feature-scope.json.orig" "$LOG_TARGET/.agent-work/feature-scope.json"
# 워커가 worker-baseline.tree 를 빈 tree 로 바꾸고 new_file_roots 아래 기존 파일을 수정 → SCOPE_BASELINE_CHANGED, review 미진입, 원복 없음
# 준비: 기준선에 있는 root 아래 파일을 커밋하고, roots 가 있는 manifest 로 원본·lock 을 맞춘 뒤 impl 체크포인트를 다시 만든다
mkdir -p "$LOG_TARGET/src" && echo "existing" > "$LOG_TARGET/src/existing-under-root.txt"
(cd "$LOG_TARGET" && git add src/existing-under-root.txt && git -c user.email=smoke@test -c user.name=smoke commit -qm "existing under root")
jq -c '.new_file_roots = ["src/"]' "$LOG_TARGET/.agent-work/feature-scope.json.orig" > "$LOG_TARGET/.agent-work/feature-scope.json"
cp "$LOG_TARGET/.agent-work/feature-scope.json" "$LOG_TARGET/.agent-work/feature-scope.lock.json"
sed -i.sedbak "s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"true\"|" "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
fake_consensus_pass "$LOG_TARGET" impl
sed -i.sedbak "s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$FAKE_CODEX\"|" "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
(cd "$LOG_TARGET" && bash -c 'source .claude/skills/feature/scripts/lib/bootstrap.sh; snapshot_worktree_tree > .agent-work/worker-baseline.tree')   # 기준선에 existing-under-root.txt 포함
cp "$LOG_TARGET/.agent-work/worker-baseline.tree" "$LOG_TARGET/.agent-work/worker-baseline.tree.keep"
# 이전 하위 사례의 unit 시도 산출물(UNDECIDED 결과 + 옛 tree)을 치운다 — 위에서 파일을 커밋해 작업 트리가 그 시도와 달라졌고,
# 러너의 재개 판정은 그런 드리프트를 WORKER_OUTCOME_UNCERTAIN 으로 막는다(생산 동작). 이 하위 사례는 워커 진입 직후 시나리오를 새로 구성한다.
rm -rf "$LOG_TARGET/.agent-work/units" "$LOG_TARGET/.agent-work/implementation-context.json"
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > "$LOG_TARGET/.agent-work/run-state.json"
: > "$LOG_TARGET/.agent-work/live.log"
set +e
(cd "$LOG_TARGET" && FAKE_TAMPER_BASELINE=1 FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
tamper_rc=$?
set -e
[ "$tamper_rc" = 2 ] || fail "기준선 조작: 러너 종료 코드가 2 가 아님 ($tamper_rc)"
[ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = SCOPE_BASELINE_CHANGED ] || fail "기준선 조작: reason 이 SCOPE_BASELINE_CHANGED 가 아님 ($(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json"))"
[ "$(jq -r '.stage' "$LOG_TARGET/.agent-work/run-state.json")" = worker ] || fail "기준선 조작: review 단계로 진입함"
[ "$(tail -1 "$LOG_TARGET/src/existing-under-root.txt")" = tampered ] || fail "기준선 조작: 워커의 기존 파일 변경이 원복됨(보존돼야 함)"
[ "$(cat "$LOG_TARGET/.agent-work/worker-baseline.tree")" = 4b825dc642cb6eb9a060e54bf8d69288fbee4904 ] || fail "기준선 조작: 기준선 파일이 자동 복구됨(복구 금지)"
[ "$(jq -r .expected "$LOG_TARGET/.agent-work/worker-baseline.guard.json")" = "$(cat "$LOG_TARGET/.agent-work/worker-baseline.tree.keep")" ] || fail "기준선 조작: 가드 기대값이 원래 기준선이 아님"
# 복구 없이 같은 명령 재실행 → 다시 SCOPE_BASELINE_CHANGED, codex 호출 0회
: > "$LOG_TARGET/.agent-work/live.log"; : > "$FAKE_WORKER_COUNT"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
tamper_rerun_rc=$?
set -e
[ "$tamper_rerun_rc" = 2 ] || fail "기준선 미복구 재실행: 종료 코드가 2 가 아님 ($tamper_rerun_rc)"
[ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = SCOPE_BASELINE_CHANGED ] || fail "기준선 미복구 재실행: reason 이 SCOPE_BASELINE_CHANGED 가 아님"
[ ! -s "$FAKE_WORKER_COUNT" ] || fail "기준선 미복구 재실행: 워커(codex)가 호출됨"
# 원래 값으로 복구하면 워커가 재개된다 (가짜 워커는 USER_DECISION 을 내므로 exit 2 / UNDECIDED)
cp "$LOG_TARGET/.agent-work/worker-baseline.tree.keep" "$LOG_TARGET/.agent-work/worker-baseline.tree"
: > "$LOG_TARGET/.agent-work/live.log"; : > "$FAKE_WORKER_COUNT"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
restored_rc=$?
set -e
[ "$restored_rc" = 2 ] && [ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = UNDECIDED ] || fail "기준선 복구 후: 워커가 재개되지 않음 (rc $restored_rc, reason $(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json"))"
[ -s "$FAKE_WORKER_COUNT" ] || fail "기준선 복구 후: 워커(codex)가 호출되지 않음"
[ "$(jq -r .active "$LOG_TARGET/.agent-work/worker-baseline.guard.json")" = false ] || fail "기준선 복구 후: 가드가 비활성화되지 않음"
clear_gap
# 복합 변경: 기준선 + manifest(원본·lock) 를 함께 바꾸면 SCOPE_MANIFEST_CHANGED 로 먼저 멈추더라도 가드가 남아야 한다
cp "$LOG_TARGET/.agent-work/feature-scope.json" "$LOG_TARGET/.agent-work/feature-scope.json.keep"
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > "$LOG_TARGET/.agent-work/run-state.json"
: > "$LOG_TARGET/.agent-work/live.log"
set +e
(cd "$LOG_TARGET" && FAKE_TAMPER_BOTH=1 FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
both_rc=$?
set -e
[ "$both_rc" = 2 ] || fail "복합 변조: 종료 코드가 2 가 아님 ($both_rc)"
[ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = SCOPE_MANIFEST_CHANGED ] || fail "복합 변조: 첫 사유가 SCOPE_MANIFEST_CHANGED 가 아님 ($(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json"))"
[ "$(jq -r .active "$LOG_TARGET/.agent-work/worker-baseline.guard.json")" = true ] || fail "복합 변조: manifest 사유로 먼저 멈췄는데 기준선 가드가 기록되지 않음"
# manifest 만 복구(원본·lock)하고 재실행 → SCOPE_BASELINE_CHANGED, codex 0회
cp "$LOG_TARGET/.agent-work/feature-scope.json.keep" "$LOG_TARGET/.agent-work/feature-scope.json"
cp "$LOG_TARGET/.agent-work/feature-scope.json.keep" "$LOG_TARGET/.agent-work/feature-scope.lock.json"
: > "$LOG_TARGET/.agent-work/live.log"; : > "$FAKE_WORKER_COUNT"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
both_rerun_rc=$?
set -e
[ "$both_rerun_rc" = 2 ] && [ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = SCOPE_BASELINE_CHANGED ] || fail "복합 변조: manifest 만 복구한 재실행이 막히지 않음 (rc $both_rerun_rc, reason $(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json"))"
[ ! -s "$FAKE_WORKER_COUNT" ] || fail "복합 변조: 기준선 미복구 재실행에서 워커(codex)가 호출됨"
# 기준선까지 복구하면 재개
cp "$LOG_TARGET/.agent-work/worker-baseline.tree.keep" "$LOG_TARGET/.agent-work/worker-baseline.tree"
: > "$LOG_TARGET/.agent-work/live.log"; : > "$FAKE_WORKER_COUNT"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
both_restored_rc=$?
set -e
[ "$both_restored_rc" = 2 ] && [ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = UNDECIDED ] || fail "복합 변조 복구 후: 워커가 재개되지 않음 (rc $both_restored_rc, reason $(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json"))"
[ -s "$FAKE_WORKER_COUNT" ] || fail "복합 변조 복구 후: 워커(codex)가 호출되지 않음"
clear_gap
echo "[OK] 8. live.log 아카이브 + 중첩 tee 중복 방지 + 워커 원문(events.jsonl/stderr.log 분리) + 워커 DOC_GAP/USER_DECISION → 사용자 결정 체크포인트 + 필수 워커 스킬 누락 시 워커 미실행 + scope lock 불일치 시 NEED_USER + 기준선 조작 시 SCOPE_BASELINE_CHANGED(미복구 재실행 재중단·복구 후 재개·복합 변조 시 가드 보존)"

# ---------- 9. feature-live 저장소별 단일 실행 lock ----------
chmod +x "$LOG_TARGET/feature-live"
: > "$LOG_TARGET/.agent-work/live.log"
"$LOG_TARGET/feature-live" >/dev/null 2>&1 &
viewer_pid=$!
for _ in $(seq 1 50); do
  [ -f "$LOG_TARGET/.agent-work/.feature-live.lock/viewer.pid" ] && break
  sleep 0.02
done
[ -f "$LOG_TARGET/.agent-work/.feature-live.lock/viewer.pid" ] \
  || fail "feature-live lock: viewer.pid가 생성되지 않음"
[ "$(cat "$LOG_TARGET/.agent-work/.feature-live.lock/viewer.pid")" = "$viewer_pid" ] \
  || fail "feature-live lock: 실제 뷰어 PID와 기록값이 다름"

duplicate_viewer_output="$("$LOG_TARGET/feature-live")"
grep -q '이미 실행 중' <<< "$duplicate_viewer_output" \
  || fail "feature-live lock: 두 번째 실행이 기존 뷰어를 감지하지 못함"
kill "$viewer_pid"
wait "$viewer_pid" 2>/dev/null || true
[ ! -e "$LOG_TARGET/.agent-work/.feature-live.lock" ] \
  || fail "feature-live lock: 뷰어 종료 후 lock이 정리되지 않음"

mkdir -p "$LOG_TARGET/.agent-work/.feature-live.lock"
printf '99999999\n' > "$LOG_TARGET/.agent-work/.feature-live.lock/viewer.pid"
"$LOG_TARGET/feature-live" >/dev/null 2>&1 &
replacement_viewer_pid=$!
for _ in $(seq 1 50); do
  replacement_recorded_pid="$(cat "$LOG_TARGET/.agent-work/.feature-live.lock/viewer.pid" 2>/dev/null || true)"
  [ "$replacement_recorded_pid" = "$replacement_viewer_pid" ] && break
  sleep 0.02
done
[ "$replacement_recorded_pid" = "$replacement_viewer_pid" ] \
  || fail "feature-live lock: stale lock을 회수하지 못함"
kill "$replacement_viewer_pid"
wait "$replacement_viewer_pid" 2>/dev/null || true
echo "[OK] 9. feature-live 저장소별 단일 실행 lock"

# ---------- 10. 구현 리뷰 루프 — 리뷰어 계약 연계 검사 (가짜 claude, LLM 호출 없음) ----------
REVIEW_TARGET="$SCRATCH/review"
REVIEW_SKILL="$REVIEW_TARGET/.claude/skills/feature"
REVIEW_SIDE="$SCRATCH/review.side"; mkdir -p "$REVIEW_SIDE"
git init -q "$REVIEW_TARGET"
bash "$SOURCE_ROOT/install.sh" "$REVIEW_TARGET" >/dev/null
chmod -x "$REVIEW_TARGET/feature-live"
# 가짜 claude: FAKE_REVIEW 파일을 structured_output 으로 감싸 출력 (카운터·픽스처는 저장소 밖 — 지문 보호)
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[ "${FEATURE_ROLE_CHILD:-}" = 1 ] || { echo "child claude without FEATURE_ROLE_CHILD=1: $*" >&2; exit 9; }' \
  'jq -n -c --slurpfile r "$FAKE_REVIEW" '"'"'{structured_output: $r[0], session_id:"fake", total_cost_usd:0, usage:{input_tokens:0,output_tokens:0,cache_read_input_tokens:0,cache_creation_input_tokens:0}}'"'" \
  > "$REVIEW_SIDE/fake-claude"
chmod +x "$REVIEW_SIDE/fake-claude"
# 이 절의 가짜는 claude 형태뿐이다 — production config 의 REVIEWER/FIXER 모델이 codex 로 라우팅돼도 가짜 claude 가 쓰이도록 역할 CLI 를 고정한다((f) 라우팅 절만 해제)
sed -i.sedbak "s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"legacy_cli\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$REVIEW_SIDE/fake-claude\"|; s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"true\"|; s/^TEST_CMD=.*/TEST_CMD=\"true\"/; s/^LINT_CMD=.*/LINT_CMD=\"true\"/; s/^MAX_IMPL_ROUNDS=.*/MAX_IMPL_ROUNDS=0/; s/^REVIEWER_CLI=.*/REVIEWER_CLI=\"claude\"/; s/^FIXER_CLI=.*/FIXER_CLI=\"claude\"/" "$REVIEW_SKILL/config.sh" && rm -f "$REVIEW_SKILL/config.sh.sedbak"
mkdir -p "$REVIEW_TARGET/src" "$REVIEW_TARGET/.agent-work/reviews"
printf 'base\n' > "$REVIEW_TARGET/src/a.txt"
printf 'base\n' > "$REVIEW_TARGET/src/b.txt"
(cd "$REVIEW_TARGET" && git add -A && git -c user.email=t@t -c user.name=t commit -qm base)
# 피처 이전부터 있던 사용자의 미커밋 변경(b.txt) → 워커 진입 기준선에 포함돼 리뷰 diff 에 나오면 안 된다
printf 'user edit before feature\n' > "$REVIEW_TARGET/src/b.txt"
(cd "$REVIEW_TARGET" && bash -c 'source .claude/skills/feature/scripts/lib/bootstrap.sh; snapshot_worktree_tree' > .agent-work/worker-baseline.tree)
printf 'changed\n' > "$REVIEW_TARGET/src/a.txt"
printf 'new\n' > "$REVIEW_TARGET/src/new.txt"
for doc in design implementation approach; do printf '# %s\n' "$doc" > "$REVIEW_TARGET/.agent-work/$doc.md"; done
printf '\n## all\n전체 계약\n' >> "$REVIEW_TARGET/.agent-work/implementation.md"   # unit references(implementation.md#all)가 가리키는 절
fake_scope "$REVIEW_TARGET" src/a.txt src/new.txt   # b.txt 는 범위 밖 — 리뷰 diff·승인 지문에서 제외된다 (impl PASS 지문에 포함되므로 합의보다 먼저)
fake_consensus_pass "$REVIEW_TARGET" design
fake_consensus_pass "$REVIEW_TARGET" impl
printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[]}\n' > "$REVIEW_TARGET/.agent-work/worker-result.json"
review_issue='{"id":"R-01","action":"FIX_CODE","category":"CONTRACT_VIOLATION","evidence_type":"DIRECT_MISMATCH","basis_refs":["approach.md:L1"],"code_refs":["src/a.txt:L1-L1"],"reachable_scenario":"","impact":"","why_blocks_now":"x","required_outcome":"y","origin":"ROUND_1","previous_issue_id":"","fix_ref":"","user_question":"","options":[]}'
run_review_loop() { # fake-review-json → exit code (stdout 은 run.log)
  printf '%s\n' "$1" > "$REVIEW_SIDE/review.json"
  # 각 사례는 새 리뷰어 호출을 전제한다 — 직전 사례의 APPROVE 체크포인트가 재사용되지 않게 포맷 버전 불일치로 무효화
  printf '{"version":0}\n' > "$REVIEW_TARGET/.agent-work/review-impl.json"
  local rc=0   # 함수 안에서 set ±e 를 토글하지 않는다 — 호출자의 errexit 상태를 바꾼다
  # --new-attempt: 직전 사례가 REVIEW_OUTPUT_INVALID 기록을 남겼으면 명시적 새 리뷰 시도로 닫는다(없으면 WARN 뿐 — 일반 재실행은 리뷰어 0회로 같은 진단을 돌려준다)
  (cd "$REVIEW_TARGET" && FAKE_REVIEW="$REVIEW_SIDE/review.json" FEATURE_LIVE_TEE=1 bash "$REVIEW_SKILL/scripts/impl-review-loop.sh" --new-attempt) > "$REVIEW_SIDE/run.log" 2>&1 || rc=$?
  return $rc
}
# 리뷰어 출력 계약 위반은 exit 4 / state.json REVIEW_OUTPUT_INVALID / 구조화 진단(rule_id) — ENV_ERROR(exit 1)로 뭉개지지 않는다
expect_review_invalid() { # 사례-이름 rule_id
  local rc=0; run_review_loop "$3" || rc=$?
  [ "$rc" = 4 ] || { tail -5 "$REVIEW_SIDE/run.log" >&2; fail "리뷰 루프: $1 — 종료 코드가 4(REVIEW_OUTPUT_INVALID)가 아님 ($rc)"; }
  [ "$(jq -r '.status' "$REVIEW_TARGET/.agent-work/state.json")" = REVIEW_OUTPUT_INVALID ] || fail "리뷰 루프: $1 — state.json 이 REVIEW_OUTPUT_INVALID 가 아님"
  jq -e --arg r "$2" '.active==true and (.errors|length)>0 and any(.errors[]; .rule_id==$r and has("issue_id") and has("field") and has("observed") and has("expected")) and (.result_sha256|length)==64 and (.input_fingerprint|length)==64' \
    "$REVIEW_TARGET/.agent-work/reviews/invalid-review.json" >/dev/null || fail "리뷰 루프: $1 — invalid-review.json 에 구조화 진단($2)이 없음: $(cat "$REVIEW_TARGET/.agent-work/reviews/invalid-review.json" 2>/dev/null)"
  [ ! -f "$REVIEW_TARGET/.agent-work/approved.fingerprint" ] || fail "리뷰 루프: $1 — 무효 출력인데 승인 지문이 생김"
}
# (a) APPROVE → exit 0, 승인 지문 생성, diff 에 untracked 신규 파일 포함
run_review_loop "{\"schema_version\":$REVIEWER_CONTRACT,\"verdict\":\"APPROVE\",\"issues\":[]}" || fail "리뷰 루프: APPROVE 가 exit 0 이 아님"
[ -f "$REVIEW_TARGET/.agent-work/approved.fingerprint" ] || fail "리뷰 루프: 승인 지문 미생성"
grep -q 'src/new.txt' "$REVIEW_TARGET/.agent-work/reviews/impl-attempt-01/diff-round-01.patch" || fail "리뷰 루프: untracked 신규 파일이 리뷰 diff 에 없음"
grep -q 'src/b.txt' "$REVIEW_TARGET/.agent-work/reviews/impl-attempt-01/diff-round-01.patch" && fail "리뷰 루프: 기준선 이전 사용자 변경(b.txt)이 리뷰 diff 에 섞임"
grep -q '리뷰 기준선: 워커 진입 직전 tree' "$REVIEW_SIDE/run.log" || fail "리뷰 루프: 기준선 tree 를 쓰지 않음"
# 세션은 stage/attempt 단위 — 리뷰어 세션 파일은 attempt 번호를 달고, 역할 전체를 잇는 옛 이름(.session-reviewer)은 생기지 않는다
[ -f "$REVIEW_TARGET/.agent-work/.session-reviewer-a01" ] || fail "세션 범위: 리뷰어 세션이 attempt 단위(.session-reviewer-a01)가 아님"
[ ! -e "$REVIEW_TARGET/.agent-work/.session-reviewer" ] || fail "세션 범위: 역할 전체를 잇는 .session-reviewer 가 생성됨"
mv "$REVIEW_TARGET/.agent-work/approved.fingerprint" "$REVIEW_SIDE/approved.fingerprint.a"   # (a) 의 승인 지문이 아래 무효 사례의 "승인 지문 없음" 단언에 섞이지 않게 (삭제 대신 이동)
# (b) Round 1 인데 origin=FIX_REGRESSION → 출력 계약 위반(REVIEW_OUTPUT_INVALID, exit 4) — origin 과 fix_ref 위반이 따로 기록된다
expect_review_invalid "Round 1 의 FIX_REGRESSION origin" INVALID_ORIGIN "$(printf '%s' "$review_issue" | jq -c --argjson v "$REVIEWER_CONTRACT" '{schema_version:$v,verdict:"REQUEST_CHANGES",issues:[. + {origin:"FIX_REGRESSION",fix_ref:"src/a.txt:L1-L1"}]}')"
jq -e '[.errors[].rule_id] | index("INVALID_FIX_REF") != null' "$REVIEW_TARGET/.agent-work/reviews/invalid-review.json" >/dev/null || fail "리뷰 루프: 여러 위반이 하나로 뭉쳐짐(INVALID_FIX_REF 누락)"
# (c) schema_version 불일치 → REVIEW_OUTPUT_INVALID
expect_review_invalid "구버전 schema_version" SCHEMA_VERSION_MISMATCH '{"schema_version":1,"verdict":"APPROVE","issues":[]}'
# (c2) verdict 와 issues 모순 → REVIEW_OUTPUT_INVALID
expect_review_invalid "APPROVE 인데 issue 있음" VERDICT_INCONSISTENT "$(printf '%s' "$review_issue" | jq -c --argjson v "$REVIEWER_CONTRACT" '{schema_version:$v,verdict:"APPROVE",issues:[.]}')"
# (d) FIX_CODE 인데 required_outcome 비어 있음 → REVIEW_OUTPUT_INVALID
expect_review_invalid "required_outcome 없는 FIX_CODE" SCHEMA_INVALID "$(printf '%s' "$review_issue" | jq -c --argjson v "$REVIEWER_CONTRACT" '{schema_version:$v,verdict:"REQUEST_CHANGES",issues:[. + {required_outcome:""}]}')"
# (e) DOC_GAP → user_question/options 계약 + exit 3 + doc-gap-resume.json(WAITING_USER), 러너는 NEED_USER(REVIEW_DOC_GAP) + stage=doc-gap (impl 재합의 아님)
expect_review_invalid "user_question/options 없는 DOC_GAP" ACTION_FIELDS "$(printf '%s' "$review_issue" | jq -c --argjson v "$REVIEWER_CONTRACT" '{schema_version:$v,verdict:"REQUEST_CHANGES",issues:[. + {action:"DOC_GAP"}]}')"
expect_review_invalid "user_question/options 가 있는 FIX_CODE" ACTION_FIELDS "$(printf '%s' "$review_issue" | jq -c --argjson v "$REVIEWER_CONTRACT" '{schema_version:$v,verdict:"REQUEST_CHANGES",issues:[. + {user_question:"q?",options:["A","B"]}]}')"
# fix_ref 정의는 한 문장이다 — config.sh(REVIEW_FIX_REF_RULE) · 리뷰어 프롬프트 · 스키마 설명이 글자 그대로 같아야 한다
fix_ref_rule="$(sed -n "s/^REVIEW_FIX_REF_RULE='\(.*\)'\$/\1/p" "$SOURCE_ROOT/.claude/skills/feature/scripts/lib/contract/review.sh")"
[ -n "$fix_ref_rule" ] || fail "fix_ref 계약: scripts/lib/contract/review.sh 에 REVIEW_FIX_REF_RULE 이 없음"
grep -qF -- "$fix_ref_rule" "$SOURCE_ROOT/.claude/skills/feature/prompts/reviewer.md" || fail "fix_ref 계약: reviewer.md 의 문장이 REVIEW_FIX_REF_RULE 과 다름"
[ "$(jq -r '.properties.issues.items.properties.fix_ref.description' "$SOURCE_ROOT/.claude/skills/feature/schemas/impl-review.schema.json" | grep -cF -- "$fix_ref_rule")" = 1 ] || fail "fix_ref 계약: 스키마 설명의 문장이 REVIEW_FIX_REF_RULE 과 다름"
grep -qF '$REVIEW_FIX_REF_RULE' "$SOURCE_ROOT/.claude/skills/feature/scripts/impl-review-loop.sh" || fail "fix_ref 계약: 리뷰 루프가 REVIEW_FIX_REF_RULE 을 쓰지 않음"
set +e; run_review_loop "$(printf '%s' "$review_issue" | jq -c --argjson v "$REVIEWER_CONTRACT" '{schema_version:$v,verdict:"REQUEST_CHANGES",issues:[. + {action:"DOC_GAP",user_question:"Map 인가 선형 탐색인가",options:["Map","linear"]}]}')"; docgap_loop_rc=$?; set -e
[ "$docgap_loop_rc" = 3 ] || fail "리뷰 루프: DOC_GAP 종료 코드가 3 이 아님 ($docgap_loop_rc)"
[ "$(jq -r '.status' "$REVIEW_TARGET/.agent-work/state.json")" = DOC_GAP ] || fail "리뷰 루프: state.json 이 DOC_GAP 이 아님"
jq -e '.version==1 and .origin=="review" and .next_step=="WAITING_USER" and .gaps[0].key=="R-01" and .gaps[0].tag=="review-issue=R-01" and (.gaps[0].options|length)==2 and .source_tree!=""' "$REVIEW_TARGET/.agent-work/doc-gap-resume.json" >/dev/null \
  || fail "리뷰 루프: doc-gap-resume.json 이 WAITING_USER 로 기록되지 않음: $(cat "$REVIEW_TARGET/.agent-work/doc-gap-resume.json" 2>/dev/null)"
printf '{"stage":"review","test_retries":0,"stale_count":0,"history":[]}\n' > "$REVIEW_TARGET/.agent-work/run-state.json"
set +e
(cd "$REVIEW_TARGET" && FAKE_REVIEW="$REVIEW_SIDE/review.json" bash "$REVIEW_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
review_docgap_rc=$?
set -e
[ "$review_docgap_rc" = 2 ] || fail "리뷰어 DOC_GAP: 러너 종료 코드가 2(NEED_USER)가 아님 ($review_docgap_rc)"
[ "$(jq -r '.reason' "$REVIEW_TARGET/.agent-work/run-state.json")" = REVIEW_DOC_GAP ] || fail "리뷰어 DOC_GAP: reason 이 REVIEW_DOC_GAP 이 아님 ($(jq -r '.reason' "$REVIEW_TARGET/.agent-work/run-state.json"))"
[ "$(jq -r '.stage' "$REVIEW_TARGET/.agent-work/run-state.json")" = doc-gap ] || fail "리뷰어 DOC_GAP: 재개 stage 가 doc-gap 이 아님"
mv "$REVIEW_TARGET/.agent-work/doc-gap-resume.json" "$REVIEW_SIDE/doc-gap-resume.e.json"   # 이후 절은 pending gap 없이 계속 (삭제 대신 이동)
# (f) 역할 → CLI 라우팅: REVIEWER_MODEL 을 gpt-* 로 바꾸면 같은 루프가 codex 로 리뷰어를 부른다 (읽기 전용 sandbox + 스키마 + -o), claude 는 호출 0회
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# 가짜 codex: 리뷰어 호출 형태를 검사하고 FAKE_REVIEW 를 -o 경로에 쓴다' \
  'case " $* " in *" --sandbox read-only "*) ;; *) echo "codex reviewer without read-only sandbox: $*" >&2; exit 9;; esac' \
  'case " $* " in *" --output-schema "*) ;; *) echo "codex reviewer without --output-schema: $*" >&2; exit 9;; esac' \
  'case " $* " in *" -m gpt-6-astra "*) ;; *) echo "codex reviewer with wrong model: $*" >&2; exit 9;; esac' \
  'out=""; while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done' \
  'printf "{\"type\":\"thread.started\",\"thread_id\":\"mock-thread-%s\"}\n" "$$"' \
  'printf "codex\n" >> "$FAKE_COUNT.codex"; cp "$FAKE_REVIEW" "$out"' \
  > "$REVIEW_SIDE/fake-codex-reviewer"
printf '%s\n' '#!/usr/bin/env bash' 'printf "claude\n" >> "$FAKE_COUNT.claude"; exit 9' > "$REVIEW_SIDE/fake-claude-never"
chmod +x "$REVIEW_SIDE/fake-codex-reviewer" "$REVIEW_SIDE/fake-claude-never"
cp "$REVIEW_SKILL/config.sh" "$REVIEW_SIDE/config.before-routing.sh"
sed -i.sedbak "s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"legacy_cli\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$REVIEW_SIDE/fake-claude-never\"|; s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$REVIEW_SIDE/fake-codex-reviewer\"|; s/^REVIEWER_MODEL=.*/REVIEWER_MODEL=\"gpt-6-astra\"/; s/^REVIEWER_EFFORT=.*/REVIEWER_EFFORT=\"low\"/; s/^REVIEWER_CLI=.*/REVIEWER_CLI=\"\"/" "$REVIEW_SKILL/config.sh"
mv "$REVIEW_SKILL/config.sh.sedbak" "$REVIEW_SIDE/config.sedbak.routing"
FAKE_COUNT="$REVIEW_SIDE/.routing-calls" run_review_loop "{\"schema_version\":$REVIEWER_CONTRACT,\"verdict\":\"APPROVE\",\"issues\":[]}" \
  || { tail -5 "$REVIEW_SIDE/run.log" >&2; fail "라우팅: REVIEWER_MODEL=gpt-* 인데 codex 리뷰어가 APPROVE 로 exit 0 이 아님"; }
[ -f "$REVIEW_SIDE/.routing-calls.codex" ] || fail "라우팅: codex 리뷰어가 호출되지 않음"
[ ! -f "$REVIEW_SIDE/.routing-calls.claude" ] || fail "라우팅: 리뷰어가 codex 인데 claude 가 호출됨"
routing_attempt_dir="$(ls -d "$REVIEW_TARGET/.agent-work/reviews/impl-attempt-"* | sort | tail -1)"   # 앞 사례들이 attempt 를 소비했으므로 마지막 attempt
[ -f "$routing_attempt_dir/reviewer-round-01.json.events.jsonl" ] && [ -f "$routing_attempt_dir/reviewer-round-01.json.stderr.log" ] || fail "라우팅: codex 리뷰어 이벤트 JSONL/stderr 로그가 남지 않음 ($routing_attempt_dir)"
[ "$(jq -r '.verdict' "$routing_attempt_dir/reviewer-round-01.json")" = APPROVE ] || fail "라우팅: codex 리뷰어 결과 JSON 이 -o 경로에 없음"
grep -q '검증자 CLI\|claude 실행 실패' "$REVIEW_SIDE/run.log" && fail "라우팅: codex 리뷰어 경로에서 claude 오류 메시지가 나옴"
cp "$REVIEW_SIDE/config.before-routing.sh" "$REVIEW_SKILL/config.sh"   # 이후 절은 원래(claude 리뷰어) 설정으로 계속
# 이 사례의 APPROVE 산출물(승인 지문·체크포인트)이 다음 절에서 재사용되지 않게 치운다 (삭제 대신 이동)
mv "$REVIEW_TARGET/.agent-work/approved.fingerprint" "$REVIEW_SIDE/approved.fingerprint.routing"
printf '{"version":0}\n' > "$REVIEW_TARGET/.agent-work/review-impl.json"
echo "[OK] 10. 구현 리뷰 루프 계약 연계 검사 (APPROVE / REVIEW_OUTPUT_INVALID 구조화 진단: origin·schema_version·verdict·필드 / fix_ref 단일 문장 / DOC_GAP / 리뷰어 codex 라우팅)"

# ---------- 11. 범위 밖 변경은 자동 원복하지 않는다 — FOREIGN_WORKTREE_CHANGE 로 보존 후 중단 ----------
# b.txt: 기준선 이전 사용자 unstaged 변경 + 기준선 이후 (워커 또는 다른 세션의) 추가 변경. 리뷰어가 OUT_OF_SCOPE_CHANGE 를 내면
# 수정자를 부르지 않고 exit 2 / FOREIGN_WORKTREE_CHANGE. 내용·git status 모두 그대로 (worker-baseline.tree 는 시점 기준선이지 소유권 증거가 아니다).
printf 'user edit before feature\nworker edit\n' > "$REVIEW_TARGET/src/b.txt"
status_before="$(cd "$REVIEW_TARGET" && git status --porcelain=v1 -- src/b.txt)"
[ "$status_before" = " M src/b.txt" ] || fail "원복 금지 픽스처: b.txt 초기 상태가 unstaged 수정이 아님 ($status_before)"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# 리뷰어 호출: 1회차 FAKE_REVIEW, 2회차 FAKE_REVIEW2. 수정자 호출(--permission-mode): FAKE_FIX_CMD 를 실행하고 호출 사실을 기록' \
  '[ "${FEATURE_ROLE_CHILD:-}" = 1 ] || { echo "child claude without FEATURE_ROLE_CHILD=1: $*" >&2; exit 9; }' \
  'case " $* " in *" --permission-mode "*) printf "fixer\n" >> "$FAKE_COUNT.fixer"; eval "${FAKE_FIX_CMD:-true}"; printf "%s\n" "{\"session_id\":\"fake\",\"total_cost_usd\":0,\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}"; exit "${FAKE_FIX_RC:-0}";; esac' \
  'n=$(( $(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1 )); printf "%s" "$n" > "$FAKE_COUNT"' \
  'f="$FAKE_REVIEW"; [ "$n" -ge 2 ] && f="$FAKE_REVIEW2"' \
  'jq -n -c --slurpfile r "$f" '"'"'{structured_output: $r[0], session_id:"fake", total_cost_usd:0, usage:{input_tokens:0,output_tokens:0,cache_read_input_tokens:0,cache_creation_input_tokens:0}}'"'" \
  > "$REVIEW_SIDE/fake-claude-fix"
chmod +x "$REVIEW_SIDE/fake-claude-fix"
printf '%s\n' "$review_issue" | jq -c --argjson v "$REVIEWER_CONTRACT" '{schema_version:$v,verdict:"REQUEST_CHANGES",issues:[. + {category:"OUT_OF_SCOPE_CHANGE",code_refs:["src/b.txt:L2-L2"],required_outcome:"src/b.txt 의 변경이 범위 밖"}]}' > "$REVIEW_SIDE/review-oos.json"
printf '%s\n' "$review_issue" | jq -c --argjson v "$REVIEWER_CONTRACT" '{schema_version:$v,verdict:"REQUEST_CHANGES",issues:[.]}' > "$REVIEW_SIDE/review-fix.json"
printf '{"schema_version":%s,"verdict":"APPROVE","issues":[]}\n' "$REVIEWER_CONTRACT" > "$REVIEW_SIDE/review-approve.json"
sed -i.sedbak "s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"legacy_cli\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$REVIEW_SIDE/fake-claude-fix\"|; s/^MAX_IMPL_ROUNDS=.*/MAX_IMPL_ROUNDS=1/" "$REVIEW_SKILL/config.sh" && rm -f "$REVIEW_SKILL/config.sh.sedbak"
: > "$REVIEW_TARGET/.agent-work/decisions.md"
set +e
(cd "$REVIEW_TARGET" && FAKE_COUNT="$REVIEW_SIDE/.oos-calls" FAKE_REVIEW="$REVIEW_SIDE/review-oos.json" FAKE_REVIEW2="$REVIEW_SIDE/review-approve.json" FEATURE_LIVE_TEE=1 \
  bash "$REVIEW_SKILL/scripts/impl-review-loop.sh") > "$REVIEW_SIDE/run-oos.log" 2>&1
oos_rc=$?
set -e
[ "$oos_rc" = 2 ] || { tail -5 "$REVIEW_SIDE/run-oos.log" >&2; fail "원복 금지: OUT_OF_SCOPE_CHANGE 가 exit 2 로 끝나지 않음 (exit $oos_rc)"; }
[ "$(jq -r '.status' "$REVIEW_TARGET/.agent-work/state.json")" = FOREIGN_WORKTREE_CHANGE ] || fail "원복 금지: state.json 이 FOREIGN_WORKTREE_CHANGE 가 아님"
[ ! -f "$REVIEW_SIDE/.oos-calls.fixer" ] || fail "원복 금지: 범위 밖 변경인데 수정자가 호출됨"
[ "$(cat "$REVIEW_TARGET/src/b.txt")" = "$(printf 'user edit before feature\nworker edit')" ] || fail "원복 금지: b.txt 내용이 바뀜(보존돼야 함)"
status_after="$(cd "$REVIEW_TARGET" && git status --porcelain=v1 -- src/b.txt)"
[ "$status_after" = "$status_before" ] || fail "원복 금지: git status 가 바뀜 (전 '$status_before' → 후 '$status_after')"
grep -q 'src/b.txt' "$REVIEW_TARGET/.agent-work/reviews/impl-attempt-"*"/diff-round-01.patch" && fail "원복 금지: 범위 밖 파일(b.txt)이 리뷰 diff 에 포함됨"
echo "[OK] 11. 범위 밖 변경 → FOREIGN_WORKTREE_CHANGE, 수정자 미호출, 내용·index 보존, diff 범위 한정"

# ---------- 11b. 수정자가 index 를 바꾸면 결과 기준으로 중단 (자동 복구 없음) ----------
# 수정자 픽스처: FIX_CODE 이슈(a.txt)를 받고 b.txt 를 git add 한다 (index 조작)
printf 'user edit before feature\nworker edit\n' > "$REVIEW_TARGET/src/b.txt"
set +e
(cd "$REVIEW_TARGET" && FAKE_COUNT="$REVIEW_SIDE/.stage-calls" FAKE_FIX_CMD="git add src/b.txt" FAKE_REVIEW="$REVIEW_SIDE/review-fix.json" FAKE_REVIEW2="$REVIEW_SIDE/review-approve.json" FEATURE_LIVE_TEE=1 \
  bash "$REVIEW_SKILL/scripts/impl-review-loop.sh") > "$REVIEW_SIDE/run-stage.log" 2>&1
stage_rc=$?
set -e
[ "$stage_rc" = 1 ] || fail "index 검사: 수정자의 git add 가 중단(exit 1)으로 이어지지 않음 (exit $stage_rc)"
grep -q '수정자가 git index 를 변경함' "$REVIEW_SIDE/run-stage.log" || fail "index 검사: 중단 사유가 기록되지 않음"
# 수정자 세션도 attempt 단위. 이 사례의 attempt 번호는 리뷰 디렉터리에서 읽는다 (앞 사례들이 attempt 를 올렸을 수 있다)
stage_attempt="$(ls -d "$REVIEW_TARGET/.agent-work/reviews/impl-attempt-"* | sed 's/.*impl-attempt-//' | sort | tail -1)"
[ -f "$REVIEW_TARGET/.agent-work/.session-fixer-a$stage_attempt" ] || fail "세션 범위: 수정자 세션이 attempt 단위(.session-fixer-a$stage_attempt)가 아님 ($(ls -a "$REVIEW_TARGET/.agent-work" | grep session | paste -sd, -))"
[ ! -e "$REVIEW_TARGET/.agent-work/.session-fixer" ] || fail "세션 범위: 역할 전체를 잇는 .session-fixer 가 생성됨"
[ "$(cd "$REVIEW_TARGET" && git status --porcelain=v1 -- src/b.txt)" = "M  src/b.txt" ] || fail "index 검사: 중단 시 index 를 임의로 복구함(자동 복구 금지)"
(cd "$REVIEW_TARGET" && git restore --staged src/b.txt)   # 테스트 정리
echo "[OK] 11b. 수정자 index 변경 → 결과 기준 중단, 자동 복구 없음"

# ---------- 11c. index 변경 + CLI 실패 → CLI 실패보다 index 변경이 먼저 보고됨 (수정자 / 워커) ----------
# 11c-1 수정자: git add 후 exit 7
printf 'user edit before feature\nworker edit\n' > "$REVIEW_TARGET/src/b.txt"
set +e
(cd "$REVIEW_TARGET" && FAKE_COUNT="$REVIEW_SIDE/.stagefail-calls" FAKE_FIX_CMD="git add src/b.txt" FAKE_FIX_RC=7 FAKE_REVIEW="$REVIEW_SIDE/review-fix.json" FAKE_REVIEW2="$REVIEW_SIDE/review-approve.json" FEATURE_LIVE_TEE=1 \
  bash "$REVIEW_SKILL/scripts/impl-review-loop.sh") > "$REVIEW_SIDE/run-stagefail.log" 2>&1
stagefail_rc=$?
set -e
[ "$stagefail_rc" = 1 ] || fail "index 검사(수정자 실패 경로): exit 1 이 아님 ($stagefail_rc)"
grep -q '수정자가 git index 를 변경함' "$REVIEW_SIDE/run-stagefail.log" || fail "index 검사(수정자 실패 경로): CLI 가 실패해도 index 변경이 보고돼야 함"
grep -q 'claude 실행 실패' "$REVIEW_SIDE/run-stagefail.log" && fail "index 검사(수정자 실패 경로): index 변경보다 CLI 실패가 먼저 보고됨"
[ "$(cd "$REVIEW_TARGET" && git status --porcelain=v1 -- src/b.txt)" = "M  src/b.txt" ] || fail "index 검사(수정자 실패 경로): index 를 임의로 복구함"
(cd "$REVIEW_TARGET" && git restore --staged src/b.txt)
# 11c-2 워커: 가짜 codex 가 git add 후 (a) 정상 JSON + exit 0, (b) exit 7. 둘 다 러너가 index 변경으로 중단하고 복구하지 않는다
WIDX_TARGET="$SCRATCH/worker-index"; WIDX_SKILL="$WIDX_TARGET/.claude/skills/feature"; WIDX_SIDE="$SCRATCH/worker-index.side"; mkdir -p "$WIDX_SIDE"
git init -q "$WIDX_TARGET"; bash "$SOURCE_ROOT/install.sh" "$WIDX_TARGET" >/dev/null; chmod -x "$WIDX_TARGET/feature-live"
mkdir -p "$WIDX_TARGET/src" "$WIDX_TARGET/.agent-work/reviews"
printf 'base\n' > "$WIDX_TARGET/src/w.txt"
(cd "$WIDX_TARGET" && git add -A && git -c user.email=t@t -c user.name=t commit -qm base)
for doc in design implementation approach; do printf '# %s\n' "$doc" > "$WIDX_TARGET/.agent-work/$doc.md"; done
printf '\n## all\n전체 계약\n' >> "$WIDX_TARGET/.agent-work/implementation.md"   # unit references(implementation.md#all)가 가리키는 절
sed -i.sedbak "s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"legacy_cli\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"true\"|; s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"true\"|; s/^TEST_CMD=.*/TEST_CMD=\"true\"/; s/^LINT_CMD=.*/LINT_CMD=\"true\"/" "$WIDX_SKILL/config.sh" && rm -f "$WIDX_SKILL/config.sh.sedbak"
fake_scope "$WIDX_TARGET" src/w.txt
fake_consensus_pass "$WIDX_TARGET" design
fake_consensus_pass "$WIDX_TARGET" impl
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'out=""; while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done' \
  'printf "worker edit\n" >> src/w.txt; git add src/w.txt' \
  'printf '\''{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[]}'\'' > "$out"' \
  'exit "${FAKE_WORKER_RC:-0}"' \
  > "$WIDX_SIDE/fake-codex"
chmod +x "$WIDX_SIDE/fake-codex"
sed -i.sedbak "s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"legacy_cli\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"true\"|; s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$WIDX_SIDE/fake-codex\"|; s/^TEST_CMD=.*/TEST_CMD=\"true\"/; s/^LINT_CMD=.*/LINT_CMD=\"true\"/; s/^WORKER_CLI=.*/WORKER_CLI=\"codex\"/" "$WIDX_SKILL/config.sh" && rm -f "$WIDX_SKILL/config.sh.sedbak"   # 워커 픽스처가 fake codex 이므로 모델 기본값과 무관하게 고정
for worker_rc_case in 0 7; do
  (cd "$WIDX_TARGET" && git restore --staged --worktree src/w.txt)
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > "$WIDX_TARGET/.agent-work/run-state.json"
  set +e
  (cd "$WIDX_TARGET" && FAKE_WORKER_RC="$worker_rc_case" bash "$WIDX_SKILL/scripts/feature-run.sh") > "$WIDX_SIDE/run-$worker_rc_case.log" 2>&1
  widx_rc=$?
  set -e
  [ "$widx_rc" = 1 ] || fail "index 검사(워커, codex exit $worker_rc_case): 러너 종료 코드가 1 이 아님 ($widx_rc)"
  grep -q '워커가 git index 를 변경함' "$WIDX_SIDE/run-$worker_rc_case.log" || fail "index 검사(워커, codex exit $worker_rc_case): index 변경이 보고되지 않음"
  grep -q 'codex 워커 실행 실패' "$WIDX_SIDE/run-$worker_rc_case.log" && fail "index 검사(워커, codex exit $worker_rc_case): index 변경보다 CLI 실패가 먼저 보고됨"
  [ "$(cd "$WIDX_TARGET" && git status --porcelain=v1 -- src/w.txt)" = "M  src/w.txt" ] || fail "index 검사(워커, codex exit $worker_rc_case): index 를 임의로 복구함"
done
# assume-unchanged 플래그 변경도 지문에 잡힌다
idx_a="$(cd "$WIDX_TARGET" && bash -c 'source .claude/skills/feature/scripts/lib/bootstrap.sh; compute_index_fingerprint')"
(cd "$WIDX_TARGET" && git update-index --assume-unchanged src/w.txt)
idx_b="$(cd "$WIDX_TARGET" && bash -c 'source .claude/skills/feature/scripts/lib/bootstrap.sh; compute_index_fingerprint')"
(cd "$WIDX_TARGET" && git update-index --no-assume-unchanged src/w.txt)
[ "$idx_a" != "$idx_b" ] || fail "index 지문: assume-unchanged 플래그 변경이 지문에 반영되지 않음"
echo "[OK] 11c. index 변경 + CLI 실패 → index 변경 우선 보고 (수정자·워커), assume-unchanged 감지"

# ---------- 11d. verify 단계 worker-fix 가 기준선을 바꾼 뒤 verify 재진입 — 전역 가드가 DONE 을 막는다 ----------
# exact files 범위(src/w.txt)만 쓰므로 범위 밖 파일·기준선 변경은 승인 지문에 잡히지 않는다. 가드가 없으면 두 번째 실행에서
# 테스트만 통과하면 run_worker·리뷰 루프를 거치지 않고 DONE 이 된다.
VFIX_TARGET="$SCRATCH/verify-fix"; VFIX_SKILL="$VFIX_TARGET/.claude/skills/feature"; VFIX_SIDE="$SCRATCH/verify-fix.side"; mkdir -p "$VFIX_SIDE"
git init -q "$VFIX_TARGET"; bash "$SOURCE_ROOT/install.sh" "$VFIX_TARGET" >/dev/null; chmod -x "$VFIX_TARGET/feature-live"
mkdir -p "$VFIX_TARGET/src" "$VFIX_TARGET/.agent-work/reviews"
printf 'base\n' > "$VFIX_TARGET/src/w.txt"; printf 'other\n' > "$VFIX_TARGET/src/other.txt"
(cd "$VFIX_TARGET" && git add -A && git -c user.email=t@t -c user.name=t commit -qm base)
for doc in design implementation approach; do printf '# %s\n' "$doc" > "$VFIX_TARGET/.agent-work/$doc.md"; done
printf '\n## all\n전체 계약\n' >> "$VFIX_TARGET/.agent-work/implementation.md"   # unit references(implementation.md#all)가 가리키는 절
# 테스트 더블: 호출 횟수를 기록하고 flag 파일이 있을 때만 통과
printf '%s\n' '#!/usr/bin/env bash' 'echo t >> "$VFIX_COUNT"' '[ -f "$VFIX_PASS_FLAG" ]' > "$VFIX_SIDE/test.sh"; chmod +x "$VFIX_SIDE/test.sh"
# 가짜 codex(worker-fix): 기준선을 빈 tree 로 바꾸고 범위 밖 파일 수정, DONE
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'out=""; while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done' \
  'printf "VFIX_WORKER_MARKER\n" >&2' \
  'printf "%s\n" 4b825dc642cb6eb9a060e54bf8d69288fbee4904 > .agent-work/worker-baseline.tree; echo tampered >> src/other.txt' \
  'printf '\''{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[]}'\'' > "$out"' \
  > "$VFIX_SIDE/fake-codex"
chmod +x "$VFIX_SIDE/fake-codex"
sed -i.sedbak "s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"legacy_cli\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"true\"|; s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"true\"|; s|^TEST_CMD=.*|TEST_CMD=\"VFIX_COUNT=$VFIX_SIDE/test-calls VFIX_PASS_FLAG=$VFIX_SIDE/tests-pass bash $VFIX_SIDE/test.sh\"|; s/^LINT_CMD=.*/LINT_CMD=\"true\"/; s/^MAX_IMPL_ROUNDS=.*/MAX_IMPL_ROUNDS=0/; s/^REVIEWER_CLI=.*/REVIEWER_CLI=\"claude\"/; s/^WORKER_CLI=.*/WORKER_CLI=\"codex\"/" "$VFIX_SKILL/config.sh" && rm -f "$VFIX_SKILL/config.sh.sedbak"
fake_scope "$VFIX_TARGET" src/w.txt
fake_consensus_pass "$VFIX_TARGET" design
fake_consensus_pass "$VFIX_TARGET" impl
sed -i.sedbak "s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"legacy_cli\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$REVIEW_SIDE/fake-claude\"|; s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$VFIX_SIDE/fake-codex\"|" "$VFIX_SKILL/config.sh" && rm -f "$VFIX_SKILL/config.sh.sedbak"
(cd "$VFIX_TARGET" && bash -c 'source .claude/skills/feature/scripts/lib/bootstrap.sh; snapshot_worktree_tree' > .agent-work/worker-baseline.tree)
cp "$VFIX_TARGET/.agent-work/worker-baseline.tree" "$VFIX_SIDE/baseline.keep"
cp "$VFIX_TARGET/.agent-work/feature-scope.json" "$VFIX_TARGET/.agent-work/feature-scope.lock.json"
printf 'worker change\n' >> "$VFIX_TARGET/src/w.txt"
printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[]}\n' > "$VFIX_TARGET/.agent-work/worker-result.json"
printf '{"stage":"review","test_retries":0,"stale_count":0,"history":[]}\n' > "$VFIX_TARGET/.agent-work/run-state.json"
# 1차: 리뷰 APPROVE → verify 테스트 실패 → worker-fix 가 기준선 변조 → SCOPE_BASELINE_CHANGED (stage verify)
set +e
(cd "$VFIX_TARGET" && FAKE_REVIEW="$REVIEW_SIDE/review-approve.json" bash "$VFIX_SKILL/scripts/feature-run.sh") > "$VFIX_SIDE/run1.log" 2>&1
vfix_rc1=$?
set -e
[ "$vfix_rc1" = 2 ] || { tail -5 "$VFIX_SIDE/run1.log" >&2; fail "verify worker-fix 변조: 1차 종료 코드가 2 가 아님 ($vfix_rc1)"; }
[ "$(jq -r '.reason' "$VFIX_TARGET/.agent-work/run-state.json")" = SCOPE_BASELINE_CHANGED ] || fail "verify worker-fix 변조: 1차 reason 이 SCOPE_BASELINE_CHANGED 가 아님 ($(jq -r '.reason' "$VFIX_TARGET/.agent-work/run-state.json"))"
[ "$(jq -r '.stage' "$VFIX_TARGET/.agent-work/run-state.json")" = verify ] || fail "verify worker-fix 변조: 1차 stage 가 verify 가 아님"
[ "$(jq -r .active "$VFIX_TARGET/.agent-work/worker-baseline.guard.json")" = true ] || fail "verify worker-fix 변조: 가드가 기록되지 않음"
[ "$(wc -l < "$VFIX_SIDE/test-calls" | tr -d ' ')" = 1 ] || fail "verify worker-fix 변조: 1차 테스트 호출 횟수가 1 이 아님"
# 2차: 테스트는 통과하도록 바꾸고 기준선은 복구하지 않음 → 전역 가드가 exit 2, 테스트·codex 호출 0회, DONE 아님
touch "$VFIX_SIDE/tests-pass"
: > "$VFIX_TARGET/.agent-work/live.log"
set +e
(cd "$VFIX_TARGET" && FAKE_REVIEW="$REVIEW_SIDE/review-approve.json" bash "$VFIX_SKILL/scripts/feature-run.sh") > "$VFIX_SIDE/run2.log" 2>&1
vfix_rc2=$?
set -e
[ "$vfix_rc2" = 2 ] || { tail -5 "$VFIX_SIDE/run2.log" >&2; fail "verify 재진입: 기준선 미복구인데 종료 코드가 2 가 아님 ($vfix_rc2)"; }
[ "$(jq -r '.reason' "$VFIX_TARGET/.agent-work/run-state.json")" = SCOPE_BASELINE_CHANGED ] || fail "verify 재진입: reason 이 SCOPE_BASELINE_CHANGED 가 아님 ($(jq -r '.reason' "$VFIX_TARGET/.agent-work/run-state.json"))"
[ "$(jq -r '.status' "$VFIX_TARGET/.agent-work/run-state.json")" != DONE ] || fail "verify 재진입: 기준선 미복구인데 DONE 이 됨"
[ "$(wc -l < "$VFIX_SIDE/test-calls" | tr -d ' ')" = 1 ] || fail "verify 재진입: 기준선 미복구인데 테스트가 실행됨"
[ "$(ls "$VFIX_TARGET"/.agent-work/reviews/worker-*.log.stderr.log | wc -l | tr -d ' ')" = 1 ] || fail "verify 재진입: 기준선 미복구인데 codex 가 호출됨(worker 원문 로그가 늘어남)"
# 3차: 기준선 복구 → verify 재개, 테스트 통과, DONE, 가드 비활성화
cp "$VFIX_SIDE/baseline.keep" "$VFIX_TARGET/.agent-work/worker-baseline.tree"
set +e
(cd "$VFIX_TARGET" && FAKE_REVIEW="$REVIEW_SIDE/review-approve.json" bash "$VFIX_SKILL/scripts/feature-run.sh") > "$VFIX_SIDE/run3.log" 2>&1
vfix_rc3=$?
set -e
[ "$vfix_rc3" = 0 ] && [ "$(jq -r '.status' "$VFIX_TARGET/.agent-work/run-state.json")" = DONE ] || { tail -5 "$VFIX_SIDE/run3.log" >&2; fail "verify 재진입: 기준선 복구 후 DONE 에 이르지 못함 (rc $vfix_rc3, status $(jq -r '.status' "$VFIX_TARGET/.agent-work/run-state.json"))"; }
[ "$(wc -l < "$VFIX_SIDE/test-calls" | tr -d ' ')" = 2 ] || fail "verify 재진입: 복구 후 테스트가 다시 실행되지 않음"
[ "$(jq -r .active "$VFIX_TARGET/.agent-work/worker-baseline.guard.json")" = false ] || fail "verify 재진입: 복구 후 가드가 비활성화되지 않음"
[ "$(tail -1 "$VFIX_TARGET/src/other.txt")" = tampered ] || fail "verify 재진입: 범위 밖 변경이 원복됨(보존돼야 함)"
ref_hint_ok "$VFIX_SIDE/run1.log" 'NEED_USER(SCOPE_BASELINE_CHANGED)' exit-states-resume.md || fail "로딩 경로: NEED_USER(SCOPE_BASELINE_CHANGED) 반환에 references/exit-states-resume.md 안내가 없음"
ref_hint_ok "$VFIX_SIDE/run3.log" 'DONE' done-finalize.md || fail "로딩 경로: DONE 반환에 references/done-finalize.md 안내가 없음: $(grep 'SKILL REFERENCE' "$VFIX_SIDE/run3.log")"
echo "[OK] 11d. verify worker-fix 기준선 변조 → 미복구 재진입은 테스트·codex 0회로 재중단, 복구 후에만 DONE"

# ---------- 12. 유료 회귀 승인 게이트 (실제 LLM 호출 없음) ----------
GATE_SOURCE="$SCRATCH/gate-source"
cp -R "$SOURCE_ROOT" "$GATE_SOURCE"
rm -f "$GATE_SOURCE/.claude/ALLOW_REAL_LLM_REGRESSION"
for script in reviewer-regression.sh validator-regression.sh; do
  set +e; bash "$GATE_SOURCE/tests/$script" > "$SCRATCH/gate.log" 2>&1; gate_rc=$?; set -e
  [ "$gate_rc" = 3 ] || fail "승인 게이트($script): 허용 파일 없이 exit 3 이 아님 ($gate_rc)"
  grep -q 'ALLOW_REAL_LLM_REGRESSION' "$SCRATCH/gate.log" || fail "승인 게이트($script): 안내 메시지 누락"
done
# 허용 파일이 있으면 게이트를 지나 소모된다 — 실제 호출 전에 CHANGE_ME 검사에서 멈추도록 모델을 비워 둔다
sed -i.sedbak 's/^REVIEWER_MODEL=.*/REVIEWER_MODEL="CHANGE_ME"/' "$GATE_SOURCE/.claude/skills/feature/config.sh" && rm -f "$GATE_SOURCE/.claude/skills/feature/config.sh.sedbak"
touch "$GATE_SOURCE/.claude/ALLOW_REAL_LLM_REGRESSION"
set +e; bash "$GATE_SOURCE/tests/reviewer-regression.sh" > "$SCRATCH/gate.log" 2>&1; gate_rc=$?; set -e
[ "$gate_rc" = 1 ] || fail "승인 게이트: 허용 파일이 있는데 게이트를 통과하지 못함 (exit $gate_rc)"
grep -q 'CHANGE_ME' "$SCRATCH/gate.log" || fail "승인 게이트: 게이트 다음 단계(CHANGE_ME 검사)에 도달하지 않음"
[ ! -f "$GATE_SOURCE/.claude/ALLOW_REAL_LLM_REGRESSION" ] || fail "승인 게이트: 허용 파일이 1회용으로 소모되지 않음"
ls "$GATE_SOURCE/.agent-work"/ALLOW_REAL_LLM_REGRESSION.used.* >/dev/null 2>&1 || fail "승인 게이트: 소모된 허용 파일 기록이 없음"
echo "[OK] 12. 유료 회귀 승인 게이트 (차단 / 1회용 소모)"

# ---------- 13. usage telemetry recorder — 픽스처만으로 함수 검사 (실제 LLM 호출 없음) ----------
# 한 행 = invocation 한 번. session 누적 delta 없음, label 은 unique key 아님, null 은 관측 불가(0 으로 위조 금지).
# 임시 config 는 소스 트리가 아니라 $SCRATCH 의 가짜 프로젝트에 둔다 — 중간 실패·병렬 실행에도 trap 이 정리한다
USAGE_DIR="$SCRATCH/usage-fixture"; mkdir -p "$USAGE_DIR/.agent-work" "$USAGE_DIR/.claude/hooks"
printf '# smoke\n' > "$USAGE_DIR/.claude/hooks/core_rules.md"
USAGE_LOADER="$(filled_skill_copy "$SRC_SKILL" "$USAGE_DIR/.claude/skills/feature")"
cat > "$USAGE_DIR/claude-a.json" <<'EOF'
{"session_id":"session-a","total_cost_usd":1.25,"num_turns":7,"duration_ms":12000,"duration_api_ms":10000,
 "usage":{"input_tokens":40,"output_tokens":500,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}
EOF
cat > "$USAGE_DIR/claude-b.json" <<'EOF'
{"session_id":"session-b","total_cost_usd":0.5,"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}
EOF
printf '{"session_id":"session-c","result":"no usage here"}\n' > "$USAGE_DIR/claude-c.json"
cat > "$USAGE_DIR/claude-a2.json" <<'EOF'
{"session_id":"session-a","total_cost_usd":0.1,"num_turns":1,"usage":{"input_tokens":5,"output_tokens":6,"cache_read_input_tokens":7,"cache_creation_input_tokens":0}}
EOF
cat > "$USAGE_DIR/claude-g.json" <<'EOF'
{"session_id":"session-g","total_cost_usd":1.2914188,"num_turns":12,"usage":{"input_tokens":38,"output_tokens":14701,"cache_read_input_tokens":2509959,"cache_creation_input_tokens":158503}}
EOF
# codex --json 이벤트 JSONL: 다른 이벤트 사이에 turn.completed 두 개(합산, 선택 필드 생략은 0) / usage 없는 스트림 / 옛 plain "tokens used" 텍스트(더 이상 읽지 않음)
# / 깨진 줄 혼재(리뷰 1: 정상 turn 만 합산해 complete 로 적지 않는다 → unknown) / usage:{} (필수 필드 없음 → 0 이 아니라 unknown)
printf '%s\n' '{"type":"thread.started","thread_id":"t"}' '{"type":"turn.completed","usage":{"input_tokens":10000,"cached_input_tokens":6000,"cache_write_input_tokens":1000,"output_tokens":500,"reasoning_output_tokens":300}}' \
  '{"type":"item.completed","item":{"type":"agent_message"}}' '{"type":"turn.completed","usage":{"input_tokens":2000,"cached_input_tokens":345,"output_tokens":100}}' > "$USAGE_DIR/codex-f.jsonl"
printf '%s\n' '{"type":"thread.started"}' 'tokens used' '12,345' > "$USAGE_DIR/codex-none.jsonl"
printf '%s\n' '{"type":"thread.started","thread_id":"t"}' 'not json at all' '{"type":"turn.completed","usage":{"input_tokens":10000,"cached_input_tokens":6000,"cache_write_input_tokens":1000,"output_tokens":500}}' > "$USAGE_DIR/codex-corrupt.jsonl"
printf '%s\n' '{"type":"thread.started","thread_id":"t"}' '{"type":"turn.completed","usage":{"input_tokens":10000,"cached_input_tokens":6000,"cache_write_input_tokens":1000,"output_tokens":500}}' '{"type":"turn.completed","usage":{}}' > "$USAGE_DIR/codex-emptyusage.jsonl"
usage_run() { (cd "$USAGE_DIR" && source "$USAGE_LOADER" && "$@"); }
usage_last() { tail -1 "$USAGE_DIR/.agent-work/usage.jsonl" | jq -r "$1"; }
usage_rows() { wc -l < "$USAGE_DIR/.agent-work/usage.jsonl" | tr -d ' '; }
# A. 정상 result — 모든 필드 그대로, input_effective 파생
usage_run log_claude_usage lbl-a REVIEWER claude-sonnet-5 "$USAGE_DIR/claude-a.json" 2>"$USAGE_DIR/warn.log" || fail "usage A: recorder 실패"
[ "$(usage_rows)" = 1 ] || fail "usage A: 행 1개가 아님"
[ "$(usage_last '[.input_uncached,.cache_read,.cache_write,.output,.input_effective,.num_turns,.duration_ms,.duration_api_ms,.cost_usd,.session]|@csv')" = '40,1000,200,500,1240,7,12000,10000,1.25,"session-a"' ] \
  || fail "usage A: 필드 값 불일치: $(tail -1 "$USAGE_DIR/.agent-work/usage.jsonl")"
[ "$(usage_last '[.label,.role,.cli,.model,.source,.exit_code,.success]|@csv')" = '"lbl-a","REVIEWER","claude","claude-sonnet-5","claude-result",0,true' ] || fail "usage A: metadata 불일치"
usage_last '.invocation_id' | grep -Eq '^.{8,}$' || fail "usage A: invocation_id 없음"
usage_last 'has("in") or has("out")' | grep -q false || fail "usage A: legacy in/out 필드가 남아 있음"
# B. optional 진단 필드 없음 → 행 생성, null (0 아님)
usage_run log_claude_usage lbl-b VALIDATOR claude-sonnet-5 "$USAGE_DIR/claude-b.json" 2>>"$USAGE_DIR/warn.log" || fail "usage B: recorder 실패"
[ "$(usage_rows)" = 2 ] || fail "usage B: 행이 추가되지 않음"
[ "$(usage_last '[.num_turns,.duration_ms,.duration_api_ms]|map(.==null)|all')" = true ] || fail "usage B: optional 필드가 null 이 아님"
[ "$(usage_last '.input_effective')" = 80 ] || fail "usage B: input_effective 오류"
# C. usage 핵심 필드 없음 → WARN + unknown 행 1개(비용·토큰 null — 숨은 0건 금지, GOAL-6), 함수는 0 반환
usage_run log_claude_usage lbl-c VALIDATOR claude-sonnet-5 "$USAGE_DIR/claude-c.json" 2>"$USAGE_DIR/warn-c.log" || fail "usage C: 함수가 실패를 돌려줌"
grep -q '\[WARN\]' "$USAGE_DIR/warn-c.log" || fail "usage C: WARN 없음"
[ "$(usage_rows)" = 3 ] && [ "$(usage_last '[.cost_kind,.cost_usd,.input_uncached,.usage_observation_status,.usage_error]|@csv')" = '"unknown",,,"unavailable","USAGE_FIELDS_MISSING"' ] \
  || fail "usage C: usage 필드 없는 invocation 이 unknown 행 1개로 기록되지 않음: $(tail -1 "$USAGE_DIR/.agent-work/usage.jsonl")"
# D. 동일 session 두 invocation → 행 2개, 각각 fixture 값 그대로 (두 번째가 작아도 정상, delta 없음)
usage_run log_claude_usage lbl-d REVIEWER claude-sonnet-5 "$USAGE_DIR/claude-a2.json" 2>>"$USAGE_DIR/warn.log"
[ "$(jq -r 'select(.session=="session-a") | .cache_read' "$USAGE_DIR/.agent-work/usage.jsonl" | paste -sd, -)" = "1000,7" ] || fail "usage D: 같은 session 두 행이 invocation 값 그대로가 아님"
# E. 동일 label 재시도 → 두 행, invocation_id 상이
usage_run log_claude_usage lbl-a REVIEWER claude-sonnet-5 "$USAGE_DIR/claude-a.json" 2>>"$USAGE_DIR/warn.log"
[ "$(jq -r 'select(.label=="lbl-a") | .invocation_id' "$USAGE_DIR/.agent-work/usage.jsonl" | wc -l | tr -d ' ')" = 2 ] || fail "usage E: label 재시도 행이 2개가 아님"
[ "$(jq -r 'select(.label=="lbl-a") | .invocation_id' "$USAGE_DIR/.agent-work/usage.jsonl" | sort -u | wc -l | tr -d ' ')" = 2 ] || fail "usage E: invocation_id 가 같음"
# F. codex --json 이벤트 → turn.completed 합산(input_total 12000 = uncached 4655 + cache_read 6345 + cache_write 1000), reasoning 은 output 의 부분집합, 가격표 추정 비용
#    gpt-5.6-sol(v4 수식): uncached 4655*4.00 + cache_read 6345*0.40 + cache_write 1000*5.00(30분 캐시 쓰기 별도율) + output 600*20.00 (per 1M) = 0.038158
usage_run log_role_usage codex VALIDATOR gpt-5.6-sol lbl-f "$USAGE_DIR/codex-f.jsonl" 2>>"$USAGE_DIR/warn.log" || fail "usage F: recorder 실패"
[ "$(usage_last '[.cli,.tokens_total,.source,.role,.model,.num_turns]|@csv')" = '"codex",12600,"codex-events","VALIDATOR","gpt-5.6-sol",2' ] || fail "usage F: codex 행 불일치: $(tail -1 "$USAGE_DIR/.agent-work/usage.jsonl")"
[ "$(usage_last '[.input_uncached,.cache_read,.cache_write,.input_effective,.output,.reasoning_output]|@csv')" = '4655,6345,1000,12000,600,300' ] || fail "usage F: codex 토큰 매핑 불일치: $(tail -1 "$USAGE_DIR/.agent-work/usage.jsonl")"
[ "$(usage_last '[.cost_usd,.cost_kind,((.estimated_cost_usd*1000000)|round),.pricing_basis]|@csv')" = ',"estimated",38158,"openai-api-standard-2026-10-30"' ] || fail "usage F: codex 비용 필드 불일치: $(tail -1 "$USAGE_DIR/.agent-work/usage.jsonl")"
[ "$(usage_last '[.duration_ms,.duration_api_ms,.session]|map(.==null)|all')" = true ] || fail "usage F: 관측 불가 값이 null 이 아님"
usage_run log_codex_usage lbl-f2 VALIDATOR gpt-5.6-sol "$USAGE_DIR/codex-none.jsonl" 2>"$USAGE_DIR/warn-f.log" || fail "usage F: usage 이벤트 없는 스트림에서 함수 실패"
grep -q '\[WARN\]' "$USAGE_DIR/warn-f.log" || fail "usage F: usage 이벤트 없음 WARN 누락"
# 옛 plain "tokens used" 텍스트는 JSON 이 아니므로 CORRUPT 로 분류된다(읽지 않는다) — 어느 쪽이든 unknown 행 1개
[ "$(usage_rows)" = 7 ] && [ "$(usage_last '[.cost_kind,.tokens_total,.usage_observation_status,.usage_error]|@csv')" = '"unknown",,"unavailable","USAGE_EVENTS_CORRUPT"' ] \
  || fail "usage F: usage 이벤트 없는 스트림(옛 plain tokens used 포함)은 unknown 행 1개(비용·토큰 null)여야 함: $(tail -1 "$USAGE_DIR/.agent-work/usage.jsonl")"
# F2. 가격표에 없는 codex 모델 → estimated null / cost_kind unknown (추측 가격 없음)
usage_run log_codex_usage lbl-f3 WORKER gpt-unknown-x "$USAGE_DIR/codex-f.jsonl" 2>>"$USAGE_DIR/warn.log" || fail "usage F2: recorder 실패"
[ "$(usage_last '[.estimated_cost_usd,.cost_kind,.pricing_basis,.tokens_total]|@csv')" = ',"unknown",,12600' ] || fail "usage F2: unknown 모델 행 불일치: $(tail -1 "$USAGE_DIR/.agent-work/usage.jsonl")"
# F3 (리뷰 1). 깨진 줄 혼재 → 정상 turn 1개가 있어도 합산하지 않고 unknown(partial) / usage:{} → 필수 필드 없음이라 0 이 아니라 unknown(partial, 다른 turn 은 유효)
usage_run log_codex_usage lbl-f4 WORKER gpt-5.6-sol "$USAGE_DIR/codex-corrupt.jsonl" 2>"$USAGE_DIR/warn-f4.log" || fail "usage F3: corrupt 스트림에서 함수 실패"
grep -q 'JSON 으로 읽을 수 없는 줄 1 개' "$USAGE_DIR/warn-f4.log" || fail "usage F3: corrupt WARN 없음"
[ "$(usage_last '[.cost_kind,.estimated_cost_usd,.tokens_total,.num_turns,.usage_observation_status,.usage_error,.success]|@csv')" = '"unknown",,,,"partial","USAGE_EVENTS_CORRUPT",true' ] \
  || fail "usage F3: 깨진 줄 혼재 스트림이 과소 집계(complete)되거나 unknown 행이 아님: $(tail -1 "$USAGE_DIR/.agent-work/usage.jsonl")"
usage_run log_codex_usage lbl-f5 WORKER gpt-5.6-sol "$USAGE_DIR/codex-emptyusage.jsonl" 2>"$USAGE_DIR/warn-f5.log" || fail "usage F3: usage:{} 스트림에서 함수 실패"
[ "$(usage_last '[.cost_kind,.estimated_cost_usd,.tokens_total,.usage_observation_status,.usage_error]|@csv')" = '"unknown",,,"partial","USAGE_FIELDS_INCOMPLETE"' ] \
  || fail "usage F3: usage:{} 가 0 달러/estimated 로 기록됨: $(tail -1 "$USAGE_DIR/.agent-work/usage.jsonl")"
# G. effective input 회귀 + 실패 invocation 도 기록(exit_code/success)
usage_run log_role_usage claude REVIEWER claude-sonnet-5 impl-review-a01-round-01 "$USAGE_DIR/claude-g.json" 1 2>>"$USAGE_DIR/warn.log"
[ "$(usage_last '[.input_effective,.exit_code,.success]|@csv')" = '2668500,1,false' ] || fail "usage G: input_effective/exit_code 불일치"
# 파생 집계는 writer 밖 — legacy 행(in/out, v2 codex tokens_total 만 있는 행)도 함께 읽는다
printf '{"label":"legacy","session":"s","cost_usd":0.2,"in":3,"out":4,"cache_read":5,"cache_write":6}\n' >> "$USAGE_DIR/.agent-work/usage.jsonl"
printf '{"schema_version":2,"label":"legacy-codex","role":"WORKER","cli":"codex","model":"gpt-5.6-luna","session":null,"cost_usd":null,"input_uncached":null,"cache_read":null,"cache_write":null,"output":null,"input_effective":null,"tokens_total":777,"num_turns":null,"exit_code":0,"success":true,"source":"codex-log"}\n' >> "$USAGE_DIR/.agent-work/usage.jsonl"
# 행: A B C(unknown) D E(claude, cost 1.25+0.5+0.1+1.25) F(codex sol, est 0.038158) F-none(unknown) F2(codex unknown) F3×2(unknown) G(claude 1.2914188) legacy(0.2) legacy-codex(unknown)
[ "$(usage_run usage_summary | jq -r '[.invocations,.input_uncached,.output,.cost_unknown_invocations,.usage_unobserved_invocations]|@csv')" = "13,9446,16931,6,4" ] || fail "usage summary: 합계 불일치(unknown 행 C·F-none·F3 포함): $(usage_run usage_summary)"
# 비용은 provenance 별로 분리 — reported(claude 보고값 합) / estimated(codex 가격표 추정 합) / combined 는 둘의 합(추정치), cost_usd 는 reported 와 같은 옛 이름
usage_summary_json="$(usage_run usage_summary)"
[ "$(printf '%s' "$usage_summary_json" | jq -r '[((.reported_cost_usd*10000000)|round), ((.estimated_cost_usd*10000000)|round), ((.combined_cost_usd_estimate*10000000)|round), ((.cost_usd*10000000)|round), .reasoning_output]|@csv')" = "45914188,381580,46295768,45914188,600" ] \
  || fail "usage summary: reported/estimated/combined 비용 분리 불일치: $usage_summary_json"
# 집계 보강: num_turns/output/cache_read_per_turn(전체·그룹), by_label·by_session 으로 어느 호출·세션이 cache read 를 만드는지 본다.
# cache_read_per_turn 은 num_turns 를 보고한 행만으로 계산(A 1000/7, D 7/1, E 1000/7, G 2509959/12, F 6345/2, F2 6345/2 → 2524656/31). legacy 행은 num_turns 없음.
[ "$(printf '%s' "$usage_summary_json" | jq -r '[.num_turns, .cache_read, (.cache_read_per_turn|floor)]|@csv')" = "31,2524691,81440" ] \
  || fail "usage summary: num_turns/cache_read_per_turn 불일치: $usage_summary_json"
[ "$(printf '%s' "$usage_summary_json" | jq -r '.by_label["lbl-a"] | [.invocations,.cache_read,.num_turns,(.cache_read_per_turn|floor)]|@csv')" = "2,2000,14,142" ] \
  || fail "usage summary: by_label(lbl-a) 불일치: $usage_summary_json"
[ "$(printf '%s' "$usage_summary_json" | jq -r '.by_session["session-a"] | [.invocations,.cache_read,.num_turns,.output]|@csv')" = "3,2007,15,1006" ] \
  || fail "usage summary: by_session(session-a) 불일치: $usage_summary_json"
[ "$(printf '%s' "$usage_summary_json" | jq -r '[.by_session["none"].invocations, .by_label["legacy-codex"].cache_read_per_turn, .by_label["legacy-codex"].cost_unknown_invocations]|@csv')" = "7,,1" ] \
  || fail "usage summary: num_turns 없는 그룹(legacy codex/session null)의 cache_read_per_turn 이 null 이 아님: $usage_summary_json"
[ "$(printf '%s' "$usage_summary_json" | jq -r '.by_role.REVIEWER | [.invocations,((.cost_usd*10000)|round),.cache_read,.num_turns]|@csv')" = "4,38914,2511966,27" ] \
  || fail "usage summary: by_role(REVIEWER) 불일치: $usage_summary_json"
echo "[OK] 13. usage telemetry recorder (A~G: 필드 명확화·optional null·핵심 필드 없음 WARN·session 무누적·label 재시도·codex --json 이벤트 합산·가격표 추정·unknown 모델·effective 회귀) + usage_summary reported/estimated/combined·by_label/by_session/cache_read_per_turn"

# ---------- 14. 프롬프트 철학 가드 (LLM 호출 없음) ----------
# 합의 문서는 production diff 를 사전에 고정하지 않고 material implementation contract 를 고정한다.
# 옛 철학("과잉 명세 > 과소 명세", "두 워커가 구조적으로 다르면 불완전", "워커는 타이피스트", helper/local/iteration 미정 → DOC_GAP)이
# 프롬프트·문서에 되살아나면 실패한다. exact 문장 grep 이 아니라 그 의미를 담는 핵심 어구 몇 개만 본다.
PROMPTS="$TARGET_SKILL/prompts"
forbid() { # file phrase
  grep -Fq -- "$2" "$1" && fail "프롬프트 철학 회귀: $(basename "$1") 에 '$2' 가 남아 있음"; return 0
}
require() { # file phrase
  grep -Fq -- "$2" "$1" || fail "프롬프트 철학 누락: $(basename "$1") 에 '$2' 가 없음"; return 0
}
for f in "$PROMPTS/designer-revise-impl.md" "$SOURCE_ROOT/.claude/skills/feature/SKILL.md" "$SOURCE_ROOT/README.md" "$SOURCE_ROOT/tests/solution-shape-cases.md"; do
  forbid "$f" "과잉 명세를 택한다"; forbid "$f" "과잉 명세 > 과소 명세"; forbid "$f" "구조적으로 다른 코드를 쓸 수 있다면"; forbid "$f" "타이피스트"
done
require "$PROMPTS/designer-revise-impl.md" "material decision"; require "$PROMPTS/designer-revise-impl.md" "local implementation expression"
forbid "$PROMPTS/designer-revise-impl.md" "코드 blueprint 수준"; forbid "$PROMPTS/designer-revise-impl.md" "helper 여부와 signature"
for f in "$PROMPTS/validator-review-impl.md" "$PROMPTS/validator-overlays/guided.md"; do
  forbid "$f" "두 워커가 문서를 지키면서"; forbid "$f" "non-trivial diff"; forbid "$f" "문서는 코드 사양서다"
done
require "$PROMPTS/validator-review-impl.md" "무엇이 달라지는가"; require "$PROMPTS/validator-review-impl.md" "local implementation expression"
for f in "$PROMPTS"/worker-*.md; do
  forbid "$f" "타이피스트"; forbid "$f" "helper placement 를 선택해야 함"; forbid "$f" "collection·aggregation 위치를 선택해야 함"; forbid "$f" "변수 이름·pseudocode 를 그대로"
  require "$f" "material"
done
require "$PROMPTS/worker-unit.md" "local implementation expression(당신이 정한다)"; require "$PROMPTS/worker-implement.md" "local implementation expression(당신이 정한다)"
forbid "$PROMPTS/reviewer.md" "문서가 지정하지 않은 private helper 추출이나 지정된 helper 의 inline"; forbid "$PROMPTS/reviewer.md" "다른 이름·구조를 쓴 것"
require "$PROMPTS/reviewer.md" "local implementation expression"; require "$PROMPTS/reviewer.md" "standalone abstraction"
forbid "$PROMPTS/fixer.md" "지정된 helper 를 inline 하지 않고"; require "$PROMPTS/fixer.md" "material contract"
echo "[OK] 14. 프롬프트 철학 가드 — material decision / local implementation expression 경계 (과잉 명세·두 워커 diff·타이피스트·helper/local DOC_GAP 의미 부재)"

# ---------- 15. SKILL.md 진입 문서 + 참조 문서 계약 (LLM 호출 없음) ----------
ENTRY="$SRC_SKILL/SKILL.md"; REFS="$SRC_SKILL/references"
# (a) 진입 문서는 압축 뒤에도 남는 크기여야 한다. 토큰 계측기가 없으므로 바이트·문자 수 상한으로 회귀만 막는다(토큰의 정확한 대체값이 아니다).
entry_bytes="$(wc -c < "$ENTRY" | tr -d ' ')"
[ "$entry_bytes" -le 14000 ] || fail "SKILL.md 진입 문서가 다시 커짐: ${entry_bytes} bytes (> 14000) — 상세 절차는 references/ 에 둔다"
# (b) 참조 문서를 @import 로 한꺼번에 펼치지 않는다(필요 시 읽는 파일이어야 한다)
grep -nE '(^|[[:space:]])@[A-Za-z0-9._/-]*references/' "$ENTRY" && fail "SKILL.md 가 references 를 @import 로 펼침"
# (c) 분기별 읽기 지시·누락 시 중단·압축 뒤 재확인이 진입 문서에 있다
for phrase in '행동하기 전에 그 파일을 Read 로 읽고' '파일이 없거나 읽히지 않으면 진행하지 않는다' '압축·재개 뒤 복구' '피처 worktree 의' '[SKILL REFERENCE]' \
              'DESIGN_MISSING' 'IMPL_DOCS_MISSING' 'SCOPE_MISSING' 'ASK_USER' 'DEADLOCK' 'MAX_ROUNDS' 'UNDECIDED' 'REVIEW_DOC_GAP' 'UNIT' 'DONE' '--finalize' 'USER_RESOLVED' 'ENV_ERROR'; do
  grep -Fq -- "$phrase" "$ENTRY" || fail "SKILL.md 진입 문서에 필수 항목 누락: '$phrase'"
done
# (d) 러너가 내는 모든 NEED_USER/NEED_DOCS reason 이 참조 문서에 설명돼 있다(요약 편집으로 종료 사유가 문서에서 사라지지 않게)
runner_reasons="$(grep -ohE 'stop_need_(user|docs) [A-Z][A-Z_]+' "$SRC_SKILL"/scripts/*.sh | awk '{print $2}' | sort -u)"
[ "$(printf '%s\n' "$runner_reasons" | grep -c .)" -ge 20 ] || fail "참조 문서 계약: 러너 reason 추출 실패"
for r in $runner_reasons; do
  grep -Fq -- "$r" "$REFS"/*.md || fail "참조 문서 계약: 러너가 내는 reason '$r' 이 references/ 어디에도 없음"
done
# (e) 사용자 결정 태그·승인 경계 등 필수 계약의 원문이 참조 문서에 남아 있다
ref_require() { grep -Fq -- "$2" "$REFS/$1" || fail "참조 문서 계약: references/$1 에 '$2' 가 없음"; }
ref_require exit-states-resume.md '[USER-QUESTION][scope=<stage>][escalation=<blocker id>]'
ref_require exit-states-resume.md '[USER-QUESTION][scope=impl][worker-gap=<unit id>#<n>]'
ref_require exit-states-resume.md '[USER-QUESTION][scope=impl][review-issue=<issue id>]'
ref_require exit-states-resume.md '검증자 PASS 가 아니다'
ref_require exit-states-resume.md 'resolved_impl_fingerprint'
ref_require phase0-design.md '[USER-QUESTION][scope=design]'
ref_require phase0-design.md '## 요구 변경/추가'
ref_require impl-docs.md 'feature-scope.lock.json'
ref_require impl-docs.md 'REUSE_DISCOVERY_GAP'
ref_require done-finalize.md 'finalize 는 사용자 승인 없이는 실행하지 않는다'
ref_require done-finalize.md 'touch .claude/ALLOW_COMMIT'
ref_require done-finalize.md 'FINALIZE_CONFLICT'
ref_require pipeline-contracts.md '범위 밖 변경은 자동 원복하지 않는다'
ref_require pipeline-contracts.md '파일 삭제 절대 금지'
ref_require pipeline-contracts.md 'WORKER_SESSION_MISMATCH'
ref_require pipeline-contracts.md '막히면 AI끼리 풀지 말고 사용자에게 묻는다'
# (f) 줄 길이: Read 도구는 한 줄이 2,000자를 넘으면 뒷부분을 잘라 보여 준다 — 진입 문서·참조 문서의 어느 줄도 그 근처에 가지 않게 한다(코드 블록 포함).
#     표의 한 행은 나눌 수 없으므로 긴 설명은 표가 아니라 절(### reason)과 문단으로 쓴다.
#     로케일·awk 구현에 따라 length 가 문자/바이트로 갈리므로 LC_ALL=C 의 바이트로 고정해 센다(바이트 ≥ 문자 수 — 1,500바이트 이하면 1,500자 이하다).
MAX_DOC_LINE_BYTES=1500
long_lines="$(LC_ALL=C awk -v max="$MAX_DOC_LINE_BYTES" 'length($0) > max { printf "%s:%d(%d bytes) ", FILENAME, FNR, length($0) }' "$ENTRY" "$REFS"/*.md)"
[ -z "$long_lines" ] || fail "참조 문서에 ${MAX_DOC_LINE_BYTES}바이트를 넘는 줄이 있음(Read 에서 잘릴 수 있다 — 문장 경계에서 줄을 나눈다): $long_lines"
# (g) 모든 종료 reason 이 exit-states-resume.md 의 절 제목에 있어야 한다(SKILL.md 가 "제목에 그 reason 이 든 절 전체"를 읽게 한다 — 통합 절도 제목에 reason 이름이 든다).
#     러너가 stop_need_* 로 내는 reason 전부 + 합의 루프 status 에서 오는 동적 reason(ASK_USER/DEADLOCK/MAX_ROUNDS) + ENV_ERROR. 새 reason 을 절 없이 추가하면 여기서 실패한다.
for r in $runner_reasons ASK_USER DEADLOCK MAX_ROUNDS ENV_ERROR; do
  grep -q "^### .*\`$r\`" "$REFS/exit-states-resume.md" || fail "참조 문서 계약: exit-states-resume.md 에 '$r' 절 제목이 없음"
done
# 통합 절과 WORKER_SESSION_* 의 추가 읽기 경로는 진입 문서가 명시한다
grep -Fq '`DEADLOCK`/`MAX_ROUNDS`, `TEST_RETRIES_EXHAUSTED`/`APPROVAL_STALE_REPEATED`' "$ENTRY" || fail "SKILL.md: 통합 절(reason 둘이 한 절) 안내가 없음"
grep -q 'WORKER_SESSION_\*.*references/pipeline-contracts.md' "$ENTRY" || fail "SKILL.md: WORKER_SESSION_* 의 pipeline-contracts.md 읽기 경로가 없음"
grep -q '^|' "$REFS/exit-states-resume.md" && fail "참조 문서 계약: exit-states-resume.md 에 표가 다시 생김(긴 행은 Read 에서 잘린다)"
# (h) decisions.md '기존 줄 수정 금지' 의 유일한 예외(DECISION_SCOPE_REQUIRED 의 scope 보정)가 진입 문서에 명시돼 있다
grep -Fq '유일한 예외: `DECISION_SCOPE_REQUIRED`' "$ENTRY" || fail "SKILL.md: decisions.md 기존 줄 수정 금지의 DECISION_SCOPE_REQUIRED 예외가 없음"
for f in "$REFS"/*.md; do
  forbid "$f" "과잉 명세를 택한다"; forbid "$f" "과잉 명세 > 과소 명세"; forbid "$f" "구조적으로 다른 코드를 쓸 수 있다면"; forbid "$f" "타이피스트"
done
echo "[OK] 15. SKILL.md 진입 문서(${entry_bytes} bytes)·분기별 읽기 지시 / 러너 reason $(printf '%s\n' "$runner_reasons" | grep -c .)개 전부 references 에 존재 / 필수 계약 원문 보존"

echo ""
echo "install.sh 스모크 테스트 전부 통과"
