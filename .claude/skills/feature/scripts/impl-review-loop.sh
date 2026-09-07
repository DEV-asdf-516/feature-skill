#!/usr/bin/env bash
# =============================================================
# 구현 리뷰 루프: 리뷰어(병합 게이트) ↔ 수정자(FIX_CODE 만) 수렴 강제
# 파일 경로: .claude/skills/feature/scripts/impl-review-loop.sh
# 사용법: impl-review-loop.sh  (메인 작성자 워커의 구현이 끝난 뒤에만 실행)
# 종료 코드: 0=승인, 2=사용자 판단(DEADLOCK | MAX_ROUNDS_EXCEEDED | FOREIGN_WORKTREE_CHANGE | SCOPE_VIOLATION | SCOPE_MANIFEST_CHANGED | SCOPE_BASELINE_CHANGED),
#            3=문서 보강(DOC_GAP), 1=환경·응답 오류
# 각 라운드 = 읽기 전용 리뷰 → (FIX_CODE 이슈 있으면) 수정자가 직접 수정 → 다음
# 라운드에서 종결 검토. 리뷰는 MAX_IMPL_ROUNDS+1 회 — 마지막 수정도 재검증한다.
# Round 1 은 입장 조건을 만족하는 issue 를 전부, Round 2+ 는 직전 이슈의 해결 여부와
# 수정이 만든 직접 회귀만 다룬다(origin 과 fix_ref 를 러너가 대조).
# 재개: $WORK_DIR/review-impl.json 에 attempt/round/next_step(REVIEWER_PENDING|FIXER_PENDING|APPROVE)·
#   리뷰 경로·tree·작업 트리 지문을 남긴다. 수정자 호출이 실패하면 재실행 시 리뷰어를 다시 부르지 않고
#   같은 리뷰 JSON 으로 수정자만 재시도한다(같은 attempt 유지). APPROVE 도 지문과 함께 캐시한다.
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

# ---------- round/substep 단위 체크포인트 ----------
# 러너의 run-state.json 은 stage(review) 까지만 기억한다. 리뷰어가 REQUEST_CHANGES 를 정상 출력한 뒤
# 수정자 호출이 실패(모델 ID 오류 등)하면, 재실행이 리뷰어를 다시 부르지 않고 같은 리뷰 JSON 으로
# 수정자만 재시도하도록 attempt/round/다음 단계를 별도 파일에 남긴다.
#   next_step: REVIEWER_PENDING | FIXER_PENDING | APPROVE | NONE(초기화됨 — 새 attempt 로 시작)
# worktree_fingerprint: FIXER_PENDING/REVIEWER_PENDING 에서는 작업 트리+decisions.md 지문(compute_fixer_resume_fingerprint) —
# 재개 시 달라졌으면 수정자가 일부 고친 뒤 죽은 것이므로 같은 수정을 반복하지 않고 다음 리뷰 라운드로 간다.
# APPROVE 에서는 범위 지문(compute_approval_fingerprint = feature-scope 범위, 없으면 작업 트리 전체) — 같고 리뷰가 실제 APPROVE 일 때만 승인을 재사용한다.
RESUME_STATE="$WORK_DIR/review-impl.json"
save_review_checkpoint() { # attempt round next_step review tree worktree_fingerprint
  jq -n --argjson version "$REVIEW_CHECKPOINT_VERSION" --argjson contract_version "$REVIEWER_CONTRACT_VERSION" --argjson attempt "$1" --argjson round "$2" \
    --arg next_step "$3" --arg review "${4:-}" --arg tree "${5:-}" --arg worktree_fingerprint "${6:-}" \
    --arg now "$(date '+%FT%T%z')" \
    '{version:$version, contract_version:$contract_version, attempt:$attempt, round:$round, next_step:$next_step,
      review:$review, tree:$tree, worktree_fingerprint:$worktree_fingerprint, updated_at:$now}' \
    > "$RESUME_STATE.tmp" && mv "$RESUME_STATE.tmp" "$RESUME_STATE"
}
# 사용자 판단·문서 보강으로 넘어가는 종료(DEADLOCK/MAX_ROUNDS/DOC_GAP)는 코드나 문서가 바뀐 뒤 재진입하므로
# 라운드 중간이 아니라 새 attempt 의 Round 1 부터 시작해야 한다 — 체크포인트를 초기 상태로 되돌린다(파일 삭제 대신 덮어쓰기).
reset_review_checkpoint() { save_review_checkpoint "${attempt:-0}" 0 NONE "" "" ""; }

# lock 이 있으면 원본과 같아야 한다 — 다르면 범위가 바뀐 것이고 어느 쪽이 맞는지 여기서 정하지 않는다.
# 재개 블록이 승인 지문(compute_approval_fingerprint — 같은 불변식을 검사한다)을 계산하기 전에 여기서 상태를 남기고 멈춘다.
if [ -f "$FEATURE_SCOPE_LOCK" ] && ! cmp -s "$FEATURE_SCOPE_FILE" "$FEATURE_SCOPE_LOCK"; then
  echo "[STOP] feature-scope.json 이 feature-scope.lock.json 과 다름 — 범위 변경은 워커 재진입(impl 재합의) 경로로만. 자동 복구 없음." >&2
  jq -n '{phase:"impl", status:"SCOPE_MANIFEST_CHANGED"}' > "$WORK_DIR/state.json"
  reset_review_checkpoint
  exit 2
fi

# 직전 실행이 기준선 변조로 멈췄으면 복구 전에는 리뷰어·수정자를 부르지 않고, 체크포인트·승인 지문도 계산하지 않는다
if ! require_baseline_guard_resolved; then
  jq -n --arg e "$(jq -r .expected "$BASELINE_GUARD")" '{phase:"impl", status:"SCOPE_BASELINE_CHANGED", expected:$e}' > "$WORK_DIR/state.json"
  reset_review_checkpoint
  exit 2
fi

attempt=""; round=1; next_step="REVIEWER_PENDING"
prev_review=""; prev_tree=""; prev_fingerprint_issues=""
if [ -f "$RESUME_STATE" ]; then
  if ! jq -e --argjson cv "$REVIEW_CHECKPOINT_VERSION" '.version==$cv' "$RESUME_STATE" >/dev/null 2>&1; then
    # 포맷 버전이 다르면 지문의 의미가 다르다 — 비교하지 않고 새 attempt 부터 (건너뛰기 오판 방지)
    echo "[WARN] 리뷰 체크포인트 포맷 버전 불일치(현재 $REVIEW_CHECKPOINT_VERSION) — 새 attempt 로 Round 1 부터 리뷰"
  elif jq -e --argjson v "$REVIEWER_CONTRACT_VERSION" '.contract_version==$v' "$RESUME_STATE" >/dev/null 2>&1; then
    ck_attempt="$(jq -r '.attempt' "$RESUME_STATE")"
    ck_round="$(jq -r '.round' "$RESUME_STATE")"
    ck_step="$(jq -r '.next_step' "$RESUME_STATE")"
    ck_review="$(jq -r '.review // ""' "$RESUME_STATE")"
    ck_tree="$(jq -r '.tree // ""' "$RESUME_STATE")"
    ck_wt_fp="$(jq -r '.worktree_fingerprint // ""' "$RESUME_STATE")"
    cur_wt_fp="$(compute_approval_fingerprint)"
    cur_fix_fp="$(compute_fixer_resume_fingerprint)"
    ck_dir="$WORK_DIR/reviews/impl-attempt-$(printf '%02d' "${ck_attempt:-0}")"
    refs_ok=1
    if [ "$ck_round" -gt 1 ] 2>/dev/null || [ "$ck_step" = FIXER_PENDING ]; then
      { [ -f "$ck_review" ] && [ -n "$ck_tree" ] && git cat-file -e "$ck_tree" 2>/dev/null; } || refs_ok=0
    fi
    case "$ck_step" in
      APPROVE)
        # 트리 지문 일치 + 리뷰 파일이 해당 attempt/round 의 실제 APPROVE 리뷰(현재 계약)일 때만 재사용
        if [ "$ck_wt_fp" = "$cur_wt_fp" ] && [ "$ck_review" = "$ck_dir/reviewer-round-$(printf '%02d' "${ck_round:-0}").json" ] \
           && valid_impl_approve_review "$ck_review"; then
          echo "=== 기존 승인 체크포인트 재사용 (attempt $ck_attempt round $ck_round, 작업 트리 변경 없음) ==="
          printf '%s\n' "$ck_wt_fp" | tee "$ck_dir/approved.fingerprint" > "$WORK_DIR/approved.fingerprint"
          jq -n --arg r "$ck_round" --arg a "$ck_attempt" '{phase:"impl", status:"APPROVE", rounds:($r|tonumber), attempt:($a|tonumber)}' > "$WORK_DIR/state.json"
          exit 0
        fi
        echo "[$(date '+%F %T')] 기존 승인이 현재 작업 트리·계약에 대해 유효하지 않음 — 새 attempt 로 Round 1 부터 리뷰";;
      REVIEWER_PENDING|FIXER_PENDING)
        if [ "$refs_ok" = 0 ] || [ ! -d "$ck_dir" ]; then
          echo "[WARN] 체크포인트가 가리키는 attempt/리뷰/tree 없음 — 새 attempt 로 Round 1 부터 리뷰"
        else
          attempt="$ck_attempt"; round="$ck_round"; next_step="$ck_step"; prev_review="$ck_review"; prev_tree="$ck_tree"
          if [ "$next_step" = REVIEWER_PENDING ] && [ "$round" -gt 1 ] && [ "$ck_wt_fp" != "$cur_fix_fp" ]; then
            # 수정자가 '완료'된 뒤 별도 변경이 들어왔다(사람·다른 도구). Round 2 는 수정자 변경의 종결 검토라
            # 이 변경이 fix-diff 에 섞이면 귀속이 틀어진다 — 같은 attempt 를 잇지 않고 새 attempt Round 1 로.
            echo "[WARN] 수정자 완료 이후 추가 변경 감지 — 새 attempt 로 Round 1 부터 리뷰"
            attempt=""; round=1; next_step="REVIEWER_PENDING"; prev_review=""; prev_tree=""
          elif [ "$next_step" = FIXER_PENDING ] && [ "$ck_wt_fp" != "$cur_fix_fp" ]; then
            # 수정자가 코드나 decisions.md 를 일부 고친 뒤 죽었거나 사람이 손댔다(FIXER_PENDING 지문 = 작업 트리 + decisions.md).
            # 같은 수정을 다시 시키면 이중 수정·REJECT 중복 기록 위험.
            echo "[WARN] 수정자 호출 중 작업 트리 변경 흔적 감지 — 같은 수정을 재실행하지 않고 다음 리뷰 라운드로 진행"
            round=$((round + 1)); next_step="REVIEWER_PENDING"
            save_review_checkpoint "$attempt" "$round" "$next_step" "$prev_review" "$prev_tree" "$cur_fix_fp"
          fi
          [ -z "$prev_review" ] || prev_fingerprint_issues=$(jq -Sc '[.issues[] | {id, category, code_refs, required_outcome}] | sort_by(.id)' "$prev_review")
          [ -z "$attempt" ] || echo "[$(date '+%F %T')] impl-review-loop 재개: attempt $attempt round $round / $next_step"
        fi;;
      NONE) ;;
      *) echo "[WARN] 알 수 없는 next_step '$ck_step' — 새 attempt 로 Round 1 부터 리뷰";;
    esac
  else
    echo "[WARN] 리뷰 체크포인트 계약 버전 불일치 — 현재 계약으로 새 attempt 부터 리뷰"
  fi
fi

# Phase 4 재진입마다 attempt 디렉터리를 새로 잡아 이전 승인·리뷰 증거를 보존한다 (체크포인트 재개 시엔 기존 attempt 유지)
if [ -z "$attempt" ]; then
  attempt=1
  while [ -d "$WORK_DIR/reviews/impl-attempt-$(printf '%02d' "$attempt")" ]; do
    attempt=$((attempt + 1))
  done
fi
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
  git cat-file -e "$BASELINE_TREE^{tree}" 2>/dev/null || { echo "[FAIL] worker-baseline.tree 가 가리키는 tree 객체가 없음: $BASELINE_TREE" >&2; exit 1; }
  echo "리뷰 기준선: 워커 진입 직전 tree $BASELINE_TREE"
else
  echo "[WARN] worker-baseline.tree 없음 — HEAD 를 기준선으로 리뷰한다(피처 이전 미커밋 변경이 diff 에 섞일 수 있음). 범위 밖 변경 자동 원복은 비활성."
fi
REVIEW_BASE="${BASELINE_TREE:-HEAD}"
# 리뷰 diff 범위: feature-scope.json 이 있으면 그 경로만. 같은 working tree 의 다른 세션 변경은 "이번 작업"이 아니다.
scope_pathspecs=()
if feature_scope_valid; then
  # manifest 문자열을 glob 으로 해석하지 않는다 — :(literal) 고정 (디렉터리 접두 매칭은 literal 에서도 유지된다)
  while IFS= read -r ps; do scope_pathspecs+=(":(literal)$ps"); done < <(feature_scope_pathspecs)
  echo "리뷰 범위: feature-scope.json (${#scope_pathspecs[@]} 경로) — 범위 밖 변경은 diff·승인 지문에서 제외"
elif feature_scope_present; then
  echo "[FAIL] feature-scope.json 형식 오류 (version $FEATURE_SCOPE_VERSION, files[] 비어있지 않은 상대 경로)" >&2; exit 1
else
  echo "[WARN] feature-scope.json 없음 — 전체 작업 트리를 리뷰한다(구버전 산출물). 공유 working tree 에서는 다른 세션의 변경이 섞일 수 있다."
fi
scoped_diff() { # args... → git diff args -- <scope>
  if [ "${#scope_pathspecs[@]}" -gt 0 ]; then git diff "$@" -- "${scope_pathspecs[@]}"; else git diff "$@" --; fi
}
stop_with() { # exit-code status [extra jq assignments]  — 사용자·문서 단계로 넘기는 종료. 체크포인트는 초기화
  local rc="$1" status="$2"; shift 2
  jq -n --arg a "$attempt" --arg s "$status" "$@" '{phase:"impl", status:$s, attempt:($a|tonumber)} + $ARGS.named | del(.a, .s)' > "$WORK_DIR/state.json"
  reset_review_checkpoint
  exit "$rc"
}

while [ "$round" -le $((MAX_IMPL_ROUNDS + 1)) ]; do
  tag=$(printf '%02d' "$round")
  review="$ATTEMPT_DIR/reviewer-round-$tag.json"

  if [ "$next_step" = "REVIEWER_PENDING" ]; then
  echo "=== Impl Round $round/$((MAX_IMPL_ROUNDS + 1)) : 리뷰어 리뷰 ==="

  # ---------- 리뷰 단계: 판정 무결성을 위해 이 실행은 읽기 도구만 허용 ----------
  # (리뷰 실행이 코드를 만질 수 있으면 "고치면서 동시에 APPROVE"가 가능해져
  #  모든 수정은 다음 라운드에서 재검증된다는 불변식이 깨진다)
  diff_file="$ATTEMPT_DIR/diff-round-$tag.patch"
  status_file="$ATTEMPT_DIR/status-round-$tag.txt"
  # 리뷰 입력 스냅샷의 지문 — 승인 시 현재 지문과 일치해야만 승인으로 인정
  # (리뷰 도중 작업 트리가 바뀌면 리뷰되지 않은 변경이 승인에 섞이는 것을 차단)
  # 지문을 diff/status 캡처보다 먼저 찍고 직후 재비교해, 캡처 도중 변경까지 배제한다
  review_fingerprint=$(compute_approval_fingerprint)
  cur_tree=$(snapshot_worktree_tree) || { echo "[FAIL] 작업 트리 스냅샷(tree 객체) 생성 실패" >&2; exit 1; }
  scoped_diff "$REVIEW_BASE" "$cur_tree" > "$diff_file"
  scoped_diff --name-status "$REVIEW_BASE" "$cur_tree" > "$status_file"
  snapshot_fingerprint=$(compute_approval_fingerprint)
  if [ "$snapshot_fingerprint" != "$review_fingerprint" ]; then
    echo "[FAIL] 리뷰 입력 스냅샷 생성 중 작업 트리가 변경됨. 재실행 필요." >&2
    exit 1
  fi

  # Round 1 은 입장 조건을 만족하는 issue 를 전부 낸다. Round 2+ 는 재감사가 아니라 종결 검토다.
  prev_context="이번은 Round 1 이다. 입장 조건을 만족하는 issue 를 이번 라운드에 전부 내라 — 다음 라운드로 미루지 마라. 모든 issue 의 origin 은 ROUND_1."
  changed_files_json='[]'; prev_ids_json='[]'
  if [ -n "$prev_review" ]; then
    fix_diff="$ATTEMPT_DIR/fix-diff-round-$tag.patch"
    scoped_diff "$prev_tree" "$cur_tree" > "$fix_diff"
    changed_files_json="$(scoped_diff --name-only "$prev_tree" "$cur_tree" | jq -Rsc 'split("\n") | map(select(length > 0))')"
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
    current_fingerprint=$(compute_approval_fingerprint)
    if [ "$current_fingerprint" != "$review_fingerprint" ]; then
      echo "[FAIL] 리뷰 도중 작업 트리가 변경됨 — 리뷰되지 않은 변경은 승인할 수 없음. 재실행 필요." >&2
      exit 1
    fi
    echo "=== 구현 리뷰 승인 (round $round) ==="
    # 승인된 것은 '리뷰 입력 스냅샷' 상태다 — Phase 4 진입·커밋 직전에 verify_approved_fingerprint 로 검증
    printf '%s\n' "$review_fingerprint" | tee "$ATTEMPT_DIR/approved.fingerprint" > "$WORK_DIR/approved.fingerprint"
    # 승인도 체크포인트로 남긴다 — 러너가 다음 stage 를 기록하기 전에 죽어도 트리가 그대로면 리뷰어를 다시 부르지 않는다
    save_review_checkpoint "$attempt" "$round" APPROVE "$review" "$cur_tree" "$review_fingerprint"
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

  # OUT_OF_SCOPE_CHANGE: 자동 원복 금지. 같은 working tree 에서 다른 세션이 만든 변경일 수 있고 git 은 변경 소유자를
  # 기록하지 않는다 — worker-baseline.tree 는 시점 기준선이지 소유권 증거가 아니다. 파일을 건드리지 않고 보존한 채 중단.
  foreign_ids=$(jq -r '[.issues[] | select(.category=="OUT_OF_SCOPE_CHANGE") | .id] | join(",")' "$review")
  if [ -n "$foreign_ids" ]; then
    echo "[STOP] 범위 밖 변경 감지($foreign_ids). 다른 세션 작업일 수 있으므로 자동 원복하지 않고 현재 내용을 보존한 채 중단." >&2
    jq -r '.issues[] | select(.category=="OUT_OF_SCOPE_CHANGE") | "  [\(.id)] \(.code_refs | join(", "))"' "$review" >&2
    stop_with 2 FOREIGN_WORKTREE_CHANGE --arg issues "$foreign_ids" --arg review "$review"
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

  # 리뷰 완료 → 수정자 호출 '전에' 체크포인트. 수정자가 실패하면 이 상태가 남아 재실행이 같은 리뷰 JSON 으로 수정자만 다시 부른다.
  next_step="FIXER_PENDING"
  save_review_checkpoint "$attempt" "$round" "$next_step" "$prev_review" "$prev_tree" "$(compute_fixer_resume_fingerprint)"
  fi # REVIEWER_PENDING

  if [ "$next_step" = "FIXER_PENDING" ]; then
  # ---------- 수정 단계: 수정자가 FIX_CODE 이슈만 반영 ----------
  # 리뷰와 다른 세션을 이어간다 — 실행 비용은 캐시로 줄이되 승인 독립성은 유지
  echo "--- 수정자가 FIX_CODE 이슈($(basename "$prev_review"))를 수정합니다 ---"
  touch "$WORK_DIR/decisions.md"
  decisions_lines_before=$(wc -l < "$WORK_DIR/decisions.md")
  fix_result="$ATTEMPT_DIR/fixer-round-$tag.raw"
  index_before=$(compute_index_fingerprint) || { echo "[FAIL] 수정자 호출 전 git index 지문 계산 실패" >&2; exit 1; }
  scope_hash_before=$(feature_scope_hash)
  # 소유권 기준선은 시작 시 읽은 BASELINE_TREE 를 쓴다(호출 후 파일을 다시 읽지 않는다). 파일 자체가 바뀌었는지도 본다.
  baseline_file_before=""; [ -f "$WORK_DIR/worker-baseline.tree" ] && baseline_file_before="$(cat "$WORK_DIR/worker-baseline.tree")"
  fix_session=$(claude_session_args fixer)
  set +e
  "$CLAUDE_BIN" -p $fix_session --model "$FIXER_MODEL" --effort "$FIXER_EFFORT" --permission-mode acceptEdits \
    ${review_rule_args[@]+"${review_rule_args[@]}"} \
    --allowedTools "Bash" --output-format json \
    "$(REVIEW_FILE="$prev_review" WORK_DIR="$WORK_DIR" TEST_CMD="$TEST_CMD" ROUND="$round" BASELINE_TREE="$BASELINE_TREE" \
      render_prompt "$SKILL_DIR/prompts/fixer.md" '${REVIEW_FILE} ${WORK_DIR} ${TEST_CMD} ${ROUND} ${BASELINE_TREE}')" \
    > "$fix_result"
  fixer_rc=$?
  set -e
  # 기준선 변경은 다른 사후 조건보다 먼저 '기록'만 한다 — index·manifest 검사가 앞서 종료해도 재실행 가드는 남아야 한다
  baseline_changed=0
  baseline_file_after=""; [ -f "$WORK_DIR/worker-baseline.tree" ] && baseline_file_after="$(cat "$WORK_DIR/worker-baseline.tree")"
  if [ "$baseline_file_after" != "$baseline_file_before" ]; then
    record_baseline_guard "$baseline_file_before" "$baseline_file_after" fixer || { echo "[FAIL] worker-baseline 가드 기록 실패" >&2; exit 1; }
    baseline_changed=1
  fi
  # 사후 조건을 CLI 성공 여부·세션 확정·사용량 기록보다 먼저 본다 — 수정자는 작업 트리만 바꿀 수 있고,
  # index 가 바뀌었으면 사용자 staged 상태를 건드린 것이므로 실패한 실행이라도 복구하지 않고 그 사실부터 보고한다
  index_after=$(compute_index_fingerprint) || { echo "[FAIL] 수정자 호출 후 git index 지문 계산 실패" >&2; exit 1; }
  if [ "$index_after" != "$index_before" ]; then
    echo "[FAIL] 수정자가 git index 를 변경함(git add/reset/stash/restore --staged 등). 자동 복구하지 않고 중단 — git status 로 확인 후 재실행." >&2
    exit 1
  fi
  # manifest 불변 검사: 수정자가 원본·lock 을 고쳐 범위를 넓히면 write-set 검사가 무력화된다 — CLI 성공 여부보다 먼저 본다
  if [ "$(feature_scope_hash)" != "$scope_hash_before" ]; then
    echo "[STOP] 수정자 호출 중 feature-scope.json 또는 lock 이 바뀜 — 자동 복구하지 않음. 원본·lock 확인 후 재실행." >&2
    stop_with 2 SCOPE_MANIFEST_CHANGED --arg review "$prev_review" --arg step "fixer round $round"
  fi
  # 기준선 불변 검사: 수정자가 worker-baseline.tree 를 바꾸면 roots 아래 기존 파일 보호가 풀린다 — 자동 복구 없이 중단 (가드는 위에서 이미 기록)
  if [ "$baseline_changed" -eq 1 ]; then
    echo "[STOP] 수정자 호출 중 worker-baseline.tree 가 바뀜(전: ${baseline_file_before:-없음} / 후: ${baseline_file_after:-없음}) — 자동 복구하지 않음. 원래 값으로 되돌리고 수정자 변경을 확인한 뒤 재실행." >&2
    stop_with 2 SCOPE_BASELINE_CHANGED --arg before "$baseline_file_before" --arg after "$baseline_file_after" --arg review "$prev_review" --arg step "fixer round $round"
  fi
  # write-set 검사: 수정자 호출 전후 tree 사이 변경이 범위를 벗어나면 자동 원복 없이 보존하고 중단 (성공·실패 무관)
  if feature_scope_valid; then
    fixer_after_tree=$(snapshot_worktree_tree) || { echo "[FAIL] 수정자 호출 후 tree 스냅샷 실패" >&2; exit 1; }
    printf '%s\n' "$fixer_after_tree" > "$ATTEMPT_DIR/fixer-after-round-$tag.tree"
    violations="$(feature_scope_violations "$prev_tree" "$fixer_after_tree" "$BASELINE_TREE")"
    if [ -n "$violations" ]; then
      echo "[STOP] 수정자 호출 중 feature-scope.json 범위 밖 경로가 바뀜 — 자동 원복하지 않음(다른 세션 변경일 수 있음). 확인 후 재실행:" >&2
      printf '  %s\n' $violations >&2
      stop_with 2 SCOPE_VIOLATION --arg files "$(printf '%s' "$violations" | paste -sd, -)" --arg review "$prev_review" --arg step "fixer round $round"
    fi
  fi
  [ "$fixer_rc" -eq 0 ] || { echo "[FAIL] claude 실행 실패 (모델 '$FIXER_MODEL' 확인). 재실행 시 attempt $attempt round $round / FIXER_PENDING 부터 재개" >&2; exit 1; }
  claude_session_commit fixer
  log_claude_usage "impl-fix-a$attempt_tag-round-$tag" "$fix_result"
  echo "--- 수정자 판정 (decisions.md 신규 기록) ---"
  tail -n +"$((decisions_lines_before + 1))" "$WORK_DIR/decisions.md" | sed 's/^/  /'

  # 수정자 성공 → 다음 라운드 리뷰 대기 상태로 전환
  round=$((round + 1))
  next_step="REVIEWER_PENDING"
  save_review_checkpoint "$attempt" "$round" "$next_step" "$prev_review" "$prev_tree" "$(compute_fixer_resume_fingerprint)"
  fi # FIXER_PENDING
done

echo "[STOP] $MAX_IMPL_ROUNDS 라운드 내 승인 실패. 남은 이슈를 사용자에게 보고." >&2
stop_with 2 MAX_ROUNDS_EXCEEDED --arg review "$prev_review"
