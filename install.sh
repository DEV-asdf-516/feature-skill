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
#  - 스킬 코드(scripts/, prompts/, schemas/, references/, SKILL.md, 훅 스크립트)는 갱신한다.
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
  # 헬퍼 '이름'이 전부 있어도 본문이 옛 버전이면 새 scripts/·schemas/·prompts/ 와 옛 config.sh 본문이 섞인다(혼합 버전).
  # config.sh 의 버전 상수(런타임 계약 표식 FEATURE_RUNTIME_CONTRACT_VERSION, 검증자·리뷰어 계약 버전, 체크포인트 포맷 버전 …)는 사용자 설정이 아니라
  # 코드와 한 몸인 값이다 — 소스와 하나라도 다르면(대상에 없음 포함) 활성 코드를 바꾸기 전에 중단한다. 모델·effort·TEST_CMD 같은 사용자 설정은 비교하지 않는다.
  version_mismatch=""
  while IFS='=' read -r version_name version_value; do
    [ -n "$version_name" ] || continue
    target_value="$(sed -n "s/^${version_name}=\([0-9][0-9]*\).*/\1/p" "$TARGET_CONFIG" | tail -1)"
    [ "$target_value" = "$version_value" ] || version_mismatch="$version_mismatch $version_name(대상 ${target_value:-없음} / 새 버전 $version_value)"
  done < <(sed -n 's/^\([A-Z][A-Z_]*_VERSION\)=\([0-9][0-9]*\).*/\1=\2/p' "$SOURCE_CONFIG")
  if [ -n "$version_mismatch" ]; then
    cp "$SOURCE_CONFIG" "$TARGET_CONFIG.new"
    echo "[FAIL] 기존 $TARGET_CONFIG 의 본문이 새 스킬 코드와 다른 버전임(혼합 설치 방지):$version_mismatch" >&2
    echo "       $TARGET_CONFIG.new 의 버전 상수와 '헬퍼' 구분선 아래 본문으로 교체하고, 그 위의 사용자 설정(모델·effort·CLI·TEST_CMD/LINT_CMD 등)은 기존 값을 유지해 병합한 뒤 다시 실행하세요." >&2
    echo "       (활성 코드는 변경하지 않았음. 진행 중인 피처가 있으면 그 세션이 끝난 뒤에 병합·설치하세요 — 계약 버전이 바뀌면 진행 중인 합의·리뷰·워커 세션의 전제가 달라집니다)" >&2
    exit 1
  fi
fi

# ---------- 1. 스킬 본체 (config.sh 는 사용자 편집 파일로 별도 처리) ----------
# 스테이징 후 교체 — 복사 실패(소스 누락·디스크 부족)가 기존 설치를 파괴하지 않게 한다
mkdir -p "$TARGET_SKILL_DIR"
trap 'rm -rf "$TARGET_SKILL_DIR"/.install-stage-* 2>/dev/null' EXIT
# 1단계: 다섯 항목 전부 스테이징 성공 후에만 2단계 교체 시작 (혼합 버전 방지)
# references/ 는 SKILL.md 가 분기 직전에 읽으라고 가리키는 상세 지침이다 — SKILL.md 만 새 버전이고 references/ 가 없거나 일부만 있으면
# 오케스트레이터가 요약만으로 진행하게 되므로 같은 스테이징 단위로 묶는다(구버전 설치의 업데이트에서는 references/ 가 새로 생긴다).
# agents/ 는 native Agent 정의 템플릿이다(scripts/native-agent-bridge.sh 가 config.sh 의 모델·effort 로 렌더링해 .claude/agents/ 에 쓴다) — 브리지와 같은 스테이징 단위다.
SKILL_ENTRIES="SKILL.md prompts schemas scripts references agents"
for skill_entry in $SKILL_ENTRIES; do
  stage_path="$TARGET_SKILL_DIR/.install-stage-$skill_entry"
  rm -rf "$stage_path"
  [ -e "$SOURCE_ROOT/.claude/skills/feature/$skill_entry" ] \
    || { echo "[FAIL] 소스에 스킬 항목 없음: .claude/skills/feature/$skill_entry — 설치하지 않음(활성 코드는 변경하지 않았음)" >&2; exit 1; }
  cp -R "$SOURCE_ROOT/.claude/skills/feature/$skill_entry" "$stage_path"
done
# 교체 전 완전성 검사: 스테이징된 SKILL.md 가 언급하는 references/<이름>.md 가 스테이징된 references/ 에 전부(비어 있지 않게) 있어야 한다.
# 하나라도 없으면 상세 지침이 누락된 설치이므로 교체하지 않고 실패한다 — 성공 메시지를 내지 않는다.
missing_references=""
for reference_name in $(grep -oE 'references/[A-Za-z0-9._-]+\.md' "$TARGET_SKILL_DIR/.install-stage-SKILL.md" | sort -u); do
  [ -s "$TARGET_SKILL_DIR/.install-stage-references/${reference_name#references/}" ] || missing_references="$missing_references $reference_name"
done
if [ -n "$missing_references" ]; then
  echo "[FAIL] SKILL.md 가 참조하는 상세 지침 문서가 소스에 없음:$missing_references" >&2
  echo "       참조 문서 없이 SKILL.md 만 설치하면 오케스트레이터가 요약만으로 진행한다. 소스 저장소를 온전히 받은 뒤 다시 실행하세요. (활성 코드는 변경하지 않았음)" >&2
  exit 1
fi
[ -n "$(grep -oE 'references/[A-Za-z0-9._-]+\.md' "$TARGET_SKILL_DIR/.install-stage-SKILL.md")" ] \
  || { echo "[FAIL] 소스 SKILL.md 가 references/ 문서를 하나도 가리키지 않음 — 진입 문서와 참조 문서의 버전이 맞지 않는다. (활성 코드는 변경하지 않았음)" >&2; exit 1; }
for skill_entry in $SKILL_ENTRIES; do
  rm -rf "$TARGET_SKILL_DIR/${skill_entry:?}"
  mv "$TARGET_SKILL_DIR/.install-stage-$skill_entry" "$TARGET_SKILL_DIR/$skill_entry"
done
chmod +x "$TARGET_SKILL_DIR/scripts/"*.sh
echo "[OK] 스킬 코드 갱신: $TARGET_SKILL_DIR (SKILL.md, prompts/, schemas/, scripts/, references/, agents/)"
install_user_editable "$SOURCE_ROOT/.claude/skills/feature/config.sh" "$TARGET_SKILL_DIR/config.sh"
# 선택 설정 안내: 보존된 기존 config.sh 에 프로젝트 빠른 검사 설정 줄이 없으면(이 기능 이전의 설치) 미설정으로 그대로 동작한다.
# 헬퍼는 scripts/fast-check.sh 에 있어 config.sh 본문 병합이 필요 없다(런타임 계약 표식 불변) — 필수 작업이 아니므로 manual_steps 로 세지 않는다.
if ! grep -q '^FAST_CHECK_CMD=' "$TARGET_SKILL_DIR/config.sh"; then
  echo "[INFO] 선택 기능 '프로젝트 빠른 검사' 미설정: $TARGET_SKILL_DIR/config.sh 에 FAST_CHECK_CMD 줄이 없습니다 — 지금 그대로 동작합니다(리뷰 전 검사 생략, 기존 설정 변경 없음)."
  echo "       쓰려면 config.sh.new 의 '프로젝트 빠른 검사 (선택)' 블록(FAST_CHECK_CMD / FAST_CHECK_TIMEOUT_SEC)을 사용자 설정 영역에 옮겨 적으세요. 진행 중인 피처가 없을 때 켭니다. (README '프로젝트 빠른 검사')"
fi
# 같은 방식의 선택 설정 둘(Unit 정적 검사·위험도별 추가 검증): 헬퍼는 scripts/fast-check.sh 에 있어 줄이 없어도 미설정으로 그대로 동작한다(런타임 계약 표식 불변, 필수 작업 아님).
if ! grep -q '^UNIT_CHECK_CMD=' "$TARGET_SKILL_DIR/config.sh" || ! grep -q '^RISK_VERIFY_CMD=' "$TARGET_SKILL_DIR/config.sh"; then
  echo "[INFO] 선택 기능 'Unit 정적 검사'·'위험도별 추가 검증' 미설정: $TARGET_SKILL_DIR/config.sh 에 UNIT_CHECK_CMD / RISK_VERIFY_CMD 줄이 없습니다 — 지금 그대로 동작합니다(검사 생략, 기존 설정 변경 없음)."
  echo "       쓰려면 config.sh.new 의 'Unit 정적 검사 (선택)'·'위험도별 추가 검증 (선택)' 블록을 사용자 설정 영역에 옮겨 적으세요. (README '검증 게이트')"
fi

# ---------- 2. Claude 훅 스크립트 + core_rules.md ----------
# 훅 스크립트도 프로젝트별로 커스터마이즈될 수 있어 기존 파일은 보존한다.
# 대상에 이 파이프라인 외의 훅이 있어도 일절 건드리지 않는다 (지정 파일만 다룸).
TARGET_CLAUDE_HOOKS="$TARGET_ROOT/.claude/hooks"
mkdir -p "$TARGET_CLAUDE_HOOKS"
# compact_recovery.sh: SessionStart(compact) — 컨텍스트 압축 직후 스킬 참조 문서·conventions 재확인 지침(inject_conventions.sh 의 세션당 1회 정책 보완)
# feature_native_agent.sh: native Agent 인계의 dispatch 검증·프롬프트 주입(PreToolUse)·원문 결과 캡처(SubagentStop). CLAUDE_BACKEND=native 일 때 필수다.
for hook_script in inject_conventions.sh pre_bash_guard.sh compact_recovery.sh feature_native_agent.sh; do
  install_user_editable "$SOURCE_ROOT/.claude/hooks/$hook_script" "$TARGET_CLAUDE_HOOKS/$hook_script"
done
# 마이그레이션: 옛 inject_conventions.sh 는 매 UserPromptSubmit 마다 conventions.md 전체를 주입하고 파이프라인 child Claude 에도
# 중복 주입했다. 보존된 훅에 세션당 1회·child 제외 로직(FEATURE_ROLE_CHILD)이 없으면 .new 로 교체를 안내한다.
if ! grep -q 'FEATURE_ROLE_CHILD' "$TARGET_CLAUDE_HOOKS/inject_conventions.sh"; then
  echo "[WARN] $TARGET_CLAUDE_HOOKS/inject_conventions.sh 가 구버전(매 턴 주입)입니다."
  echo "       매 턴·child Claude 중복 주입으로 cache read 가 커집니다. $TARGET_CLAUDE_HOOKS/inject_conventions.sh.new 로 교체하세요"
  echo "       (커스터마이즈가 없다면 그대로 덮어써도 됩니다: 세션당 1회 주입 + FEATURE_ROLE_CHILD=1 이면 미주입)."
  manual_steps=1
fi
chmod +x "$TARGET_CLAUDE_HOOKS/compact_recovery.sh" "$TARGET_CLAUDE_HOOKS/feature_native_agent.sh"
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
  # SessionStart:compact_recovery.sh — 미등록이면 압축 뒤 복구 지침이 주입되지 않는다. 조용히 정상으로 보고하지 않고 추가할 항목을 출력한다.
  # feature_native_agent.sh 세 이벤트 — 하나라도 빠지면 native 요청이 dispatch 되지 않거나(PreToolUse) 실행이 확인되지 않거나(PostToolUse — DISPATCHING 에 머문다) 결과가 캡처되지 않는다(SubagentStop). 러너는 그 경우 CLI 로 대체하지 않고 대기·중단한다.
  for hook_entry in "UserPromptSubmit:inject_conventions.sh" "PreToolUse:pre_bash_guard.sh" "SessionStart:compact_recovery.sh" \
      "PreToolUse:feature_native_agent.sh" "PostToolUse:feature_native_agent.sh" "SubagentStop:feature_native_agent.sh"; do
    hook_event="${hook_entry%%:*}"; hook_script="${hook_entry#*:}"
    # 같은 이벤트에 훅이 여러 개일 수 있으므로 스크립트 이름으로 해당 항목 하나만 고른다(여러 줄 비교로 항상 실패하던 버그 수정).
    expected_command="$(jq -r --arg event "$hook_event" --arg script "/$hook_script" \
      '[.hooks[$event][].hooks[] | select(.type == "command" and (.command | endswith($script))) | .command][0]' "$SOURCE_ROOT/.claude/settings.json")"
    # 소스가 matcher 를 지정한 훅은 대상의 matcher 도 그 값을 포함해야 한다("a|b" 대안 목록 허용, 소스에 matcher 가 없으면 검사하지 않는다). command 만 보면 compact_recovery.sh 가
    # "matcher": "startup" 으로 잘못 등록돼도 정상으로 판정된다 — 그 훅은 압축 뒤에 실행되지 않는다.
    expected_matcher="$(jq -r --arg event "$hook_event" --arg script "/$hook_script" \
      '[.hooks[$event][] | select(any(.hooks[]; .type == "command" and (.command | endswith($script)))) | (.matcher // "")][0]' "$SOURCE_ROOT/.claude/settings.json")"
    if ! jq -e --arg event "$hook_event" --arg cmd "$expected_command" --arg matcher "$expected_matcher" \
        '[.hooks[$event][]? | select($matcher == "" or ((.matcher // "") | split("|") | index($matcher) != null)) | .hooks[]? | select(.type == "command" and .command == $cmd)] | length > 0' \
        "$TARGET_SETTINGS" >/dev/null; then
      if jq -e --arg event "$hook_event" --arg cmd "$expected_command" \
          '[.hooks[$event][]?.hooks[]? | select(.type == "command" and .command == $cmd)] | length > 0' "$TARGET_SETTINGS" >/dev/null; then
        echo "[WARN] $TARGET_SETTINGS 의 $hook_event 에 $hook_script 가 있지만 matcher 가 \"$expected_matcher\" 가 아닙니다. 아래와 같은 matcher 로 고치세요:"
      else
        echo "[WARN] $TARGET_SETTINGS 의 $hook_event 에 $hook_script 미등록. 아래를 hooks 에 직접 추가하세요:"
      fi
      jq --arg event "$hook_event" --arg script "/$hook_script" \
        '{hooks: {($event): [.hooks[$event][] | select(any(.hooks[]; .type == "command" and (.command | endswith($script))))]}}' "$SOURCE_ROOT/.claude/settings.json"
      manual_steps=1
    fi
  done
fi

# ---------- 3.5 native Agent 정의 (.claude/agents/feature-<역할>.md) ----------
# 정의 파일은 설치 때 만들지 않는다 — model·effort 가 config.sh 값이어야 하므로 러너가 매 요청 직전에 렌더링·대조해 쓴다(관리 표식이 있는 파일만 갱신).
# 같은 이름의 사용자 파일(관리 표식 없음)이 이미 있으면 러너가 덮어쓰지 않고 멈추므로 여기서 미리 알린다.
for agent_template in "$TARGET_SKILL_DIR"/agents/feature-*.md; do
  agent_target="$TARGET_ROOT/.claude/agents/$(basename "$agent_template")"
  if [ -f "$agent_target" ] && ! grep -q 'managed-by: feature-skill native-agent' "$agent_target"; then
    echo "[WARN] $agent_target 는 이 스킬이 관리하는 파일이 아닙니다(관리 표식 없음). CLAUDE_BACKEND=native 로 쓰려면 다른 이름으로 옮기세요 — 러너는 덮어쓰지 않고 중단합니다."
    manual_steps=1
  fi
done
if ! grep -q '^CLAUDE_BACKEND=' "$TARGET_SKILL_DIR/config.sh"; then
  echo "[INFO] $TARGET_SKILL_DIR/config.sh 에 CLAUDE_BACKEND 줄이 없습니다 — 종전대로 claude 모델을 'claude -p' 로 실행합니다(legacy_cli). native Agent 로 바꾸려면 config.sh.new 의 'Claude 모델의 실행 backend' 블록을 옮겨 적으세요(진행 중인 피처가 없을 때)."
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
  if [ -s "$TARGET_ROOT/.gitignore" ] && [ "$(tail -c 1 "$TARGET_ROOT/.gitignore" | wc -l | tr -d ' ')" -eq 0 ]; then
    printf '\n' >> "$TARGET_ROOT/.gitignore"
  fi
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
