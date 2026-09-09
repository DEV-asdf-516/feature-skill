#!/usr/bin/env bash
# =============================================================
# feature 파이프라인 러너 — 교통정리기 (agent 가 아니다)
# 파일 경로: .claude/skills/feature/scripts/feature-run.sh
# 사용법 (저장소 루트에서):
#   feature-run.sh [--new [--archive-as <이름>]] [--branch <이름>] [--worktree <디렉터리>]
#     --worktree: 피처 전용 git worktree 에서 실행(권장). 없으면 --branch 로 생성. 다른 세션의 미커밋 변경과 물리적으로 분리.
#     --new     : 이전 피처 산출물을 archive/ 로 mv 하고 처음부터 시작
#     --branch  : 워커 진입 전 해당 브랜치가 없으면 생성·체크아웃
#   인자 없이 다시 실행하면 run-state.json 의 stage 에서 재개한다. 합의·리뷰 루프는 자체 체크포인트
#   (consensus-<target>.json, review-impl.json)로 round/substep 까지 이어가며, stage 결정은 consensus_pass_current 로 교차 확인한다.
#
# 상태 전이 (결정론적 제어만 담당):
#   preflight → design → impl → worker → review → verify → done
#   design : consensus-loop.sh design
#   impl   : consensus-loop.sh impl        (implementation.md + approach.md 필요)
#   worker : codex 워커 실행, 결과 JSON(status DONE|UNDECIDED)
#   review : impl-review-loop.sh (리뷰어 게이트 → FIX_CODE 만 수정자 → 종결 검토)
#            DOC_GAP → impl(문서 보강), DEADLOCK/MAX_ROUNDS → 사용자
#   verify : 승인 지문 → TEST_CMD → LINT_CMD → 지문 재확인
#            실패 → worker-fix(최대 MAX_TEST_RETRIES) → review → verify
#            지문 STALE → review (연속 2회면 사용자 반환)
#
# 종료 코드 / run-state.json status:
#   0 DONE        완료
#   2 NEED_USER   사용자 판단 필요 (reason: ASK_USER | DEADLOCK | MAX_ROUNDS | UNDECIDED |
#                 TEST_RETRIES_EXHAUSTED | APPROVAL_STALE_REPEATED | FOREIGN_WORKTREE_CHANGE | SCOPE_VIOLATION |
#                 SCOPE_MANIFEST_CHANGED | SCOPE_BASELINE_CHANGED)
#   3 NEED_DOCS   오케스트레이터가 문서를 써야 함 (reason: DESIGN_MISSING | IMPL_DOCS_MISSING | SCOPE_MISSING | APPROACH_GAP)
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

# ---------- 인자 ----------
NEW=0; ARCHIVE_AS=""; BRANCH=""; WORKTREE=""; FEATURE_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --new) NEW=1;;
    --archive-as) ARCHIVE_AS="$2"; shift;;
    --branch) BRANCH="$2"; shift;;
    --worktree) WORKTREE="$2"; shift;;
    --feature) FEATURE_ID="$2"; shift;;
    *) echo "[FAIL] 알 수 없는 인자: $1" >&2; exit 1;;
  esac
  shift
done

# ---------- --feature <id>: 결정론적 전용 worktree 부트스트랩 (기본 모드) ----------
# branch feature/<id>, 경로 <main root 옆>/<repo>-feature-<id> 를 id 로 정한다. 없으면 원본의 dirty 상태(미커밋 tracked 변경·untracked)를
# bootstrap 커밋 없이 snapshot tree 로 옮겨 만들고, 있으면 그 worktree 와 그 안의 .agent-work 를 이어서 쓴다. --branch/--worktree 를
# 같이 주면 그 값이 이름을 대신한다(재실행 때도 같은 인자). 상세는 scripts/feature-worktree.sh.
FEATURE_WORKTREE_MODE=""; FEATURE_SNAPSHOT_TREE=""
if [ -n "$FEATURE_ID" ]; then
  source "$SKILL_DIR/scripts/feature-worktree.sh"
  feature_worktree_bootstrap "$FEATURE_ID" "$BRANCH" "$WORKTREE" || { echo "[FAIL] 피처 worktree 부트스트랩 실패 (--feature $FEATURE_ID)" >&2; exit 1; }
  WORKTREE="$FEATURE_ROOT"; BRANCH="$FEATURE_BRANCH"
fi

# ---------- 피처 전용 git worktree (수동 모드 — --feature 없이 경로·브랜치를 직접 지정) ----------
# 같은 working tree 를 다른 세션과 공유하면 git 은 변경 소유자를 기록하지 않으므로 워커·수정자·리뷰·승인이
# 다른 세션의 미커밋 변경을 "이번 작업"으로 오인할 수 있다. 디렉터리를 분리하면 물리적으로 존재하지 않는다.
# --worktree <dir> : 없으면 `git worktree add <dir> -b <branch> HEAD` 로 만들고(--branch 필수), 있으면 그대로 쓴다.
# 이후 모든 단계(산출물 .agent-work 포함)는 그 디렉터리에서 돈다. 완료 후 main 반영은 사용자가 병합 단계에서 한다.
if [ -n "$WORKTREE" ]; then
  if [ ! -d "$WORKTREE" ]; then
    [ -n "$BRANCH" ] || { echo "[FAIL] --worktree 로 새 worktree 를 만들려면 --branch <이름> 이 필요" >&2; exit 1; }
    if git -C "$ROOT" rev-parse --verify -q "$BRANCH" >/dev/null; then
      git -C "$ROOT" worktree add "$WORKTREE" "$BRANCH" || { echo "[FAIL] git worktree add 실패" >&2; exit 1; }
    else
      git -C "$ROOT" worktree add -b "$BRANCH" "$WORKTREE" HEAD || { echo "[FAIL] git worktree add 실패" >&2; exit 1; }
    fi
    echo "[feature-run] 피처 worktree 생성: $WORKTREE (branch $BRANCH)"
  fi
  wt_root="$(git -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null)" || { echo "[FAIL] $WORKTREE 는 git worktree 가 아님" >&2; exit 1; }
  [ "$(git -C "$wt_root" rev-parse --git-common-dir)" != "$(git -C "$wt_root" rev-parse --git-dir)" ] \
    || [ "$wt_root" != "$ROOT" ] || { echo "[FAIL] --worktree 가 현재 main working tree 를 가리킴 — 분리된 디렉터리여야 한다" >&2; exit 1; }
  # gitignore 된 안전 게이트 설정(.codex, .claude/settings.json, .claude/hooks)은 --feature 모드와 같이 원본에서 복사한다(실패는 중단)
  [ -n "$FEATURE_ID" ] || { source "$SKILL_DIR/scripts/feature-worktree.sh"; feature_worktree_copy_gates "$ROOT" "$wt_root" || exit 1; }
  ROOT="$wt_root"
fi
cd "$ROOT"

# 프로젝트 종속 경로 재바인딩 — 소스는 worktree 로 격리됐는데 규칙 파일·conventions·프로젝트 로컬 워커 스킬을 원본에서 읽으면
# 원본의 이후 변경이 이 실행에 새어 든다. 실행 엔진 위치(SKILL_DIR/FEATURE_SKILL_DIR)는 그대로 두고 프로젝트 경로만 바꾼다.
# 하위 루프(consensus/impl-review)는 config.sh 를 따로 source 하므로 환경 변수로 같은 값을 물려준다.
if [ "$(cd "$PROJECT_ROOT" && pwd -P)" != "$(pwd -P)" ]; then
  export FEATURE_PROJECT_ROOT="$ROOT"
  PROJECT_ROOT="$ROOT"
  CORE_RULES_FILE="$PROJECT_ROOT/.claude/hooks/core_rules.md"
  CONVENTIONS_FILE="$PROJECT_ROOT/conventions.md"
  [ -f "$CORE_RULES_FILE" ] || { echo "[FAIL] worktree 에 core_rules.md 없음: $CORE_RULES_FILE — .claude/hooks 를 커밋하거나 복사하라" >&2; exit 1; }
  echo "[feature-run] 프로젝트 경로 재바인딩: $PROJECT_ROOT (규칙·conventions·워커 스킬을 이 worktree 에서 읽는다)"
fi

exec </dev/null
mkdir -p "$WORK_DIR"

# ---------- 러너 단일 실행 락 (원자적 claim) ----------
# pid 파일만으로는 "확인 → 기록" 사이에 두 러너가 같은 트리에 들어올 수 있다. mkdir 은 원자적이라 먼저 만든 쪽만 진입한다.
# 죽은 pid 가 남긴 stale 락은 회수한다. 다른 피처의 부트스트랩도 이 락의 pid 로 이 트리에 러너가 살아 있는지 본다(feature-worktree.sh).
RUNNER_LOCK_DIR="$WORK_DIR/.runner.lock"
runner_lock_pid_alive() { # pid-file
  local pid
  [ -f "$1" ] || return 1
  IFS= read -r pid < "$1"
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  kill -0 "$pid" 2>/dev/null
}
# claim 은 mkdir + pid 기록까지 한 단위다. 락은 있는데 pid 가 아직 없으면 "다른 러너가 mkdir 직후 pid 를 쓰는 중"일 수 있으므로
# stale 로 보고 훔치지 않는다(활성 락 탈취 방지가 pid 없이 죽은 극단적 stale 의 자동 회수보다 우선). pid 가 있고 죽었을 때만 회수한다.
write_runner_lock_pid() { printf '%s\n' "$$" > "$RUNNER_LOCK_DIR/pid" || { rmdir "$RUNNER_LOCK_DIR" 2>/dev/null || true; return 1; }; }
claim_runner_lock() {
  if mkdir "$RUNNER_LOCK_DIR" 2>/dev/null; then write_runner_lock_pid; return $?; fi
  [ -f "$RUNNER_LOCK_DIR/pid" ] || return 1
  runner_lock_pid_alive "$RUNNER_LOCK_DIR/pid" && return 1
  local stale="$RUNNER_LOCK_DIR.stale.${BASHPID:-$$}"
  mv "$RUNNER_LOCK_DIR" "$stale" 2>/dev/null || return 1
  rm -rf "$stale"
  mkdir "$RUNNER_LOCK_DIR" 2>/dev/null || return 1
  write_runner_lock_pid
}
claim_runner_lock || { echo "[FAIL] 이 트리($ROOT)에서 러너가 이미 실행 중이거나 시작 중(pid $(cat "$RUNNER_LOCK_DIR/pid" 2>/dev/null || echo '기록 중')) — 같은 트리에서 러너를 두 번 돌리지 않는다. pid 없이 남은 락이 확실히 죽은 것이면 $RUNNER_LOCK_DIR 을 직접 지운다" >&2; exit 1; }
release_runner_lock() { [ "$(cat "$RUNNER_LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$RUNNER_LOCK_DIR"; return 0; }

STATE="$WORK_DIR/run-state.json"
WORKER_RESULT="$WORK_DIR/worker-result.json"
WORKER_SCHEMA="$SKILL_DIR/schemas/worker-result.schema.json"

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
trap 'rc=$?; case $rc in 0|2|3) ;; *) jq -e ".status==\"ENV_ERROR\"" "$STATE" >/dev/null 2>&1 || write_state "${STAGE:-preflight}" ENV_ERROR ENV_ERROR "예기치 않은 종료 (exit $rc)";; esac; release_runner_lock' EXIT
[ -z "$FEATURE_ID" ] || log "피처 worktree: $ROOT (feature $FEATURE_ID, branch $BRANCH, $FEATURE_WORKTREE_MODE${FEATURE_SNAPSHOT_TREE:+, snapshot tree $FEATURE_SNAPSHOT_TREE}) — 문서·산출물은 $ROOT/$WORK_DIR"

# ---------- preflight ----------
STAGE=preflight
require_role_bins DESIGNER VALIDATOR WORKER REVIEWER FIXER jq uuidgen envsubst git || env_error "역할별 CLI 확인 실패"
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
    case "$(basename "$item")" in archive|live.log|feature.json) continue;; esac   # feature.json 은 worktree 자체의 기록 — 피처 재시작에도 남긴다
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
# 활성 기준선 가드는 stage 와 관계없이 파이프라인 전체를 막는다 — 특히 verify 단계의 worker-fix 가 기준선을 바꿔 멈춘 뒤
# verify 로 재진입하는 경로: exact files 범위에서는 범위 밖 변경·기준선 변경이 승인 지문에 안 잡혀 리뷰 루프·run_worker 를 거치지 않고
# 테스트만 통과하면 DONE 이 된다. run_worker 안의 검사는 이 전역 검사 뒤 다른 세션이 기준선을 바꾸는 경우를 호출 직전에 다시 막는다.
require_baseline_guard_resolved \
  || stop_need_user SCOPE_BASELINE_CHANGED "worker-baseline.tree 가 직전 중단 시점의 기대값($(jq -r .expected "$BASELINE_GUARD"))으로 복구되지 않음 — 되돌린 뒤 재실행. 자동 복구 없음 (stage $STAGE 재개 전 전역 검사)"
# 산출물이 힌트보다 뒤처져 있으면 뒤로 물린다 (state 만 믿지 않는다)
# 합의 PASS 판정은 config.sh 의 consensus_pass_current — 체크포인트(consensus-<target>.json)가 PASS 이고 계약 버전·
# 현재 입력 지문(request/design/impl docs + [USER-QUESTION])이 일치하며 가리키는 리뷰가 실제 PASS 여야 한다.
# 파일명 정렬로 마지막 라운드 파일을 고르지 않는다 — 과거 round-02 PASS 가 새 round-01 BLOCK 을 가리고,
# 문서를 고친 뒤 재실행해도 합의 루프를 건너뛰는 경로가 있었다.
[ -f "$WORK_DIR/design.md" ] || { STAGE=design; stop_need_docs DESIGN_MISSING "$ROOT/$WORK_DIR/design.md 초안을 작성한 뒤 다시 실행"; }
case "$STAGE" in
  impl|worker|review|verify|done)
    consensus_pass_current design || { log "design 합의 PASS 가 현재 입력에 대해 유효하지 않음 — design 부터"; STAGE=design; };;
esac
case "$STAGE" in
  worker|review|verify|done)
    consensus_pass_current impl || { log "impl 합의 PASS 가 현재 입력에 대해 유효하지 않음 — impl 부터"; STAGE=impl; };;
esac
case "$STAGE" in
  review|verify|done)
    { [ -f "$WORKER_RESULT" ] && jq -e '.status=="DONE"' "$WORKER_RESULT" >/dev/null 2>&1; } || STAGE=worker;;
esac
# verify 로 바로 가려면 approved.fingerprint 파일 존재만으론 부족하다 — 리뷰 체크포인트가 현재 계약·현재 작업 트리의
# 실제 APPROVE 리뷰를 가리켜야 한다(config.sh impl_approval_current). 아니면 리뷰 루프가 스스로 재개 지점을 고른다.
if [ "$STAGE" = verify ] && ! impl_approval_current; then
  log "구현 승인이 현재 작업 트리·계약에 대해 유효하지 않음 — review 부터"; STAGE=review
fi
log "시작 stage: $STAGE (test_retries=$TEST_RETRIES)"

# ---------- 워커 호출 ----------
run_worker() { # prompt-file extra-vars-spec
  local prompt_file="$1"; shift
  local prompt worker_rules
  # 직전 실행이 기준선 변조로 멈췄으면 복구 전에는 워커를 부르지 않는다(변조된 값을 새 기준선으로 읽는 재실행 우회 차단)
  require_baseline_guard_resolved \
    || stop_need_user SCOPE_BASELINE_CHANGED "worker-baseline.tree 가 직전 중단 시점의 기대값($(jq -r .expected "$BASELINE_GUARD"))으로 복구되지 않음 — 되돌린 뒤 재실행. 자동 복구 없음"
  # 환경 변수 대입 안의 command substitution 실패는 뒤의 render_prompt 가 성공하면 묻힌다 — 먼저 별도 변수로 받아 실패를 확정한다
  worker_rules="$(load_worker_rules)" || env_error "워커 규칙 또는 필수 워커 스킬(WORKER_SKILLS) 로드 실패 — 워커를 실행하지 않음"
  prompt="$(WORKER_RULES="$worker_rules" REFERENCE_CODE="$(load_reference_code)" WORK_DIR="$WORK_DIR" TEST_CMD="$TEST_CMD" TEST_LOG="${TEST_LOG:-}" \
    render_prompt "$SKILL_DIR/prompts/$prompt_file" '${WORKER_RULES} ${REFERENCE_CODE} ${WORK_DIR} ${TEST_CMD} ${TEST_LOG}')" \
    || env_error "워커 프롬프트 렌더링 실패"
  local raw="$WORK_DIR/reviews/worker-$(date '+%Y%m%d-%H%M%S').log"
  mkdir -p "$WORK_DIR/reviews"
  rm -f "$WORKER_RESULT"
  local index_before index_after worker_rc before_tree after_tree violations scope_hash_before scope_hash_after baseline_before baseline_after
  index_before="$(compute_index_fingerprint)" || env_error "워커 호출 전 git index 지문 계산 실패"
  scope_hash_before="$(feature_scope_hash)"
  # 소유권 기준선은 호출 전에 확정해 사후 판정에 그대로 넘긴다 — 파일은 워커가 쓸 수 있는 .agent-work 안에 있다
  baseline_before="$(read_worker_baseline_tree)" || env_error "worker-baseline.tree 가 유효한 tree 를 가리키지 않음"
  [ -n "$baseline_before" ] || log "[WARN] worker-baseline.tree 없음 — new_file_roots 아래는 신규 생성(A)만 허용하는 규칙으로 검사"
  before_tree="$(snapshot_worktree_tree)" || env_error "워커 호출 전 tree 스냅샷 실패"
  printf '%s\n' "$before_tree" > "$WORK_DIR/worker-before.tree"
  set +e
  # 워커 CLI 는 WORKER_MODEL 로 라우팅. 프롬프트에 conventions·core_rules 가 이미 있으므로 conventions 는 "".
  run_edit_role WORKER worker "worker-$(date '+%Y%m%d-%H%M%S')" "$raw" "$prompt" "" "$WORKER_SCHEMA" "$WORKER_RESULT" --allowedTools "Bash"
  worker_rc=$?
  set -e
  # 기준선 변경은 다른 사후 조건보다 먼저 '기록'만 한다 — index·manifest 검사가 앞서 종료하면 가드가 남지 않아
  # 사용자가 보고된 문제만 고치고 재실행할 때 변조된 기준선이 새 기준선으로 읽힌다. 종료 우선순위(index → manifest → 기준선)는 그대로.
  local baseline_changed=0
  baseline_after=""; [ -f "$WORK_DIR/worker-baseline.tree" ] && baseline_after="$(cat "$WORK_DIR/worker-baseline.tree")"
  if [ "$baseline_after" != "$baseline_before" ]; then
    record_baseline_guard "$baseline_before" "$baseline_after" worker || env_error "worker-baseline 가드 기록 실패"
    baseline_changed=1
  fi
  # 사후 조건을 CLI 성공 여부보다 먼저 본다 — 워커는 작업 트리만 바꿀 수 있고, index 가 바뀌었으면
  # (worker_guard 정규식을 우회한 git add 등) 실패한 실행이라도 복구하지 않고 그 사실부터 보고한다
  index_after="$(compute_index_fingerprint)" || env_error "워커 호출 후 git index 지문 계산 실패"
  [ "$index_after" = "$index_before" ] \
    || env_error "워커가 git index 를 변경함 — 자동 복구하지 않음. git status 로 확인 후 재실행"
  # manifest 불변 검사: 워커가 원본이나 lock 을 고쳐 범위를 넓히면 write-set 검사가 무력화된다 — CLI 성공 여부보다 먼저 본다
  scope_hash_after="$(feature_scope_hash)"
  [ "$scope_hash_after" = "$scope_hash_before" ] \
    || stop_need_user SCOPE_MANIFEST_CHANGED "워커 호출 중 feature-scope.json 또는 feature-scope.lock.json 이 바뀜 — 자동 복구하지 않음. 원본과 lock 을 확인하고, 의도한 범위 변경이면 lock 을 지운 뒤 재실행(impl 재합의)"
  # write-set 검사: 호출 전후 tree 사이 변경이 feature-scope.json 범위를 벗어나면 자동 원복 없이 보존하고 중단.
  # (같은 working tree 의 다른 세션 변경도 여기 잡힐 수 있다 — 그래서 원복하지 않고 사람이 본다)
  after_tree="$(snapshot_worktree_tree)" || env_error "워커 호출 후 tree 스냅샷 실패"
  printf '%s\n' "$after_tree" > "$WORK_DIR/worker-after.tree"
  # 기준선 불변 검사: 워커가 worker-baseline.tree 를 바꾸면(예: 빈 tree) roots 아래 기존 파일이 전부 '피처가 만든 것'으로 보인다 (가드는 위에서 이미 기록)
  [ "$baseline_changed" -eq 0 ] \
    || stop_need_user SCOPE_BASELINE_CHANGED "워커 호출 중 worker-baseline.tree 가 변경됨(전: ${baseline_before:-없음} / 후: ${baseline_after:-없음}) — 자동 복구하지 않음. 파일을 원래 값으로 되돌리고 워커 변경을 확인한 뒤 재실행"
  violations="$(feature_scope_violations "$before_tree" "$after_tree" "$baseline_before")"
  if [ -n "$violations" ]; then
    log "[SCOPE_VIOLATION] 워커 호출 중 범위 밖 경로 변경 — 자동 원복하지 않음:"; printf '  %s\n' $violations
    stop_need_user SCOPE_VIOLATION "feature-scope.json 범위 밖 경로가 바뀜($(printf '%s' "$violations" | paste -sd, -)). 워커 과잉 변경이면 범위를 넓히거나 되돌릴지 사용자가 결정, 다른 세션 변경이면 보존. 자동 원복 금지"
  fi
  if [ "$worker_rc" -ne 0 ]; then
    tail -20 "$raw" >&2
    env_error "워커 실행 실패 (모델 '$WORKER_MODEL' 확인)"
  fi
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
        || stop_need_docs IMPL_DOCS_MISSING "합의된 design.md 기반으로 $ROOT/$WORK_DIR/implementation.md(무엇)·approach.md(어떻게, REQUIRED/DELEGATED) 작성 후 재실행"
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
      # 피처 범위 manifest 는 워커 진입 전에 있어야 한다 — write-set 검사·리뷰 diff·승인 지문의 기준.
      feature_scope_present || stop_need_docs SCOPE_MISSING "implementation.md 의 변경·생성 파일 목록을 $FEATURE_SCOPE_FILE ({version:1, files:[...], new_file_roots:[...]}) 로 작성 후 재실행"
      feature_scope_valid_file "$FEATURE_SCOPE_FILE" || env_error "feature-scope.json 형식 오류 — version $FEATURE_SCOPE_VERSION, files/new_file_roots 중 하나 이상, canonical 상대 경로(선행 ./ · 후행 / · '..' 금지)"
      # 원본을 lock 사본으로 확정한다. 이미 lock 이 있는데 원본과 다르면 사용자가 범위를 바꾼 것 — 어느 쪽이 맞는지 파이프라인이 정하지 않는다.
      # set -e 아래에서는 `f; rc=$?` 가 f 실패 시 바로 종료한다 — if/else 로 받아야 stop_need_user 에 도달한다
      if lock_feature_scope; then :; else
        lock_rc=$?
        case "$lock_rc" in
          2) stop_need_user SCOPE_MANIFEST_CHANGED "feature-scope.json 이 워커 진입 시 확정한 feature-scope.lock.json 과 다름. 의도한 범위 변경이면 lock 을 지우고 재실행(impl 재합의 후 새 lock 확정), 아니면 원본을 lock 과 같게 되돌린 뒤 재실행";;
          *) env_error "feature-scope.lock.json 생성 또는 확인 실패";;
        esac
      fi
      [ -f "$FEATURE_SCOPE_LOCK" ] && log "피처 범위 lock: $FEATURE_SCOPE_LOCK ($(jq -c '{files:(.files|length), roots:((.new_file_roots // [])|length)}' "$FEATURE_SCOPE_LOCK"))"
      # 워커 진입 직전 작업 트리를 기준선으로 한 번만 기록한다(같은 피처 동안 재사용, --new 가 아카이브).
      # 리뷰 diff 는 HEAD 가 아니라 이 기준선 대비다 — 피처 이전의 미커밋 변경을 이번 작업으로 오인하지 않는다.
      # 이 기준선은 '시점'의 증거이지 변경 '소유자'의 증거가 아니다 — 기준선 이후 변경을 근거로 원복하지 않는다(범위 밖 변경은 보존 후 중단).
      if [ ! -f "$WORK_DIR/worker-baseline.tree" ]; then
        snapshot_worktree_tree > "$WORK_DIR/worker-baseline.tree.tmp" && mv "$WORK_DIR/worker-baseline.tree.tmp" "$WORK_DIR/worker-baseline.tree" \
          || env_error "워커 진입 기준선 tree 기록 실패"
        log "워커 진입 기준선 tree: $(cat "$WORK_DIR/worker-baseline.tree")"
      fi
      run_worker worker-implement.md
      STAGE=review;;

    review)
      set +e; bash "$SKILL_DIR/scripts/impl-review-loop.sh"; rc=$?; set -e
      case $rc in
        0) STAGE=verify;;
        2) stop_need_user "$(jq -r '.status' "$WORK_DIR/state.json" | sed 's/MAX_ROUNDS_EXCEEDED/MAX_ROUNDS/')" "구현 리뷰 중단 — state.json.review 의 남은 이슈를 사용자에게 보고";;
        3)
          # 리뷰어 DOC_GAP: 코드가 아니라 approach.md 가 비어 있다. 워커 DOC_GAP 과 같은 경로로 문서 단계 재진입.
          STAGE=impl
          stop_need_docs APPROACH_GAP "$(jq -r '.review' "$WORK_DIR/state.json") 의 DOC_GAP 이슈(required_outcome)대로 approach.md 를 보강한 뒤 재실행 (검증자 재합의 후 워커 재개)";;
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
