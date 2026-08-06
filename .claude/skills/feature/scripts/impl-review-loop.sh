#!/usr/bin/env bash
# =============================================================
# 구현 리뷰 루프: Sonnet(리뷰 + 직접 개선) 수렴 강제
# 파일 경로: .claude/skills/feature/scripts/impl-review-loop.sh
# 사용법: impl-review-loop.sh  (메인 작성자 Luna의 구현이 끝난 뒤에만 실행)
# 종료 코드: 0=승인, 2=라운드 초과, 1=환경 오류
# 각 라운드 = 읽기 전용 리뷰 → (이슈 있으면) Sonnet이 직접 수정 → 다음
# 라운드에서 재검증. 리뷰는 MAX_IMPL_ROUNDS+1 회 — 마지막 수정도 재검증한다.
# =============================================================
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.sh"

# 진행 로그를 $WORK_DIR/live.log 에 실시간 누적 (tail -f 로 관찰 가능)
mkdir -p "$WORK_DIR"
exec > >(tee -a "$WORK_DIR/live.log") 2>&1
echo "[$(date '+%F %T')] impl-review-loop 시작"

for bin in "$CLAUDE_BIN" jq uuidgen envsubst; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[FAIL] '$bin' 미설치. 중단." >&2; exit 1; }
done
CORE_RULES="$(cat "$CORE_RULES_FILE")"
SCHEMA_FILE="$SKILL_DIR/schemas/impl-review.schema.json"
[ -f "$SCHEMA_FILE" ] || { echo "[FAIL] 스키마 없음: $SCHEMA_FILE" >&2; exit 1; }
for prompt_file in sonnet-review.md sonnet-fix.md; do
  [ -f "$SKILL_DIR/prompts/$prompt_file" ] || { echo "[FAIL] 프롬프트 없음: $SKILL_DIR/prompts/$prompt_file" >&2; exit 1; }
done

# Phase 4 재진입마다 attempt 디렉터리를 새로 잡아 이전 승인·리뷰 증거를 보존한다
attempt=1
while [ -d "$WORK_DIR/reviews/impl-attempt-$(printf '%02d' "$attempt")" ]; do
  attempt=$((attempt + 1))
done
attempt_tag=$(printf '%02d' "$attempt")
ATTEMPT_DIR="$WORK_DIR/reviews/impl-attempt-$attempt_tag"
mkdir -p "$ATTEMPT_DIR"
echo "리뷰 산출물: $ATTEMPT_DIR (attempt $attempt)"

for round in $(seq 1 $((MAX_IMPL_ROUNDS + 1))); do
  tag=$(printf '%02d' "$round")
  review="$ATTEMPT_DIR/sonnet-round-$tag.json"
  echo "=== Impl Round $round/$((MAX_IMPL_ROUNDS + 1)) : Sonnet 리뷰 ==="

  # ---------- 리뷰 단계: 판정 무결성을 위해 이 실행은 읽기 도구만 허용 ----------
  # (리뷰 실행이 코드를 만질 수 있으면 "고치면서 동시에 APPROVE"가 가능해져
  #  모든 수정은 다음 라운드에서 재검증된다는 불변식이 깨진다)
  diff_file="$ATTEMPT_DIR/diff-round-$tag.patch"
  status_file="$ATTEMPT_DIR/status-round-$tag.txt"
  git diff HEAD -- > "$diff_file"
  git status --short > "$status_file"

  review_session=$(claude_session_args sonnet-review)
  "$CLAUDE_BIN" -p $review_session --model "$SONNET_MODEL" --effort "$CLAUDE_EFFORT" \
    --append-system-prompt "$CORE_RULES" \
    --tools "Read,Grep,Glob" \
    --disallowedTools "Bash,Edit,Write,NotebookEdit" \
    --json-schema "$(cat "$SCHEMA_FILE")" --output-format json \
    "$(DIFF_FILE="$diff_file" STATUS_FILE="$status_file" WORK_DIR="$WORK_DIR" \
      render_prompt "$SKILL_DIR/prompts/sonnet-review.md" '${DIFF_FILE} ${STATUS_FILE} ${WORK_DIR}')" \
    > "$review.raw" || { echo "[FAIL] claude 실행 실패 (모델 '$SONNET_MODEL' 확인)"; exit 1; }
  claude_session_commit sonnet-review
  log_claude_usage "impl-review-a$attempt_tag-round-$tag" "$review.raw"

  jq -e '.structured_output' "$review.raw" > "$review" \
    || { echo "[FAIL] 리뷰 JSON이 스키마와 다름: $review.raw" >&2; exit 1; }
  verdict=$(jq -er '.verdict' "$review")
  issue_count=$(jq '.issues | length' "$review")
  echo "Sonnet verdict: $verdict / issues: $issue_count"

  # 승인은 verdict 와 issues 가 일치할 때만 인정 (API가 조건부 스키마를 막아 여기서 강제)
  if [ "$verdict" = "APPROVE" ] && [ "$issue_count" -eq 0 ]; then
    echo "=== 구현 리뷰 승인 (round $round) ==="
    jq -n --arg r "$round" --arg a "$attempt" '{phase:"impl", status:"APPROVE", rounds:($r|tonumber), attempt:($a|tonumber)}' > "$WORK_DIR/state.json"
    exit 0
  fi
  if [ "$verdict" = "APPROVE" ]; then
    echo "[WARN] APPROVE 인데 issues $issue_count 건 존재 — 모순 응답이라 REQUEST_CHANGES 로 취급." >&2
  fi

  # 마지막 검증 라운드였다면 수정 없이 종료 (수정은 항상 재검증 대상이어야 함)
  [ "$round" -le "$MAX_IMPL_ROUNDS" ] || break

  # ---------- 수정 단계: Sonnet 이 자신의 리뷰 이슈를 직접 반영 ----------
  # 리뷰와 다른 세션을 이어간다 — 실행 비용은 캐시로 줄이되 승인 독립성은 유지
  echo "--- Sonnet 이 이슈를 직접 수정합니다 ---"
  fix_result="$ATTEMPT_DIR/sonnet-fix-round-$tag.raw"
  fix_session=$(claude_session_args sonnet-fix)
  "$CLAUDE_BIN" -p $fix_session --model "$SONNET_MODEL" --effort "$CLAUDE_EFFORT" --permission-mode acceptEdits \
    --append-system-prompt "$CORE_RULES" \
    --allowedTools "Bash" --output-format json \
    "$(REVIEW_FILE="$review" WORK_DIR="$WORK_DIR" TEST_CMD="$TEST_CMD" \
      render_prompt "$SKILL_DIR/prompts/sonnet-fix.md" '${REVIEW_FILE} ${WORK_DIR} ${TEST_CMD}')" \
    > "$fix_result" || { echo "[FAIL] claude 실행 실패 (모델 '$SONNET_MODEL' 확인)"; exit 1; }
  claude_session_commit sonnet-fix
  log_claude_usage "impl-fix-a$attempt_tag-round-$tag" "$fix_result"
done

echo "[STOP] $MAX_IMPL_ROUNDS 라운드 내 승인 실패. 남은 이슈를 사용자에게 보고." >&2
jq -n --arg a "$attempt" '{phase:"impl", status:"MAX_ROUNDS_EXCEEDED", attempt:($a|tonumber)}' > "$WORK_DIR/state.json"
exit 2
