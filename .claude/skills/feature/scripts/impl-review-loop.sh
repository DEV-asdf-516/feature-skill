#!/usr/bin/env bash
# =============================================================
# 구현 리뷰 루프: 리뷰어(병합 게이트) ↔ 수정자(FIX_CODE 만) 수렴 강제
# 파일 경로: .claude/skills/feature/scripts/impl-review-loop.sh
# 사용법: impl-review-loop.sh [--new-attempt]  (메인 작성자 워커의 구현이 끝난 뒤에만 실행)
#   --new-attempt (또는 FEATURE_REVIEW_NEW_ATTEMPT=1): REVIEW_OUTPUT_INVALID 로 멈춘 리뷰를 닫고 **명시적 새 리뷰 시도**(새 attempt Round 1, 새 세션 key)를 시작한다.
#                 대기 중인 무효 출력이 없으면 아무 효과가 없다(유료 리뷰를 강제로 다시 돌리는 스위치가 아니다).
# 종료 코드: 0=승인, 2=사용자 판단(DEADLOCK | MAX_ROUNDS_EXCEEDED | FOREIGN_WORKTREE_CHANGE | SCOPE_VIOLATION | SCOPE_MANIFEST_CHANGED | SCOPE_BASELINE_CHANGED),
#            3=리뷰어 DOC_GAP(사용자 결정 — doc-gap-resume.json 기록, 러너가 NEED_USER/REVIEW_DOC_GAP),
#            4=리뷰어 출력 계약 위반(REVIEW_OUTPUT_INVALID — reviews/invalid-review.json, 러너가 NEED_USER/REVIEW_OUTPUT_INVALID), 1=환경·CLI 오류
# 세 가지 중단은 서로 다른 상태다:
#   REVIEW_OUTPUT_INVALID      리뷰어가 JSON 을 돌려줬지만 출력 계약(스키마 → 버전 → origin/ref → verdict 일관성)에 어긋남. 원본·이벤트·invocation id 를 보존하고
#                              재실행은 모델 0회로 같은 진단을 돌려준다(같은 프롬프트 재전송 금지). 검사기를 고쳤으면 저장된 출력을 로컬 재검증한다.
#   CLI 결과 불확실(exit 1)     결과 JSON 자체가 없음/CLI 실패. codex resume 이면 marker 가 남아 다음 실행도 모델 0회(SESSION_RESUME_UNCERTAIN) — 여기서 지우지 않는다.
#   정상 이슈 미해결            유효한 REQUEST_CHANGES — 리뷰 → 수정자 → 종결 검토 루프(MAX_IMPL_ROUNDS).
# 각 라운드 = 읽기 전용 리뷰 → (FIX_CODE 이슈 있으면) 수정자가 직접 수정 → 다음
# 라운드에서 종결 검토. 리뷰는 MAX_IMPL_ROUNDS+1 회 — 마지막 수정도 재검증한다.
# Round 1 은 입장 조건을 만족하는 issue 를 전부, Round 2+ 는 직전 이슈의 해결 여부와
# 수정이 만든 직접 회귀만 다룬다(origin 과 fix_ref 를 러너가 대조).
# 재개: $WORK_DIR/review-impl.json 에 attempt/round/next_step(REVIEWER_PENDING|FIXER_PENDING|APPROVE)·
#   리뷰 경로·tree·작업 트리 지문을 남긴다. 수정자 호출이 실패하면 재실행 시 리뷰어를 다시 부르지 않고
#   같은 리뷰 JSON 으로 수정자만 재시도한다(같은 attempt 유지). APPROVE 도 지문과 함께 캐시한다.
# =============================================================
set -euo pipefail
NEW_ATTEMPT="${FEATURE_REVIEW_NEW_ATTEMPT:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --new-attempt) NEW_ATTEMPT=1;;
    *) echo "[FAIL] 알 수 없는 인자: $1" >&2; exit 1;;
  esac
  shift
done
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.sh"
PROJECT_CONVENTIONS="$(load_project_conventions)"
# 컨벤션 본문은 위 PROJECT_CONVENTIONS 로 한 번만 전달한다(claude --append-system-prompt / codex 프롬프트 앞 블록).
# 프롬프트에는 경로만 추가로 넣어 리뷰어·수정자가 basis_refs 에 실제 규칙 파일·줄을 인용할 수 있게 한다. 파일이 없으면 빈 값 = 컨벤션 검사 없음.
CONVENTIONS_REF=""; [ -f "$CONVENTIONS_FILE" ] && CONVENTIONS_REF="$CONVENTIONS_FILE"

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

require_role_bins REVIEWER FIXER jq uuidgen envsubst git || exit 1
[ -n "${REVIEWER_CONTRACT_VERSION:-}" ] || { echo "[FAIL] config.sh 에 REVIEWER_CONTRACT_VERSION 이 없음 (config.sh.new 참고해 병합)" >&2; exit 1; }
[ -n "${REVIEW_CHECKER_VERSION:-}" ] || { echo "[FAIL] config.sh 에 REVIEW_CHECKER_VERSION 이 없음 (config.sh.new 참고해 병합)" >&2; exit 1; }
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
#   next_step: REVIEWER_PENDING | FIXER_PENDING | APPROVE | REVIEW_OUTPUT_INVALID(무효 출력 대기 — 판정은 reviews/invalid-review.json) | NONE(초기화됨 — 새 attempt 로 시작)
# worktree_fingerprint: FIXER_PENDING/REVIEWER_PENDING 에서는 작업 트리+decisions.md 지문(compute_fixer_resume_fingerprint) —
# 재개 시 달라졌으면 수정자가 일부 고친 뒤 죽은 것이므로 같은 수정을 반복하지 않고 다음 리뷰 라운드로 간다.
# APPROVE 에서는 범위 지문(compute_approval_fingerprint = feature-scope 범위, 없으면 작업 트리 전체) — 같고 리뷰가 실제 APPROVE 일 때만 승인을 재사용한다.
# checker_version: 이 체크포인트를 쓴 루프 검사기 버전(config.sh REVIEW_CHECKER_VERSION). APPROVE 재사용 때 현재와 다르면(필드 없는 옛 체크포인트 포함)
# 저장된 승인 출력을 현재 검사기로 로컬 재검증(모델 0회)한 뒤에만 재사용한다 — 통과하면 버전을 갱신하고, 무효면 새 attempt 로 리뷰한다.
# contract_docs_sha256(APPROVE 만): 그 리뷰가 기준으로 읽은 계약 문서의 내용 지문(config.sh review_contract_docs_json approval). 승인 재사용은 작업 트리 지문뿐 아니라
# 이 값도 현재와 같아야 한다 — 코드가 그대로여도 계약 문서·사용자 결정·conventions.md 가 바뀌었으면 과거 APPROVE 를 재사용하지 않고 새 attempt 로 리뷰한다(필드 없는 옛 체크포인트 포함).
RESUME_STATE="$WORK_DIR/review-impl.json"
save_review_checkpoint() { # attempt round next_step review tree worktree_fingerprint [contract_docs_json — APPROVE 만]
  jq -n --argjson version "$REVIEW_CHECKPOINT_VERSION" --argjson contract_version "$REVIEWER_CONTRACT_VERSION" --argjson checker_version "$REVIEW_CHECKER_VERSION" \
    --argjson attempt "$1" --argjson round "$2" \
    --arg next_step "$3" --arg review "${4:-}" --arg tree "${5:-}" --arg worktree_fingerprint "${6:-}" --argjson docs "${7:-null}" \
    --arg now "$(date '+%FT%T%z')" \
    '{version:$version, contract_version:$contract_version, checker_version:$checker_version, attempt:$attempt, round:$round, next_step:$next_step,
      review:$review, tree:$tree, worktree_fingerprint:$worktree_fingerprint, contract_docs_sha256:$docs, updated_at:$now}' \
    > "$RESUME_STATE.tmp" && mv "$RESUME_STATE.tmp" "$RESUME_STATE"
}
# 사용자 판단으로 넘어가는 종료(DEADLOCK/MAX_ROUNDS/DOC_GAP)는 코드나 문서가 바뀐 뒤 재진입하므로
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

# ---------- 리뷰어 출력 계약 위반 기록 (REVIEW_OUTPUT_INVALID) ----------
# reviews/invalid-review.json: {version, active, status, attempt, round, review(원본 결과 JSON 경로), result_sha256, invocation_id, label, session_key,
#   input{prev_tree, cur_tree, review_base, approval_fingerprint, scope_hash, prev_review, prev_review_sha256, reviewer_contract_version, conventions_sha256,
#         contract_docs_sha256{request.md, design.md, implementation.md, approach.md, decisions.md → 내용 SHA256 | ABSENT}},
#   input_fingerprint, checker_version(진단을 낸 검사기 — 입력 지문에는 들어가지 않는다), errors[{issue_id, field, observed, expected, rule_id}], recorded_at}
# 무효 출력은 APPROVE 도 REQUEST_CHANGES 도 아니다 — 수정자를 부르지 않고, 세션을 수용하지 않으며(codex resume marker·스테이징 그대로),
# 원본 결과·이벤트 로그는 attempt 디렉터리에 그대로 둔다(새 호출은 새 attempt 디렉터리 = 새 이름).
# 이 기록이 active 인 동안 일반 재실행은 리뷰어를 부르지 않는다: 입력 지문·결과 해시가 같으면 현재 검사기로 로컬 재검증하고
# (유효해졌으면 같은 출력을 그대로 이어서 처리, 여전히 무효면 같은 진단), 달라졌으면 명시적 새 리뷰 시도(--new-attempt)를 요구한다.
INVALID_REVIEW="$WORK_DIR/reviews/invalid-review.json"
INVALID_REVIEW_VERSION=1
invalid_review_active() { [ -f "$INVALID_REVIEW" ] && jq -e --argjson v "$INVALID_REVIEW_VERSION" '.version==$v and .active==true' "$INVALID_REVIEW" >/dev/null 2>&1; }
invalid_review_field() { jq -r "$1" "$INVALID_REVIEW"; }
invalid_review_close() { # status note — active=false 로 남긴다(삭제하지 않는다)
  jq --arg s "$1" --arg note "$2" --arg now "$(date '+%FT%T%z')" '.active=false | .status=$s | .closed_note=$note | .closed_at=$now' \
    "$INVALID_REVIEW" > "$INVALID_REVIEW.tmp" && mv "$INVALID_REVIEW.tmp" "$INVALID_REVIEW"
}
# 저장된 무효 출력이 현재 검사기로 유효해져 그대로 처리하는 중인가. REVALIDATED 로 닫는 것은 **세션 확정과 체크포인트 전환이 모두 끝난 뒤**다 —
# 먼저 닫으면 그 사이(세션 확정 실패 등)에 죽었을 때 재실행이 active 기록을 보지 못하고 새 리뷰 호출(유료)로 간다. 닫기 전까지는 재실행이
# 같은 기록으로 같은 로컬 재검증을 다시 하고(모델 0회) 같은 처리를 이어간다(세션 확정·체크포인트 저장은 멱등).
revalidated_pending=0
close_revalidated_review() {
  [ "$revalidated_pending" = 1 ] || return 0
  invalid_review_close REVALIDATED "stored output accepted by the current checker (v$REVIEW_CHECKER_VERSION) without a model call" \
    || { echo "[FAIL] invalid-review.json 갱신 실패" >&2; exit 1; }
  revalidated_pending=0
}
print_review_errors() { # errors-json
  printf '%s' "$1" | jq -r '.[] | "  [INVALID] rule=\(.rule_id) issue=\(if .issue_id=="" then "-" else .issue_id end) field=\(.field)\n      observed: \(.observed)\n      expected: \(.expected)"' >&2
}
stop_review_output_invalid() { # why — 모델 호출 없이 진단을 돌려주고 exit 4. 체크포인트는 초기화하지 않는다(무효 기록이 재개 판정의 원천)
  echo "[STOP] REVIEW_OUTPUT_INVALID: 리뷰어 출력이 계약에 어긋남 (attempt $(invalid_review_field '.attempt') round $(invalid_review_field '.round'), invocation $(invalid_review_field '.invocation_id'), 원본 $(invalid_review_field '.review')) — $1" >&2
  print_review_errors "$(invalid_review_field '.errors')"
  echo "       APPROVE/REQUEST_CHANGES 로 처리하지 않았고 수정자도 부르지 않았다. 같은 프롬프트를 같은 세션에 다시 보내지 않는다(재실행 = 모델 0회, 같은 진단)." >&2
  echo "       복구: ① 검사기 버그였으면 고친 뒤 재실행(저장된 출력을 로컬 재검증, 모델 0회) ② 새 리뷰가 필요하면 명시적으로 'feature-run.sh … --new-review-attempt'(또는 impl-review-loop.sh --new-attempt) — 새 attempt Round 1, 새 세션. 기록: $INVALID_REVIEW" >&2
  jq --arg why "$1" --arg record "$INVALID_REVIEW" \
    '{phase:"impl", status:"REVIEW_OUTPUT_INVALID", attempt, round, review, record:$record, invocation_id, errors, why:$why}' "$INVALID_REVIEW" > "$WORK_DIR/state.json"
  exit 4
}

# ---------- 리뷰어 출력 계약 검사 (스키마 → 버전 → origin/ref → DOC_GAP code_refs 경로 → verdict 일관성) ----------
# 정의는 재개 블록보다 앞에 둔다 — 승인 체크포인트 재사용이 저장된 승인 출력을 현재 검사기로 재검증할 때 쓴다.
# ATTEMPT_DIR·scoped_diff 는 호출 시점에만 필요하고(Round 2+ 의 fix_ref 대조), 그 호출은 둘이 정해진 뒤에만 일어난다.
# 결과: 위반 목록 JSON 배열([{issue_id, field, observed, expected, rule_id}], 통과면 []). issue 본문·verdict 는 고치지 않는다.
# 앞 단계가 깨지면 뒤 단계는 해석할 수 없으므로 거기서 멈춘다(스키마·버전). 그 뒤 단계는 위반을 전부 따로 낸다 — 하나의 문자열로 합치지 않는다.
# origin 별 필드:
#   ROUND_1                               1라운드 전용, previous_issue_id="" · fix_ref=""
#   UNRESOLVED_PREVIOUS                   직전 리뷰에 같은 id 가 있고 previous_issue_id=id · fix_ref=""
#   FIX_REGRESSION / NEWLY_EXPOSED_BY_FIX previous_issue_id="" · fix_ref 필수(config.sh REVIEW_FIX_REF_RULE — review_fix_ref_violation 이 git tree 로 대조)
# 수정과 신규 issue 사이의 의미적 인과관계까지는 보지 않는다(tests/reviewer-cases.md 의 몫).
validate_review_output() { # review round prev_review prev_tree cur_tree → errors JSON
  local review="$1" round="$2" prev_review="$3" prev_tree="$4" cur_tree="$5" errors prev_ids='[]' changed_list row id ref why schema_errors
  # ① 최소 형태: JSON 객체 + 숫자 schema_version (이것도 아니면 어느 계약의 출력인지조차 알 수 없다)
  if ! jq -e 'type=="object" and (.schema_version|type=="number")' "$review" >/dev/null 2>&1; then
    jq -nc --arg f "$review" '[{issue_id:"", field:"(root)", observed:("JSON 객체가 아니거나 schema_version 이 숫자가 아님: " + $f), expected:"schemas/impl-review.schema.json", rule_id:"SCHEMA_INVALID"}]'
    return 0
  fi
  # ② 계약 버전: 다른 계약의 출력은 현재 스키마로 해석하지 않는다
  if ! jq -e --argjson v "$REVIEWER_CONTRACT_VERSION" '.schema_version==$v' "$review" >/dev/null 2>&1; then
    jq -c --argjson v "$REVIEWER_CONTRACT_VERSION" '[{issue_id:"", field:"schema_version", observed:(.schema_version|tostring), expected:("현재 리뷰어 계약 버전 " + ($v|tostring)), rule_id:"SCHEMA_VERSION_MISMATCH"}]' "$review"
    return 0
  fi
  # ③ JSON Schema 전체(required·enum·minItems·minLength·additionalProperties·타입) — 스키마 파일 자체로 검사한다(config.sh json_schema_violations).
  #    CLI 의 structured output 이 스키마를 강제했다고 가정하지 않는다. 구조가 깨진 출력에는 아래 조건부 규칙을 적용하지 않는다(해석 불가).
  schema_errors="$(json_schema_violations "$SCHEMA_FILE" "$review")" || return 1
  if [ "$(jq 'length' <<< "$schema_errors")" -gt 0 ]; then
    jq -c --slurpfile r "$review" 'map(. as $e
      | (($e.path | capture("^\\$\\.issues\\[(?<i>[0-9]+)\\]") | .i | tonumber) // null) as $i
      | {issue_id:(if $i == null then "" else (($r[0].issues[$i] | objects | .id | strings) // "") end),
         field:($e.path | sub("^\\$\\.?"; "") | if . == "" then "(root)" else . end), observed:$e.observed, expected:("스키마: " + $e.expected), rule_id:"SCHEMA_INVALID"})' <<< "$schema_errors" || return 1
    return 0
  fi
  [ -z "$prev_review" ] || prev_ids="$(jq -c '[.issues[].id]' "$prev_review")" || return 1
  errors="$(jq -c --argjson round "$round" --argjson prev "$prev_ids" '
    def e($id; $field; $obs; $exp; $rule): {issue_id:$id, field:$field, observed:($obs|tostring), expected:$exp, rule_id:$rule};
    def chk(cond; $field; obs; $exp; $rule): . as $i | if cond then [e($i.id; $field; ($i|obs); $exp; $rule)] else [] end;
    ([.issues[].id] | group_by(.) | map(select(length>1) | e(.[0]; "id"; .[0]; "issue id 는 한 리뷰 안에서 유일"; "DUPLICATE_ISSUE_ID")))
    + ([.issues[] | (
        chk(.evidence_type=="DIRECT_MISMATCH" and (.basis_refs|length)==0; "basis_refs"; "[]"; "DIRECT_MISMATCH 는 basis_refs 1개 이상"; "EVIDENCE_FIELDS")
      + chk(.evidence_type=="DIRECT_MISMATCH" and .reachable_scenario!=""; "reachable_scenario"; .reachable_scenario; "DIRECT_MISMATCH 는 reachable_scenario 빈 문자열"; "EVIDENCE_FIELDS")
      + chk(.evidence_type=="REACHABLE_FAILURE" and .reachable_scenario==""; "reachable_scenario"; ""; "REACHABLE_FAILURE 는 reachable_scenario 필수"; "EVIDENCE_FIELDS")
      + chk(.evidence_type=="REACHABLE_FAILURE" and .impact==""; "impact"; ""; "REACHABLE_FAILURE 는 impact 필수"; "EVIDENCE_FIELDS")
      + chk(.evidence_type=="SEMANTIC_REDUNDANCY" and .reachable_scenario!=""; "reachable_scenario"; .reachable_scenario; "SEMANTIC_REDUNDANCY 는 reachable_scenario 빈 문자열"; "EVIDENCE_FIELDS")
      + chk(.evidence_type=="SEMANTIC_REDUNDANCY" and (.category!="REDUNDANT_CONTROL_FLOW" and .category!="REDUNDANT_CODE"); "category"; .category; "SEMANTIC_REDUNDANCY 는 REDUNDANT_CONTROL_FLOW 또는 REDUNDANT_CODE 에만"; "EVIDENCE_FIELDS")
      + chk((.category=="REDUNDANT_CONTROL_FLOW" or .category=="REDUNDANT_CODE") and .evidence_type!="SEMANTIC_REDUNDANCY"; "evidence_type"; .evidence_type; "REDUNDANT_* category 는 SEMANTIC_REDUNDANCY"; "EVIDENCE_FIELDS")
      + chk(.category=="UNDECIDED_APPROACH" and (.action!="DOC_GAP" or .evidence_type!="DIRECT_MISMATCH" or (.code_refs|length)==0); "category"; "action=\(.action) evidence_type=\(.evidence_type) code_refs=\(.code_refs|length)"; "UNDECIDED_APPROACH 는 action=DOC_GAP · evidence_type=DIRECT_MISMATCH · code_refs 1개 이상"; "EVIDENCE_FIELDS")
      + chk(.action=="DOC_GAP" and ((.user_question // "")=="" or ((.options // [])|length)<2); "user_question/options"; "user_question 길이 \((.user_question // "")|length) / options \((.options // [])|length)개"; "DOC_GAP 은 user_question 비어 있지 않음 · options 2개 이상"; "ACTION_FIELDS")
      + chk(.action=="FIX_CODE" and ((.user_question // "")!="" or ((.options // [])|length)>0); "user_question/options"; "user_question 길이 \((.user_question // "")|length) / options \((.options // [])|length)개"; "FIX_CODE 는 user_question 빈 문자열 · options 빈 배열"; "ACTION_FIELDS")
      + chk(.required_outcome==""; "required_outcome"; ""; "required_outcome 은 모든 issue 에 필수"; "ACTION_FIELDS")
      + (if $round==1 then
          chk(.origin!="ROUND_1"; "origin"; .origin; "Round 1 의 origin 은 ROUND_1"; "INVALID_ORIGIN")
        + chk(.previous_issue_id!=""; "previous_issue_id"; .previous_issue_id; "ROUND_1 은 previous_issue_id 빈 문자열"; "INVALID_PREVIOUS_ISSUE_ID")
        + chk(.fix_ref!=""; "fix_ref"; .fix_ref; "ROUND_1 은 fix_ref 빈 문자열"; "INVALID_FIX_REF")
        else
          chk(.origin=="ROUND_1"; "origin"; .origin; "Round 2+ 의 origin 은 UNRESOLVED_PREVIOUS | FIX_REGRESSION | NEWLY_EXPOSED_BY_FIX"; "INVALID_ORIGIN")
        + chk(.origin=="UNRESOLVED_PREVIOUS" and (.previous_issue_id!=.id or (.id as $x | ($prev|index([$x]))==null)); "previous_issue_id"; "id=\(.id) previous_issue_id=\(.previous_issue_id) / 직전 리뷰 id=\($prev|join(","))"; "UNRESOLVED_PREVIOUS 는 직전 리뷰에 있는 id 이고 previous_issue_id 가 그 id 와 같다"; "INVALID_PREVIOUS_ISSUE_ID")
        + chk(.origin=="UNRESOLVED_PREVIOUS" and .fix_ref!=""; "fix_ref"; .fix_ref; "UNRESOLVED_PREVIOUS 는 fix_ref 빈 문자열"; "INVALID_FIX_REF")
        + chk((.origin=="FIX_REGRESSION" or .origin=="NEWLY_EXPOSED_BY_FIX") and .previous_issue_id!=""; "previous_issue_id"; .previous_issue_id; "FIX_REGRESSION/NEWLY_EXPOSED_BY_FIX 는 previous_issue_id 빈 문자열"; "INVALID_PREVIOUS_ISSUE_ID")
        + chk((.origin=="FIX_REGRESSION" or .origin=="NEWLY_EXPOSED_BY_FIX") and .fix_ref==""; "fix_ref"; ""; "FIX_REGRESSION/NEWLY_EXPOSED_BY_FIX 는 fix_ref 필수"; "INVALID_FIX_REF")
        end)
      )] | add // [])' "$review")" || return 1
  # DOC_GAP 의 code_refs: gap 을 구현 단위에 연결하는 유일한 입력이다(doc_gap_record_review → gaps[].paths). ref 하나라도 파일 경로로 확정할 수 없으면
  # 체크포인트를 만들기 전에 거부한다 — 비정규 ref 만 버리고 남은 경로로 기록하면 빠진 파일의 unit 은 gap 해결로 인정받지 못하고, 사용자가 그 사실을 알 수 없다.
  # 정규화는 줄 범위 제거와 선행 "./" 제거뿐이다(config.sh code_ref_path). 파일 실재 규칙은 워커 undecided[].paths 와 같다(repo_file_path_violation).
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    if [ "$(jq -r '.ok' <<< "$row")" = true ]; then
      if why="$(repo_file_path_violation "$(jq -r '.path' <<< "$row")")"; then continue; fi
    else why="저장소 상대 파일 경로가 아님(절대경로·\"..\"·glob·디렉터리 표기·설명 문구)"; fi
    errors="$(jq -c --argjson r "$row" --arg why "$why" \
      '. + [{issue_id:$r.id, field:("code_refs[" + ($r.i|tostring) + "]"), observed:($r.ref + " — " + $why), expected:"DOC_GAP 의 code_refs 는 전부 실제 저장소 상대 파일 경로:L시작-L끝", rule_id:"DOC_GAP_CODE_REF_PATH"}]' <<< "$errors")" || return 1
  done < <(jq -c "$JQ_PATH_DEFS"'.issues[] | select(.action=="DOC_GAP") | .id as $id | .code_refs | to_entries[]
             | (.value | code_ref_path) as $p | {id:$id, i:.key, ref:.value, path:$p, ok:($p | plain_file_path)}' "$review")
  # fix_ref ↔ 실제 수정 대조: 직전 리뷰 tree → 이번 리뷰 tree 의 범위 안 변경 목록과 새 버전 hunk (패치 파일 텍스트가 아니라 git tree 기준)
  if [ "$round" -gt 1 ] && [ -n "$prev_tree" ]; then
    changed_list="$ATTEMPT_DIR/.fix-changed-files.$$.tmp"
    scoped_diff --no-renames --name-only "$prev_tree" "$cur_tree" > "$changed_list" || return 1
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      id="$(jq -r '.id' <<< "$row")"; ref="$(jq -r '.fix_ref' <<< "$row")"
      if why="$(review_fix_ref_violation "$ref" "$prev_tree" "$cur_tree" "$changed_list")"; then continue; fi
      errors="$(jq -c --arg id "$id" --arg obs "$ref — $why" --arg exp "$REVIEW_FIX_REF_RULE" \
        '. + [{issue_id:$id, field:"fix_ref", observed:$obs, expected:$exp, rule_id:"INVALID_FIX_REF"}]' <<< "$errors")" || return 1
    done < <(jq -c '.issues[] | select((.origin=="FIX_REGRESSION" or .origin=="NEWLY_EXPOSED_BY_FIX") and .fix_ref!="") | {id, fix_ref}' "$review")
    rm -f "$changed_list"
  fi
  # verdict ↔ issues 일관성(스키마만 통과했다고 올바른 리뷰로 간주하지 않는다)
  jq -c --slurpfile r "$review" '
    ($r[0].verdict) as $v | ($r[0].issues|length) as $n
    | if ($v=="APPROVE" and $n>0) or ($v=="REQUEST_CHANGES" and $n==0)
      then . + [{issue_id:"", field:"verdict", observed:("verdict=" + $v + " / issues=" + ($n|tostring)), expected:"APPROVE 는 issues 0개, REQUEST_CHANGES 는 1개 이상", rule_id:"VERDICT_INCONSISTENT"}]
      else . end' <<< "$errors"
}

attempt=""; round=1; next_step="REVIEWER_PENDING"
prev_review=""; prev_tree=""; prev_fingerprint_issues=""
invalid_resume=0; reuse_review=0
if invalid_review_active; then
  if [ "$NEW_ATTEMPT" = 1 ]; then
    # 명시적 새 리뷰 시도: 무효 기록을 닫고(보존) 새 attempt Round 1 로. 이전 attempt 의 미수용 세션 key 는 다시 쓰이지 않는다(marker·스테이징은 건드리지 않는다).
    echo "[$(date '+%F %T')] 명시적 새 리뷰 시도(--new-attempt) — 무효 출력 기록(attempt $(invalid_review_field '.attempt') round $(invalid_review_field '.round'))을 닫고 새 attempt Round 1 부터 리뷰"
    invalid_review_close SUPERSEDED "explicit new review attempt" || { echo "[FAIL] invalid-review.json 갱신 실패" >&2; exit 1; }
    save_review_checkpoint "$(invalid_review_field '.attempt')" 0 NONE "" "" ""
  else
    invalid_resume=1
    attempt="$(invalid_review_field '.attempt')"; round="$(invalid_review_field '.round')"
    prev_review="$(invalid_review_field '.input.prev_review')"; prev_tree="$(invalid_review_field '.input.prev_tree')"
  fi
elif [ "$NEW_ATTEMPT" = 1 ]; then
  echo "[WARN] --new-attempt 지정됐지만 대기 중인 REVIEW_OUTPUT_INVALID 기록이 없음 — 무시하고 일반 재개 규칙을 따른다"
fi
if [ "$invalid_resume" = 0 ] && [ -f "$RESUME_STATE" ]; then
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
        approve_ok=0
        if [ "$ck_wt_fp" = "$cur_wt_fp" ] && [ "$ck_review" = "$ck_dir/reviewer-round-$(printf '%02d' "${ck_round:-0}").json" ] \
           && valid_impl_approve_review "$ck_review" && ! review_approval_docs_current "$RESUME_STATE"; then
          echo "[$(date '+%F %T')] 작업 트리는 승인 당시와 같지만 계약 문서(request/design/implementation/approach·사용자 결정·conventions.md)가 승인 당시와 다르다 — 그 APPROVE 는 다른 계약에 대한 승인이므로 재사용하지 않는다"
        elif [ "$ck_wt_fp" = "$cur_wt_fp" ] && [ "$ck_review" = "$ck_dir/reviewer-round-$(printf '%02d' "${ck_round:-0}").json" ] \
           && valid_impl_approve_review "$ck_review"; then
          approve_ok=1
          if ! jq -e --argjson kv "$REVIEW_CHECKER_VERSION" '.checker_version==$kv' "$RESUME_STATE" >/dev/null 2>&1; then
            # 이 승인은 다른(또는 기록되지 않은) 검사기 버전이 통과시켰다 — 그대로 믿지 않고 저장된 출력을 현재 검사기로 재검증한다(모델 0회).
            # APPROVE 는 issues 가 0개여야 하므로 직전 리뷰·tree 없이도 판정이 같다(issue 가 하나라도 있으면 VERDICT_INCONSISTENT).
            ck_errors="$(validate_review_output "$ck_review" "$ck_round" "" "" "$ck_tree")" || { echo "[FAIL] 승인 출력 재검증 실행 실패(검사기 오류): $ck_review" >&2; exit 1; }
            if [ "$(jq 'length' <<< "$ck_errors")" -gt 0 ]; then
              echo "[WARN] 기존 승인 출력이 현재 검사기(v$REVIEW_CHECKER_VERSION, 체크포인트 v$(jq -r '.checker_version // "없음"' "$RESUME_STATE"))로는 무효 — 승인을 재사용하지 않는다"
              print_review_errors "$ck_errors"
              approve_ok=0
            else
              echo "[$(date '+%F %T')] 기존 승인 출력을 현재 검사기(v$REVIEW_CHECKER_VERSION)로 로컬 재검증 — 유효(리뷰어 호출 없음), 체크포인트의 검사기 버전 갱신"
              save_review_checkpoint "$ck_attempt" "$ck_round" APPROVE "$ck_review" "$ck_tree" "$ck_wt_fp" "$(jq -c '.contract_docs_sha256' "$RESUME_STATE")"
            fi
          fi
        fi
        if [ "$approve_ok" = 1 ]; then
          echo "=== 기존 승인 체크포인트 재사용 (attempt $ck_attempt round $ck_round, 작업 트리 변경 없음) ==="
          printf '%s\n' "$ck_wt_fp" | tee "$ck_dir/approved.fingerprint" > "$WORK_DIR/approved.fingerprint"
          jq -n --arg r "$ck_round" --arg a "$ck_attempt" '{phase:"impl", status:"APPROVE", rounds:($r|tonumber), attempt:($a|tonumber)}' > "$WORK_DIR/state.json"
          exit 0
        fi
        echo "[$(date '+%F %T')] 기존 승인이 현재 작업 트리·계약·검사기에 대해 유효하지 않음 — 새 attempt 로 Round 1 부터 리뷰";;
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
      REVIEW_OUTPUT_INVALID) echo "[$(date '+%F %T')] 무효 출력 체크포인트지만 active 한 invalid-review.json 이 없음(닫힘) — 새 attempt 로 Round 1 부터 리뷰";;
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
  close_revalidated_review   # 재검증으로 수용한 리뷰가 사용자 반환으로 끝난 경우 — 체크포인트 전환(초기화) 뒤에 닫는다
  exit "$rc"
}


# 리뷰 입력 지문: 같은 입력 + 같은 계약일 때만 저장된 출력을 로컬 재검증·재사용한다.
# 리뷰어가 기준 문서로 읽는 계약 문서(prompts/reviewer.md 의 입력: implementation·approach·design·request·decisions)의 **내용** 해시를 넣는다 —
# 코드(tree)가 그대로여도 계약이 바뀌었으면 저장된 출력은 다른 계약에 대한 리뷰다. 파일별로 따로 들어 무엇이 달라졌는지 진단할 수 있게 한다.
# 검사기 버전(REVIEW_CHECKER_VERSION)은 넣지 않는다 — 입력이 아니라 판정 도구이고, 넣으면 검사기를 고친 뒤의 로컬 재검증이 불가능해진다.
# (문서 목록·해시 계산은 config.sh review_contract_docs_json — 승인 캐시의 계약 문서 지문과 같은 함수다.)
review_input_json() { # prev_review prev_tree cur_tree approval_fingerprint
  local prev_sha="" conv_sha="ABSENT" base_tree docs
  docs="$(review_contract_docs_json)" || return 1
  if [ -n "$1" ]; then prev_sha="$(sha256_stdin < "$1")" || return 1; fi
  if [ -n "$CONVENTIONS_REF" ]; then conv_sha="$(sha256_stdin < "$CONVENTIONS_REF")" || return 1; fi
  base_tree="$(git rev-parse -q --verify "$REVIEW_BASE^{tree}")" || return 1
  jq -nc --arg prev_tree "$2" --arg cur_tree "$3" --arg base "$base_tree" --arg fp "$4" --arg scope "$(feature_scope_hash)" \
    --arg prev_review "$1" --arg prev_sha "$prev_sha" --argjson cv "$REVIEWER_CONTRACT_VERSION" --arg conv "$conv_sha" --argjson docs "$docs" \
    '{prev_tree:$prev_tree, cur_tree:$cur_tree, review_base:$base, approval_fingerprint:$fp, scope_hash:$scope,
      prev_review:$prev_review, prev_review_sha256:$prev_sha, reviewer_contract_version:$cv, conventions_sha256:$conv, contract_docs_sha256:$docs}'
}
record_invalid_review() { # review round errors-json input-json label session_key
  jq -n --argjson v "$INVALID_REVIEW_VERSION" --argjson attempt "$attempt" --argjson round "$2" --arg review "$1" --arg sha "$(sha256_stdin < "$1")" \
    --arg inv "${RUN_READONLY_INVOCATION_ID:-}" --arg label "$5" --arg key "$6" --argjson errors "$3" --argjson input "$4" \
    --arg ifp "$(printf '%s' "$4" | jq -Sc . | sha256_stdin)" --argjson kv "$REVIEW_CHECKER_VERSION" --arg now "$(date '+%FT%T%z')" \
    '{version:$v, active:true, status:"REVIEW_OUTPUT_INVALID", attempt:$attempt, round:$round, review:$review, result_sha256:$sha,
      invocation_id:$inv, label:$label, session_key:$key, input:$input, input_fingerprint:$ifp, checker_version:$kv, errors:$errors, recorded_at:$now}' \
    > "$INVALID_REVIEW.tmp" && mv "$INVALID_REVIEW.tmp" "$INVALID_REVIEW"
}

# ---------- 무효 출력 재개 판정 (모델 호출 전) ----------
if [ "$invalid_resume" = 1 ]; then
  inv_review="$(invalid_review_field '.review')"
  { [ "$inv_review" = "$ATTEMPT_DIR/reviewer-round-$(printf '%02d' "$round").json" ] && [ -f "$inv_review" ] \
    && [ "$(sha256_stdin < "$inv_review")" = "$(invalid_review_field '.result_sha256')" ]; } \
    || stop_review_output_invalid "저장된 원본 결과 JSON 이 없거나 기록 당시와 내용이 다르다 — 로컬 재검증 불가, 명시적 새 리뷰 시도가 필요하다"
  { { [ -z "$prev_review" ] || [ -f "$prev_review" ]; } && { [ -z "$prev_tree" ] || git cat-file -e "$prev_tree^{tree}" 2>/dev/null; }; } \
    || stop_review_output_invalid "직전 리뷰 JSON 또는 tree 가 없어 리뷰 입력을 재구성할 수 없다 — 명시적 새 리뷰 시도가 필요하다"
  inv_cur_tree="$(snapshot_worktree_tree)" || { echo "[FAIL] 작업 트리 스냅샷(tree 객체) 생성 실패" >&2; exit 1; }
  inv_fp="$(compute_approval_fingerprint)" || exit 1
  inv_input="$(review_input_json "$prev_review" "$prev_tree" "$inv_cur_tree" "$inv_fp")" || { echo "[FAIL] 리뷰 입력 지문 계산 실패" >&2; exit 1; }
  if [ "$(printf '%s' "$inv_input" | jq -Sc . | sha256_stdin)" != "$(invalid_review_field '.input_fingerprint')" ]; then
    # 어느 입력이 달라졌는지 기록 당시 input 과 필드별로 대조해 알려 준다(계약 문서는 파일 단위). 기록에 없던 필드(옛 기록)도 '달라짐'이다 — 같다고 증명할 수 없다.
    inv_changed="$(jq -r --argjson cur "$inv_input" '
      (.input // {}) as $old
      | [ (($old + $cur) | keys[]) as $k
          | if $k == "contract_docs_sha256" then ((($old[$k] // {}) + ($cur[$k] // {})) | keys[]) as $d | select(($old[$k] // {})[$d] != ($cur[$k] // {})[$d]) | "계약 문서 " + $d
            else select($old[$k] != $cur[$k]) | $k end ] | join(", ")' "$INVALID_REVIEW" 2>/dev/null)" || inv_changed=""
    stop_review_output_invalid "리뷰 입력(작업 트리·범위·직전 리뷰·기준선·conventions·계약 문서 내용) 또는 리뷰어 계약 버전이 무효 출력 당시와 다르다(달라진 항목: ${inv_changed:-알 수 없음}) — 저장된 출력은 지금의 입력에 대한 리뷰가 아니므로 재사용할 수 없다, 명시적 새 리뷰 시도가 필요하다"
  fi
  inv_errors="$(validate_review_output "$inv_review" "$round" "$prev_review" "$prev_tree" "$inv_cur_tree")" || { echo "[FAIL] 리뷰 출력 검사 실행 실패(검사기 오류): $inv_review" >&2; exit 1; }
  if [ "$(jq 'length' <<< "$inv_errors")" -gt 0 ]; then
    # 현재 검사기로도 무효 — 진단을 현재 검사기 기준으로 갱신만 하고(원본·지문은 그대로) 모델 호출 없이 멈춘다
    jq --argjson errors "$inv_errors" --argjson kv "$REVIEW_CHECKER_VERSION" --arg now "$(date '+%FT%T%z')" '.errors=$errors | .checker_version=$kv | .last_checked_at=$now' "$INVALID_REVIEW" > "$INVALID_REVIEW.tmp" && mv "$INVALID_REVIEW.tmp" "$INVALID_REVIEW" \
      || { echo "[FAIL] invalid-review.json 갱신 실패" >&2; exit 1; }
    stop_review_output_invalid "같은 입력·같은 계약의 재실행 — 리뷰어를 다시 부르지 않고 저장된 출력을 현재 검사기로 재검증했으나 여전히 무효"
  fi
  echo "=== 저장된 리뷰 출력이 현재 검사기로 유효 (attempt $attempt round $round, 입력 동일) — 리뷰어를 다시 부르지 않고 그 출력을 그대로 처리한다 ==="
  reuse_review=1; next_step="REVIEWER_PENDING"
  [ -z "$prev_review" ] || prev_fingerprint_issues=$(jq -Sc '[.issues[] | {id, category, code_refs, required_outcome}] | sort_by(.id)' "$prev_review")
fi

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
  # 이 리뷰가 기준으로 읽는 계약 문서의 지문 — 승인 체크포인트에 남기고, 승인 직전에 다시 대조한다(리뷰 도중 계약이 바뀐 승인을 남기지 않는다)
  review_docs="$(review_contract_docs_json approval)" || { echo "[FAIL] 계약 문서 지문 계산 실패" >&2; exit 1; }
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
  if [ -n "$prev_review" ]; then
    fix_diff="$ATTEMPT_DIR/fix-diff-round-$tag.patch"
    fix_files="$ATTEMPT_DIR/fix-files-round-$tag.txt"
    scoped_diff "$prev_tree" "$cur_tree" > "$fix_diff"
    scoped_diff --no-renames --name-only "$prev_tree" "$cur_tree" > "$fix_files"
    prev_context="이번은 Round $round(종결 검토)다. 입력: 직전 리뷰 JSON = $prev_review, 수정자의 ACCEPT/REJECT 기록 = $WORK_DIR/decisions.md 의 [fix round $((round - 1))] 줄, 직전 리뷰 이후 수정자가 바꾼 diff = $fix_diff(무엇이 바뀌었는지 읽는 용도), 그 수정으로 실제 바뀐 소스 파일 목록 = $fix_files, 현재 전체 diff = $diff_file. 이번 라운드에서 허용되는 issue 는 세 종류뿐이며 origin 으로 표시한다: UNRESOLVED_PREVIOUS(직전 이슈가 미해결 — id 와 previous_issue_id 에 직전 리뷰의 같은 id, fix_ref 는 빈 문자열) / FIX_REGRESSION(수정이 새로 만든 직접 회귀 — previous_issue_id 는 빈 문자열, fix_ref 필수) / NEWLY_EXPOSED_BY_FIX(직전 라운드에는 볼 수 없었던 문제가 수정으로 처음 드러남 — previous_issue_id 는 빈 문자열, fix_ref 필수). $REVIEW_FIX_REF_RULE. fix_ref 의 경로는 $fix_files 의 한 줄과 정확히 같아야 하며, $fix_diff 자체나 그 안의 행 번호를 가리키면 러너가 출력을 거부한다. 직전 라운드 당시 이미 볼 수 있었던 별개의 문제는 제기하지 마라. 해결된 이슈는 제외한다. REJECT 된 이슈는 새로운 근거 위치가 없으면 재제기하지 마라."
  fi

  reviewer_prompt="$(REFERENCE_CODE="$(load_reference_code)" DIFF_FILE="$diff_file" STATUS_FILE="$status_file" WORK_DIR="$WORK_DIR" \
       WORKER_RESULT="$WORK_DIR/worker-result.json" PREV_CONTEXT="$prev_context" REVIEWER_CONTRACT_VERSION="$REVIEWER_CONTRACT_VERSION" CONVENTIONS_FILE="$CONVENTIONS_REF" \
      render_prompt "$SKILL_DIR/prompts/reviewer.md" '${REFERENCE_CODE} ${DIFF_FILE} ${STATUS_FILE} ${WORK_DIR} ${WORKER_RESULT} ${PREV_CONTEXT} ${REVIEWER_CONTRACT_VERSION} ${CONVENTIONS_FILE}')"
  # 리뷰어 CLI 는 REVIEWER_MODEL 로 라우팅. 결과 JSON 은 $review, 원문은 $review.raw(claude) / $review.events.jsonl + $review.stderr.log(codex).
  if [ "$reuse_review" = 1 ]; then
    echo "--- 리뷰어 호출 생략: 저장된 출력 재사용 ($review, invocation $(invalid_review_field '.invocation_id')) ---"
  else
    run_readonly_json_role REVIEWER "reviewer-a$attempt_tag" "impl-review-a$attempt_tag-round-$tag" "$SCHEMA_FILE" "$review" "$reviewer_prompt" "$PROJECT_CONVENTIONS" \
      || exit 1
  fi
  # 출력 계약 검사: 스키마 → 버전 → origin/ref → verdict 일관성. 위반은 '재리뷰 예약'이 아니라 REVIEW_OUTPUT_INVALID 다 —
  # 원본 결과·이벤트·invocation id 를 그대로 두고 구조화 진단을 기록한 뒤 exit 4. 세션을 수용하지 않고 수정자도 부르지 않는다.
  review_errors="$(validate_review_output "$review" "$round" "$prev_review" "$prev_tree" "$cur_tree")" \
    || { echo "[FAIL] 리뷰 출력 검사 실행 실패(검사기 오류): $review" >&2; exit 1; }
  if [ "$(jq 'length' <<< "$review_errors")" -gt 0 ]; then
    if [ "$reuse_review" = 1 ]; then
      # 재개 판정이 방금 유효로 본 출력이 여기서 무효다 = 그 사이 입력이 바뀌었다. 기록은 active 그대로 두고 멈춘다(다음 실행이 입력 지문으로 다시 판정)
      stop_review_output_invalid "저장된 출력 재사용 도중 리뷰 입력이 바뀜"
    fi
    review_input="$(review_input_json "$prev_review" "$prev_tree" "$cur_tree" "$review_fingerprint")" || { echo "[FAIL] 리뷰 입력 지문 계산 실패" >&2; exit 1; }
    record_invalid_review "$review" "$round" "$review_errors" "$review_input" "impl-review-a$attempt_tag-round-$tag" "reviewer-a$attempt_tag" \
      || { echo "[FAIL] invalid-review.json 기록 실패" >&2; exit 1; }
    save_review_checkpoint "$attempt" "$round" REVIEW_OUTPUT_INVALID "$prev_review" "$prev_tree" ""
    stop_review_output_invalid "리뷰어 응답 수신 직후 검사"
  fi
  if [ "$reuse_review" = 1 ]; then
    # 여기서 닫지 않는다 — 아래 세션 확정과 이 리뷰의 체크포인트 전환(APPROVE / FIXER_PENDING / 사용자 반환)이 끝난 뒤 close_revalidated_review 가 닫는다
    revalidated_pending=1; reuse_review=0
  fi
  verdict=$(jq -er '.verdict' "$review")
  issue_count=$(jq '.issues | length' "$review")
  echo "리뷰어 verdict: $verdict / issues: $issue_count"
  jq -r '.issues[]? | "  [\(.id)] \(.category) / \(.evidence_type) / \(.action) / origin=\(.origin)\n      코드: \(.code_refs | join(", "))" + (if (.basis_refs|length)>0 then "\n      근거: \(.basis_refs | join(", "))" else "" end) + (if .reachable_scenario != "" then "\n      경로: \(.reachable_scenario)\n      영향: \(.impact)" else "" end) + "\n      지금 막는 이유: \(.why_blocks_now)" + "\n      → 필요한 결과: \(.required_outcome)"' "$review"

  # 스키마·계약·근거·일관성 게이트를 모두 지난 뒤에만 이 invocation 의 세션을 수용한다 — 리뷰어 세션은 같은 attempt 안에서만
  # 재사용되고(claude --resume / codex exec resume), 거부된 응답의 대화는 다음 실행이 잇지 않는다. attempt 가 바뀌면 key 가 바뀌어 fresh 다.
  role_session_accept REVIEWER "reviewer-a$attempt_tag" "impl-review-a$attempt_tag-round-$tag" \
    || { echo "[FAIL] 리뷰어 세션 확정 실패" >&2; exit 1; }

  # 승인은 verdict 와 issues 가 일치할 때만 인정 (조건부 스키마는 validate_review_output 이 강제) — 저장된 출력을 재사용한 경우에도
  # 아래 승인 지문 재확인을 그대로 거친다(재개 판정이 입력 지문에 승인 지문을 포함해 대조했다)
  if [ "$verdict" = "APPROVE" ]; then
    current_fingerprint=$(compute_approval_fingerprint)
    if [ "$current_fingerprint" != "$review_fingerprint" ]; then
      echo "[FAIL] 리뷰 도중 작업 트리가 변경됨 — 리뷰되지 않은 변경은 승인할 수 없음. 재실행 필요." >&2
      exit 1
    fi
    if [ "$(review_contract_docs_json approval)" != "$review_docs" ]; then
      echo "[FAIL] 리뷰 도중 계약 문서(request/design/implementation/approach·사용자 결정·conventions.md)가 변경됨 — 다른 계약에 대한 리뷰는 승인할 수 없음. 재실행 필요." >&2
      exit 1
    fi
    echo "=== 구현 리뷰 승인 (round $round) ==="
    # 승인된 것은 '리뷰 입력 스냅샷' 상태다 — Phase 4 진입·커밋 직전에 verify_approved_fingerprint 로 검증
    printf '%s\n' "$review_fingerprint" | tee "$ATTEMPT_DIR/approved.fingerprint" > "$WORK_DIR/approved.fingerprint"
    # 승인도 체크포인트로 남긴다 — 러너가 다음 stage 를 기록하기 전에 죽어도 트리가 그대로면 리뷰어를 다시 부르지 않는다
    save_review_checkpoint "$attempt" "$round" APPROVE "$review" "$cur_tree" "$review_fingerprint" "$review_docs"
    close_revalidated_review
    jq -n --arg r "$round" --arg a "$attempt" '{phase:"impl", status:"APPROVE", rounds:($r|tonumber), attempt:($a|tonumber)}' > "$WORK_DIR/state.json"
    exit 0
  fi

  # DOC_GAP: 구현 중 드러난 solution-shape 미결정 — 사용자 판단이다. 수정자도 impl 재합의도 부르지 않고 리뷰 전체를 체크포인트(doc-gap-resume.json,
  # source tree 포함)한 뒤 사용자에게 돌려보낸다. 같은 리뷰의 FIX_CODE 는 사용자가 답한 뒤 review-gap 워커 1회가 DOC_GAP 결정과 함께 처리한다
  # (수정자를 먼저 돌리지 않는다). exit 3 = 러너가 NEED_USER(REVIEW_DOC_GAP) 로 반환.
  doc_ids=$(jq -r '[.issues[] | select(.action=="DOC_GAP") | .id] | join(",")' "$review")
  if [ -n "$doc_ids" ]; then
    doc_gap_record_review "$review" "$attempt" "$round" "$cur_tree" || { echo "[FAIL] doc-gap-resume.json 기록 실패" >&2; exit 1; }
    echo "[STOP] 리뷰어 DOC_GAP($doc_ids) — 사용자 결정 필요. 답을 decisions.md 에 '- [USER-QUESTION][scope=impl][<tag>] <질문> → <답>'(tag: $(doc_gap_field '[.gaps[].tag] | join(", ")')) 으로 기록하고 approach.md 에 반영한 뒤 재실행(검증자·디자이너 없이 review-gap 워커 → 리뷰)." >&2
    jq -r '.issues[] | select(.action=="DOC_GAP") | "  [\(.id)] \(.user_question)\n      선택지: \(.options | join(" | "))"' "$review" >&2
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
  close_revalidated_review
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
  fixer_prompt="$(REVIEW_FILE="$prev_review" WORK_DIR="$WORK_DIR" TEST_CMD="$TEST_CMD" ROUND="$round" BASELINE_TREE="$BASELINE_TREE" CONVENTIONS_FILE="$CONVENTIONS_REF" \
      render_prompt "$SKILL_DIR/prompts/fixer.md" '${REVIEW_FILE} ${WORK_DIR} ${TEST_CMD} ${ROUND} ${BASELINE_TREE} ${CONVENTIONS_FILE}')"
  # 호출 전 지문(작업 트리 범위 + decisions.md). rc≠0 이어도 허용 범위 안 변경이 있으면 같은 수정자를 다시 부르지 않는다.
  fix_fp_before="$(compute_fixer_resume_fingerprint)" || { echo "[FAIL] 수정자 호출 전 지문 계산 실패" >&2; exit 1; }
  set +e
  # 수정자 CLI 는 FIXER_MODEL 로 라우팅(codex 는 --sandbox workspace-write, claude 는 acceptEdits + Bash 허용).
  run_edit_role FIXER "fixer-a$attempt_tag" "impl-fix-a$attempt_tag-round-$tag" "$fix_result" "$fixer_prompt" "$PROJECT_CONVENTIONS" "" "" --allowedTools "Bash"
  fixer_rc=$?
  set -e
  # codex resume marker 는 "호출이 스레드에 도달했는지 모른다"를 막는 장치다 — CLI 가 반환된 지금은 해소됐다(워커와 같은 편집 역할 의미).
  # 결과 판정은 아래 index·manifest·기준선·write-set·지문 게이트가 하고, 게이트 중단 뒤의 재실행은 같은 스레드의 '의도된 새 턴'이다.
  # (호출 도중 프로세스가 죽으면 marker 가 남아 codex_session_begin 이 모델 0회로 멈춘다 — 그 계약은 그대로다. 리뷰어(읽기 전용) marker 는 건드리지 않는다.)
  [ "$(role_cli FIXER)" != codex ] || rm -f "$(codex_resume_marker "fixer-a$attempt_tag")"
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
  # ---------- CLI 판정 (위 index → manifest → 기준선 → write-set 게이트를 모두 지난 뒤에만) ----------
  if [ "$fixer_rc" -ne 0 ]; then
    fix_fp_after="$(compute_fixer_resume_fingerprint)" || { echo "[FAIL] 수정자 호출 후 지문 계산 실패" >&2; exit 1; }
    if [ "$fix_fp_after" = "$fix_fp_before" ]; then
      # 코드·decisions 변경 없음 → 기존 실패. 같은 수정자 재실행은 안전하다(체크포인트 FIXER_PENDING 그대로).
      echo "[FAIL] 수정자 실행 실패 (모델 '$FIXER_MODEL' 확인). 재실행 시 attempt $attempt round $round / FIXER_PENDING 부터 재개" >&2; exit 1
    fi
    # 허용 범위 안 변경 있음 → '수정자 성공' 으로 간주하는 것이 아니다. 같은 수정을 반복하지 않고 다음 리뷰어가 partial/incomplete fix 를 독립 판정한다.
    echo "[WARN] CLI_EXIT_STATUS_MISMATCH: FIXER $(role_cli FIXER) exited $fixer_rc, but current invocation changed the working tree/decisions within scope; forwarding to the reviewer instead of replaying the fixer"
    record_cli_anomaly FIXER "$(role_cli FIXER)" "impl-fix-a$attempt_tag-round-$tag" "$fixer_rc" FORWARD_TO_REVIEWER "$fix_result"
  fi
  # index·manifest·기준선·write-set 게이트와 CLI 판정을 지나 이 수정 결과가 다음 리뷰로 넘어가는 시점 — 수정자 세션도 attempt 단위로 수용한다.
  role_session_accept FIXER "fixer-a$attempt_tag" "impl-fix-a$attempt_tag-round-$tag" \
    || { echo "[FAIL] 수정자 세션 확정 실패" >&2; exit 1; }
  echo "--- 수정자 판정 (decisions.md 신규 기록) ---"
  tail -n +"$((decisions_lines_before + 1))" "$WORK_DIR/decisions.md" | sed 's/^/  /'

  # 수정자 성공(또는 변경 있음 + rc 불일치) → 다음 라운드 리뷰 대기 상태로 전환
  round=$((round + 1))
  next_step="REVIEWER_PENDING"
  save_review_checkpoint "$attempt" "$round" "$next_step" "$prev_review" "$prev_tree" "$(compute_fixer_resume_fingerprint)"
  fi # FIXER_PENDING
done

echo "[STOP] $MAX_IMPL_ROUNDS 라운드 내 승인 실패. 남은 이슈를 사용자에게 보고." >&2
stop_with 2 MAX_ROUNDS_EXCEEDED --arg review "$prev_review"
