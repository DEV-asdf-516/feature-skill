#!/usr/bin/env bash
# =============================================================
# 문서 합의 루프: 디자이너(문서 소유자) ↔ 검증자 수렴 강제
# 파일 경로: .claude/skills/feature/scripts/consensus-loop.sh
# 사용법: consensus-loop.sh [design|impl]  (저장소 루트에서 실행)
#   design: $WORK_DIR/design.md 합의 (오케스트레이터가 초안을 먼저 작성)
#   impl  : $WORK_DIR/implementation.md 합의 (design 합의 후 실행)
# 종료 코드: 0=PASS 수렴, 2=라운드 초과/교착, 1=환경 오류
# 리뷰는 MAX_SPEC_ROUNDS+1 회 — 마지막 수정도 반드시 재검증한다.
# =============================================================
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.sh"
PROJECT_CONVENTIONS="$(load_project_conventions)"
designer_rule_args=()
[ -z "$PROJECT_CONVENTIONS" ] || designer_rule_args=(--append-system-prompt "$PROJECT_CONVENTIONS")

# stdin 원천 차단 — codex/claude 비대화형 실행은 stdin이 열린 채 상속되면
# EOF 를 기다리며 무기한 대기한다. 호출부가 어떤 형태로 이 스크립트를 묶어
# 실행하든(heredoc 조합, 백그라운드 등) 여기서 닫아 하위 실행 전체를 보호한다.
exec </dev/null

# 진행 로그를 $WORK_DIR/live.log 에 실시간 누적 (tail -f 로 관찰 가능)
mkdir -p "$WORK_DIR"
exec > >(tee -a "$WORK_DIR/live.log") 2>&1
echo "[$(date '+%F %T')] consensus-loop ${1:-design} 시작"

TARGET="${1:-design}"
case "$TARGET" in
  design)
    TARGET_DOC="$WORK_DIR/design.md"
    VALIDATOR_PROMPT_FILE="$SKILL_DIR/prompts/validator-review-design.md"
    DESIGNER_PROMPT_FILE="$SKILL_DIR/prompts/designer-revise-design.md"
    ;;
  impl)
    TARGET_DOC="$WORK_DIR/implementation.md"
    VALIDATOR_PROMPT_FILE="$SKILL_DIR/prompts/validator-review-impl.md"
    DESIGNER_PROMPT_FILE="$SKILL_DIR/prompts/designer-revise-impl.md"
    ;;
  *) echo "[FAIL] 대상은 design 또는 impl 이어야 함: '$TARGET'" >&2; exit 1;;
esac

# ---------- 사전 점검 (환경이 틀리면 진행 금지) ----------
for bin in "$CLAUDE_BIN" "$CODEX_BIN" jq uuidgen envsubst; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[FAIL] '$bin' 미설치. 중단." >&2; exit 1; }
done
[ -f "$TARGET_DOC" ] || { echo "[FAIL] $TARGET_DOC 없음. 오케스트레이터가 초안을 먼저 작성해야 함." >&2; exit 1; }
if [ "$TARGET" = "impl" ]; then
  [ -f "$WORK_DIR/design.md" ] || { echo "[FAIL] $WORK_DIR/design.md 없음. 설계 합의가 먼저다." >&2; exit 1; }
fi
for prompt_file in "$VALIDATOR_PROMPT_FILE" "$DESIGNER_PROMPT_FILE"; do
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
  review="$WORK_DIR/reviews/validator-$TARGET-round-$tag.json"
  echo "=== [$TARGET] Round $round/$((MAX_SPEC_ROUNDS + 1)) : 검증자 검토 ==="

  prev_context=""
  if [ -n "$prev_review" ]; then
    prev_context="직전 라운드 리뷰는 $prev_review 에 있다. 같은 문제를 다시 지적할 때는 반드시 같은 id를 재사용하고, 새 문제에만 새 id를 붙여라. $WORK_DIR/decisions.md 에서 REJECT 된 이슈는 새로운 논거가 없으면 재제기하지 마라."
  fi

  # ---------- 검증자(codex) 검토: 읽기 전용, 스키마 강제 JSON ----------
  validator_prompt=$(PROJECT_CONVENTIONS="$PROJECT_CONVENTIONS" WORK_DIR="$WORK_DIR" PREV_CONTEXT="$prev_context" \
    render_prompt "$VALIDATOR_PROMPT_FILE" '${PROJECT_CONVENTIONS} ${WORK_DIR} ${PREV_CONTEXT}')
  "$CODEX_BIN" exec -m "$VALIDATOR_MODEL" -c "model_reasoning_effort=\"$VALIDATOR_EFFORT\"" --sandbox read-only \
    --output-schema "$SCHEMA_FILE" -o "$review" \
    "$validator_prompt" \
    > "$review.log" 2>&1 || { echo "[FAIL] codex 실행 실패 (모델 '$VALIDATOR_MODEL' 확인)"; tail -20 "$review.log" >&2; exit 1; }

  verdict=$(jq -er '.verdict' "$review") || { echo "[FAIL] 리뷰 JSON이 스키마와 다름: $review" >&2; exit 1; }
  ids=$(jq -r '[.blocking_issues[].id] | sort | join(",")' "$review")
  fingerprint=$(jq -Sc '[.blocking_issues[] | {id, problem, required_change}] | sort_by(.id)' "$review")
  echo "검증자 verdict: $verdict / blocking: ${ids:-없음}"
  jq -r '.blocking_issues[]? | "  [\(.id)] \(.problem)\n      → 요구: \(.required_change)"' "$review"
  jq -r '.non_blocking_notes[]? | "  (참고) \(.)"' "$review"

  # 모순 응답은 재시도 없이 즉시 실패 — 스키마만 통과했다고 올바른 리뷰로 간주하지 않는다
  if { [ "$verdict" = "PASS" ] && [ -n "$ids" ]; } \
     || { [ "$verdict" = "BLOCK" ] && [ -z "$ids" ]; }; then
    echo "[FAIL] 모순 리뷰 응답: verdict=$verdict / blocking=${ids:-0건} — 응답 오류로 중단: $review" >&2
    exit 1
  fi

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

  # ---------- 디자이너 응답: 각 이슈 ACCEPT/REJECT + 문서 갱신 ----------
  # 라운드 간 같은 세션을 이어가 저장소 재탐색 없이 프롬프트 캐시를 활용
  echo "--- 디자이너가 리뷰를 반영/반박합니다 ---"
  decisions_lines_before=$(wc -l < "$WORK_DIR/decisions.md")
  designer_result="$WORK_DIR/reviews/designer-$TARGET-round-$tag.raw"
  session_args=$(claude_session_args designer-doc)
  designer_prompt=$(REVIEW_FILE="$review" WORK_DIR="$WORK_DIR" ROUND="$round" \
    render_prompt "$DESIGNER_PROMPT_FILE" '${REVIEW_FILE} ${WORK_DIR} ${ROUND}')
  "$CLAUDE_BIN" -p $session_args --model "$DESIGNER_MODEL" --effort "$DESIGNER_EFFORT" \
    "${designer_rule_args[@]}" \
    --permission-mode acceptEdits --output-format json \
    "$designer_prompt" \
    > "$designer_result" || { echo "[FAIL] claude 실행 실패 (모델 '$DESIGNER_MODEL' 확인)"; exit 1; }
  claude_session_commit designer-doc
  log_claude_usage "$TARGET-designer-round-$tag" "$designer_result"
  echo "--- 디자이너 판정 (decisions.md 신규 기록) ---"
  tail -n +"$((decisions_lines_before + 1))" "$WORK_DIR/decisions.md" | sed 's/^/  /'
done

echo "[STOP] $MAX_SPEC_ROUNDS 라운드 내 수렴 실패. 쟁점을 사용자에게 보고하고 중단." >&2
jq -n --arg t "$TARGET" '{phase:$t, status:"MAX_ROUNDS_EXCEEDED"}' > "$WORK_DIR/state.json"
exit 2
