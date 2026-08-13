#!/usr/bin/env bash
# =============================================================
# feature 파이프라인 설치/업데이트 스크립트
# 사용법: ./install.sh /path/to/target-project
#
# 원칙:
#  - 대상의 기존 settings.json / .codex/hooks.json 은 절대 수정하지 않는다.
#    누락된 hook 항목은 감지해서 "추가해야 할 내용"만 출력한다.
#  - 프로젝트별 편집 파일(config.sh, core_rules.md)은 보존한다.
#    새 버전과 다르면 <파일>.new 로 옆에 두고 병합을 안내한다.
#  - 스킬 코드(scripts/, prompts/, schemas/, SKILL.md, 훅 스크립트)는 갱신한다.
# =============================================================
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_ROOT="${1:-}"

[ -n "$TARGET_ROOT" ] || { echo "사용법: ./install.sh /path/to/target-project" >&2; exit 1; }
[ -d "$TARGET_ROOT" ] || { echo "[FAIL] 대상 디렉터리 없음: $TARGET_ROOT" >&2; exit 1; }
TARGET_ROOT="$(cd "$TARGET_ROOT" && pwd)"
git -C "$TARGET_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 \
  || { echo "[FAIL] 대상이 git 저장소가 아님: $TARGET_ROOT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[FAIL] jq 미설치 (hook 항목 검사에 필요)." >&2; exit 1; }
[ "$SOURCE_ROOT" != "$TARGET_ROOT" ] || { echo "[FAIL] 소스 저장소 자신에게는 설치할 수 없음." >&2; exit 1; }

manual_steps=0

# 사용자 편집 파일 설치: 없으면 복사, 있는데 내용이 다르면 .new 로 두고 병합 안내
install_user_editable() {
  local source_file="$1" target_file="$2"
  if [ ! -f "$target_file" ]; then
    cp "$source_file" "$target_file"
    echo "[OK] 생성: $target_file"
  elif ! cmp -s "$source_file" "$target_file"; then
    cp "$source_file" "$target_file.new"
    echo "[WARN] 기존 파일 보존: $target_file"
    echo "       새 버전을 $target_file.new 로 복사함. diff 확인 후 직접 병합하세요."
    manual_steps=1
  fi
}

# ---------- 0. 호환성 사전 검사 (활성 코드를 바꾸기 전에 중단 판단) ----------
# 기존 config.sh 는 보존되므로, 새 스크립트가 요구하는 헬퍼 함수가 거기 없으면
# 스크립트만 교체된 시점에 설치가 깨진다. 교체 전에 검사하고 없으면 중단한다.
TARGET_SKILL_DIR="$TARGET_ROOT/.claude/skills/feature"
SOURCE_CONFIG="$SOURCE_ROOT/.claude/skills/feature/config.sh"
TARGET_CONFIG="$TARGET_SKILL_DIR/config.sh"
if [ -f "$TARGET_CONFIG" ] && ! cmp -s "$SOURCE_CONFIG" "$TARGET_CONFIG"; then
  missing_helpers=""
  for helper_name in $(grep -oE '^[a-z_][a-z_0-9]*\(\)' "$SOURCE_CONFIG" | tr -d '()'); do
    grep -qE "^${helper_name}\(\)" "$TARGET_CONFIG" || missing_helpers="$missing_helpers $helper_name"
  done
  if [ -n "$missing_helpers" ]; then
    cp "$SOURCE_CONFIG" "$TARGET_CONFIG.new"
    echo "[FAIL] 기존 $TARGET_CONFIG 에 새 스크립트가 요구하는 헬퍼가 없음:$missing_helpers" >&2
    echo "       $TARGET_CONFIG.new 를 참고해 먼저 병합한 뒤 다시 실행하세요. (활성 코드는 변경하지 않았음)" >&2
    exit 1
  fi
fi

# ---------- 1. 스킬 본체 (config.sh 는 사용자 편집 파일로 별도 처리) ----------
# 스테이징 후 교체 — 복사 실패(소스 누락·디스크 부족)가 기존 설치를 파괴하지 않게 한다
mkdir -p "$TARGET_SKILL_DIR"
trap 'rm -rf "$TARGET_SKILL_DIR"/.install-stage-* 2>/dev/null' EXIT
# 1단계: 네 항목 전부 스테이징 성공 후에만 2단계 교체 시작 (혼합 버전 방지)
for skill_entry in SKILL.md prompts schemas scripts; do
  stage_path="$TARGET_SKILL_DIR/.install-stage-$skill_entry"
  rm -rf "$stage_path"
  cp -R "$SOURCE_ROOT/.claude/skills/feature/$skill_entry" "$stage_path"
done
for skill_entry in SKILL.md prompts schemas scripts; do
  rm -rf "$TARGET_SKILL_DIR/${skill_entry:?}"
  mv "$TARGET_SKILL_DIR/.install-stage-$skill_entry" "$TARGET_SKILL_DIR/$skill_entry"
done
chmod +x "$TARGET_SKILL_DIR/scripts/"*.sh
echo "[OK] 스킬 코드 갱신: $TARGET_SKILL_DIR (SKILL.md, prompts/, schemas/, scripts/)"
install_user_editable "$SOURCE_ROOT/.claude/skills/feature/config.sh" "$TARGET_SKILL_DIR/config.sh"

# ---------- 2. Claude 훅 스크립트 + core_rules.md ----------
# 훅 스크립트도 프로젝트별로 커스터마이즈될 수 있어 기존 파일은 보존한다.
# 대상에 이 파이프라인 외의 훅이 있어도 일절 건드리지 않는다 (지정 파일만 다룸).
TARGET_CLAUDE_HOOKS="$TARGET_ROOT/.claude/hooks"
mkdir -p "$TARGET_CLAUDE_HOOKS"
for hook_script in inject_conventions.sh pre_bash_guard.sh; do
  install_user_editable "$SOURCE_ROOT/.claude/hooks/$hook_script" "$TARGET_CLAUDE_HOOKS/$hook_script"
done
install_user_editable "$SOURCE_ROOT/.claude/hooks/core_rules.md" "$TARGET_CLAUDE_HOOKS/core_rules.md"

# ---------- 3. .claude/settings.json — 없으면 복사, 있으면 검사만 ----------
TARGET_SETTINGS="$TARGET_ROOT/.claude/settings.json"
if [ ! -f "$TARGET_SETTINGS" ]; then
  cp "$SOURCE_ROOT/.claude/settings.json" "$TARGET_SETTINGS"
  echo "[OK] 생성: $TARGET_SETTINGS"
else
  if jq -e '[.hooks.UserPromptSubmit[]?.hooks[]? | select(.type == "command" and (.command | endswith("/.claude/hooks/inject_core_rules.sh")))] | length > 0' \
      "$TARGET_SETTINGS" >/dev/null; then
    echo "[WARN] $TARGET_SETTINGS 에 레거시 inject_core_rules.sh가 등록돼 있습니다."
    echo "       해당 항목을 inject_conventions.sh로 교체해야 core_rules.md가 워커에게만 주입됩니다."
    manual_steps=1
  fi
  # 이벤트 + 실제 command 문자열이 소스와 정확히 일치해야 등록으로 인정
  # (contains 검사는 "echo disabled ...guard.sh" 같은 비활성 문자열도 통과시킨다)
  for hook_entry in "UserPromptSubmit:inject_conventions.sh" "PreToolUse:pre_bash_guard.sh"; do
    hook_event="${hook_entry%%:*}"; hook_script="${hook_entry#*:}"
    expected_command="$(jq -r --arg event "$hook_event" \
      '.hooks[$event][].hooks[] | select(.type == "command") | .command' "$SOURCE_ROOT/.claude/settings.json")"
    if ! jq -e --arg event "$hook_event" --arg cmd "$expected_command" \
        '[.hooks[$event][]?.hooks[]? | select(.type == "command" and .command == $cmd)] | length > 0' \
        "$TARGET_SETTINGS" >/dev/null; then
      echo "[WARN] $TARGET_SETTINGS 의 $hook_event 에 $hook_script 미등록. 아래를 hooks 에 직접 추가하세요:"
      jq --arg event "$hook_event" '{hooks: {($event): .hooks[$event]}}' "$SOURCE_ROOT/.claude/settings.json"
      manual_steps=1
    fi
  done
fi

# ---------- 4. Codex 훅 ----------
TARGET_CODEX_DIR="$TARGET_ROOT/.codex"
mkdir -p "$TARGET_CODEX_DIR/hooks"
install_user_editable "$SOURCE_ROOT/.codex/hooks/worker_guard.sh" "$TARGET_CODEX_DIR/hooks/worker_guard.sh"
if [ ! -f "$TARGET_CODEX_DIR/hooks.json" ]; then
  cp "$SOURCE_ROOT/.codex/hooks.json" "$TARGET_CODEX_DIR/hooks.json"
  echo "[OK] 생성: $TARGET_CODEX_DIR/hooks.json"
elif expected_codex_command="$(jq -r '.hooks.PreToolUse[].hooks[] | select(.type == "command") | .command' "$SOURCE_ROOT/.codex/hooks.json")" \
  && ! jq -e --arg cmd "$expected_codex_command" \
    '[.hooks.PreToolUse[]?.hooks[]? | select(.type == "command" and .command == $cmd)] | length > 0' \
    "$TARGET_CODEX_DIR/hooks.json" >/dev/null; then
  echo "[WARN] $TARGET_CODEX_DIR/hooks.json 에 worker_guard.sh 항목 없음. 아래를 직접 추가하세요:"
  cat "$SOURCE_ROOT/.codex/hooks.json"
  manual_steps=1
fi

# ---------- 5. feature-live + .gitignore ----------
cp "$SOURCE_ROOT/feature-live" "$TARGET_ROOT/feature-live"
chmod +x "$TARGET_ROOT/feature-live"
echo "[OK] 갱신: $TARGET_ROOT/feature-live"

if ! grep -qE '^\.agent-work(/|/\*)?$' "$TARGET_ROOT/.gitignore" 2>/dev/null; then
  printf '.agent-work/\n' >> "$TARGET_ROOT/.gitignore"
  echo "[OK] .gitignore 에 .agent-work/ 추가"
fi

# ---------- 마무리 안내 ----------
echo ""
if grep -q 'CHANGE_ME' "$TARGET_SKILL_DIR/config.sh"; then
  echo "[다음 단계] $TARGET_SKILL_DIR/config.sh 의 CHANGE_ME(TEST_CMD/LINT_CMD)를 채우세요."
  echo "            안 채우면 config.sh 가드가 모든 스크립트 실행을 거부합니다."
fi
if [ "$manual_steps" -eq 1 ]; then
  echo "[완료 — 수동 병합 필요] 위 [WARN] 항목을 처리해야 파이프라인이 온전히 동작합니다."
else
  echo "[완료] 설치/업데이트 끝."
fi
