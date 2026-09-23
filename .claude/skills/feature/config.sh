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
VALIDATOR_MODEL="gpt-6-sol"     # 명세 검증자
VALIDATOR_EFFORT="medium" # 게이트 모드(구현을 막을 최소 사유만 판정). 전체 보안·아키텍처 감사는 별도 수동 audit 에서만 high
VALIDATOR_PROFILE=""      # 판정 전략 오버레이(prompts/validator-overlays/<이름>.md). 빈 값 = 모델별 기본값(validator_profile 헬퍼). compact | guided | conservative | none
WORKER_MODEL="gpt-6-luna"       # 구현 담당
WORKER_EFFORT="max"
REVIEWER_MODEL="gpt-6-astra"  # 구현 리뷰 담당
REVIEWER_EFFORT="low"
FIXER_MODEL="claude-sonnet-5"     # 리뷰 이슈 수정 담당
FIXER_EFFORT="low"

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
# 13: implementation.md+approach.md 를 코드 사양서로 판정 — CODE_SPEC_GAP(문서가 두 가지 이상의 non-trivial 코드 구조를 허용) 추가, DELEGATED 는 formatter/import/compiler 세부와 저장소 단일 표현뿐.
# 15: 검증 대상을 production diff 동일성 → material decision 으로 되돌림. CODE_SPEC_GAP 은 material 구현 계약 하나가 열린 경우만(일곱 입장 조건 + "무엇이 달라지는가" gate), helper/local naming/intermediate/if·switch/for·stream/동등 overload/bounded local collection 은 워커 소유 local expression. REUSE_DISCOVERY_GAP 은 새 responsibility boundary 에만(feature-local DTO/entity/private helper 제외). "두 워커 다른 diff" 기준 폐기.
VALIDATOR_CONTRACT_VERSION=15

# --- 리뷰어 계약 버전 ---
# 리뷰어 프롬프트·수정자 프롬프트·impl-review 스키마·impl-review-loop 의 연계 검사 중 하나라도 바뀌면 올린다.
# 루프는 리뷰 JSON 의 schema_version 이 이 값과 다르면 응답 오류로 중단한다.
# 10: 프로젝트 컨벤션(conventions.md) 명시 규칙 위반을 CONTRACT_VIOLATION 으로 검사 — 리뷰어·수정자 프롬프트에 CONVENTIONS_FILE 경로 전달.
# 11: code-spec 수준 REQUIRED(호출 순서·helper 분해·naming·local 구조·reference pattern) 이탈을 동작이 같아도 CONTRACT_VIOLATION 으로 검사. 제외는 formatter/import/compiler 세부뿐.
# 14: DOC_GAP issue 에 user_question(비어 있지 않음)·options(≥2) 필수, FIX_CODE 는 둘 다 빈 값 — 리뷰어 DOC_GAP 은 impl 재합의가 아니라 사용자 결정으로 간다(doc-gap-resume.json).
# 15: CONTRACT_VIOLATION/UNDECIDED_APPROACH 를 material 계약(책임 배치·재사용·호출 횟수·상태 순서·transaction/lock/retry/cache·public 계약·명시 convention)으로 한정. helper/local naming/intermediate/if·switch/for·stream/동등 overload/bounded local collection/반환 직전 alias 는 문서가 적어 두었어도 issue 아님. REDUNDANT_CODE 에 문서가 요구하지 않은 standalone abstraction(outcome/context/kind 등) 추가. 수정자는 material contract 만 복구.
REVIEWER_CONTRACT_VERSION=15

# --- 체크포인트 포맷 버전 ---
# consensus-<target>.json / review-impl.json 의 필드·지문 '의미'가 바뀌면 올린다(계약 버전과 별개).
# 로더는 버전이 다르면 저장된 지문을 해석하지 않고 안전하게 처음(Round 1 / 새 attempt)으로 돌아간다 —
# 다른 의미의 지문을 비교해 "부분 실행"으로 오판하고 단계를 건너뛰는 것을 막는다.
CONSENSUS_CHECKPOINT_VERSION=3
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
# 이름 목록(기본 없음). 탐색 순서: $PROJECT_ROOT/.claude/skills/<이름>/SKILL.md → .agents/skills/<이름>/SKILL.md (npx skills add 로 설치한 것).
# frontmatter 를 뗀 본문을 [WORKER SKILL: <이름>] 블록으로 core rules 뒤에 붙인다. 워커가 codex 면 Claude 스킬 로더가 없다.
# 목록에 있는데 어디에도 없으면 필수 동작 누락이므로 조용히 진행하지 않고 실패한다.
WORKER_SKILLS=()

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
    gpt-6-sol)   printf 'compact' ;;
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
worker_skill_file() { # name → 경로 (없으면 빈 출력)
  local d
  for d in "$PROJECT_ROOT/.claude/skills/$1" "$PROJECT_ROOT/.agents/skills/$1"; do
    [ -f "$d/SKILL.md" ] && { printf '%s' "$d/SKILL.md"; return 0; }
  done
  return 1
}
strip_frontmatter() { awk 'NR==1 && $0=="---" {infm=1; next} infm && $0=="---" {infm=0; next} !infm' "$1"; }
load_worker_skills() {
  local name file
  [ "${#WORKER_SKILLS[@]}" -gt 0 ] || return 0
  for name in "${WORKER_SKILLS[@]}"; do
    file="$(worker_skill_file "$name")" || { echo "[FAIL] 필수 워커 스킬 '$name' 없음 — .claude/skills/, .agents/skills/ 어디에도 SKILL.md 가 없다. npx skills add 로 설치하거나 config.sh WORKER_SKILLS 에서 제거" >&2; return 1; }
    printf '\n\n[WORKER SKILL: %s]\n' "$name"
    strip_frontmatter "$file"
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

# 세션 재사용: 첫 호출은 --session-id <새 UUID>, 이후엔 --resume.
# 세션 이름은 역할이 아니라 stage/attempt 단위다(designer-design, validator-impl, reviewer-a01, fixer-a01, worker-unit-<id>).
# 같은 stage/attempt 안의 라운드·재시도만 이어가고(저장소 재탐색 없이 프롬프트 캐시 활용), 다른 stage/attempt 로는
# 대화 문맥을 넘기지 않는다 — 상태 전달은 문서·JSON·체크포인트·지문으로만 한다. 넓은 세션은 turn 마다 누적 문맥을
# 통째로 cache read 하므로 비용이 stage 수에 비례해 커진다.
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
#   결과 JSON → $out. 부산물: claude 는 $out.raw(전체 응답, structured_output 추출 전), codex 는 $out.events.jsonl(--json stdout) + $out.stderr.log.
#   conventions: 프롬프트에 이미 들어 있으면 "" 를 넘긴다. claude 는 --append-system-prompt, codex 는 프롬프트 앞 블록으로 붙인다.
#   claude 는 세션(session_name)을 라운드 간 이어간다(codex exec 는 무상태). 두 CLI 모두 invocation 마다 usage.jsonl 에 행 1개(log_role_usage).
run_readonly_json_role() { # ROLE session_name usage_label schema_file out_json prompt conventions
  local role="$1" session="$2" label="$3" schema="$4" out="$5" prompt="$6" conv="$7" model effort cli rc=0 inv
  model="$(role_model "$role")"; effort="$(role_effort "$role")"; cli="$(role_cli "$role")" || return 1
  inv="$(new_invocation_id)"
  case "$cli" in
    codex)
      [ -z "$conv" ] || prompt="$conv"$'\n\n'"$prompt"
      # invocation 전용 임시 -o 경로: 이번 호출이 만든 파일은 이것 하나뿐이다. 이전 실행·픽스처가 $out 에 남긴 파일을 이번 결과로 오인하지 않고,
      # 내용·mtime 으로 provenance 를 추론하지도 않는다(같은 JSON 을 다시 써도 새 결과다). usable 할 때만 $out 으로 atomic move.
      local tmp_out="$out.invocation-$inv.tmp"
      rm -f "$tmp_out"
      # --json: stdout 은 이벤트 JSONL(usage telemetry 원천, $out.events.jsonl), stderr 는 진단($out.stderr.log) — 한 파일에 섞으면 JSONL 이 깨진다.
      # structured result 는 계속 invocation 전용 -o 파일만 인정한다(telemetry 와 result provenance 는 별개).
      "$CODEX_BIN" exec --json -m "$model" -c "model_reasoning_effort=\"$effort\"" --sandbox read-only \
        --output-schema "$schema" -o "$tmp_out" \
        "$prompt" > "$out.events.jsonl" 2> "$out.stderr.log" || rc=$?
      log_role_usage codex "$role" "$model" "$label" "$out.events.jsonl" "$rc" "$inv"   # raw exit code 그대로 (exit_code/success 위조 없음)
      if ! { [ -s "$tmp_out" ] && jq -e 'type=="object"' "$tmp_out" >/dev/null 2>&1; }; then
        rm -f "$tmp_out"
        echo "[FAIL] codex 실행 실패 또는 결과 JSON 없음 (exit $rc, 모델 '$model', $role 확인)" >&2; tail -20 "$out.stderr.log" >&2; return 1
      fi
      if [ "$rc" -ne 0 ]; then
        # rc ≠ 0 이어도 이번 호출이 파싱 가능한 결과 JSON 을 썼으면 즉시 폐기하지 않는다 — 호출자의 schema/contract 검사가 최종 게이트다.
        # (codex 는 작업을 정상 완료한 뒤 프로세스 종료코드가 간헐적으로 1 이 되는 사례가 있다.)
        echo "[WARN] CLI_EXIT_STATUS_MISMATCH: $role codex exited $rc, but current invocation produced a JSON result ($tmp_out); using it subject to the caller's schema/contract checks" >&2
        record_cli_anomaly "$role" codex "$label" "$rc" STRUCTURED_RESULT "$out"
      fi
      mv "$tmp_out" "$out"
      ;;
    claude)
      local session_args conv_args=()
      [ -z "$conv" ] || conv_args=(--append-system-prompt "$conv")
      session_args=$(claude_session_args "$session")
      # FEATURE_ROLE_CHILD=1: 프로젝트 UserPromptSubmit 훅(inject_conventions.sh)이 conventions 를 다시 넣지 않게 한다 — 여기서 이미 명시 전달.
      FEATURE_ROLE_CHILD=1 "$CLAUDE_BIN" -p $session_args --model "$model" --effort "$effort" \
        ${conv_args[@]+"${conv_args[@]}"} \
        --tools "Read,Grep,Glob" \
        --disallowedTools "Bash,Edit,Write,NotebookEdit" \
        --json-schema "$(cat "$schema")" --output-format json \
        "$prompt" \
        > "$out.raw" || rc=$?
      log_role_usage claude "$role" "$model" "$label" "$out.raw" "$rc" "$inv"
      [ "$rc" -eq 0 ] || { echo "[FAIL] claude 실행 실패 (모델 '$model', $role 확인)" >&2; return 1; }
      claude_session_commit "$session"
      jq -e '.structured_output' "$out.raw" > "$out" \
        || { echo "[FAIL] 응답에 structured_output 없음: $out.raw" >&2; return 1; }
      ;;
  esac
}

# 편집 역할(디자이너·수정자·워커). 원문 출력을 $raw(claude) 또는 $raw.events.jsonl + $raw.stderr.log(codex) 에 남기고 CLI 종료 코드를 그대로 돌려준다(호출자가 set +e 로 받는다).
#   schema_file/out_json 이 비어 있지 않으면 스키마 강제 JSON 을 out_json 에 남긴다(워커). claude 는 structured_output 을 추출한다.
#   conventions 는 run_readonly_json_role 과 같다. 나머지 인자는 claude 에만 붙는 추가 플래그(예: --allowedTools Bash).
run_edit_role() { # ROLE session_name usage_label raw_out prompt conventions schema_file out_json [claude_extra_args...]
  local role="$1" session="$2" label="$3" raw="$4" prompt="$5" conv="$6" schema="$7" out="$8"; shift 8
  local model effort cli rc=0 inv
  model="$(role_model "$role")"; effort="$(role_effort "$role")"; cli="$(role_cli "$role")" || return 1
  inv="$(new_invocation_id)"
  case "$cli" in
    codex)
      [ -z "$conv" ] || prompt="$conv"$'\n\n'"$prompt"
      local schema_args=()
      [ -z "$schema" ] || schema_args=(--output-schema "$schema" -o "$out")
      # --json stdout(이벤트 JSONL) 과 stderr 를 분리한다 — tee 로 합치면 JSONL 이 깨지고 pipe rc 가 섞인다. raw codex rc 를 그대로 돌려준다.
      "$CODEX_BIN" exec --json -m "$model" -c "model_reasoning_effort=\"$effort\"" --sandbox workspace-write \
        ${schema_args[@]+"${schema_args[@]}"} "$prompt" > "$raw.events.jsonl" 2> "$raw.stderr.log" || rc=$?
      log_role_usage codex "$role" "$model" "$label" "$raw.events.jsonl" "$rc" "$inv"
      ;;
    claude)
      local session_args conv_args=() schema_args=()
      [ -z "$conv" ] || conv_args=(--append-system-prompt "$conv")
      [ -z "$schema" ] || schema_args=(--json-schema "$(cat "$schema")")
      session_args=$(claude_session_args "$session")
      FEATURE_ROLE_CHILD=1 "$CLAUDE_BIN" -p $session_args --model "$model" --effort "$effort" --permission-mode acceptEdits \
        ${conv_args[@]+"${conv_args[@]}"} \
        ${schema_args[@]+"${schema_args[@]}"} \
        "$@" --output-format json \
        "$prompt" \
        > "$raw" || rc=$?
      log_role_usage claude "$role" "$model" "$label" "$raw" "$rc" "$inv"   # 실패해도 파싱 가능한 usage 는 남긴다
      if [ "$rc" -eq 0 ]; then
        claude_session_commit "$session"
        # 스키마 역할이면 structured_output 을 꺼낸다. 없으면 out 은 빈 파일로 남고 호출자의 스키마 검사가 잡는다.
        [ -z "$schema" ] || jq -e '.structured_output' "$raw" > "$out" 2>/dev/null || rc=1
      fi
      ;;
  esac
  return "$rc"
}
# 편집 역할 실패 진단용 tail: codex 는 $raw.stderr.log, claude 는 $raw.
role_raw_diag_tail() { # raw
  if [ -f "$1.stderr.log" ]; then tail -20 "$1.stderr.log"; elif [ -f "$1" ]; then tail -20 "$1"; fi
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
# SCOPE_MANIFEST_OVERRIDE: 같은 files/new_file_roots 의미의 다른 manifest(구현 단위의 scope.json)로 아래 검사·pathspec 함수를 한 번 더 돌릴 때
# 호출 한 번에만 지정한다(`SCOPE_MANIFEST_OVERRIDE=<path> feature_scope_violations …`). 두 번째 범위 엔진을 만들지 않기 위한 매개변수다.
feature_scope_file() {
  if [ -n "${SCOPE_MANIFEST_OVERRIDE:-}" ]; then printf '%s' "$SCOPE_MANIFEST_OVERRIDE"; return 0; fi
  if [ -f "$FEATURE_SCOPE_LOCK" ]; then printf '%s' "$FEATURE_SCOPE_LOCK"; else printf '%s' "$FEATURE_SCOPE_FILE"; fi
}
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
# =============================================================
# CLI 종료 코드 ≠ 의미적 완료
#   편집 역할이 작업 트리·문서를 이미 바꾼 뒤 비정상 종료코드를 돌려줄 수 있다(codex 가 task_complete 뒤 프로세스 exit 1 을 내는 간헐 사례).
#   raw exit code 는 usage.jsonl 에 관측값 그대로 남기고(위조 없음), 호출자가 raw rc + 이번 invocation 의 기계 판독 결과 +
#   호출 전후 변경 + 기존 index/manifest/baseline/write-set 게이트 + 다음 독립 검증 게이트(검증자·리뷰어·targeted test)로 재실행 여부를 정한다.
#   불변식: 편집 역할이 한번 변경을 만들고 종료했으면, 성공 여부가 불명확하다는 이유만으로 같은 편집 호출을 자동 반복하지 않는다.
#   복구된 경우는 숨기지 않는다 — [WARN] CLI_EXIT_STATUS_MISMATCH 로그 + append-only cli-anomalies.jsonl.
# =============================================================
CLI_ANOMALY_LOG="$WORK_DIR/cli-anomalies.jsonl"
record_cli_anomaly() { # role cli label raw_exit_code recovery(STRUCTURED_RESULT|FORWARD_TO_VALIDATOR|FORWARD_TO_REVIEWER) evidence
  jq -nc --arg role "$1" --arg cli "$2" --arg label "$3" --argjson rc "$4" --arg recovery "$5" --arg evidence "$6" --arg now "$(date '+%FT%T%z')" \
    '{timestamp:$now, kind:"CLI_EXIT_STATUS_MISMATCH", role:$role, cli:$cli, label:$label, raw_exit_code:$rc, recovery:$recovery, evidence:$evidence}' \
    >> "$CLI_ANOMALY_LOG"
}
cli_anomaly_count() { if [ -f "$CLI_ANOMALY_LOG" ]; then grep -c . "$CLI_ANOMALY_LOG" || true; else echo 0; fi; }
# 워커 결과 JSON 이 러너가 실제로 쓰는 계약을 만족하는가 — 파일 존재만으로 성공 취급하지 않는다.
#   JSON parse / status ∈ {DONE,UNDECIDED} / undecided·delegated_choices·tests 배열 / context_updates.upsert·remove 배열(unit 의 rolling context 가 읽는다) /
#   undecided 항목의 kind·location·decision_needed / DONE+undecided>0 · UNDECIDED+undecided==0 모순.
worker_result_valid() { # result.json
  [ -s "$1" ] || return 1
  jq -e '
    type=="object"
    and (.status=="DONE" or .status=="UNDECIDED")
    and (.undecided|type)=="array" and (.delegated_choices|type)=="array" and (.tests|type)=="array"
    and (.context_updates|type)=="object" and (.context_updates.upsert|type)=="array" and (.context_updates.remove|type)=="array"
    and all(.undecided[]; (.kind=="DOC_GAP" or .kind=="USER_DECISION") and (.location|type)=="string" and (.decision_needed|type)=="string")
    and ((.status=="DONE" and (.undecided|length)==0) or (.status=="UNDECIDED" and (.undecided|length)>0))
  ' "$1" >/dev/null 2>&1
}
# 디자이너 범위 가드: 디자이너(편집 역할)가 합의 단계에서 문서 밖 source 작업 트리를 바꾸면 rc 와 무관하게 DESIGNER_SCOPE_VIOLATION 으로 중단한다.
# 검증자는 설계 문서를 검증하는 역할이지 디자이너가 바꾼 구현 코드를 승인하는 역할이 아니므로 VALIDATOR_PENDING 으로 넘기지 않는다.
# 호출 전 tree(expected)를 남겨, 사용자가 작업 트리를 되돌리기 전에는 재실행이 모델 호출 0회로 같은 사유로 다시 멈춘다(자동 원복·자동 재호출 없음).
DESIGNER_SCOPE_GUARD="$WORK_DIR/designer-scope.guard.json"
record_designer_scope_guard() { # expected(before-tree) observed(after-tree) target round raw_exit_code
  jq -n --arg expected "$1" --arg observed "$2" --arg target "$3" --argjson round "$4" --argjson rc "$5" --arg now "$(date '+%FT%T%z')" \
    '{active:true, expected:$expected, observed:$observed, target:$target, round:$round, raw_exit_code:$rc, recorded_at:$now}' \
    > "$DESIGNER_SCOPE_GUARD.tmp" && mv "$DESIGNER_SCOPE_GUARD.tmp" "$DESIGNER_SCOPE_GUARD"
}
require_designer_scope_guard_resolved() {
  local expected current
  [ -f "$DESIGNER_SCOPE_GUARD" ] || return 0
  jq -e '.active == true' "$DESIGNER_SCOPE_GUARD" >/dev/null 2>&1 || return 0
  expected="$(jq -r '.expected' "$DESIGNER_SCOPE_GUARD")"
  current="$(snapshot_worktree_tree)" || return 1
  if [ "$current" != "$expected" ]; then
    echo "[STOP] 직전 디자이너 호출($(jq -r '.target' "$DESIGNER_SCOPE_GUARD") round $(jq -r '.round' "$DESIGNER_SCOPE_GUARD"))이 문서 밖 source 파일을 바꿨고 작업 트리가 호출 전 tree 로 복구되지 않음 — 기대: $expected / 현재: $current. 자동 복구하지 않음." >&2
    return 1
  fi
  jq '.active = false' "$DESIGNER_SCOPE_GUARD" > "$DESIGNER_SCOPE_GUARD.tmp" && mv "$DESIGNER_SCOPE_GUARD.tmp" "$DESIGNER_SCOPE_GUARD"
}
# 워커 결과 불확실 가드: 워커가 작업 트리를 바꿨는데 결과 JSON 이 없거나 깨졌고 rc ≠ 0 이면 WORKER_OUTCOME_UNCERTAIN 으로 중단한다.
# 호출 전 tree(expected)를 남겨, 사용자가 작업 트리를 그 tree 로 명시적으로 되돌리기 전에는 재실행이 모델 호출 0회로 같은 사유로 다시 멈춘다.
# 자동 restore/reset/checkout/stash 없음. worker-baseline.guard.json 과 같은 fail-closed 패턴이며 워커 전용의 최소 구현이다.
WORKER_OUTCOME_GUARD="$WORK_DIR/worker-outcome.guard.json"
record_worker_outcome_guard() { # expected(before-tree) observed(after-tree) role label raw_exit_code result_path
  jq -n --arg expected "$1" --arg observed "$2" --arg role "$3" --arg label "$4" --argjson rc "$5" --arg result "$6" --arg now "$(date '+%FT%T%z')" \
    '{active:true, expected:$expected, observed:$observed, role:$role, label:$label, raw_exit_code:$rc, result:$result, recorded_at:$now}' \
    > "$WORKER_OUTCOME_GUARD.tmp" && mv "$WORKER_OUTCOME_GUARD.tmp" "$WORKER_OUTCOME_GUARD"
}
# 활성 가드가 있으면 현재 작업 트리가 expected(호출 전 tree)와 같아야 통과(가드 비활성화). 다르면 1 — 호출자가 모델 호출 없이 중단.
require_worker_outcome_guard_resolved() {
  local expected current
  [ -f "$WORKER_OUTCOME_GUARD" ] || return 0
  jq -e '.active == true' "$WORKER_OUTCOME_GUARD" >/dev/null 2>&1 || return 0
  expected="$(jq -r '.expected' "$WORKER_OUTCOME_GUARD")"
  current="$(snapshot_worktree_tree)" || return 1
  if [ "$current" != "$expected" ]; then
    echo "[STOP] 직전 워커 호출($(jq -r '.label' "$WORKER_OUTCOME_GUARD"), exit $(jq -r '.raw_exit_code' "$WORKER_OUTCOME_GUARD"))의 완료 여부가 불확실한데 작업 트리가 호출 전 tree 로 복구되지 않음 — 기대: $expected / 현재: $current. 자동 복구하지 않음." >&2
    return 1
  fi
  jq '.active = false' "$WORKER_OUTCOME_GUARD" > "$WORKER_OUTCOME_GUARD.tmp" && mv "$WORKER_OUTCOME_GUARD.tmp" "$WORKER_OUTCOME_GUARD"
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

# ---------- 구현 단위 manifest (implementation-units.json) ----------
# 오케스트레이터가 implementation.md/approach.md 와 함께 쓴다(schemas/implementation-units.schema.json). impl 합의의 입력이며(PASS 지문 포함),
# 워커 단계는 이 파일을 units 배열 순서대로 **직렬** 실행한다 — unit 마다 fresh 워커 → targeted test. unit 별 리뷰 없음, 병렬·DAG·우선순위 없음.
#   scope : feature-scope.json 과 같은 files/new_file_roots 의미. 전체 범위(lock)의 부분집합이어야 하며 위반 검사는 같은 feature_scope_violations 를 쓴다.
#   lock  : 워커 진입 시 implementation-units.lock.json 으로 확정(feature-scope.lock.json 과 같은 철학). 원본≠lock 이면 어느 쪽이 맞는지 정하지 않고 사람에게.
UNITS_MANIFEST_FILE="$WORK_DIR/implementation-units.json"
UNITS_MANIFEST_LOCK="$WORK_DIR/implementation-units.lock.json"
UNITS_MANIFEST_VERSION=1
units_manifest_present() { [ -f "$UNITS_MANIFEST_FILE" ]; }
units_manifest_file() { if [ -f "$UNITS_MANIFEST_LOCK" ]; then printf '%s' "$UNITS_MANIFEST_LOCK"; else printf '%s' "$UNITS_MANIFEST_FILE"; fi; }
# 스키마(schemas/implementation-units.schema.json)를 jq 로 그대로 강제한다 — 이 파일은 모델 출력이 아니라 오케스트레이터가 쓰므로 CLI 의 스키마 검사가 없다.
#   root/unit/scope additionalProperties false · version 1 · units ≥1 · id 순번 prefix + kebab · id 유일 · 순번이 배열 순서와 같이 증가 ·
#   requirements/references ≥1 · targeted_test 비어 있지 않음 · scope 는 feature-scope 와 같은 canonical 규칙(files/roots 중 하나 이상)
#   depends_on / priority / parallel 같은 필드는 additionalProperties false 로 거부된다(스케줄링 개념 없음).
units_manifest_valid_file() { # manifest-path
  [ -f "$1" ] && jq -e --argjson v "$UNITS_MANIFEST_VERSION" '
    def canonical: type=="string" and length>0 and (startswith("/")|not) and (startswith("./")|not)
      and (split("/") | all(.[]; . != "" and . != "." and . != ".."));
    def nonempty_strings: type=="array" and length>0 and all(.[]; type=="string" and length>0);
    type=="object" and .version==$v and ((keys - ["version","units"])|length)==0
    and (.units|type=="array") and (.units|length)>=1
    and all(.units[]; type=="object"
      and ((keys - ["id","title","goal","requirements","scope","references","targeted_test"])|length)==0
      and (.id|type=="string" and test("^[0-9]{2,}-[a-z0-9]+(-[a-z0-9]+)*$"))
      and (.title|type=="string" and length>0) and (.goal|type=="string" and length>0)
      and (.requirements|nonempty_strings) and (.references|nonempty_strings)
      and (.targeted_test|type=="string" and length>0)
      and (.scope|type=="object" and ((keys - ["files","new_file_roots"])|length)==0
        and (.files|type=="array") and ((.new_file_roots // [])|type=="array")
        and ((.files|length) + ((.new_file_roots // [])|length)) > 0
        and all(.files[]; canonical)
        and all((.new_file_roots // [])[]; type=="string" and (sub("/$"; "") | canonical))))
    and ([.units[].id] | length == (unique|length))
    and ([.units[].id | split("-")[0] | tonumber] as $n | all(range(1; $n|length); $n[.] > $n[.-1]))' \
    "$1" >/dev/null 2>&1
}
# unit scope 가 전체 범위(feature-scope lock) 밖으로 나가는 경로를 "<unit-id>:<path>" 로 출력 (빈 출력이면 부분집합).
#   files 는 전체 files 에 정확히 있거나 전체 roots 아래여야 하고, roots 는 전체 roots 와 같거나 그 아래여야 한다.
#   실행 시에는 전체 검사와 unit 검사를 둘 다 통과해야 하므로(둘 중 좁은 규칙이 이긴다) 여기서는 경로 포함 관계만 본다.
units_scope_outside_global() { # units-manifest global-scope-manifest
  jq -r --slurpfile g "$2" '
    ($g[0].files) as $gf | (($g[0].new_file_roots // []) | map(sub("/+$"; "") + "/")) as $gr
    | def covered_file: . as $p | (($gf | index($p)) != null) or any($gr[]; . as $r | $p | startswith($r));
      def covered_root: (sub("/+$"; "") + "/") as $p | any($gr[]; . as $r | $p == $r or ($p | startswith($r)));
      .units[] | .id as $id
      | ((.scope.files[] | select(covered_file | not) | "\($id):\(.)"),
         ((.scope.new_file_roots // [])[] | select(covered_root | not) | "\($id):\(.)"))' "$1"
}
units_manifest_hash() { # 원본 + lock 내용 해시 (없는 쪽은 MISSING). unit 워커 호출 전후로 비교한다.
  {
    for f in "$UNITS_MANIFEST_FILE" "$UNITS_MANIFEST_LOCK"; do
      printf '%s\0' "$f"; if [ -f "$f" ]; then cat "$f"; else printf 'MISSING'; fi; printf '\0'
    done
  } | sha256_stdin
}
# lock 확정: 없으면 원본을 복사. 있는데 원본과 다르면 2 (호출자가 중단 — 의도한 변경이면 impl 재합의 후 lock 을 지우고 재실행).
lock_units_manifest() {
  if [ ! -f "$UNITS_MANIFEST_LOCK" ]; then
    cp "$UNITS_MANIFEST_FILE" "$UNITS_MANIFEST_LOCK" || return 1
    return 0
  fi
  cmp -s "$UNITS_MANIFEST_FILE" "$UNITS_MANIFEST_LOCK" && return 0
  return 2
}
unit_ids() { jq -r '.units[].id' "$(units_manifest_file)"; }
unit_json() { jq -c --arg id "$1" '.units[] | select(.id==$id)' "$(units_manifest_file)"; }
# unit spec 지문: lock 의 해당 unit 객체(정렬된 compact JSON)의 해시. done.json 의 spec_hash 와 대조해 spec 이 바뀐 unit 의 체크포인트를 무효화한다.
unit_spec_hash() { jq -Sc --arg id "$1" '.units[] | select(.id==$id)' "$(units_manifest_file)" | sha256_stdin; }
# 완료 체크포인트가 유효한가: run-state 는 힌트일 뿐이고 실제 판정은 units/<id>/done.json 의 내용 + 현재 spec 지문 교차 확인이다.
unit_done_valid() { # unit-id
  local done="$WORK_DIR/units/$1/done.json"
  [ -f "$done" ] || return 1
  jq -e --arg id "$1" --arg h "$(unit_spec_hash "$1")" \
    '.version==1 and .unit_id==$id and .spec_hash==$h and .worker_status=="DONE" and .targeted_test_status=="PASS"' \
    "$done" >/dev/null 2>&1
}
all_units_done() { local id; for id in $(unit_ids); do unit_done_valid "$id" || return 1; done; }

# ---------- unit 간 rolling implementation context ----------
# 파일: $WORK_DIR/implementation-context.json = {version, completed_units[], facts[{kind,subject,note,source_unit}]}.
# source of truth 가 아니다(실제 코드 → 합의 문서 → 이 파일). 각 완료 unit 의 units/<id>/context-updates.json(워커 → test-fix 순서의
# context_updates 원본)이 원천이고 이 파일은 그로부터 **재구성되는 파생 상태**다 — 러너는 의미를 해석하지 않고 upsert/remove 만 적용한다.
#   identity  : (kind, subject). 같은 키의 upsert 는 제자리 교체(append 아님), remove 는 삭제. 한 update 안에서는 remove → upsert 순.
#   확정 시점 : unit 워커 DONE → targeted test PASS → context-updates.json → done.json. 실패한 unit 의 update 는 확정되지 않는다.
#   resume    : lock 순서대로 done 체크포인트가 유효한(내용 + spec_hash) 연속 prefix 만 fold 한다 — 무효화된 체크포인트의 update 는 재사용하지 않는다.
IMPL_CONTEXT_FILE="$WORK_DIR/implementation-context.json"
IMPL_CONTEXT_VERSION=1
impl_context_empty() { jq -nc --argjson v "$IMPL_CONTEXT_VERSION" '{version:$v, completed_units:[], facts:[]}'; }
# 결과 JSON(워커/test-fix) 의 context_updates 를 정규화해 한 줄로 낸다(없으면 빈 update). source 는 산출물 접두(worker, test-fix-01 …).
context_update_of() { # result-json source-label
  jq -c --arg src "$2" '{source:$src, upsert:((.context_updates.upsert // []) | map({kind,subject,note})), remove:((.context_updates.remove // []) | map({kind,subject}))}' "$1"
}
# fold: base facts 배열(JSON 문자열) 에 updates 배열(파일)을 순서대로 적용한 facts 배열을 낸다. 결정론적 — 병합·요약 판단 없음.
fold_context_updates() { # base-facts-json updates-file source-unit
  jq -c --argjson base "$1" --arg unit "$3" '
    reduce .[] as $u ($base;
      reduce ($u.remove // [])[] as $r (.; map(select((.kind==$r.kind and .subject==$r.subject) | not)))
      | reduce ($u.upsert // [])[] as $f (.;
          ({kind:$f.kind, subject:$f.subject, note:$f.note, source_unit:$unit}) as $new
          | if any(.[]; .kind==$f.kind and .subject==$f.subject)
            then map(if .kind==$f.kind and .subject==$f.subject then $new else . end)
            else . + [$new] end))' "$2"
}
# implementation-context.json 재구성: lock 순서대로 완료 체크포인트가 유효한 unit 의 context-updates.json 을 fold 한다.
#   stop-id 가 있으면 그 unit 직전까지(현재 unit 워커 호출 전) — 그 앞의 unit 이 하나라도 무효면 실패(조용히 건너뛰지 않는다).
#   stop-id 가 없으면 첫 무효 unit 에서 멈춘다(그 뒤 unit 의 update 는 무효 unit 재실행 뒤 다시 포함된다).
impl_context_write() { # [stop-id]
  local stop="${1:-}" id facts='[]' done_ids='[]' upd
  for id in $(unit_ids); do
    [ "$id" != "$stop" ] || { stop=""; break; }
    if ! unit_done_valid "$id"; then
      [ -z "$stop" ] || return 1
      break
    fi
    upd="$WORK_DIR/units/$id/context-updates.json"
    if [ -f "$upd" ]; then
      facts="$(jq -c '.updates' "$upd" | fold_context_updates "$facts" /dev/stdin "$id")" || return 1
    else
      echo "[WARN] unit $id: context-updates.json 없음(이 변경 이전의 체크포인트) — 해당 unit 의 문맥 없이 진행" >&2
    fi
    done_ids="$(jq -c --arg id "$id" '. + [$id]' <<<"$done_ids")"
  done
  [ -z "$stop" ] || return 1   # stop-id 가 unit 목록에 없음
  jq -n --argjson v "$IMPL_CONTEXT_VERSION" --argjson u "$done_ids" --argjson f "$facts" '{version:$v, completed_units:$u, facts:$f}' \
    > "$IMPL_CONTEXT_FILE.tmp" && mv "$IMPL_CONTEXT_FILE.tmp" "$IMPL_CONTEXT_FILE"
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
    impl) printf '%s\n' "$WORK_DIR/implementation.md" "$WORK_DIR/approach.md" "$WORK_DIR/implementation-units.json" "$WORK_DIR/decisions.md";;
  esac
}
# (impl 은 구현 단위 manifest 도 디자이너가 고치는 합의 대상이다 — 러너는 impl 단계 진입 전에 존재를 요구하고, 루프 단독 실행·회귀 픽스처에서는 없어도 된다)
# 지문 세 종류 — 재개 지점은 "누가 무엇을 바꿨는가"에 따라 달라지므로 하나로 합치지 않는다.
#   editable : 디자이너가 고치는 것(consensus_docs_for = 대상 문서 + decisions.md). DESIGNER_PENDING 에서 달라졌으면 디자이너 부분 실행.
#   upstream : 디자이너 입력이지만 이 루프가 고치지 않는 것(design: request.md / impl: request.md + design.md, + target 범위의 [USER-QUESTION]).
#              달라졌으면 저장된 리뷰 자체가 무효 → Round 1 부터.
#   pass     : 합의된 입력 전체(upstream + 대상 문서 + target 범위의 [USER-QUESTION]). PASS 가 현재 입력에 대한 것인지.
# [USER-QUESTION] 의 의존성 범위(scope) — downstream 은 upstream 결정을 상속하지만 upstream 은 downstream 결정을 보지 않는다:
#   design ← [USER-QUESTION][scope=design]
#   impl   ← [USER-QUESTION][scope=design] + [USER-QUESTION][scope=impl]
# 그래서 impl 합의 중 사용자가 검증자 요구를 기각한 결정(scope=impl)은 이미 PASS 한 design 을 무효화하지 않는다.
# scope 없는 옛 형식 `- [USER-QUESTION] ...` 은 어느 단계의 결정인지 코드가 추론할 수 없으므로 여기서 추정하지 않는다 —
# 러너·합의 루프가 LLM 호출 전에 DECISION_SCOPE_REQUIRED 로 멈추고 사용자가 태그를 명시한다(consensus_unscoped_user_decisions).
_fingerprint_files() { # file... → NUL 구분 내용 스트림
  for file in "$@"; do
    [ -f "$file" ] || continue
    printf '%s\0' "$file"; cat "$file"; printf '\0'
  done
}
# decisions.md 에서 scope 없는 옛 형식의 사용자 결정 줄 → stdout (없으면 빈 출력). LLM 호출 전 preflight 가 쓴다.
consensus_unscoped_user_decisions() {
  [ -f "$WORK_DIR/decisions.md" ] || return 0
  grep -nE '^[[:space:]]*- \[USER-QUESTION\]' "$WORK_DIR/decisions.md" | grep -vE '^[0-9]+:[[:space:]]*- \[USER-QUESTION\]\[scope=(design|impl)\]' || true
}
# target 이 보는 사용자 결정 줄만 → NUL 구분 스트림 (지문 입력). [round N] ACCEPT/REJECT 같은 합의 이력은 넣지 않는다.
consensus_user_decisions_for() { # design | impl
  local pattern
  case "$1" in
    design) pattern='^[[:space:]]*- \[USER-QUESTION\]\[scope=design\]';;
    impl) pattern='^[[:space:]]*- \[USER-QUESTION\]\[scope=(design|impl)\]';;
    *) echo "[FAIL] consensus_user_decisions_for: 대상은 design 또는 impl 이어야 함: '$1'" >&2; return 1;;
  esac
  printf 'decisions:USER-QUESTION:%s\0' "$1"
  if [ -f "$WORK_DIR/decisions.md" ]; then grep -E "$pattern" "$WORK_DIR/decisions.md" || true; fi
  printf '\0'
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
    consensus_user_decisions_for "$1"
  } | sha256_stdin
}
# PASS 지문: 합의된 '입력'이 여전히 같은지 확인하는 용도. request/design(/implementation/approach) 전체와
# decisions.md 중 이 target 범위의 사용자 정책 결정([USER-QUESTION][scope=…]) 줄만 — 이후 수정자·디자이너의 판정 기록이
# 쌓이거나 downstream 단계의 사용자 결정이 추가돼도 이전 PASS 가 불필요하게 무효화되지 않게 한다.
# decisions.md 전체를 넣지 않는다(합의 이력이 PASS 를 깨면 안 됨). 반대로 사용자 결정을 아예 빼지도 않는다 — 문서 변경 없이
# 검증자 요구를 기각한 결정이 합의 입력에서 빠지면 옛 PASS 가 그대로 재사용되는 다른 stale-cache 문제가 생긴다.
consensus_pass_fingerprint() { # design | impl
  {
    case "$1" in
      design) _fingerprint_files "$WORK_DIR/request.md" "$WORK_DIR/design.md";;
      impl) _fingerprint_files "$WORK_DIR/request.md" "$WORK_DIR/design.md" "$WORK_DIR/implementation.md" "$WORK_DIR/approach.md" "$WORK_DIR/feature-scope.json" "$WORK_DIR/implementation-units.json";;
    esac
    consensus_user_decisions_for "$1"
  } | sha256_stdin
}
# (impl PASS 지문에 feature-scope.json · implementation-units.json 원본을 넣는다 — 사용자가 범위나 구현 단위를 바꾸면 워커 재진입 전에 impl 재합의를 거치게 한다)
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

# =============================================================
# 구현 후 DOC_GAP 재개 체크포인트 — $WORK_DIR/doc-gap-resume.json
#   impl consensus 는 최초 워커 진입 전의 사전 게이트다. 그 뒤 워커(unit)·리뷰어·review-gap 워커가 발견한 DOC_GAP/USER_DECISION 은
#   impl 재합의로 돌아가지 않고 사용자에게 직접 간다: NEED_USER → 사용자가 decisions.md + approach.md 에 결정 기록 → 검증자·디자이너 없이 워커 → 리뷰.
#   사용자 결정이 그 gap 의 최종 결정이며 validator PASS 와는 다른 provenance 다 — consensus-impl.json 을 위조하거나 PASS 지문을 덮어쓰지 않는다.
#   대신 이 파일이 "이미 PASS 한 impl 문서(base_consensus_review) + 사용자가 답한 gap + 동기화된 approach" 의 지문(resolved_impl_fingerprint)을 들고,
#   러너는 consensus_pass_current impl 이 stale 이어도 그 지문이 현재 입력과 같으면 impl 단계로 되돌리지 않는다(impl_docs_accepted).
#   next_step: WAITING_USER(사용자 답 전 — 모델 호출 0회) → WORKER_PENDING(답·동기화·source tree 확인됨) → REVIEW_PENDING(review-gap 워커 완료) → RESOLVED.
#   gaps[].tag 는 decisions.md 의 답 줄이 달아야 하는 태그다: `- [USER-QUESTION][scope=impl][<tag>] <질문> → <답>`
#     리뷰어 issue  → review-issue=<issue id>          워커 undecided → worker-gap=<unit id | review-gap>#<n>
#   기존 [USER-QUESTION][scope=impl] 의미는 그대로다(impl 지문에 들어가고 design PASS 를 깨지 않는다). 태그가 붙은 줄만 pending gap 의 답으로 인정한다.
# =============================================================
DOC_GAP_RESUME="$WORK_DIR/doc-gap-resume.json"
DOC_GAP_RESUME_VERSION=1
_doc_gap_docs_hash() { _fingerprint_files "$WORK_DIR/implementation.md" "$WORK_DIR/approach.md" "$WORK_DIR/decisions.md" | sha256_stdin; }
_doc_gap_approach_hash() { if [ -f "$WORK_DIR/approach.md" ]; then sha256_stdin < "$WORK_DIR/approach.md"; else printf 'MISSING'; fi; }
# 해결 과정에서 바뀌어도 되는 것은 approach.md 와 decisions.md 의 **추가** 뿐이다. 그 밖의 impl 입력(implementation.md·implementation-units.json·feature-scope.json)은
# gap 기록 시점 그대로여야 한다 — 바뀌었으면 gap 해결이 아니라 새 구현 제안이므로 사용자 해결 경로로 우회할 수 없다(impl 재합의).
_doc_gap_frozen_hash() { _fingerprint_files "$WORK_DIR/implementation.md" "$WORK_DIR/implementation-units.json" "$WORK_DIR/feature-scope.json" | sha256_stdin; }
_doc_gap_decisions_lines() { if [ -f "$WORK_DIR/decisions.md" ]; then wc -l < "$WORK_DIR/decisions.md" | tr -d ' '; else echo 0; fi; }
_doc_gap_decisions_prefix_hash() { # n → decisions.md 앞 n 줄의 해시
  if [ -f "$WORK_DIR/decisions.md" ]; then head -n "$1" "$WORK_DIR/decisions.md" | sha256_stdin; else printf 'MISSING'; fi
}
# 해결 범위 검사: frozen 문서 불변 + decisions.md 는 기록 시점 내용을 prefix 로 유지(append-only). 0 = OK, 1 = 범위 밖 변경.
doc_gap_resolution_scope_ok() {
  [ "$(_doc_gap_frozen_hash)" = "$(doc_gap_field '.frozen_docs_hash')" ] || return 1
  local n; n="$(doc_gap_field '.decisions_lines')"
  [ "$(_doc_gap_decisions_lines)" -ge "$n" ] && [ "$(_doc_gap_decisions_prefix_hash "$n")" = "$(doc_gap_field '.decisions_prefix_hash')" ]
}
_doc_gap_write() { # gaps-json origin review attempt round unit_id result source_tree
  # 전제: 지금 impl 문서가 승인된 상태(최초 validator PASS 유효 또는 직전 gap 의 사용자 해결 지문 유효)여야 gap 을 기록할 수 있다 —
  # 승인되지 않은 문서 위의 gap 은 존재할 수 없고, 이 전제가 provenance 체인(PASS → 해결 → 해결 …)의 귀납 조건이다.
  impl_docs_accepted || { echo "[FAIL] doc-gap 기록 거부 — impl 문서가 승인된 상태가 아님(consensus-impl.json PASS 도 사용자 해결 지문도 현재 입력에 유효하지 않음)" >&2; return 1; }
  local base_review="" base_round=0 base_fp=""
  if [ -f "$WORK_DIR/consensus-impl.json" ]; then
    base_review="$(jq -r '.review // ""' "$WORK_DIR/consensus-impl.json")"; base_round="$(jq -r '.round // 0' "$WORK_DIR/consensus-impl.json")"
    base_fp="$(jq -r '.input_fingerprint // ""' "$WORK_DIR/consensus-impl.json")"
  fi
  local n; n="$(_doc_gap_decisions_lines)"
  jq -n --argjson v "$DOC_GAP_RESUME_VERSION" --argjson gaps "$1" --arg origin "$2" --arg review "$3" --arg attempt "${4:-0}" --arg round "${5:-0}" \
    --arg unit "$6" --arg result "$7" --arg tree "$8" --arg docs "$(_doc_gap_docs_hash)" --arg approach "$(_doc_gap_approach_hash)" \
    --arg base "$base_review" --arg base_round "$base_round" --arg base_fp "$base_fp" --arg gap_fp "$(consensus_pass_fingerprint impl)" \
    --arg frozen "$(_doc_gap_frozen_hash)" --arg dl "$n" --arg dh "$(_doc_gap_decisions_prefix_hash "$n")" --arg now "$(date '+%FT%T%z')" \
    '{version:$v, origin:$origin, next_step:"WAITING_USER", review:$review, attempt:($attempt|tonumber), round:($round|tonumber), unit_id:$unit, result:$result,
      gaps:$gaps, source_tree:$tree, docs_fingerprint:$docs, approach_hash:$approach,
      base_consensus_review:$base, base_consensus_round:($base_round|tonumber), base_pass_fingerprint:$base_fp, gap_impl_fingerprint:$gap_fp,
      frozen_docs_hash:$frozen, decisions_lines:($dl|tonumber), decisions_prefix_hash:$dh,
      resolved_impl_fingerprint:"", recorded_at:$now, updated_at:$now}' > "$DOC_GAP_RESUME.tmp" && mv "$DOC_GAP_RESUME.tmp" "$DOC_GAP_RESUME"
}
# 리뷰어 DOC_GAP issue → 체크포인트(WAITING_USER). 리뷰 루프가 수정자 호출 전에 부른다(같은 리뷰의 FIX_CODE 는 review-gap 워커가 함께 처리).
doc_gap_record_review() { # review attempt round source_tree
  local gaps
  gaps="$(jq -c '[.issues[] | select(.action=="DOC_GAP") | {key:.id, tag:("review-issue=" + .id), question:.user_question, options:.options,
    refs:(.basis_refs + .code_refs), impact:.impact, location:(.code_refs|join(", "))}]' "$1")"
  _doc_gap_write "$gaps" review "$1" "$2" "$3" "" "" "$4"
}
# 워커 undecided(DOC_GAP·USER_DECISION 모두 — 구현 시점의 solution-shape 선택은 둘 다 사용자 판단) → 체크포인트(WAITING_USER).
# unit 호출이면 unit_id, review-gap 워커면 review 경로를 남겨 재개 시 같은 워커를 다시 부른다. key 는 <unit|review-gap>#<n>(스키마에 id 없음).
doc_gap_record_worker() { # result unit_id review source_tree
  local gaps prefix="${2:-review-gap}"
  gaps="$(jq -c --arg p "$prefix" '[.undecided | to_entries[] | ($p + "#" + ((.key + 1)|tostring)) as $k
    | {key:$k, tag:("worker-gap=" + $k), question:.value.decision_needed, options:.value.options, refs:[.value.location], impact:.value.kind, location:.value.location}]' "$1")"
  _doc_gap_write "$gaps" worker "$3" 0 0 "$2" "$1" "$4"
}
doc_gap_field() { jq -r "$1" "$DOC_GAP_RESUME"; }
doc_gap_next_step() { [ -f "$DOC_GAP_RESUME" ] && jq -r --argjson v "$DOC_GAP_RESUME_VERSION" 'if .version==$v then .next_step else "" end' "$DOC_GAP_RESUME" || printf ''; }
doc_gap_pending() { case "$(doc_gap_next_step)" in WAITING_USER|WORKER_PENDING|REVIEW_PENDING) return 0;; *) return 1;; esac; }
doc_gap_set_step() { # next_step [source_tree]
  jq --arg s "$1" --arg t "${2:-}" --arg now "$(date '+%FT%T%z')" '.next_step=$s | (if $t != "" then .source_tree=$t else . end) | .updated_at=$now' \
    "$DOC_GAP_RESUME" > "$DOC_GAP_RESUME.tmp" && mv "$DOC_GAP_RESUME.tmp" "$DOC_GAP_RESUME"
}
_doc_gap_tag_regex() { printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g'; }
# tag 의 답 줄(scope=impl + tag + 비어 있지 않은 답). 빈 답은 답이 아니다.
doc_gap_answer_line() { # tag
  grep -E "^[[:space:]]*- \[USER-QUESTION\]\[scope=impl\]\[$(_doc_gap_tag_regex "$1")\] .*→[[:space:]]*[^[:space:]]" "$WORK_DIR/decisions.md" 2>/dev/null | tail -1
}
doc_gap_unanswered() { # → 답 없는 gap 의 tag, 한 줄 하나
  local tag
  while IFS= read -r tag; do [ -n "$(doc_gap_answer_line "$tag")" ] || printf '%s\n' "$tag"; done < <(doc_gap_field '.gaps[].tag')
}
doc_gap_approach_synced() { [ "$(_doc_gap_approach_hash)" != "$(doc_gap_field '.approach_hash')" ]; }
doc_gap_source_unchanged() { [ "$(snapshot_worktree_tree)" = "$(doc_gap_field '.source_tree')" ]; }
# 체크포인트의 밑바탕이 실제 impl consensus PASS 인가: base_consensus_review 가 지금 consensus-impl.json(포맷·계약 버전·target·PASS)이 가리키는
# 그 round 의 리뷰이고, 그 PASS 의 입력 지문(base_pass_fingerprint)이 체크포인트에 그대로이며, 리뷰 파일이 현재 계약의 실제 PASS 다.
doc_gap_base_consensus_valid() {
  local ck="$WORK_DIR/consensus-impl.json"
  [ -f "$ck" ] || return 1
  jq -e --argjson v "$VALIDATOR_CONTRACT_VERSION" --argjson cv "$CONSENSUS_CHECKPOINT_VERSION" \
    '.version==$cv and .target=="impl" and .contract_version==$v and .next_step=="PASS"' "$ck" >/dev/null 2>&1 || return 1
  [ "$(jq -r '.review // ""' "$ck")" = "$(doc_gap_field '.base_consensus_review')" ] || return 1
  [ -n "$(doc_gap_field '.base_pass_fingerprint')" ] && [ "$(jq -r '.input_fingerprint // ""' "$ck")" = "$(doc_gap_field '.base_pass_fingerprint')" ] || return 1
  [ "$(doc_gap_field '.base_consensus_review')" = "$WORK_DIR/reviews/validator-impl-round-$(printf '%02d' "$(doc_gap_field '.base_consensus_round')").json" ] || return 1
  valid_spec_pass_review "$(doc_gap_field '.base_consensus_review')"
}
# 사용자 답 수리: 답·approach 동기화·source tree 는 호출자가 확인했다. 여기서는 해결 범위(frozen 문서 불변·decisions append-only)와 밑바탕 PASS 를 다시 확인한 뒤
# 지금의 impl 입력 지문(문서 + [scope=impl] 결정)을 사용자 해결 provenance 로 고정하고 WORKER_PENDING 으로. 반환: 0 수리, 2 해결 범위 밖 변경, 1 밑바탕 무효/기록 실패.
doc_gap_accept() {
  doc_gap_base_consensus_valid || return 1
  doc_gap_resolution_scope_ok || return 2
  [ -z "$(doc_gap_unanswered)" ] || return 2
  jq --arg fp "$(consensus_pass_fingerprint impl)" --arg now "$(date '+%FT%T%z')" '.resolved_impl_fingerprint=$fp | .next_step="WORKER_PENDING" | .updated_at=$now' \
    "$DOC_GAP_RESUME" > "$DOC_GAP_RESUME.tmp" && mv "$DOC_GAP_RESUME.tmp" "$DOC_GAP_RESUME"
}
# 사용자 해결 provenance 가 현재 입력에 유효한가 — 다섯 가지를 모두 만족할 때만 true(어느 하나라도 깨지면 일반 impl 재합의로 돌아간다):
#   ① 활성 체크포인트(포맷 버전, 수리된 단계 WORKER_PENDING/REVIEW_PENDING/RESOLVED, 수리 지문 존재)
#   ② 밑바탕이 실제 impl consensus PASS(doc_gap_base_consensus_valid)
#   ③ 모든 pending gap 에 사용자 답이 지금도 존재
#   ④ 해결 범위 안의 변경뿐(frozen 문서 불변, decisions append-only)
#   ⑤ 수리 시점에 고정한 impl 입력 지문 == 현재 impl 입력 지문(그 뒤 approach/decisions 를 또 고쳤으면 무효)
# approach.md 가 바뀌었다는 사실만으로는 어느 조건도 만족하지 않는다 — 수리 지문은 doc_gap_accept 만 쓴다.
doc_gap_resolved_current() {
  [ -f "$DOC_GAP_RESUME" ] || return 1
  jq -e --argjson v "$DOC_GAP_RESUME_VERSION" '.version==$v and (.next_step=="WORKER_PENDING" or .next_step=="REVIEW_PENDING" or .next_step=="RESOLVED") and .resolved_impl_fingerprint!=""' \
    "$DOC_GAP_RESUME" >/dev/null 2>&1 || return 1
  doc_gap_base_consensus_valid || return 1
  [ -z "$(doc_gap_unanswered)" ] || return 1
  doc_gap_resolution_scope_ok || return 1
  [ "$(doc_gap_field '.resolved_impl_fingerprint')" = "$(consensus_pass_fingerprint impl)" ]
}
# 워커 이상으로 가도 되는 impl 문서 상태: 최초 validator PASS 가 현재 입력에 유효하거나, 그 PASS 위에 사용자가 gap 을 해결한 지문이 현재 입력과 같다.
impl_docs_accepted() { consensus_pass_current impl || doc_gap_resolved_current; }
# 사용자 보고문: gap 마다 id·질문·선택지·근거/코드 위치·영향 + 답을 적을 decisions.md 형식.
doc_gap_report() {
  jq -r '.gaps[] | "  [\(.key)] \(.question)\n      선택지: \(.options | join(" | "))\n      근거·코드: \(.refs | join(", "))\n      영향: \(.impact)\n      답 형식: - [USER-QUESTION][scope=impl][\(.tag)] \(.question) → <선택한 option>"' "$DOC_GAP_RESUME"
}
# review-gap 워커 프롬프트 블록: pending gap + 사용자가 decisions.md 에 적은 답 줄.
doc_gap_prompt_block() {
  local tag
  jq -r '.gaps[] | "- gap \(.key) (\(.location)): \(.question)\n  options: \(.options | join(" | "))"' "$DOC_GAP_RESUME"
  printf '\n사용자 결정(decisions.md):\n'
  while IFS= read -r tag; do printf '%s\n' "$(doc_gap_answer_line "$tag")"; done < <(doc_gap_field '.gaps[].tag')
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

# =============================================================
# usage telemetry — $WORK_DIR/usage.jsonl
#   한 행 = CLI invocation 한 번의 관측값(세션 누계 아님). 같은 session 이 여러 행에 나와도 각 행은 독립된 실행 결과다.
#   writer 는 append-only 원시 기록만 한다 — session 별 delta·누적 total·가격 추정은 하지 않는다(집계는 usage_summary 참고).
#   null = "관측 불가"(0 이 아님).
#   input_effective = input_uncached + cache_read + cache_write — 진단용 파생값이지 provider billing 공식 필드가 아니다.
#   cache_read 는 invocation 안의 model turn 들에서 읽힌 cache 누계일 수 있으므로 num_turns 와 함께 해석한다.
#   CLI 종료 성공/실패와 무관하게 파싱 가능한 telemetry 가 있으면 기록한다(exit_code/success). 파싱 불가면 WARN 후 생략 —
#   telemetry 는 best effort 이며 파싱 실패로 작업을 실패시키거나 같은 유료 invocation 을 재실행하지 않는다.
#   비용 필드는 provenance 로 나눈다(섞지 않는다):
#     cost_usd           = provider 가 직접 보고한 비용(claude total_cost_usd). codex 는 항상 null.
#     estimated_cost_usd = 토큰 관측값 × 명시적 가격표(codex_model_pricing) 추정치. claude 는 null. 가격표에 없는 모델은 null.
#     cost_kind          = reported | estimated | unknown,  pricing_basis = 추정에 쓴 가격표 기준(estimated 일 때만).
#   codex(v3): `codex exec --json` 이벤트 JSONL 의 turn.completed.usage 를 invocation 안에서 합산한다 —
#     input_total=Σinput_tokens(cached 포함), cache_read=Σcached_input_tokens, cache_write=Σcache_write_input_tokens, output=Σoutput_tokens,
#     reasoning_output=Σreasoning_output_tokens(output 의 부분집합 — total/cost 에 다시 더하지 않음), num_turns=turn.completed 개수.
#     input_uncached = input_total − cache_read − cache_write (진단 partition), input_effective = 그 셋의 합 = input_total, tokens_total = input_total + output.
#   schema_version 3: codex 행에 input/cache/output/reasoning_output/num_turns 채움, cost_kind/estimated_cost_usd/pricing_basis 추가. usage_summary 는 v2·legacy 행도 읽는다.
# =============================================================
USAGE_SCHEMA_VERSION=3

# codex 모델 가격표 — per 1M tokens USD: "<input> <cached input> <output>". 한 곳에만 둔다(파서 안에 숫자를 흩뿌리지 않는다).
# 기준: 2026-09-23 공개 standard token rate(사용자 제공 표: GPT-5.6/6 Sol·Luna). 실제 청구(월정액·long-context·특수 billing)가 아니라 모델/루프 비용 비교용 추정치다.
# 실제로 쓰는 모델만 둔다 — 여기 없는 모델은 estimated_cost_usd=null, cost_kind=unknown 으로 집계된다(추측 가격 금지).
CODEX_PRICING_BASIS="openai-standard-token-rate-2026-09-23"
codex_model_pricing() { # model → "input cached output" (per 1M USD) / 가격표에 없으면 1
  case "$1" in
    gpt-5.6-sol)  printf '4.00 0.40 20.00';;
    gpt-6-sol)    printf '2.00 0.20 10.00';;
    gpt-5.6-luna) printf '0.20 0.02 1.20';;
    gpt-6-luna)   printf '0.10 0.01 0.50';;
    *) return 1;;
  esac
}

new_invocation_id() { # 호출 직전 생성. 같은 label 재시도를 구분한다
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'
  else printf '%s-%s-%s' "$(date +%s)" "$$" "$RANDOM$RANDOM"; fi
}

# claude --output-format json 결과 파일 → 행 1개.  usage 핵심 필드(usage.input_tokens)가 없으면 경고 후 생략(pipeline 실패 아님).
log_claude_usage() { # label role model result_file [exit_code] [invocation_id]
  local label="$1" role="$2" model="$3" result_file="$4" rc="${5:-0}" inv="${6:-}"
  [ -n "$inv" ] || inv="$(new_invocation_id)"
  if ! jq -e '.usage.input_tokens != null' "$result_file" >/dev/null 2>&1; then
    echo "[WARN] usage 필드 없음 — 기록 생략: $result_file" >&2
    return 0
  fi
  jq -c --arg label "$label" --arg role "$role" --arg model "$model" --arg inv "$inv" \
    --argjson rc "$rc" --argjson v "$USAGE_SCHEMA_VERSION" --arg now "$(date '+%FT%T%z')" '
    {
      schema_version: $v,
      invocation_id: $inv,
      label: $label, role: $role, cli: "claude", model: $model,
      session: (.session_id // null),
      cost_usd: (.total_cost_usd // null),
      cost_kind: (if .total_cost_usd != null then "reported" else "unknown" end),
      estimated_cost_usd: null, pricing_basis: null,
      input_uncached: (.usage.input_tokens // null),
      cache_read: (.usage.cache_read_input_tokens // 0),
      cache_write: (.usage.cache_creation_input_tokens // 0),
      output: (.usage.output_tokens // null),
      reasoning_output: null,
      input_effective: ((.usage.input_tokens // 0) + (.usage.cache_read_input_tokens // 0) + (.usage.cache_creation_input_tokens // 0)),
      tokens_total: null,
      num_turns: (.num_turns // null),
      duration_ms: (.duration_ms // null),
      duration_api_ms: (.duration_api_ms // null),
      exit_code: $rc, success: ($rc == 0),
      source: "claude-result",
      recorded_at: $now
    }' "$result_file" >> "$WORK_DIR/usage.jsonl"
}

# codex exec --json 이벤트 JSONL → 행 1개. invocation 의 모든 turn.completed.usage 를 합산한다(위 v3 매핑). 깨진 줄은 건너뛰고,
# turn.completed 가 하나도 없으면 WARN 후 생략(작업 실패 아님·재실행 없음). plain "tokens used" 텍스트는 더 이상 읽지 않는다.
log_codex_usage() { # label role model events_jsonl [exit_code] [invocation_id]
  local label="$1" role="$2" model="$3" events="$4" rc="${5:-0}" inv="${6:-}" agg rates='null' basis='null'
  [ -n "$inv" ] || inv="$(new_invocation_id)"
  agg="$(jq -R -c 'fromjson? | select(type=="object" and .type=="turn.completed" and (.usage|type)=="object") | .usage' "$events" 2>/dev/null \
    | jq -s -c 'map({i:(.input_tokens // 0), c:(.cached_input_tokens // 0), w:(.cache_write_input_tokens // 0), o:(.output_tokens // 0), r:(.reasoning_output_tokens // 0)})
        | {turns:length, input_total:(map(.i)|add // 0), cache_read:(map(.c)|add // 0), cache_write:(map(.w)|add // 0), output:(map(.o)|add // 0), reasoning:(map(.r)|add // 0)}' 2>/dev/null)"
  if [ -z "$agg" ] || [ "$(printf '%s' "$agg" | jq -r '.turns')" = 0 ]; then
    echo "[WARN] codex 이벤트 JSONL 에 turn.completed usage 없음 — 기록 생략: $events" >&2
    return 0
  fi
  if rates="$(codex_model_pricing "$model")"; then
    rates="$(printf '%s' "$rates" | awk '{printf "{\"input\":%s,\"cached\":%s,\"output\":%s}", $1, $2, $3}')"; basis="\"$CODEX_PRICING_BASIS\""
  else
    rates='null'
  fi
  jq -nc --arg label "$label" --arg role "$role" --arg model "$model" --arg inv "$inv" --argjson a "$agg" --argjson rates "$rates" --argjson basis "$basis" \
    --argjson rc "$rc" --argjson v "$USAGE_SCHEMA_VERSION" --arg now "$(date '+%FT%T%z')" '
    ($a.input_total - $a.cache_read - $a.cache_write) as $uncached
    | (if $rates == null then null
       else ((($a.input_total - $a.cache_read) * $rates.input + $a.cache_read * $rates.cached + $a.output * $rates.output) / 1000000) end) as $est
    | {
      schema_version: $v,
      invocation_id: $inv,
      label: $label, role: $role, cli: "codex", model: $model,
      session: null,
      cost_usd: null,
      cost_kind: (if $est == null then "unknown" else "estimated" end),
      estimated_cost_usd: $est, pricing_basis: $basis,
      input_uncached: $uncached, cache_read: $a.cache_read, cache_write: $a.cache_write, output: $a.output,
      reasoning_output: $a.reasoning,
      input_effective: ($uncached + $a.cache_read + $a.cache_write),
      tokens_total: ($a.input_total + $a.output),
      num_turns: $a.turns, duration_ms: null, duration_api_ms: null,
      exit_code: $rc, success: ($rc == 0),
      source: "codex-events",
      recorded_at: $now
    }' >> "$WORK_DIR/usage.jsonl"
}

# 공통 진입점 — 모든 역할 invocation 이 여기를 지나 기록 누락을 막는다.
log_role_usage() { # cli role model label raw_or_log_path [exit_code] [invocation_id]
  local cli="$1"; shift
  case "$cli" in
    claude) log_claude_usage "$3" "$1" "$2" "$4" "${5:-0}" "${6:-}" ;;
    codex)  log_codex_usage  "$3" "$1" "$2" "$4" "${5:-0}" "${6:-}" ;;
    *) echo "[WARN] usage 기록: 알 수 없는 cli '$cli'" >&2 ;;
  esac
}

# 파생 집계(별도 명령). legacy 행(in/out, v2 codex tokens_total 만 있는 행)도 읽는다. 사용: usage_summary [usage.jsonl]
# 비용은 provenance 별로 따로 낸다 — 섞은 값은 이름에 estimate 를 붙인다:
#   reported_cost_usd        = provider 가 보고한 cost_usd 의 합(claude)            / cost_usd = 같은 값(외부 호환용 옛 이름, 의미 불변)
#   estimated_cost_usd       = 가격표 추정치 estimated_cost_usd 의 합(codex)
#   combined_cost_usd_estimate = reported + estimated (실제 청구액이 아니라 비교용 추정치)
#   cost_unknown_invocations = 둘 다 null 인 행 수(가격표에 없는 codex 모델, telemetry 없는 행 등)
# by_role / by_label / by_session: 어느 역할·호출·Claude 세션이 cache read 를 만드는지 보는 그룹 합계(같은 지표 세트).
# cache_read_per_turn = cache_read 합 / num_turns 합(num_turns 를 보고한 행만) — turn 당 다시 읽히는 문맥 크기의 근사치.
# num_turns 가 하나도 없으면 null. 임계치·자동 판단은 두지 않는다(관측값만 제공).
usage_summary() {
  local f="${1:-$WORK_DIR/usage.jsonl}"
  [ -s "$f" ] || { echo '{}'; return 0; }
  jq -s '
    def metrics: {
      invocations: length,
      cost_usd: (map(.cost_usd // 0) | add),
      reported_cost_usd: (map(.cost_usd // 0) | add),
      estimated_cost_usd: (map(.estimated_cost_usd // 0) | add),
      combined_cost_usd_estimate: (map((.cost_usd // 0) + (.estimated_cost_usd // 0)) | add),
      cost_unknown_invocations: (map(select(.cost_usd == null and .estimated_cost_usd == null)) | length),
      cache_read: (map(.cache_read // 0) | add),
      num_turns: (map(.num_turns // 0) | add),
      output: (map(.output // .out // 0) | add),
      reasoning_output: (map(.reasoning_output // 0) | add),
      cache_read_per_turn: (
        (map(select(.num_turns != null))) as $t
        | if ($t | map(.num_turns) | add // 0) > 0
          then (($t | map(.cache_read // 0) | add) / ($t | map(.num_turns) | add))
          else null end)
    };
    def grouped(key): group_by(key) | map({key: (.[0] | key), value: metrics}) | from_entries;
    metrics + {
      input_uncached: (map(.input_uncached // .in // 0) | add),
      cache_write: (map(.cache_write // 0) | add),
      tokens_total_codex: (map(select(.cli == "codex") | .tokens_total // 0) | add),
      by_role: grouped(.role // "legacy"),
      by_label: grouped(.label // "legacy"),
      by_session: grouped(.session // "none")
    }' "$f"
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
