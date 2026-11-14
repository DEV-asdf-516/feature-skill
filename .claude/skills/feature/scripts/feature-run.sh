#!/usr/bin/env bash
# =============================================================
# feature 파이프라인 러너 — 교통정리기 (agent 가 아니다)
# 파일 경로: .claude/skills/feature/scripts/feature-run.sh
# 사용법 (저장소 루트에서):
#   feature-run.sh [--feature <id>] [--new [--archive-as <이름>]] [--branch <이름>] [--worktree <디렉터리>] [--new-review-attempt]
#   feature-run.sh --feature <id> --finalize
#     --feature : 피처 전용 worktree 를 id 로 결정론적으로 확정(권장, scripts/feature-worktree.sh)
#     --finalize: DONE 된 피처 worktree 의 결과(B→F delta)를 원본 working tree 에 커밋 없이 3-way 반영하고 worktree·브랜치를 정리.
#                 사용자 승인 뒤에만 실행한다. 파이프라인 stage 가 아니며 DONE 의 의미를 바꾸지 않는다.
#     --worktree: 피처 전용 git worktree 에서 실행(권장). 없으면 --branch 로 생성. 다른 세션의 미커밋 변경과 물리적으로 분리.
#     --new     : 이전 피처 산출물을 archive/ 로 mv 하고 처음부터 시작
#     --branch  : 워커 진입 전 해당 브랜치가 없으면 생성·체크아웃
#     --new-review-attempt : REVIEW_OUTPUT_INVALID(리뷰어 출력 계약 위반)로 멈춘 리뷰 단계에 한정한 **명시적 새 리뷰 시도**. 무효 기록을 닫고 새 attempt Round 1(새 세션)로
#                 리뷰한다. 피처 전체를 다시 시작하는 --new 가 아니며, 대기 중인 무효 출력이 없으면 아무 효과가 없다. 이 실행의 첫 리뷰 루프 호출에만 적용된다.
#   인자 없이 다시 실행하면 run-state.json 의 stage 에서 재개한다. 합의·리뷰 루프는 자체 체크포인트
#   (consensus-<target>.json, review-impl.json)로 round/substep 까지 이어가며, stage 결정은 consensus_stage_accepted(검증자 PASS 또는
#   합의 에스컬레이션의 유효한 사용자 수리 USER_RESOLVED)로 교차 확인한다.
#
# 상태 전이 (결정론적 제어만 담당):
#   preflight → design → impl → worker → review → verify → done
#   design : consensus-loop.sh design
#   impl   : consensus-loop.sh impl        (implementation.md + approach.md + implementation-units.json 필요)
#            design/impl 의 사용자 에스컬레이션(ASK_USER | DEADLOCK | MAX_ROUNDS)은 user-escalation-resume-<target>.json(WAITING_USER)을 남긴다.
#            사용자가 모든 blocker 에 [USER-QUESTION][scope=<target>][escalation=<id>] 답을 추가하면 그 단계 검증자·디자이너 0회로
#            USER_RESOLVED → 다음 단계(design → impl 은 impl 합의를 정상 수행, impl → worker). 답 전·일부 답은 모델 0회 NEED_USER.
#            USER_RESOLVED 는 검증자 PASS 가 아니며 review/verify/DONE 게이트는 그대로다.
#   worker : implementation-units.json 을 lock 으로 확정하고 units 배열 순서대로 **직렬** 실행 — Feature 전체를 **하나의 Worker
#            세션**(worker-invoke.sh 의 FEATURE_WORKER_SESSION, 저널 worker-session.json)이 턴 단위로 이어 간다: unit 마다
#            같은 세션의 워커 턴(worker-unit.md, 결과 JSON DONE|UNDECIDED) → targeted_test(실패 시 같은 세션에 unit 범위 수정 → 재테스트)
#            → context-updates.json(워커·수정 결과의 context_updates 를 순서대로 보존) → units/<id>/done.json.
#            unit 사이에 이어지는 것은 worktree 의 코드 + 합의 문서 + 같은 Worker 세션의 대화 문맥 + implementation-context.json(앞 unit 이
#            확정한 사실의 압축 색인 — 세션 기억은 source of truth 가 아니고 이 색인·문서가 체크포인트다). unit 별 리뷰·수정자·설계는 없다.
#            Unit N 이 끝나기 전에는 N+1 을 시작하지 않는다 — 다음 unit 시작 권한은 러너만 갖는다.
#            병렬·DAG·우선순위·worker pool 없음. 재실행은 첫 미완료 unit 부터(유효한 결과 + after-tree 일치 + **워커가 받은 계약 == 현재 계약**이면 워커 재호출 없이 테스트부터).
#            unit 유효 계약(config.sh "unit 유효 계약 스냅샷"): unit 마다 references 가 가리키는 문서 절 본문·그 unit 의 사용자 결정·unit JSON(local)과
#            request/conventions/묶이지 않은 결정(global)을 최초 워커 호출 직전에 스냅샷한다. 네 지점이 같은 지문을 본다 — ① 완료 체크포인트 건너뛰기 전
#            ② 과거 worker-result 로 테스트부터 재개하기 전 ③ done.json 확정 전 ④ review/verify/DONE 진입 전. local 이 바뀐 unit 만 stale 이 되어
#            [UNIT TURN]/[CHANGED CONTRACT](실제 diff)를 받은 워커 턴 + targeted test 뒤에만 새 done.json 이 생긴다. 다른 unit 의 독립 절 변경은 영향이 없다.
#            전역 입력만 바뀌었거나(영향 unit 을 코드가 정하지 않는다), 스냅샷 없는 과거 산출물이거나, references 를 해석할 수 없으면 모델 0회로
#            UNIT_CONTRACT_IMPACT_REQUIRED — 사용자가 unit-contract-impact.json(version 2, 러너가 내준 target_fingerprint 포함)으로 영향 unit 을 확정한다(추가 LLM 분석 없음).
#            모든 unit 완료 후 unit 결과를 worker-result.json 으로 합쳐 기존 전체 review 로.
#   review : impl-review-loop.sh (리뷰어 게이트 → FIX_CODE 만 수정자 → 종결 검토)
#            DOC_GAP → 사용자(REVIEW_DOC_GAP, doc-gap-resume.json), DEADLOCK/MAX_ROUNDS → 사용자
#            리뷰어 출력 계약 위반 → 사용자(REVIEW_OUTPUT_INVALID, reviews/invalid-review.json) — 일반 재실행은 리뷰어 0회로 같은 진단(검사기를 고쳤으면 저장된 출력을
#            로컬 재검증), 새 리뷰는 --new-review-attempt 로만. CLI 결과 불확실(결과 JSON 없음 — ENV_ERROR, codex resume marker 유지)과 다른 상태다.
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
#                 DOC_GAP_LOCATION_UNRESOLVED(gap 위치를 파일 경로로 확정할 수 없음 — 범위 위반과 구분, 체크포인트는 WAITING_USER 유지) |
#                 TEST_RETRIES_EXHAUSTED | APPROVAL_STALE_REPEATED | FOREIGN_WORKTREE_CHANGE | SCOPE_VIOLATION | REVIEW_OUTPUT_INVALID |
#                 SCOPE_MANIFEST_CHANGED | SCOPE_BASELINE_CHANGED | UNITS_MANIFEST_CHANGED | UNIT_SCOPE_VIOLATION |
#                 UNIT_TEST_RETRIES_EXHAUSTED | UNIT_CHECKPOINT_CHAIN_STALE | UNIT_CONTRACT_IMPACT_REQUIRED | UNIT_CONTRACT_STALE | DECISION_SCOPE_REQUIRED | WORKER_OUTCOME_UNCERTAIN | DESIGNER_SCOPE_VIOLATION |
#                 RESOLVED_GAP_REPEATED(이미 사용자가 결정한 unit 미결정을 워커가 같은 질문으로 재반환 — 자동 재시도 없음) |
#                 WORKER_SESSION_MISMATCH(세션 전제 불일치 — 자동 resume·자동 fresh 금지) | WORKER_SESSION_MISSING(이전 fresh-워커 실행의 묵시적 마이그레이션 금지))
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
NEW=0; ARCHIVE_AS=""; BRANCH=""; WORKTREE=""; FEATURE_ID=""; FINALIZE=0; NEW_REVIEW_ATTEMPT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --new) NEW=1;;
    --archive-as) ARCHIVE_AS="$2"; shift;;
    --branch) BRANCH="$2"; shift;;
    --worktree) WORKTREE="$2"; shift;;
    --feature) FEATURE_ID="$2"; shift;;
    --finalize) FINALIZE=1;;
    --new-review-attempt) NEW_REVIEW_ATTEMPT=1;;
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
# [Added: GOAL-6] 종료 공통 비용 보고 — DONE 뿐 아니라 NEED_USER/NEED_DOCS/ENV_ERROR 로 멈출 때도 usage_summary 의 같은 숫자로 보고하고 usage-summary.json 을 갱신한다.
# usage.jsonl 을 다시 집계할 뿐이라 이중 카운트가 없다. usage.jsonl 이 없으면(실제 invocation 전 실패) 빈 상태로 표시한다. 모델 호출 없음, 종료 코드·상태 불변.
report_usage_on_exit() {
  if [ -s "$WORK_DIR/usage.jsonl" ]; then
    usage_summary > "$WORK_DIR/usage-summary.json.tmp" && mv "$WORK_DIR/usage-summary.json.tmp" "$WORK_DIR/usage-summary.json" || true
    local cost_line; cost_line="$(usage_cost_report_line)" || cost_line=""
    [ -z "$cost_line" ] || log "$cost_line (상세: $WORK_DIR/usage-summary.json)"
  else
    log "비용(usage_summary): child invocation 없음 — usage.jsonl 없음(시작 전 중단)"
  fi
  return 0
}
stop_need_user() { # reason detail
  log "NEED_USER ($1): $2"
  write_state "$STAGE" NEED_USER "$1" "$2"
  report_usage_on_exit
  exit 2
}
# 오케스트레이터가 문서를 쓰기 직전에 읽는 유일한 출력이 이 반환이다. 그래서 설계·구현 문서 요청(DESIGN_MISSING / IMPL_DOCS_MISSING)에는
# 이 worktree 의 conventions.md 본문을 그대로 덧붙여 "작성 직전 재대조" 를 강제한다 — 세션 첫 프롬프트에 주입된 원본 conventions 는
# 긴 세션에서 멀어지고 snapshot 된 worktree 사본과 다를 수 있다. CONVENTIONS_FILE 은 위에서 worktree 로 재바인딩돼 있다.
# 훅(PreToolUse 거부)으로 하지 않는 이유: 거부는 대조를 강제하지 못하고 문서 본문 재출력만 만든다. 러너 흐름 밖의 임의 문서 수정은
# 검증자(v18 부터 impl 검증자도 conventions 수신)가 하류에서 잡는다.
print_conventions_for_docs() { # reason
  case "$1" in DESIGN_MISSING|IMPL_DOCS_MISSING) ;; *) return 0;; esac
  [ -f "$CONVENTIONS_FILE" ] || return 0
  local doc_names="design.md"
  [ "$1" = IMPL_DOCS_MISSING ] && doc_names="implementation.md·approach.md"
  echo
  echo "[PROJECT CONVENTIONS] ($CONVENTIONS_FILE) — $doc_names 작성 직전 재대조용. 이 worktree 사본이 기준이다."
  echo "대조 절차: ① 아래 규칙 중 이번 문서의 변경 대상·계약·책임 배치에 적용되는 항목을 고른다 ② 그 항목이 요구하는 방식을 문서에 명시 반영한다(명시적 project convention 이 직접 요구한 방식은 material decision 이다 — 워커 재량으로 남기지 않는다) ③ 적용 규칙이 하나도 없으면 문서 전제·비범위 절에 '적용 conventions: 없음 — <사유>' 한 줄을 남긴다(decisions.md 는 합의 지문 대상이므로 거기엔 쓰지 않는다)."
  cat "$CONVENTIONS_FILE"
  echo
}
stop_need_docs() {
  log "NEED_DOCS ($1): $2"
  write_state "$STAGE" NEED_DOCS "$1" "$2"
  report_usage_on_exit
  print_conventions_for_docs "$1"
  exit 3
}
env_error() {
  log "ENV_ERROR: $*"
  write_state "${STAGE:-preflight}" ENV_ERROR ENV_ERROR "$*"
  report_usage_on_exit
  exit 1
}
# [Modified: 리뷰 3] 예기치 않은 종료(set -e·시그널 등 명시적 종료 함수를 거치지 않은 경로)에도 비용 보고를 남긴다. 명시적 경로(DONE/stop_need_user/
# stop_need_docs/env_error)는 이미 report_usage_on_exit 를 불렀고 상태를 기록했으므로, 여기서는 상태가 아직 ENV_ERROR 가 아닐 때만 1회 보고한다(이중 출력 없음).
on_unexpected_exit() { # rc
  jq -e '.status=="ENV_ERROR"' "$STATE" >/dev/null 2>&1 && return 0
  write_state "${STAGE:-preflight}" ENV_ERROR ENV_ERROR "예기치 않은 종료 (exit $1)"
  [ -z "${WORK_DIR:-}" ] || report_usage_on_exit
}
trap 'rc=$?; case $rc in 0|2|3) ;; *) on_unexpected_exit "$rc";; esac; release_runner_lock' EXIT
[ -z "$FEATURE_ID" ] || log "피처 worktree: $ROOT (feature $FEATURE_ID, branch $BRANCH, $FEATURE_WORKTREE_MODE${FEATURE_SNAPSHOT_TREE:+, snapshot tree $FEATURE_SNAPSHOT_TREE}) — 문서·산출물은 $ROOT/$WORK_DIR"

# ---------- unit 유효 계약: 영향 확정 게이트 (모델 호출 0회) ----------
# 진행 흔적이 있는 unit(done.json / 워커 호출 흔적) 가운데 코드가 영향 여부를 정할 수 없는 것을 모은다:
#   NO_BASELINE      스냅샷 없는 과거 산출물 — '현재 문서가 첫 시도 당시와 같다'를 증명할 수 없다(최초 실행으로 오판 금지)
#   IMPACT_REQUIRED  완료된 unit 인데 전역 입력(request.md·conventions.md·묶이지 않은 사용자 결정·references 에 절이 없는 design.md)만 바뀜
# 사용자가 $UNIT_CONTRACT_IMPACT_FILE 로 unit 마다 affected / unaffected 를 확정해야 진행한다. 조용히 '영향 없음'으로 넘어가지 않고 LLM 에게 묻지도 않는다.
#   unaffected : 기준 계약의 전역 부분을 현재로 옮긴다(스냅샷 없던 unit 은 현재 문서를 기준으로 확정). 완료 체크포인트는 그 결정 기록과 함께 유지된다.
#   affected   : 그 unit 을 stale 로 만든다 — 워커가 변경 계약을 받아 기존 구현을 대조·수정하고 targeted test 뒤에만 새 done.json 이 생긴다.
# mode check: 확정 파일이 없거나 대상과 맞지 않으면 멈춘다(합의 단계 전의 조기 확인 — 파일 적용은 문서가 확정된 worker 진입 때).  mode apply: 검증 → 적용 → 파일 소비(.used.<ts>).
# 확정은 '그때 본 계약'에 대한 것이다: 러너가 확정 대상의 지문(target_fingerprint = 대상 unit 마다 id·상태·local 계약 지문·전역 계약 지문)을
#   $UNIT_CONTRACT_IMPACT_REQUEST 와 중단 사유에 내주고, 확정 파일은 그 값을 그대로 적어야 한다(version 2). check·apply 모두 직전에 다시 계산해 대조한다 —
#   사용자가 판단한 뒤 계약 문서가 한 번 더 바뀌었으면(합의 단계의 디자이너 수정 포함) 대상 집합이 같아도 같은 확정을 적용하지 않고 모델 0회로 다시 확정을 요구한다.
#   지문 없는 옛 형식(version 1)은 무엇을 보고 확정했는지 증명할 수 없으므로 적용하지 않는다.
UNIT_CONTRACT_IMPACT_REQUEST="$WORK_DIR/unit-contract-impact.request.json"
apply_unit_contract_impact() { # unit-id affected|unaffected
  local id="$1" dec="$2" ud="$WORK_DIR/units/$1" dir meta compose
  dir="$(unit_contract_dir "$id")"; meta="$dir/contract.json"
  unit_contract_current "$id" || env_error "unit $id: 계약 렌더링 실패 — $UC_WHY"
  if [ "$dec" = unaffected ]; then
    if [ -f "$meta" ]; then
      compose="$WORK_DIR/.unit-contract/$id.rebase"
      mkdir -p "$compose" && cp "$dir/baseline/contract.txt" "$compose/contract.txt" && cp "$UC_DIR/global.txt" "$compose/global.txt" || env_error "unit $id: 기준 계약 전역 부분 갱신 준비 실패"
      unit_contract_write_baseline "$id" user-confirmed-unaffected "$compose" || env_error "unit $id: 기준 계약 기록 실패"
    else
      unit_contract_write_baseline "$id" user-confirmed-unaffected "$UC_DIR" || env_error "unit $id: 기준 계약 기록 실패"
      # 사용자가 '현재 문서 == 첫 시도 당시 문서'로 확정했다 — 이미 있는 워커 결과가 받은 계약도 현재 계약으로 본다(테스트-only 재개 판정용)
      if [ -f "$ud/worker-result.json" ] && [ ! -f "$ud/worker-contract.json" ]; then
        jq -n --arg id "$id" --arg l "$UC_LOCAL" --arg g "$UC_GLOBAL" --arg fp "$(unit_contract_fingerprint_of "$UC_LOCAL" "$UC_GLOBAL")" --arg now "$(date '+%FT%T%z')" \
          '{unit_id:$id, kind:"USER_CONFIRMED_BASELINE", local_fingerprint:$l, global_fingerprint:$g, fingerprint:$fp, previous_fingerprint:$fp, recorded_at:$now}' \
          > "$ud/worker-contract.json.tmp" && mv "$ud/worker-contract.json.tmp" "$ud/worker-contract.json" || env_error "unit $id: worker-contract.json 기록 실패"
      fi
    fi
    if [ -f "$ud/done.json" ]; then
      jq --argjson v "$UNIT_DONE_VERSION" --arg fp "$(jq -r '.fingerprint' "$meta")" --arg tfp "$(jq -r '.target_fingerprint' "$UNIT_CONTRACT_IMPACT_FILE")" --arg now "$(date '+%FT%T%z')" \
        '.contract_determinations=((.contract_determinations // []) + [{decision:"unaffected", by:"unit-contract-impact.json", target_fingerprint:$tfp, from_version:.version, at:$now}])
         | .version=$v | .unit_contract_fingerprint=$fp' "$ud/done.json" > "$ud/done.json.tmp" && mv "$ud/done.json.tmp" "$ud/done.json" || env_error "unit $id: done.json 갱신 실패"
    fi
  elif [ -f "$meta" ]; then
    jq --arg g "$UC_GLOBAL" --arg now "$(date '+%FT%T%z')" '.impact_confirmed_global=$g | .impact_confirmed_at=$now' "$meta" > "$meta.tmp" && mv "$meta.tmp" "$meta" || env_error "unit $id: contract.json 갱신 실패"
  else
    unit_contract_write_baseline "$id" user-confirmed-affected "" || env_error "unit $id: 기준 계약 기록 실패"
  fi
}
units_contract_preflight() { # check | apply
  local mode="$1" id ud st need="" why="" unresolved="" dir bad ts targets="" target_fp
  [ -f "$UNITS_MANIFEST_LOCK" ] || return 0
  for id in $(unit_ids); do
    ud="$WORK_DIR/units/$id"
    { [ -f "$ud/done.json" ] || [ -f "$ud/worker-before.tree" ] || [ -f "$ud/worker-result.json" ]; } || continue
    st="$(unit_contract_status "$id")"
    case "$st" in
      UNRESOLVED) unit_contract_current "$id" || true; unresolved="$unresolved[$id] $UC_WHY ; ";;
      NO_BASELINE)
        unit_contract_current "$id" || env_error "unit $id: 계약 렌더링 실패 — $UC_WHY"
        targets="$targets$id"$'\t'"$st"$'\t'"$UC_LOCAL"$'\t'"$UC_GLOBAL"$'\n'
        need="$need$id "; why="$why[$id] 계약 스냅샷 없음(이 기능 이전의 산출물 — 현재 문서가 첫 시도 당시와 같은지 증명할 수 없다) ; ";;
      IMPACT_REQUIRED)
        # 전역 입력만 바뀐 완료 unit. 구현 후 gap 의 사용자 해결은 전역 계약을 바꾸지 않으므로(unit_contract_drift_covered ②) 그 예외는 여기 해당하지 않는다.
        if [ -f "$ud/done.json" ]; then
          dir="$(unit_contract_dir "$id")"
          unit_contract_current "$id" || env_error "unit $id: 계약 렌더링 실패 — $UC_WHY"
          { diff -u -L "previous/global.txt" -L "current/global.txt" "$dir/baseline/global.txt" "$UC_DIR/global.txt" || true; } > "$ud/global-impact.diff"
          targets="$targets$id"$'\t'"$st"$'\t'"$UC_LOCAL"$'\t'"$UC_GLOBAL"$'\n'
          need="$need$id "; why="$why[$id] 완료된 unit 인데 전역 입력이 바뀜(diff: $ud/global-impact.diff) ; "
        fi;;
    esac
  done
  if [ -n "$unresolved" ] && [ "$mode" = apply ]; then
    stop_need_user UNIT_CONTRACT_IMPACT_REQUIRED "이미 진행된 unit 의 references 를 현재 문서에서 해석할 수 없다 — '영향 없음'으로 넘어가지 않는다(모델 호출 0회). ${unresolved}가리키던 절이 삭제·개명됐거나 같은 heading 이 둘 이상이다. 문서의 heading 을 복구하거나 implementation-units.json 의 references 를 정확한 절(design.md#… 포함)로 고친 뒤 재실행(범위·분할이 바뀌면 impl 재합의)"
  fi
  [ -n "$need" ] || return 0
  need="${need% }"
  # 확정 대상 지문: 대상 unit 의 (id, 상태, local 계약 지문, 전역 계약 지문). 사용자가 본 계약과 적용 시점의 계약이 같은지 이 값 하나로 대조한다.
  target_fp="$(printf '%s' "$targets" | sha256_stdin)"
  printf '%s' "$targets" | jq -Rn --arg fp "$target_fp" --arg now "$(date '+%FT%T%z')" \
    '{version:2, target_fingerprint:$fp, units:[inputs | select(length>0) | split("\t") | {id:.[0], status:.[1], local_fingerprint:.[2], global_fingerprint:.[3]}], generated_at:$now}' \
    > "$UNIT_CONTRACT_IMPACT_REQUEST.tmp" && mv "$UNIT_CONTRACT_IMPACT_REQUEST.tmp" "$UNIT_CONTRACT_IMPACT_REQUEST" || env_error "unit-contract-impact.request.json 기록 실패"
  if [ ! -f "$UNIT_CONTRACT_IMPACT_FILE" ]; then
    stop_need_user UNIT_CONTRACT_IMPACT_REQUIRED "unit 계약의 영향 여부를 코드가 정할 수 없다(모델 호출 0회, 자동 재실행·자동 원복 없음): ${why}영향 unit 을 명시적으로 확정하라 — $UNIT_CONTRACT_IMPACT_FILE 에 {\"version\":2,\"target_fingerprint\":\"$target_fp\",\"affected_units\":[…],\"unaffected_units\":[…]} 를 쓰고 재실행. target_fingerprint 는 지금 확정 대상인 계약의 지문이다(대상별 내역: $UNIT_CONTRACT_IMPACT_REQUEST) — 확정 뒤 계약 문서가 다시 바뀌면 이 값이 달라져 같은 확정이 적용되지 않는다. 대상 unit($need)을 빠짐없이 둘 중 한 목록에만 넣는다. unaffected = 이 변경이 그 unit 의 구현 계약에 영향이 없음(스냅샷 없던 unit 은 '현재 문서가 구현 당시와 같음')을 사용자가 확정 — 완료 체크포인트 유지. affected = 그 unit 을 변경 계약으로 다시 돌린다(뒤 unit 이 이미 완료돼 있으면 기존 UNIT_CHECKPOINT_CHAIN_STALE 정책대로 멈춘다). 다음부터 전역 변경에 덜 걸리려면 unit references 에 의존하는 design.md#<절> 을 명시한다"
  fi
  # 확정 파일의 형식·대상 일치는 check 단계에서도 본다 — 틀린 파일을 들고 합의 단계(유료 검증자)까지 갔다가 worker 진입에서 거부되지 않게 한다
  # 지문 대조는 check·apply 모두에서 한다 — apply 는 check 뒤에 합의 단계(디자이너의 문서 수정)를 지났을 수 있으므로 적용 직전의 현재 계약으로 다시 계산한 값이다.
  bad="$(jq -r --arg need "$need" --arg fp "$target_fp" '
    ($need | split(" ")) as $n
    | if type=="object" and .version==1 then "지문 없는 옛 형식(version 1) — 어떤 계약을 보고 확정했는지 증명할 수 없다. version 2 로 다시 확정하라(target_fingerprint 필수)"
      elif type!="object" or .version!=2 or (.target_fingerprint|type)!="string" or ((.affected_units // [])|type)!="array" or ((.unaffected_units // [])|type)!="array" then "형식이 {version:2, target_fingerprint:\"…\", affected_units:[], unaffected_units:[]} 가 아님"
      elif .target_fingerprint != $fp then "확정 당시의 계약 지문(\(.target_fingerprint))이 현재 확정 대상의 지문(\($fp))과 다름 — 확정한 뒤 계약 문서(절 본문·전역 입력·사용자 결정)나 대상 unit 이 다시 바뀌었다. 이전 판단을 그대로 적용하지 않는다: 현재 diff 를 다시 확인하고 target_fingerprint 를 현재 값으로 고쳐 다시 확정하라"
      elif (((.affected_units // []) + (.unaffected_units // [])) | sort) != ($n | sort) then "두 목록의 합집합이 확정 대상 unit(\($n|join(", ")))과 정확히 같지 않음(누락·중복·대상 아닌 unit)"
      else "" end' "$UNIT_CONTRACT_IMPACT_FILE" 2>/dev/null)" || bad="JSON 파싱 실패"
  [ -z "$bad" ] || stop_need_user UNIT_CONTRACT_IMPACT_REQUIRED "$UNIT_CONTRACT_IMPACT_FILE 을 적용할 수 없다(모델 호출 0회) — $bad. 확정 대상: $need (${why}), 현재 target_fingerprint: $target_fp (내역: $UNIT_CONTRACT_IMPACT_REQUEST). 파일을 고친 뒤 재실행"
  [ "$mode" = apply ] || return 0
  for id in $(jq -r '(.unaffected_units // [])[]' "$UNIT_CONTRACT_IMPACT_FILE"); do apply_unit_contract_impact "$id" unaffected; done
  for id in $(jq -r '(.affected_units // [])[]' "$UNIT_CONTRACT_IMPACT_FILE"); do apply_unit_contract_impact "$id" affected; done
  ts="$(date '+%Y%m%d-%H%M%S')"
  log "unit 계약 영향 확정 적용 — unaffected: $(jq -r '(.unaffected_units // []) | join(",")' "$UNIT_CONTRACT_IMPACT_FILE") / affected: $(jq -r '(.affected_units // []) | join(",")' "$UNIT_CONTRACT_IMPACT_FILE") (기록: $WORK_DIR/unit-contract-impact.used.$ts.json)"
  mv "$UNIT_CONTRACT_IMPACT_FILE" "$WORK_DIR/unit-contract-impact.used.$ts.json" || env_error "unit-contract-impact.json 소비 실패"
  mv "$UNIT_CONTRACT_IMPACT_REQUEST" "$WORK_DIR/unit-contract-impact.request.used.$ts.json" || env_error "unit-contract-impact.request.json 소비 실패"
}
# review / verify / DONE 진입 직전: 모든 unit 의 완료 체크포인트가 **현재 계약**에 대해 유효해야 한다(같은 실행 안에서 문서·결정이 바뀐 경우까지 잡는다).
require_units_contract_current() { # 다음-단계
  [ -f "$UNITS_MANIFEST_LOCK" ] || return 0
  all_units_done && return 0
  stop_need_user UNIT_CONTRACT_STALE "$1 진입 전 검사: 구현 단위 완료 체크포인트가 현재 계약(문서 절·사용자 결정·unit JSON)에 대해 전부 유효하지 않다 — 이전 완료·승인을 재사용하지 않는다. 그대로 재실행하면 러너가 합의 상태를 다시 확인한 뒤 첫 stale unit 부터 변경 계약으로 워커를 돌린다(자동 원복 없음)"
}

# ---------- preflight ----------
STAGE=preflight
# 런타임 계약 표식: 이 스크립트가 전제하는 config.sh 본문(헬퍼) 세대. config.sh 는 사용자 편집 파일이라 설치가 덮어쓰지 않으므로, 옛 본문이 남은 혼합 설치를
# 헬퍼 이름이 아니라 이 값으로 가려 모델 호출 전에 멈춘다(install.sh 도 설치 전에 같은 값을 대조한다). config.sh 의 FEATURE_RUNTIME_CONTRACT_VERSION 과 함께 올린다.
REQUIRED_RUNTIME_CONTRACT_VERSION=1
[ "${FEATURE_RUNTIME_CONTRACT_VERSION:-}" = "$REQUIRED_RUNTIME_CONTRACT_VERSION" ] \
  || env_error "config.sh 의 런타임 계약 표식(FEATURE_RUNTIME_CONTRACT_VERSION=${FEATURE_RUNTIME_CONTRACT_VERSION:-없음})이 이 스크립트가 요구하는 값($REQUIRED_RUNTIME_CONTRACT_VERSION)과 다르다 — scripts/·schemas/ 와 config.sh 본문이 서로 다른 버전이다(혼합 설치). 새 config.sh(설치 시 만들어진 config.sh.new)의 '헬퍼' 이하 본문을 병합하고 모델·명령 설정은 유지한 뒤 재실행"
require_role_bins DESIGNER VALIDATOR WORKER REVIEWER FIXER jq uuidgen envsubst git || env_error "역할별 CLI 확인 실패"
for f in consensus-loop.sh impl-review-loop.sh; do
  [ -x "$SKILL_DIR/scripts/$f" ] || env_error "스크립트 없음/실행권한 없음: $f"
done
[ -f "$SKILL_DIR/scripts/worker-invoke.sh" ] || env_error "스크립트 없음: worker-invoke.sh (run_worker)"
[ -f "$SKILL_DIR/scripts/notify-done.sh" ] || env_error "스크립트 없음: notify-done.sh (notify_feature_done)"
[ -f "$WORKER_SCHEMA" ] || env_error "스키마 없음: $WORKER_SCHEMA"
for p in worker-unit.md worker-unit-fix.md worker-fix.md worker-review-gap.md; do
  [ -f "$SKILL_DIR/prompts/$p" ] || env_error "프롬프트 없음: $p"
done

if [ "$NEW" = 1 ]; then
  # 이전 산출물은 삭제하지 않고 archive/ 로 이동 (rm 금지)
  archive_name="$ARCHIVE_NAME"
  archive_dir="$WORK_DIR/archive/$archive_name"
  moved=0
  for item in "$WORK_DIR"/* "$WORK_DIR"/.session-* "$WORK_DIR"/.unit-contract; do   # .unit-contract = unit 계약 렌더링(파생물) — 이전 피처 것이 남지 않게 함께 옮긴다
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
[ -z "$unscoped_decisions" ] || stop_need_user DECISION_SCOPE_REQUIRED "decisions.md 에 scope 없는 [USER-QUESTION] 줄이 있음 — 각 줄을 그 결정이 **처음 영향을 주는 단계**에 따라 '[USER-QUESTION][scope=design]'(요구·외부 동작·design.md 에 영향 — 질문이 impl/워커/리뷰 단계에서 나왔어도) 또는 '[USER-QUESTION][scope=impl]'(합의된 설계는 그대로이고 implementation.md·approach.md·unit 분할·범위에만 영향) 로 직접 고친 뒤 재실행. 자동 추정 없음. 해당 줄(행번호:내용): $(printf '%s' "$unscoped_decisions" | paste -sd'|' -)"

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
# unit 계약의 영향 확정이 필요한데 확정 파일이 없으면 합의 단계(검증자)로 가기 전에 모델 0회로 멈춘다. 구현 후 gap 대기 중에는 그 경로의 provenance 규칙이 먼저다.
doc_gap_pending || units_contract_preflight check
# 산출물이 힌트보다 뒤처져 있으면 뒤로 물린다 (state 만 믿지 않는다)
# 합의 PASS 판정은 config.sh 의 consensus_pass_current — 체크포인트(consensus-<target>.json)가 PASS 이고 계약 버전·
# 현재 입력 지문(request/design/impl docs + 그 target 범위의 [USER-QUESTION][scope=…])이 일치하며 가리키는 리뷰가 실제 PASS 여야 한다.
# scope=impl 결정은 impl 지문에만 들어가므로 impl 합의 뒤 추가된 사용자 결정은 design PASS 를 무효화하지 않는다.
# 파일명 정렬로 마지막 라운드 파일을 고르지 않는다 — 과거 round-02 PASS 가 새 round-01 BLOCK 을 가리고,
# 문서를 고친 뒤 재실행해도 합의 루프를 건너뛰는 경로가 있었다.
[ -f "$WORK_DIR/design.md" ] || { STAGE=design; stop_need_docs DESIGN_MISSING "$ROOT/$WORK_DIR/design.md 초안을 작성한 뒤 다시 실행"; }
case "$STAGE" in
  impl|worker|review|verify|done)
    # design 진입 권한은 검증자 PASS 또는 design 에스컬레이션의 유효한 사용자 수리(USER_RESOLVED — PASS 아님, user-escalation-resume-design.json)다.
    # 사용자 수리 뒤 impl 로 넘어갔다가 재실행해도 design 검증자를 다시 부르지 않는다. 수리 뒤 입력이 또 바뀌었으면 둘 다 무효 → design 부터.
    consensus_stage_accepted design || { log "design 합의 PASS 가 현재 입력에 대해 유효하지 않음 — design 부터"; STAGE=design; };;
esac
# 구현 후 DOC_GAP 체크포인트가 pending 이면 impl 지문 추론보다 먼저 doc-gap 경로로 간다 — 사용자가 답을 decisions.md/approach.md 에 적으면
# impl PASS 지문은 당연히 stale 이 되지만 그것은 새 구현 제안이 아니라 pending gap 의 해결이다(검증자 재승인 없음). design PASS 는 위에서 이미 확인.
if [ "$STAGE" != design ] && doc_gap_pending; then
  log "DOC_GAP 재개 체크포인트 pending ($(doc_gap_next_step), origin $(doc_gap_field .origin)) — doc-gap 경로 우선"; STAGE=doc-gap
fi
case "$STAGE" in
  worker|review|verify|done)
    # impl PASS 가 stale 이어도 사용자가 해결한 gap 의 지문(doc-gap-resume.json)이 현재 입력과 같으면 impl 로 되돌리지 않는다(impl_docs_accepted).
    # impl 합의 에스컬레이션의 유효한 사용자 수리(user-escalation-resume-impl.json, USER_RESOLVED)도 워커 진입 권한이다 — impl 검증자를 다시 부르지 않는다.
    impl_docs_accepted || { log "impl 합의 PASS 가 현재 입력에 대해 유효하지 않음 — impl 부터"; STAGE=impl; };;
esac
case "$STAGE" in
  review|verify|done)
    { [ -f "$WORKER_RESULT" ] && jq -e '.status=="DONE"' "$WORKER_RESULT" >/dev/null 2>&1; } || STAGE=worker
    # 구현 단위 lock 이 있으면 모든 unit 의 done 체크포인트(내용 + 현재 spec 지문 + 현재 유효 계약 지문)도 유효해야 review 이상으로 간다 — worker-result.json 만 믿지 않는다.
    # 영향 확정 파일이 있으면 여기서 적용한다(이 경로는 worker stage 를 거치지 않을 수 있다).
    [ "$STAGE" = worker ] || units_contract_preflight apply
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

# ---------- DONE 완료 푸시 알림 ----------
# notify_feature_done 은 scripts/notify-done.sh — done stage 의 write_state done DONE 직후 1회.
# 미설정·발송 실패는 DONE(exit 0)을 바꾸지 않고, 재발송은 notify-done.sent 마커와 "이미 DONE" 조기 종료가 막는다.
source "$SKILL_DIR/scripts/notify-done.sh"

# ---------- 구현 단위 하나 실행 ----------
# Feature Worker 세션의 워커 턴 → targeted test(실패 시 같은 세션에 unit 범위 수정 → 재테스트, MAX_TEST_RETRIES) → done.json.
# unit 별 리뷰·수정자는 없다 — 품질 승인은 모든 unit 뒤의 전체 review/verify 가 한다. targeted test 는 다음 unit 이 깨진 코드 위에
# 쌓이는 것을 막는 장치이지 리뷰의 대체가 아니다. 완료 체크포인트가 유효하면(내용 + spec 지문) 통째로 건너뛴다.
# 중간에 멈춘 unit 의 재개는 대화 진도가 아니라 **결과 JSON + 실제 tree** 로 판정한다: 직전 시도의 유효한 DONE 결과의 after-tree 가
# 현재 tree 와 일치하면 워커 재호출 없이 테스트부터, tree 가 바뀌었는데 일치하는 유효 결과가 없으면 WORKER_OUTCOME_UNCERTAIN 으로
# 멈춘다(새 세션 생성·같은 세션 임의 재호출 금지). 그 외에는 워커 턴부터 다시 돌되 before.tree 는 첫 시도의 것을 재사용한다
# (unit 시작 시점의 증거). 러너는 unit 을 건너뛸지 판단하지 않는다(체크포인트가 유효한가만 본다).
run_unit() { # unit-id
  local id="$1" unit_dir="$WORK_DIR/units/$1" test_cmd test_log test_rc test_retries=0 test_n=0 title
  local pending=()   # 이번 시도의 결과 파일(워커 → test-fix 순). targeted test 최종 PASS 전까지 context_updates 는 pending 이다
  if unit_done_valid "$id"; then log "unit $id: 완료 체크포인트 유효(spec + 현재 계약 지문) — 건너뜀"; return 0; fi
  [ ! -f "$unit_dir/done.json" ] || log "unit $id: 완료 체크포인트가 현재 spec·계약에 대해 유효하지 않음($(unit_contract_status "$id")) — 과거 DONE 을 재사용하지 않고 다시 실행"
  # (계약이 바뀐 unit 만 여기까지 온다 — 다른 unit 의 독립 절 변경은 이 unit 을 무효화하지 않으므로 불필요한 연쇄 stale 을 만들지 않는다.)
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
  # 세션 전제는 워커 호출 여부와 무관하게 unit 진입 시 확정한다(이전 체계 산출물의 묵시적 마이그레이션도 여기서 막힌다)
  ensure_feature_worker_session
  # ---------- 재개 판정: 대화 진도가 아니라 결과 JSON + 실제 tree ----------
  # 직전 시도의 마지막 결과(worker → test-fix-NN 순)가 유효한 DONE 이고 그 after-tree 가 현재 tree 와 같으면
  # CLI 호출은 끝났고 targeted test 전(또는 중)에 죽은 것이다 — 같은 워커를 재호출하지 않고 테스트부터 재개한다.
  # 건너뛴 호출 몫의 범위 게이트(전체 scope + unit scope)는 모델 호출 0회로 여기서 다시 돈다.
  local cur_tree resume_tag="" latest="" last_attempt="" fixes=0 fix_i fix_tag
  cur_tree="$(snapshot_worktree_tree)" || env_error "unit $id: 작업 트리 스냅샷 실패"
  [ ! -f "$unit_dir/worker-result.json" ] || latest=worker
  [ ! -f "$unit_dir/worker-before.tree" ] || last_attempt=worker
  for ((fix_i=1; fix_i<=MAX_TEST_RETRIES; fix_i++)); do
    fix_tag="test-fix-$(printf '%02d' "$fix_i")"
    [ ! -f "$unit_dir/$fix_tag-before.tree" ] || last_attempt="$fix_tag"
    [ -f "$unit_dir/$fix_tag-result.json" ] || break
    latest="$fix_tag"; fixes=$fix_i
  done
  if [ -n "$latest" ] && worker_result_valid "$unit_dir/$latest-result.json" \
     && [ -f "$unit_dir/$latest-after.tree" ] && [ "$(cat "$unit_dir/$latest-after.tree")" = "$cur_tree" ] \
     && jq -e '.status=="DONE"' "$unit_dir/$latest-result.json" >/dev/null 2>&1; then
    # 유효한 UNDECIDED 결과 + tree 일치는 DOC_GAP 해결 후 재개 — resume 이 아니라 워커 턴을 다시 돈다(아래 일반 경로)
    # 계약 게이트: 그 DONE 결과는 '워커가 그때 받은 계약'에 대한 것이다. 문서 절·사용자 결정·unit JSON 이 그 뒤 바뀌었으면 테스트만 다시 돌려 완료시키지 않고
    # 워커 턴을 다시 돈다(변경 계약 diff 전달 → 기존 구현 대조). tree 가 같다는 사실은 계약이 같다는 증거가 아니다.
    if unit_worker_contract_current "$id" "$unit_dir"; then
      resume_tag="$latest"
    else
      log "unit $id: 직전 결과($latest)의 tree 는 일치하지만 워커가 받은 계약과 현재 계약이 다르다${UC_WHY:+ ($UC_WHY)} — 테스트-only 재개 금지, 워커 턴부터"
    fi
  elif [ -n "$last_attempt" ] && [ ! -f "$unit_dir/$last_attempt-after.tree" ] \
       && [ "$cur_tree" != "$(cat "$unit_dir/$last_attempt-before.tree")" ]; then
    # run_worker 는 CLI 반환 직후(게이트 전에) after-tree 를 기록한다 — before-tree 만 있고 after-tree 가 없는 시도는
    # CLI 호출 중에 죽은 것이고, 그 위에 tree 까지 바뀌었으면 세션이 얼마나 진행됐는지 알 수 없다.
    # (게이트 중단·실행 실패는 after-tree 가 남으므로 여기 걸리지 않고 기존 가드·재호출 규칙을 따른다.)
    stop_need_user WORKER_OUTCOME_UNCERTAIN "unit $id: 직전 시도($last_attempt)가 CLI 호출 중에 중단됐고(after-tree 없음) 작업 트리가 호출 전 tree($(cat "$unit_dir/$last_attempt-before.tree"))와 다르다 — 대화 세션이 얼마나 진행됐는지 알 수 없으므로 새 세션을 만들거나 같은 세션을 자동 재호출하지 않고 원복도 하지 않는다. 변경을 확인한 뒤 호출 전 tree 로 명시적으로 되돌리고 재실행하거나, 변경을 유지하려면 사용자가 정리 방식을 명시하라"
  fi
  if [ -n "$resume_tag" ]; then
    local baseline_resume violations
    baseline_resume="$(read_worker_baseline_tree)" || env_error "unit $id: worker-baseline.tree 가 유효한 tree 를 가리키지 않음"
    violations="$(feature_scope_violations "$(cat "$unit_dir/before.tree")" "$cur_tree" "$baseline_resume")"
    [ -z "$violations" ] || stop_need_user SCOPE_VIOLATION "unit $id 재개 검사: feature-scope 밖 경로가 바뀜($(printf '%s' "$violations" | paste -sd, -)) — 자동 원복 없음"
    violations="$(SCOPE_MANIFEST_OVERRIDE="$unit_dir/scope.json" feature_scope_violations "$(cat "$unit_dir/before.tree")" "$cur_tree" "$baseline_resume")"
    [ -z "$violations" ] || stop_need_user UNIT_SCOPE_VIOLATION "unit $id 재개 검사: unit scope 밖 경로가 바뀜($(printf '%s' "$violations" | paste -sd, -)) — 자동 원복 없음, 다음 unit 으로 가지 않음"
    pending+=("$unit_dir/worker-result.json")
    for ((fix_i=1; fix_i<=fixes; fix_i++)); do pending+=("$unit_dir/test-fix-$(printf '%02d' "$fix_i")-result.json"); done
    test_retries=$fixes
    log "unit $id: 직전 시도의 유효한 결과($resume_tag)가 현재 tree 와 일치 — 워커 재호출 없이 targeted test 부터 재개 (test_retries=$test_retries)"
  else
    write_state worker RUNNING "" "unit $id: worker"
    log "=== unit $id ($title) : Feature Worker 세션 턴 — context facts $(jq '.facts|length' "$IMPL_CONTEXT_FILE")건 — scope $(jq -c '{files:(.files|length), roots:(.new_file_roots|length)}' "$unit_dir/scope.json") ==="
    RUN_TAG=worker run_worker worker-unit.md "$unit_dir"
    pending+=("$unit_dir/worker-result.json")
  fi
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
  # DONE 확정 직전 계약 게이트: 워커 턴이 받은 계약과 지금 유효한 계약이 같아야 한다 — 워커 실행·테스트 도중 문서·결정이 바뀌었으면
  # 통과한 테스트는 옛 계약에 대한 것이다. done.json 을 쓰지 않고 멈춘다(재실행이 합의 상태 확인 → 변경 계약으로 워커 턴을 다시 돈다).
  unit_worker_contract_current "$id" "$unit_dir" \
    || stop_need_user UNIT_CONTRACT_STALE "unit $id: targeted test 는 통과했지만 워커 턴이 받은 계약과 현재 유효 계약이 다르다(워커 실행·테스트 도중 문서 절·사용자 결정·unit JSON 이 바뀜${UC_WHY:+ — $UC_WHY}) — done.json 을 확정하지 않았다. 재실행하면 변경 계약(units/$id/changed-contract.diff)을 받은 워커 턴부터 다시 돈다. 자동 원복 없음"
  # 완료 시점 계약이 다음 세대의 기준이 된다(옛 기준은 contract/history 로). done.json 은 그 지문을 든다 — spec_hash 만으로는 문서 변경을 못 잡는다.
  unit_contract_write_baseline "$id" unit-done "$UC_DIR" || env_error "unit $id: 완료 시점 계약 스냅샷 기록 실패"
  jq -n --arg id "$id" --arg h "$(unit_spec_hash "$id")" --argjson v "$UNIT_DONE_VERSION" --arg now "$(date '+%FT%T%z')" \
    --arg fp "$(jq -r '.fingerprint' "$(unit_contract_dir "$id")/contract.json")" --arg l "$UC_LOCAL" --arg g "$UC_GLOBAL" \
    '{version:$v, unit_id:$id, spec_hash:$h, unit_contract_fingerprint:$fp, contract_local_fingerprint:$l, contract_global_fingerprint:$g,
      worker_status:"DONE", targeted_test_status:"PASS", completed_at:$now}' \
    > "$unit_dir/done.json.tmp" && mv "$unit_dir/done.json.tmp" "$unit_dir/done.json" || env_error "unit $id: done.json 기록 실패"
  impl_context_write || env_error "unit $id: implementation-context.json 갱신 실패"
  # 세션 저널의 진행 체크포인트 갱신 — 상태 문자열이 아니라 done.json·실제 tree 와 함께 대조되는 보조 기록이다
  local done_tree; done_tree="$(snapshot_worktree_tree)" || env_error "unit $id: 완료 tree 스냅샷 실패"
  worker_session_note_unit_done "$id" "$done_tree" || env_error "unit $id: worker-session.json 갱신 실패"
  # 세션 교체 판단은 unit 경계에서만 — 관측 토큰이 임계치 이상이면 worker-handoff.json 을 쓰고 다음 unit 부터 fresh 세대
  maybe_rotate_feature_worker_session "$id" "$done_tree"
  log "=== unit $id 완료 (done.json, context facts $(jq '.facts|length' "$IMPL_CONTEXT_FILE")건) ==="
}

# ---------- 합의 단계 사용자 에스컬레이션 안내 ----------
# 합의 루프가 exit 2 로 돌아왔을 때의 NEED_USER detail. 사용자 에스컬레이션(WAITING_USER)이면 blocker 마다 써야 할 답 줄을 그대로 준다.
# 그 외 exit 2(DESIGNER_SCOPE_VIOLATION 등)는 에스컬레이션 체크포인트가 없으므로 state.json 을 보라는 안내만 한다.
escalation_detail() { # target docs
  if [ "$(user_escalation_step "$1")" != WAITING_USER ]; then printf '%s' "$WORK_DIR/state.json 의 status 와 사유를 확인"; return 0; fi
  local unanswered; unanswered="$(user_escalation_unanswered "$1" | paste -sd, -)"
  printf '%s' "사용자 결정이 최종이다 — 아래 blocker **전부**에 답을 decisions.md 에 추가하고(blocker 마다 한 줄: '- [USER-QUESTION][scope=$1][escalation=<id>] <질문·쟁점> → <답>', <질문·쟁점> 은 아래 항목의 문구 그대로, <답> 은 실제 결정으로 바꾼다 — 빈 답·'<답>' 같은 플레이스홀더·다른 scope·다른 id·질문 문구 불일치는 인정되지 않는다. 검증자 요구를 기각하는 것도 같은 형식의 답이다) 결정 내용을 $2 에 반영한 뒤(ASK_USER 는 문서가 발생 시점과 같으면 수리되지 않는다) 재실행하면 $1 검증자·디자이너를 다시 부르지 않고 다음 단계로 간다(USER_RESOLVED — 검증자 PASS 아님). 답이 일부만 있으면 모델 호출 0회로 다시 멈춘다. request.md·상위 문서·범위(feature-scope/implementation-units)·conventions 를 함께 바꾸면 이 우회 대상이 아니라 Round 1 부터 재합의한다. 체크포인트·리뷰 JSON 을 손으로 고치지 않는다. 답 없는 blocker: ${unanswered:-없음}.$(user_escalation_docs_synced "$1" || printf ' 문서 미반영: %s 가 발생 시점과 같다 — ASK_USER 의 선택을 반영해야 한다.' "$2") 항목: $(user_escalation_field "$1" '[.issues[] | "[\(.id)] (\(.action)) \(.question)" + (if (.options|length)>0 then " (options: \(.options|join(" | ")))" else "" end)] | join(" ; ")')"
}
consensus_exit0_note() { # target — exit 0 이 검증자 PASS 인지 사용자 수리인지 로그에 남긴다(둘은 다른 provenance)
  [ "$(jq -r '.status // ""' "$WORK_DIR/state.json" 2>/dev/null)" != USER_RESOLVED ] \
    || log "$1 단계: 사용자 수리(USER_RESOLVED, $(user_escalation_field "$1" '.reason'), blocker $(user_escalation_field "$1" '[.issues[].id] | join(",")')) — 검증자 PASS 아님, $(user_escalation_file "$1")"
}

# ---------- 상태 기계 ----------
while :; do
  write_state "$STAGE" RUNNING "" ""
  case "$STAGE" in

    design)
      set +e; bash "$SKILL_DIR/scripts/consensus-loop.sh" design; rc=$?; set -e
      case $rc in
        0) consensus_exit0_note design; STAGE=impl;;
        2) stop_need_user "$(jq -r '.status' "$WORK_DIR/state.json" | sed 's/MAX_ROUNDS_EXCEEDED/MAX_ROUNDS/')" "설계 합의 중단 — ASK_USER 면 해당 이슈의 user_question·options 를, 그 외엔 state.json.review 의 쟁점을 사용자에게 보고. $(escalation_detail design 'design.md')";;
        *) env_error "consensus-loop design 실패 (exit $rc)";;
      esac;;

    impl)
      { [ -f "$WORK_DIR/implementation.md" ] && [ -f "$WORK_DIR/approach.md" ] && units_manifest_present; } \
        || stop_need_docs IMPL_DOCS_MISSING "합의된 design.md 기반으로 $ROOT/$WORK_DIR/implementation.md(무엇)·approach.md(어떻게, REQUIRED/DELEGATED)·implementation-units.json(구현 단위, schemas/implementation-units.schema.json) 작성 후 재실행"
      # 구현 단위 manifest 는 합의 입력이므로 검증자를 부르기 전에 형식을 확정한다 (오케스트레이터 문서 오류 → NEED_DOCS)
      units_manifest_valid_file "$UNITS_MANIFEST_FILE" \
        || stop_need_docs IMPL_DOCS_MISSING "$ROOT/$UNITS_MANIFEST_FILE 형식 오류 — schemas/implementation-units.schema.json: version 1, units ≥1, unit 마다 id(순번-kebab, 유일, 배열 순서대로 증가)·title·goal·requirements≥1·scope(files/new_file_roots, canonical, 하나 이상)·references≥1·targeted_test(비어 있지 않음) 필수, 그 외 필드(depends_on/priority/parallel 등) 금지"
      # unit references 는 계약 의존의 유일한 근거다 — 가리키는 절이 없거나 모호한 manifest 로 검증자를 부르지 않는다(모델 0회).
      bad_refs="$(units_unresolved_references "$UNITS_MANIFEST_FILE" | paste -sd';' -)"
      if [ -n "$bad_refs" ]; then
        if ls "$WORK_DIR"/units/*/worker-before.tree >/dev/null 2>&1 || ls "$WORK_DIR"/units/*/done.json >/dev/null 2>&1; then
          stop_need_user UNIT_CONTRACT_IMPACT_REQUIRED "이미 워커가 진행한 피처인데 unit references 를 현재 문서에서 해석할 수 없다 — '영향 없음'으로 넘어가지 않는다(모델 호출 0회): $bad_refs. 삭제·개명된 heading 을 복구하거나 references 를 정확한 절로 고친 뒤 재실행"
        fi
        stop_need_docs IMPL_DOCS_MISSING "implementation-units.json 의 references 가 문서의 절을 정확히 가리키지 않는다: $bad_refs. references 는 'implementation.md#<heading>' / 'approach.md#<heading>' / 'design.md#<heading>'(heading 텍스트 또는 slug, 문서 안에서 유일) 형식이어야 한다 — 러너가 그 절의 본문으로 unit 별 계약 변경을 판정한다. 고친 뒤 재실행"
      fi
      set +e; bash "$SKILL_DIR/scripts/consensus-loop.sh" impl; rc=$?; set -e
      case $rc in
        0) consensus_exit0_note impl
           # 상위 계약이 정상 재합의로 다시 확정됐다 — 그 전 문서 위에서 기록된 pending gap 은 밑바탕이 달라졌으므로 재개 대상이 아니다(SUPERSEDED 로 보존).
           # 그 unit 은 변경 계약으로 다시 돈다. 옛 doc-gap-resume.json 으로 이 재합의를 건너뛰거나, 재합의 뒤 옛 gap 대기로 되돌아가지 않는다.
           if doc_gap_pending && ! doc_gap_base_consensus_valid; then
             log "impl 재합의 완료 — 이전 문서 위의 pending gap($(doc_gap_next_step), $(doc_gap_field '[.gaps[].key] | join(",")'))을 SUPERSEDED 로 남긴다"
             doc_gap_supersede "impl 재합의로 밑바탕 문서가 다시 확정됨" || env_error "doc-gap-resume.json 갱신 실패"
           fi
           STAGE=worker;;
        2) stop_need_user "$(jq -r '.status' "$WORK_DIR/state.json" | sed 's/MAX_ROUNDS_EXCEEDED/MAX_ROUNDS/')" "구현 문서 합의 중단 — ASK_USER 면 해당 이슈의 user_question·options 를, 그 외엔 state.json.review 의 쟁점을 사용자에게 보고. $(escalation_detail impl 'implementation.md/approach.md')";;
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
      # lock 기준으로 references 를 다시 확인하고(아직 시작하지 않은 unit 포함), 영향 확정이 필요한 unit 을 워커 호출 전에 정리한다 — 모델 0회
      bad_refs="$(units_unresolved_references "$UNITS_MANIFEST_LOCK" | paste -sd';' -)"
      [ -z "$bad_refs" ] || stop_need_user UNIT_CONTRACT_IMPACT_REQUIRED "unit references 를 현재 문서에서 해석할 수 없다 — '영향 없음'으로 넘어가지 않는다(모델 호출 0회): $bad_refs. 삭제·개명된 heading 을 복구하거나 references 를 정확한 절로 고친 뒤 재실행(manifest 를 고치면 impl 재합의)"
      units_contract_preflight apply
      for unit_id in $(unit_ids); do
        run_unit "$unit_id"
      done
      # 같은 실행 안에서 앞 unit 의 계약이 바뀌었을 수 있다 — 전체 review 로 넘기기 전에 모든 완료 체크포인트를 현재 계약으로 다시 본다
      require_units_contract_current review
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
        stop_need_user DOC_GAP_SCOPE_EXCEEDED "사용자 해결 체크포인트($gap_step)의 provenance 가 현재 상태와 맞지 않는다 — 수리 뒤 approach.md/decisions.md 를 다시 고침(수리 시점에 고정한 지문과 불일치), 답 줄 삭제, implementation.md/units/scope 변경, decisions.md 기존 줄 수정, 또는 밑바탕(impl consensus PASS 또는 impl 사용자 수리 USER_RESOLVED) 무효. 이미 고정된 체크포인트에는 새 승인 지문을 묵시적으로 발급하지 않는다 — 해당 변경을 수리 시점 상태로 되돌리고 재실행하거나, 새 구현 제안이면 사용자 확인 뒤 doc-gap-resume.json 을 치우고 재실행(impl 재합의). 자동 복구 없음"
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
          # 해결 범위 밖 변경(implementation.md/units/scope 변경, decisions.md 기존 줄 삭제·수정)은 gap 해결이 아니라 새 제안 — 사용자 해결 경로로 우회하지 않는다.
          # 여기부터 확정(doc_gap_accept) 전까지는 체크포인트를 바꾸지 않는다: 어느 검사에서 멈추든 WAITING_USER 그대로라 사용자가 고친 뒤 같은 체크포인트로 재실행할 수 있다.
          if doc_gap_accept_precheck; then :; else
            case $? in
              2) stop_need_user DOC_GAP_SCOPE_EXCEEDED "gap 해결 범위(approach.md 반영 + decisions.md 추가) 밖의 impl 입력이 바뀌었다(implementation.md/implementation-units.json/feature-scope.json 변경 또는 decisions.md 기존 줄 삭제·수정). 사용자 해결 경로로는 impl 재합의를 우회할 수 없다 — 의도한 새 구현 제안이면 doc-gap-resume.json 을 치우고 재실행(impl 재합의), 아니면 그 문서를 gap 발생 시점으로 되돌리고 재실행";;
              *) env_error "doc-gap-resume.json 의 밑바탕(impl consensus PASS 또는 impl 사용자 수리 USER_RESOLVED)이 유효하지 않음 — 체크포인트·consensus-impl.json·user-escalation-resume-impl.json 을 손으로 고치지 않는다";;
            esac
          fi
          # 리뷰 gap(review-gap 워커 경로): 지문을 고정하기 **전에** 완료 unit 을 후보 상태로 검사한다(doc_gap_repair_preflight — 체크포인트는 읽기만).
          # gap 해결(approach.md 반영)이 그 gap 과 연결되지 않은 unit 의 계약까지 바꿨으면 그 unit 의 완료는 유효하지 않고 review-gap 워커는 그 unit 을 다시 구현하지 않는다.
          # 먼저 고정하고 검사하면 안내대로 절을 되돌리거나 tag 를 보완해도 고정된 지문과 달라 재시도가 막힌다(feature 073) — 실패는 WAITING_USER 인 채 모델 0회로 돌려준다.
          gap_fp=""
          if [ -z "$gap_unit" ] && [ -n "$gap_review" ] && [ -f "$UNITS_MANIFEST_LOCK" ]; then
            if doc_gap_repair_preflight; then gap_fp="$DOC_GAP_PREFLIGHT_FP"; else
              case $? in
                2)
                  if [ "$DOC_GAP_PREFLIGHT_KIND" = DOC_GAP_LOCATION_UNRESOLVED ]; then
                    stop_need_user DOC_GAP_LOCATION_UNRESOLVED "이 체크포인트의 gap(현재 gap, 또는 gap 해결로 바뀐 approach.md 절에 적힌 tag 의 gap) 위치를 파일 경로로 확정할 수 없다 — 유효하지 않은 완료 unit 이 없어도 위치를 모르는 gap 의 해결은 승인하지 않는다. '무관한 unit 의 계약 변경'으로 단정하지 않고, 경로를 추정하거나 저장소를 검색하지도 않는다(모델 호출 0회, 체크포인트는 WAITING_USER 그대로 — 지문을 고정하지 않았다). $DOC_GAP_PREFLIGHT_DETAIL. ① 그 절 변경이 이 gap 의 해결이 아니면 절을 gap 발생 시점으로 되돌리고 재실행 ② 위치가 확정된 다른 gap 의 해결이면 그 gap 의 tag 를 절에 적고 재실행 — 둘 다 같은 체크포인트에서 다시 평가된다 ③ 위치를 확정할 수 없는 gap 의 해결로만 설명되는 절이거나 유효하지 않은 unit 없이 현재 gap 의 위치만 미확정이면 러너가 연결을 정할 수 없다: 사용자 확인 뒤 명시적으로 재시작(doc-gap-resume.json 을 옮기고 재실행 → impl 재합의). 자동 원복·자동 재합의 없음"
                  fi
                  stop_need_user DOC_GAP_SCOPE_EXCEEDED "DOC_GAP($(doc_gap_field '[.gaps[].key] | join(",")')) 해결 과정에서 그 gap 으로 설명되지 않는 완료 unit 의 계약 변경이 있다(모델 호출 0회, 체크포인트는 WAITING_USER 그대로 — 지문을 고정하지 않았다). $DOC_GAP_PREFLIGHT_DETAIL. 사용자 해결 예외는 ⓐ gap 의 경로가 scope 에 속한 unit 의 ⓑ approach.md 절 변경 가운데 ⓒ 그 절 본문에 gap tag($(doc_gap_field '[.gaps[] | "[" + .tag + "]"] | join(" / ")'))가 적힌 절에만 적용된다. ① 의도하지 않은 변경이면 그 절을 gap 발생 시점으로 되돌리고 재실행 ② gap 해결로 고친 절인데 표시만 빠졌으면 그 절에 해당 tag 를 적고 재실행 — 둘 다 같은 체크포인트에서 다시 평가된다(체크포인트를 치울 필요 없음) ③ gap 과 무관하게 의도한 변경이면 새 구현 제안이다: doc-gap-resume.json 을 옮기고 재실행(impl 재합의 → 그 unit 부터 변경 계약으로 다시 돈다). 자동 원복·자동 재실행 없음";;
                *) env_error "DOC_GAP 수리 사전 검사 실패(후보 상태 구성·unit 계약 진단) — 체크포인트는 바뀌지 않았다";;
              esac
            fi
          fi
          if doc_gap_accept "$gap_fp"; then :; else
            case $? in
              2) stop_need_user DOC_GAP_SCOPE_EXCEEDED "사전 검사 뒤 gap 해결 범위 밖의 impl 입력이 바뀌었다(implementation.md/implementation-units.json/feature-scope.json 변경 또는 decisions.md 기존 줄 삭제·수정·답 삭제) — 체크포인트는 WAITING_USER 그대로다. 되돌리고 재실행";;
              3) stop_need_user DOC_GAP_SCOPE_EXCEEDED "사전 검사와 확정 사이에 impl 입력(approach.md/decisions.md)이 바뀌었다 — 검사하지 않은 문서의 지문을 고정하지 않는다(체크포인트는 WAITING_USER 그대로). 편집을 마친 뒤 재실행";;
              *) env_error "doc-gap-resume.json 수리 기록 실패 — 체크포인트·consensus-impl.json·user-escalation-resume-impl.json 을 손으로 고치지 않는다";;
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
          # gap 해결(approach.md 반영)이 그 gap 과 연결되지 않은 unit 의 계약까지 바꿨으면 그 unit 의 완료는 더 이상 유효하지 않다(unit_contract_drift_covered) —
          # review-gap 워커는 그 unit 을 다시 구현하지 않으므로 워커·리뷰어를 부르기 전에 모델 0회로 멈춘다.
          # 새로 수리되는 체크포인트는 WAITING_USER 의 사전 검사를 통과해야만 여기 온다. 이 검사는 이미 WORKER_PENDING 으로 고정된 체크포인트(이 수정 이전에 고정된 것,
          # 고정 뒤 unit 산출물이 바뀐 것)를 같은 기준으로 다시 본다 — 지문은 이미 고정돼 있으므로 여기서 문서를 고치는 복구는 없다(묵시적으로 새 지문을 발급하지 않는다).
          if [ -f "$UNITS_MANIFEST_LOCK" ]; then
            gap_diag="$(doc_gap_units_diagnosis)" || env_error "완료 unit 진단 실패"
            if doc_gap_diagnosis_classify "$gap_diag"; then :; else
              [ "$?" -eq 2 ] || env_error "완료 unit 진단 분류 실패"
              stop_need_user "$DOC_GAP_PREFLIGHT_KIND" "이미 수리된(WORKER_PENDING — 지문 고정) DOC_GAP 체크포인트($(doc_gap_field '[.gaps[].key] | join(",")'))에서 gap 으로 설명되지 않는 완료 unit 이 있다(모델 호출 0회). $DOC_GAP_PREFLIGHT_DETAIL. 사용자 해결 예외는 ⓐ gap 의 경로가 scope 에 속한 unit 의 ⓑ approach.md 절 변경 가운데 ⓒ 그 절 본문에 gap tag($(doc_gap_field '[.gaps[] | "[" + .tag + "]"] | join(" / ")'))가 적힌 절에만 적용된다. 이 체크포인트의 지문은 수리 시점 문서에 고정돼 있다 — 문서를 더 고치면 고정된 지문과 달라져 provenance 불일치로 멈춘다(새 지문을 묵시적으로 발급하지 않는다). ① unit 산출물(units/<id>/)이 수리 뒤 바뀌었으면 원 상태로 되돌리고 재실행 ② 문서를 고쳐야 하면 사용자 확인 뒤 명시적으로 재시작(doc-gap-resume.json 을 옮기고 재실행 → impl 재합의 → 그 unit 부터 변경 계약으로 다시 돈다). 자동 원복·자동 재실행 없음"
            fi
          fi
          # 리뷰 DOC_GAP: review-gap 워커 1회. 재시작 안전성 — 이 gap 의 워커가 이미 끝났다고 **증명될 때만** 재호출 없이 리뷰로 간다.
          # 증명 = 체크포인트의 worker_run(DONE) 이 지금의 실행 식별자(리뷰 내용·미결정 ID·사용자 결정·계약)와 같고, 호출 전 tree == source tree,
          # 현재 tree == 기록된 after tree, 결과 파일이 기록 당시 내용의 유효한 DONE 이다. review-gap-*.tree / review-gap-result.json 만으로는 판정하지 않는다 —
          # 그 파일들은 앞 gap 의 워커가 남긴 것일 수 있고, 그 워커가 코드를 바꾸지 않았으면 tree 가 전부 같다(feature 061: Gap A 직후 Gap B 의 워커를 건너뜀).
          # source tree 가 기록과 다르면(외부 변경) fail closed, 완료 여부가 불확실하면 자동 재호출 없이 멈춘다. 모델 호출 없이 판정.
          cur_tree="$(snapshot_worktree_tree)" || env_error "작업 트리 스냅샷 실패"
          gap_identity="$(doc_gap_worker_identity)" || env_error "review-gap 워커 실행 식별자 계산 실패"
          gap_why="$(doc_gap_worker_run_verdict "$gap_identity" "$cur_tree")" && gap_verdict=0 || gap_verdict=$?
          case "$gap_verdict" in
            0) ;;
            10)
              log "review-gap 워커 결과 재사용 — 같은 실행 식별자(${gap_identity:0:12}…)의 DONE 기록·결과 파일·after tree 가 현재와 일치 — 재호출 없이 리뷰로"
              doc_gap_set_step REVIEW_PENDING "$cur_tree" || env_error "doc-gap-resume.json 갱신 실패"; STAGE=review; continue;;
            11) stop_need_user DOC_GAP_SOURCE_CHANGED "review-gap 워커 단계의 source worktree 가 기록된 tree($gap_why)와 다르다(현재 $cur_tree) — 조용히 진행하지 않는다. 그 tree 로 되돌리고 재실행하거나 doc-gap-resume.json 을 치우고 새 리뷰. 자동 원복 없음";;
            12) stop_need_user WORKER_OUTCOME_UNCERTAIN "review-gap 워커($(basename "$gap_review"))의 기존 결과를 이 gap 의 완료로 확정할 수 없다 — $gap_why. 같은 워커를 자동 재호출하지 않고 결과도 재사용하지 않는다(모델 호출 0회, 체크포인트를 손으로 고치지 않는다). 작업 트리와 $WORK_DIR/review-gap-result.json 을 확인한 뒤, 그 호출을 버리고 새 리뷰부터 다시 하려면 doc-gap-resume.json 을 치우고 재실행(impl 지문이 stale 이면 impl 재합의를 거친다). 자동 원복 없음";;
            *) env_error "review-gap 워커 실행 기록 판정 실패 (verdict $gap_verdict)";;
          esac
          # 호출 직전에 식별자와 호출 전 tree 를 체크포인트에 남긴다 — 이 뒤에 남는 결과 파일은 이 식별자의 것으로만 해석된다
          doc_gap_worker_run_start "$gap_identity" "$cur_tree" "$WORK_DIR/review-gap-result.json" || env_error "doc-gap-resume.json 갱신 실패(review-gap 워커 시작 기록)"
          write_state doc-gap RUNNING "" "review-gap worker ($(basename "$gap_review"))"
          log "=== review-gap 워커: DOC_GAP 사용자 결정 + 같은 리뷰의 FIX_CODE 를 함께 구현 ($(basename "$gap_review")) ==="
          RUN_TAG=review-gap REVIEW_FILE="$gap_review" DOC_GAP_REVIEW="$gap_review" \
            GAP_CONTEXT="$(printf '리뷰 JSON: %s\n리뷰 당시 diff: %s\n\n미결정 항목과 사용자 결정:\n%s' "$gap_review" "$(dirname "$gap_review")/diff-round-$(printf '%02d' "$(doc_gap_field '.round')").patch" "$(doc_gap_prompt_block)")" \
            run_worker worker-review-gap.md
          # run_worker 가 돌아왔다 = 모든 게이트·세션 수용을 지난 유효한 DONE 이다(UNDECIDED 는 새 체크포인트를 쓰고 거기서 멈춘다).
          # 결과 파일 해시·after tree 를 식별자와 함께 고정한 뒤에 단계를 넘긴다 — 두 기록 사이에서 죽어도 다음 실행이 위 판정으로 재사용한다.
          doc_gap_worker_run_done "$(cat "$WORK_DIR/review-gap-after.tree")" || env_error "doc-gap-resume.json 갱신 실패(review-gap 워커 완료 기록)"
          doc_gap_set_step REVIEW_PENDING "$(cat "$WORK_DIR/review-gap-after.tree")" || env_error "doc-gap-resume.json 갱신 실패"
          STAGE=review; continue;;
        REVIEW_PENDING)
          # 단계가 넘어갔다고 증명을 생략하지 않는다 — 완료 기록(worker_run DONE)·식별자·결과 파일 해시를 다시 확인하고, 리뷰가 아직 진행되지 않았으면 tree 도 본다.
          # (WORKER_PENDING 의 재사용 판정만 검사하면, 완료 기록 뒤 결과 파일·리뷰·결정이 바뀌어도 재개가 그대로 리뷰로 들어간다.) 모델 호출 없이 판정.
          cur_tree="$(snapshot_worktree_tree)" || env_error "작업 트리 스냅샷 실패"
          gap_identity="$(doc_gap_worker_identity)" || env_error "review-gap 워커 실행 식별자 계산 실패"
          gap_why="$(doc_gap_review_entry_verdict "$gap_identity" "$cur_tree")" && gap_verdict=0 || gap_verdict=$?
          case "$gap_verdict" in
            0) ;;
            11) stop_need_user DOC_GAP_SOURCE_CHANGED "review-gap 워커 완료 뒤 리뷰가 시작되기 전에 source worktree 가 기록된 after tree($gap_why)와 달라졌다(현재 $cur_tree) — 워커 결과를 그 위의 리뷰로 조용히 잇지 않는다. 그 tree 로 되돌리고 재실행하거나 doc-gap-resume.json 을 치우고 새 리뷰. 자동 원복 없음";;
            12) stop_need_user WORKER_OUTCOME_UNCERTAIN "리뷰 대기(REVIEW_PENDING) 중인 review-gap 워커($(basename "$gap_review"))의 완료를 확정할 수 없다 — $gap_why. 리뷰로 진행하지 않고 워커도 자동 재호출하지 않는다(모델 호출 0회, 체크포인트를 손으로 고치지 않는다). 작업 트리와 $WORK_DIR/review-gap-result.json 을 확인한 뒤, 그 호출을 버리고 새 리뷰부터 다시 하려면 doc-gap-resume.json 을 치우고 재실행(impl 지문이 stale 이면 impl 재합의를 거친다). 자동 원복 없음";;
            *) env_error "review-gap 워커 완료 기록 판정 실패 (verdict $gap_verdict)";;
          esac
          STAGE=review; continue;;
        *) STAGE=worker; continue;;
      esac;;

    review)
      # --new-review-attempt 는 이 실행의 첫 리뷰 루프 호출에만 전달한다(verify 실패 뒤의 재리뷰까지 새 시도로 만들지 않는다)
      set +e; FEATURE_REVIEW_NEW_ATTEMPT="$NEW_REVIEW_ATTEMPT" bash "$SKILL_DIR/scripts/impl-review-loop.sh"; rc=$?; set -e
      NEW_REVIEW_ATTEMPT=0
      case $rc in
        0)
          [ "$(doc_gap_next_step)" != REVIEW_PENDING ] || doc_gap_set_step RESOLVED || env_error "doc-gap-resume.json 갱신 실패"
          STAGE=verify;;
        2)
          # 리뷰 루프가 수정자까지 돌린 뒤 사용자에게 돌아온다(리뷰 체크포인트는 초기화됨) — tree 가 review-gap 워커의 after tree 와 달라진 것은 정상이므로 진행 사실을 남긴다
          [ "$(doc_gap_next_step)" != REVIEW_PENDING ] || doc_gap_mark_review_progressed || env_error "doc-gap-resume.json 갱신 실패"
          stop_need_user "$(jq -r '.status' "$WORK_DIR/state.json" | sed 's/MAX_ROUNDS_EXCEEDED/MAX_ROUNDS/')" "구현 리뷰 중단 — state.json.review 의 남은 이슈를 사용자에게 보고";;
        3)
          # 리뷰어 DOC_GAP: 사용자 결정. 루프가 doc-gap-resume.json(WAITING_USER, 리뷰·source tree 포함)을 남겼다 — impl 재합의 없음.
          log "리뷰어 DOC_GAP — 사용자 결정 필요:"; doc_gap_report
          stop_need_user REVIEW_DOC_GAP "리뷰어가 구현 중 미결정 solution shape 를 보고함($(jq -r '.issues' "$WORK_DIR/state.json")) — 사용자 결정이 최종이며 검증자·디자이너·impl 재합의 없이 review-gap 워커 1회(DOC_GAP 결정 + 같은 리뷰의 FIX_CODE $(jq -r '[.issues[] | select(.action=="FIX_CODE") | .id] | join(",")' "$(jq -r '.review' "$WORK_DIR/state.json")")) → 리뷰로 간다. 각 issue 의 답을 decisions.md 에 '- [USER-QUESTION][scope=impl][<tag>] <질문> → <답>' 으로 기록하고 approach.md 에 반영한 뒤 재실행(tag 는 항목에 표기된 값 그대로 — 보통 review-issue=<id>, 앞선 gap 과 id 가 겹치면 @N 이 붙는다). 항목: $(doc_gap_field '[.gaps[] | "[\(.key)] \(.question) (options: \(.options|join(" | ")); refs: \(.refs|join(", ")); impact: \(.impact); tag: \(.tag))"] | join(" ; ")')";;
        4)
          # 리뷰어 출력 계약 위반: 승인도 수정 요청도 아니다. 루프가 원본·진단·입력 지문을 reviews/invalid-review.json 에 남겼고 재실행은 리뷰어 0회다.
          [ "$(doc_gap_next_step)" != REVIEW_PENDING ] || doc_gap_mark_review_progressed || env_error "doc-gap-resume.json 갱신 실패"
          stop_need_user REVIEW_OUTPUT_INVALID "리뷰어 출력이 계약에 어긋나 수용하지 않음(attempt $(jq -r '.attempt' "$WORK_DIR/state.json") round $(jq -r '.round' "$WORK_DIR/state.json"), invocation $(jq -r '.invocation_id' "$WORK_DIR/state.json")) — $(jq -r '.why' "$WORK_DIR/state.json"). 위반: $(jq -r '[.errors[] | "[\(.rule_id)] issue=\(if .issue_id=="" then "-" else .issue_id end) field=\(.field) observed=\(.observed)"] | join(" ; ")' "$WORK_DIR/state.json"). 같은 프롬프트를 같은 세션에 재전송하지 않는다 — 그대로 재실행하면 모델 호출 0회로 같은 진단이 나온다. 복구: ① 검사기 버그였으면 고친 뒤 재실행(저장된 출력을 로컬 재검증) ② 새 리뷰가 필요하면 '--new-review-attempt' 를 붙여 재실행(새 attempt Round 1, 새 세션 — 이전 미수용 세션·resume marker 는 건드리지 않는다). 기록: $WORK_DIR/reviews/invalid-review.json, 원본: $(jq -r '.review' "$WORK_DIR/state.json")";;
        *) env_error "impl-review-loop 실패 (exit $rc)";;
      esac;;

    verify)
      require_units_contract_current verify
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
      require_units_contract_current DONE
      write_state done DONE "" "Phase 3 승인 + 전체 테스트 통과. 커밋은 사용자 지시 시에만."
      notify_feature_done || true   # DONE 기록 성공 뒤에만, 피처당 1회 — 실패해도 exit 0 그대로
      anomaly_n="$(cli_anomaly_count)"
      [ "$anomaly_n" -eq 0 ] || log "[WARN] CLI 종료코드 불일치 복구 $anomaly_n 건 — $CLI_ANOMALY_LOG (raw exit code 는 usage.jsonl 에 그대로)"
      # [Added] 완료 보고: usage_summary 의 같은 숫자로 Claude 보고 비용 + Codex 추정 비용(API 표준 요금 환산) + 추정 불가 건수를 모두 적는다.
      # reported+estimated 는 실제 청구액이 아니다. interactive 오케스트레이터 자체 비용은 usage.jsonl 범위 밖이라 섞지 않는다. (중단 경로도 같은 함수)
      report_usage_on_exit
      log "DONE"
      exit 0;;

    *) env_error "알 수 없는 stage: $STAGE";;
  esac
done
