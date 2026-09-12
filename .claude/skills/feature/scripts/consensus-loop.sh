#!/usr/bin/env bash
# =============================================================
# 문서 합의 루프: 디자이너(문서 소유자) ↔ 검증자 수렴 강제
# 파일 경로: .claude/skills/feature/scripts/consensus-loop.sh
# 사용법: consensus-loop.sh [design|impl]  (저장소 루트에서 실행)
#   design: $WORK_DIR/design.md 합의 (오케스트레이터가 초안을 먼저 작성)
#   impl  : $WORK_DIR/implementation.md(무엇) + approach.md(어떻게) 합의 (design 합의 후 실행)
# 종료 코드: 0=PASS 수렴, 2=라운드 초과/교착, 1=환경 오류
# 리뷰는 MAX_SPEC_ROUNDS+1 회 — 마지막 수정도 반드시 재검증한다.
# 재개: $WORK_DIR/consensus-<target>.json 에 round/next_step(VALIDATOR_PENDING|DESIGNER_PENDING|PASS)·
#   리뷰·스냅샷 경로·입력 지문을 남긴다. 디자이너 호출이 실패하면 재실행 시 검증자를 다시 부르지 않고
#   같은 리뷰 JSON 으로 디자이너만 재시도한다. PASS 도 지문과 함께 캐시한다.
# =============================================================
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.sh"
PROJECT_CONVENTIONS="$(load_project_conventions)"

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
for bin in jq uuidgen envsubst; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[FAIL] '$bin' 미설치. 중단." >&2; exit 1; }
done
[ -f "$TARGET_DOC" ] || { echo "[FAIL] $TARGET_DOC 없음. 오케스트레이터가 초안을 먼저 작성해야 함." >&2; exit 1; }
if [ "$TARGET" = "impl" ]; then
  [ -f "$WORK_DIR/design.md" ] || { echo "[FAIL] $WORK_DIR/design.md 없음. 설계 합의가 먼저다." >&2; exit 1; }
  [ -f "$WORK_DIR/approach.md" ] || { echo "[FAIL] $WORK_DIR/approach.md 없음. 구현 문서는 implementation.md(무엇)와 approach.md(어떻게) 두 개가 모두 있어야 한다." >&2; exit 1; }
  # 구현 단위 manifest 는 러너가 impl 단계 진입 전에 요구한다. 루프 단독 실행·회귀 픽스처에서는 없어도 되므로 여기서는 경고만 한다.
  [ -f "$WORK_DIR/implementation-units.json" ] || echo "[WARN] $WORK_DIR/implementation-units.json 없음 — 구현 단위 분할은 검증되지 않는다(러너 실행에서는 impl 진입 전에 필수)"
fi
for prompt_file in "$VALIDATOR_PROMPT_FILE" "$DESIGNER_PROMPT_FILE"; do
  [ -f "$prompt_file" ] || { echo "[FAIL] 프롬프트 없음: $prompt_file" >&2; exit 1; }
done
# 검증자 오버레이(판정 전략)는 유료 호출 전에 한 번만 확정한다 — 프로필 이름이 있는데 파일이 없으면 여기서 중단.
VALIDATOR_OVERLAY="$(load_validator_overlay)" || exit 1
echo "검증자: $VALIDATOR_MODEL / effort=$VALIDATOR_EFFORT / profile=$(validator_profile)"
mkdir -p "$WORK_DIR/reviews"
touch "$WORK_DIR/decisions.md"

SCHEMA_FILE="$SKILL_DIR/schemas/spec-review.schema.json"
[ -f "$SCHEMA_FILE" ] || { echo "[FAIL] 스키마 없음: $SCHEMA_FILE" >&2; exit 1; }
# Round 2+ 입력용: 디자이너 수정 전 문서를 보관하고, 다음 라운드에 현재 문서와의 diff 를 검증자에게 준다.
# 파일 목록은 config.sh 의 consensus_docs_for — 스냅샷·diff·변경 파일·재개 지문이 같은 집합을 본다.
consensus_docs() { consensus_docs_for "$TARGET"; }
# 목록의 문서가 없을 수 있다(implementation-units.json 은 루프 단독 실행에서 선택) — 없는 쪽은 /dev/null 로 다뤄 생성·삭제도 변경으로 잡는다.
snapshot_docs() { # dir
  mkdir -p "$1"
  consensus_docs | while IFS= read -r doc; do if [ -f "$doc" ]; then cp "$doc" "$1/$(basename "$doc")"; fi; done
}
snapshot_changed_docs() { # dir → 스냅샷 대비 내용이 바뀐 문서의 basename 목록 (변경 없으면 빈 출력)
  consensus_docs | while IFS= read -r doc; do
    if [ -f "$1/$(basename "$doc")" ] || [ -f "$doc" ]; then cmp -s "$1/$(basename "$doc")" "$doc" || basename "$doc"; fi
  done
}
snapshot_docs_diff() { # dir → stdout (unified diff, 검증자 입력·사람 확인용. 변경 없으면 빈 출력)
  local before after
  consensus_docs | while IFS= read -r doc; do
    before="$1/$(basename "$doc")"; after="$doc"
    [ -f "$before" ] || before=/dev/null; [ -f "$after" ] || after=/dev/null
    if [ "$before" != /dev/null ] || [ "$after" != /dev/null ]; then diff -u "$before" "$after" || true; fi
  done
}

# ---------- round/substep 단위 체크포인트 ----------
# 러너의 run-state.json 은 stage(design|impl) 까지만 기억한다. 검증자는 끝났는데 디자이너 호출이
# 실패(모델 ID 오류 등)하면, 재실행 시 이미 돈 검증자 라운드를 다시 부르지 않도록 여기서
# "몇 라운드의 어느 단계부터 재개하는가"를 별도 파일에 남긴다.
#   next_step: VALIDATOR_PENDING | DESIGNER_PENDING | PASS
# review/snapshot 경로를 함께 저장해 DESIGNER_PENDING 재개가 같은 리뷰 JSON 을 그대로 쓰게 한다.
RESUME_STATE="$WORK_DIR/consensus-$TARGET.json"
# 지문은 config.sh 의 세 종류(editable / upstream / pass)를 항상 함께 저장한다. 어떤 것이 달라졌느냐가 재개 지점을 정한다.
save_consensus_checkpoint() { # round next_step review snapshot
  jq -n --arg target "$TARGET" --argjson version "$CONSENSUS_CHECKPOINT_VERSION" --argjson contract_version "$VALIDATOR_CONTRACT_VERSION" \
    --argjson round "$1" --arg next_step "$2" --arg review "${3:-}" --arg snapshot "${4:-}" \
    --arg editable "$(consensus_editable_fingerprint "$TARGET")" --arg upstream "$(consensus_upstream_fingerprint "$TARGET")" \
    --arg input "$(consensus_pass_fingerprint "$TARGET")" --arg now "$(date '+%FT%T%z')" \
    '{version:$version, target:$target, contract_version:$contract_version, round:$round, next_step:$next_step,
      review:$review, snapshot:$snapshot, editable_fingerprint:$editable, upstream_fingerprint:$upstream,
      input_fingerprint:$input, updated_at:$now}' \
    > "$RESUME_STATE.tmp" && mv "$RESUME_STATE.tmp" "$RESUME_STATE"
}
# 사용자 판단으로 넘어가는 종료(ASK_USER/DEADLOCK/MAX_ROUNDS)는 사용자가 문서를 고친 뒤 재실행하므로
# 라운드 중간이 아니라 Round 1 부터 다시 시작해야 한다 — 체크포인트를 초기 상태로 되돌린다(파일 삭제 대신 덮어쓰기).
reset_consensus_checkpoint() { save_consensus_checkpoint 1 "VALIDATOR_PENDING" "" ""; }
restart_from_round_1() { round=1; next_step="VALIDATOR_PENDING"; prev_review=""; prev_snapshot=""; }

round=1
next_step="VALIDATOR_PENDING"
prev_fingerprint=""   # 직전 라운드 blocker 내용 지문 (교착 감지용)
prev_review=""
prev_snapshot=""
if [ -f "$RESUME_STATE" ]; then
  if ! jq -e --argjson cv "$CONSENSUS_CHECKPOINT_VERSION" '.version==$cv' "$RESUME_STATE" >/dev/null 2>&1; then
    # 포맷 버전이 다르면 지문의 의미가 다르다 — 비교하지 않고 처음부터 (건너뛰기 오판 방지)
    echo "[WARN] 합의 체크포인트 포맷 버전 불일치(현재 $CONSENSUS_CHECKPOINT_VERSION) — Round 1 부터 다시 검증"
  elif jq -e --arg t "$TARGET" --argjson v "$VALIDATOR_CONTRACT_VERSION" \
      '.target==$t and .contract_version==$v' "$RESUME_STATE" >/dev/null 2>&1; then
    round="$(jq -r '.round' "$RESUME_STATE")"
    next_step="$(jq -r '.next_step' "$RESUME_STATE")"
    prev_review="$(jq -r '.review // ""' "$RESUME_STATE")"
    prev_snapshot="$(jq -r '.snapshot // ""' "$RESUME_STATE")"
    saved_editable="$(jq -r '.editable_fingerprint // ""' "$RESUME_STATE")"
    saved_upstream="$(jq -r '.upstream_fingerprint // ""' "$RESUME_STATE")"
    cur_editable="$(consensus_editable_fingerprint "$TARGET")"
    cur_upstream="$(consensus_upstream_fingerprint "$TARGET")"
    case "$next_step" in
      PASS)
        # 지문 일치 + 리뷰 파일이 해당 round 의 실제 PASS 리뷰(현재 계약)일 때만 재사용 — 파일 존재만으로 복원하지 않는다
        if consensus_pass_current "$TARGET"; then
          echo "=== [$TARGET] 기존 PASS 체크포인트 재사용 (round $round, 입력 변경 없음) ==="
          jq -n --arg t "$TARGET" --arg r "$round" '{phase:$t, status:"PASS", rounds:($r|tonumber)}' > "$WORK_DIR/state.json"
          exit 0
        fi
        echo "[$(date '+%F %T')] 기존 PASS 가 현재 입력·계약에 대해 유효하지 않음 — Round 1 부터 다시 검증"
        restart_from_round_1;;
      DESIGNER_PENDING|VALIDATOR_PENDING)
        if [ "$next_step" = VALIDATOR_PENDING ] && [ "$round" -le 1 ]; then
          restart_from_round_1   # 초기 상태 — 검사할 이전 리뷰가 없다
        elif [ ! -f "$prev_review" ] || [ ! -d "$prev_snapshot" ]; then
          echo "[WARN] 체크포인트가 가리키는 리뷰/스냅샷 없음 — Round 1 부터 다시 검증"
          restart_from_round_1
        elif [ "$saved_upstream" != "$cur_upstream" ]; then
          # 상위 입력(request/design/사용자 결정)이 바뀌었다 — 저장된 리뷰는 옛 입력에 대한 것이라 무효
          echo "[$(date '+%F %T')] 상위 입력 문서 변경 감지 — 저장된 리뷰 무효, Round 1 부터 다시 검증"
          restart_from_round_1
        elif [ "$next_step" = DESIGNER_PENDING ] && [ "$saved_editable" != "$cur_editable" ]; then
          # 디자이너가 문서를 일부 고친 뒤 죽었거나 사람이 손댔다. 같은 수정을 다시 시키면 decisions.md 중복 기록·이중 수정 위험.
          echo "[WARN] 디자이너 호출 중 문서 변경 흔적 감지 — 같은 수정을 재실행하지 않고 다음 검증 라운드로 진행"
          round=$((round + 1)); next_step="VALIDATOR_PENDING"
          save_consensus_checkpoint "$round" "$next_step" "$prev_review" "$prev_snapshot"
        fi;;
      *) echo "[WARN] 알 수 없는 next_step '$next_step' — Round 1 부터 다시 검증"; restart_from_round_1;;
    esac
    [ -z "$prev_review" ] || prev_fingerprint=$(jq -Sc '[.blocking_issues[] | {id, evidence_type, basis_refs, minimum_contract_needed, user_question}] | sort_by(.id)' "$prev_review")
    echo "[$(date '+%F %T')] consensus-loop 재개: $TARGET round $round / $next_step"
  else
    echo "[WARN] 합의 체크포인트 계약 버전 불일치 — 현재 계약으로 Round 1 부터 다시 검증"
  fi
fi

while [ "$round" -le $((MAX_SPEC_ROUNDS + 1)) ]; do
  tag=$(printf '%02d' "$round")
  review="$WORK_DIR/reviews/validator-$TARGET-round-$tag.json"

  if [ "$next_step" = "VALIDATOR_PENDING" ]; then
  echo "=== [$TARGET] Round $round/$((MAX_SPEC_ROUNDS + 1)) : 검증자 검토 ==="

  # Round 1 은 입장 조건을 만족하는 문제를 전부 낸다. Round 2+ 는 재감사가 아니라 종결 검토다.
  prev_context="이번은 Round 1 이다. 입장 조건을 만족하는 문제를 이번 라운드에 전부 내라 — 다음 라운드로 미루지 마라. 모든 이슈의 origin 은 ROUND_1."
  if [ -n "$prev_review" ]; then
    docs_diff="$WORK_DIR/reviews/docs-diff-$TARGET-round-$tag.diff"
    snapshot_docs_diff "$prev_snapshot" > "$docs_diff" || true
    prev_context="이번은 Round $round(종결 검토)다. 입력: 직전 blocking issue JSON = $prev_review, 디자이너의 ACCEPT/REJECT 판정 = $WORK_DIR/decisions.md, 직전 라운드 이후 문서 diff = $docs_diff, 현재 문서. 이번 라운드에서 허용되는 blocking 은 세 종류뿐이며 origin 으로 표시한다: UNRESOLVED_PREVIOUS(직전 이슈가 미해결, previous_issue_id 에 같은 id) / REVISION_REGRESSION(직전 수정이 새로 만든 직접 회귀, revision_ref 에 diff 위치) / NEWLY_EXPOSED_BY_REVISION(Round 1 에는 없던 정보가 수정으로 처음 드러남, revision_ref 필수). 직전 라운드 당시 이미 볼 수 있었던 별개의 문제는 제기하지 마라. 해결된 이슈는 제외한다. REJECT 된 이슈는 새로운 근거 위치가 없으면 재제기하지 마라."
  fi

  # ---------- 검증자 검토: 읽기 전용, 스키마 강제 JSON (CLI 는 VALIDATOR_MODEL 로 라우팅) ----------
  # 공통 계약(validator-review-*.md) 뒤에 프로필 오버레이를 붙인다. 오버레이는 envsubst 를 거치지 않는다(치환 변수 없음).
  validator_prompt=$(PROJECT_CONVENTIONS="$PROJECT_CONVENTIONS" WORK_DIR="$WORK_DIR" PREV_CONTEXT="$prev_context" \
    render_prompt "$VALIDATOR_PROMPT_FILE" '${PROJECT_CONVENTIONS} ${WORK_DIR} ${PREV_CONTEXT}')"$VALIDATOR_OVERLAY"
  # conventions 는 검증자 프롬프트 본문에 이미 렌더링돼 있으므로 "" 를 넘긴다.
  run_readonly_json_role VALIDATOR validator "$TARGET-validator-round-$tag" "$SCHEMA_FILE" "$review" "$validator_prompt" "" \
    || exit 1

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
    # PASS 도 체크포인트로 남긴다 — 러너가 다음 stage 를 기록하기 전에 죽어도 재진입 시 검증자를 다시 부르지 않는다
    save_consensus_checkpoint "$round" "PASS" "$review" ""
    jq -n --arg t "$TARGET" --arg r "$round" '{phase:$t, status:"PASS", rounds:($r|tonumber)}' > "$WORK_DIR/state.json"
    exit 0
  fi

  # ASK_USER: 문서 재작성으로 풀리지 않는 문제(범위 밖 공용 컴포넌트 수정·제품 정책 선택)는 디자이너를 거치지 않고 즉시 사용자에게
  ask_ids=$(jq -r '[.blocking_issues[] | select(.action=="ASK_USER") | .id] | join(",")' "$review")
  if [ -n "$ask_ids" ]; then
    echo "[STOP] 검증자가 사용자 결정을 요구함($ask_ids). user_question / options 를 사용자에게 그대로 전달." >&2
    jq -n --arg t "$TARGET" --arg i "$ask_ids" --arg r "$review" '{phase:$t, status:"ASK_USER", issues:$i, review:$r}' > "$WORK_DIR/state.json"
    reset_consensus_checkpoint
    exit 2
  fi

  # 교착 감지: 이슈 '내용'까지 동일한 집합이 2라운드 연속이면 사람에게 에스컬레이션
  # (같은 id라도 reachable_scenario/minimum_contract_needed 가 달라지면 진전 중으로 본다)
  if [ -n "$ids" ] && [ "$fingerprint" = "$prev_fingerprint" ]; then
    echo "[STOP] 동일 이슈($ids)가 내용 변화 없이 2라운드 연속 반복됨. 사용자 판단 필요." >&2
    jq -n --arg t "$TARGET" --arg i "$ids" '{phase:$t, status:"DEADLOCK", issues:$i}' > "$WORK_DIR/state.json"
    reset_consensus_checkpoint
    exit 2
  fi
  prev_fingerprint="$fingerprint"
  prev_review="$review"

  # 마지막 검증 라운드였다면 수정 없이 종료 (수정은 항상 재검증 대상이어야 함)
  [ "$round" -le "$MAX_SPEC_ROUNDS" ] || break

  # 검증 완료 → 디자이너 호출 '전에' 체크포인트. 디자이너가 실패하면 이 상태가 그대로 남아
  # 재실행이 같은 리뷰 JSON 으로 디자이너만 다시 부른다.
  prev_snapshot="$WORK_DIR/reviews/docs-snapshot-$TARGET-round-$tag"
  snapshot_docs "$prev_snapshot"
  next_step="DESIGNER_PENDING"
  save_consensus_checkpoint "$round" "$next_step" "$prev_review" "$prev_snapshot"
  fi # VALIDATOR_PENDING

  if [ "$next_step" = "DESIGNER_PENDING" ]; then
  # ---------- 디자이너 응답: 각 이슈 ACCEPT/REJECT + 문서 갱신 ----------
  # 라운드 간 같은 세션을 이어가 저장소 재탐색 없이 프롬프트 캐시를 활용
  echo "--- 디자이너가 리뷰($(basename "$prev_review"))를 반영/반박합니다 ---"
  decisions_lines_before=$(wc -l < "$WORK_DIR/decisions.md")
  designer_result="$WORK_DIR/reviews/designer-$TARGET-round-$tag.raw"
  designer_prompt=$(REVIEW_FILE="$prev_review" WORK_DIR="$WORK_DIR" ROUND="$round" \
    render_prompt "$DESIGNER_PROMPT_FILE" '${REVIEW_FILE} ${WORK_DIR} ${ROUND}')
  run_edit_role DESIGNER designer-doc "$TARGET-designer-round-$tag" "$designer_result" "$designer_prompt" "$PROJECT_CONVENTIONS" "" "" \
    || { echo "[FAIL] 디자이너 실행 실패 (모델 '$DESIGNER_MODEL' 확인). 재실행 시 $TARGET round $round / DESIGNER_PENDING 부터 재개"; exit 1; }
  echo "--- 디자이너 판정 (decisions.md 신규 기록) ---"
  tail -n +"$((decisions_lines_before + 1))" "$WORK_DIR/decisions.md" | sed 's/^/  /'

  # 디자이너 성공 → 다음 라운드 검증 대기 상태로 전환
  round=$((round + 1))
  next_step="VALIDATOR_PENDING"
  save_consensus_checkpoint "$round" "$next_step" "$prev_review" "$prev_snapshot"
  fi # DESIGNER_PENDING
done

echo "[STOP] $MAX_SPEC_ROUNDS 라운드 내 수렴 실패. 쟁점을 사용자에게 보고하고 중단." >&2
jq -n --arg t "$TARGET" '{phase:$t, status:"MAX_ROUNDS_EXCEEDED"}' > "$WORK_DIR/state.json"
reset_consensus_checkpoint
exit 2
