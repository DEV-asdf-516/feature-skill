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
# 합의 PASS 픽스처: 러너의 stage 결정은 파일명이 아니라 consensus-<target>.json 체크포인트(+입력 지문·리뷰 내용)를 본다.
# 가짜 PASS 리뷰 파일을 두고 합의 루프를 한 번 돌려 체크포인트를 만든다 (대상 config 의 CODEX_BIN 이 "true" 여야 한다 — 리뷰 파일을 덮어쓰지 않도록).
fake_consensus_pass() { # target-root design|impl
  local root="$1" t="$2"
  mkdir -p "$root/.agent-work/reviews"
  printf '{"schema_version":9,"verdict":"PASS","blocking_issues":[]}\n' > "$root/.agent-work/reviews/validator-$t-round-01.json"
  (cd "$root" && FEATURE_LIVE_TEE=1 bash .claude/skills/feature/scripts/consensus-loop.sh "$t") >/dev/null 2>&1 \
    || fail "픽스처: $t 합의 PASS 체크포인트 생성 실패 ($root)"
}
# 피처 범위 manifest 픽스처 (워커 진입에 필수)
fake_scope() { # target-root file...
  local root="$1"; shift
  printf '%s\n' "$@" | jq -R . | jq -sc '{version:1, files:., new_file_roots:[]}' > "$root/.agent-work/feature-scope.json"
}

TARGET="$SCRATCH/target"
TARGET_SKILL="$TARGET/.claude/skills/feature"
git init -q "$TARGET"

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
# config.sh 의 CHANGE_ME 가드를 지나려면 값을 채운 사본으로 source 한다 (대상 config.sh 는 건드리지 않는다)
# 사본은 대상 config.sh 옆에 둔다 — PROJECT_ROOT 가 파일 위치 기준이라 다른 곳에서 source 하면 대상 프로젝트를 못 찾는다
sed 's/^TEST_CMD="CHANGE_ME"/TEST_CMD="true"/; s/^LINT_CMD="CHANGE_ME"/LINT_CMD="true"/' "$TARGET_SKILL/config.sh" > "$TARGET_SKILL/.config.smoke.sh"
worker_rules="$(bash -c 'source "$1"; load_worker_rules' _ "$TARGET_SKILL/.config.smoke.sh")" || fail "신규 설치: load_worker_rules 실패"
rm -f "$TARGET_SKILL/.config.smoke.sh"
echo "$worker_rules" | grep -q '\[WORKER SKILL:' && fail "신규 설치: 기본 설정에서 워커 스킬이 주입됨 (WORKER_SKILLS 는 비어 있어야 함)"
echo "[OK] 1. 신규 설치"

# ---------- 2. 재실행 멱등성 ----------
rerun_output="$(bash "$SOURCE_ROOT/install.sh" "$TARGET")"
echo "$rerun_output" | grep -q WARN && fail "재실행: 변경 없는데 WARN 발생"
echo "[OK] 2. 재실행 멱등성"

# ---------- 3. 사용자 수정 보존 (+ .new 생성) ----------
sed -i.sedbak 's/^TEST_CMD=.*/TEST_CMD="npm test"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
printf '# 프로젝트 커스텀 규칙\n' >> "$TARGET/.claude/hooks/core_rules.md"
bash "$SOURCE_ROOT/install.sh" "$TARGET" >/dev/null
grep -q 'npm test' "$TARGET_SKILL/config.sh" || fail "수정 보존: config.sh 덮어써짐"
grep -q '커스텀 규칙' "$TARGET/.claude/hooks/core_rules.md" || fail "수정 보존: core_rules.md 덮어써짐"
[ -f "$TARGET_SKILL/config.sh.new" ] || fail "수정 보존: config.sh.new 미생성"
echo "[OK] 3. 사용자 수정 보존 + .new"

# ---------- 3b. 역할별 모델/effort + 선택 conventions 규칙 병합 ----------
sed -i.sedbak 's/^LINT_CMD=.*/LINT_CMD="true"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^WORKER_EFFORT=.*/WORKER_EFFORT="high"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^REVIEWER_EFFORT=.*/REVIEWER_EFFORT="low"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^FIXER_EFFORT=.*/FIXER_EFFORT="high"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
role_efforts="$(bash -c 'source "$1"; printf "%s|%s|%s|%s|%s" "$DESIGNER_EFFORT" "$VALIDATOR_EFFORT" "$WORKER_EFFORT" "$REVIEWER_EFFORT" "$FIXER_EFFORT"' _ "$TARGET_SKILL/config.sh")"
# 디자이너·검증자 effort 는 소스 config.sh 값을 그대로 기대한다(프로젝트별로 바꾸는 값이라 고정 문자열로 두지 않는다)
src_designer_effort="$(sed -n 's/^DESIGNER_EFFORT="\([^"]*\)".*/\1/p' "$SOURCE_ROOT/.claude/skills/feature/config.sh")"
src_validator_effort="$(sed -n 's/^VALIDATOR_EFFORT="\([^"]*\)".*/\1/p' "$SOURCE_ROOT/.claude/skills/feature/config.sh")"
[ "$role_efforts" = "$src_designer_effort|$src_validator_effort|high|low|high" ] || fail "역할별 effort: config 값이 독립적으로 적용되지 않음 ($role_efforts, 기대 $src_designer_effort|$src_validator_effort|high|low|high)"
conventions_without_file="$(bash -c 'source "$1"; load_project_conventions' _ "$TARGET_SKILL/config.sh")"
[ -z "$conventions_without_file" ] || fail "규칙 병합: conventions.md가 없는데 내용이 생성됨"
worker_rules_without_conventions="$(bash -c 'source "$1"; load_worker_rules' _ "$TARGET_SKILL/config.sh")"
echo "$worker_rules_without_conventions" | grep -q '커스텀 규칙' || fail "워커 규칙: core_rules.md 누락"
echo "$worker_rules_without_conventions" | grep -q '\[PROJECT CONVENTIONS\]' \
  && fail "워커 규칙: conventions.md가 없는데 구획이 생성됨"
printf '# 프로젝트 컨벤션\n' > "$TARGET/conventions.md"
conventions_with_file="$(bash -c 'source "$1"; load_project_conventions' _ "$TARGET_SKILL/config.sh")"
echo "$conventions_with_file" | grep -q '\[PROJECT CONVENTIONS\]' || fail "규칙 병합: conventions 구획 누락"
echo "$conventions_with_file" | grep -q '프로젝트 컨벤션' || fail "규칙 병합: conventions.md 내용 누락"
echo "$conventions_with_file" | grep -q '커스텀 규칙' && fail "규칙 분리: core_rules.md가 비워커 규칙에 포함됨"
orchestrator_rules="$(CLAUDE_PROJECT_DIR="$TARGET" bash "$TARGET/.claude/hooks/inject_conventions.sh")"
echo "$orchestrator_rules" | grep -q '프로젝트 컨벤션' || fail "오케스트레이터 규칙: conventions.md 누락"
echo "$orchestrator_rules" | grep -q '커스텀 규칙' && fail "오케스트레이터 규칙: core_rules.md가 주입됨"
grep -Fq '${WORKER_RULES}' "$TARGET_SKILL/prompts/worker-implement.md" || fail "규칙 전달: 워커 프롬프트 누락"
grep -Fq '${PROJECT_CONVENTIONS}' "$TARGET_SKILL/prompts/validator-review-design.md" || fail "규칙 전달: 검증자 conventions 누락"
# 검증자 프로필 오버레이: 세 프로필 파일이 설치되고, 모델별 기본 매핑·명시 프로필·none·오타 실패가 동작하는지
for ov in compact guided conservative; do
  [ -f "$TARGET_SKILL/prompts/validator-overlays/$ov.md" ] || fail "검증자 오버레이 미설치: $ov.md"
done
overlay_sol="$(bash -c 'source "$1"; VALIDATOR_MODEL=gpt-5.6-sol VALIDATOR_PROFILE=""; load_validator_overlay' _ "$TARGET_SKILL/config.sh")"
echo "$overlay_sol" | grep -q '^\[VALIDATOR PROFILE: compact\]$' || fail "검증자 프로필: sol 기본값이 compact 가 아님"
overlay_explicit="$(bash -c 'source "$1"; VALIDATOR_MODEL=gpt-5.6-sol VALIDATOR_PROFILE=guided; load_validator_overlay' _ "$TARGET_SKILL/config.sh")"
echo "$overlay_explicit" | grep -q '^\[VALIDATOR PROFILE: guided\]$' || fail "검증자 프로필: 명시 VALIDATOR_PROFILE 이 모델 기본값을 덮지 않음"
overlay_none="$(bash -c 'source "$1"; VALIDATOR_PROFILE=none; load_validator_overlay' _ "$TARGET_SKILL/config.sh")"
[ -z "$overlay_none" ] || fail "검증자 프로필: none 인데 오버레이가 출력됨"
bash -c 'source "$1"; VALIDATOR_PROFILE=no-such-profile; load_validator_overlay' _ "$TARGET_SKILL/config.sh" >/dev/null 2>&1 \
  && fail "검증자 프로필: 없는 프로필이 조용히 생략됨"
grep -Fq 'VALIDATOR_OVERLAY="$(load_validator_overlay)" || exit 1' "$TARGET_SKILL/scripts/consensus-loop.sh" || fail "검증자 프로필: consensus-loop 오버레이 로딩 누락"
grep -Fq '"$VALIDATOR_OVERLAY"' "$TARGET_SKILL/scripts/consensus-loop.sh" || fail "검증자 프로필: 오버레이가 검증자 프롬프트에 붙지 않음"
# conventions 는 역할 호출 헬퍼(config.sh)로 전달된다 — claude 는 --append-system-prompt, codex 는 프롬프트 앞 블록.
grep -Fq 'run_readonly_json_role REVIEWER reviewer' "$TARGET_SKILL/scripts/impl-review-loop.sh" \
  && grep -Eq 'run_readonly_json_role REVIEWER .*"\$PROJECT_CONVENTIONS"' "$TARGET_SKILL/scripts/impl-review-loop.sh" \
  && grep -Eq 'run_edit_role FIXER .*"\$PROJECT_CONVENTIONS"' "$TARGET_SKILL/scripts/impl-review-loop.sh" \
  && grep -Fq -- '--append-system-prompt "$conv"' "$TARGET_SKILL/config.sh" \
  || fail "규칙 전달: 리뷰어/수정자 conventions 전달 누락"
# 역할 → CLI 라우팅: 모델 이름으로 claude/codex 를 고르고, <ROLE>_CLI 로 덮어쓸 수 있으며, 알 수 없는 이름은 실패한다.
routing="$(bash -c 'source "$1"
  a=$(REVIEWER_MODEL=gpt-6-astra REVIEWER_CLI="" role_cli REVIEWER)
  b=$(REVIEWER_MODEL=claude-sonnet-5 REVIEWER_CLI="" role_cli REVIEWER)
  c=$(WORKER_MODEL=o4-mini WORKER_CLI="" role_cli WORKER)
  d=$(WORKER_MODEL=mystery-1 WORKER_CLI=claude role_cli WORKER)
  e=$(WORKER_MODEL=mystery-1 WORKER_CLI="" role_cli WORKER 2>/dev/null || echo FAIL)
  f=$(WORKER_MODEL=gpt-5.6-luna WORKER_CLI=gemini role_cli WORKER 2>/dev/null || echo FAIL)
  printf "%s|%s|%s|%s|%s|%s" "$a" "$b" "$c" "$d" "$e" "$f"' _ "$TARGET_SKILL/config.sh")"
[ "$routing" = "codex|claude|codex|claude|FAIL|FAIL" ] || fail "역할 → CLI 라우팅 오류: $routing"
grep -Fq 'require_role_bins REVIEWER FIXER' "$TARGET_SKILL/scripts/impl-review-loop.sh" || fail "설치 확인이 설정된 역할의 CLI 를 따르지 않음(impl-review-loop)"
grep -Fq 'require_role_bins DESIGNER VALIDATOR WORKER REVIEWER FIXER' "$TARGET_SKILL/scripts/feature-run.sh" || fail "설치 확인이 설정된 역할의 CLI 를 따르지 않음(feature-run)"
grep -Fq '.blocking_issues[]?' "$TARGET_SKILL/scripts/consensus-loop.sh" || fail "관찰성: 상세 blocking 이슈 출력 누락"
grep -q 'decisions_lines_before' "$TARGET_SKILL/scripts/consensus-loop.sh" || fail "관찰성: 신규 결정 출력 누락"
echo "[OK] 3b. 역할별 모델/effort + 역할→CLI 라우팅 + 선택 conventions + 합의 로그"

# ---------- 4. 비호환 구버전 config → 활성 코드 교체 전 중단 ----------
printf 'TEST_CMD="npm test"\nLINT_CMD="true"\n' > "$TARGET_SKILL/config.sh"
printf 'sentinel\n' > "$TARGET_SKILL/scripts/.pre-update-sentinel"
if bash "$SOURCE_ROOT/install.sh" "$TARGET" >/dev/null 2>&1; then
  fail "비호환 config: 중단 없이 성공함"
fi
[ -f "$TARGET_SKILL/scripts/.pre-update-sentinel" ] || fail "비호환 config: 중단 전에 활성 코드가 교체됨"
ls "$TARGET_SKILL"/.install-stage-* >/dev/null 2>&1 && fail "비호환 config: 스테이징 잔여물 남음"
echo "[OK] 4. 비호환 config 사전 중단 (활성 코드 무손상)"

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

# ---------- 5. 잘못된 이벤트에 등록된 훅 → 미등록으로 판정 ----------
WRONG_EVENT_TARGET="$SCRATCH/wrong-event"
git init -q "$WRONG_EVENT_TARGET"
mkdir -p "$WRONG_EVENT_TARGET/.claude"
jq -n '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: "$CLAUDE_PROJECT_DIR/.claude/hooks/pre_bash_guard.sh"}]}]}}' \
  > "$WRONG_EVENT_TARGET/.claude/settings.json"
wrong_event_output="$(bash "$SOURCE_ROOT/install.sh" "$WRONG_EVENT_TARGET")"
echo "$wrong_event_output" | grep -q 'PreToolUse 에 pre_bash_guard.sh 미등록' \
  || fail "훅 이벤트 검사: 잘못된 이벤트 등록을 설치됨으로 오판"
echo "[OK] 5. 훅 이벤트 단위 검사"

# ---------- 5b. 올바른 이벤트 + 가짜 command 문자열 → 미등록으로 판정 ----------
FAKE_COMMAND_TARGET="$SCRATCH/fake-command"
git init -q "$FAKE_COMMAND_TARGET"
mkdir -p "$FAKE_COMMAND_TARGET/.claude"
jq -n '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: "echo disabled pre_bash_guard.sh"}]}]}}' \
  > "$FAKE_COMMAND_TARGET/.claude/settings.json"
fake_command_output="$(bash "$SOURCE_ROOT/install.sh" "$FAKE_COMMAND_TARGET")"
echo "$fake_command_output" | grep -q 'PreToolUse 에 pre_bash_guard.sh 미등록' \
  || fail "훅 command 검사: 비활성 문자열(echo disabled ...)을 설치됨으로 오판"
echo "[OK] 5b. 가짜 command 문자열 미등록 판정"

# ---------- 5c. 레거시 core rules 주입 훅 → 교체 경고 ----------
LEGACY_HOOK_TARGET="$SCRATCH/legacy-hook"
git init -q "$LEGACY_HOOK_TARGET"
mkdir -p "$LEGACY_HOOK_TARGET/.claude"
jq -n '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: "$CLAUDE_PROJECT_DIR/.claude/hooks/inject_core_rules.sh"}]}]}}' \
  > "$LEGACY_HOOK_TARGET/.claude/settings.json"
legacy_hook_output="$(bash "$SOURCE_ROOT/install.sh" "$LEGACY_HOOK_TARGET")"
echo "$legacy_hook_output" | grep -q '레거시 inject_core_rules.sh' \
  || fail "훅 마이그레이션: 레거시 core rules 주입 훅 교체 경고 누락"
echo "$legacy_hook_output" | grep -q 'inject_conventions.sh로 교체' \
  || fail "훅 마이그레이션: 교체 대상 안내 누락"
echo "[OK] 5c. 레거시 core rules 훅 교체 안내"

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
sed -i.sedbak 's/^CLAUDE_BIN=.*/CLAUDE_BIN="true"/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^CODEX_BIN=.*/CODEX_BIN="true"/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^TEST_CMD=.*/TEST_CMD="true"/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^LINT_CMD=.*/LINT_CMD="true"/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
chmod -x "$LOG_TARGET/feature-live"

mkdir -p "$LOG_TARGET/.agent-work"
printf '이전 피처 로그\n' > "$LOG_TARGET/.agent-work/live.log"
printf '이전 산출물\n' > "$LOG_TARGET/.agent-work/previous.txt"
set +e
(cd "$LOG_TARGET" && bash "$LOG_SKILL/scripts/feature-run.sh" --new --archive-as live-regression) >/dev/null 2>&1
new_rc=$?
set -e
[ "$new_rc" = 3 ] || fail "live.log 아카이브: 새 피처 초기화 종료 코드가 3이 아님 ($new_rc)"
[ "$(cat "$LOG_TARGET/.agent-work/archive/live-regression/live.log")" = '이전 피처 로그' ] \
  || fail "live.log 아카이브: 이전 로그 내용이 보존되지 않음"
[ -f "$LOG_TARGET/.agent-work/archive/live-regression/previous.txt" ] \
  || fail "live.log 아카이브: 다른 이전 산출물과 같은 디렉터리에 보관되지 않음"
grep -q '이전 피처 로그' "$LOG_TARGET/.agent-work/live.log" \
  && fail "live.log 아카이브: 새 로그에 이전 로그가 계속 누적됨"

printf '# design\n' > "$LOG_TARGET/.agent-work/design.md"
mkdir -p "$LOG_TARGET/.agent-work/reviews"
printf '{"schema_version":9,"verdict":"PASS","blocking_issues":[]}\n' \
  > "$LOG_TARGET/.agent-work/reviews/validator-design-round-01.json"
set +e
(cd "$LOG_TARGET" && bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
resume_rc=$?
set -e
[ "$resume_rc" = 3 ] || fail "중첩 tee: 설계 합의 후 구현 문서 대기 종료 코드가 3이 아님 ($resume_rc)"
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
printf '# implementation\n' > "$LOG_TARGET/.agent-work/implementation.md"
printf '# approach\n' > "$LOG_TARGET/.agent-work/approach.md"
fake_scope "$LOG_TARGET" src/x.txt            # impl PASS 지문에 manifest 가 들어가므로 합의보다 먼저 둔다
fake_consensus_pass "$LOG_TARGET" impl        # CODEX_BIN 이 아직 "true" 인 동안 체크포인트를 만든다
# 워커 원문 로그를 reviews/에 보존하면서 live.log에도 실시간 전달한다.
FAKE_CODEX="$LOG_TARGET/fake-codex"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -e' \
  'output_file=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in -o) output_file="$2"; shift 2;; *) shift;; esac' \
  'done' \
  'printf "WORKER_STREAM_MARKER\\n"' \
  'if [ "${FAKE_TAMPER_BASELINE:-0}" = 1 ]; then printf "%s\\n" 4b825dc642cb6eb9a060e54bf8d69288fbee4904 > .agent-work/worker-baseline.tree; echo tampered >> src/existing-under-root.txt; fi' \
  'if [ "${FAKE_TAMPER_BOTH:-0}" = 1 ]; then printf "%s\\n" 4b825dc642cb6eb9a060e54bf8d69288fbee4904 > .agent-work/worker-baseline.tree; for m in .agent-work/feature-scope.json .agent-work/feature-scope.lock.json; do jq -c ".files += [\"src/z.txt\"]" "$m" > "$m.tmp" && mv "$m.tmp" "$m"; done; echo tampered-both >> src/existing-under-root.txt; fi' \
  'printf '\''{"status":"UNDECIDED","undecided":[{"kind":"'"'"'"$FAKE_KIND"'"'"'","location":"test","decision_needed":"test decision","options":[]}],"delegated_choices":[],"tests":[]}'\'' > "$output_file"' \
  > "$FAKE_CODEX"
chmod +x "$FAKE_CODEX"
sed -i.sedbak "s|^CODEX_BIN=.*|CODEX_BIN=\"$FAKE_CODEX\"|" "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' \
  > "$LOG_TARGET/.agent-work/run-state.json"
: > "$LOG_TARGET/.agent-work/live.log"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
worker_rc=$?
set -e
[ "$worker_rc" = 2 ] || fail "워커 스트리밍: USER_DECISION 종료 코드가 2가 아님 ($worker_rc)"
[ -f "$LOG_TARGET/.agent-work/worker-baseline.tree" ] || fail "워커 기준선: 러너가 worker-baseline.tree 를 기록하지 않음"
(cd "$LOG_TARGET" && git cat-file -e "$(cat .agent-work/worker-baseline.tree)") || fail "워커 기준선: tree 객체가 저장소에 없음"
worker_raw="$(ls "$LOG_TARGET"/.agent-work/reviews/worker-*.log | tail -1)"
[ "$(grep -c 'WORKER_STREAM_MARKER' "$worker_raw")" = 1 ] \
  || fail "워커 스트리밍: reviews 원문 로그에 출력이 정확히 1회 보존되지 않음"
[ "$(grep -c 'WORKER_STREAM_MARKER' "$LOG_TARGET/.agent-work/live.log")" = 1 ] \
  || fail "워커 스트리밍: live.log에 출력이 정확히 1회 전달되지 않음"
# DOC_GAP 만 있으면 사용자에게 가지 않고 NEED_DOCS(exit 3), 재실행 시 검증자 재합의(stage=impl)
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > "$LOG_TARGET/.agent-work/run-state.json"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=DOC_GAP bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
docgap_rc=$?
set -e
[ "$docgap_rc" = 3 ] || fail "DOC_GAP: 종료 코드가 3(NEED_DOCS)이 아님 ($docgap_rc)"
[ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = APPROACH_GAP ] || fail "DOC_GAP: reason 이 APPROACH_GAP 이 아님"
[ "$(jq -r '.stage' "$LOG_TARGET/.agent-work/run-state.json")" = impl ] || fail "DOC_GAP: 재개 stage 가 impl 이 아님"
# 필수 워커 스킬 누락 → run_worker 가 실제로 중단하고(exit 1) 가짜 codex 를 부르지 않는다 (load_worker_rules 단독 호출로는 잡히지 않는 경로)
sed -i.sedbak 's/^WORKER_SKILLS=.*/WORKER_SKILLS=("missing-skill")/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > "$LOG_TARGET/.agent-work/run-state.json"
: > "$LOG_TARGET/.agent-work/live.log"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
missing_skill_rc=$?
set -e
[ "$missing_skill_rc" = 1 ] || fail "필수 워커 스킬 누락: 러너 종료 코드가 1 이 아님 ($missing_skill_rc)"
grep -q "필수 워커 스킬 'missing-skill' 없음" "$LOG_TARGET/.agent-work/live.log" || fail "필수 워커 스킬 누락: 실패 사유가 기록되지 않음"
grep -q 'WORKER_STREAM_MARKER' "$LOG_TARGET/.agent-work/live.log" && fail "필수 워커 스킬 누락: 워커(codex)가 호출됨"
sed -i.sedbak 's/^WORKER_SKILLS=.*/WORKER_SKILLS=()/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
# worker 단계 진입 시 원본 != lock → exit 2, run-state NEED_USER/SCOPE_MANIFEST_CHANGED, codex 호출 0 (set -e 아래 stop_need_user 도달 확인)
[ -f "$LOG_TARGET/.agent-work/feature-scope.lock.json" ] || fail "scope lock: 러너가 feature-scope.lock.json 을 확정하지 않음"
cp "$LOG_TARGET/.agent-work/feature-scope.json" "$LOG_TARGET/.agent-work/feature-scope.json.orig"
jq -c '.files += ["src/y.txt"]' "$LOG_TARGET/.agent-work/feature-scope.json.orig" > "$LOG_TARGET/.agent-work/feature-scope.json"
# 원본 manifest 는 impl PASS 지문에 포함되므로 러너는 먼저 impl 재합의로 돌아간다(설계된 흐름). 사용자가 재합의를 마친 뒤
# lock 을 지우지 않고 재실행한 상황을 만들기 위해 impl 체크포인트를 다시 만든다 (그동안만 CODEX_BIN=true).
sed -i.sedbak "s|^CODEX_BIN=.*|CODEX_BIN=\"true\"|" "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
fake_consensus_pass "$LOG_TARGET" impl
sed -i.sedbak "s|^CODEX_BIN=.*|CODEX_BIN=\"$FAKE_CODEX\"|" "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > "$LOG_TARGET/.agent-work/run-state.json"
: > "$LOG_TARGET/.agent-work/live.log"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
lock_mismatch_rc=$?
set -e
[ "$lock_mismatch_rc" = 2 ] || fail "scope lock 불일치: 러너 종료 코드가 2 가 아님 ($lock_mismatch_rc)"
[ "$(jq -r '.status' "$LOG_TARGET/.agent-work/run-state.json")" = NEED_USER ] || fail "scope lock 불일치: run-state status 가 NEED_USER 가 아님 ($(jq -r '.status' "$LOG_TARGET/.agent-work/run-state.json"))"
[ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = SCOPE_MANIFEST_CHANGED ] || fail "scope lock 불일치: reason 이 SCOPE_MANIFEST_CHANGED 가 아님"
grep -q 'WORKER_STREAM_MARKER' "$LOG_TARGET/.agent-work/live.log" && fail "scope lock 불일치: 워커(codex)가 호출됨"
cp "$LOG_TARGET/.agent-work/feature-scope.json.orig" "$LOG_TARGET/.agent-work/feature-scope.json"
# 워커가 worker-baseline.tree 를 빈 tree 로 바꾸고 new_file_roots 아래 기존 파일을 수정 → SCOPE_BASELINE_CHANGED, review 미진입, 원복 없음
# 준비: 기준선에 있는 root 아래 파일을 커밋하고, roots 가 있는 manifest 로 원본·lock 을 맞춘 뒤 impl 체크포인트를 다시 만든다
mkdir -p "$LOG_TARGET/src" && echo "existing" > "$LOG_TARGET/src/existing-under-root.txt"
(cd "$LOG_TARGET" && git add src/existing-under-root.txt && git -c user.email=smoke@test -c user.name=smoke commit -qm "existing under root")
jq -c '.new_file_roots = ["src/"]' "$LOG_TARGET/.agent-work/feature-scope.json.orig" > "$LOG_TARGET/.agent-work/feature-scope.json"
cp "$LOG_TARGET/.agent-work/feature-scope.json" "$LOG_TARGET/.agent-work/feature-scope.lock.json"
sed -i.sedbak "s|^CODEX_BIN=.*|CODEX_BIN=\"true\"|" "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
fake_consensus_pass "$LOG_TARGET" impl
sed -i.sedbak "s|^CODEX_BIN=.*|CODEX_BIN=\"$FAKE_CODEX\"|" "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
(cd "$LOG_TARGET" && bash -c 'source .claude/skills/feature/config.sh; snapshot_worktree_tree > .agent-work/worker-baseline.tree')   # 기준선에 existing-under-root.txt 포함
cp "$LOG_TARGET/.agent-work/worker-baseline.tree" "$LOG_TARGET/.agent-work/worker-baseline.tree.keep"
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
: > "$LOG_TARGET/.agent-work/live.log"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
tamper_rerun_rc=$?
set -e
[ "$tamper_rerun_rc" = 2 ] || fail "기준선 미복구 재실행: 종료 코드가 2 가 아님 ($tamper_rerun_rc)"
[ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = SCOPE_BASELINE_CHANGED ] || fail "기준선 미복구 재실행: reason 이 SCOPE_BASELINE_CHANGED 가 아님"
grep -q 'WORKER_STREAM_MARKER' "$LOG_TARGET/.agent-work/live.log" && fail "기준선 미복구 재실행: 워커(codex)가 호출됨"
# 원래 값으로 복구하면 워커가 재개된다 (가짜 워커는 USER_DECISION 을 내므로 exit 2 / UNDECIDED)
cp "$LOG_TARGET/.agent-work/worker-baseline.tree.keep" "$LOG_TARGET/.agent-work/worker-baseline.tree"
: > "$LOG_TARGET/.agent-work/live.log"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
restored_rc=$?
set -e
[ "$restored_rc" = 2 ] && [ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = UNDECIDED ] || fail "기준선 복구 후: 워커가 재개되지 않음 (rc $restored_rc, reason $(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json"))"
grep -q 'WORKER_STREAM_MARKER' "$LOG_TARGET/.agent-work/live.log" || fail "기준선 복구 후: 워커(codex)가 호출되지 않음"
[ "$(jq -r .active "$LOG_TARGET/.agent-work/worker-baseline.guard.json")" = false ] || fail "기준선 복구 후: 가드가 비활성화되지 않음"
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
: > "$LOG_TARGET/.agent-work/live.log"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
both_rerun_rc=$?
set -e
[ "$both_rerun_rc" = 2 ] && [ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = SCOPE_BASELINE_CHANGED ] || fail "복합 변조: manifest 만 복구한 재실행이 막히지 않음 (rc $both_rerun_rc, reason $(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json"))"
grep -q 'WORKER_STREAM_MARKER' "$LOG_TARGET/.agent-work/live.log" && fail "복합 변조: 기준선 미복구 재실행에서 워커(codex)가 호출됨"
# 기준선까지 복구하면 재개
cp "$LOG_TARGET/.agent-work/worker-baseline.tree.keep" "$LOG_TARGET/.agent-work/worker-baseline.tree"
: > "$LOG_TARGET/.agent-work/live.log"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
both_restored_rc=$?
set -e
[ "$both_restored_rc" = 2 ] && [ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = UNDECIDED ] || fail "복합 변조 복구 후: 워커가 재개되지 않음 (rc $both_restored_rc, reason $(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json"))"
grep -q 'WORKER_STREAM_MARKER' "$LOG_TARGET/.agent-work/live.log" || fail "복합 변조 복구 후: 워커(codex)가 호출되지 않음"
echo "[OK] 8. live.log 아카이브 + 중첩 tee 중복 방지 + 워커 출력 스트리밍 + 필수 워커 스킬 누락 시 워커 미실행 + scope lock 불일치 시 NEED_USER + 기준선 조작 시 SCOPE_BASELINE_CHANGED(미복구 재실행 재중단·복구 후 재개·복합 변조 시 가드 보존)"

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
echo "$duplicate_viewer_output" | grep -q '이미 실행 중' \
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
  'jq -n -c --slurpfile r "$FAKE_REVIEW" '"'"'{structured_output: $r[0], session_id:"fake", total_cost_usd:0, usage:{input_tokens:0,output_tokens:0,cache_read_input_tokens:0,cache_creation_input_tokens:0}}'"'" \
  > "$REVIEW_SIDE/fake-claude"
chmod +x "$REVIEW_SIDE/fake-claude"
sed -i.sedbak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$REVIEW_SIDE/fake-claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"true\"|; s/^TEST_CMD=.*/TEST_CMD=\"true\"/; s/^LINT_CMD=.*/LINT_CMD=\"true\"/; s/^MAX_IMPL_ROUNDS=.*/MAX_IMPL_ROUNDS=0/" "$REVIEW_SKILL/config.sh" && rm -f "$REVIEW_SKILL/config.sh.sedbak"
mkdir -p "$REVIEW_TARGET/src" "$REVIEW_TARGET/.agent-work/reviews"
printf 'base\n' > "$REVIEW_TARGET/src/a.txt"
printf 'base\n' > "$REVIEW_TARGET/src/b.txt"
(cd "$REVIEW_TARGET" && git add -A && git -c user.email=t@t -c user.name=t commit -qm base)
# 피처 이전부터 있던 사용자의 미커밋 변경(b.txt) → 워커 진입 기준선에 포함돼 리뷰 diff 에 나오면 안 된다
printf 'user edit before feature\n' > "$REVIEW_TARGET/src/b.txt"
(cd "$REVIEW_TARGET" && bash -c 'source .claude/skills/feature/config.sh; snapshot_worktree_tree' > .agent-work/worker-baseline.tree)
printf 'changed\n' > "$REVIEW_TARGET/src/a.txt"
printf 'new\n' > "$REVIEW_TARGET/src/new.txt"
for doc in design implementation approach; do printf '# %s\n' "$doc" > "$REVIEW_TARGET/.agent-work/$doc.md"; done
fake_scope "$REVIEW_TARGET" src/a.txt src/new.txt   # b.txt 는 범위 밖 — 리뷰 diff·승인 지문에서 제외된다 (impl PASS 지문에 포함되므로 합의보다 먼저)
fake_consensus_pass "$REVIEW_TARGET" design
fake_consensus_pass "$REVIEW_TARGET" impl
printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[]}\n' > "$REVIEW_TARGET/.agent-work/worker-result.json"
review_issue='{"id":"R-01","action":"FIX_CODE","category":"CONTRACT_VIOLATION","evidence_type":"DIRECT_MISMATCH","basis_refs":["approach.md:L1"],"code_refs":["src/a.txt:L1-L1"],"reachable_scenario":"","impact":"","why_blocks_now":"x","required_outcome":"y","origin":"ROUND_1","previous_issue_id":"","fix_ref":""}'
run_review_loop() { # fake-review-json → exit code (stdout 은 run.log)
  printf '%s\n' "$1" > "$REVIEW_SIDE/review.json"
  # 각 사례는 새 리뷰어 호출을 전제한다 — 직전 사례의 APPROVE 체크포인트가 재사용되지 않게 포맷 버전 불일치로 무효화
  printf '{"version":0}\n' > "$REVIEW_TARGET/.agent-work/review-impl.json"
  local rc=0   # 함수 안에서 set ±e 를 토글하지 않는다 — 호출자의 errexit 상태를 바꾼다
  (cd "$REVIEW_TARGET" && FAKE_REVIEW="$REVIEW_SIDE/review.json" FEATURE_LIVE_TEE=1 bash "$REVIEW_SKILL/scripts/impl-review-loop.sh") > "$REVIEW_SIDE/run.log" 2>&1 || rc=$?
  return $rc
}
# (a) APPROVE → exit 0, 승인 지문 생성, diff 에 untracked 신규 파일 포함
run_review_loop '{"schema_version":8,"verdict":"APPROVE","issues":[]}' || fail "리뷰 루프: APPROVE 가 exit 0 이 아님"
[ -f "$REVIEW_TARGET/.agent-work/approved.fingerprint" ] || fail "리뷰 루프: 승인 지문 미생성"
grep -q 'src/new.txt' "$REVIEW_TARGET/.agent-work/reviews/impl-attempt-01/diff-round-01.patch" || fail "리뷰 루프: untracked 신규 파일이 리뷰 diff 에 없음"
grep -q 'src/b.txt' "$REVIEW_TARGET/.agent-work/reviews/impl-attempt-01/diff-round-01.patch" && fail "리뷰 루프: 기준선 이전 사용자 변경(b.txt)이 리뷰 diff 에 섞임"
grep -q '리뷰 기준선: 워커 진입 직전 tree' "$REVIEW_SIDE/run.log" || fail "리뷰 루프: 기준선 tree 를 쓰지 않음"
# (b) Round 1 인데 origin=FIX_REGRESSION → 연계 검사가 응답 오류로 거부 (exit 1)
run_review_loop "$(printf '%s' "$review_issue" | jq -c '{schema_version:8,verdict:"REQUEST_CHANGES",issues:[. + {origin:"FIX_REGRESSION",fix_ref:"src/a.txt:L1-L1"}]}')" && fail "리뷰 루프: Round 1 의 FIX_REGRESSION origin 이 통과됨"
grep -q '근거·연계 필드' "$REVIEW_SIDE/run.log" || fail "리뷰 루프: origin 위반 거부 사유가 기록되지 않음"
# (c) schema_version 불일치 → exit 1
run_review_loop '{"schema_version":1,"verdict":"APPROVE","issues":[]}' && fail "리뷰 루프: 구버전 schema_version 이 통과됨"
# (d) FIX_CODE 인데 required_outcome 비어 있음 → exit 1
run_review_loop "$(printf '%s' "$review_issue" | jq -c '{schema_version:8,verdict:"REQUEST_CHANGES",issues:[. + {required_outcome:""}]}')" && fail "리뷰 루프: required_outcome 없는 FIX_CODE 가 통과됨"
# (e) DOC_GAP → exit 3, 러너는 NEED_DOCS(APPROACH_GAP) + stage=impl 로 반환
set +e; run_review_loop "$(printf '%s' "$review_issue" | jq -c '{schema_version:8,verdict:"REQUEST_CHANGES",issues:[. + {action:"DOC_GAP"}]}')"; docgap_loop_rc=$?; set -e
[ "$docgap_loop_rc" = 3 ] || fail "리뷰 루프: DOC_GAP 종료 코드가 3 이 아님 ($docgap_loop_rc)"
[ "$(jq -r '.status' "$REVIEW_TARGET/.agent-work/state.json")" = DOC_GAP ] || fail "리뷰 루프: state.json 이 DOC_GAP 이 아님"
printf '{"stage":"review","test_retries":0,"stale_count":0,"history":[]}\n' > "$REVIEW_TARGET/.agent-work/run-state.json"
set +e
(cd "$REVIEW_TARGET" && FAKE_REVIEW="$REVIEW_SIDE/review.json" bash "$REVIEW_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
review_docgap_rc=$?
set -e
[ "$review_docgap_rc" = 3 ] || fail "리뷰어 DOC_GAP: 러너 종료 코드가 3(NEED_DOCS)이 아님 ($review_docgap_rc)"
[ "$(jq -r '.reason' "$REVIEW_TARGET/.agent-work/run-state.json")" = APPROACH_GAP ] || fail "리뷰어 DOC_GAP: reason 이 APPROACH_GAP 이 아님"
[ "$(jq -r '.stage' "$REVIEW_TARGET/.agent-work/run-state.json")" = impl ] || fail "리뷰어 DOC_GAP: 재개 stage 가 impl 이 아님"
# (f) 역할 → CLI 라우팅: REVIEWER_MODEL 을 gpt-* 로 바꾸면 같은 루프가 codex 로 리뷰어를 부른다 (읽기 전용 sandbox + 스키마 + -o), claude 는 호출 0회
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# 가짜 codex: 리뷰어 호출 형태를 검사하고 FAKE_REVIEW 를 -o 경로에 쓴다' \
  'case " $* " in *" --sandbox read-only "*) ;; *) echo "codex reviewer without read-only sandbox: $*" >&2; exit 9;; esac' \
  'case " $* " in *" --output-schema "*) ;; *) echo "codex reviewer without --output-schema: $*" >&2; exit 9;; esac' \
  'case " $* " in *" -m gpt-6-astra "*) ;; *) echo "codex reviewer with wrong model: $*" >&2; exit 9;; esac' \
  'out=""; while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done' \
  'printf "codex\n" >> "$FAKE_COUNT.codex"; cp "$FAKE_REVIEW" "$out"' \
  > "$REVIEW_SIDE/fake-codex-reviewer"
printf '%s\n' '#!/usr/bin/env bash' 'printf "claude\n" >> "$FAKE_COUNT.claude"; exit 9' > "$REVIEW_SIDE/fake-claude-never"
chmod +x "$REVIEW_SIDE/fake-codex-reviewer" "$REVIEW_SIDE/fake-claude-never"
cp "$REVIEW_SKILL/config.sh" "$REVIEW_SIDE/config.before-routing.sh"
sed -i.sedbak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$REVIEW_SIDE/fake-claude-never\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$REVIEW_SIDE/fake-codex-reviewer\"|; s/^REVIEWER_MODEL=.*/REVIEWER_MODEL=\"gpt-6-astra\"/; s/^REVIEWER_EFFORT=.*/REVIEWER_EFFORT=\"low\"/" "$REVIEW_SKILL/config.sh"
mv "$REVIEW_SKILL/config.sh.sedbak" "$REVIEW_SIDE/config.sedbak.routing"
FAKE_COUNT="$REVIEW_SIDE/.routing-calls" run_review_loop '{"schema_version":8,"verdict":"APPROVE","issues":[]}' \
  || { tail -5 "$REVIEW_SIDE/run.log" >&2; fail "라우팅: REVIEWER_MODEL=gpt-* 인데 codex 리뷰어가 APPROVE 로 exit 0 이 아님"; }
[ -f "$REVIEW_SIDE/.routing-calls.codex" ] || fail "라우팅: codex 리뷰어가 호출되지 않음"
[ ! -f "$REVIEW_SIDE/.routing-calls.claude" ] || fail "라우팅: 리뷰어가 codex 인데 claude 가 호출됨"
routing_attempt_dir="$(ls -d "$REVIEW_TARGET/.agent-work/reviews/impl-attempt-"* | sort | tail -1)"   # 앞 사례들이 attempt 를 소비했으므로 마지막 attempt
[ -f "$routing_attempt_dir/reviewer-round-01.json.log" ] || fail "라우팅: codex 리뷰어 로그(.log)가 남지 않음 ($routing_attempt_dir)"
[ "$(jq -r '.verdict' "$routing_attempt_dir/reviewer-round-01.json")" = APPROVE ] || fail "라우팅: codex 리뷰어 결과 JSON 이 -o 경로에 없음"
grep -q '검증자 CLI\|claude 실행 실패' "$REVIEW_SIDE/run.log" && fail "라우팅: codex 리뷰어 경로에서 claude 오류 메시지가 나옴"
cp "$REVIEW_SIDE/config.before-routing.sh" "$REVIEW_SKILL/config.sh"   # 이후 절은 원래(claude 리뷰어) 설정으로 계속
# 이 사례의 APPROVE 산출물(승인 지문·체크포인트)이 다음 절에서 재사용되지 않게 치운다 (삭제 대신 이동)
mv "$REVIEW_TARGET/.agent-work/approved.fingerprint" "$REVIEW_SIDE/approved.fingerprint.routing"
printf '{"version":0}\n' > "$REVIEW_TARGET/.agent-work/review-impl.json"
echo "[OK] 10. 구현 리뷰 루프 계약 연계 검사 (APPROVE / origin / schema_version / 필드 / DOC_GAP / 리뷰어 codex 라우팅)"

# ---------- 11. 범위 밖 변경은 자동 원복하지 않는다 — FOREIGN_WORKTREE_CHANGE 로 보존 후 중단 ----------
# b.txt: 기준선 이전 사용자 unstaged 변경 + 기준선 이후 (워커 또는 다른 세션의) 추가 변경. 리뷰어가 OUT_OF_SCOPE_CHANGE 를 내면
# 수정자를 부르지 않고 exit 2 / FOREIGN_WORKTREE_CHANGE. 내용·git status 모두 그대로 (worker-baseline.tree 는 시점 기준선이지 소유권 증거가 아니다).
printf 'user edit before feature\nworker edit\n' > "$REVIEW_TARGET/src/b.txt"
status_before="$(cd "$REVIEW_TARGET" && git status --porcelain=v1 -- src/b.txt)"
[ "$status_before" = " M src/b.txt" ] || fail "원복 금지 픽스처: b.txt 초기 상태가 unstaged 수정이 아님 ($status_before)"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# 리뷰어 호출: 1회차 FAKE_REVIEW, 2회차 FAKE_REVIEW2. 수정자 호출(--permission-mode): FAKE_FIX_CMD 를 실행하고 호출 사실을 기록' \
  'case " $* " in *" --permission-mode "*) printf "fixer\n" >> "$FAKE_COUNT.fixer"; eval "${FAKE_FIX_CMD:-true}"; printf "%s\n" "{\"session_id\":\"fake\",\"total_cost_usd\":0,\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}"; exit "${FAKE_FIX_RC:-0}";; esac' \
  'n=$(( $(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1 )); printf "%s" "$n" > "$FAKE_COUNT"' \
  'f="$FAKE_REVIEW"; [ "$n" -ge 2 ] && f="$FAKE_REVIEW2"' \
  'jq -n -c --slurpfile r "$f" '"'"'{structured_output: $r[0], session_id:"fake", total_cost_usd:0, usage:{input_tokens:0,output_tokens:0,cache_read_input_tokens:0,cache_creation_input_tokens:0}}'"'" \
  > "$REVIEW_SIDE/fake-claude-fix"
chmod +x "$REVIEW_SIDE/fake-claude-fix"
printf '%s\n' "$review_issue" | jq -c '{schema_version:8,verdict:"REQUEST_CHANGES",issues:[. + {category:"OUT_OF_SCOPE_CHANGE",code_refs:["src/b.txt:L2-L2"],required_outcome:"src/b.txt 의 변경이 범위 밖"}]}' > "$REVIEW_SIDE/review-oos.json"
printf '%s\n' "$review_issue" | jq -c '{schema_version:8,verdict:"REQUEST_CHANGES",issues:[.]}' > "$REVIEW_SIDE/review-fix.json"
printf '{"schema_version":8,"verdict":"APPROVE","issues":[]}\n' > "$REVIEW_SIDE/review-approve.json"
sed -i.sedbak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$REVIEW_SIDE/fake-claude-fix\"|; s/^MAX_IMPL_ROUNDS=.*/MAX_IMPL_ROUNDS=1/" "$REVIEW_SKILL/config.sh" && rm -f "$REVIEW_SKILL/config.sh.sedbak"
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
sed -i.sedbak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"true\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"true\"|; s/^TEST_CMD=.*/TEST_CMD=\"true\"/; s/^LINT_CMD=.*/LINT_CMD=\"true\"/" "$WIDX_SKILL/config.sh" && rm -f "$WIDX_SKILL/config.sh.sedbak"
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
sed -i.sedbak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"true\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$WIDX_SIDE/fake-codex\"|; s/^TEST_CMD=.*/TEST_CMD=\"true\"/; s/^LINT_CMD=.*/LINT_CMD=\"true\"/" "$WIDX_SKILL/config.sh" && rm -f "$WIDX_SKILL/config.sh.sedbak"
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
idx_a="$(cd "$WIDX_TARGET" && bash -c 'source .claude/skills/feature/config.sh; compute_index_fingerprint')"
(cd "$WIDX_TARGET" && git update-index --assume-unchanged src/w.txt)
idx_b="$(cd "$WIDX_TARGET" && bash -c 'source .claude/skills/feature/config.sh; compute_index_fingerprint')"
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
# 테스트 더블: 호출 횟수를 기록하고 flag 파일이 있을 때만 통과
printf '%s\n' '#!/usr/bin/env bash' 'echo t >> "$VFIX_COUNT"' '[ -f "$VFIX_PASS_FLAG" ]' > "$VFIX_SIDE/test.sh"; chmod +x "$VFIX_SIDE/test.sh"
# 가짜 codex(worker-fix): 기준선을 빈 tree 로 바꾸고 범위 밖 파일 수정, DONE
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'out=""; while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done' \
  'printf "VFIX_WORKER_MARKER\n"' \
  'printf "%s\n" 4b825dc642cb6eb9a060e54bf8d69288fbee4904 > .agent-work/worker-baseline.tree; echo tampered >> src/other.txt' \
  'printf '\''{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[]}'\'' > "$out"' \
  > "$VFIX_SIDE/fake-codex"
chmod +x "$VFIX_SIDE/fake-codex"
sed -i.sedbak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"true\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"true\"|; s|^TEST_CMD=.*|TEST_CMD=\"VFIX_COUNT=$VFIX_SIDE/test-calls VFIX_PASS_FLAG=$VFIX_SIDE/tests-pass bash $VFIX_SIDE/test.sh\"|; s/^LINT_CMD=.*/LINT_CMD=\"true\"/; s/^MAX_IMPL_ROUNDS=.*/MAX_IMPL_ROUNDS=0/" "$VFIX_SKILL/config.sh" && rm -f "$VFIX_SKILL/config.sh.sedbak"
fake_scope "$VFIX_TARGET" src/w.txt
fake_consensus_pass "$VFIX_TARGET" design
fake_consensus_pass "$VFIX_TARGET" impl
sed -i.sedbak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$REVIEW_SIDE/fake-claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$VFIX_SIDE/fake-codex\"|" "$VFIX_SKILL/config.sh" && rm -f "$VFIX_SKILL/config.sh.sedbak"
(cd "$VFIX_TARGET" && bash -c 'source .claude/skills/feature/config.sh; snapshot_worktree_tree' > .agent-work/worker-baseline.tree)
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
grep -q 'VFIX_WORKER_MARKER' "$VFIX_TARGET/.agent-work/live.log" && fail "verify 재진입: 기준선 미복구인데 codex 가 호출됨"
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

echo ""
echo "install.sh 스모크 테스트 전부 통과"
