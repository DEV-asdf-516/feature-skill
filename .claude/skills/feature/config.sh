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
DESIGNER_MODEL="claude-fable-5.1"   # 오케스트레이터 겸 문서 소유자 (claude CLI)
DESIGNER_EFFORT="low"
VALIDATOR_MODEL="gpt-5.6-sol"     # 명세 검증자 (codex CLI)
VALIDATOR_EFFORT="high"   # 게이트 모드(구현을 막을 최소 사유만 판정). 전체 보안·아키텍처 감사는 별도 수동 audit 에서만 high
WORKER_MODEL="gpt-5.6-luna"       # 구현 담당 (codex CLI)
WORKER_EFFORT="max"
REVIEWER_MODEL="claude-sonnet-5"  # 구현 리뷰 담당 (claude CLI)
REVIEWER_EFFORT="medium"
FIXER_MODEL="claude-sonnet-5"     # 리뷰 이슈 수정 담당 (claude CLI)
FIXER_EFFORT="medium"

# --- CLI 실행 형식 ---
# Claude Code 비대화형 실행. 필요 시 --permission-mode 조정.
CLAUDE_BIN="claude"
CODEX_BIN="codex"

# --- 검증자 계약 버전 ---
# 검증자 프롬프트·spec-review 스키마·러너의 연계 검사 중 하나라도 바뀌면 올린다.
# 러너는 이 값과 다른 이전 PASS 파일을 무효로 보고 검증 라운드를 다시 돈다(--new 불필요).
VALIDATOR_CONTRACT_VERSION=3

# --- 리뷰어 계약 버전 ---
# 리뷰어 프롬프트·impl-review 스키마·impl-review-loop 의 연계 검사 중 하나라도 바뀌면 올린다.
# 루프는 리뷰 JSON 의 schema_version 이 이 값과 다르면 응답 오류로 중단한다.
REVIEWER_CONTRACT_VERSION=6

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
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CORE_RULES_FILE="$PROJECT_ROOT/.claude/hooks/core_rules.md" # 워커 전용 필수 규칙
CONVENTIONS_FILE="$PROJECT_ROOT/conventions.md" # 선택 파일: 없으면 조용히 생략

# =============================================================
# 헬퍼
# =============================================================

# 페르소나 템플릿(prompts/*.md) 렌더링. 지정한 변수만 치환해 본문의 다른 $ 문자를 보존한다.
# 사용: VAR1=... VAR2=... render_prompt <템플릿 파일> '${VAR1} ${VAR2}'
render_prompt() {
  envsubst "$2" < "$1"
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
  local idx; idx="$(cd "$WORK_DIR" && pwd)/.snapshot-index"
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

# 마지막 APPROVE 시점 지문과 현재 작업 트리를 비교. 다르면 승인 무효(APPROVAL_STALE).
# Phase 4 진입 직전과 커밋 위임 직전, 두 지점에서 반드시 호출한다.
verify_approved_fingerprint() {
  local fingerprint_file="$WORK_DIR/approved.fingerprint"
  [ -f "$fingerprint_file" ] || { echo "[FAIL] 승인 지문 없음: $fingerprint_file — Phase 3 승인이 선행돼야 함." >&2; return 1; }
  local approved_hash current_hash
  approved_hash="$(cat "$fingerprint_file")"
  current_hash="$(compute_worktree_fingerprint)"
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
[ -f "$CORE_RULES_FILE" ] || { echo "[FAIL] core_rules.md 없음: $CORE_RULES_FILE" >&2; exit 1; }
