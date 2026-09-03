#!/usr/bin/env bash
# =============================================================
# feature 파이프라인 러너 — 교통정리기 (agent 가 아니다)
# 파일 경로: .claude/skills/feature/scripts/feature-run.sh
# 사용법 (저장소 루트에서):
#   feature-run.sh [--new [--archive-as <이름>]] [--branch <이름>]
#     --new     : 이전 피처 산출물을 archive/ 로 mv 하고 처음부터 시작
#     --branch  : 워커 진입 전 해당 브랜치가 없으면 생성·체크아웃
#   인자 없이 다시 실행하면 run-state.json 의 stage 에서 재개한다.
#
# 상태 전이 (결정론적 제어만 담당):
#   preflight → design → impl → worker → review → verify → done
#   design : consensus-loop.sh design
#   impl   : consensus-loop.sh impl        (implementation.md + approach.md 필요)
#   worker : codex 워커 실행, 결과 JSON(status DONE|UNDECIDED)
#   review : impl-review-loop.sh
#   verify : 승인 지문 → TEST_CMD → LINT_CMD → 지문 재확인
#            실패 → worker-fix(최대 MAX_TEST_RETRIES) → review → verify
#            지문 STALE → review (연속 2회면 사용자 반환)
#
# 종료 코드 / run-state.json status:
#   0 DONE        완료
#   2 NEED_USER   사용자 판단 필요 (reason: ASK_USER | DEADLOCK | MAX_ROUNDS | UNDECIDED |
#                 TEST_RETRIES_EXHAUSTED | APPROVAL_STALE_REPEATED)
#   3 NEED_DOCS   오케스트레이터가 문서를 써야 함 (reason: DESIGN_MISSING | IMPL_DOCS_MISSING)
#   1 ENV_ERROR   환경·CLI 오류
#
# 자동 복구 금지: 여기서 허용하는 자동 루프는 성공 조건이 기계적으로 명확한
# 두 가지뿐이다 — (리뷰 이슈 → 수정자 → 재리뷰), (테스트 실패 → 워커 1회 수정 →
# 재리뷰 → 재테스트). "무슨 뜻인지 모르겠다", "둘 중 골라야 한다", "같은 이슈가
# 반복된다"는 추가 추론 없이 즉시 사람에게 반환한다. 여기에 더 똑똑한 복구를
# 추가하지 마라 — 이 스킬의 목적을 거꾸로 훼손한다.
# =============================================================
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.sh"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

exec </dev/null
mkdir -p "$WORK_DIR"

STATE="$WORK_DIR/run-state.json"
WORKER_RESULT="$WORK_DIR/worker-result.json"
WORKER_SCHEMA="$SKILL_DIR/schemas/worker-result.schema.json"

# ---------- 인자 ----------
NEW=0; ARCHIVE_AS=""; BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --new) NEW=1;;
    --archive-as) ARCHIVE_AS="$2"; shift;;
    --branch) BRANCH="$2"; shift;;
    *) echo "[FAIL] 알 수 없는 인자: $1" >&2; exit 1;;
  esac
  shift
done

# --new에서는 tee가 live.log를 열기 전에 이전 로그를 아카이브한다.
# 열린 파일을 나중에 mv하면 tee가 아카이브된 inode에 계속 쓰게 된다.
ARCHIVE_NAME="${ARCHIVE_AS:-$(date '+%Y%m%d-%H%M%S')}"
if [ "$NEW" = 1 ] && [ -f "$WORK_DIR/live.log" ]; then
  mkdir -p "$WORK_DIR/archive/$ARCHIVE_NAME"
  mv "$WORK_DIR/live.log" "$WORK_DIR/archive/$ARCHIVE_NAME/live.log"
fi
exec > >(tee -a "$WORK_DIR/live.log") 2>&1

# 하위 루프가 같은 live.log에 tee를 중첩해 로그를 중복 기록하지 않게 한다.
export FEATURE_LIVE_TEE=1

# ---------- 상태 기록 (임시 파일 + mv 원자 교체) ----------
# state 는 재개 '힌트'다. 각 stage 진입 시 필요한 산출물 존재·지문을 별도로 확인한다.
write_state() { # stage status reason detail
  local now; now="$(date '+%F %T')"
  local history='[]'
  [ -f "$STATE" ] && history="$(jq -c '.history // []' "$STATE")"
  jq -n --arg stage "$1" --arg status "$2" --arg reason "$3" --arg detail "$4" --arg now "$now" \
    --argjson retries "${TEST_RETRIES:-0}" --argjson stale "${STALE_COUNT:-0}" --argjson history "$history" \
    '{version:1, stage:$stage, status:$status, reason:(if $reason=="" then null else $reason end),
      detail:(if $detail=="" then null else $detail end), test_retries:$retries, stale_count:$stale,
      updated_at:$now, history:($history + [{stage:$stage,status:$status,reason:(if $reason=="" then null else $reason end),at:$now}])}' \
    > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
log() { echo "[$(date '+%F %T')] [feature-run] $*"; }
stop_need_user() { # reason detail
  log "NEED_USER ($1): $2"
  write_state "$STAGE" NEED_USER "$1" "$2"
  exit 2
}
stop_need_docs() {
  log "NEED_DOCS ($1): $2"
  write_state "$STAGE" NEED_DOCS "$1" "$2"
  exit 3
}
env_error() {
  log "ENV_ERROR: $*"
  write_state "${STAGE:-preflight}" ENV_ERROR ENV_ERROR "$*"
  exit 1
}
trap 'rc=$?; case $rc in 0|2|3) ;; *) jq -e ".status==\"ENV_ERROR\"" "$STATE" >/dev/null 2>&1 || write_state "${STAGE:-preflight}" ENV_ERROR ENV_ERROR "예기치 않은 종료 (exit $rc)";; esac' EXIT

# ---------- preflight ----------
STAGE=preflight
for bin in "$CLAUDE_BIN" "$CODEX_BIN" jq uuidgen envsubst git; do
  command -v "$bin" >/dev/null 2>&1 || env_error "'$bin' 미설치"
done
for f in consensus-loop.sh impl-review-loop.sh; do
  [ -x "$SKILL_DIR/scripts/$f" ] || env_error "스크립트 없음/실행권한 없음: $f"
done
[ -f "$WORKER_SCHEMA" ] || env_error "스키마 없음: $WORKER_SCHEMA"
for p in worker-implement.md worker-fix.md; do
  [ -f "$SKILL_DIR/prompts/$p" ] || env_error "프롬프트 없음: $p"
done

if [ "$NEW" = 1 ]; then
  # 이전 산출물은 삭제하지 않고 archive/ 로 이동 (rm 금지)
  archive_name="$ARCHIVE_NAME"
  archive_dir="$WORK_DIR/archive/$archive_name"
  moved=0
  for item in "$WORK_DIR"/* "$WORK_DIR"/.session-*; do
    [ -e "$item" ] || continue
    case "$(basename "$item")" in archive|live.log) continue;; esac
    mkdir -p "$archive_dir"; mv "$item" "$archive_dir/"; moved=1
  done
  [ "$moved" = 1 ] && log "이전 산출물 → $archive_dir"
  : > "$WORK_DIR/decisions.md"
  TEST_RETRIES=0; STALE_COUNT=0
  write_state preflight RUNNING "" ""
fi
[ -f "$WORK_DIR/decisions.md" ] || : > "$WORK_DIR/decisions.md"

# 실시간 로그 뷰어. 저장소별 lock을 먼저 선점해 러너 재실행·동시 실행이
# 같은 뷰어 터미널을 여러 개 열지 못하게 한다.
live_pid_active() { # pid-file
  local pid
  [ -f "$1" ] || return 1
  IFS= read -r pid < "$1"
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  kill -0 "$pid" 2>/dev/null
}
claim_live_launch_lock() {
  LIVE_LOCK_DIR="$WORK_DIR/.feature-live.lock"
  mkdir "$LIVE_LOCK_DIR" 2>/dev/null && return 0
  if live_pid_active "$LIVE_LOCK_DIR/viewer.pid" \
     || live_pid_active "$LIVE_LOCK_DIR/launcher.pid"; then
    return 1
  fi

  # 강제 종료 등으로 남은 stale lock은 고유 경로로 옮긴 뒤 회수한다.
  local stale_lock="$LIVE_LOCK_DIR.stale.$$"
  if mv "$LIVE_LOCK_DIR" "$stale_lock" 2>/dev/null; then
    rm -rf "$stale_lock"
  fi
  mkdir "$LIVE_LOCK_DIR" 2>/dev/null
}

if [ -x "$ROOT/feature-live" ] && claim_live_launch_lock; then
  printf '%s\n' "$$" > "$LIVE_LOCK_DIR/launcher.pid"
  live_launched=0
  case "$(uname)" in
    Darwin)
      osascript -e "tell application \"Terminal\" to do script \"$ROOT/feature-live --lock-held\"" \
        >/dev/null 2>&1 && live_launched=1
      ;;
    Linux)
      (x-terminal-emulator -e "$ROOT/feature-live" --lock-held \
        || gnome-terminal -- "$ROOT/feature-live" --lock-held) >/dev/null 2>&1 &
      live_launched=1
      ;;
  esac
  if [ "$live_launched" = 0 ]; then
    rm -f "$LIVE_LOCK_DIR/launcher.pid"
    rmdir "$LIVE_LOCK_DIR" 2>/dev/null || true
  fi
fi

# ---------- 재개 지점 결정: state 힌트 + 산출물 교차 확인 ----------
TEST_RETRIES=0; STALE_COUNT=0; STAGE=design
if [ -f "$STATE" ]; then
  TEST_RETRIES="$(jq -r '.test_retries // 0' "$STATE")"
  STALE_COUNT="$(jq -r '.stale_count // 0' "$STATE")"
  hinted="$(jq -r '.stage' "$STATE")"
  hinted_status="$(jq -r '.status' "$STATE")"
  [ "$hinted_status" = DONE ] && { log "이미 DONE 상태. --new 로 새 피처를 시작하라."; exit 0; }
  case "$hinted" in preflight|"") STAGE=design;; *) STAGE="$hinted";; esac
fi
# 산출물이 힌트보다 뒤처져 있으면 뒤로 물린다 (state 만 믿지 않는다)
last_pass() { # 검증자 라운드 파일 중 마지막이 PASS 인가
  local last; last="$(ls "$WORK_DIR"/reviews/validator-"$1"-round-*.json 2>/dev/null | sort | tail -1)"
  # schema_version 이 현재 계약(VALIDATOR_CONTRACT_VERSION)과 다른 이전 PASS 는 무효 — 검증 라운드를 새 기준으로 다시 돈다 (--new 불필요)
  [ -n "$last" ] && jq -e --argjson v "$VALIDATOR_CONTRACT_VERSION" '.schema_version==$v and .verdict=="PASS" and (.blocking_issues|length)==0' "$last" >/dev/null 2>&1
}
[ -f "$WORK_DIR/design.md" ] || { STAGE=design; stop_need_docs DESIGN_MISSING "$WORK_DIR/design.md 초안을 작성한 뒤 다시 실행"; }
case "$STAGE" in
  worker|review|verify|done)
    last_pass impl || STAGE=impl;;
esac
case "$STAGE" in
  review|verify|done)
    { [ -f "$WORKER_RESULT" ] && jq -e '.status=="DONE"' "$WORKER_RESULT" >/dev/null 2>&1; } || STAGE=worker;;
esac
[ "$STAGE" = verify ] && { [ -f "$WORK_DIR/approved.fingerprint" ] || STAGE=review; }
log "시작 stage: $STAGE (test_retries=$TEST_RETRIES)"

# ---------- 워커 호출 ----------
run_worker() { # prompt-file extra-vars-spec
  local prompt_file="$1"; shift
  local prompt
  prompt="$(WORKER_RULES="$(load_worker_rules)" REFERENCE_CODE="$(load_reference_code)" WORK_DIR="$WORK_DIR" TEST_CMD="$TEST_CMD" TEST_LOG="${TEST_LOG:-}" \
    render_prompt "$SKILL_DIR/prompts/$prompt_file" '${WORKER_RULES} ${REFERENCE_CODE} ${WORK_DIR} ${TEST_CMD} ${TEST_LOG}')"
  local raw="$WORK_DIR/reviews/worker-$(date '+%Y%m%d-%H%M%S').log"
  mkdir -p "$WORK_DIR/reviews"
  rm -f "$WORKER_RESULT"
  "$CODEX_BIN" exec -m "$WORKER_MODEL" -c "model_reasoning_effort=\"$WORKER_EFFORT\"" --sandbox workspace-write \
    --output-schema "$WORKER_SCHEMA" -o "$WORKER_RESULT" "$prompt" 2>&1 \
    | tee "$raw" \
    || { tail -20 "$raw" >&2; env_error "codex 워커 실행 실패 (모델 '$WORKER_MODEL' 확인)"; }
  jq -e '.status' "$WORKER_RESULT" >/dev/null 2>&1 || env_error "워커 결과 JSON 이 스키마와 다름: $WORKER_RESULT"
  local status; status="$(jq -r '.status' "$WORKER_RESULT")"
  local n; n="$(jq '.undecided|length' "$WORKER_RESULT")"
  if { [ "$status" = DONE ] && [ "$n" -gt 0 ]; } || { [ "$status" = UNDECIDED ] && [ "$n" -eq 0 ]; }; then
    env_error "모순된 워커 결과: status=$status / undecided=$n"
  fi
  log "워커 status: $status / undecided: $n / delegated_choices: $(jq '.delegated_choices|length' "$WORKER_RESULT")"
  jq -r '.undecided[]? | "  [UNDECIDED] \(.location): \(.decision_needed)"' "$WORKER_RESULT"
  if [ "$status" = UNDECIDED ]; then
    # 문서 누락(DOC_GAP)은 오케스트레이터가 approach.md 를 보강할 일이고, 제품 정책(USER_DECISION)만 사용자에게 간다.
    local user_n; user_n="$(jq '[.undecided[] | select(.kind=="USER_DECISION")] | length' "$WORKER_RESULT")"
    if [ "$user_n" -gt 0 ]; then
      stop_need_user UNDECIDED "$WORKER_RESULT 의 USER_DECISION 항목을 사용자에게 질문 → decisions.md [USER-QUESTION] 기록 → approach.md 반영 후 재실행 (DOC_GAP 항목은 오케스트레이터가 함께 보강)"
    fi
    # stage 힌트를 impl 로 되돌려 재실행 시 보강된 approach.md 가 검증자 재합의를 거치게 한다
    STAGE=impl
    stop_need_docs APPROACH_GAP "$WORKER_RESULT 의 DOC_GAP 항목대로 approach.md 를 보강한 뒤 재실행 (검증자 재합의 후 워커 재개)"
  fi
}

# ---------- 상태 기계 ----------
while :; do
  write_state "$STAGE" RUNNING "" ""
  case "$STAGE" in

    design)
      set +e; bash "$SKILL_DIR/scripts/consensus-loop.sh" design; rc=$?; set -e
      case $rc in
        0) STAGE=impl;;
        2) stop_need_user "$(jq -r '.status' "$WORK_DIR/state.json" | sed 's/MAX_ROUNDS_EXCEEDED/MAX_ROUNDS/')" "설계 합의 중단 — ASK_USER 면 해당 이슈의 user_question·options 를, 그 외엔 마지막 reviews/validator-design-*.json 의 쟁점을 사용자에게 보고";;
        *) env_error "consensus-loop design 실패 (exit $rc)";;
      esac;;

    impl)
      { [ -f "$WORK_DIR/implementation.md" ] && [ -f "$WORK_DIR/approach.md" ]; } \
        || stop_need_docs IMPL_DOCS_MISSING "합의된 design.md 기반으로 implementation.md(무엇)·approach.md(어떻게, REQUIRED/DELEGATED) 작성 후 재실행"
      set +e; bash "$SKILL_DIR/scripts/consensus-loop.sh" impl; rc=$?; set -e
      case $rc in
        0) STAGE=worker;;
        2) stop_need_user "$(jq -r '.status' "$WORK_DIR/state.json" | sed 's/MAX_ROUNDS_EXCEEDED/MAX_ROUNDS/')" "구현 문서 합의 중단 — ASK_USER 면 해당 이슈의 user_question·options 를, 그 외엔 마지막 reviews/validator-impl-*.json 의 쟁점을 사용자에게 보고";;
        *) env_error "consensus-loop impl 실패 (exit $rc)";;
      esac;;

    worker)
      if [ -n "$BRANCH" ] && [ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]; then
        git rev-parse --verify -q "$BRANCH" >/dev/null && git checkout "$BRANCH" || git checkout -b "$BRANCH"
      fi
      run_worker worker-implement.md
      STAGE=review;;

    review)
      set +e; bash "$SKILL_DIR/scripts/impl-review-loop.sh"; rc=$?; set -e
      case $rc in
        0) STAGE=verify;;
        2) stop_need_user MAX_ROUNDS "구현 리뷰 미승인 — 마지막 reviews/impl-attempt-*/reviewer-*.json 의 이슈를 사용자에게 보고";;
        *) env_error "impl-review-loop 실패 (exit $rc)";;
      esac;;

    verify)
      if ! verify_approved_fingerprint; then
        STALE_COUNT=$((STALE_COUNT + 1))
        [ "$STALE_COUNT" -ge 2 ] && stop_need_user APPROVAL_STALE_REPEATED "승인 후 작업 트리가 반복 변경됨 — 외부 변경 원인 확인 필요"
        log "승인 지문 불일치 → 재리뷰"; STAGE=review; continue
      fi
      STALE_COUNT=0
      test_log="$WORK_DIR/reviews/verify-$(date '+%Y%m%d-%H%M%S').log"
      log "전체 테스트: $TEST_CMD"
      set +e; { bash -c "$TEST_CMD" && { log "린트: $LINT_CMD"; bash -c "$LINT_CMD"; }; } > "$test_log" 2>&1; rc=$?; set -e
      if [ $rc -ne 0 ]; then
        log "테스트/린트 실패 (exit $rc) — $test_log"; tail -30 "$test_log"
        [ "$TEST_RETRIES" -ge "$MAX_TEST_RETRIES" ] && stop_need_user TEST_RETRIES_EXHAUSTED "테스트 실패 $((TEST_RETRIES + 1))회 — $test_log"
        TEST_RETRIES=$((TEST_RETRIES + 1))
        write_state verify RUNNING "" "worker-fix $TEST_RETRIES/$MAX_TEST_RETRIES"
        TEST_LOG="$test_log" run_worker worker-fix.md
        STAGE=review; continue   # 워커 수정 후 기존 승인은 무효 → 재리뷰 필수
      fi
      log "테스트·린트 통과"
      if ! verify_approved_fingerprint; then
        STALE_COUNT=$((STALE_COUNT + 1))
        [ "$STALE_COUNT" -ge 2 ] && stop_need_user APPROVAL_STALE_REPEATED "테스트·린트가 작업 트리를 반복 변경 — 스냅샷/자동 포맷 확인 필요"
        log "테스트·린트가 작업 트리를 바꿈 → 재리뷰"; STAGE=review; continue
      fi
      STAGE=done;;

    done)
      write_state done DONE "" "Phase 3 승인 + 전체 테스트 통과. 커밋은 사용자 지시 시에만."
      log "DONE"
      exit 0;;

    *) env_error "알 수 없는 stage: $STAGE";;
  esac
done
