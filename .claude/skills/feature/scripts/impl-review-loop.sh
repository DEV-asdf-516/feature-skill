#!/usr/bin/env bash
# =============================================================
# 구현 리뷰 루프: 리뷰어(병합 게이트) ↔ 수정자(FIX_CODE 만) 수렴 강제
# 파일 경로: .claude/skills/feature/scripts/impl-review-loop.sh
# 사용법: impl-review-loop.sh  (메인 작성자 워커의 구현이 끝난 뒤에만 실행)
# 종료 코드: 0=승인, 2=사용자 판단(DEADLOCK | MAX_ROUNDS_EXCEEDED),
#            3=문서 보강(DOC_GAP), 1=환경·응답 오류
# 각 라운드 = 읽기 전용 리뷰 → (FIX_CODE 이슈 있으면) 수정자가 직접 수정 → 다음
# 라운드에서 종결 검토. 리뷰는 MAX_IMPL_ROUNDS+1 회 — 마지막 수정도 재검증한다.
# Round 1 은 입장 조건을 만족하는 issue 를 전부, Round 2+ 는 직전 이슈의 해결 여부와
# 수정이 만든 직접 회귀만 다룬다(origin 과 fix_ref 를 러너가 대조).
# =============================================================
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.sh"
PROJECT_CONVENTIONS="$(load_project_conventions)"
review_rule_args=()
[ -z "$PROJECT_CONVENTIONS" ] || review_rule_args=(--append-system-prompt "$PROJECT_CONVENTIONS")

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
echo "[$(date '+%F %T')] impl-review-loop 시작"

for bin in "$CLAUDE_BIN" jq uuidgen envsubst git; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[FAIL] '$bin' 미설치. 중단." >&2; exit 1; }
done
[ -n "${REVIEWER_CONTRACT_VERSION:-}" ] || { echo "[FAIL] config.sh 에 REVIEWER_CONTRACT_VERSION 이 없음 (config.sh.new 참고해 병합)" >&2; exit 1; }
SCHEMA_FILE="$SKILL_DIR/schemas/impl-review.schema.json"
[ -f "$SCHEMA_FILE" ] || { echo "[FAIL] 스키마 없음: $SCHEMA_FILE" >&2; exit 1; }
for prompt_file in reviewer.md fixer.md; do
  [ -f "$SKILL_DIR/prompts/$prompt_file" ] || { echo "[FAIL] 프롬프트 없음: $SKILL_DIR/prompts/$prompt_file" >&2; exit 1; }
done
git rev-parse --verify -q HEAD >/dev/null || { echo "[FAIL] HEAD 커밋 없음 — diff 기준선이 필요하다." >&2; exit 1; }

# Phase 4 재진입마다 attempt 디렉터리를 새로 잡아 이전 승인·리뷰 증거를 보존한다
attempt=1
while [ -d "$WORK_DIR/reviews/impl-attempt-$(printf '%02d' "$attempt")" ]; do
  attempt=$((attempt + 1))
done
attempt_tag=$(printf '%02d' "$attempt")
ATTEMPT_DIR="$WORK_DIR/reviews/impl-attempt-$attempt_tag"
mkdir -p "$ATTEMPT_DIR"
echo "리뷰 산출물: $ATTEMPT_DIR (attempt $attempt)"

# 라운드별 작업 트리 스냅샷은 config.sh 의 snapshot_worktree_tree (tree 객체). 라운드 간 tree 끼리 diff 하면
# "수정자가 실제로 바꾼 것"이 정확히 나온다.
# 리뷰 기준선: 러너가 워커 진입 직전에 기록한 worker-baseline.tree. 없으면(구버전 산출물) HEAD 로 대체하되
# 수정자에게 기준선 없음을 알려 범위 밖 변경 자동 원복을 막는다.
BASELINE_TREE=""
if [ -f "$WORK_DIR/worker-baseline.tree" ]; then
  BASELINE_TREE="$(cat "$WORK_DIR/worker-baseline.tree")"
  git cat-file -e "$BASELINE_TREE" 2>/dev/null || { echo "[FAIL] worker-baseline.tree 가 가리키는 tree 객체가 없음: $BASELINE_TREE" >&2; exit 1; }
  echo "리뷰 기준선: 워커 진입 직전 tree $BASELINE_TREE"
else
  echo "[WARN] worker-baseline.tree 없음 — HEAD 를 기준선으로 리뷰한다(피처 이전 미커밋 변경이 diff 에 섞일 수 있음). 범위 밖 변경 자동 원복은 비활성."
fi
REVIEW_BASE="${BASELINE_TREE:-HEAD}"
stop_with() { # exit-code status [extra jq assignments]
  local rc="$1" status="$2"; shift 2
  jq -n --arg a "$attempt" --arg s "$status" "$@" '{phase:"impl", status:$s, attempt:($a|tonumber)} + $ARGS.named | del(.a, .s)' > "$WORK_DIR/state.json"
  exit "$rc"
}

prev_review=""; prev_tree=""; prev_fingerprint_issues=""
for round in $(seq 1 $((MAX_IMPL_ROUNDS + 1))); do
  tag=$(printf '%02d' "$round")
  review="$ATTEMPT_DIR/reviewer-round-$tag.json"
  echo "=== Impl Round $round/$((MAX_IMPL_ROUNDS + 1)) : 리뷰어 리뷰 ==="

  # ---------- 리뷰 단계: 판정 무결성을 위해 이 실행은 읽기 도구만 허용 ----------
  # (리뷰 실행이 코드를 만질 수 있으면 "고치면서 동시에 APPROVE"가 가능해져
  #  모든 수정은 다음 라운드에서 재검증된다는 불변식이 깨진다)
  diff_file="$ATTEMPT_DIR/diff-round-$tag.patch"
  status_file="$ATTEMPT_DIR/status-round-$tag.txt"
  # 리뷰 입력 스냅샷의 지문 — 승인 시 현재 지문과 일치해야만 승인으로 인정
  # (리뷰 도중 작업 트리가 바뀌면 리뷰되지 않은 변경이 승인에 섞이는 것을 차단)
  # 지문을 diff/status 캡처보다 먼저 찍고 직후 재비교해, 캡처 도중 변경까지 배제한다
  review_fingerprint=$(compute_worktree_fingerprint)
  cur_tree=$(snapshot_worktree_tree) || { echo "[FAIL] 작업 트리 스냅샷(tree 객체) 생성 실패" >&2; exit 1; }
  git diff "$REVIEW_BASE" "$cur_tree" -- > "$diff_file"
  git diff --name-status "$REVIEW_BASE" "$cur_tree" -- > "$status_file"
  snapshot_fingerprint=$(compute_worktree_fingerprint)
  if [ "$snapshot_fingerprint" != "$review_fingerprint" ]; then
    echo "[FAIL] 리뷰 입력 스냅샷 생성 중 작업 트리가 변경됨. 재실행 필요." >&2
    exit 1
  fi

  # Round 1 은 입장 조건을 만족하는 issue 를 전부 낸다. Round 2+ 는 재감사가 아니라 종결 검토다.
  prev_context="이번은 Round 1 이다. 입장 조건을 만족하는 issue 를 이번 라운드에 전부 내라 — 다음 라운드로 미루지 마라. 모든 issue 의 origin 은 ROUND_1."
  changed_files_json='[]'; prev_ids_json='[]'
  if [ -n "$prev_review" ]; then
    fix_diff="$ATTEMPT_DIR/fix-diff-round-$tag.patch"
    git diff "$prev_tree" "$cur_tree" -- > "$fix_diff"
    changed_files_json="$(git diff --name-only "$prev_tree" "$cur_tree" -- | jq -Rsc 'split("\n") | map(select(length > 0))')"
    prev_ids_json=$(jq -c '[.issues[].id]' "$prev_review")
    prev_context="이번은 Round $round(종결 검토)다. 입력: 직전 리뷰 JSON = $prev_review, 수정자의 ACCEPT/REJECT 기록 = $WORK_DIR/decisions.md 의 [fix round $((round - 1))] 줄, 직전 리뷰 이후 수정자가 바꾼 diff = $fix_diff, 현재 전체 diff = $diff_file. 이번 라운드에서 허용되는 issue 는 세 종류뿐이며 origin 으로 표시한다: UNRESOLVED_PREVIOUS(직전 이슈가 미해결, id 와 previous_issue_id 에 같은 id) / FIX_REGRESSION(수정이 새로 만든 직접 회귀, fix_ref 에 수정 diff 안의 위치 '파일:L시작-L끝') / NEWLY_EXPOSED_BY_FIX(직전 라운드에는 볼 수 없었던 문제가 수정으로 처음 드러남, fix_ref 필수). 직전 라운드 당시 이미 볼 수 있었던 별개의 문제는 제기하지 마라. 해결된 이슈는 제외한다. REJECT 된 이슈는 새로운 근거 위치가 없으면 재제기하지 마라."
  fi

  review_session=$(claude_session_args reviewer)
  "$CLAUDE_BIN" -p $review_session --model "$REVIEWER_MODEL" --effort "$REVIEWER_EFFORT" \
    ${review_rule_args[@]+"${review_rule_args[@]}"} \
    --tools "Read,Grep,Glob" \
    --disallowedTools "Bash,Edit,Write,NotebookEdit" \
    --json-schema "$(cat "$SCHEMA_FILE")" --output-format json \
    "$(REFERENCE_CODE="$(load_reference_code)" DIFF_FILE="$diff_file" STATUS_FILE="$status_file" WORK_DIR="$WORK_DIR" \
       WORKER_RESULT="$WORK_DIR/worker-result.json" PREV_CONTEXT="$prev_context" REVIEWER_CONTRACT_VERSION="$REVIEWER_CONTRACT_VERSION" \
      render_prompt "$SKILL_DIR/prompts/reviewer.md" '${REFERENCE_CODE} ${DIFF_FILE} ${STATUS_FILE} ${WORK_DIR} ${WORKER_RESULT} ${PREV_CONTEXT} ${REVIEWER_CONTRACT_VERSION}')" \
    > "$review.raw" || { echo "[FAIL] claude 실행 실패 (모델 '$REVIEWER_MODEL' 확인)"; exit 1; }
  claude_session_commit reviewer
  log_claude_usage "impl-review-a$attempt_tag-round-$tag" "$review.raw"

  jq -e '.structured_output' "$review.raw" > "$review" \
    || { echo "[FAIL] 리뷰 JSON이 스키마와 다름: $review.raw" >&2; exit 1; }
  jq -e --argjson v "$REVIEWER_CONTRACT_VERSION" '.schema_version==$v' "$review" >/dev/null 2>&1 \
    || { echo "[FAIL] 리뷰 schema_version 이 현재 계약($REVIEWER_CONTRACT_VERSION)과 다름: $review" >&2; exit 1; }
  verdict=$(jq -er '.verdict' "$review")
  issue_count=$(jq '.issues | length' "$review")

  # 스키마가 표현 못 하는 조건부 필수·상호 배제·연계를 여기서 강제 — 근거 없는 issue 는 응답 오류다.
  # 러너가 보장하는 것은 증거 필드의 존재, action 별 필드, origin 의 형식과 참조 대상(직전 이슈 id,
  # 수정 diff 에 실제로 바뀐 파일)까지다. 수정과 신규 issue 사이의 의미적 인과관계는 tests/reviewer-cases.md 가 본다.
  dup_ids=$(jq -r '[.issues[].id] | group_by(.) | map(select(length>1) | .[0]) | join(",")' "$review")
  [ -z "$dup_ids" ] || { echo "[FAIL] 중복 issue id($dup_ids) — 리뷰어 응답 오류로 중단: $review" >&2; exit 1; }
  bad=$(jq -r --arg round "$round" --argjson prev "$prev_ids_json" --argjson changed "$changed_files_json" '
    .issues[] | select(
      (.evidence_type=="DIRECT_MISMATCH" and ((.basis_refs|length)==0 or .reachable_scenario!="")) or
      (.evidence_type=="REACHABLE_FAILURE" and (.reachable_scenario=="" or .impact=="")) or
      (.evidence_type=="SEMANTIC_REDUNDANCY" and (.reachable_scenario!="" or (.category!="REDUNDANT_CONTROL_FLOW" and .category!="REDUNDANT_CODE"))) or
      ((.category=="REDUNDANT_CONTROL_FLOW" or .category=="REDUNDANT_CODE") and .evidence_type!="SEMANTIC_REDUNDANCY") or
      (.required_outcome=="") or
      (($round|tonumber)==1 and (.origin!="ROUND_1" or .previous_issue_id!="" or .fix_ref!="")) or
      (($round|tonumber)>1 and (
        .origin=="ROUND_1" or
        (.origin=="UNRESOLVED_PREVIOUS" and (.previous_issue_id=="" or .previous_issue_id!=.id or .fix_ref!="" or (.previous_issue_id as $pid | ($prev|index([$pid]))==null))) or
        (.origin!="UNRESOLVED_PREVIOUS" and (.fix_ref=="" or .previous_issue_id!="" or ((.fix_ref|split(":")[0]) as $rf | ($changed|index([$rf]))==null)))))
    ) | .id' "$review")
  if [ -n "$bad" ]; then
    echo "[FAIL] 근거·연계 필드가 빠지거나 어긋난 issue($(echo "$bad" | paste -sd, -)) — 리뷰어 응답 오류로 중단: $review" >&2
    exit 1
  fi
  echo "리뷰어 verdict: $verdict / issues: $issue_count"
  jq -r '.issues[]? | "  [\(.id)] \(.category) / \(.evidence_type) / \(.action) / origin=\(.origin)\n      코드: \(.code_refs | join(", "))" + (if (.basis_refs|length)>0 then "\n      근거: \(.basis_refs | join(", "))" else "" end) + (if .reachable_scenario != "" then "\n      경로: \(.reachable_scenario)\n      영향: \(.impact)" else "" end) + "\n      지금 막는 이유: \(.why_blocks_now)" + "\n      → 필요한 결과: \(.required_outcome)"' "$review"

  # 모순 응답은 재시도 없이 즉시 실패 — 스키마만 통과했다고 올바른 리뷰로 간주하지 않는다
  if { [ "$verdict" = "APPROVE" ] && [ "$issue_count" -gt 0 ]; } \
     || { [ "$verdict" = "REQUEST_CHANGES" ] && [ "$issue_count" -eq 0 ]; }; then
    echo "[FAIL] 모순 리뷰 응답: verdict=$verdict / issues=$issue_count — 응답 오류로 중단: $review" >&2
    exit 1
  fi

  # 승인은 verdict 와 issues 가 일치할 때만 인정 (API가 조건부 스키마를 막아 여기서 강제)
  if [ "$verdict" = "APPROVE" ]; then
    current_fingerprint=$(compute_worktree_fingerprint)
    if [ "$current_fingerprint" != "$review_fingerprint" ]; then
      echo "[FAIL] 리뷰 도중 작업 트리가 변경됨 — 리뷰되지 않은 변경은 승인할 수 없음. 재실행 필요." >&2
      exit 1
    fi
    echo "=== 구현 리뷰 승인 (round $round) ==="
    # 승인된 것은 '리뷰 입력 스냅샷' 상태다 — Phase 4 진입·커밋 직전에 verify_approved_fingerprint 로 검증
    printf '%s\n' "$review_fingerprint" | tee "$ATTEMPT_DIR/approved.fingerprint" > "$WORK_DIR/approved.fingerprint"
    jq -n --arg r "$round" --arg a "$attempt" '{phase:"impl", status:"APPROVE", rounds:($r|tonumber), attempt:($a|tonumber)}' > "$WORK_DIR/state.json"
    exit 0
  fi

  # DOC_GAP: 코드가 아니라 approach.md 가 비어 있다 — 수정자를 부르지 않고 문서 단계로.
  # 제품 정책 선택이라 사용자에게 가야 하는지는 재합의 때 문서 검증자(ASK_USER/POLICY_UNDECIDED)가 판정한다.
  doc_ids=$(jq -r '[.issues[] | select(.action=="DOC_GAP") | .id] | join(",")' "$review")
  if [ -n "$doc_ids" ]; then
    echo "[STOP] 리뷰어가 문서 공백을 보고함($doc_ids). approach.md 보강 후 재실행(검증자 재합의 → 워커 재개)." >&2
    stop_with 3 DOC_GAP --arg issues "$doc_ids" --arg review "$review"
  fi

  # 교착 감지: 이슈 '내용'까지 동일한 집합이 2라운드 연속이면 두 번째 수정자를 부르지 않고 사람에게
  # (같은 id 라도 code_refs/required_outcome 이 달라지면 진전 중으로 본다)
  ids=$(jq -r '[.issues[].id] | sort | join(",")' "$review")
  fingerprint_issues=$(jq -Sc '[.issues[] | {id, category, code_refs, required_outcome}] | sort_by(.id)' "$review")
  if [ "$fingerprint_issues" = "$prev_fingerprint_issues" ]; then
    echo "[STOP] 동일 이슈($ids)가 내용 변화 없이 2라운드 연속 반복됨. 사용자 판단 필요." >&2
    stop_with 2 DEADLOCK --arg issues "$ids" --arg review "$review"
  fi
  prev_fingerprint_issues="$fingerprint_issues"
  prev_review="$review"
  prev_tree="$cur_tree"

  # 마지막 검증 라운드였다면 수정 없이 종료 (수정은 항상 재검증 대상이어야 함)
  [ "$round" -le "$MAX_IMPL_ROUNDS" ] || break

  # ---------- 수정 단계: 수정자가 FIX_CODE 이슈만 반영 ----------
  # 리뷰와 다른 세션을 이어간다 — 실행 비용은 캐시로 줄이되 승인 독립성은 유지
  echo "--- 수정자가 FIX_CODE 이슈를 수정합니다 ---"
  decisions_lines_before=$(wc -l < "$WORK_DIR/decisions.md" 2>/dev/null || echo 0)
  touch "$WORK_DIR/decisions.md"
  fix_result="$ATTEMPT_DIR/fixer-round-$tag.raw"
  index_before=$(compute_index_fingerprint) || { echo "[FAIL] 수정자 호출 전 git index 지문 계산 실패" >&2; exit 1; }
  fix_session=$(claude_session_args fixer)
  set +e
  "$CLAUDE_BIN" -p $fix_session --model "$FIXER_MODEL" --effort "$FIXER_EFFORT" --permission-mode acceptEdits \
    ${review_rule_args[@]+"${review_rule_args[@]}"} \
    --allowedTools "Bash" --output-format json \
    "$(REVIEW_FILE="$review" WORK_DIR="$WORK_DIR" TEST_CMD="$TEST_CMD" ROUND="$round" BASELINE_TREE="$BASELINE_TREE" \
      render_prompt "$SKILL_DIR/prompts/fixer.md" '${REVIEW_FILE} ${WORK_DIR} ${TEST_CMD} ${ROUND} ${BASELINE_TREE}')" \
    > "$fix_result"
  fixer_rc=$?
  set -e
  # 사후 조건을 CLI 성공 여부·세션 확정·사용량 기록보다 먼저 본다 — 수정자는 작업 트리만 바꿀 수 있고,
  # index 가 바뀌었으면 사용자 staged 상태를 건드린 것이므로 실패한 실행이라도 복구하지 않고 그 사실부터 보고한다
  index_after=$(compute_index_fingerprint) || { echo "[FAIL] 수정자 호출 후 git index 지문 계산 실패" >&2; exit 1; }
  if [ "$index_after" != "$index_before" ]; then
    echo "[FAIL] 수정자가 git index 를 변경함(git add/reset/stash/restore --staged 등). 자동 복구하지 않고 중단 — git status 로 확인 후 재실행." >&2
    exit 1
  fi
  [ "$fixer_rc" -eq 0 ] || { echo "[FAIL] claude 실행 실패 (모델 '$FIXER_MODEL' 확인)" >&2; exit 1; }
  claude_session_commit fixer
  log_claude_usage "impl-fix-a$attempt_tag-round-$tag" "$fix_result"
  echo "--- 수정자 판정 (decisions.md 신규 기록) ---"
  tail -n +"$((decisions_lines_before + 1))" "$WORK_DIR/decisions.md" | sed 's/^/  /'
done

echo "[STOP] $MAX_IMPL_ROUNDS 라운드 내 승인 실패. 남은 이슈를 사용자에게 보고." >&2
stop_with 2 MAX_ROUNDS_EXCEEDED --arg review "$prev_review"
