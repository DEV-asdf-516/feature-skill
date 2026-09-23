#!/usr/bin/env bash
# =============================================================
# feature 파이프라인 러너 — 교통정리기 (agent 가 아니다)
# 파일 경로: .claude/skills/feature/scripts/feature-run.sh
# 사용법 (저장소 루트에서):
#   feature-run.sh [--feature <id>] [--new [--archive-as <이름>]] [--branch <이름>] [--worktree <디렉터리>]
#   feature-run.sh --feature <id> --finalize
#     --feature : 피처 전용 worktree 를 id 로 결정론적으로 확정(권장, scripts/feature-worktree.sh)
#     --finalize: DONE 된 피처 worktree 의 결과(B→F delta)를 원본 working tree 에 커밋 없이 3-way 반영하고 worktree·브랜치를 정리.
#                 사용자 승인 뒤에만 실행한다. 파이프라인 stage 가 아니며 DONE 의 의미를 바꾸지 않는다.
#     --worktree: 피처 전용 git worktree 에서 실행(권장). 없으면 --branch 로 생성. 다른 세션의 미커밋 변경과 물리적으로 분리.
#     --new     : 이전 피처 산출물을 archive/ 로 mv 하고 처음부터 시작
#     --branch  : 워커 진입 전 해당 브랜치가 없으면 생성·체크아웃
#   인자 없이 다시 실행하면 run-state.json 의 stage 에서 재개한다. 합의·리뷰 루프는 자체 체크포인트
#   (consensus-<target>.json, review-impl.json)로 round/substep 까지 이어가며, stage 결정은 consensus_pass_current 로 교차 확인한다.
#
# 상태 전이 (결정론적 제어만 담당):
#   preflight → design → impl → worker → review → verify → done
#   design : consensus-loop.sh design
#   impl   : consensus-loop.sh impl        (implementation.md + approach.md + implementation-units.json 필요)
#   worker : implementation-units.json 을 lock 으로 확정하고 units 배열 순서대로 **직렬** 실행 — unit 마다
#            fresh 워커(worker-unit.md, 결과 JSON DONE|UNDECIDED) → targeted_test(실패 시 unit 범위 수정 → 재테스트)
#            → context-updates.json(워커·수정 결과의 context_updates 를 순서대로 보존) → units/<id>/done.json.
#            unit 사이에 이어지는 것은 worktree 의 코드 + 합의 문서 + implementation-context.json(앞 unit 이 확정한 사실의 압축 색인,
#            워커가 낸 upsert/remove 를 러너가 (kind,subject) 키로 기계적으로 fold — 별도 요약 모델·추가 호출 없음)뿐이다. unit 별 리뷰·수정자·설계는 없다. Unit N 이 끝나기 전에는 N+1 을 시작하지 않는다.
#            병렬·DAG·우선순위 없음. 재실행은 첫 미완료 unit 부터. 모든 unit 완료 후 unit 결과를 worker-result.json 으로 합쳐
#            기존 전체 review 로 — 기존 `run_worker worker-implement.md` 1회를 unit 별 fresh 워커 여러 회로 바꾼 것뿐이다.
#   review : impl-review-loop.sh (리뷰어 게이트 → FIX_CODE 만 수정자 → 종결 검토)
#            DOC_GAP → 사용자(REVIEW_DOC_GAP, doc-gap-resume.json), DEADLOCK/MAX_ROUNDS → 사용자
#   doc-gap: 구현 후 DOC_GAP 재개 경로(doc-gap-resume.json 이 pending 인 동안 impl 지문 추론보다 우선). impl consensus 는 최초 워커 진입 전
#            사전 게이트일 뿐이고, 워커·리뷰어가 구현 중 발견한 DOC_GAP/USER_DECISION 은 사용자 결정이 최종이다 — 검증자·디자이너 재호출 없음.
#            WAITING_USER(답 전 — 모델 0회) → 답·approach 동기화·source tree 불변 확인 → WORKER_PENDING(unit 이면 그 unit 부터 worker stage,
#            리뷰 이슈면 review-gap 워커 1회가 DOC_GAP 결정 + 같은 리뷰의 FIX_CODE 를 함께) → REVIEW_PENDING → review → RESOLVED.
#   verify : 승인 지문 → TEST_CMD → LINT_CMD → 지문 재확인
#            실패 → worker-fix(최대 MAX_TEST_RETRIES) → review → verify
#            지문 STALE → review (연속 2회면 사용자 반환)
#
# 종료 코드 / run-state.json status:
#   0 DONE        완료
#   2 NEED_USER   사용자 판단 필요 (reason: ASK_USER | DEADLOCK | MAX_ROUNDS | UNDECIDED(워커 DOC_GAP/USER_DECISION) | REVIEW_DOC_GAP | DOC_GAP_SOURCE_CHANGED | DOC_GAP_SCOPE_EXCEEDED |
#                 TEST_RETRIES_EXHAUSTED | APPROVAL_STALE_REPEATED | FOREIGN_WORKTREE_CHANGE | SCOPE_VIOLATION |
#                 SCOPE_MANIFEST_CHANGED | SCOPE_BASELINE_CHANGED | UNITS_MANIFEST_CHANGED | UNIT_SCOPE_VIOLATION |
#                 UNIT_TEST_RETRIES_EXHAUSTED | UNIT_CHECKPOINT_CHAIN_STALE | DECISION_SCOPE_REQUIRED | WORKER_OUTCOME_UNCERTAIN | DESIGNER_SCOPE_VIOLATION)
#   3 NEED_DOCS   오케스트레이터가 문서를 써야 함 (reason: DESIGN_MISSING | IMPL_DOCS_MISSING | SCOPE_MISSING)
#   1 ENV_ERROR   환경·CLI 오류
#
# 자동 복구 금지: 여기서 허용하는 자동 루프는 성공 조건이 기계적으로 명확한
# 두 가지뿐이다 — (리뷰 이슈 → 수정자 → 재리뷰), (테스트 실패 → 워커 1회 수정 →
# 재리뷰 → 재테스트). unit 단계의 (targeted test 실패 → unit 범위 수정 → 재테스트)는 두 번째 형태와
# 같고 같은 한도(MAX_TEST_RETRIES)를 쓴다. "무슨 뜻인지 모르겠다", "둘 중 골라야 한다", "같은 이슈가
# 반복된다"는 추가 추론 없이 즉시 사람에게 반환한다. 여기에 더 똑똑한 복구를
# 추가하지 마라 — 이 스킬의 목적을 거꾸로 훼손한다.
# =============================================================
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SKILL_DIR/config.sh"
ROOT="$(git rev-parse --show-toplevel)"

# ---------- 인자 ----------
NEW=0; ARCHIVE_AS=""; BRANCH=""; WORKTREE=""; FEATURE_ID=""; FINALIZE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --new) NEW=1;;
    --archive-as) ARCHIVE_AS="$2"; shift;;
    --branch) BRANCH="$2"; shift;;
    --worktree) WORKTREE="$2"; shift;;
    --feature) FEATURE_ID="$2"; shift;;
    --finalize) FINALIZE=1;;
    *) echo "[FAIL] 알 수 없는 인자: $1" >&2; exit 1;;
  esac
  shift
done

# ---------- --feature <id> --finalize: DONE 된 피처 worktree 결과를 원본에 커밋 없이 반영하고 정리 (사용자 승인 뒤에만) ----------
# 파이프라인 stage 가 아니다 — 부트스트랩·러너 락·live.log 어느 것도 거치지 않고, 기존 worktree 를 찾아(없으면 만들지 않음) 검증·archive·
# B/O/F 3-way 반영·정리만 한다(scripts/feature-worktree.sh 의 finalize 절). 원본에서 실행한다. 종료 코드:
#   0 FINALIZED(또는 already finalized)  2 FINALIZE_CONFLICT / APPLIED_CLEANUP_INCOMPLETE(사용자 확인)  1 거부·오류(원본·worktree 불변)
if [ "$FINALIZE" = 1 ]; then
  [ -n "$FEATURE_ID" ] || { echo "[FAIL] --finalize 는 --feature <id> 와 함께 쓴다" >&2; exit 1; }
  [ "$NEW" = 0 ] || { echo "[FAIL] --finalize 와 --new 는 함께 쓸 수 없다" >&2; exit 1; }
  source "$SKILL_DIR/scripts/feature-worktree.sh"
  exec </dev/null
  if feature_worktree_finalize "$FEATURE_ID" "$BRANCH" "$WORKTREE"; then exit 0; else rc=$?; fi
  case "$rc" in
    2) exit 2;;
    *) echo "[FAIL] finalize 실패 (--feature $FEATURE_ID) — 원본·worktree 는 위 사유대로 보존됨" >&2; exit 1;;
  esac
fi

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
[ -f "$SKILL_DIR/scripts/worker-invoke.sh" ] || env_error "스크립트 없음: worker-invoke.sh (run_worker)"
[ -f "$WORKER_SCHEMA" ] || env_error "스키마 없음: $WORKER_SCHEMA"
for p in worker-unit.md worker-unit-fix.md worker-fix.md worker-review-gap.md; do
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
# scope 없는 옛 형식 `- [USER-QUESTION] …` 은 어느 합의 gate 의 결정인지 코드가 안전하게 추론할 수 없다(design 으로 보면
# impl 결정이 design PASS 를 깨는 버그가 유지되고, impl 로 보면 과거 design 결정을 잃는다). LLM 호출 전에 사람이 태그를 붙이게 멈춘다.
unscoped_decisions="$(consensus_unscoped_user_decisions)"
[ -z "$unscoped_decisions" ] || stop_need_user DECISION_SCOPE_REQUIRED "decisions.md 에 scope 없는 [USER-QUESTION] 줄이 있음 — 각 줄을 그 질문이 발생한 합의 gate 에 따라 '[USER-QUESTION][scope=design]'(요구·설계 선택, design ASK_USER/DEADLOCK/MAX_ROUNDS) 또는 '[USER-QUESTION][scope=impl]'(impl ASK_USER/DEADLOCK/MAX_ROUNDS, 워커 USER_DECISION) 로 직접 고친 뒤 재실행. 자동 추정 없음. 해당 줄(행번호:내용): $(printf '%s' "$unscoped_decisions" | paste -sd'|' -)"

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
  # doc-gap 힌트인데 체크포인트가 더 이상 pending 이 아니면(RESOLVED 직후 죽음) worker 부터 — 완료 unit 은 건너뛰고 review 로 간다
  case "$hinted" in preflight|"") STAGE=design;; doc-gap) STAGE=worker;; *) STAGE="$hinted";; esac
fi
# 활성 기준선 가드는 stage 와 관계없이 파이프라인 전체를 막는다 — 특히 verify 단계의 worker-fix 가 기준선을 바꿔 멈춘 뒤
# verify 로 재진입하는 경로: exact files 범위에서는 범위 밖 변경·기준선 변경이 승인 지문에 안 잡혀 리뷰 루프·run_worker 를 거치지 않고
# 테스트만 통과하면 DONE 이 된다. run_worker 안의 검사는 이 전역 검사 뒤 다른 세션이 기준선을 바꾸는 경우를 호출 직전에 다시 막는다.
require_baseline_guard_resolved \
  || stop_need_user SCOPE_BASELINE_CHANGED "worker-baseline.tree 가 직전 중단 시점의 기대값($(jq -r .expected "$BASELINE_GUARD"))으로 복구되지 않음 — 되돌린 뒤 재실행. 자동 복구 없음 (stage $STAGE 재개 전 전역 검사)"
# 직전 워커 호출의 완료 여부가 불확실(결과 JSON 없음/깨짐 + 작업 트리 변경 + rc≠0)한 채 멈췄으면, 사용자가 작업 트리를 호출 전 tree 로
# 되돌리기 전에는 stage 와 무관하게 모델·테스트 호출 0회로 다시 멈춘다 — 같은 편집을 정상 반영된 작업 위에 반복하지 않는다.
require_worker_outcome_guard_resolved \
  || stop_need_user WORKER_OUTCOME_UNCERTAIN "직전 워커 호출($(jq -r '.label' "$WORKER_OUTCOME_GUARD"))이 작업 트리를 바꿨지만 유효한 결과 JSON 없이 exit $(jq -r '.raw_exit_code' "$WORKER_OUTCOME_GUARD") 로 끝났고, 작업 트리가 호출 전 tree($(jq -r '.expected' "$WORKER_OUTCOME_GUARD"))로 복구되지 않음 — 변경 내용을 확인한 뒤 ① 호출 전 tree 로 명시적으로 되돌리고 재실행(워커 재호출) 하거나 ② 변경을 유지하려면 사용자가 직접 정리. 자동 원복·자동 재호출 없음 (stage $STAGE 재개 전 전역 검사)"
# 산출물이 힌트보다 뒤처져 있으면 뒤로 물린다 (state 만 믿지 않는다)
# 합의 PASS 판정은 config.sh 의 consensus_pass_current — 체크포인트(consensus-<target>.json)가 PASS 이고 계약 버전·
# 현재 입력 지문(request/design/impl docs + 그 target 범위의 [USER-QUESTION][scope=…])이 일치하며 가리키는 리뷰가 실제 PASS 여야 한다.
# scope=impl 결정은 impl 지문에만 들어가므로 impl 합의 뒤 추가된 사용자 결정은 design PASS 를 무효화하지 않는다.
# 파일명 정렬로 마지막 라운드 파일을 고르지 않는다 — 과거 round-02 PASS 가 새 round-01 BLOCK 을 가리고,
# 문서를 고친 뒤 재실행해도 합의 루프를 건너뛰는 경로가 있었다.
[ -f "$WORK_DIR/design.md" ] || { STAGE=design; stop_need_docs DESIGN_MISSING "$ROOT/$WORK_DIR/design.md 초안을 작성한 뒤 다시 실행"; }
case "$STAGE" in
  impl|worker|review|verify|done)
    consensus_pass_current design || { log "design 합의 PASS 가 현재 입력에 대해 유효하지 않음 — design 부터"; STAGE=design; };;
esac
# 구현 후 DOC_GAP 체크포인트가 pending 이면 impl 지문 추론보다 먼저 doc-gap 경로로 간다 — 사용자가 답을 decisions.md/approach.md 에 적으면
# impl PASS 지문은 당연히 stale 이 되지만 그것은 새 구현 제안이 아니라 pending gap 의 해결이다(검증자 재승인 없음). design PASS 는 위에서 이미 확인.
if [ "$STAGE" != design ] && doc_gap_pending; then
  log "DOC_GAP 재개 체크포인트 pending ($(doc_gap_next_step), origin $(doc_gap_field .origin)) — doc-gap 경로 우선"; STAGE=doc-gap
fi
case "$STAGE" in
  worker|review|verify|done)
    # impl PASS 가 stale 이어도 사용자가 해결한 gap 의 지문(doc-gap-resume.json)이 현재 입력과 같으면 impl 로 되돌리지 않는다(impl_docs_accepted)
    impl_docs_accepted || { log "impl 합의 PASS 가 현재 입력에 대해 유효하지 않음 — impl 부터"; STAGE=impl; };;
esac
case "$STAGE" in
  review|verify|done)
    { [ -f "$WORKER_RESULT" ] && jq -e '.status=="DONE"' "$WORKER_RESULT" >/dev/null 2>&1; } || STAGE=worker
    # 구현 단위 lock 이 있으면 모든 unit 의 done 체크포인트(내용 + 현재 spec 지문)도 유효해야 review 이상으로 간다 — worker-result.json 만 믿지 않는다
    if [ "$STAGE" != worker ] && [ -f "$UNITS_MANIFEST_LOCK" ] && ! all_units_done; then
      log "구현 단위 체크포인트가 전부 유효하지 않음 — worker 부터(첫 미완료 unit 에서 재개)"; STAGE=worker
    fi;;
esac
# verify 로 바로 가려면 approved.fingerprint 파일 존재만으론 부족하다 — 리뷰 체크포인트가 현재 계약·현재 작업 트리의
# 실제 APPROVE 리뷰를 가리켜야 한다(config.sh impl_approval_current). 아니면 리뷰 루프가 스스로 재개 지점을 고른다.
if [ "$STAGE" = verify ] && ! impl_approval_current; then
  log "구현 승인이 현재 작업 트리·계약에 대해 유효하지 않음 — review 부터"; STAGE=review
fi
log "시작 stage: $STAGE (test_retries=$TEST_RETRIES)"

# ---------- 워커 호출 ----------
# run_worker 는 scripts/worker-invoke.sh 에 있다(본문 그대로 분리 — tests/worker-regression.sh 가 같은 경로로 production 워커 1회를 호출한다).
source "$SKILL_DIR/scripts/worker-invoke.sh"

# ---------- 구현 단위 하나 실행 ----------
# fresh 워커 → targeted test(실패 시 unit 범위 수정 → 재테스트, MAX_TEST_RETRIES) → done.json. unit 별 리뷰·수정자는 없다 —
# 품질 승인은 모든 unit 뒤의 전체 review/verify 가 한다. targeted test 는 다음 unit 이 깨진 코드 위에 쌓이는 것을 막는 장치이지 리뷰의 대체가 아니다.
# 완료 체크포인트가 유효하면(내용 + spec 지문) 통째로 건너뛴다. 중간에 멈춘 unit 은 워커부터 다시 돌되 before.tree 는 첫 시도의 것을
# 재사용한다(unit 시작 시점의 증거). 러너는 unit 을 건너뛸지 판단하지 않는다(체크포인트가 유효한가만 본다).
run_unit() { # unit-id
  local id="$1" unit_dir="$WORK_DIR/units/$1" test_cmd test_log test_rc test_retries=0 test_n=0 title
  local pending=()   # 이번 시도의 결과 파일(워커 → test-fix 순). targeted test 최종 PASS 전까지 context_updates 는 pending 이다
  if unit_done_valid "$id"; then log "unit $id: 완료 체크포인트 유효 — 건너뜀"; return 0; fi
  # 직렬 의존성: 이 unit 을 (다시) 실행해야 하는데 뒤 unit 이 이미 완료돼 있으면 그 완료는 옛 결과 위에 쌓인 것이고 worktree 에도 그 코드가 남아 있다.
  # 뒤 unit 의 spec_hash 가 그대로여도 재사용하지 않고, 자동 원복(before.tree 로 되돌려 replay)도 하지 않는다 — 사람이 정리한 뒤 재실행.
  local later="" seen=0 u
  for u in $(unit_ids); do
    if [ "$seen" -eq 1 ] && [ -f "$WORK_DIR/units/$u/done.json" ]; then later="$later$u "; fi
    [ "$u" != "$id" ] || seen=1
  done
  if [ -n "$later" ]; then
    stop_need_user UNIT_CHECKPOINT_CHAIN_STALE "unit $id 를 다시 실행해야 하는데 뒤 unit(${later% })의 완료 체크포인트가 있다 — 뒤 unit 은 옛 $id 결과 위에 작성됐고 그 코드가 worktree 에 남아 있어 $id 재실행 결과와 맞는다는 보장이 없다. 자동 원복·자동 replay 없음. 사용자가 ① worktree 를 unit $id 시작 시점(units/$id/before.tree${unit_dir:+, $( [ -f "$unit_dir/before.tree" ] && cat "$unit_dir/before.tree" || echo '없음')})으로 되돌리고 ② units/<뒤 unit id>/ 체크포인트를 치운 뒤 재실행하면 $id 부터 순서대로 다시 돈다"
  fi
  mkdir -p "$unit_dir"
  unit_json "$id" > "$unit_dir/unit.json.tmp" && mv "$unit_dir/unit.json.tmp" "$unit_dir/unit.json" || env_error "unit $id: unit.json 기록 실패"
  jq -c --argjson v "$FEATURE_SCOPE_VERSION" '{version:$v, files:.scope.files, new_file_roots:(.scope.new_file_roots // [])}' "$unit_dir/unit.json" > "$unit_dir/scope.json.tmp" \
    && mv "$unit_dir/scope.json.tmp" "$unit_dir/scope.json" || env_error "unit $id: scope.json 기록 실패"
  feature_scope_valid_file "$unit_dir/scope.json" || env_error "unit $id: scope 가 feature-scope 형식(canonical 경로, files/roots 중 하나 이상)에 맞지 않음"
  title="$(jq -r '.title' "$unit_dir/unit.json")"; test_cmd="$(jq -r '.targeted_test' "$unit_dir/unit.json")"
  if [ -f "$unit_dir/before.tree" ] && git cat-file -e "$(cat "$unit_dir/before.tree")^{tree}" 2>/dev/null; then
    log "unit $id: 이전 시도의 시작 tree 재사용 ($(cat "$unit_dir/before.tree"))"
  else
    snapshot_worktree_tree > "$unit_dir/before.tree.tmp" && mv "$unit_dir/before.tree.tmp" "$unit_dir/before.tree" || env_error "unit $id: 시작 tree 기록 실패"
  fi
  # 앞 unit 들이 확정한 rolling context 를 재구성(완료 체크포인트가 유효한 것만) — 워커·test-fix 프롬프트에 들어간다
  impl_context_write "$id" || env_error "unit $id: implementation-context.json 재구성 실패 — 앞선 unit 의 완료 체크포인트가 유효하지 않음"
  write_state worker RUNNING "" "unit $id: worker"
  log "=== unit $id ($title) : fresh 워커 — context facts $(jq '.facts|length' "$IMPL_CONTEXT_FILE")건 — scope $(jq -c '{files:(.files|length), roots:(.new_file_roots|length)}' "$unit_dir/scope.json") ==="
  RUN_TAG=worker run_worker worker-unit.md "$unit_dir"
  pending+=("$unit_dir/worker-result.json")
  while :; do
    test_n=$((test_n + 1)); test_log="$unit_dir/targeted-test-$(printf '%02d' "$test_n").log"
    write_state worker RUNNING "" "unit $id: targeted test #$test_n"
    log "unit $id: targeted test: $test_cmd"
    set +e; bash -c "$test_cmd" > "$test_log" 2>&1; test_rc=$?; set -e
    cp "$test_log" "$unit_dir/targeted-test.log"
    [ "$test_rc" -ne 0 ] || break
    log "unit $id: targeted test 실패 (exit $test_rc) — $test_log"; tail -30 "$test_log"
    [ "$test_retries" -lt "$MAX_TEST_RETRIES" ] \
      || stop_need_user UNIT_TEST_RETRIES_EXHAUSTED "unit $id: targeted test 실패 $((test_retries + 1))회 — $test_log. 자동 복구 없음"
    test_retries=$((test_retries + 1))
    write_state worker RUNNING "" "unit $id: test-fix $test_retries/$MAX_TEST_RETRIES"
    # 수정은 unit 범위 안에서만(같은 fresh 세션 규칙, 같은 사후 검사) — 리뷰어를 부르지 않고 바로 재테스트한다
    TEST_LOG="$test_log" RUN_TAG="test-fix-$(printf '%02d' "$test_retries")" run_worker worker-unit-fix.md "$unit_dir"
    pending+=("$unit_dir/test-fix-$(printf '%02d' "$test_retries")-result.json")
  done
  log "unit $id: targeted test 통과"
  # context 확정: PASS 뒤에만, 워커 → 수정 순서로 보존한다(fold 는 impl_context_write 가 한다). done.json 보다 먼저 써야 체크포인트가 원천을 가리킨다
  { local f; for f in "${pending[@]}"; do context_update_of "$f" "$(basename "$f" -result.json)"; done; } \
    | jq -s --arg id "$id" --argjson v "$IMPL_CONTEXT_VERSION" '{version:$v, unit_id:$id, updates:.}' > "$unit_dir/context-updates.json.tmp" \
    && mv "$unit_dir/context-updates.json.tmp" "$unit_dir/context-updates.json" || env_error "unit $id: context-updates.json 기록 실패"
  jq -n --arg id "$id" --arg h "$(unit_spec_hash "$id")" --arg now "$(date '+%FT%T%z')" \
    '{version:1, unit_id:$id, spec_hash:$h, worker_status:"DONE", targeted_test_status:"PASS", completed_at:$now}' \
    > "$unit_dir/done.json.tmp" && mv "$unit_dir/done.json.tmp" "$unit_dir/done.json" || env_error "unit $id: done.json 기록 실패"
  impl_context_write || env_error "unit $id: implementation-context.json 갱신 실패"
  log "=== unit $id 완료 (done.json, context facts $(jq '.facts|length' "$IMPL_CONTEXT_FILE")건) ==="
}

# ---------- 상태 기계 ----------
while :; do
  write_state "$STAGE" RUNNING "" ""
  case "$STAGE" in

    design)
      set +e; bash "$SKILL_DIR/scripts/consensus-loop.sh" design; rc=$?; set -e
      case $rc in
        0) STAGE=impl;;
        2) stop_need_user "$(jq -r '.status' "$WORK_DIR/state.json" | sed 's/MAX_ROUNDS_EXCEEDED/MAX_ROUNDS/')" "설계 합의 중단 — ASK_USER 면 해당 이슈의 user_question·options 를, 그 외엔 마지막 reviews/validator-design-*.json 의 쟁점을 사용자에게 보고. 답은 decisions.md 에 '- [USER-QUESTION][scope=design] <질문> → <답>' 으로 기록(필요하면 design.md 반영) 후 재실행";;
        *) env_error "consensus-loop design 실패 (exit $rc)";;
      esac;;

    impl)
      { [ -f "$WORK_DIR/implementation.md" ] && [ -f "$WORK_DIR/approach.md" ] && units_manifest_present; } \
        || stop_need_docs IMPL_DOCS_MISSING "합의된 design.md 기반으로 $ROOT/$WORK_DIR/implementation.md(무엇)·approach.md(어떻게, REQUIRED/DELEGATED)·implementation-units.json(구현 단위, schemas/implementation-units.schema.json) 작성 후 재실행"
      # 구현 단위 manifest 는 합의 입력이므로 검증자를 부르기 전에 형식을 확정한다 (오케스트레이터 문서 오류 → NEED_DOCS)
      units_manifest_valid_file "$UNITS_MANIFEST_FILE" \
        || stop_need_docs IMPL_DOCS_MISSING "$ROOT/$UNITS_MANIFEST_FILE 형식 오류 — schemas/implementation-units.schema.json: version 1, units ≥1, unit 마다 id(순번-kebab, 유일, 배열 순서대로 증가)·title·goal·requirements≥1·scope(files/new_file_roots, canonical, 하나 이상)·references≥1·targeted_test(비어 있지 않음) 필수, 그 외 필드(depends_on/priority/parallel 등) 금지"
      set +e; bash "$SKILL_DIR/scripts/consensus-loop.sh" impl; rc=$?; set -e
      case $rc in
        0) STAGE=worker;;
        2) stop_need_user "$(jq -r '.status' "$WORK_DIR/state.json" | sed 's/MAX_ROUNDS_EXCEEDED/MAX_ROUNDS/')" "구현 문서 합의 중단 — ASK_USER 면 해당 이슈의 user_question·options 를, 그 외엔 마지막 reviews/validator-impl-*.json 의 쟁점을 사용자에게 보고. 답은 decisions.md 에 '- [USER-QUESTION][scope=impl] <질문> → <답>' 으로 기록(필요하면 implementation.md/approach.md 반영) 후 재실행 — design PASS 는 그대로 재사용되고 impl 만 Round 1 부터 재검증된다. 체크포인트·리뷰 JSON 을 손으로 고치지 않는다";;
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
      # ---------- 구현 단위 직렬 실행 ----------
      # manifest 검증 → unit scope ⊆ 전체 범위(lock) → lock 확정 → units 순서대로 run_unit → 결과 합치기. 러너는 순서를 바꾸거나 건너뛰지 않는다.
      units_manifest_present || stop_need_docs IMPL_DOCS_MISSING "$ROOT/$UNITS_MANIFEST_FILE 이 없다 — implementation.md 의 구현 범위를 기능 단위 unit 으로 나눠 작성 후 재실행(impl 재합의)"
      units_manifest_valid_file "$UNITS_MANIFEST_FILE" || stop_need_docs IMPL_DOCS_MISSING "$ROOT/$UNITS_MANIFEST_FILE 형식 오류 — schemas/implementation-units.schema.json 참고 후 재실행(impl 재합의)"
      outside="$(units_scope_outside_global "$UNITS_MANIFEST_FILE" "$FEATURE_SCOPE_LOCK")"
      [ -z "$outside" ] || stop_need_docs IMPL_DOCS_MISSING "unit scope 가 feature-scope.lock.json 범위 밖($(printf '%s' "$outside" | paste -sd, -)) — unit scope 는 전체 범위의 부분집합이어야 한다. implementation-units.json(또는 feature-scope.json) 을 고친 뒤 재실행(impl 재합의)"
      if lock_units_manifest; then :; else
        lock_rc=$?
        case "$lock_rc" in
          2) stop_need_user UNITS_MANIFEST_CHANGED "implementation-units.json 이 워커 진입 시 확정한 implementation-units.lock.json 과 다름. 의도한 분할 변경이면 lock 을 지우고 재실행(impl 재합의 후 새 lock 확정 — spec 이 그대로인 unit 의 완료 체크포인트는 유지된다), 아니면 원본을 lock 과 같게 되돌린 뒤 재실행. 어느 쪽이 맞는지 파이프라인이 정하지 않는다";;
          *) env_error "implementation-units.lock.json 생성 또는 확인 실패";;
        esac
      fi
      log "구현 단위 lock: $UNITS_MANIFEST_LOCK ($(jq -r '[.units[].id] | length' "$UNITS_MANIFEST_LOCK") units: $(unit_ids | paste -sd' ' -))"
      for unit_id in $(unit_ids); do
        run_unit "$unit_id"
      done
      # 모든 unit 완료 → unit 별 워커 결과를 전체 review 입력(worker-result.json)으로 합친다. 최종 품질 승인은 여기가 아니라 전체 review/verify 다.
      { for unit_id in $(unit_ids); do cat "$WORK_DIR/units/$unit_id/worker-result.json"; done; } \
        | jq -s '{status:"DONE", undecided:[], delegated_choices:(map(.delegated_choices[])), tests:(map(.tests[])), context_updates:{upsert:[],remove:[]}}' > "$WORKER_RESULT.tmp" \
        && mv "$WORKER_RESULT.tmp" "$WORKER_RESULT" || env_error "unit 결과 합치기 실패"
      log "모든 구현 단위 완료 (delegated_choices $(jq '.delegated_choices|length' "$WORKER_RESULT")건) — 전체 review 로"
      # unit 워커 DOC_GAP 을 사용자가 해결한 뒤 그 unit 부터 다시 돌아 전부 끝났다 → 사용자 해결 provenance 는 RESOLVED 로 남는다(지문은 그대로 유효)
      if [ "$(doc_gap_next_step)" = WORKER_PENDING ] && [ -n "$(doc_gap_field '.unit_id')" ]; then doc_gap_set_step RESOLVED || env_error "doc-gap-resume.json 갱신 실패"; fi
      STAGE=review;;

    doc-gap)
      # 사용자 답 전에는 모델을 부르지 않는다. 답이 오면 검증자·디자이너 없이 워커 → 리뷰. 어느 substep 에서 죽어도 여기서 이어간다.
      gap_step="$(doc_gap_next_step)"; gap_unit="$(doc_gap_field '.unit_id')"; gap_review="$(doc_gap_field '.review')"
      gap_reason=UNDECIDED; [ "$(doc_gap_field '.origin')" != review ] || gap_reason=REVIEW_DOC_GAP
      # 수리된 단계(WORKER_PENDING/REVIEW_PENDING)라도 provenance 다섯 조건이 지금 깨져 있으면(답 삭제·frozen 문서 변경·밑바탕 PASS 무효) 모델 0회로 멈춘다
      if [ "$gap_step" != WAITING_USER ] && ! doc_gap_resolved_current; then
        stop_need_user DOC_GAP_SCOPE_EXCEEDED "사용자 해결 체크포인트($gap_step)의 provenance 가 현재 상태와 맞지 않는다 — 답 줄 삭제, implementation.md/units/scope 변경, decisions.md 기존 줄 수정, 또는 impl consensus PASS 무효. 해당 변경을 되돌리고 재실행하거나, 새 구현 제안이면 doc-gap-resume.json 을 치우고 재실행(impl 재합의). 자동 복구 없음"
      fi
      case "$gap_step" in
        WAITING_USER)
          unanswered="$(doc_gap_unanswered)"
          if [ -n "$unanswered" ]; then
            log "사용자 결정 대기 중 — 답 없는 gap: $(printf '%s' "$unanswered" | paste -sd, -)"; doc_gap_report
            stop_need_user "$gap_reason" "구현 중 발견된 미결정 사항 — 사용자 결정이 최종이며 검증자·디자이너를 다시 부르지 않는다. 각 gap 의 답을 decisions.md 에 '- [USER-QUESTION][scope=impl][<tag>] <질문> → <답>'(빈 답 불가) 으로 기록하고 approach.md 에 그 결정을 최소한으로 반영한 뒤 재실행. 답 없는 gap: $(printf '%s' "$unanswered" | paste -sd, -). 항목: $(doc_gap_field '[.gaps[] | "[\(.key)] \(.question) (options: \(.options|join(" | ")))"] | join(" ; ")')"
          fi
          doc_gap_approach_synced \
            || stop_need_user "$gap_reason" "모든 gap 에 답은 있지만 approach.md 가 DOC_GAP 발생 시점과 같다 — 사용자 결정을 approach.md 에 반영(동기화)한 뒤 재실행. 러너·디자이너가 대신 쓰지 않는다"
          doc_gap_source_unchanged \
            || stop_need_user DOC_GAP_SOURCE_CHANGED "사용자 결정을 기다리는 동안 source worktree 가 DOC_GAP 발생 시점 tree($(doc_gap_field '.source_tree'))와 달라졌다 — 기존 리뷰·워커 결과를 조용히 재사용하지 않는다. 변경을 확인한 뒤 ① 그 tree 로 명시적으로 되돌리고 재실행하거나 ② 변경을 유지하려면 doc-gap-resume.json 을 치우고 재실행(새 리뷰가 필요). 자동 원복 없음"
          # 해결 범위 밖 변경(implementation.md/units/scope 변경, decisions.md 기존 줄 삭제·수정)은 gap 해결이 아니라 새 제안 — 사용자 해결 경로로 우회하지 않는다
          if doc_gap_accept; then :; else
            case $? in
              2) stop_need_user DOC_GAP_SCOPE_EXCEEDED "gap 해결 범위(approach.md 반영 + decisions.md 추가) 밖의 impl 입력이 바뀌었다(implementation.md/implementation-units.json/feature-scope.json 변경 또는 decisions.md 기존 줄 삭제·수정). 사용자 해결 경로로는 impl 재합의를 우회할 수 없다 — 의도한 새 구현 제안이면 doc-gap-resume.json 을 치우고 재실행(impl 재합의), 아니면 그 문서를 gap 발생 시점으로 되돌리고 재실행";;
              *) env_error "doc-gap-resume.json 의 밑바탕 impl consensus PASS 가 유효하지 않거나 수리 기록 실패 — 체크포인트·consensus-impl.json 을 손으로 고치지 않는다";;
            esac
          fi
          log "DOC_GAP 사용자 결정 확인 ($(doc_gap_field '[.gaps[].key] | join(",")')) — approach 동기화·source tree 불변 — 검증자·디자이너 없이 워커로"
          continue;;
        WORKER_PENDING)
          if [ -n "$gap_unit" ]; then
            # unit 워커 DOC_GAP: 그 unit 은 완료 처리되지 않았으므로 일반 worker stage 가 첫 미완료 unit(= 그 unit)부터 직렬로 이어간다
            log "unit $gap_unit 부터 워커 재개(앞선 완료 unit 은 건너뜀)"; STAGE=worker; continue
          fi
          if [ -z "$gap_review" ]; then
            # verify 의 worker-fix 가 낸 미결정: 결정이 approach.md 에 반영됐으므로 verify 로 돌아가 테스트 → 필요하면 worker-fix 가 다시 돈다
            doc_gap_set_step RESOLVED || env_error "doc-gap-resume.json 갱신 실패"; STAGE=verify; continue
          fi
          # 리뷰 DOC_GAP: review-gap 워커 1회. 재시작 안전성 — 워커가 이미 끝났으면(after tree == 현재, 유효 DONE 결과) 재호출 없이 리뷰로,
          # source tree 가 기록과 다르면(외부 변경) fail closed. 모델 호출 없이 판정.
          cur_tree="$(snapshot_worktree_tree)" || env_error "작업 트리 스냅샷 실패"
          if [ -f "$WORK_DIR/review-gap-after.tree" ] && [ "$(cat "$WORK_DIR/review-gap-after.tree")" = "$cur_tree" ] \
             && worker_result_valid "$WORK_DIR/review-gap-result.json" && jq -e '.status=="DONE"' "$WORK_DIR/review-gap-result.json" >/dev/null 2>&1; then
            log "review-gap 워커 결과가 이미 현재 작업 트리와 일치 — 재호출 없이 리뷰로"
            doc_gap_set_step REVIEW_PENDING "$cur_tree" || env_error "doc-gap-resume.json 갱신 실패"; STAGE=review; continue
          fi
          [ "$cur_tree" = "$(doc_gap_field '.source_tree')" ] \
            || stop_need_user DOC_GAP_SOURCE_CHANGED "review-gap 워커 호출 전 source worktree 가 기록된 tree($(doc_gap_field '.source_tree'))와 다르다 — 조용히 진행하지 않는다. 그 tree 로 되돌리고 재실행하거나 doc-gap-resume.json 을 치우고 새 리뷰. 자동 원복 없음"
          write_state doc-gap RUNNING "" "review-gap worker ($(basename "$gap_review"))"
          log "=== review-gap 워커: DOC_GAP 사용자 결정 + 같은 리뷰의 FIX_CODE 를 함께 구현 ($(basename "$gap_review")) ==="
          RUN_TAG=review-gap REVIEW_FILE="$gap_review" DOC_GAP_REVIEW="$gap_review" \
            GAP_CONTEXT="$(printf '리뷰 JSON: %s\n리뷰 당시 diff: %s\n\n미결정 항목과 사용자 결정:\n%s' "$gap_review" "$(dirname "$gap_review")/diff-round-$(printf '%02d' "$(doc_gap_field '.round')").patch" "$(doc_gap_prompt_block)")" \
            run_worker worker-review-gap.md
          doc_gap_set_step REVIEW_PENDING "$(cat "$WORK_DIR/review-gap-after.tree")" || env_error "doc-gap-resume.json 갱신 실패"
          STAGE=review; continue;;
        REVIEW_PENDING) STAGE=review; continue;;
        *) STAGE=worker; continue;;
      esac;;

    review)
      set +e; bash "$SKILL_DIR/scripts/impl-review-loop.sh"; rc=$?; set -e
      case $rc in
        0)
          [ "$(doc_gap_next_step)" != REVIEW_PENDING ] || doc_gap_set_step RESOLVED || env_error "doc-gap-resume.json 갱신 실패"
          STAGE=verify;;
        2) stop_need_user "$(jq -r '.status' "$WORK_DIR/state.json" | sed 's/MAX_ROUNDS_EXCEEDED/MAX_ROUNDS/')" "구현 리뷰 중단 — state.json.review 의 남은 이슈를 사용자에게 보고";;
        3)
          # 리뷰어 DOC_GAP: 사용자 결정. 루프가 doc-gap-resume.json(WAITING_USER, 리뷰·source tree 포함)을 남겼다 — impl 재합의 없음.
          log "리뷰어 DOC_GAP — 사용자 결정 필요:"; doc_gap_report
          stop_need_user REVIEW_DOC_GAP "리뷰어가 구현 중 미결정 solution shape 를 보고함($(jq -r '.issues' "$WORK_DIR/state.json")) — 사용자 결정이 최종이며 검증자·디자이너·impl 재합의 없이 review-gap 워커 1회(DOC_GAP 결정 + 같은 리뷰의 FIX_CODE $(jq -r '[.issues[] | select(.action=="FIX_CODE") | .id] | join(",")' "$(jq -r '.review' "$WORK_DIR/state.json")")) → 리뷰로 간다. 각 issue 의 답을 decisions.md 에 '- [USER-QUESTION][scope=impl][review-issue=<id>] <질문> → <답>' 으로 기록하고 approach.md 에 반영한 뒤 재실행. 항목: $(doc_gap_field '[.gaps[] | "[\(.key)] \(.question) (options: \(.options|join(" | ")); refs: \(.refs|join(", ")); impact: \(.impact))"] | join(" ; ")')";;
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
      anomaly_n="$(cli_anomaly_count)"
      [ "$anomaly_n" -eq 0 ] || log "[WARN] CLI 종료코드 불일치 복구 $anomaly_n 건 — $CLI_ANOMALY_LOG (raw exit code 는 usage.jsonl 에 그대로)"
      log "DONE"
      exit 0;;

    *) env_error "알 수 없는 stage: $STAGE";;
  esac
done
