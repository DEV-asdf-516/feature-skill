#!/usr/bin/env bash
# =============================================================
# 문서 합의 루프: Fable(문서 소유자) ↔ Sol(검증) 수렴 강제
# 파일 경로: .claude/skills/feature/scripts/consensus-loop.sh
# 사용법: consensus-loop.sh [design|impl]  (저장소 루트에서 실행)
#   design: $WORK_DIR/design.md 합의 (Fable이 초안을 먼저 작성)
#   impl  : $WORK_DIR/implementation.md 합의 (design 합의 후 실행)
# 종료 코드: 0=PASS 수렴, 2=라운드 초과/교착, 1=환경 오류
# 리뷰는 MAX_SPEC_ROUNDS+1 회 — 마지막 수정도 반드시 재검증한다.
# =============================================================
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.sh"

# 진행 로그를 $WORK_DIR/live.log 에 실시간 누적 (tail -f 로 관찰 가능)
mkdir -p "$WORK_DIR"
exec > >(tee -a "$WORK_DIR/live.log") 2>&1
echo "[$(date '+%F %T')] consensus-loop ${1:-design} 시작"

TARGET="${1:-design}"
case "$TARGET" in
  design)
    TARGET_DOC="$WORK_DIR/design.md"
    SOL_PROMPT_FILE="$SKILL_DIR/prompts/sol-review-design.md"
    FABLE_PROMPT_FILE="$SKILL_DIR/prompts/fable-revise-design.md"
    ;;
  impl)
    TARGET_DOC="$WORK_DIR/implementation.md"
    SOL_PROMPT_FILE="$SKILL_DIR/prompts/sol-review-impl.md"
    FABLE_PROMPT_FILE="$SKILL_DIR/prompts/fable-revise-impl.md"
    ;;
  *) echo "[FAIL] 대상은 design 또는 impl 이어야 함: '$TARGET'" >&2; exit 1;;
esac

# ---------- 사전 점검 (환경이 틀리면 진행 금지) ----------
for bin in "$CLAUDE_BIN" "$CODEX_BIN" jq uuidgen envsubst; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[FAIL] '$bin' 미설치. 중단." >&2; exit 1; }
done
[ -f "$TARGET_DOC" ] || { echo "[FAIL] $TARGET_DOC 없음. Fable이 초안을 먼저 작성해야 함." >&2; exit 1; }
if [ "$TARGET" = "impl" ]; then
  [ -f "$WORK_DIR/design.md" ] || { echo "[FAIL] $WORK_DIR/design.md 없음. 설계 합의가 먼저다." >&2; exit 1; }
fi
for prompt_file in "$SOL_PROMPT_FILE" "$FABLE_PROMPT_FILE"; do
  [ -f "$prompt_file" ] || { echo "[FAIL] 프롬프트 없음: $prompt_file" >&2; exit 1; }
done
mkdir -p "$WORK_DIR/reviews"
touch "$WORK_DIR/decisions.md"

SCHEMA_FILE="$SKILL_DIR/schemas/spec-review.schema.json"
[ -f "$SCHEMA_FILE" ] || { echo "[FAIL] 스키마 없음: $SCHEMA_FILE" >&2; exit 1; }
prev_fingerprint=""
prev_review=""

for round in $(seq 1 $((MAX_SPEC_ROUNDS + 1))); do
  tag=$(printf '%02d' "$round")
  review="$WORK_DIR/reviews/sol-$TARGET-round-$tag.json"
  echo "=== [$TARGET] Round $round/$((MAX_SPEC_ROUNDS + 1)) : Sol 검토 ==="

  prev_context=""
  if [ -n "$prev_review" ]; then
    prev_context="직전 라운드 리뷰는 $prev_review 에 있다. 같은 문제를 다시 지적할 때는 반드시 같은 id를 재사용하고, 새 문제에만 새 id를 붙여라. $WORK_DIR/decisions.md 에서 REJECT 된 이슈는 새로운 논거가 없으면 재제기하지 마라."
  fi

  # ---------- Sol (Codex) 검토: 읽기 전용, 스키마 강제 JSON ----------
  sol_prompt=$(WORK_DIR="$WORK_DIR" PREV_CONTEXT="$prev_context" \
    render_prompt "$SOL_PROMPT_FILE" '${WORK_DIR} ${PREV_CONTEXT}')
  "$CODEX_BIN" exec -m "$SOL_MODEL" -c "model_reasoning_effort=\"$SOL_EFFORT\"" --sandbox read-only \
    --output-schema "$SCHEMA_FILE" -o "$review" \
    "$sol_prompt" \
    > "$review.log" 2>&1 || { echo "[FAIL] codex 실행 실패 (모델 '$SOL_MODEL' 확인)"; tail -20 "$review.log" >&2; exit 1; }

  verdict=$(jq -er '.verdict' "$review") || { echo "[FAIL] 리뷰 JSON이 스키마와 다름: $review" >&2; exit 1; }
  ids=$(jq -r '[.blocking_issues[].id] | sort | join(",")' "$review")
  fingerprint=$(jq -Sc '[.blocking_issues[] | {id, problem, required_change}] | sort_by(.id)' "$review")
  echo "Sol verdict: $verdict / blocking: ${ids:-없음}"

  if [ "$verdict" = "PASS" ] && [ -z "$ids" ]; then
    echo "=== [$TARGET] 문서 합의 완료 (round $round) ==="
    jq -n --arg t "$TARGET" --arg r "$round" '{phase:$t, status:"PASS", rounds:($r|tonumber)}' > "$WORK_DIR/state.json"
    exit 0
  fi

  # 교착 감지: 이슈 '내용'까지 동일한 집합이 2라운드 연속이면 사람에게 에스컬레이션
  # (같은 id라도 problem/required_change가 달라지면 진전 중으로 본다)
  if [ -n "$ids" ] && [ "$fingerprint" = "$prev_fingerprint" ]; then
    echo "[STOP] 동일 이슈($ids)가 내용 변화 없이 2라운드 연속 반복됨. 사용자 판단 필요." >&2
    jq -n --arg t "$TARGET" --arg i "$ids" '{phase:$t, status:"DEADLOCK", issues:$i}' > "$WORK_DIR/state.json"
    exit 2
  fi
  prev_fingerprint="$fingerprint"
  prev_review="$review"

  # 마지막 검증 라운드였다면 수정 없이 종료 (수정은 항상 재검증 대상이어야 함)
  [ "$round" -le "$MAX_SPEC_ROUNDS" ] || break

  # ---------- Fable 응답: 각 이슈 ACCEPT/REJECT + 문서 갱신 ----------
  # 라운드 간 같은 세션을 이어가 저장소 재탐색 없이 프롬프트 캐시를 활용
  echo "--- Fable 이 리뷰를 반영/반박합니다 ---"
  fable_result="$WORK_DIR/reviews/fable-$TARGET-round-$tag.raw"
  session_args=$(claude_session_args fable-doc)
  fable_prompt=$(REVIEW_FILE="$review" WORK_DIR="$WORK_DIR" ROUND="$round" \
    render_prompt "$FABLE_PROMPT_FILE" '${REVIEW_FILE} ${WORK_DIR} ${ROUND}')
  "$CLAUDE_BIN" -p $session_args --model "$FABLE_MODEL" --effort "$CLAUDE_EFFORT" \
    --permission-mode acceptEdits --output-format json \
    "$fable_prompt" \
    > "$fable_result" || { echo "[FAIL] claude 실행 실패 (모델 '$FABLE_MODEL' 확인)"; exit 1; }
  claude_session_commit fable-doc
  log_claude_usage "$TARGET-fable-round-$tag" "$fable_result"
done

echo "[STOP] $MAX_SPEC_ROUNDS 라운드 내 수렴 실패. 쟁점을 사용자에게 보고하고 중단." >&2
jq -n --arg t "$TARGET" '{phase:$t, status:"MAX_ROUNDS_EXCEEDED"}' > "$WORK_DIR/state.json"
exit 2
