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
# =============================================================

FEATURE_BRANCH_PREFIX="${FEATURE_BRANCH_PREFIX:-feature/}"
FEATURE_WORKTREE_PARENT="${FEATURE_WORKTREE_PARENT:-}"
FEATURE_BOOTSTRAP_VERSION=1

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
  jq -n --argjson version "$FEATURE_BOOTSTRAP_VERSION" --arg feature "$id" --arg branch "$branch" --arg worktree "$FEATURE_ROOT" \
    --arg source_root "$source_root" --arg main_root "$main_root" --arg head "$(git -C "$source_root" rev-parse HEAD)" \
    --arg tree "$FEATURE_SNAPSHOT_TREE" --arg mode "$FEATURE_WORKTREE_MODE" --arg now "$(date '+%FT%T%z')" \
    '{version:$version, feature:$feature, branch:$branch, worktree:$worktree, source_root:$source_root, main_root:$main_root,
      head:$head, snapshot_tree:(if $tree=="" then null else $tree end), mode:$mode, created_at:$now}' \
    > "$FEATURE_ROOT/$WORK_DIR/feature.json.tmp" && mv "$FEATURE_ROOT/$WORK_DIR/feature.json.tmp" "$FEATURE_ROOT/$WORK_DIR/feature.json"
}
