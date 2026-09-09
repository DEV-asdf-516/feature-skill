#!/usr/bin/env bash
# =============================================================
# feature 파이프라인 설정
# 파일 경로: .claude/skills/feature/config.sh
# 사용 전 반드시 모델 ID를 실제 환경에 맞게 채워 넣으세요.
#  - Claude 계열: claude 대화 세션에서 /model 로 확인
#  - Codex 계열: codex --help 또는 codex -m 후보 목록으로 확인
# =============================================================

# --- 역할별 모델 + reasoning effort ---
# 모델별 지원 effort가 다르므로 역할마다 함께 설정한다. 실제 허용 여부는 각 CLI가 검증한다.
# 어느 CLI 로 돌릴지는 모델 ID 로 정한다(claude* → claude, gpt-*/o*/codex* → codex). 아래 "역할 → CLI 라우팅" 참고.
DESIGNER_MODEL="claude-fable-5-1"   # 오케스트레이터 겸 문서 소유자
DESIGNER_EFFORT="low"
VALIDATOR_MODEL="gpt-5.6-sol"     # 명세 검증자
VALIDATOR_EFFORT="medium" # 게이트 모드(구현을 막을 최소 사유만 판정). 전체 보안·아키텍처 감사는 별도 수동 audit 에서만 high
VALIDATOR_PROFILE=""      # 판정 전략 오버레이(prompts/validator-overlays/<이름>.md). 빈 값 = 모델별 기본값(validator_profile 헬퍼). compact | guided | conservative | none
WORKER_MODEL="gpt-5.6-luna"       # 구현 담당
WORKER_EFFORT="max"
REVIEWER_MODEL="claude-sonnet-5"  # 구현 리뷰 담당
REVIEWER_EFFORT="medium"
FIXER_MODEL="claude-sonnet-5"     # 리뷰 이슈 수정 담당
FIXER_EFFORT="medium"

# --- CLI 실행 형식 ---
# Claude Code 비대화형 실행. 필요 시 --permission-mode 조정.
CLAUDE_BIN="claude"
CODEX_BIN="codex"

# --- 역할 → CLI 라우팅 ---
# 역할(디자이너/검증자/워커/리뷰어/수정자)은 고정이지만 어느 CLI 로 돌릴지는 모델 ID 로 정한다:
#   claude*                  → claude CLI (CLAUDE_BIN)
#   gpt-* | o[0-9]* | codex* → codex CLI (CODEX_BIN)
# 이름으로 정할 수 없는 모델은 아래에 claude|codex 를 직접 적는다(빈 값 = 모델 이름으로 자동 판정).
DESIGNER_CLI=""
VALIDATOR_CLI=""
WORKER_CLI=""
REVIEWER_CLI=""
FIXER_CLI=""

# --- 검증자 계약 버전 ---
# 검증자 프롬프트(공통 계약 prompts/validator-review-*.md 와 오버레이 prompts/validator-overlays/*.md 모두)·spec-review 스키마·러너의 연계 검사 중 하나라도 바뀌면 올린다.
# 러너는 이 값과 다른 이전 PASS 파일을 무효로 보고 검증 라운드를 다시 돈다(--new 불필요).
VALIDATOR_CONTRACT_VERSION=9

# --- 리뷰어 계약 버전 ---
# 리뷰어 프롬프트·impl-review 스키마·impl-review-loop 의 연계 검사 중 하나라도 바뀌면 올린다.
# 루프는 리뷰 JSON 의 schema_version 이 이 값과 다르면 응답 오류로 중단한다.
REVIEWER_CONTRACT_VERSION=7

# --- 체크포인트 포맷 버전 ---
# consensus-<target>.json / review-impl.json 의 필드·지문 '의미'가 바뀌면 올린다(계약 버전과 별개).
# 로더는 버전이 다르면 저장된 지문을 해석하지 않고 안전하게 처음(Round 1 / 새 attempt)으로 돌아간다 —
# 다른 의미의 지문을 비교해 "부분 실행"으로 오판하고 단계를 건너뛰는 것을 막는다.
CONSENSUS_CHECKPOINT_VERSION=2
REVIEW_CHECKPOINT_VERSION=2

# --- 수렴/안전 한도 ---
MAX_SPEC_ROUNDS=1        # 명세 합의 최대 라운드
MAX_IMPL_ROUNDS=1        # 구현 리뷰-수정 라운드 (리뷰는 +1회 — 마지막 수정도 종결 검토). 1 = Reviewer 2 + Fixer 1, 첫 수정으로 안 풀리면 사용자에게
MAX_TEST_RETRIES=1       # 최종 테스트 실패 시 워커 재수정 허용 횟수

# --- 산출물 디렉터리 (저장소 루트 기준 상대 경로) ---
WORK_DIR=".agent-work"

# --- 프로젝트 명령 (저장소 루트에서 실행 기준, 프로젝트에 맞게 교체) ---
# 예: Gradle "./gradlew test" / pytest "venv/bin/pytest tests -q" / npm "npm test"
TEST_CMD="CHANGE_ME"
LINT_CMD="CHANGE_ME"
# 복잡도·중복·dead code 같은 정적 분석은 LINT_CMD 안에 프로젝트 도구로 구성한다(eslint/sonar, radon, detekt, clippy, knip, jscpd…).
# 스킬은 언어 독립이므로 자체 코드 검사를 갖지 않는다. 커버리지 % 임계치도 두지 않는다 — 숫자 채우기용 테스트를 유발한다.

# --- 역할별 규칙 파일 ---
# 기본은 이 스킬이 설치된 프로젝트. 피처 전용 worktree 에서 돌 때는 러너가 FEATURE_PROJECT_ROOT 로 그 worktree 를 넘긴다 —
# 규칙 파일·conventions·프로젝트 로컬 워커 스킬을 원본이 아니라 snapshot 된 worktree 에서 읽어 실행 격리를 지킨다(하위 루프도 상속).
PROJECT_ROOT="${FEATURE_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
FEATURE_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_RULES_FILE="$PROJECT_ROOT/.claude/hooks/core_rules.md" # 워커 전용 필수 규칙
CONVENTIONS_FILE="$PROJECT_ROOT/conventions.md" # 선택 파일: 없으면 조용히 생략

# --- 워커에 주입하는 외부 스킬 ---
# 이름 목록. 탐색 순서: $PROJECT_ROOT/.claude/skills/<이름>/SKILL.md → .agents/skills/<이름>/SKILL.md (npx skills add 로 설치한 것)
# → 이 스킬 안의 worker-skills/<이름>/SKILL.md (vendored 사본 — install.sh 가 함께 복사하므로 설치 대상에서도 항상 있다).
# frontmatter 를 뗀 본문을 [WORKER SKILL: <이름>] 블록으로 core rules 뒤에 붙인다. 워커는 codex 라 Claude 스킬 로더가 없다.
# 목록에 있는데 어디에도 없으면 필수 동작 누락이므로 조용히 진행하지 않고 실패한다.
WORKER_SKILLS=("ponytail")
PONYTAIL_LEVEL="full"   # lite | full | ultra — ponytail 강도 (WORKER_SKILLS 에 ponytail 이 있을 때만)

# =============================================================
# 헬퍼
# =============================================================

# 페르소나 템플릿(prompts/*.md) 렌더링. 지정한 변수만 치환해 본문의 다른 $ 문자를 보존한다.
# 사용: VAR1=... VAR2=... render_prompt <템플릿 파일> '${VAR1} ${VAR2}'
render_prompt() {
  envsubst "$2" < "$1"
}

# 검증자 판정 전략 프로필. VALIDATOR_PROFILE 이 비어 있으면 VALIDATOR_MODEL 로 기본값을 고른다.
# 프로필은 모델 ID 가 아니라 전략 이름(compact/guided/conservative)이라, 모델이 바뀌어도 여기 매핑 한 줄만 고친다.
# 공통 계약(관할·탐색 범위·BLOCK/ASK_USER 입장 조건·스키마)은 validator-review-*.md 한 곳에만 있고 오버레이는 "그 계약을 어떤 순서로 판정할지"만 담는다.
validator_profile() {
  if [ -n "${VALIDATOR_PROFILE:-}" ]; then printf '%s' "$VALIDATOR_PROFILE"; return 0; fi
  case "${VALIDATOR_MODEL:-}" in
    gpt-5.6-sol)   printf 'compact' ;;
    gpt-5.6-astra) printf 'guided' ;;
    *)             printf 'conservative' ;;
  esac
}

# 오버레이 본문을 [VALIDATOR PROFILE: <이름>] 블록으로 출력한다. 검증자 task prompt 뒤에 붙인다(system prompt 가 아니다 — 정체성이 아니라 실행 힌트).
# 프로필 none 이면 아무것도 출력하지 않는다. 이름이 있는데 파일이 없으면 조용히 생략하지 않고 실패한다(오타로 전략이 빠진 채 유료 호출을 막는다).
load_validator_overlay() {
  local profile file
  profile="$(validator_profile)"
  [ "$profile" = none ] && return 0
  file="$FEATURE_SKILL_DIR/prompts/validator-overlays/$profile.md"
  [ -f "$file" ] || { echo "[FAIL] 검증자 프로필 '$profile' 의 오버레이 없음: $file — config.sh VALIDATOR_PROFILE 또는 validator_profile 매핑 확인" >&2; return 1; }
  printf '\n\n[VALIDATOR PROFILE: %s]\n' "$profile"
  cat "$file"
}

# 프로젝트 conventions는 모든 역할에 전달하되 없으면 아무것도 출력하지 않는다.
load_project_conventions() {
  [ -f "$CONVENTIONS_FILE" ] || return 0
  printf '[PROJECT CONVENTIONS]\n'
  cat "$CONVENTIONS_FILE"
}

# core_rules.md는 워커에게만 전달한다. 선택 conventions가 있으면 뒤에 덧붙인다.
load_worker_rules() {
  printf '[CORE RULES]\n'
  cat "$CORE_RULES_FILE"
  if [ -f "$CONVENTIONS_FILE" ]; then
    printf '\n\n[PROJECT CONVENTIONS]\n'
    cat "$CONVENTIONS_FILE"
  fi
  load_worker_skills
}

# WORKER_SKILLS 의 SKILL.md 본문(frontmatter 제외)을 워커 프롬프트에 붙인다.
# 파이프라인 계약과의 우선순위를 함께 명시한다 — 스킬은 '어떻게'(DELEGATED 결정)에만 적용되고,
# 문서가 정한 동작·REQUIRED 결정·테스트 목록은 스킬의 YAGNI 로 빼지 못한다.
worker_skill_file() { # name → 경로 (없으면 빈 출력)
  local d
  for d in "$PROJECT_ROOT/.claude/skills/$1" "$PROJECT_ROOT/.agents/skills/$1" "$FEATURE_SKILL_DIR/worker-skills/$1"; do
    [ -f "$d/SKILL.md" ] && { printf '%s' "$d/SKILL.md"; return 0; }
  done
  return 1
}
strip_frontmatter() { awk 'NR==1 && $0=="---" {infm=1; next} infm && $0=="---" {infm=0; next} !infm' "$1"; }
load_worker_skills() {
  local name file
  [ "${#WORKER_SKILLS[@]}" -gt 0 ] || return 0
  for name in "${WORKER_SKILLS[@]}"; do
    file="$(worker_skill_file "$name")" || { echo "[FAIL] 필수 워커 스킬 '$name' 없음 — .claude/skills/, .agents/skills/, feature/worker-skills/ 어디에도 SKILL.md 가 없다. npx skills add 로 설치하거나 config.sh WORKER_SKILLS 에서 제거" >&2; return 1; }
    printf '\n\n[WORKER SKILL: %s]\n' "$name"
    strip_frontmatter "$file"
    if [ "$name" = ponytail ]; then
      printf '\n[WORKER SKILL: ponytail — 이 파이프라인에서의 적용 범위]\n'
      printf -- '- 강도: %s.\n' "$PONYTAIL_LEVEL"
      printf -- '- 사다리는 approach.md 의 DELEGATED 결정과 로컬 구현 방식에만 적용한다. request.md·design.md·implementation.md 가 정한 동작, approach.md 의 REQUIRED 결정, implementation.md 가 요구한 테스트는 YAGNI 로 빼거나 축소하지 않는다 — "이 요구가 필요한가"는 여기서 다시 묻지 않는다(문서 합의에서 이미 정해졌다).\n'
      printf -- '- 요구 자체가 과하다고 판단되면 구현을 줄이지 말고 결과 JSON 의 delegated_choices 나 undecided(DOC_GAP) 로 보고한다. "lazy 버전을 먼저 내고 질문한다" 는 여기서는 UNDECIDED 로 돌려보내는 것이다.\n'
      printf -- '- "skipped: X, add when Y" 는 코드 주석·산문이 아니라 delegated_choices 항목으로 남긴다. ponytail: 주석은 approach.md 가 허용한 범위에서만.\n'
      printf -- '- 테스트: implementation.md 의 테스트 목록이 우선이며 그 외 자체 검사는 추가하지 않는다(리뷰어가 문서 밖 테스트를 TEST_CONTRACT_GAP 으로 보지 않더라도 커버리지용 테스트는 금지).\n'
      printf -- '- 파일 삭제 금지·범위 밖 변경 금지·index 조작 금지는 스킬보다 우선한다("Deletion over addition" 은 파일 내 코드 제거에만 해당).\n'
    fi
  done
}

# approach.md 가 백틱으로 인용한 참조 구현 `path:L40-L68` 의 해당 줄 범위만 워커 프롬프트에 붙인다.
# "가서 읽어라"는 codex 비대화형 실행에서 자주 무시되므로 러너가 결정론적으로 눈앞에 둔다.
# 심볼 탐색은 언어 종속이라 하지 않는다 — 줄 범위가 없는 인용은 붙이지 않는다(검증자가 범위를 요구한다).
# 참조당 REF_MAX_LINES 줄, 총 REF_MAX_REFS 개까지.
REF_MAX_REFS="${REF_MAX_REFS:-8}"
REF_MAX_LINES="${REF_MAX_LINES:-100}"
load_reference_code() {
  local approach="$WORK_DIR/approach.md" count=0 ref path from to
  [ -f "$approach" ] || return 0
  grep -oE '`[A-Za-z0-9_./-]+:L[0-9]+-L[0-9]+`' "$approach" | tr -d '`' | sort -u \
    | while IFS= read -r ref; do
        path="${ref%%:L*}"; from="${ref##*:L}"; from="${from%%-L*}"; to="${ref##*-L}"
        [ -f "$path" ] || continue
        [ "$count" -ge "$REF_MAX_REFS" ] && { printf '\n[REFERENCE CODE 생략: 참조 %d개 초과]\n' "$REF_MAX_REFS"; break; }
        [ "$count" -eq 0 ] && printf '[REFERENCE CODE — approach.md 가 인용한 기존 코드. REQUIRED 동작·구조·재사용 계약 확인용]\n'
        count=$((count + 1))
        if [ $((to - from + 1)) -gt "$REF_MAX_LINES" ]; then to=$((from + REF_MAX_LINES - 1)); fi
        printf '\n--- %s:L%d-L%d ---\n' "$path" "$from" "$to"
        sed -n "${from},${to}p" "$path"
      done
  return 0
}

# 작업 트리(WORK_DIR 제외, gitignore 적용)를 git tree 객체로 기록해 SHA 를 출력한다.
# 커밋·실제 index 를 건드리지 않고(임시 index) untracked 신규 파일까지 담는다.
# 용도: 워커 진입 직전 기준선(worker-baseline.tree — 이번 작업이 만든 변경만 리뷰·원복 대상으로 삼는다),
#       리뷰 라운드별 스냅샷(수정자가 실제로 바꾼 diff).
snapshot_worktree_tree() {
  # 임시 index 는 프로세스별 이름 — 같은 트리에서 두 실행(예: 두 피처의 worktree 부트스트랩)이 동시에 스냅샷해도 서로 덮어쓰지 않는다
  local idx; idx="$(cd "$WORK_DIR" && pwd)/.snapshot-index.${BASHPID:-$$}"   # $$ 는 subshell 에서 부모와 같다 — BASHPID 로 구분
  rm -f "$idx"
  if git rev-parse --verify -q HEAD >/dev/null; then
    GIT_INDEX_FILE="$idx" git read-tree HEAD || return 1
  else
    GIT_INDEX_FILE="$idx" git read-tree --empty || return 1   # 커밋이 없는 저장소: 빈 tree 에서 시작
  fi
  # pathspec 으로 WORK_DIR 를 빼면 gitignore 된 경우 git 이 "ignored path" 힌트와 함께 실패한다 — 전부 담은 뒤 index 에서만 뺀다
  GIT_INDEX_FILE="$idx" git add -A >/dev/null || return 1
  GIT_INDEX_FILE="$idx" git rm -r -q --cached --ignore-unmatch -- "$WORK_DIR" >/dev/null || return 1
  GIT_INDEX_FILE="$idx" git write-tree || return 1
  rm -f "$idx"
}

# 역할별 세션 재사용: 첫 호출은 --session-id <새 UUID>, 이후엔 --resume.
# 라운드 사이 저장소 재탐색을 없애고 프롬프트 캐시를 살리기 위함.
# 새 피처 시작 시 $WORK_DIR/.session-* 를 지워야 이전 피처 문맥이 섞이지 않는다.
claude_session_args() {
  local role="$1"
  local id_file="$WORK_DIR/.session-$role"
  if [ -f "$id_file" ]; then
    printf -- '--resume %s' "$(cat "$id_file")"
  else
    local new_id
    new_id="$(uuidgen | tr 'A-Z' 'a-z')"
    printf '%s' "$new_id" > "$id_file.new"
    printf -- '--session-id %s' "$new_id"
  fi
}

# 호출 '성공' 직후에만 세션 ID 확정. 첫 호출이 실패하면 .new 가 확정되지 않아
# 다음 실행이 존재하지 않는 세션을 --resume 하는 사고를 막는다.
claude_session_commit() {
  local id_file="$WORK_DIR/.session-$1"
  if [ -f "$id_file.new" ]; then mv "$id_file.new" "$id_file"; fi
}

# =============================================================
# 역할 → CLI 라우팅과 공통 호출 헬퍼
# 역할별 CLI 를 스크립트에 고정하지 않는다. 모델 ID(또는 <ROLE>_CLI 명시)로 claude/codex 를 고르고,
# 역할이 요구하는 실행 형태(읽기 전용+스키마 JSON / 편집)를 두 CLI 의 플래그로 각각 옮긴다.
# =============================================================
cli_for_model() { # model → claude|codex (이름으로 정할 수 없으면 1)
  case "$1" in
    claude*)                 printf 'claude' ;;
    gpt-*|o[0-9]*|codex*)    printf 'codex' ;;
    *)                       return 1 ;;
  esac
}
role_model()  { local v="${1}_MODEL";  printf '%s' "${!v}"; }
role_effort() { local v="${1}_EFFORT"; printf '%s' "${!v}"; }
role_cli() { # ROLE(DESIGNER|VALIDATOR|WORKER|REVIEWER|FIXER) → claude|codex
  local role="$1" override_var="${1}_CLI" override model
  override="${!override_var:-}"; model="$(role_model "$role")"
  if [ -n "$override" ]; then
    case "$override" in
      claude|codex) printf '%s' "$override"; return 0 ;;
      *) echo "[FAIL] config.sh $override_var='$override' — claude 또는 codex 만 허용" >&2; return 1 ;;
    esac
  fi
  cli_for_model "$model" \
    || { echo "[FAIL] 모델 '$model'($role) 의 CLI 를 이름으로 정하지 못함 — config.sh 에 $override_var=claude|codex 를 지정" >&2; return 1; }
}
role_bin() { # ROLE → 실행 파일
  case "$(role_cli "$1")" in claude) printf '%s' "$CLAUDE_BIN" ;; codex) printf '%s' "$CODEX_BIN" ;; *) return 1 ;; esac
}
require_role_bins() { # ROLE... [+ 공용 도구...] : 설정된 역할이 실제로 쓰는 CLI 만 설치 확인
  local item bin
  for item in "$@"; do
    case "$item" in
      DESIGNER|VALIDATOR|WORKER|REVIEWER|FIXER) bin="$(role_bin "$item")" || return 1 ;;
      *) bin="$item" ;;
    esac
    command -v "$bin" >/dev/null 2>&1 || { echo "[FAIL] '$bin' 미설치 (${item})" >&2; return 1; }
  done
}

# 읽기 전용·스키마 강제 JSON 역할(검증자·리뷰어).
#   결과 JSON → $out. 부산물: claude 는 $out.raw(전체 응답, structured_output 추출 전), codex 는 $out.log(stdout/stderr).
#   conventions: 프롬프트에 이미 들어 있으면 "" 를 넘긴다. claude 는 --append-system-prompt, codex 는 프롬프트 앞 블록으로 붙인다.
#   claude 는 세션(session_name)을 라운드 간 이어가고 usage 를 기록한다(codex exec 는 무상태 — 사용량은 $out.log 의 "tokens used" 참고).
run_readonly_json_role() { # ROLE session_name usage_label schema_file out_json prompt conventions
  local role="$1" session="$2" label="$3" schema="$4" out="$5" prompt="$6" conv="$7" model effort cli
  model="$(role_model "$role")"; effort="$(role_effort "$role")"; cli="$(role_cli "$role")" || return 1
  case "$cli" in
    codex)
      [ -z "$conv" ] || prompt="$conv"$'\n\n'"$prompt"
      "$CODEX_BIN" exec -m "$model" -c "model_reasoning_effort=\"$effort\"" --sandbox read-only \
        --output-schema "$schema" -o "$out" \
        "$prompt" > "$out.log" 2>&1 \
        || { echo "[FAIL] codex 실행 실패 (모델 '$model', $role 확인)" >&2; tail -20 "$out.log" >&2; return 1; }
      ;;
    claude)
      local session_args conv_args=()
      [ -z "$conv" ] || conv_args=(--append-system-prompt "$conv")
      session_args=$(claude_session_args "$session")
      "$CLAUDE_BIN" -p $session_args --model "$model" --effort "$effort" \
        ${conv_args[@]+"${conv_args[@]}"} \
        --tools "Read,Grep,Glob" \
        --disallowedTools "Bash,Edit,Write,NotebookEdit" \
        --json-schema "$(cat "$schema")" --output-format json \
        "$prompt" \
        > "$out.raw" || { echo "[FAIL] claude 실행 실패 (모델 '$model', $role 확인)" >&2; return 1; }
      claude_session_commit "$session"
      log_claude_usage "$label" "$out.raw"
      jq -e '.structured_output' "$out.raw" > "$out" \
        || { echo "[FAIL] 응답에 structured_output 없음: $out.raw" >&2; return 1; }
      ;;
  esac
}

# 편집 역할(디자이너·수정자·워커). 원문 출력을 $raw 에 남기고 CLI 종료 코드를 그대로 돌려준다(호출자가 set +e 로 받는다).
#   schema_file/out_json 이 비어 있지 않으면 스키마 강제 JSON 을 out_json 에 남긴다(워커). claude 는 structured_output 을 추출한다.
#   conventions 는 run_readonly_json_role 과 같다. 나머지 인자는 claude 에만 붙는 추가 플래그(예: --allowedTools Bash).
run_edit_role() { # ROLE session_name usage_label raw_out prompt conventions schema_file out_json [claude_extra_args...]
  local role="$1" session="$2" label="$3" raw="$4" prompt="$5" conv="$6" schema="$7" out="$8"; shift 8
  local model effort cli rc=0
  model="$(role_model "$role")"; effort="$(role_effort "$role")"; cli="$(role_cli "$role")" || return 1
  case "$cli" in
    codex)
      [ -z "$conv" ] || prompt="$conv"$'\n\n'"$prompt"
      local schema_args=()
      [ -z "$schema" ] || schema_args=(--output-schema "$schema" -o "$out")
      "$CODEX_BIN" exec -m "$model" -c "model_reasoning_effort=\"$effort\"" --sandbox workspace-write \
        ${schema_args[@]+"${schema_args[@]}"} "$prompt" 2>&1 \
        | tee "$raw" || rc=$?
      ;;
    claude)
      local session_args conv_args=() schema_args=()
      [ -z "$conv" ] || conv_args=(--append-system-prompt "$conv")
      [ -z "$schema" ] || schema_args=(--json-schema "$(cat "$schema")")
      session_args=$(claude_session_args "$session")
      "$CLAUDE_BIN" -p $session_args --model "$model" --effort "$effort" --permission-mode acceptEdits \
        ${conv_args[@]+"${conv_args[@]}"} \
        ${schema_args[@]+"${schema_args[@]}"} \
        "$@" --output-format json \
        "$prompt" \
        > "$raw" || rc=$?
      if [ "$rc" -eq 0 ]; then
        claude_session_commit "$session"
        log_claude_usage "$label" "$raw"
        # 스키마 역할이면 structured_output 을 꺼낸다. 없으면 out 은 빈 파일로 남고 호출자의 스키마 검사가 잡는다.
        [ -z "$schema" ] || jq -e '.structured_output' "$raw" > "$out" 2>/dev/null || rc=1
      fi
      ;;
  esac
  return "$rc"
}

# SHA-256 해시 (Linux sha256sum / macOS shasum 겸용)
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# git index 지문. 워커·수정자 호출 전후로 비교해 staged/unstaged 상태가 바뀌었으면 자동 복구 없이 중단한다
# (사용자의 staged 상태를 파이프라인이 해석하지 않는다). 정규식 훅이 놓치는 index 명령까지 결과 기준으로 잡는다.
compute_index_fingerprint() {
  # -v: assume-unchanged(소문자 태그)·skip-worktree(S) 같은 index 플래그까지 지문에 포함 — 변경 파일을 status 에서 숨기는 우회를 막는다
  git ls-files --stage -v -z | sha256_stdin
}

# 작업 트리 지문: tracked diff + status(-uall) + untracked 파일 '내용'까지 해시.
# git diff HEAD 만으로는 untracked 파일이, status 만으로는 untracked 내용 변경이
# 빠지므로 셋을 함께 묶어야 "승인 이후 어떤 변경도 없었다"를 보장할 수 있다.
# $WORK_DIR 는 제외 — 파이프라인 산출물(state.json, 리뷰, 지문 파일 자신)은
# 코드 변경이 아니며, gitignore 되지 않은 환경에서 지문이 자기참조되는 것을 막는다.
compute_worktree_fingerprint() {
  {
    git diff --binary HEAD -- . ":(exclude)$WORK_DIR"
    git status --porcelain=v1 -uall -- . ":(exclude)$WORK_DIR"
    git ls-files --others --exclude-standard -z -- . ":(exclude)$WORK_DIR" \
      | while IFS= read -r -d '' untracked_file; do
          if [ -L "$untracked_file" ]; then
            # 심볼릭 링크는 대상 내용이 아니라 '가리키는 경로'를 해시한다
            # (깨진 링크 실패 방지 + 같은 내용의 다른 대상으로 바꿔치기 감지)
            printf 'symlink %s ' "$untracked_file"
            readlink "$untracked_file" | sha256_stdin
          else
            printf '%s ' "$untracked_file"
            sha256_stdin < "$untracked_file"
          fi
        done
  } | sha256_stdin
}

# ---------- 피처 범위 manifest (feature-scope.json) ----------
# 오케스트레이터가 implementation.md 와 함께 쓴다: {"version":1,"files":[...],"new_file_roots":[...]}.
#   files          : 이번 피처가 변경·생성하는 정확한 경로(저장소 루트 기준)
#   new_file_roots : 정확한 파일명을 미리 정할 수 없는 생성 경로의 디렉터리 접두(마이그레이션 등). 최소한으로.
# 용도 — 같은 working tree 를 다른 세션과 공유할 때 "이번 피처의 변경"을 시점이 아니라 범위로 정의한다.
#   worker-baseline.tree 는 시점 기준선이지 변경 소유권의 증거가 아니다.
#   (1) 워커·수정자 호출 전후 write-set 이 범위를 벗어나면 자동 원복 없이 보존하고 중단
#   (2) 리뷰 diff 를 범위 경로로 한정 — 다른 세션의 변경이 "이번 작업"으로 리뷰어에게 가지 않는다
#   (3) 승인 지문을 범위 파일로 계산 — 다른 세션이 범위 밖 파일을 바꿔도 승인이 무효화되지 않는다
FEATURE_SCOPE_FILE="$WORK_DIR/feature-scope.json"          # 오케스트레이터가 쓰는 원본
FEATURE_SCOPE_LOCK="$WORK_DIR/feature-scope.lock.json"     # 워커 진입 전에 확정한 불변 사본 — 검사·diff·지문은 전부 이것을 쓴다
FEATURE_SCOPE_VERSION=1
# manifest 는 '검사 기준'이면서 워커·수정자가 쓸 수 있는 .agent-work 안에 있다(작업 트리 스냅샷은 WORK_DIR 를 제외하므로
# manifest 변경은 write-set diff 에 보이지 않는다). 그래서 원본을 직접 쓰지 않고 lock 사본을 기준으로 삼고, 호출 전후
# 원본·lock 해시를 대조해 달라졌으면 SCOPE_MANIFEST_CHANGED 로 자동 복구 없이 중단한다.
feature_scope_present() { [ -f "$FEATURE_SCOPE_FILE" ]; }
feature_scope_file() { if [ -f "$FEATURE_SCOPE_LOCK" ]; then printf '%s' "$FEATURE_SCOPE_LOCK"; else printf '%s' "$FEATURE_SCOPE_FILE"; fi; }
# 원본 + lock 의 내용 해시 (없는 쪽은 MISSING). 워커·수정자 호출 전후로 비교한다.
feature_scope_hash() {
  {
    for f in "$FEATURE_SCOPE_FILE" "$FEATURE_SCOPE_LOCK"; do
      printf '%s\0' "$f"; if [ -f "$f" ]; then cat "$f"; else printf 'MISSING'; fi; printf '\0'
    done
  } | sha256_stdin
}
# lock 확정: 없으면 원본을 복사. 있는데 원본과 다르면 2 (사용자가 범위를 바꿨거나 누군가 원본을 건드림 — 호출자가 중단).
# 반환: 0 확정/일치, 1 생성 실패, 2 원본≠lock. 호출부는 set -e 아래에서 `if lock_feature_scope; then :; else rc=$?; ...` 형태로 받는다
# (`f; rc=$?` 는 errexit 가 f 의 실패에서 바로 종료해 rc 줄에 도달하지 못한다).
lock_feature_scope() {
  if [ ! -f "$FEATURE_SCOPE_LOCK" ]; then
    cp "$FEATURE_SCOPE_FILE" "$FEATURE_SCOPE_LOCK" || return 1
    return 0
  fi
  cmp -s "$FEATURE_SCOPE_FILE" "$FEATURE_SCOPE_LOCK" && return 0
  return 2
}
# 경로는 canonical 이어야 한다 — git 이 돌려주는 변경 경로(선행 ./ 없음, 후행 / 없음)와 문자열로 비교하기 때문.
#   files          : 저장소 상대, 선행 "./" 금지, 후행 "/" 금지, 빈·"."·".." 세그먼트 금지. 이 경로는 생성·수정·삭제 전부 허용.
#   new_file_roots : 같은 규칙이되 후행 "/" 는 하나 허용(비교 전에 제거). 이 아래는 **기준선 tree 에 없던 파일의 생성·후속 수정(A/M)만** 허용 —
#                    기존 파일의 수정·삭제·타입 변경은 범위 위반이다(정확한 파일명을 미리 알 수 없는 '생성' 경로라는 정의 그대로).
#   files 와 new_file_roots 중 하나 이상에 항목이 있어야 한다 (마이그레이션만 만드는 피처는 roots 만으로 표현)
feature_scope_valid_file() { # manifest-path
  [ -f "$1" ] && jq -e --argjson v "$FEATURE_SCOPE_VERSION" '
    def canonical: type=="string" and length>0 and (startswith("/")|not) and (startswith("./")|not)
      and (split("/") | all(.[]; . != "" and . != "." and . != ".."));
    .version==$v and (.files|type=="array") and ((.new_file_roots // [])|type=="array")
    and ((.files|length) + ((.new_file_roots // [])|length)) > 0
    and all(.files[]; canonical)
    and all((.new_file_roots // [])[]; type=="string" and (sub("/$"; "") | canonical))' \
    "$1" >/dev/null 2>&1
}
feature_scope_valid() { feature_scope_valid_file "$(feature_scope_file)"; }
feature_scope_pathspecs() { # git pathspec 목록 (files + roots), 한 줄 하나
  jq -r '.files[], ((.new_file_roots // [])[] | sub("/+$"; "") + "/")' "$(feature_scope_file)"
}
path_in_exact_feature_files() { # path → 0 이면 files 에 정확히 있음
  jq -e --arg p "$1" '(.files|index($p))!=null' "$(feature_scope_file)" >/dev/null 2>&1
}
path_in_new_file_roots() { # path → 0 이면 어떤 root 아래
  jq -e --arg p "$1" 'any((.new_file_roots // [])[]; . as $r | ($p|startswith(($r|sub("/+$"; "")) + "/")))' "$(feature_scope_file)" >/dev/null 2>&1
}
path_in_feature_scope() { path_in_exact_feature_files "$1" || path_in_new_file_roots "$1"; }
# 두 tree 사이 변경 중 범위 밖인 것을 출력 (없으면 빈 출력, 반환 0). 호출자가 비어 있지 않으면 중단한다.
#   files 경로: A/M/D/T 전부 허용. 그 밖(범위 밖): 전부 위반.
#   roots 아래: 소유 분류는 이번 호출의 A/M 이 아니라 **워커 진입 기준선 tree 에 있었는가**로 정한다.
#     기준선에 있던 파일 → M/D/T 전부 위반 (이 피처 것이 아니다)
#     기준선에 없던 파일(이 피처가 만든 것) → A/M 허용, D/T 위반 (파일 삭제 금지 계약을 결과 기준으로도 지킨다)
#     그래야 첫 워커 호출이 만든 파일을 다음 라운드의 수정자·worker-fix 가 다시 고칠 수 있다(호출 직전 tree 대비 M 이지만 피처가 만든 파일).
#   기준선 tree 는 **호출자가 호출 전에 읽어 인자로 넘긴다** — 이 함수는 worker-baseline.tree 파일을 다시 읽지 않는다.
#   그 파일은 에이전트가 쓸 수 있는 .agent-work 안에 있어서, 호출 후에 읽으면 워커가 빈 tree 로 바꿔 기존 파일 보호를 무력화할 수 있다.
#   호출자는 호출 전후 파일 내용이 같은지도 검사한다(SCOPE_BASELINE_CHANGED). 기준선 인자가 비어 있으면(구버전 산출물·단독 실행)
#   호출 전후 status A 만 허용하는 보수적 규칙으로 돌아간다.
path_owned_by_baseline() { # baseline-tree path → 0 이면 워커 진입 전부터 존재
  [ -n "$1" ] || return 1
  git ls-tree "$1" -- ":(literal)$2" 2>/dev/null | grep -q .
}
# worker-baseline.tree 를 읽어 검증된 tree 해시를 출력. 파일이 없으면 빈 출력(반환 0), 있는데 유효한 tree 가 아니면 반환 1.
read_worker_baseline_tree() {
  local t
  [ -f "$WORK_DIR/worker-baseline.tree" ] || return 0
  t="$(cat "$WORK_DIR/worker-baseline.tree")"
  git cat-file -e "$t^{tree}" 2>/dev/null || { echo "[FAIL] worker-baseline.tree 가 유효한 tree 를 가리키지 않음: $t" >&2; return 1; }
  printf '%s' "$t"
}
# 기준선 변조 가드: SCOPE_BASELINE_CHANGED 로 중단한 뒤 사용자가 worker-baseline.tree 를 원래 값으로 되돌리기 전에는
# 다음 실행이 변조된 값을 새 기준선으로 읽어 들이면 안 된다(그러면 첫 실행이 잡은 우회가 재실행에서 성립한다).
# 자동 원복은 하지 않고, 중단 당시의 기대값을 이 파일에 남겨 복구 전 재실행을 모델 호출 0회로 다시 막는다.
BASELINE_GUARD="$WORK_DIR/worker-baseline.guard.json"
record_baseline_guard() { # expected observed actor
  jq -n --arg expected "$1" --arg observed "$2" --arg actor "$3" \
    '{active:true, expected:$expected, observed:$observed, actor:$actor}' > "$BASELINE_GUARD.tmp" && mv "$BASELINE_GUARD.tmp" "$BASELINE_GUARD"
}
# 활성 가드가 있으면 현재 worker-baseline.tree 가 기대값과 같아야 통과(가드를 비활성화). 다르면 1 — 호출자가 모델 호출 없이 중단.
require_baseline_guard_resolved() {
  local expected current=""
  [ -f "$BASELINE_GUARD" ] || return 0
  jq -e '.active == true' "$BASELINE_GUARD" >/dev/null 2>&1 || return 0
  expected="$(jq -r '.expected' "$BASELINE_GUARD")"
  [ -f "$WORK_DIR/worker-baseline.tree" ] && current="$(cat "$WORK_DIR/worker-baseline.tree")"
  if [ "$current" != "$expected" ]; then
    echo "[STOP] worker-baseline.tree 가 아직 변조 전 값으로 복구되지 않음 — 기대: ${expected:-없음} / 현재: ${current:-없음}. 자동 복구하지 않음." >&2
    return 1
  fi
  jq '.active = false' "$BASELINE_GUARD" > "$BASELINE_GUARD.tmp" && mv "$BASELINE_GUARD.tmp" "$BASELINE_GUARD"
}
feature_scope_violations() { # before-tree after-tree [ownership-baseline-tree]
  # --no-renames: rename 을 삭제+추가로 분해한다. 아니면 범위 밖 파일을 범위 안 경로로 옮겼을 때 목적지만 보여
  # 출발지(범위 밖 파일의 삭제)가 검사를 통과한다. 리뷰용 diff 는 rename 형태를 유지해도 되지만 위반 검사는 고정.
  local before="$1" after="$2" baseline="${3:-}" status changed
  git diff --no-renames --name-status -z "$before" "$after" -- | while IFS= read -r -d '' status && IFS= read -r -d '' changed; do
    [ -z "$changed" ] && continue
    path_in_exact_feature_files "$changed" && continue
    if path_in_new_file_roots "$changed"; then
      if [ -n "$baseline" ]; then
        if ! path_owned_by_baseline "$baseline" "$changed"; then
          case "$status" in A|M) continue;; esac
        fi
      elif [ "$status" = A ]; then
        continue
      fi
    fi
    printf '%s\n' "$changed"
  done
}
# 범위 지문: 현재 작업 트리의 git tree 객체에서 범위 경로의 엔트리(모드·유형·blob·경로)를 해시한다.
# 내용뿐 아니라 실행 권한·symlink 목적지·생성/삭제까지 잡히고, snapshot_worktree_tree 와 같은 기준(untracked 포함, WORK_DIR 제외)이다.
# manifest(lock) 자체도 포함한다 — 범위 정의가 바뀌면 이전 승인은 다른 범위에 대한 것이다.
# roots 아래는 신규 파일만 피처 변경이므로, 워커 진입 기준선(worker-baseline.tree)에 이미 있던 엔트리는 제외한다(기준선이 없으면 전부 포함).
compute_feature_fingerprint() {
  local tree path root baseline=""
  tree="$(snapshot_worktree_tree)" || return 1
  [ -f "$WORK_DIR/worker-baseline.tree" ] && baseline="$(cat "$WORK_DIR/worker-baseline.tree")"
  {
    printf 'feature-scope\0'; cat "$(feature_scope_file)"; printf '\0'
    while IFS= read -r path; do
      git ls-tree -r -z "$tree" -- ":(literal)$path"
    done < <(jq -r '.files[]' "$(feature_scope_file)")
    while IFS= read -r root; do
      root="${root%/}"
      if [ -n "$baseline" ]; then
        # 기준선에 있던 경로는 제외 (경로 기준 차집합)
        git ls-tree -r "$tree" -- ":(literal)$root/" \
          | awk -v base="$(git ls-tree -r --name-only "$baseline" -- ":(literal)$root/" | tr '\n' '\001')" \
              'BEGIN{n=split(base,a,"\001"); for(i=1;i<=n;i++) if(a[i]!="") seen[a[i]]=1} {p=$0; sub(/^[^\t]*\t/,"",p); if(!(p in seen)) print}'
      else
        git ls-tree -r "$tree" -- ":(literal)$root/"
      fi
    done < <(jq -r '(.new_file_roots // [])[]' "$(feature_scope_file)")
  } | sha256_stdin
}
# 승인·리뷰 입력 지문. manifest 가 없으면(구버전 산출물) 작업 트리 전체 지문으로 호환한다.
# manifest 가 '있는데' 잘못된 경우는 조용히 전체 지문으로 돌아가지 않는다 — 범위 격리가 소리 없이 풀리기 때문에 실패시킨다.
# lock 이 있으면 원본과 같아야 한다 — 이 불변식을 여기 두어 러너 verify·리뷰 루프·승인 재사용·커밋 직전 검사가 전부 같은 조건을 본다
# (lock 만 해시하면 승인 뒤 원본만 바뀌어도 통과해 버린다).
compute_approval_fingerprint() {
  if [ -f "$FEATURE_SCOPE_LOCK" ]; then
    [ -f "$FEATURE_SCOPE_FILE" ] || { echo "[FAIL] feature-scope.json 은 없고 lock 만 존재함" >&2; return 1; }
    cmp -s "$FEATURE_SCOPE_FILE" "$FEATURE_SCOPE_LOCK" || { echo "[SCOPE_MANIFEST_CHANGED] feature-scope.json 과 feature-scope.lock.json 이 다름 — 승인·지문 계산 불가" >&2; return 1; }
    feature_scope_valid_file "$FEATURE_SCOPE_LOCK" || { echo "[FAIL] 유효하지 않은 feature-scope.lock.json" >&2; return 1; }
  fi
  if feature_scope_present; then
    feature_scope_valid_file "$FEATURE_SCOPE_FILE" || { echo "[FAIL] 유효하지 않은 feature-scope.json — version $FEATURE_SCOPE_VERSION, files/new_file_roots 중 하나 이상, canonical 상대 경로" >&2; return 1; }
    compute_feature_fingerprint
  else
    compute_worktree_fingerprint
  fi
}

# 수정자(FIXER_PENDING) 재개용 지문: 승인 지문 + decisions.md. 수정자는 코드를 고치지 않고 decisions.md 에
# REJECT 만 기록하고 죽을 수 있으므로, 작업 트리 지문만으로는 부분 실행을 감지하지 못한다.
# APPROVE 캐시는 계속 compute_approval_fingerprint 만 쓴다 — 이후 문서 기록이 승인을 무효화하면 안 된다.
compute_fixer_resume_fingerprint() {
  {
    compute_approval_fingerprint
    if [ -f "$WORK_DIR/decisions.md" ]; then sha256_stdin < "$WORK_DIR/decisions.md"; else printf 'MISSING\n'; fi
  } | sha256_stdin
}

# ---------- 문서 합의 체크포인트 공용 정의 (consensus-loop.sh 와 feature-run.sh 가 같은 것을 써야 한다) ----------
# 합의 대상 문서 + decisions.md. 스냅샷·문서 diff·변경 파일 계산·재개 지문이 모두 이 목록 하나를 쓴다.
# (지문에 들어가는 파일과 diff 에 잡히는 파일이 다르면, 변경 감지로 넘어간 다음 라운드에서 검증자가
#  실제로 바뀐 파일을 revision_ref 로 가리켜도 러너가 "변경 목록에 없음"으로 응답을 거부하게 된다)
consensus_docs_for() { # design | impl
  case "$1" in
    design) printf '%s\n' "$WORK_DIR/design.md" "$WORK_DIR/decisions.md";;
    impl) printf '%s\n' "$WORK_DIR/implementation.md" "$WORK_DIR/approach.md" "$WORK_DIR/decisions.md";;
  esac
}
# 지문 세 종류 — 재개 지점은 "누가 무엇을 바꿨는가"에 따라 달라지므로 하나로 합치지 않는다.
#   editable : 디자이너가 고치는 것(consensus_docs_for = 대상 문서 + decisions.md). DESIGNER_PENDING 에서 달라졌으면 디자이너 부분 실행.
#   upstream : 디자이너 입력이지만 이 루프가 고치지 않는 것(design: request.md / impl: request.md + design.md, + [USER-QUESTION]).
#              달라졌으면 저장된 리뷰 자체가 무효 → Round 1 부터.
#   pass     : 합의된 입력 전체(upstream + 대상 문서 + [USER-QUESTION]). PASS 가 현재 입력에 대한 것인지.
_fingerprint_files() { # file... → NUL 구분 내용 스트림
  for file in "$@"; do
    [ -f "$file" ] || continue
    printf '%s\0' "$file"; cat "$file"; printf '\0'
  done
}
_user_decisions() {
  printf 'decisions:USER-QUESTION\0'
  if [ -f "$WORK_DIR/decisions.md" ]; then grep -E '^\s*- \[USER-QUESTION\]' "$WORK_DIR/decisions.md" || true; fi
}
consensus_editable_fingerprint() { # design | impl
  { consensus_docs_for "$1" | while IFS= read -r file; do _fingerprint_files "$file"; done; } | sha256_stdin
}
consensus_upstream_fingerprint() { # design | impl
  {
    case "$1" in
      design) _fingerprint_files "$WORK_DIR/request.md";;
      impl) _fingerprint_files "$WORK_DIR/request.md" "$WORK_DIR/design.md";;
    esac
    _user_decisions
  } | sha256_stdin
}
# PASS 지문: 합의된 '입력'이 여전히 같은지 확인하는 용도. request/design(/implementation/approach) 전체와
# decisions.md 중 사용자 정책 결정([USER-QUESTION]) 줄만 — 이후 수정자·디자이너의 판정 기록이 쌓여도
# 이전 PASS 가 불필요하게 무효화되지 않게 한다.
consensus_pass_fingerprint() { # design | impl
  {
    case "$1" in
      design) _fingerprint_files "$WORK_DIR/request.md" "$WORK_DIR/design.md";;
      impl) _fingerprint_files "$WORK_DIR/request.md" "$WORK_DIR/design.md" "$WORK_DIR/implementation.md" "$WORK_DIR/approach.md" "$WORK_DIR/feature-scope.json";;
    esac
    _user_decisions
  } | sha256_stdin
}
# (impl PASS 지문에 feature-scope.json 원본을 넣는다 — 사용자가 범위를 바꾸면 워커 재진입 전에 impl 재합의를 거치게 한다)
# 리뷰 JSON 내용 검증 — 체크포인트가 가리키는 파일이 존재한다는 것만으로 PASS/APPROVE 를 복원하지 않는다.
valid_spec_pass_review() { # review.json
  [ -f "$1" ] && jq -e --argjson v "$VALIDATOR_CONTRACT_VERSION" \
    '.schema_version==$v and .verdict=="PASS" and (.blocking_issues|length)==0' "$1" >/dev/null 2>&1
}
valid_impl_approve_review() { # review.json
  [ -f "$1" ] && jq -e --argjson v "$REVIEWER_CONTRACT_VERSION" \
    '.schema_version==$v and .verdict=="APPROVE" and (.issues|length)==0' "$1" >/dev/null 2>&1
}
# 현재 입력에 대해 유효한 합의 PASS 가 있는가: 체크포인트가 PASS 이고, 계약 버전·PASS 지문이 현재와 같고,
# 가리키는 리뷰 파일이 해당 round 의 실제 PASS 리뷰여야 한다. 러너의 stage 결정과 루프의 PASS 재사용이 함께 쓴다.
consensus_pass_current() { # design | impl
  local target="$1" checkpoint="$WORK_DIR/consensus-$1.json" review round
  [ -f "$checkpoint" ] || return 1
  jq -e --arg t "$target" --argjson v "$VALIDATOR_CONTRACT_VERSION" --argjson cv "$CONSENSUS_CHECKPOINT_VERSION" \
    '.version==$cv and .target==$t and .contract_version==$v and .next_step=="PASS"' "$checkpoint" >/dev/null 2>&1 || return 1
  [ "$(jq -r '.input_fingerprint // ""' "$checkpoint")" = "$(consensus_pass_fingerprint "$target")" ] || return 1
  review="$(jq -r '.review // ""' "$checkpoint")"
  round="$(jq -r '.round // 0' "$checkpoint")"
  [ "$review" = "$WORK_DIR/reviews/validator-$target-round-$(printf '%02d' "$round").json" ] || return 1
  valid_spec_pass_review "$review"
}

# 현재 작업 트리에 대해 유효한 구현 승인이 있는가: review-impl.json 이 APPROVE 이고 포맷·계약 버전이 맞고,
# 작업 트리 지문이 같고, 리뷰 경로가 attempt/round 와 일치하며 실제 APPROVE 리뷰이고, approved.fingerprint 도 같은 값이어야 한다.
# 러너가 verify stage 로 바로 들어가기 전에 쓴다 — approved.fingerprint 파일 존재만으로 리뷰 루프의 검사를 우회하지 않게.
impl_approval_current() {
  local checkpoint="$WORK_DIR/review-impl.json" fp review attempt round
  [ -f "$checkpoint" ] && [ -f "$WORK_DIR/approved.fingerprint" ] || return 1
  jq -e --argjson v "$REVIEWER_CONTRACT_VERSION" --argjson cv "$REVIEW_CHECKPOINT_VERSION" \
    '.version==$cv and .contract_version==$v and .next_step=="APPROVE"' "$checkpoint" >/dev/null 2>&1 || return 1
  fp="$(jq -r '.worktree_fingerprint // ""' "$checkpoint")"
  [ -n "$fp" ] && [ "$fp" = "$(cat "$WORK_DIR/approved.fingerprint")" ] && [ "$fp" = "$(compute_approval_fingerprint)" ] || return 1
  review="$(jq -r '.review // ""' "$checkpoint")"
  attempt="$(jq -r '.attempt // 0' "$checkpoint")"; round="$(jq -r '.round // 0' "$checkpoint")"
  [ "$review" = "$WORK_DIR/reviews/impl-attempt-$(printf '%02d' "$attempt")/reviewer-round-$(printf '%02d' "$round").json" ] || return 1
  valid_impl_approve_review "$review"
}

# 마지막 APPROVE 시점 지문과 현재 작업 트리를 비교. 다르면 승인 무효(APPROVAL_STALE).
# Phase 4 진입 직전과 커밋 위임 직전, 두 지점에서 반드시 호출한다.
verify_approved_fingerprint() {
  local fingerprint_file="$WORK_DIR/approved.fingerprint"
  [ -f "$fingerprint_file" ] || { echo "[FAIL] 승인 지문 없음: $fingerprint_file — Phase 3 승인이 선행돼야 함." >&2; return 1; }
  local approved_hash current_hash
  approved_hash="$(cat "$fingerprint_file")"
  current_hash="$(compute_approval_fingerprint)"
  if [ "$approved_hash" != "$current_hash" ]; then
    echo "[APPROVAL_STALE] 마지막 APPROVE 이후 코드가 변경됨. Phase 3 재리뷰 없이는 진행 금지." >&2
    return 1
  fi
  echo "승인 지문 일치 — 마지막 APPROVE 이후 변경 없음."
}

# claude --output-format json 결과에서 사용량을 $WORK_DIR/usage.jsonl 에 누적.
# 필수 필드가 없으면 null 을 조용히 쌓지 않고 경고 후 생략한다.
log_claude_usage() {
  local label="$1" result_file="$2"
  if ! jq -e '.usage.input_tokens != null' "$result_file" >/dev/null 2>&1; then
    echo "[WARN] usage 필드 없음 — 기록 생략: $result_file" >&2
    return 0
  fi
  jq -c --arg label "$label" \
    '{label: $label, session: .session_id, cost_usd: .total_cost_usd, in: .usage.input_tokens, out: .usage.output_tokens, cache_read: .usage.cache_read_input_tokens, cache_write: .usage.cache_creation_input_tokens}' \
    "$result_file" >> "$WORK_DIR/usage.jsonl"
}

# =============================================================
# 가드: 설정이 틀리면 이 파일을 source 하는 스크립트를 즉시 중단
# =============================================================
case "$DESIGNER_MODEL$DESIGNER_EFFORT$VALIDATOR_MODEL$VALIDATOR_EFFORT$WORKER_MODEL$WORKER_EFFORT$REVIEWER_MODEL$REVIEWER_EFFORT$FIXER_MODEL$FIXER_EFFORT$TEST_CMD$LINT_CMD" in
  *CHANGE_ME*) echo "[FAIL] config.sh 의 CHANGE_ME 항목을 먼저 채우세요." >&2; exit 1;;
esac
for required_value in \
  "$DESIGNER_MODEL" "$DESIGNER_EFFORT" \
  "$VALIDATOR_MODEL" "$VALIDATOR_EFFORT" \
  "$WORKER_MODEL" "$WORKER_EFFORT" \
  "$REVIEWER_MODEL" "$REVIEWER_EFFORT" \
  "$FIXER_MODEL" "$FIXER_EFFORT" \
  "$TEST_CMD" "$LINT_CMD"; do
  [ -n "$required_value" ] || { echo "[FAIL] config.sh 역할별 모델/effort 및 프로젝트 명령은 비워둘 수 없습니다." >&2; exit 1; }
done
for _role in DESIGNER VALIDATOR WORKER REVIEWER FIXER; do role_cli "$_role" >/dev/null || exit 1; done; unset _role
[ -f "$CORE_RULES_FILE" ] || { echo "[FAIL] core_rules.md 없음: $CORE_RULES_FILE" >&2; exit 1; }
