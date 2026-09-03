#!/usr/bin/env bash
# =============================================================
# 문서 합의 루프: 디자이너(문서 소유자) ↔ 검증자 수렴 강제
# 파일 경로: .claude/skills/feature/scripts/consensus-loop.sh
# 사용법: consensus-loop.sh [design|impl]  (저장소 루트에서 실행)
#   design: $WORK_DIR/design.md 합의 (오케스트레이터가 초안을 먼저 작성)
#   impl  : $WORK_DIR/implementation.md(무엇) + approach.md(어떻게) 합의 (design 합의 후 실행)
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
# 부모 러너가 이미 live.log를 tee 중이면 중복 기록하지 않는다.
# 단독 실행할 때만 이 스크립트가 직접 tee를 연다.
if [ -z "${FEATURE_LIVE_TEE:-}" ]; then
  exec > >(tee -a "$WORK_DIR/live.log") 2>&1
fi
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
  [ -f "$WORK_DIR/approach.md" ] || { echo "[FAIL] $WORK_DIR/approach.md 없음. 구현 문서는 implementation.md(무엇)와 approach.md(어떻게) 두 개가 모두 있어야 한다." >&2; exit 1; }
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
prev_snapshot=""
# Round 2+ 입력용: 디자이너 수정 전 문서를 보관하고, 다음 라운드에 현재 문서와의 diff 를 검증자에게 준다
consensus_docs() {
  case "$TARGET" in
    design) printf '%s\n' "$WORK_DIR/design.md";;
    impl) printf '%s\n' "$WORK_DIR/implementation.md" "$WORK_DIR/approach.md";;
  esac
}
snapshot_docs() { # dir
  mkdir -p "$1"
  consensus_docs | while IFS= read -r doc; do cp "$doc" "$1/$(basename "$doc")"; done
}
snapshot_changed_docs() { # dir → 스냅샷 대비 내용이 바뀐 문서의 basename 목록 (변경 없으면 빈 출력)
  consensus_docs | while IFS= read -r doc; do
    cmp -s "$1/$(basename "$doc")" "$doc" || basename "$doc"
  done
}
snapshot_docs_diff() { # dir → stdout (unified diff, 검증자 입력·사람 확인용. 변경 없으면 빈 출력)
  consensus_docs | while IFS= read -r doc; do
    diff -u "$1/$(basename "$doc")" "$doc" || true
  done
}

for round in $(seq 1 $((MAX_SPEC_ROUNDS + 1))); do
  tag=$(printf '%02d' "$round")
  review="$WORK_DIR/reviews/validator-$TARGET-round-$tag.json"
  echo "=== [$TARGET] Round $round/$((MAX_SPEC_ROUNDS + 1)) : 검증자 검토 ==="

  # Round 1 은 입장 조건을 만족하는 문제를 전부 낸다. Round 2+ 는 재감사가 아니라 종결 검토다.
  prev_context="이번은 Round 1 이다. 입장 조건을 만족하는 문제를 이번 라운드에 전부 내라 — 다음 라운드로 미루지 마라. 모든 이슈의 origin 은 ROUND_1."
  if [ -n "$prev_review" ]; then
    docs_diff="$WORK_DIR/reviews/docs-diff-$TARGET-round-$tag.diff"
    snapshot_docs_diff "$prev_snapshot" > "$docs_diff" || true
    prev_context="이번은 Round $round(종결 검토)다. 입력: 직전 blocking issue JSON = $prev_review, 디자이너의 ACCEPT/REJECT 판정 = $WORK_DIR/decisions.md, 직전 라운드 이후 문서 diff = $docs_diff, 현재 문서. 이번 라운드에서 허용되는 blocking 은 세 종류뿐이며 origin 으로 표시한다: UNRESOLVED_PREVIOUS(직전 이슈가 미해결, previous_issue_id 에 같은 id) / REVISION_REGRESSION(직전 수정이 새로 만든 직접 회귀, revision_ref 에 diff 위치) / NEWLY_EXPOSED_BY_REVISION(Round 1 에는 없던 정보가 수정으로 처음 드러남, revision_ref 필수). 직전 라운드 당시 이미 볼 수 있었던 별개의 문제는 제기하지 마라. 해결된 이슈는 제외한다. REJECT 된 이슈는 새로운 근거 위치가 없으면 재제기하지 마라."
  fi

  # ---------- 검증자(codex) 검토: 읽기 전용, 스키마 강제 JSON ----------
  validator_prompt=$(PROJECT_CONVENTIONS="$PROJECT_CONVENTIONS" WORK_DIR="$WORK_DIR" PREV_CONTEXT="$prev_context" \
    render_prompt "$VALIDATOR_PROMPT_FILE" '${PROJECT_CONVENTIONS} ${WORK_DIR} ${PREV_CONTEXT}')
  "$CODEX_BIN" exec -m "$VALIDATOR_MODEL" -c "model_reasoning_effort=\"$VALIDATOR_EFFORT\"" --sandbox read-only \
    --output-schema "$SCHEMA_FILE" -o "$review" \
    "$validator_prompt" \
    > "$review.log" 2>&1 || { echo "[FAIL] codex 실행 실패 (모델 '$VALIDATOR_MODEL' 확인)"; tail -20 "$review.log" >&2; exit 1; }

  verdict=$(jq -er '.verdict' "$review") || { echo "[FAIL] 리뷰 JSON이 스키마와 다름: $review" >&2; exit 1; }
  jq -e --argjson v "$VALIDATOR_CONTRACT_VERSION" '.schema_version==$v' "$review" >/dev/null 2>&1 \
    || { echo "[FAIL] 리뷰 schema_version 이 현재 계약($VALIDATOR_CONTRACT_VERSION)과 다름: $review" >&2; exit 1; }
  # 스키마가 표현 못 하는 조건부 필수·상호 배제·연계를 여기서 강제 — 근거 없는 blocker 는 응답 오류다.
  # 러너가 보장하는 것은 origin 의 형식과 참조 대상(직전 이슈 id, diff 에 실제로 바뀐 파일)의 존재까지다.
  # 수정과 신규 blocker 사이의 의미적 인과관계는 tests/validator-cases.md 의 감도 회귀 세트로 본다.
  prev_ids_json='[]'; changed_files_json='[]'
  if [ -n "$prev_review" ]; then
    prev_ids_json=$(jq -c '[.blocking_issues[].id]' "$prev_review")
    # diff 헤더를 파싱하지 않는다 — 빈 diff 에서 grep 이 실패해 pipefail 로 값이 깨지고, 본문의 '+++' 행을 오인한다. 스냅샷과 직접 비교.
    changed_files_json="$(snapshot_changed_docs "$prev_snapshot" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  fi
  dup_ids=$(jq -r '[.blocking_issues[].id] | group_by(.) | map(select(length>1) | .[0]) | join(",")' "$review")
  [ -z "$dup_ids" ] || { echo "[FAIL] 중복 blocker id($dup_ids) — 검증자 응답 오류로 중단: $review" >&2; exit 1; }
  bad=$(jq -r --arg round "$round" --argjson prev "$prev_ids_json" --argjson changed "$changed_files_json" '
    .blocking_issues[] | select(
      (.evidence_type=="DIRECT_MISMATCH" and ((.conflict_refs|length)==0 or .impact=="")) or
      (.evidence_type=="REACHABLE_FAILURE" and ((.code_refs|length)==0 or .reachable_scenario=="" or .impact=="")) or
      (.evidence_type=="UNDECIDED_CHOICE" and (.action!="ASK_USER" or .category!="POLICY_UNDECIDED" or (.conflict_refs|length)>0 or (.code_refs|length)>0 or .reachable_scenario!="")) or
      (.category=="POLICY_UNDECIDED" and (.action!="ASK_USER" or .evidence_type!="UNDECIDED_CHOICE")) or
      (.action=="REVISE_DOC" and (.minimum_contract_needed=="" or .impact=="" or .user_question!="" or (.options|length)>0)) or
      (.action=="ASK_USER" and (.user_question=="" or (.options|length)<2 or .minimum_contract_needed!="")) or
      (($round|tonumber)==1 and (.origin!="ROUND_1" or .previous_issue_id!="" or .revision_ref!="")) or
      (($round|tonumber)>1 and (
        .origin=="ROUND_1" or
        (.origin=="UNRESOLVED_PREVIOUS" and (.previous_issue_id=="" or .previous_issue_id!=.id or .revision_ref!="" or (.previous_issue_id as $pid | ($prev|index([$pid]))==null))) or
        (.origin!="UNRESOLVED_PREVIOUS" and (.revision_ref=="" or .previous_issue_id!="" or ((.revision_ref|split(":")[0]|split("/")|last) as $rf | ($changed|index([$rf]))==null)))))
    ) | .id' "$review")
  if [ -n "$bad" ]; then
    echo "[FAIL] 근거·연계 필드가 빠지거나 어긋난 blocker($(echo "$bad" | paste -sd, -)) — 검증자 응답 오류로 중단: $review" >&2
    exit 1
  fi
  ids=$(jq -r '[.blocking_issues[].id] | sort | join(",")' "$review")
  fingerprint=$(jq -Sc '[.blocking_issues[] | {id, evidence_type, basis_refs, minimum_contract_needed, user_question}] | sort_by(.id)' "$review")
  echo "검증자 verdict: $verdict / blocking: ${ids:-없음}"
  jq -r '.blocking_issues[]? | "  [\(.id)] \(.category) / \(.change_relation) / \(.evidence_type) / \(.action) / origin=\(.origin)\n      근거: \(.basis_refs | join(", "))\n      충돌·코드: \((.conflict_refs + .code_refs) | join(", "))" + (if .reachable_scenario != "" then "\n      경로: \(.reachable_scenario)\n      영향: \(.impact)" else "" end) + "\n      지금 막는 이유: \(.why_blocks_now)" + (if .action=="ASK_USER" then "\n      → 질문: \(.user_question)\n        선택지: \(.options | join(" | "))" else "\n      → 최소 계약: \(.minimum_contract_needed)" end)' "$review"

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

  # ASK_USER: 문서 재작성으로 풀리지 않는 문제(범위 밖 공용 컴포넌트 수정·제품 정책 선택)는 디자이너를 거치지 않고 즉시 사용자에게
  ask_ids=$(jq -r '[.blocking_issues[] | select(.action=="ASK_USER") | .id] | join(",")' "$review")
  if [ -n "$ask_ids" ]; then
    echo "[STOP] 검증자가 사용자 결정을 요구함($ask_ids). user_question / options 를 사용자에게 그대로 전달." >&2
    jq -n --arg t "$TARGET" --arg i "$ask_ids" --arg r "$review" '{phase:$t, status:"ASK_USER", issues:$i, review:$r}' > "$WORK_DIR/state.json"
    exit 2
  fi

  # 교착 감지: 이슈 '내용'까지 동일한 집합이 2라운드 연속이면 사람에게 에스컬레이션
  # (같은 id라도 reachable_scenario/minimum_contract_needed 가 달라지면 진전 중으로 본다)
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
  prev_snapshot="$WORK_DIR/reviews/docs-snapshot-$TARGET-round-$tag"
  snapshot_docs "$prev_snapshot"
  echo "--- 디자이너가 리뷰를 반영/반박합니다 ---"
  decisions_lines_before=$(wc -l < "$WORK_DIR/decisions.md")
  designer_result="$WORK_DIR/reviews/designer-$TARGET-round-$tag.raw"
  session_args=$(claude_session_args designer-doc)
  designer_prompt=$(REVIEW_FILE="$review" WORK_DIR="$WORK_DIR" ROUND="$round" \
    render_prompt "$DESIGNER_PROMPT_FILE" '${REVIEW_FILE} ${WORK_DIR} ${ROUND}')
  "$CLAUDE_BIN" -p $session_args --model "$DESIGNER_MODEL" --effort "$DESIGNER_EFFORT" \
    ${designer_rule_args[@]+"${designer_rule_args[@]}"} \
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
