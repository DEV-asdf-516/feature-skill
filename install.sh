#!/usr/bin/env bash
# =============================================================
# feature 파이프라인 설치/업데이트 스크립트
# 사용법: ./install.sh /path/to/target-project
#
# 원칙:
#  - 대상의 기존 settings.json / .codex/hooks.json 은 절대 수정하지 않는다.
#    누락된 hook 항목은 감지해서 "추가해야 할 내용"만 출력한다.
#  - config.sh 는 사용자 설정 전용이라 보존한다. 새 버전과 다르면 config.sh.new 를 참고용으로만 둔다(병합 불필요).
#    그 밖의 프로젝트별 편집 파일(core_rules.md)은 보존하고, 새 버전과 다르면 <파일>.new 로 옆에 두고 병합을 안내한다.
#  - 스킬 코드(scripts/ — 런타임 모듈 scripts/lib/ 포함, prompts/, schemas/, references/, SKILL.md, 훅 스크립트)는 갱신한다.
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

# ---------- 0. config.sh 소유권 분류 (활성 코드를 바꾸기 전에 중단 판단) ----------
# config.sh 는 사용자 설정 전용이다. 런타임 함수(scripts/lib/ 모듈이 정의하는 이름)의 정의나 런타임 소유 대입(계약·포맷 버전 상수, PROJECT_ROOT·FEATURE_SKILL_DIR)이 있으면 분리 이전 설치라
# 새 scripts/ 와 구 config.sh 본문이 섞인다(혼합 설치). 판정은 소스 저장소의 scripts/lib/config-layout.sh 로 한다 — 대상 런타임은 로드하지 않는다.
TARGET_SKILL_DIR="$TARGET_ROOT/.claude/skills/feature"
SOURCE_CONFIG="$SOURCE_ROOT/.claude/skills/feature/config.sh"
TARGET_CONFIG="$TARGET_SKILL_DIR/config.sh"
SOURCE_CONFIG_LAYOUT="$SOURCE_ROOT/.claude/skills/feature/scripts/lib/config-layout.sh"
[ -f "$SOURCE_CONFIG_LAYOUT" ] \
  || { echo "[FAIL] 소스 불완전: $SOURCE_CONFIG_LAYOUT 없음 — 소스 저장소를 온전히 받은 뒤 다시 실행하세요. (활성 코드는 변경하지 않았음)" >&2; exit 1; }
source "$SOURCE_CONFIG_LAYOUT"
if [ -f "$TARGET_CONFIG" ]; then
  layout_rc=0; layout_lines="$(feature_config_runtime_lines "$TARGET_CONFIG")" || layout_rc=$?
  case "$layout_rc" in
    0) ;;
    1)
      # 이관 템플릿: 소스 config.sh 그대로이되, 기존 설정에 backend 줄이 없으면 그 의미(legacy)가 바뀌지 않게 소스 템플릿의 그 줄만 legacy 값으로 적는다.
      # 사용자 파일의 줄은 해석·복사하지 않는다.
      migration_sed=""
      missing_claude_backend=0
      missing_codex_backend=0
      if ! grep -q '^CLAUDE_BACKEND=' "$TARGET_CONFIG"; then
        missing_claude_backend=1
        migration_sed="${migration_sed}s|^CLAUDE_BACKEND=\"native\"\$|CLAUDE_BACKEND=\"legacy_cli\"   # 이관: 기존 config.sh 에 이 줄이 없었다 — 종전 의미 legacy_cli 유지. native 전환은 진행 중인 피처가 없을 때 직접 한다|"$'\n'
      fi
      if ! grep -q '^CODEX_BACKEND=' "$TARGET_CONFIG"; then
        missing_codex_backend=1
        migration_sed="${migration_sed}s|^CODEX_BACKEND=\"app_server\"\$|CODEX_BACKEND=\"legacy_exec\"   # 이관: 기존 config.sh 에 이 줄이 없었다 — 종전 의미 legacy_exec 유지. app_server 전환은 진행 중인 피처가 없을 때 직접 한다|"$'\n'
      fi
      sed "$migration_sed" "$SOURCE_CONFIG" > "$TARGET_CONFIG.new"
      if [ "$missing_claude_backend" -eq 1 ] && ! grep -q '^CLAUDE_BACKEND="legacy_cli"' "$TARGET_CONFIG.new"; then
        echo "[FAIL] 소스 config.sh 에 CLAUDE_BACKEND=\"native\" 줄이 없어 이관 템플릿을 만들 수 없음: $TARGET_CONFIG.new (활성 코드는 변경하지 않았음)" >&2; exit 1
      fi
      if [ "$missing_codex_backend" -eq 1 ] && ! grep -q '^CODEX_BACKEND="legacy_exec"' "$TARGET_CONFIG.new"; then
        echo "[FAIL] 소스 config.sh 에 CODEX_BACKEND=\"app_server\" 줄이 없어 이관 템플릿을 만들 수 없음: $TARGET_CONFIG.new (활성 코드는 변경하지 않았음)" >&2; exit 1
      fi
      {
        echo "[FAIL] 기존 $TARGET_CONFIG 에 런타임 소유 줄이 있다(분리 이전 설정 — 혼합 설치 방지). 활성 코드는 변경하지 않았음."
        echo "       위반 줄(줄번호:내용, 최대 20줄):"
        printf '%s\n' "$layout_lines" | sed -n '1,20p' | sed 's/^/         /'
        echo "       ① 진행 중인 피처를 먼저 마치거나 수리하세요: 미수용 native 요청(.agent-work/native-agent/pending.json)은 새 런타임이 NATIVE_STALE_REQUEST 로 거부합니다."
        echo "          완료 불명 Codex App Server turn 은 'bash $TARGET_SKILL_DIR/scripts/codex-app-server.sh status' 로 확인하세요. 실행 중인 러너가 있으면 설치하지 마세요."
        echo "       ② 백업: cp $TARGET_CONFIG $TARGET_CONFIG.pre-runtime-split"
        echo "       ③ 이관(둘 중 하나):"
        echo "          (i)  $TARGET_CONFIG.new 를 새 config.sh 로 삼고 기존 사용자 값(모델·effort·CLI·backend·명령·한도·경로·알림·환경 변수 표현식)을 그대로 옮긴다"
        echo "          (ii) 기존 config.sh 에서 위반 줄('# 헬퍼' 구분선 이하 전부, 검증자·리뷰어 계약 버전·체크포인트 포맷 버전 블록, PROJECT_ROOT·FEATURE_SKILL_DIR 두 줄)을 지운다"
        if [ "$missing_claude_backend" -eq 1 ]; then
          echo "       ④ 기존 config.sh 에 CLAUDE_BACKEND 줄이 없다 — 종전 의미는 legacy_cli('claude -p')다. $TARGET_CONFIG.new 에 CLAUDE_BACKEND=\"legacy_cli\" 로 적었다((ii) 로 이관하면 이 줄을 새로 넣지 않으면 된다)."
        fi
        if [ "$missing_codex_backend" -eq 1 ]; then
          echo "       ④ 기존 config.sh 에 CODEX_BACKEND 줄이 없다 — 종전 의미는 legacy_exec('codex exec')다. $TARGET_CONFIG.new 에 CODEX_BACKEND=\"legacy_exec\" 로 적었다((ii) 로 이관하면 이 줄을 새로 넣지 않으면 된다)."
        fi
        echo "       ⑤ 이관한 뒤 install.sh 를 다시 실행하세요(README '설치' 의 '구 설치 이관'). 판정을 통과할 때까지 활성 코드는 바뀌지 않습니다."
      } >&2
      exit 1
      ;;
    *) echo "[FAIL] 대상 config.sh 를 읽을 수 없음: $TARGET_CONFIG (활성 코드는 변경하지 않았음)" >&2; exit 1 ;;
  esac
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
# config.sh: 사용자 설정 전용(0단계 통과)이라 보존한다. 런타임은 위 scripts/(scripts/lib/)로 이미 갱신됐으므로 병합이 필요 없다 — manual_steps 로 세지 않는다.
if [ ! -f "$TARGET_CONFIG" ]; then
  cp "$SOURCE_CONFIG" "$TARGET_CONFIG"
  echo "[OK] 생성: $TARGET_CONFIG"
elif ! cmp -s "$SOURCE_CONFIG" "$TARGET_CONFIG"; then
  cp "$SOURCE_CONFIG" "$TARGET_CONFIG.new"
  echo "[INFO] 기존 설정 보존: $TARGET_CONFIG — 사용자 설정 전용 파일이라 병합할 필요가 없습니다(없는 선택 설정은 미설정으로 동작)."
  echo "       $TARGET_CONFIG.new 는 새 설정 항목의 설명·기본값 참고용입니다."
fi
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
# 정의 파일은 설치 때 config.sh 의 model·effort 로 미리 만든다(native 로 라우팅되는 역할 전부 — 관리 표식이 있는 파일만 갱신).
# Claude Code 는 세션을 시작할 때 .claude/agents/ 를 읽는다. 역할을 처음 부르는 순간에 만든 정의는 이미 떠 있는 세션이 등록하지 못해
# 'Agent type … not found' 로 돌아올 수 있고, 그 dispatch 는 실행 여부 불명(DISPATCHING)으로 남는다. 러너는 피처 실행 시작·요청 발행 직전에 같은 함수로
# 다시 대조하고, 메인 세션이 그 정의를 등록했다는 증거가 없으면 요청을 만들지 않고 NATIVE_AGENT_RESTART_REQUIRED 로 멈춘다.
# 같은 이름의 사용자 파일(관리 표식 없음)이 이미 있으면 덮어쓰지 않는다(러너도 멈춘다) — 여기서 미리 알린다.
for agent_template in "$TARGET_SKILL_DIR"/agents/feature-*.md; do
  agent_target="$TARGET_ROOT/.claude/agents/$(basename "$agent_template")"
  if [ -f "$agent_target" ] && ! grep -q 'managed-by: feature-skill native-agent' "$agent_target"; then
    echo "[WARN] $agent_target 는 이 스킬이 관리하는 파일이 아닙니다(관리 표식 없음). CLAUDE_BACKEND=native 로 쓰려면 다른 이름으로 옮기세요 — 러너는 덮어쓰지 않고 중단합니다."
    manual_steps=1
  fi
done
# backend 는 설치기가 config.sh 의 문자열로 판정하지 않는다. 항상 prepare-agents 를 부르고, 그 명령이 로더로 config.sh 를 읽은 실제 값(따옴표·export·
# 환경 변수 표현식을 평가한 결과)으로 역할마다 판정한다 — native 로 라우팅되는 역할이 없으면(legacy_cli 등) 아무것도 쓰지 않는다.
# TEST_CMD/LINT_CMD 의 CHANGE_ME 는 막지 않는다(이 명령은 프로젝트 명령을 실행하지 않는다).
# 대상 프로젝트 루트에서 실행하고, 이 설치기를 부른 쪽(다른 프로젝트의 Claude Code 세션 등)의 변수는 넘기지 않는다:
#   FEATURE_PROJECT_ROOT·FEATURE_ORIGIN_ROOT·FEATURE_NATIVE_AGENTS_DIR(프로젝트 루트·정의 위치 재지정), FEATURE_CONFIG_QUERY_ONLY_PID(설정 가드 예외 표식 — prepare-agents 가 스스로 적는다),
#   CLAUDE_PID·CLAUDE_PROJECT_DIR(다른 세션 — 그 세션 기준의 재시작 판정이 섞인다), BASH_ENV·ENV(비대화형 bash 의 시작 파일).
# 실패해도 설치는 계속한다 — 원인을 고친 뒤 Claude Code 세션을 시작하기 전에 같은 명령을 직접 실행하면 된다.
prepare_agents_cmd="cd $TARGET_ROOT && bash .claude/skills/feature/scripts/native-agent-bridge.sh prepare-agents"
prepare_agents_ok=1
prepare_agents_out="$(cd "$TARGET_ROOT" && env -u FEATURE_PROJECT_ROOT -u FEATURE_ORIGIN_ROOT -u FEATURE_NATIVE_AGENTS_DIR -u FEATURE_CONFIG_QUERY_ONLY_PID \
  -u CLAUDE_PID -u CLAUDE_PROJECT_DIR -u BASH_ENV -u ENV bash "$TARGET_SKILL_DIR/scripts/native-agent-bridge.sh" prepare-agents 2>&1)" || prepare_agents_ok=0
# prepare-agents 가 config.sh 를 읽은 뒤 적는 한 줄(빈 값 = 미설정 → legacy_cli). 이 줄이 없으면 config.sh 를 읽기 전에 실패한 것이다 — 값을 추측하지 않는다.
effective_claude_backend_line="$(printf '%s\n' "$prepare_agents_out" | sed -n 's/^\[native-agents\] effective CLAUDE_BACKEND=/=/p')"
prepare_agents_relay="$(printf '%s\n' "$prepare_agents_out" | grep -v -e '^\[native\] ' -e '^\[native-agents\] effective ' || true)"
if [ "$prepare_agents_ok" = 1 ]; then
  echo "[OK] native Agent 정의 대조(config.sh 를 로더로 읽은 값 기준): $TARGET_ROOT/.claude/agents/"
  printf '%s\n' "$prepare_agents_relay" | sed 's/^/     /'
else
  echo "[WARN] native Agent 정의를 대조하지 못했습니다(config.sh 읽기·역할별 backend 판정 포함) — 아래 원인을 고친 뒤, 이 프로젝트에서 Claude Code 세션을 시작하기 전에 실행하세요: $prepare_agents_cmd"
  printf '%s\n' "$prepare_agents_relay" | sed 's/^/       /'
  manual_steps=1
fi
if [ "$effective_claude_backend_line" = "=" ]; then
  echo "[INFO] $TARGET_SKILL_DIR/config.sh 를 읽은 결과 CLAUDE_BACKEND 가 설정되지 않았습니다 — 종전대로 claude 모델을 'claude -p' 로 실행합니다(legacy_cli). native Agent 로 바꾸려면 config.sh.new 의 'Claude 모델의 실행 backend' 블록을 옮겨 적으세요(진행 중인 피처가 없을 때)."
fi
# Codex 모델의 실행 backend: 보존된 기존 config.sh 에 CODEX_BACKEND 줄이 없으면 종전의 codex exec(legacy_exec)로 그대로 동작한다 — 설치가 backend 를 바꾸지 않는다.
# 전환은 사용자가 그 줄을 직접 옮겨 적는 명시적 절차다(진행 중인 피처의 세션은 backend 를 바꿔도 옮겨 가지 않고 SESSION_BACKEND_MISMATCH 로 멈춘다).
if ! grep -q '^CODEX_BACKEND=' "$TARGET_SKILL_DIR/config.sh"; then
  echo "[INFO] $TARGET_SKILL_DIR/config.sh 에 CODEX_BACKEND 줄이 없습니다 — 종전대로 codex 모델을 'codex exec' 로 실행합니다(legacy_exec, 설정 변경 없음)."
  echo "       Codex App Server backend 로 바꾸려면: ① 진행 중인 피처를 먼저 마치고 ② config.sh.new 의 'Codex 모델의 실행 backend' 블록(CODEX_BACKEND / CODEX_APP_SERVER_*)을"
  echo "       사용자 설정 영역에 옮겨 적은 뒤 ③ 'bash $TARGET_SKILL_DIR/scripts/codex-app-server.sh preflight' 로 설치된 codex·Node.js(18+)의 호환성을 확인하세요(모델 호출 0회)."
elif grep -q '^CODEX_BACKEND="\{0,1\}app_server' "$TARGET_SKILL_DIR/config.sh"; then
  command -v node >/dev/null 2>&1 \
    || echo "[WARN] CODEX_BACKEND=app_server 인데 PATH 에 node 가 없습니다 — Codex 역할 호출이 실행 전에 멈춥니다(codex exec 로 대체하지 않음). Node.js 18+ 를 설치하거나 config.sh 의 CODEX_APP_SERVER_NODE_BIN 을 지정하세요."
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
