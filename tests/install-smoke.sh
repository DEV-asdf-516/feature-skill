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

TARGET="$SCRATCH/target"
TARGET_SKILL="$TARGET/.claude/skills/feature"
git init -q "$TARGET"

# ---------- 1. 신규 설치 ----------
bash "$SOURCE_ROOT/install.sh" "$TARGET" >/dev/null
[ -x "$TARGET_SKILL/scripts/consensus-loop.sh" ] || fail "신규 설치: 스크립트 누락/실행권한 없음"
[ -x "$TARGET/feature-live" ] || fail "신규 설치: feature-live 누락"
[ -f "$TARGET/.claude/hooks/core_rules.md" ] || fail "신규 설치: core_rules.md 누락"
jq -e '.hooks.UserPromptSubmit and .hooks.PreToolUse' "$TARGET/.claude/settings.json" >/dev/null \
  || fail "신규 설치: settings.json hooks 누락"
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

# ---------- 6. .gitignore 중복 방지 ----------
duplicate_count="$(grep -c '^\.agent-work/$' "$TARGET/.gitignore")"
[ "$duplicate_count" = "1" ] || fail ".gitignore: .agent-work/ 항목 ${duplicate_count}개 (1개여야 함)"
echo "[OK] 6. .gitignore 중복 방지"

echo ""
echo "install.sh 스모크 테스트 전부 통과"
