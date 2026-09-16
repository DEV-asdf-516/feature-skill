#!/usr/bin/env bash
# =============================================================
# 피처 전용 git worktree 부트스트랩 — feature-run.sh 가 source 하는 라이브러리 (단독 실행 아님)
# 파일 경로: .claude/skills/feature/scripts/feature-worktree.sh
# 전제: config.sh 가 먼저 source 돼 있어야 한다 (WORK_DIR, snapshot_worktree_tree, compute_worktree_fingerprint).
#
# 목적: 같은 프로젝트의 여러 피처를 동시에 돌려도 상태 파일·리뷰·문서·소스 변경이 섞이지 않게,
#       피처 시작 시 전용 worktree 를 먼저 확정하고 이후 모든 단계를 그 안에서만 돈다.
#
# 결정론적 이름 (--feature <id>):
#   branch   : ${FEATURE_BRANCH_PREFIX}<id>            기본 feature/<id>
#   worktree : <main root 의 부모>/<repo 이름>-feature-<id>   (FEATURE_WORKTREE_PARENT 로 부모 디렉터리 변경 가능)
#   같은 id 로 다시 실행하면 같은 경로를 찾아 그 안의 .agent-work 를 이어서 쓴다 — 중복 생성 없음.
#
# dirty working tree 지원 (bootstrap 용 커밋 없음):
#   fingerprint(원본) → snapshot_worktree_tree(원본, tree object) → fingerprint(원본) 재확인(다르면 worktree 를 만들기 전에 실패)
#   → git worktree add --no-checkout -b <branch> <path> HEAD
#   → 임시 index 로 read-tree <snapshot> + checkout-index -a  (tracked 수정·삭제·untracked 파일이 그대로 materialize)
#   → worktree 자체 index 는 read-tree HEAD (원본의 미커밋 변경이 unstaged 로 보인다)
#   → 새 worktree 에서 다시 snapshot_worktree_tree 해 같은 tree SHA 인지 자체 검증
#   원본의 branch/HEAD/index/working tree 는 읽기만 한다. stash/reset/checkout/restore 없음. .agent-work 는 snapshot 에 없다(기존 정책).
#   gitignore 된 파일은 snapshot_worktree_tree 정책 그대로 복사하지 않는다 — 단 안전 게이트 설정(.codex, .claude/settings.json,
#   .claude/hooks)은 worktree 에 없으면 원본에서 복사한다(훅이 worktree 에서도 워커·수정자에게 적용되도록).
#
# 거부 조건: 원본 .agent-work 에서 러너가 실행 중(.runner.lock/pid 생존) / dirty submodule / HEAD 없음 / 경로가 worktree 가 아니거나 브랜치 불일치
#            / 브랜치 이름이 git ref 규칙 위반 / 안전 게이트 설정 복사 실패(fail-closed).
# 같은 트리에 두 러너가 들어오는 것을 실제로 막는 것은 feature-run.sh 의 원자적 락(mkdir .agent-work/.runner.lock)이다 — 여기의 pid 검사는 조기 안내.
# 완료 후 merge·commit·rebase·worktree 삭제는 하지 않는다. 자체 검증에 실패한 '방금 만든' worktree 만 되돌린다(사용된 적 없음).
# 유일한 예외는 사용자 승인 뒤 명시적으로 호출되는 finalize(아래 "finalize" 절, feature-run.sh --feature <id> --finalize) 다.
#
# finalize (DONE 이후, 사용자 승인 뒤에만):
#   B = feature.json.bootstrap_tree (worktree 생성 시점의 tree)   F = 지금 worktree 의 snapshot   O = 지금 원본의 snapshot
#   locate(기존 worktree 만, 없으면 만들지 않음) → validate(같은 저장소·브랜치 일치·러너 없음·DONE·승인 지문·B/F/O 읽기 가능·dirty submodule 없음)
#   → merge-tree --write-tree --merge-base=B O F 로 3-way 결과 R 을 object 로만 계산(원본 index·working tree 미접촉)
#   → archive(<원본>/.agent-work/archive/worktree/<id>/<timestamp>/ : manifest.json, feature.patch(B→F, --binary), finalize.json, agent-work/)
#   → 충돌이면 FINALIZE_CONFLICT 로 중단(원본·worktree·브랜치·archive 전부 보존, 자동 해결 없음)
#   → 원본이 validate 이후 그대로인지 재확인 → 임시 index 로 read-tree O 후 read-tree -m -u O R (실제 index 미접촉, commit/stash/checkout/reset 없음)
#   → 원본을 다시 snapshot 해 R 과 같은지 검증(다르면 실패, 자동 원복 없음 — archive 의 patch/tree 로 사람이 복구)
#   → 그 뒤에만 git worktree remove + git branch -D(브랜치 = 피처 브랜치, 다른 worktree 미사용 확인). 정리 실패는 APPLIED_CLEANUP_INCOMPLETE 로 기록하고 반영은 되돌리지 않는다.
#   재실행: 같은 lifecycle(feature.json.created_at)의 FINALIZED 기록이 있으면 delta 를 다시 적용하지 않는다(already finalized / 정리만 재시도).
#   B 를 모르는 오래된 metadata 는 추측하지 않고 거부한다.
# =============================================================

FEATURE_BRANCH_PREFIX="${FEATURE_BRANCH_PREFIX:-feature/}"
FEATURE_WORKTREE_PARENT="${FEATURE_WORKTREE_PARENT:-}"
FEATURE_BOOTSTRAP_VERSION=2      # 2: bootstrap_tree(finalize 기준선 B) 추가. version 1 은 mode new 의 snapshot_tree 만 B 로 인정한다(materialize 자체 검증으로 같은 tree 가 보장된 값)
FEATURE_FINALIZE_VERSION=1

feature_id_valid() { printf '%s' "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; }
feature_branch_valid() { git check-ref-format --branch "$1" >/dev/null 2>&1; }   # a..b, foo.lock, 끝의 . 같은 ref 부적합 이름 거부

# cwd 가 속한 저장소의 main working tree (linked worktree 안에서 실행해도 같은 값)
feature_main_root() {
  local common; common="$(git rev-parse --git-common-dir)" || return 1
  (cd "$common/.." && pwd -P)
}
feature_branch_name() { printf '%s%s' "$FEATURE_BRANCH_PREFIX" "$1"; }
feature_worktree_path() { # id main-root
  local parent="$FEATURE_WORKTREE_PARENT"
  if [ -z "$parent" ]; then parent="$(dirname "$2")"
  else case "$parent" in /*) ;; *) parent="$2/$parent";; esac; fi
  printf '%s/%s-feature-%s' "$parent" "$(basename "$2")" "$1"
}

# 그 root 의 .agent-work 에서 러너(또는 그 자식 워커·수정자)가 살아 있는가 — 러너가 mkdir 로 원자적으로 잡는 .runner.lock 의 pid.
# 이 검사는 조기 안내용이고, 같은 트리에 두 러너가 들어오는 것을 실제로 막는 것은 feature-run.sh 의 claim_runner_lock 이다.
runner_active_in() { # root
  local pid_file="$1/$WORK_DIR/.runner.lock/pid" pid
  [ -f "$pid_file" ] || return 1
  IFS= read -r pid < "$pid_file"
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  [ "$pid" != "$$" ] && kill -0 "$pid" 2>/dev/null
}
# dirty submodule 목록 (cwd 기준). 출력이 있으면 부트스트랩을 거부한다 — v1 은 submodule 의 미커밋 상태를 복제하지 않는다.
dirty_submodules() {
  [ -f .gitmodules ] || return 0
  git submodule status --recursive 2>/dev/null | grep -E '^[+U]' || true
  git submodule foreach --quiet --recursive 'git status --porcelain --untracked-files=all | sed "s|^|$sm_path: |"' 2>/dev/null || true
}

# snapshot tree 를 새 worktree 의 working tree 에 materialize 하고 자체 검증한다. 실패 시 1 (호출자가 되돌린다).
feature_worktree_materialize() { # worktree-path tree
  local wt="$1" tree="$2" gitdir idx check mode type sha path
  gitdir="$(git -C "$wt" rev-parse --absolute-git-dir)" || return 1
  idx="$gitdir/feature-bootstrap.index"
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$wt" read-tree "$tree" || return 1
  (cd "$wt" && GIT_INDEX_FILE="$idx" git checkout-index -a -f) || return 1
  rm -f "$idx"
  # gitlink(submodule) 경로는 checkout-index 가 만들지 않는다 — 빈 디렉터리를 두어 '초기화되지 않은 submodule' 상태로 유지
  while read -r mode type sha path; do
    [ "$type" = commit ] && mkdir -p "$wt/$path"
  done < <(git -C "$wt" ls-tree -r "$tree")
  # worktree 자체 index = HEAD → 원본의 미커밋 변경이 unstaged 수정·삭제·untracked 로 보인다 (원본 index 는 건드리지 않는다)
  git -C "$wt" read-tree HEAD || return 1
  git -C "$wt" update-index -q --refresh >/dev/null 2>&1 || true
  mkdir -p "$wt/$WORK_DIR"
  check="$(cd "$wt" && snapshot_worktree_tree)" || return 1
  [ "$check" = "$tree" ] || { echo "[FAIL] materialize 자체 검증 실패 — 기대 tree $tree / 실제 $check" >&2; return 1; }
}

# 안전 게이트 설정이 gitignore 돼 snapshot 에 빠졌으면 원본에서 복사 (있으면 그대로 둔다). 복사 실패는 fail-closed — 게이트 없이 진행하지 않는다.
feature_worktree_copy_gates() { # source-root worktree-path
  local src="$1" wt="$2" item
  for item in .codex .claude/settings.json .claude/hooks; do
    [ -e "$src/$item" ] && [ ! -e "$wt/$item" ] || continue
    mkdir -p "$(dirname "$wt/$item")" && cp -R "$src/$item" "$wt/$item" \
      || { echo "[FAIL] 안전 게이트 설정 복사 실패: $item → $wt — 훅 없이 worktree 를 쓰지 않는다" >&2; return 1; }
    echo "[feature-run] 안전 게이트 설정 복사(gitignore 됨): $item → $wt"
  done
  [ -e "$wt/.codex" ] || echo "[WARN] $wt/.codex 없음 — codex 훅(worker_guard)이 이 worktree 에 적용되지 않는다." >&2
  return 0
}

# 결과: FEATURE_ROOT FEATURE_BRANCH FEATURE_WORKTREE_MODE(new|new-from-branch|reused) FEATURE_SNAPSHOT_TREE
feature_worktree_bootstrap() { # id [branch-override] [path-override]
  local id="$1" branch="${2:-}" path="${3:-}" source_root main_root fp_before fp_after tree created_branch=0 created_worktree=0
  # 이 호출이 만든 것만 되돌린다 — worktree 와 브랜치는 따로 센다(기존 브랜치로 만든 worktree 는 worktree 만 제거, 브랜치 보존)
  undo_created() {
    [ "$created_worktree" = 1 ] && { echo "[FAIL] 방금 만든(사용된 적 없는) worktree 를 되돌린다: $path" >&2; git -C "$source_root" worktree remove --force "$path" >/dev/null 2>&1 || true; }
    [ "$created_branch" = 1 ] && { echo "[FAIL] 방금 만든 브랜치를 되돌린다: $branch" >&2; git -C "$source_root" branch -D "$branch" >/dev/null 2>&1 || true; }
    return 0
  }
  feature_id_valid "$id" || { echo "[FAIL] --feature 식별자는 영숫자로 시작하고 [A-Za-z0-9._-] 만 허용: '$id'" >&2; return 1; }
  source_root="$(git rev-parse --show-toplevel)" || { echo "[FAIL] git 저장소 안에서 실행해야 한다" >&2; return 1; }
  main_root="$(feature_main_root)" || return 1
  [ -n "$branch" ] || branch="$(feature_branch_name "$id")"
  feature_branch_valid "$branch" || { echo "[FAIL] 피처 브랜치 이름이 git ref 규칙에 맞지 않음: '$branch' (--feature '$id')" >&2; return 1; }
  [ -n "$path" ] || path="$(feature_worktree_path "$id" "$main_root")"
  case "$path" in /*) ;; *) path="$(pwd)/$path";; esac
  FEATURE_BRANCH="$branch"; FEATURE_SNAPSHOT_TREE=""

  # ---------- 재실행: 기존 worktree 재사용 ----------
  if [ -e "$path" ]; then
    local wt_root wt_common main_common wt_branch
    wt_root="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || { echo "[FAIL] $path 가 있지만 git worktree 가 아님 — 다른 경로를 --worktree 로 지정하거나 정리 후 재실행" >&2; return 1; }
    [ "$(cd "$wt_root" && pwd -P)" = "$(cd "$path" && pwd -P)" ] || { echo "[FAIL] $path 는 worktree 루트가 아님 ($wt_root 의 하위)" >&2; return 1; }
    wt_common="$(cd "$path" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
    main_common="$(cd "$main_root" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
    [ "$wt_common" = "$main_common" ] || { echo "[FAIL] $path 는 이 저장소의 worktree 가 아님 (common dir $wt_common)" >&2; return 1; }
    [ "$(cd "$path" && pwd -P)" != "$(cd "$main_root" && pwd -P)" ] || { echo "[FAIL] 피처 worktree 경로가 main working tree 와 같음" >&2; return 1; }
    wt_branch="$(git -C "$path" symbolic-ref --short -q HEAD || true)"
    [ "$wt_branch" = "$branch" ] || { echo "[FAIL] $path 의 브랜치($wt_branch)가 피처 브랜치($branch)와 다름 — 다른 피처의 worktree 이거나 수동 변경. 정리 후 재실행" >&2; return 1; }
    ! runner_active_in "$path" || { echo "[FAIL] $path 에서 러너가 이미 실행 중(pid $(cat "$path/$WORK_DIR/.runner.lock/pid")) — 같은 피처를 동시에 두 번 돌리지 않는다" >&2; return 1; }
    [ -f "$path/$WORK_DIR/feature.json" ] || echo "[WARN] $path/$WORK_DIR/feature.json 없음 — 이 러너가 만든 worktree 가 아니지만 브랜치가 일치해 재사용" >&2
    feature_worktree_copy_gates "$source_root" "$path" || return 1
    FEATURE_ROOT="$(cd "$path" && pwd -P)"; FEATURE_WORKTREE_MODE=reused
    echo "[feature-run] 피처 worktree 재사용: $FEATURE_ROOT (branch $branch)"
    return 0
  fi

  # ---------- 신규 ----------
  git -C "$source_root" rev-parse --verify -q HEAD >/dev/null || { echo "[FAIL] HEAD 커밋 없음 — 피처 worktree 는 HEAD 기준으로 만든다" >&2; return 1; }
  ! runner_active_in "$source_root" \
    || { echo "[FAIL] 원본 working tree($source_root)에서 러너가 실행 중(pid $(cat "$source_root/$WORK_DIR/.runner.lock/pid")) — 그 실행이 바꾸는 트리를 snapshot 하지 않는다. 끝난 뒤 재실행" >&2; return 1; }
  local dirty; dirty="$(cd "$source_root" && dirty_submodules)"
  [ -z "$dirty" ] || { echo "[FAIL] dirty submodule 이 있어 부트스트랩 거부 (v1 은 submodule 상태를 복제하지 않는다). 먼저 정리:" >&2; printf '  %s\n' "$dirty" >&2; return 1; }
  mkdir -p "$(dirname "$path")" || return 1

  if git -C "$source_root" rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
    # 브랜치는 있고 worktree 디렉터리만 없음(이전에 정리됨) — 브랜치 내용 그대로 체크아웃, snapshot 없음
    git -C "$source_root" worktree add "$path" "$branch" || { echo "[FAIL] git worktree add 실패" >&2; return 1; }
    created_worktree=1
    FEATURE_WORKTREE_MODE=new-from-branch
    echo "[feature-run] 피처 worktree 생성(기존 브랜치 $branch 체크아웃, 원본 dirty 상태는 반영하지 않음): $path"
  else
    # 원본의 현재 상태를 tree object 로 찍고, 그 사이 원본이 바뀌지 않았는지 지문으로 확인한다
    mkdir -p "$source_root/$WORK_DIR" || return 1
    fp_before="$(cd "$source_root" && compute_worktree_fingerprint)" || { echo "[FAIL] 원본 지문 계산 실패" >&2; return 1; }
    tree="$(cd "$source_root" && snapshot_worktree_tree)" || { echo "[FAIL] 원본 snapshot 실패" >&2; return 1; }
    # 테스트 전용 seam: snapshot 과 지문 재확인 사이에 원본을 바꾸는 writer 를 흉내 낸다
    [ -z "${FEATURE_BOOTSTRAP_DEBUG_HOOK:-}" ] || (cd "$source_root" && eval "$FEATURE_BOOTSTRAP_DEBUG_HOOK")
    fp_after="$(cd "$source_root" && compute_worktree_fingerprint)" || { echo "[FAIL] 원본 지문 재계산 실패" >&2; return 1; }
    [ "$fp_before" = "$fp_after" ] \
      || { echo "[FAIL] snapshot 도중 원본 working tree 가 바뀜(다른 writer) — 일관되지 않은 snapshot 이라 worktree 를 만들지 않음. 원본이 조용해진 뒤 재실행" >&2; return 1; }
    git -C "$source_root" worktree add --no-checkout -b "$branch" "$path" HEAD || { echo "[FAIL] git worktree add --no-checkout 실패" >&2; return 1; }
    created_worktree=1; created_branch=1
    feature_worktree_materialize "$path" "$tree" || { echo "[FAIL] snapshot materialize 실패" >&2; undo_created; return 1; }
    FEATURE_SNAPSHOT_TREE="$tree"; FEATURE_WORKTREE_MODE=new
    echo "[feature-run] 피처 worktree 생성: $path (branch $branch, HEAD $(git -C "$source_root" rev-parse --short HEAD), snapshot tree $tree)"
  fi

  feature_worktree_copy_gates "$source_root" "$path" || { undo_created; return 1; }
  FEATURE_ROOT="$(cd "$path" && pwd -P)"
  mkdir -p "$FEATURE_ROOT/$WORK_DIR"
  # finalize 기준선 B: 이 worktree 가 처음 가진 tree. snapshot 경로는 materialize 가 검증한 snapshot tree, 기존 브랜치 체크아웃은 지금 worktree 를 찍는다.
  local bootstrap_tree="$FEATURE_SNAPSHOT_TREE"
  if [ -z "$bootstrap_tree" ]; then
    bootstrap_tree="$(cd "$FEATURE_ROOT" && snapshot_worktree_tree)" || { echo "[FAIL] 새 worktree 의 bootstrap tree 기록 실패" >&2; undo_created; return 1; }
  fi
  jq -n --argjson version "$FEATURE_BOOTSTRAP_VERSION" --arg feature "$id" --arg branch "$branch" --arg worktree "$FEATURE_ROOT" \
    --arg source_root "$(cd "$source_root" && pwd -P)" --arg main_root "$main_root" --arg head "$(git -C "$source_root" rev-parse HEAD)" \
    --arg tree "$FEATURE_SNAPSHOT_TREE" --arg bootstrap_tree "$bootstrap_tree" --arg mode "$FEATURE_WORKTREE_MODE" --arg now "$(date '+%FT%T%z')" \
    '{version:$version, feature:$feature, branch:$branch, worktree:$worktree, source_root:$source_root, main_root:$main_root,
      head:$head, snapshot_tree:(if $tree=="" then null else $tree end), bootstrap_tree:$bootstrap_tree, mode:$mode, created_at:$now}' \
    > "$FEATURE_ROOT/$WORK_DIR/feature.json.tmp" && mv "$FEATURE_ROOT/$WORK_DIR/feature.json.tmp" "$FEATURE_ROOT/$WORK_DIR/feature.json"
}

# =============================================================
# finalize — DONE 이후 사용자 승인 뒤 feature-run.sh --feature <id> --finalize 가 호출한다.
# 여기의 어떤 함수도 feature_worktree_bootstrap 을 부르지 않는다(정리된 worktree 를 다시 만드는 파괴적 재실행 방지).
# 원본에 대해 commit / stash / checkout / reset / 실제 index 변경은 하지 않는다 — 결과는 working tree 변경으로만 들어간다.
# =============================================================

feature_finalize_archive_dir() { printf '%s/%s/archive/worktree/%s' "$1" "$WORK_DIR" "$2"; }   # source-root id
# 가장 최근 finalize 기록(finalize.json) 경로. 없으면 1.
feature_finalize_latest_record() { # source-root id
  local f; f="$(ls -1d "$(feature_finalize_archive_dir "$1" "$2")"/*/finalize.json 2>/dev/null | sort | tail -1)"
  [ -n "$f" ] && printf '%s' "$f"
}
# FINALIZED 기록의 source_after_tree 와 지금 원본 tree 가 같은가 — finalize 이후 커밋 전에 오케스트레이터가 확인한다.
# (worktree 가 있는 DONE 은 verify_approved_fingerprint, worktree 를 정리한 FINALIZED 는 이 함수.) 기록이 없거나 다르면 1.
feature_finalized_source_current() { # id [source-root]
  local id="$1" src="${2:-}" rec after now
  [ -n "$src" ] || src="$(git rev-parse --show-toplevel)" || return 1
  rec="$(feature_finalize_latest_record "$src" "$id")" || { echo "[FAIL] feature $id 의 finalize 기록 없음: $(feature_finalize_archive_dir "$src" "$id")" >&2; return 1; }
  [ "$(jq -r '.status' "$rec")" = FINALIZED ] || { echo "[FAIL] 마지막 finalize 기록이 FINALIZED 가 아님($(jq -r '.status' "$rec")): $rec" >&2; return 1; }
  after="$(jq -r '.source_after_tree // empty' "$rec")"
  now="$(cd "$src" && snapshot_worktree_tree)" || return 1
  [ "$now" = "$after" ] || { echo "[FINALIZE_STALE] finalize 이후 원본 working tree 가 바뀜 (finalize 시 $after / 지금 $now) — 승인된 상태 그대로가 아니다. 변경을 확인한 뒤 결정" >&2; return 1; }
  echo "finalize 결과와 원본 일치 — finalize 이후 변경 없음 (tree $after, 기록 $rec)"
}

# 기존 worktree 를 찾기만 한다(생성 없음). 결과: FEATURE_ROOT FEATURE_BRANCH FEATURE_META FEATURE_SOURCE_ROOT FEATURE_MAIN_ROOT
# 반환 0 찾음 / 2 worktree 디렉터리 없음 / 1 있지만 이 피처의 worktree 가 아니거나 metadata 부적합
feature_worktree_locate_existing() { # id [branch-override] [path-override]
  local id="$1" branch="${2:-}" path="${3:-}" main_root wt_root wt_common main_common wt_branch
  feature_id_valid "$id" || { echo "[FAIL] --feature 식별자는 영숫자로 시작하고 [A-Za-z0-9._-] 만 허용: '$id'" >&2; return 1; }
  main_root="$(feature_main_root)" || return 1
  [ -n "$branch" ] || branch="$(feature_branch_name "$id")"
  [ -n "$path" ] || path="$(feature_worktree_path "$id" "$main_root")"
  case "$path" in /*) ;; *) path="$(pwd)/$path";; esac
  FEATURE_BRANCH="$branch"; FEATURE_MAIN_ROOT="$main_root"; FEATURE_ROOT=""; FEATURE_META=""; FEATURE_SOURCE_ROOT=""; FEATURE_WORKTREE_PATH="$path"
  [ -e "$path" ] || return 2
  wt_root="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || { echo "[FAIL] $path 가 있지만 git worktree 가 아님" >&2; return 1; }
  [ "$(cd "$wt_root" && pwd -P)" = "$(cd "$path" && pwd -P)" ] || { echo "[FAIL] $path 는 worktree 루트가 아님 ($wt_root 의 하위)" >&2; return 1; }
  wt_common="$(cd "$path" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  main_common="$(cd "$main_root" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  [ "$wt_common" = "$main_common" ] || { echo "[FAIL] $path 는 이 저장소의 worktree 가 아님 (common dir $wt_common)" >&2; return 1; }
  [ "$(cd "$path" && pwd -P)" != "$(cd "$main_root" && pwd -P)" ] || { echo "[FAIL] 피처 worktree 경로가 main working tree 와 같음" >&2; return 1; }
  wt_branch="$(git -C "$path" symbolic-ref --short -q HEAD || true)"
  [ "$wt_branch" = "$branch" ] || { echo "[FAIL] $path 의 브랜치($wt_branch)가 피처 브랜치($branch)와 다름 — 다른 피처의 worktree 이거나 수동 변경" >&2; return 1; }
  FEATURE_ROOT="$(cd "$path" && pwd -P)"
  FEATURE_META="$FEATURE_ROOT/$WORK_DIR/feature.json"
  [ -f "$FEATURE_META" ] && jq -e . "$FEATURE_META" >/dev/null 2>&1 \
    || { echo "[FAIL] $FEATURE_META 없음/손상 — 이 러너가 만든 worktree 가 아니라 finalize 기준선(B)을 알 수 없다. finalize 하지 않는다" >&2; return 1; }
  [ "$(jq -r '.feature // empty' "$FEATURE_META")" = "$id" ] || { echo "[FAIL] feature.json 의 feature($(jq -r .feature "$FEATURE_META"))가 --feature $id 와 다름" >&2; return 1; }
  [ "$(jq -r '.branch // empty' "$FEATURE_META")" = "$branch" ] || { echo "[FAIL] feature.json 의 branch($(jq -r .branch "$FEATURE_META"))가 $branch 와 다름" >&2; return 1; }
  FEATURE_SOURCE_ROOT="$(jq -r '.source_root // empty' "$FEATURE_META")"
  [ -n "$FEATURE_SOURCE_ROOT" ] || { echo "[FAIL] feature.json 에 source_root 없음 — 반영 대상 working tree 를 알 수 없다" >&2; return 1; }
  return 0
}

# finalize 전 검증. 원본·worktree 를 바꾸지 않는다. 결과: FINALIZE_BASE_TREE(B) FINALIZE_FEATURE_TREE(F) FINALIZE_SOURCE_TREE(O)
feature_worktree_validate_finalize() {
  local src="$FEATURE_SOURCE_ROOT" wt="$FEATURE_ROOT" src_common wt_common dirty status
  [ -d "$src" ] || { echo "[FAIL] 원본 working tree 없음: $src" >&2; return 1; }
  src_common="$(cd "$src" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P)" || { echo "[FAIL] 원본 $src 가 git working tree 가 아님" >&2; return 1; }
  wt_common="$(cd "$wt" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  [ "$src_common" = "$wt_common" ] || { echo "[FAIL] 원본($src)과 피처 worktree($wt)가 같은 저장소가 아님" >&2; return 1; }
  [ "$(cd "$(git -C "$src" rev-parse --show-toplevel)" && pwd -P)" = "$(cd "$src" && pwd -P)" ] || { echo "[FAIL] $src 가 working tree 루트가 아님" >&2; return 1; }
  [ "$(cd "$(git rev-parse --show-toplevel)" && pwd -P)" = "$(cd "$src" && pwd -P)" ] \
    || { echo "[FAIL] --finalize 는 피처를 시작한 원본 working tree($src)에서 실행해야 한다 (지금: $(git rev-parse --show-toplevel))" >&2; return 1; }
  git -C "$src" worktree list --porcelain | grep -qx "worktree $wt" || { echo "[FAIL] $wt 가 git worktree list 에 등록되지 않음" >&2; return 1; }
  ! runner_active_in "$wt" || { echo "[FAIL] 피처 worktree 에서 러너가 실행 중(pid $(cat "$wt/$WORK_DIR/.runner.lock/pid")) — 끝난 뒤 finalize" >&2; return 1; }
  ! runner_active_in "$src" || { echo "[FAIL] 원본 working tree 에서 러너가 실행 중(pid $(cat "$src/$WORK_DIR/.runner.lock/pid")) — 그 실행이 바꾸는 트리에 반영하지 않는다" >&2; return 1; }
  [ -f "$wt/$WORK_DIR/run-state.json" ] || { echo "[FAIL] $wt/$WORK_DIR/run-state.json 없음 — DONE 이 아니면 finalize 하지 않는다" >&2; return 1; }
  status="$(jq -r '.status // empty' "$wt/$WORK_DIR/run-state.json")"
  [ "$status" = DONE ] || { echo "[FAIL] run-state 가 DONE 이 아님(status ${status:-없음}, stage $(jq -r '.stage' "$wt/$WORK_DIR/run-state.json")) — finalize 는 DONE 이후에만" >&2; return 1; }
  (cd "$wt" && verify_approved_fingerprint >/dev/null) \
    || { echo "[FAIL] 승인 지문이 유효하지 않음 — DONE 이후 worktree 가 바뀌었다. 같은 --feature 로 러너를 재실행해 재리뷰·verify 를 거친 뒤 finalize" >&2; return 1; }
  FINALIZE_BASE_TREE="$(jq -r 'if (.bootstrap_tree // "") != "" then .bootstrap_tree elif .mode == "new" and (.snapshot_tree // "") != "" then .snapshot_tree else "" end' "$FEATURE_META")"
  [ -n "$FINALIZE_BASE_TREE" ] \
    || { echo "[FAIL] feature.json(version $(jq -r .version "$FEATURE_META"), mode $(jq -r .mode "$FEATURE_META"))에 finalize 기준선(bootstrap_tree)이 없다 — 이 worktree 가 처음 가진 tree 를 추측하지 않는다. 결과는 사람이 직접 옮긴다(worktree·브랜치 유지)" >&2; return 1; }
  git -C "$src" cat-file -e "$FINALIZE_BASE_TREE^{tree}" 2>/dev/null || { echo "[FAIL] 기준선 tree 를 읽을 수 없음: $FINALIZE_BASE_TREE (gc 등으로 유실)" >&2; return 1; }
  dirty="$(cd "$src" && dirty_submodules)"
  [ -z "$dirty" ] || { echo "[FAIL] 원본에 dirty submodule 이 있어 finalize 거부 (snapshot 정책이 submodule 상태를 표현하지 않는다):" >&2; printf '  %s\n' "$dirty" >&2; return 1; }
  dirty="$(cd "$wt" && dirty_submodules)"
  [ -z "$dirty" ] || { echo "[FAIL] 피처 worktree 에 dirty submodule 이 있어 finalize 거부:" >&2; printf '  %s\n' "$dirty" >&2; return 1; }
  FINALIZE_FEATURE_TREE="$(cd "$wt" && snapshot_worktree_tree)" || { echo "[FAIL] 피처 worktree snapshot 실패" >&2; return 1; }
  mkdir -p "$src/$WORK_DIR" || return 1
  FINALIZE_SOURCE_TREE="$(cd "$src" && snapshot_worktree_tree)" || { echo "[FAIL] 원본 snapshot 실패" >&2; return 1; }
  return 0
}

# B/O/F 3-way 결과를 object 로만 계산한다(원본 index·working tree 미접촉). 0: FINALIZE_MERGE_TREE / 2: 충돌(FINALIZE_CONFLICT_FILES, 줄 단위) / 1: 오류
feature_finalize_compute_merge() {
  local out rc=0
  FINALIZE_MERGE_TREE=""; FINALIZE_CONFLICT_FILES=""
  out="$(git -C "$FEATURE_SOURCE_ROOT" merge-tree --write-tree --name-only --merge-base="$FINALIZE_BASE_TREE" "$FINALIZE_SOURCE_TREE" "$FINALIZE_FEATURE_TREE")" || rc=$?
  case "$rc" in
    0) FINALIZE_MERGE_TREE="$out"; return 0;;
    1) FINALIZE_MERGE_TREE="$(printf '%s\n' "$out" | head -1)"
       FINALIZE_CONFLICT_FILES="$(printf '%s\n' "$out" | awk 'NR==1{next} /^$/{exit} {print}')"
       return 2;;
    *) echo "[FAIL] git merge-tree 실패 (exit $rc) — git 2.38 이상이 필요하다" >&2; return 1;;
  esac
}

# finalize.json 갱신: status + updated_at + 선택 jq 갱신식
feature_finalize_record() { # status [jq-expr]
  jq --arg status "$1" --arg now "$(date '+%FT%T%z')" ".status=\$status | .updated_at=\$now | ${2:-.}" "$FINALIZE_RECORD" > "$FINALIZE_RECORD.tmp" \
    && mv "$FINALIZE_RECORD.tmp" "$FINALIZE_RECORD" || { echo "[FAIL] finalize.json 기록 실패: $FINALIZE_RECORD" >&2; return 1; }
}

# archive: 원본 반영·worktree 삭제보다 먼저. 실패하면 finalize 중단(원본·worktree 불변). 결과: FINALIZE_ARCHIVE_DIR FINALIZE_RECORD
feature_finalize_archive() {
  local id src="$FEATURE_SOURCE_ROOT" dir stamp conflicts_json
  id="$(jq -r .feature "$FEATURE_META")"
  stamp="$(date '+%Y%m%d-%H%M%S')"; dir="$(feature_finalize_archive_dir "$src" "$id")/$stamp"
  [ ! -e "$dir" ] || dir="$dir-$$"
  mkdir -p "$dir" || { echo "[FAIL] archive 디렉터리 생성 실패: $dir" >&2; return 1; }
  conflicts_json="$(printf '%s' "${FINALIZE_CONFLICT_FILES:-}" | jq -R -s 'split("\n") | map(select(length > 0))')"
  jq --arg base "$FINALIZE_BASE_TREE" --arg feat "$FINALIZE_FEATURE_TREE" --arg src_tree "$FINALIZE_SOURCE_TREE" --arg merge "${FINALIZE_MERGE_TREE:-}" \
     --argjson conflicts "$conflicts_json" --arg now "$(date '+%FT%T%z')" \
     '. + {archived_at:$now, base_tree:$base, feature_tree:$feat, source_before_tree:$src_tree, merge_tree:(if $merge=="" then null else $merge end), conflict_files:$conflicts}' \
     "$FEATURE_META" > "$dir/manifest.json" || { echo "[FAIL] manifest.json 기록 실패" >&2; return 1; }
  # 피처 delta B→F. binary 포함, rename 감지 없음(적용·복구가 경로 단위로 단순하도록)
  git -C "$src" diff-tree -r -p --binary --no-renames "$FINALIZE_BASE_TREE" "$FINALIZE_FEATURE_TREE" > "$dir/feature.patch" \
    || { echo "[FAIL] feature.patch 기록 실패" >&2; return 1; }
  cp -R "$FEATURE_ROOT/$WORK_DIR" "$dir/agent-work" || { echo "[FAIL] worktree .agent-work 보존 실패" >&2; return 1; }
  FINALIZE_ARCHIVE_DIR="$dir"; FINALIZE_RECORD="$dir/finalize.json"
  jq -n --argjson version "$FEATURE_FINALIZE_VERSION" --arg feature "$id" --arg branch "$FEATURE_BRANCH" --arg worktree "$FEATURE_ROOT" \
     --arg source_root "$src" --arg main_root "$FEATURE_MAIN_ROOT" --arg head "$(git -C "$src" rev-parse HEAD 2>/dev/null || true)" \
     --arg created "$(jq -r '.created_at // empty' "$FEATURE_META")" \
     --arg base "$FINALIZE_BASE_TREE" --arg feat "$FINALIZE_FEATURE_TREE" --arg src_tree "$FINALIZE_SOURCE_TREE" --arg merge "${FINALIZE_MERGE_TREE:-}" \
     --argjson conflicts "$conflicts_json" --arg now "$(date '+%FT%T%z')" \
     '{version:$version, feature:$feature, branch:$branch, worktree:$worktree, source_root:$source_root, main_root:$main_root, head:$head,
       bootstrap_created_at:$created, base_tree:$base, feature_tree:$feat, source_before_tree:$src_tree,
       merge_tree:(if $merge=="" then null else $merge end), source_after_tree:null, conflict_files:$conflicts,
       status:"PENDING", cleanup:{worktree_removed:false, branch_deleted:false, error:null}, finalized_at:null, updated_at:$now}' \
     > "$FINALIZE_RECORD.tmp" && mv "$FINALIZE_RECORD.tmp" "$FINALIZE_RECORD" || { echo "[FAIL] finalize.json 생성 실패" >&2; return 1; }
  echo "[finalize] archive: $dir (manifest.json, feature.patch, finalize.json, agent-work/)"
}

# merge 결과 R 을 원본 working tree 에 materialize. 임시 index 에 O 를 읽고 O→R 두 tree merge 로 working tree 만 갱신한다 —
# 실제 index 는 읽지도 쓰지도 않는다. unpack-trees 는 쓰기 전에 모든 경로를 검사하므로 거부되면 아무것도 바뀌지 않는다.
feature_finalize_materialize_source() { # O R
  local src="$FEATURE_SOURCE_ROOT" idx gitdir rc=0
  gitdir="$(git -C "$src" rev-parse --absolute-git-dir)" || return 1
  idx="$gitdir/feature-finalize.index.$$"
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$src" read-tree "$1" \
    && GIT_INDEX_FILE="$idx" git -C "$src" update-index -q --refresh >/dev/null \
    && GIT_INDEX_FILE="$idx" git -C "$src" read-tree -m -u "$1" "$2" || rc=1
  rm -f "$idx"
  return "$rc"
}

# 원본 반영·검증·archive 기록이 끝난 뒤에만. 실패해도 반영은 되돌리지 않는다. 결과: FINALIZE_CLEANUP_ERROR
feature_finalize_cleanup() {
  local src="$FEATURE_SOURCE_ROOT" wt="$FEATURE_ROOT" branch="$FEATURE_BRANCH"
  FINALIZE_CLEANUP_ERROR=""
  if [ -e "$wt" ]; then
    if git -C "$src" worktree list --porcelain | grep -qx "worktree $wt"; then
      git -C "$src" worktree remove --force "$wt" || { FINALIZE_CLEANUP_ERROR="git worktree remove 실패: $wt"; return 1; }
    else
      FINALIZE_CLEANUP_ERROR="$wt 가 git worktree list 에 없어 제거하지 않음"; return 1
    fi
  fi
  feature_finalize_record "$(jq -r .status "$FINALIZE_RECORD")" '.cleanup.worktree_removed=true' || return 1
  if git -C "$src" rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
    if git -C "$src" worktree list --porcelain | grep -qx "branch refs/heads/$branch"; then
      FINALIZE_CLEANUP_ERROR="브랜치 $branch 가 다른 worktree 에서 체크아웃돼 있어 삭제하지 않음"; return 1
    fi
    # worktree 는 이미 제거됐을 수 있으므로 feature.json 이 아니라 archive 의 finalize.json(같은 값이 기록됨)과 대조한다
    [ "$branch" = "$(jq -r .branch "$FINALIZE_RECORD")" ] || { FINALIZE_CLEANUP_ERROR="삭제 대상 브랜치($branch)가 finalize 기록의 브랜치와 다름"; return 1; }
    git -C "$src" branch -D "$branch" >/dev/null || { FINALIZE_CLEANUP_ERROR="git branch -D $branch 실패"; return 1; }
  fi
  feature_finalize_record "$(jq -r .status "$FINALIZE_RECORD")" '.cleanup.branch_deleted=true' || return 1
}

# 전체 흐름. 반환 0 FINALIZED / already finalized, 2 FINALIZE_CONFLICT 또는 APPLIED_CLEANUP_INCOMPLETE(사용자 확인 필요), 1 거부·오류(원본·worktree 불변)
feature_worktree_finalize() { # id [branch-override] [path-override]
  local id="$1" rc=0 rec="" rec_status="" rec_created="" src now_tree after_tree
  if feature_worktree_locate_existing "$id" "${2:-}" "${3:-}"; then :; else rc=$?; fi
  src="$(git rev-parse --show-toplevel)" || return 1
  # ---------- worktree 없음: 성공 기록이 있으면 already finalized, 없으면 거부(새 worktree 를 만들지 않는다) ----------
  if [ "$rc" = 2 ]; then
    rec="$(feature_finalize_latest_record "$src" "$id")" \
      || { echo "[FAIL] 피처 worktree 가 없고($FEATURE_WORKTREE_PATH) finalize 기록도 없다($(feature_finalize_archive_dir "$src" "$id")) — finalize 할 것이 없다. 새 worktree 를 만들지 않는다" >&2; return 1; }
    rec_status="$(jq -r .status "$rec")"
    case "$rec_status" in
      FINALIZED)
        echo "[finalize] already finalized — feature $id ($(jq -r .finalized_at "$rec"), 기록 $rec). delta 를 다시 적용하지 않는다"
        if feature_finalized_source_current "$id" "$src"; then :; else echo "[finalize] 위 사유로 finalize 결과와 지금 원본이 다르다 — 커밋 전 확인" >&2; fi
        return 0;;
      APPLIED|APPLIED_CLEANUP_INCOMPLETE)
        # 반영은 끝났고 worktree 도 없다 — 남은 브랜치 정리만 재시도
        FINALIZE_RECORD="$rec"; FEATURE_SOURCE_ROOT="$(jq -r .source_root "$rec")"; FEATURE_ROOT="$(jq -r .worktree "$rec")"; FEATURE_META="$rec"
        echo "[finalize] 이전 finalize 가 반영 후 정리 단계에서 멈춤($rec_status) — 정리만 재시도 (delta 재적용 없음)"
        if feature_finalize_cleanup; then
          feature_finalize_record FINALIZED ".finalized_at=\$now | .cleanup.error=null" || return 1
          echo "[finalize] FINALIZED — 정리 완료 (feature $id)"; return 0
        fi
        feature_finalize_record APPLIED_CLEANUP_INCOMPLETE ".cleanup.error=$(printf '%s' "$FINALIZE_CLEANUP_ERROR" | jq -R .)" || return 1
        echo "[FAIL] APPLIED_CLEANUP_INCOMPLETE — $FINALIZE_CLEANUP_ERROR. 원본 반영은 유지된다. 원인 해소 후 같은 명령으로 정리만 재시도" >&2; return 2;;
      *)
        echo "[FAIL] 피처 worktree 가 없고($FEATURE_WORKTREE_PATH) 마지막 finalize 기록은 $rec_status 다($rec) — 반영된 적이 없는데 worktree 가 사라졌다. 새 worktree 를 만들지 않는다. archive 의 feature.patch 로 사람이 복구" >&2; return 1;;
    esac
  fi
  [ "$rc" = 0 ] || return 1
  # ---------- 같은 lifecycle 의 이전 기록 ----------
  if rec="$(feature_finalize_latest_record "$src" "$id")"; then
    rec_status="$(jq -r .status "$rec")"; rec_created="$(jq -r '.bootstrap_created_at // empty' "$rec")"
    if [ -n "$rec_created" ] && [ "$rec_created" = "$(jq -r '.created_at // empty' "$FEATURE_META")" ]; then
      case "$rec_status" in
        FINALIZED)
          echo "[FAIL] feature $id 는 이미 finalize 됐는데($(jq -r .finalized_at "$rec")) 같은 worktree 가 다시 존재한다($FEATURE_ROOT) — 중복 적용 방지를 위해 아무것도 하지 않는다. 기록: $rec" >&2; return 1;;
        APPLIED|APPLIED_CLEANUP_INCOMPLETE)
          FINALIZE_RECORD="$rec"
          now_tree="$(cd "$FEATURE_ROOT" && snapshot_worktree_tree)" || return 1
          [ "$now_tree" = "$(jq -r .feature_tree "$rec")" ] \
            || { echo "[FAIL] 이전 finalize($rec_status)가 반영한 worktree tree($(jq -r .feature_tree "$rec"))와 지금 worktree($now_tree)가 다르다 — 반영 뒤 worktree 가 바뀌었으므로 정리하지 않는다. 사람이 확인" >&2; return 1; }
          echo "[finalize] 이전 finalize 가 반영 후 정리 단계에서 멈춤($rec_status) — 정리만 재시도 (delta 재적용 없음)"
          if feature_finalize_cleanup; then
            feature_finalize_record FINALIZED ".finalized_at=\$now | .cleanup.error=null" || return 1
            echo "[finalize] FINALIZED — 정리 완료 (feature $id)"; return 0
          fi
          feature_finalize_record APPLIED_CLEANUP_INCOMPLETE ".cleanup.error=$(printf '%s' "$FINALIZE_CLEANUP_ERROR" | jq -R .)" || return 1
          echo "[FAIL] APPLIED_CLEANUP_INCOMPLETE — $FINALIZE_CLEANUP_ERROR. 원본 반영은 유지된다" >&2; return 2;;
      esac
    fi
  fi
  # ---------- validate → merge 계산 → archive → 충돌 판정 → 반영 → 검증 → 정리 ----------
  feature_worktree_validate_finalize || return 1
  echo "[finalize] B(bootstrap) $FINALIZE_BASE_TREE / O(원본 지금) $FINALIZE_SOURCE_TREE / F(worktree 지금) $FINALIZE_FEATURE_TREE"
  if feature_finalize_compute_merge; then rc=0; else rc=$?; fi
  [ "$rc" != 1 ] || return 1
  feature_finalize_archive || { echo "[FAIL] archive 실패 — 원본·worktree 를 바꾸지 않고 중단" >&2; return 1; }
  if [ "$rc" = 2 ]; then
    feature_finalize_record CONFLICT || return 1
    echo "[FINALIZE_CONFLICT] B/O/F 3-way merge 충돌 — 자동 해결하지 않는다. 원본·index·worktree·브랜치·archive 모두 그대로. 충돌 경로:" >&2
    printf '%s\n' "$FINALIZE_CONFLICT_FILES" | sed 's/^/  /' >&2
    echo "  기록: $FINALIZE_RECORD (conflict_files). 사용자가 원본 또는 worktree 에서 충돌을 해소한 뒤(worktree 를 바꿨으면 러너 재실행으로 재승인) 같은 명령으로 재시도" >&2
    return 2
  fi
  if [ "$FINALIZE_MERGE_TREE" = "$FINALIZE_SOURCE_TREE" ]; then
    echo "[finalize] 원본에 반영할 변경 없음 (merge 결과 = 원본 tree)"
  fi
  # 테스트 전용 seam: 검증과 반영 사이에 원본을 바꾸는 writer 를 흉내 낸다
  [ -z "${FEATURE_FINALIZE_DEBUG_HOOK:-}" ] || (cd "$FEATURE_SOURCE_ROOT" && eval "$FEATURE_FINALIZE_DEBUG_HOOK")
  # 반영 직전 재확인: validate 이후 원본이 바뀌었으면 O 가 기준이 아니다 — 아무것도 쓰지 않고 중단
  now_tree="$(cd "$FEATURE_SOURCE_ROOT" && snapshot_worktree_tree)" || return 1
  [ "$now_tree" = "$FINALIZE_SOURCE_TREE" ] \
    || { feature_finalize_record FAILED ".cleanup.error=\"원본이 검증 이후 바뀜 ($now_tree)\"" ; echo "[FAIL] 검증 이후 원본 working tree 가 바뀜(다른 writer, $now_tree) — 반영하지 않음. 원본이 조용해진 뒤 재실행" >&2; return 1; }
  if ! feature_finalize_materialize_source "$FINALIZE_SOURCE_TREE" "$FINALIZE_MERGE_TREE"; then
    after_tree="$(cd "$FEATURE_SOURCE_ROOT" && snapshot_worktree_tree || echo '?')"
    feature_finalize_record FAILED ".source_after_tree=\"$after_tree\" | .cleanup.error=\"materialize 실패\"" || true
    if [ "$after_tree" = "$FINALIZE_SOURCE_TREE" ]; then
      echo "[FAIL] 원본 materialize 거부됨 — 원본은 바뀌지 않았다(tree $after_tree). worktree·브랜치 유지. 기록: $FINALIZE_RECORD" >&2
    else
      echo "[FAIL] 원본 materialize 가 도중에 실패 — 원본 tree 가 $FINALIZE_SOURCE_TREE 에서 $after_tree 로 바뀌었다. 자동 원복하지 않는다. archive 의 manifest.json(source_before_tree)·feature.patch 로 사람이 복구: $FINALIZE_ARCHIVE_DIR" >&2
    fi
    return 1
  fi
  after_tree="$(cd "$FEATURE_SOURCE_ROOT" && snapshot_worktree_tree)" || return 1
  if [ "$after_tree" != "$FINALIZE_MERGE_TREE" ]; then
    feature_finalize_record FAILED ".source_after_tree=\"$after_tree\" | .cleanup.error=\"적용 결과가 기대 merge tree 와 다름\"" || true
    echo "[FAIL] 적용 결과 검증 실패 — 기대 merge tree $FINALIZE_MERGE_TREE / 실제 원본 tree $after_tree. 자동 원복하지 않는다(사용자 변경을 추측해 지우지 않는다). worktree·브랜치·archive 유지: $FINALIZE_ARCHIVE_DIR" >&2
    return 1
  fi
  feature_finalize_record APPLIED ".source_after_tree=\"$after_tree\"" || return 1
  echo "[finalize] 원본 반영 완료 (커밋 없음, index 불변) — 원본 tree $after_tree"
  if feature_finalize_cleanup; then
    feature_finalize_record FINALIZED ".finalized_at=\$now" || return 1
    echo "[finalize] FINALIZED — feature $id: worktree $FEATURE_ROOT 제거, 브랜치 $FEATURE_BRANCH 삭제. 원본에는 커밋되지 않은 working tree 변경으로 남아 있다. 기록: $FINALIZE_RECORD"
    return 0
  fi
  feature_finalize_record APPLIED_CLEANUP_INCOMPLETE ".cleanup.error=$(printf '%s' "$FINALIZE_CLEANUP_ERROR" | jq -R .)" || return 1
  echo "[FAIL] APPLIED_CLEANUP_INCOMPLETE — 원본 반영은 성공했고 되돌리지 않는다. 정리 실패: $FINALIZE_CLEANUP_ERROR. 원인 해소 후 같은 명령으로 정리만 재시도(delta 재적용 없음). 기록: $FINALIZE_RECORD" >&2
  return 2
}
