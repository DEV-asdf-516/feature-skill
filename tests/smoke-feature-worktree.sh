#!/usr/bin/env bash
# =============================================================
# 스모크: 피처 전용 worktree 부트스트랩 (--feature <id>) — 실제 LLM 호출 없음 (CLI 는 true), 임시 저장소
# 파일 경로: tests/smoke-feature-worktree.sh
# 사용법: bash tests/smoke-feature-worktree.sh   (어디서든 실행 가능)
#
# 사례:
#   1. clean 상태에서 전용 worktree 생성 (branch feature/<id>, 경로 <repo>-feature-<id>, 산출물은 worktree 안에만)
#   2. dirty tracked 수정/삭제·untracked 파일이 새 worktree 에 동일하게 존재 (실행 권한·symlink 포함, unstaged 로 보임)
#   3. .agent-work 와 gitignore 된 파일은 snapshot 에서 제외
#   4. bootstrap 전후 원본 HEAD / branch / index / working tree 불변 (bootstrap 커밋·stash 없음)
#   5. 피처 A 의 수정이 피처 B 와 원본 working tree 에 보이지 않음
#   6. snapshot 도중 원본 fingerprint 가 바뀌면 bootstrap 실패 — worktree·브랜치를 만들지 않음
#   7. 같은 피처 재실행은 기존 worktree 와 .agent-work 를 재사용 (중복 생성 없음, --new 도 feature.json 보존)
#   8. 기존 수동 --worktree/--branch 방식도 그대로 동작
#   9. 원본에서 러너가 실행 중이면 bootstrap 거부 / 같은 피처 worktree 에서 러너 실행 중이면 거부
#  10. dirty submodule 은 거부, clean submodule 은 gitlink 경로를 빈 디렉터리로 두고 통과
#  11. 잘못된 식별자 거부
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-worktree-$$"
WORK="$TMP/work"
SRC="$WORK/proj"
mkdir -p "$SRC/.claude/hooks" "$SRC/.claude/skills"
TMP="$(cd "$TMP" && pwd -P)"; WORK="$TMP/work"; SRC="$WORK/proj"   # macOS /var → /private/var: 러너가 출력하는 물리 경로와 맞춘다
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

# --- 임시 저장소: 스킬 복사 + CLI/명령을 true 로 ---
cp -R "$SKILL_SRC" "$SRC/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$SRC/.claude/hooks/" 2>/dev/null || echo "core rules" > "$SRC/.claude/hooks/core_rules.md"
printf '{"hooks":{}}\n' > "$SRC/.claude/settings.json"
mkdir -p "$SRC/.codex/hooks" && printf '#!/bin/sh\nexit 0\n' > "$SRC/.codex/hooks/worker_guard.sh"
CFG="$SRC/.claude/skills/feature/config.sh"
sed -i.bak 's|^CLAUDE_BIN=.*|CLAUDE_BIN="true"|; s|^CODEX_BIN=.*|CODEX_BIN="true"|; s/^TEST_CMD="CHANGE_ME"/TEST_CMD="true"/; s/^LINT_CMD="CHANGE_ME"/LINT_CMD="true"/' "$CFG" && rm -f "$CFG.bak"
RUN="$SRC/.claude/skills/feature/scripts/feature-run.sh"
GIT="git -c user.email=smoke@test -c user.name=smoke"

cd "$SRC" || exit 1
git init -q -b main
printf '.agent-work/\n.claude/\n.codex/\nignored.log\n' > .gitignore
mkdir -p src bin && echo "a base" > src/a.txt && echo "b base" > src/b.txt && echo "del base" > src/del.txt
printf '#!/bin/sh\necho run\n' > bin/run.sh && chmod +x bin/run.sh
ln -s src/a.txt link-to-a
git add -A && $GIT commit -qm baseline
HEAD0="$(git rev-parse HEAD)"

index_hash() { git ls-files --stage -v | shasum -a 256 | awk '{print $1}'; }
src_fp() { (cd "$SRC" && source "$CFG" && compute_worktree_fingerprint); }
wt_tree() { (cd "$1" && source "$CFG" && snapshot_worktree_tree); }
run_feature() { # id [extra args...] → 러너 exit, 로그 $TMP/run-<id>.log
  local id="$1"; shift
  (cd "$SRC" && bash "$RUN" --feature "$id" "$@") > "$TMP/run-$id.log" 2>&1; echo $?
}

# ===== 사례 1: clean 상태에서 전용 worktree 생성 =====
rc="$(run_feature a)"
[ "$rc" = 3 ] || { cat "$TMP/run-a.log"; fail "사례1: exit 3(DESIGN_MISSING) 기대, 실제 $rc"; }
WT_A="$WORK/proj-feature-a"
[ -d "$WT_A" ] || fail "사례1: 결정론적 경로에 worktree 가 없음: $WT_A"
[ "$(git -C "$WT_A" symbolic-ref --short HEAD)" = "feature/a" ] || fail "사례1: worktree 브랜치가 feature/a 가 아님"
[ "$(git -C "$WT_A" rev-parse HEAD)" = "$HEAD0" ] || fail "사례1: worktree HEAD 가 원본 HEAD 와 다름"
git -C "$SRC" worktree list | grep -q "proj-feature-a" || fail "사례1: git worktree list 에 등록되지 않음"
[ "$(jq -r .reason "$WT_A/.agent-work/run-state.json")" = DESIGN_MISSING ] || fail "사례1: worktree 의 run-state 가 DESIGN_MISSING 이 아님"
[ "$(jq -r .mode "$WT_A/.agent-work/feature.json")" = new ] || fail "사례1: feature.json mode 가 new 가 아님"
[ "$(jq -r .branch "$WT_A/.agent-work/feature.json")" = feature/a ] || fail "사례1: feature.json branch 불일치"
[ -f "$WT_A/.agent-work/live.log" ] || fail "사례1: live.log 가 worktree 안에 없음"
[ ! -f "$SRC/.agent-work/run-state.json" ] && [ ! -f "$SRC/.agent-work/live.log" ] || fail "사례1: 원본 .agent-work 에 러너 산출물이 생김"
grep -q "$WT_A/.agent-work/design.md" "$TMP/run-a.log" || fail "사례1: DESIGN_MISSING 안내가 worktree 절대 경로를 가리키지 않음"
[ -f "$WT_A/.codex/hooks/worker_guard.sh" ] && [ -f "$WT_A/.claude/settings.json" ] && [ -f "$WT_A/.claude/hooks/core_rules.md" ] || fail "사례1: gitignore 된 안전 게이트 설정(.codex/.claude)이 worktree 에 복사되지 않음"
[ "$(git -C "$SRC" symbolic-ref --short HEAD)" = main ] || fail "사례1: 원본 브랜치가 바뀜"
pass "사례1: clean 상태 전용 worktree 생성 (feature/a, $WT_A, 산출물은 worktree 안에만)"

# ===== 사례 2·3·4: dirty 원본 → 새 worktree 에 동일 materialize, .agent-work·ignored 제외, 원본 불변 =====
echo "a modified" > src/a.txt
echo "b modified" > src/b.txt && git add src/b.txt          # staged 변경 — index 가 HEAD 와 다른 상태에서도 index 불변이어야 한다
rm -f src/del.txt
mkdir -p new && echo "untracked content" > new/u.txt
printf '#!/bin/sh\necho new\n' > new/tool.sh && chmod +x new/tool.sh
ln -s ../src/b.txt new/link-to-b
echo "ignored" > ignored.log
mkdir -p .agent-work && echo "junk" > .agent-work/junk.txt
head_before="$(git rev-parse HEAD)"; ref_before="$(git symbolic-ref HEAD)"
index_before="$(index_hash)"; status_before="$(git status --porcelain=v1 -uall)"; fp_before="$(src_fp)"
stash_before="$(git stash list | wc -l | tr -d ' ')"; count_before="$(git rev-list --all --count)"

rc="$(run_feature b)"
[ "$rc" = 3 ] || { cat "$TMP/run-b.log"; fail "사례2: exit 3 기대, 실제 $rc"; }
WT_B="$WORK/proj-feature-b"
[ -d "$WT_B" ] || fail "사례2: worktree 없음: $WT_B"
[ "$(cat "$WT_B/src/a.txt")" = "a modified" ] || fail "사례2: tracked 수정이 worktree 에 반영되지 않음"
[ "$(cat "$WT_B/src/b.txt")" = "b modified" ] || fail "사례2: staged 수정 내용이 worktree 에 반영되지 않음"
[ ! -e "$WT_B/src/del.txt" ] || fail "사례2: tracked 삭제가 worktree 에 반영되지 않음"
[ "$(cat "$WT_B/new/u.txt")" = "untracked content" ] || fail "사례2: untracked 파일이 worktree 에 없음"
[ -x "$WT_B/new/tool.sh" ] && [ -x "$WT_B/bin/run.sh" ] || fail "사례2: 실행 권한이 보존되지 않음"
[ -L "$WT_B/new/link-to-b" ] && [ "$(readlink "$WT_B/new/link-to-b")" = "../src/b.txt" ] || fail "사례2: untracked symlink 가 보존되지 않음"
[ -L "$WT_B/link-to-a" ] || fail "사례2: tracked symlink 가 보존되지 않음"
wt_status="$(git -C "$WT_B" status --porcelain=v1 -uall)"
echo "$wt_status" | grep -q '^ M src/a.txt$' || fail "사례2: worktree 에서 src/a.txt 가 unstaged 수정으로 보이지 않음 ($wt_status)"
echo "$wt_status" | grep -q '^ D src/del.txt$' || fail "사례2: worktree 에서 src/del.txt 가 삭제로 보이지 않음"
echo "$wt_status" | grep -q '^?? new/u.txt$' || fail "사례2: worktree 에서 new/u.txt 가 untracked 로 보이지 않음"
[ "$(git -C "$WT_B" rev-parse HEAD)" = "$head_before" ] || fail "사례2: worktree HEAD 가 원본 HEAD 와 다름 (bootstrap 커밋?)"
snap="$(jq -r .snapshot_tree "$WT_B/.agent-work/feature.json")"
[ "$(wt_tree "$WT_B")" = "$snap" ] || fail "사례2: worktree 를 다시 snapshot 한 tree 가 기록된 snapshot tree 와 다름"
pass "사례2: dirty tracked 수정/삭제·untracked·권한·symlink 가 새 worktree 에 동일 (unstaged 로 표시)"

[ ! -e "$WT_B/ignored.log" ] || fail "사례3: gitignore 된 파일이 복사됨"
[ ! -e "$WT_B/.agent-work/junk.txt" ] || fail "사례3: 원본 .agent-work 내용이 복사됨"
git ls-tree -r --name-only "$snap" | grep -q '^\.agent-work/' && fail "사례3: snapshot tree 에 .agent-work 가 들어 있음"
git ls-tree -r --name-only "$snap" | grep -q '^ignored.log$' && fail "사례3: snapshot tree 에 ignored 파일이 들어 있음"
pass "사례3: .agent-work 와 gitignore 파일은 snapshot 제외"

[ "$(git rev-parse HEAD)" = "$head_before" ] || fail "사례4: 원본 HEAD 가 바뀜"
[ "$(git symbolic-ref HEAD)" = "$ref_before" ] || fail "사례4: 원본 브랜치가 바뀜"
[ "$(index_hash)" = "$index_before" ] || fail "사례4: 원본 index 가 바뀜"
[ "$(git status --porcelain=v1 -uall)" = "$status_before" ] || fail "사례4: 원본 status 가 바뀜"
[ "$(src_fp)" = "$fp_before" ] || fail "사례4: 원본 working tree 지문이 바뀜"
[ "$(git stash list | wc -l | tr -d ' ')" = "$stash_before" ] || fail "사례4: stash 가 생김"
[ "$(git rev-list --all --count)" = "$count_before" ] || fail "사례4: bootstrap 커밋이 생김"
[ -f .agent-work/junk.txt ] && [ ! -f .agent-work/run-state.json ] || fail "사례4: 원본 .agent-work 가 변경됨"
pass "사례4: bootstrap 전후 원본 HEAD/branch/index/working tree/stash 불변"

# ===== 사례 5: 피처 A 의 수정이 B 와 원본에 보이지 않음 =====
echo "changed by feature A" > "$WT_A/src/a.txt"
echo "new in A" > "$WT_A/src/only-a.txt"
[ "$(cat "$WT_B/src/a.txt")" = "a modified" ] && [ ! -e "$WT_B/src/only-a.txt" ] || fail "사례5: A 의 변경이 B 에 보임"
[ "$(cat src/a.txt)" = "a modified" ] && [ ! -e src/only-a.txt ] || fail "사례5: A 의 변경이 원본에 보임"
[ "$(git status --porcelain=v1 -uall)" = "$status_before" ] || fail "사례5: 원본 status 가 바뀜"
echo "changed by feature B" > "$WT_B/src/b.txt"
[ "$(cat "$WT_A/src/b.txt")" = "b base" ] || fail "사례5: B 의 변경이 A 에 보임 (A 는 clean HEAD 기준)"
pass "사례5: 피처 worktree 간·원본 간 격리"

# ===== 사례 6: snapshot 도중 원본이 바뀌면 bootstrap 실패 =====
rc="$( (cd "$SRC" && FEATURE_BOOTSTRAP_DEBUG_HOOK='echo "concurrent writer" >> src/a.txt' bash "$RUN" --feature c) > "$TMP/run-c.log" 2>&1; echo $?)"
[ "$rc" = 1 ] || { cat "$TMP/run-c.log"; fail "사례6: exit 1 기대, 실제 $rc"; }
grep -q 'snapshot 도중 원본 working tree 가 바뀜' "$TMP/run-c.log" || fail "사례6: 지문 불일치 사유가 보고되지 않음"
[ ! -e "$WORK/proj-feature-c" ] || fail "사례6: 실패했는데 worktree 가 만들어짐"
git rev-parse --verify -q refs/heads/feature/c >/dev/null && fail "사례6: 실패했는데 브랜치가 만들어짐"
[ "$(tail -1 src/a.txt)" = "concurrent writer" ] || fail "사례6: 테스트 전제 — hook 이 원본을 바꾸지 못함"
pass "사례6: snapshot 도중 원본 변경 → bootstrap 실패, worktree·브랜치 없음"

# ===== 사례 7: 같은 피처 재실행 → 기존 worktree 와 .agent-work 재사용 =====
echo "keep me" > "$WT_A/.agent-work/marker.txt"
feature_json_before="$(cat "$WT_A/.agent-work/feature.json")"
rc="$(run_feature a)"
[ "$rc" = 3 ] || { cat "$TMP/run-a.log"; fail "사례7: 재실행 exit 3 기대, 실제 $rc"; }
grep -q '피처 worktree 재사용' "$TMP/run-a.log" || fail "사례7: 재사용 로그 없음"
[ "$(git -C "$SRC" worktree list | grep -c 'proj-feature-a')" = 1 ] || fail "사례7: worktree 가 중복 생성됨"
[ "$(cat "$WT_A/.agent-work/marker.txt")" = "keep me" ] || fail "사례7: 기존 .agent-work 가 유지되지 않음"
[ "$(cat "$WT_A/.agent-work/feature.json")" = "$feature_json_before" ] || fail "사례7: feature.json 이 재실행에서 바뀜"
[ "$(jq '.history|length' "$WT_A/.agent-work/run-state.json")" -ge 2 ] || fail "사례7: run-state 가 이어지지 않음"
[ "$(cat "$WT_A/src/a.txt")" = "changed by feature A" ] || fail "사례7: 재실행이 worktree 의 작업 내용을 바꿈"
# --new 로 재시작해도 feature.json 은 보존, 나머지는 archive 로
rc="$(run_feature a --new --archive-as first)"
[ "$rc" = 3 ] || fail "사례7: --new 재실행 exit 3 기대, 실제 $rc"
[ -f "$WT_A/.agent-work/feature.json" ] && [ -f "$WT_A/.agent-work/archive/first/marker.txt" ] || fail "사례7: --new 가 feature.json 을 보존하고 나머지를 archive 하지 않음"
pass "사례7: 동일 피처 재실행은 기존 worktree·.agent-work 재사용, 중복 생성 없음"

# ===== 사례 8: 기존 수동 --worktree/--branch 방식 =====
rc="$( (cd "$SRC" && bash "$RUN" --worktree "$WORK/manual-x" --branch feature/x) > "$TMP/run-x.log" 2>&1; echo $?)"
[ "$rc" = 3 ] || { cat "$TMP/run-x.log"; fail "사례8: exit 3 기대, 실제 $rc"; }
[ "$(git -C "$WORK/manual-x" symbolic-ref --short HEAD)" = "feature/x" ] || fail "사례8: 수동 worktree 브랜치 불일치"
[ -f "$WORK/manual-x/.agent-work/run-state.json" ] || fail "사례8: 수동 worktree 안에 산출물이 없음"
[ ! -f "$WORK/manual-x/.agent-work/feature.json" ] || fail "사례8: 수동 모드가 feature.json 을 만듦(부트스트랩 경로를 타면 안 됨)"
# --feature 와 --worktree/--branch 를 함께 주면 그 이름을 쓴다
rc="$( (cd "$SRC" && bash "$RUN" --feature y --worktree "$WORK/custom-y" --branch topic/y) > "$TMP/run-y.log" 2>&1; echo $?)"
[ "$rc" = 3 ] && [ "$(git -C "$WORK/custom-y" symbolic-ref --short HEAD)" = "topic/y" ] && [ -f "$WORK/custom-y/.agent-work/feature.json" ] \
  || { cat "$TMP/run-y.log"; fail "사례8: --feature + --worktree/--branch 조합 실패 (exit $rc)"; }
pass "사례8: 수동 --worktree/--branch 호환, --feature 와 조합 가능"

# ===== 사례 9: 러너 실행 중이면 거부 =====
mkdir -p .agent-work/.runner.lock && printf '%s\n' "$$" > .agent-work/.runner.lock/pid     # 이 테스트 프로세스가 '실행 중인 러너' 역할
rc="$(run_feature d)"
[ "$rc" = 1 ] || { cat "$TMP/run-d.log"; fail "사례9: exit 1 기대, 실제 $rc"; }
grep -q '러너가 실행 중' "$TMP/run-d.log" || fail "사례9: 러너 실행 중 사유가 보고되지 않음"
[ ! -e "$WORK/proj-feature-d" ] || fail "사례9: 거부됐는데 worktree 가 만들어짐"
rm -rf .agent-work/.runner.lock
# 같은 피처 worktree 에 살아 있는 락 → 부트스트랩 단계에서 거부
mkdir -p "$WT_A/.agent-work/.runner.lock" && printf '%s\n' "$$" > "$WT_A/.agent-work/.runner.lock/pid"
rc="$(run_feature a)"
[ "$rc" = 1 ] && grep -q '러너가 이미 실행 중' "$TMP/run-a.log" || fail "사례9: 같은 피처 worktree 의 러너 실행 중 재실행이 거부되지 않음 (exit $rc)"
# 부트스트랩 검사 뒤에 락이 생기는 race(확인 → 기록 사이) → 러너 진입의 원자적 claim 이 막는다: 부트스트랩을 건너뛰는 수동 --worktree 경로로 재현
rc="$( (cd "$SRC" && bash "$RUN" --worktree "$WT_A" --branch feature/a) > "$TMP/run-a-lock.log" 2>&1; echo $?)"
[ "$rc" = 1 ] && grep -q '러너가 이미 실행 중' "$TMP/run-a-lock.log" || fail "사례9: 러너 진입 시 살아 있는 락이 원자적으로 거부되지 않음 (exit $rc)"
# pid 가 아직 없는 락 = 다른 러너가 mkdir 직후 pid 를 쓰는 중 → stale 로 보고 훔치지 않는다
rm -f "$WT_A/.agent-work/.runner.lock/pid"
rc="$( (cd "$SRC" && bash "$RUN" --worktree "$WT_A" --branch feature/a) > "$TMP/run-a-init.log" 2>&1; echo $?)"
[ "$rc" = 1 ] && grep -q '실행 중이거나 시작 중' "$TMP/run-a-init.log" || fail "사례9: pid 없는(초기화 중) 락을 탈취함 (exit $rc)"
[ -d "$WT_A/.agent-work/.runner.lock" ] && [ ! -f "$WT_A/.agent-work/.runner.lock/pid" ] || fail "사례9: pid 없는 락이 옮겨지거나 덮어써짐"
# 죽은 pid 의 stale 락은 회수하고 진입
printf '%s\n' 99999999 > "$WT_A/.agent-work/.runner.lock/pid"
rc="$(run_feature a)"
[ "$rc" = 3 ] || { cat "$TMP/run-a.log"; fail "사례9: stale 락(죽은 pid)이 회수되지 않음 (exit $rc)"; }
[ ! -e "$WT_A/.agent-work/.runner.lock" ] && [ ! -e "$WT_B/.agent-work/.runner.lock" ] || fail "사례9: 정상 종료한 러너의 .runner.lock 이 남아 있음"
pass "사례9: 원본 러너 실행 중 → bootstrap 거부, 같은 트리 러너 락은 진입 시 원자 claim 으로 거부, stale 락 회수, 종료 시 정리"

# ===== 사례 9b: 프로젝트 종속 경로(규칙·conventions)는 원본이 아니라 worktree 에서 읽는다 =====
echo "CONV-ORIGINAL" > conventions.md
rc="$(run_feature h)"
[ "$rc" = 3 ] || { cat "$TMP/run-h.log"; fail "사례9b: exit 3 기대, 실제 $rc"; }
WT_H="$WORK/proj-feature-h"
grep -q "프로젝트 경로 재바인딩: $WT_H" "$TMP/run-h.log" || fail "사례9b: 러너가 PROJECT_ROOT 를 worktree 로 재바인딩하지 않음"
echo "CONV-CHANGED" > conventions.md     # 부트스트랩 뒤 원본 변경 — worktree 실행에 새어 들면 안 된다
conv="$(cd "$WT_H" && FEATURE_PROJECT_ROOT="$WT_H" bash -c 'source "$1"; load_project_conventions; echo "$CORE_RULES_FILE"' _ "$CFG")"
echo "$conv" | grep -q CONV-ORIGINAL || fail "사례9b: config.sh 가 FEATURE_PROJECT_ROOT 의 conventions.md 를 읽지 않음"
echo "$conv" | grep -q CONV-CHANGED && fail "사례9b: 원본의 이후 변경이 worktree 실행에 보임"
echo "$conv" | grep -q "^$WT_H/.claude/hooks/core_rules.md$" || fail "사례9b: CORE_RULES_FILE 이 worktree 를 가리키지 않음"
pass "사례9b: 규칙·conventions 경로가 worktree 로 재바인딩되고 하위 루프에도 상속 가능"

# ===== 사례 9c: 안전 게이트 복사 실패는 fail-closed =====
chmod 000 .codex
rc="$(run_feature g)"
chmod 755 .codex
[ "$rc" = 1 ] || { cat "$TMP/run-g.log"; fail "사례9c: 게이트 복사 실패인데 exit 1 이 아님 ($rc)"; }
grep -q '안전 게이트 설정 복사 실패' "$TMP/run-g.log" || fail "사례9c: 복사 실패 사유가 보고되지 않음"
[ ! -e "$WORK/proj-feature-g" ] || fail "사례9c: 실패했는데 worktree 가 남음"
git rev-parse --verify -q refs/heads/feature/g >/dev/null && fail "사례9c: 실패했는데 브랜치가 남음"
pass "사례9c: 안전 게이트 복사 실패 → 부트스트랩 실패, worktree·브랜치 없음"
# 기존 브랜치 + worktree 디렉터리 없음(new-from-branch) → 게이트 복사 실패 시 worktree 만 제거, 기존 브랜치는 보존
git worktree remove --force "$WT_A" || fail "사례9c: 테스트 전제 — worktree A 제거 실패"
[ ! -e "$WT_A" ] && git rev-parse --verify -q refs/heads/feature/a >/dev/null || fail "사례9c: 테스트 전제 — 브랜치 feature/a 가 없거나 디렉터리가 남음"
branch_a_head="$(git rev-parse refs/heads/feature/a)"
chmod 000 .codex
rc="$(run_feature a)"
chmod 755 .codex
[ "$rc" = 1 ] || { cat "$TMP/run-a.log"; fail "사례9c(new-from-branch): exit 1 기대, 실제 $rc"; }
[ ! -e "$WT_A" ] || fail "사례9c(new-from-branch): 실패했는데 worktree 가 남음"
git worktree list | grep -q 'proj-feature-a' && fail "사례9c(new-from-branch): worktree 등록이 남음"
[ "$(git rev-parse refs/heads/feature/a 2>/dev/null)" = "$branch_a_head" ] || fail "사례9c(new-from-branch): 기존 브랜치 feature/a 가 삭제되거나 바뀜"
rc="$(run_feature a)"
[ "$rc" = 3 ] && [ "$(jq -r .mode "$WT_A/.agent-work/feature.json")" = new-from-branch ] || fail "사례9c(new-from-branch): 복구 후 기존 브랜치로 재생성 실패 (exit $rc)"
pass "사례9c(new-from-branch): 게이트 복사 실패 시 worktree 만 제거, 기존 브랜치 보존, 재실행으로 재생성"

# ===== 사례 10: submodule — dirty 는 거부, clean 은 통과 =====
$GIT init -q "$WORK/subrepo" && (cd "$WORK/subrepo" && echo "sub file" > f.txt && git add f.txt && $GIT commit -qm sub)
git -c protocol.file.allow=always submodule add -q ../subrepo sub >/dev/null 2>&1 && $GIT commit -qm "add submodule" >/dev/null \
  || fail "사례10: 테스트 전제 — submodule 추가 실패"
echo "sub dirty" >> sub/f.txt
rc="$(run_feature e)"
[ "$rc" = 1 ] || { cat "$TMP/run-e.log"; fail "사례10: dirty submodule 인데 exit 1 이 아님 ($rc)"; }
grep -q 'dirty submodule' "$TMP/run-e.log" || fail "사례10: dirty submodule 사유가 보고되지 않음"
[ ! -e "$WORK/proj-feature-e" ] || fail "사례10: 거부됐는데 worktree 가 만들어짐"
echo "sub file" > sub/f.txt   # 원래 내용으로 (테스트가 만든 변경)
rc="$(run_feature e)"
[ "$rc" = 3 ] || { cat "$TMP/run-e.log"; fail "사례10: clean submodule 인데 exit 3 이 아님 ($rc)"; }
[ -d "$WORK/proj-feature-e/sub" ] || fail "사례10: gitlink 경로가 worktree 에 없음"
pass "사례10: dirty submodule 거부, clean submodule 통과"

# ===== 사례 11: 잘못된 식별자 =====
rc="$( (cd "$SRC" && bash "$RUN" --feature '../evil') > "$TMP/run-bad.log" 2>&1; echo $?)"
[ "$rc" = 1 ] && [ ! -e "$WORK/proj-feature-../evil" ] || fail "사례11: 잘못된 식별자가 거부되지 않음"
for bad in 'a..b' 'foo.lock' 'x.'; do   # 자체 정규식은 통과하지만 git ref 규칙에 어긋나는 이름
  rc="$( (cd "$SRC" && bash "$RUN" --feature "$bad") > "$TMP/run-bad.log" 2>&1; echo $?)"
  [ "$rc" = 1 ] && grep -q 'git ref 규칙' "$TMP/run-bad.log" && [ ! -e "$WORK/proj-feature-$bad" ] || fail "사례11: ref 부적합 식별자 '$bad' 가 거부되지 않음 (exit $rc)"
done
pass "사례11: 잘못된 식별자·ref 부적합 이름 거부"

echo "[SMOKE] 전부 통과 — 임시 저장소: $TMP (필요 없으면 직접 정리)"
