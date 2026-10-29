#!/usr/bin/env bash
# =============================================================
# 문서 합의 루프: 디자이너(문서 소유자) ↔ 검증자 수렴 강제
# 파일 경로: .claude/skills/feature/scripts/consensus-loop.sh
# 사용법: consensus-loop.sh [design|impl]  (저장소 루트에서 실행)
#   design: $WORK_DIR/design.md 합의 (오케스트레이터가 초안을 먼저 작성)
#   impl  : $WORK_DIR/implementation.md(무엇) + approach.md(어떻게) 합의 (design 합의 후 실행)
# 종료 코드: 0=PASS 수렴, 2=라운드 초과/교착/ASK_USER/DESIGNER_SCOPE_VIOLATION(디자이너가 문서 밖 source 를 변경 — fail-closed), 1=환경 오류
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
# 검증자에게 conventions 는 run_readonly_json_role 인자("")가 아니라 프롬프트 본문의 ${PROJECT_CONVENTIONS} 로만 전달된다.
# 플레이스홀더가 빠진 프롬프트는 conventions.md 를 조용히 누락시키므로(2026-10-29 impl 검증자 사고) 유료 호출 전에 막는다.
grep -qF '${PROJECT_CONVENTIONS}' "$VALIDATOR_PROMPT_FILE" \
  || { echo "[FAIL] 검증자 프롬프트에 \${PROJECT_CONVENTIONS} 플레이스홀더 없음 — conventions.md 가 검증자에게 전달되지 않는다: $VALIDATOR_PROMPT_FILE" >&2; exit 1; }
# 검증자 오버레이(판정 전략)는 유료 호출 전에 한 번만 확정한다 — 프로필 이름이 있는데 파일이 없으면 여기서 중단.
VALIDATOR_OVERLAY="$(load_validator_overlay)" || exit 1
echo "검증자: $VALIDATOR_MODEL / effort=$VALIDATOR_EFFORT / profile=$(validator_profile)"
mkdir -p "$WORK_DIR/reviews"
touch "$WORK_DIR/decisions.md"
# scope 없는 옛 형식의 사용자 결정은 어느 단계 지문에 넣을지 추정하지 않는다 — 유료 호출 전에 중단(러너 preflight 와 같은 검사).
unscoped_decisions="$(consensus_unscoped_user_decisions)"
[ -z "$unscoped_decisions" ] || { echo "[FAIL] DECISION_SCOPE_REQUIRED: decisions.md 에 scope 없는 [USER-QUESTION] 줄이 있음 — '[USER-QUESTION][scope=design]' 또는 '[USER-QUESTION][scope=impl]' 로 직접 고친 뒤 재실행. 해당 줄: $(printf '%s' "$unscoped_decisions" | paste -sd'|' -)" >&2; exit 1; }

SCHEMA_FILE="$SKILL_DIR/schemas/spec-review.schema.json"
[ -f "$SCHEMA_FILE" ] || { echo "[FAIL] 스키마 없음: $SCHEMA_FILE" >&2; exit 1; }
# 직전 디자이너 호출이 source 작업 트리를 바꿔 멈췄으면, 복구 전에는 검증자·디자이너를 부르지 않는다(모델 호출 0회, 자동 원복 없음)
if ! require_designer_scope_guard_resolved; then
  jq -n --arg t "$TARGET" --arg e "$(jq -r .expected "$DESIGNER_SCOPE_GUARD")" '{phase:$t, status:"DESIGNER_SCOPE_VIOLATION", expected:$e}' > "$WORK_DIR/state.json"
  exit 2
fi
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
  # decisions.md 는 뺀다 — 직전 라운드 이후 거기 추가되는 것은 디자이너의 [round N] ACCEPT/REJECT 사유뿐이고(사용자 결정이 바뀌면 upstream 지문이 Round 1 로 되돌린다),
  # 그 사유는 종결 검증자의 판정 입력이 아니다. 변경 파일 계산(snapshot_changed_docs)과 재개 지문은 그대로 decisions.md 를 본다.
  local before after
  consensus_docs | while IFS= read -r doc; do
    [ "$(basename "$doc")" != decisions.md ] || continue
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
    # 종결 검증자는 fresh 세션이고, 직전 라운드에서 넘어오는 것은 blocker 의 구조화된 주장·증거(identity·증거 위치·실행 경로·영향·요구 불변식)뿐이다.
    # reasoning 은 끊되 evidence 는 끊지 않는다: 직전 검증자의 자유 서술(why_blocks_now)과 디자이너의 ACCEPT/REJECT 사유는 넘기지 않는다 — 현재 문서·diff·저장소로 다시 판정시킨다.
    prev_blockers="$WORK_DIR/reviews/prev-blockers-$TARGET-round-$tag.json"
    jq '[.blocking_issues[] | {id, category, evidence_type, basis_refs, conflict_refs, code_refs, reachable_scenario, impact, minimum_contract_needed}]' "$prev_review" > "$prev_blockers" \
      || { echo "[FAIL] 직전 blocker 요약 생성 실패: $prev_review" >&2; exit 1; }
    prev_context="이번은 Round $round(종결 검토)다. 입력: 직전 blocker 의 주장과 증거 = $prev_blockers (id / category / evidence_type / basis_refs / conflict_refs / code_refs / reachable_scenario = 주장된 실행 경로 / impact = 주장된 영향 / minimum_contract_needed = 요구된 최소 불변식), 직전 라운드 이후 실제 문서 diff = $docs_diff, 현재 문서. 직전 blocker 는 확정 사실이 아니라 재확인할 주장이다 — 적힌 증거 위치와 실행 경로를 출발점으로 현재 문서와 저장소에서 직접 다시 확인해, 요구된 불변식이 현재 문서에서 여전히 깨져 있고 입장 조건을 만족하면 UNRESOLVED_PREVIOUS, 아니면 제외한다. 문서 소유자가 그 이슈를 수용했는지·기각했는지와 그 이유는 판정 입력이 아니며 전달되지 않는다. 이번 라운드에서 허용되는 blocking 은 세 종류뿐이며 origin 으로 표시한다: UNRESOLVED_PREVIOUS(직전 이슈가 미해결, previous_issue_id 에 같은 id) / REVISION_REGRESSION(직전 수정이 새로 만든 직접 회귀, revision_ref 에 diff 위치) / NEWLY_EXPOSED_BY_REVISION(Round 1 에는 없던 정보가 수정으로 처음 드러남, revision_ref 필수). 직전 라운드 당시 이미 볼 수 있었던 별개의 문제는 제기하지 마라. 해결된 이슈는 제외한다."
  fi

  # ---------- 검증자 검토: 읽기 전용, 스키마 강제 JSON (CLI 는 VALIDATOR_MODEL 로 라우팅) ----------
  # 공통 계약(validator-review-*.md) 뒤에 프로필 오버레이를 붙인다. 오버레이는 envsubst 를 거치지 않는다(치환 변수 없음).
  # 검증자는 decisions.md 원본을 입력으로 받지 않는다 — 거기에는 디자이너의 [round N] ACCEPT/REJECT 사유가 섞여 있고, "읽되 무시하라" 는 격리가 아니다.
  # 이 target 의 확정 사용자 결정([USER-QUESTION][scope=…]) 줄만 매 호출 직전에 결정적으로 다시 추린다(지문의 consensus_user_decisions_for 와 같은 범위).
  # 디자이너와 지문·체크포인트는 계속 decisions.md 원본을 쓴다.
  user_decisions="$WORK_DIR/reviews/user-decisions-$TARGET.md"
  case "$TARGET" in design) user_decision_scopes='design';; impl) user_decision_scopes='design|impl';; esac
  { printf '# 확정 사용자 결정 (%s 단계 — 아래에 줄이 없으면 확정된 사용자 결정이 없다)\n' "$TARGET"
    grep -E "^[[:space:]]*- \[USER-QUESTION\]\[scope=($user_decision_scopes)\]" "$WORK_DIR/decisions.md" || true; } > "$user_decisions"
  validator_prompt=$(PROJECT_CONVENTIONS="$PROJECT_CONVENTIONS" WORK_DIR="$WORK_DIR" PREV_CONTEXT="$prev_context" USER_DECISIONS_FILE="$user_decisions" \
    render_prompt "$VALIDATOR_PROMPT_FILE" '${PROJECT_CONVENTIONS} ${WORK_DIR} ${PREV_CONTEXT} ${USER_DECISIONS_FILE}')"$VALIDATOR_OVERLAY"
  # conventions 는 검증자 프롬프트 본문(validator-review-design.md / -impl.md 1행의 ${PROJECT_CONVENTIONS})에 이미 렌더링돼 있으므로 "" 를 넘긴다.
  # 두 프롬프트 파일 모두 이 플레이스홀더를 가져야 한다 — 하나라도 빠지면 그 단계 검증자는 conventions.md 를 받지 못한다(위 start-up 검사가 막는다).
  # 검증자 세션은 호출마다 fresh 다(이름에 invocation id) — 종결 검토가 직전 검증자 대화에 anchoring 되지 않게 하고, 같은 라운드 재시도·Round 1 재시작도 옛 대화를 --resume 하지 않는다.
  # 이 정책은 CLI 독립이다: codex 로 라우팅돼도 key 가 호출마다 다르고 accept 를 부르지 않으므로 codex exec resume 은 쓰이지 않는다(도구가 지원해도 의도적 미사용).
  # 라운드 간 상태는 위 prev_context 의 파일로만 넘긴다. 디자이너는 판정자가 아니라 문서 수정자이므로 stage 세션을 그대로 이어간다(아래).
  run_readonly_json_role VALIDATOR "validator-$TARGET-round-$tag-$(new_invocation_id)" "$TARGET-validator-round-$tag" "$SCHEMA_FILE" "$review" "$validator_prompt" "" \
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
    echo "[STOP] 검증자가 사용자 결정을 요구함($ask_ids). user_question / options 를 사용자에게 그대로 전달. 답은 decisions.md 에 '- [USER-QUESTION][scope=$TARGET] <질문> → <답>' 으로 기록." >&2
    jq -n --arg t "$TARGET" --arg i "$ask_ids" --arg r "$review" '{phase:$t, status:"ASK_USER", issues:$i, review:$r}' > "$WORK_DIR/state.json"
    reset_consensus_checkpoint
    exit 2
  fi

  # 교착 감지: 이슈 '내용'까지 동일한 집합이 2라운드 연속이면 사람에게 에스컬레이션
  # (같은 id라도 reachable_scenario/minimum_contract_needed 가 달라지면 진전 중으로 본다)
  if [ -n "$ids" ] && [ "$fingerprint" = "$prev_fingerprint" ]; then
    echo "[STOP] 동일 이슈($ids)가 내용 변화 없이 2라운드 연속 반복됨. 사용자 판단 필요 — 답은 decisions.md 에 '- [USER-QUESTION][scope=$TARGET] <질문> → <답>' 으로 기록." >&2
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
  # 같은 stage(design|impl) 의 라운드 사이에서만 세션을 이어간다 — 다른 stage 의 검증·설계 문맥은 문서/체크포인트로만 전달
  echo "--- 디자이너가 리뷰($(basename "$prev_review"))를 반영/반박합니다 ---"
  decisions_lines_before=$(wc -l < "$WORK_DIR/decisions.md")
  designer_result="$WORK_DIR/reviews/designer-$TARGET-round-$tag.raw"
  # 디자이너 입력은 blocker 의 구조화된 주장·증거뿐이다 — 검증자의 자유 서술(why_blocks_now)은 넘기지 않는다. prev_review 에서 매번 결정적으로 다시 만든다(재개 포함).
  designer_input="$WORK_DIR/reviews/designer-input-$TARGET-round-$tag.json"
  jq '{blocking_issues: [.blocking_issues[] | {id, category, change_relation, evidence_type, basis_refs, conflict_refs, code_refs, reachable_scenario, impact, minimum_contract_needed}]}' "$prev_review" > "$designer_input" \
    || { echo "[FAIL] 디자이너 입력 생성 실패: $prev_review" >&2; exit 1; }
  designer_prompt=$(REVIEW_FILE="$designer_input" WORK_DIR="$WORK_DIR" ROUND="$round" \
    render_prompt "$DESIGNER_PROMPT_FILE" '${REVIEW_FILE} ${WORK_DIR} ${ROUND}')
  # 호출 전 문서 상태(합의 대상 문서 + decisions.md = editable 지문)와 source 작업 트리(WORK_DIR 제외 tree). 디자이너는 편집 역할이라 문서 밖 파일도 쓸 수 있다.
  designer_docs_before="$(consensus_editable_fingerprint "$TARGET")"
  designer_tree_before="$(snapshot_worktree_tree)" || { echo "[FAIL] 디자이너 호출 전 tree 스냅샷 실패" >&2; exit 1; }
  designer_rc=0
  run_edit_role DESIGNER "designer-$TARGET" "$TARGET-designer-round-$tag" "$designer_result" "$designer_prompt" "$PROJECT_CONVENTIONS" "" "" || designer_rc=$?
  designer_tree_after="$(snapshot_worktree_tree)" || { echo "[FAIL] 디자이너 호출 후 tree 스냅샷 실패" >&2; exit 1; }
  if [ "$designer_tree_after" != "$designer_tree_before" ]; then
    # 합의 단계에서 구현 파일이 바뀌었다 — rc 와 무관하게 디자이너 허용 범위 위반. 자동 원복 없음, 같은 디자이너 자동 재호출 없음, 검증자에게 넘기지 않음.
    record_designer_scope_guard "$designer_tree_before" "$designer_tree_after" "$TARGET" "$round" "$designer_rc" || { echo "[FAIL] designer-scope 가드 기록 실패" >&2; exit 1; }
    echo "[STOP] DESIGNER_SCOPE_VIOLATION: 디자이너($TARGET round $round, exit $designer_rc)가 합의 문서 밖 source 작업 트리를 바꿈(전: $designer_tree_before / 후: $designer_tree_after). 자동 원복하지 않음 — 변경을 확인한 뒤 호출 전 tree 로 되돌리기 전에는 재실행이 모델 호출 0회로 같은 사유로 멈춘다(designer-scope.guard.json)." >&2
    git diff --stat "$designer_tree_before" "$designer_tree_after" -- >&2 || true
    jq -n --arg t "$TARGET" --arg r "$round" --arg b "$designer_tree_before" --arg a "$designer_tree_after" --argjson rc "$designer_rc" \
      '{phase:$t, status:"DESIGNER_SCOPE_VIOLATION", round:($r|tonumber), before_tree:$b, after_tree:$a, designer_exit_code:$rc}' > "$WORK_DIR/state.json"
    exit 2
  fi
  if [ "$designer_rc" -ne 0 ]; then
    if [ "$(consensus_editable_fingerprint "$TARGET")" = "$designer_docs_before" ]; then
      # 문서·decisions 변경 없음 → 기존 실패. 같은 디자이너 재실행은 안전하다(체크포인트 DESIGNER_PENDING 그대로).
      echo "[FAIL] 디자이너 실행 실패 (모델 '$DESIGN_REVISION_MODEL' 확인). 재실행 시 $TARGET round $round / DESIGNER_PENDING 부터 재개"; exit 1
    fi
    # 문서 또는 decisions 변경 있음 → '디자이너 성공' 으로 간주하는 것이 아니다. 편집 결과는 있지만 CLI 완료 신호가 불확실하므로
    # 같은 편집을 반복하지 않고 독립 검증자에게 넘겨 판정시킨다(부분 수정이면 BLOCK 으로 기존 루프에 돌아오고, 충분하면 PASS).
    echo "[WARN] CLI_EXIT_STATUS_MISMATCH: DESIGNER $(role_cli DESIGNER) exited $designer_rc, but current invocation changed the $TARGET docs/decisions; forwarding to the validator instead of replaying the designer"
    record_cli_anomaly DESIGNER "$(role_cli DESIGNER)" "$TARGET-designer-round-$tag" "$designer_rc" FORWARD_TO_VALIDATOR "$designer_result"
  fi
  echo "--- 디자이너 판정 (decisions.md 신규 기록) ---"
  tail -n +"$((decisions_lines_before + 1))" "$WORK_DIR/decisions.md" | sed 's/^/  /'

  # 디자이너 성공(또는 변경 있음 + rc 불일치) → 다음 라운드 검증 대기 상태로 전환
  round=$((round + 1))
  next_step="VALIDATOR_PENDING"
  save_consensus_checkpoint "$round" "$next_step" "$prev_review" "$prev_snapshot"
  fi # DESIGNER_PENDING
done

echo "[STOP] $MAX_SPEC_ROUNDS 라운드 내 수렴 실패. 쟁점을 사용자에게 보고하고 중단 — 사용자 결정은 decisions.md 에 '- [USER-QUESTION][scope=$TARGET] <질문> → <답>' 으로 기록(검증자 요구를 기각한 경우도 같은 형식, 체크포인트·리뷰 JSON 수동 편집 없음)." >&2
jq -n --arg t "$TARGET" '{phase:$t, status:"MAX_ROUNDS_EXCEEDED"}' > "$WORK_DIR/state.json"
reset_consensus_checkpoint
exit 2
