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
# finalize (--feature <id> --finalize, DONE 이후 사용자 승인 뒤 — 러너 대신 run-state DONE + 승인 지문을 파일로 만들어 재현):
#  12. clean 원본: 피처 변경이 원본 working tree 에 커밋 없이 반영, worktree·브랜치 제거, archive(manifest/patch/finalize.json/agent-work) 생성
#  13. finalize 재실행: worktree 재생성 없음, delta 중복 적용 없음, "already finalized"
#  14. bootstrap 당시 원본 dirty X: B = HEAD+X, 피처 Y → 원본 = X + Y (X 중복 적용 없음), untracked 신규 파일(중첩 디렉터리 포함) 전달
#  15. finalize 전 원본의 별도 변경(다른 파일) 보존 + 원본 index(staged) byte 단위 불변
#  16. 같은 파일의 떨어진 hunk 수정 → 3-way 자동 병합
#  17. 같은 hunk 충돌 → FINALIZE_CONFLICT(exit 2), 원본 내용·index·worktree·브랜치·archive 불변/보존, 충돌 목록 기록
#  18. binary 변경·신규 전달 + feature.patch 에 binary patch 보존
#  19. 실행 권한 부여/제거·symlink 보존
#  20. archive 실패 → 원본·worktree·브랜치 불변, 복구 후 재실행 성공
#  21. 원본 반영 뒤 브랜치 삭제 실패 → 반영 유지, APPLIED_CLEANUP_INCOMPLETE 기록(exit 2), 재실행은 정리만(delta 재적용 없음)
#  22. 기준선(bootstrap_tree)을 모르는 이전 metadata → 추측 없이 거부 / version 1 의 mode new snapshot_tree 는 인정
#  23. 러너 실행 중(worktree·원본) / DONE 아님 / 승인 지문 stale / worktree 안에서 실행 / --feature 없음 / worktree·기록 없음 / 검증 뒤 원본 변경 → 거부, 아무것도 바꾸지 않음
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

# =============================================================
# finalize — DONE 이후 사용자 승인 뒤 원본 무커밋 3-way 반영 + worktree/브랜치 정리
# =============================================================
mark_done() { # worktree — LLM 없이 DONE 의 파일 수준 의미를 만든다: run-state DONE + 현재 트리에 유효한 approved.fingerprint
  local wt="$1"
  (cd "$wt" && source "$CFG" && compute_approval_fingerprint > "$WORK_DIR/approved.fingerprint") || fail "mark_done: 승인 지문 계산 실패 ($wt)"
  jq -n '{version:1, stage:"done", status:"DONE", reason:null, detail:"smoke", test_retries:0, stale_count:0, updated_at:"", history:[]}' \
    > "$wt/.agent-work/run-state.json"
}
run_finalize() { # id [extra args...] → exit, 로그 $TMP/fin-<id>.log
  local id="$1"; shift
  (cd "$SRC" && bash "$RUN" --feature "$id" --finalize "$@") > "$TMP/fin-$id.log" 2>&1; echo $?
}
src_tree() { wt_tree "$SRC"; }
cached_hash() { git diff --cached --binary | shasum -a 256 | awk '{print $1}'; }
latest_record() { ls -1d "$SRC/.agent-work/archive/worktree/$1"/*/finalize.json 2>/dev/null | sort | tail -1; }
set_line() { # file line-no text
  awk -v n="$2" -v t="$3" 'NR==n{$0=t}1' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
commit_all() { git add -A && $GIT commit -qm "$1" || fail "테스트 전제: 커밋 실패 ($1)"; }

# 전제: 지금까지의 dirty 상태를 전부 커밋해 clean 원본으로 시작. finalize 사례용 파일 추가.
for i in $(seq -w 1 12); do echo "L$i"; done > src/long.txt
echo "c base" > src/c.txt
mkdir -p assets && printf '\x00\x01\x02\x03' > assets/base.bin
printf '#!/bin/sh\necho plain\n' > bin/plain.sh && chmod -x bin/plain.sh
commit_all "finalize base"
[ -z "$(git status --porcelain=v1 -uall)" ] || fail "테스트 전제: 원본이 clean 이 아님"
HEAD_F="$(git rev-parse HEAD)"

# ===== 사례 12: clean 원본 → 반영·정리·archive =====
rc="$(run_feature f1)"; [ "$rc" = 3 ] || { cat "$TMP/run-f1.log"; fail "사례12: bootstrap exit 3 기대, 실제 $rc"; }
WT_F1="$WORK/proj-feature-f1"
[ "$(jq -r .version "$WT_F1/.agent-work/feature.json")" = 2 ] || fail "사례12: feature.json version 2 가 아님"
[ "$(jq -r .bootstrap_tree "$WT_F1/.agent-work/feature.json")" = "$(jq -r .snapshot_tree "$WT_F1/.agent-work/feature.json")" ] || fail "사례12: bootstrap_tree 가 snapshot_tree 와 다름"
echo "f1 change" > "$WT_F1/src/a.txt"
mark_done "$WT_F1"
count_before="$(git rev-list --all --count)"; index_before="$(index_hash)"; stash_before="$(git stash list | wc -l | tr -d ' ')"
rc="$(run_finalize f1)"
[ "$rc" = 0 ] || { cat "$TMP/fin-f1.log"; fail "사례12: finalize exit 0 기대, 실제 $rc"; }
[ "$(cat src/a.txt)" = "f1 change" ] || fail "사례12: 피처 변경이 원본에 반영되지 않음"
[ "$(git status --porcelain=v1 -uall)" = " M src/a.txt" ] || fail "사례12: 원본 status 가 ' M src/a.txt' 하나가 아님: $(git status --porcelain=v1 -uall)"
[ "$(git rev-parse HEAD)" = "$HEAD_F" ] && [ "$(git symbolic-ref --short HEAD)" = main ] || fail "사례12: 원본 HEAD/브랜치가 바뀜"
[ "$(git rev-list --all --count)" = "$count_before" ] || fail "사례12: finalize 가 커밋을 만듦"
[ "$(index_hash)" = "$index_before" ] || fail "사례12: 원본 index 가 바뀜"
[ "$(git stash list | wc -l | tr -d ' ')" = "$stash_before" ] || fail "사례12: stash 가 생김"
[ ! -e "$WT_F1" ] || fail "사례12: worktree 가 남아 있음"
git worktree list | grep -q 'proj-feature-f1' && fail "사례12: worktree 등록이 남음"
git rev-parse --verify -q refs/heads/feature/f1 >/dev/null && fail "사례12: 피처 브랜치가 남음"
REC="$(latest_record f1)"; [ -n "$REC" ] || fail "사례12: archive 의 finalize.json 없음"
ADIR="$(dirname "$REC")"
[ -f "$ADIR/manifest.json" ] && [ -f "$ADIR/feature.patch" ] && [ -f "$ADIR/agent-work/run-state.json" ] && [ -f "$ADIR/agent-work/feature.json" ] || fail "사례12: archive 구성(manifest/patch/agent-work) 누락: $ADIR"
[ "$(jq -r .status "$REC")" = FINALIZED ] || fail "사례12: finalize.json status 가 FINALIZED 가 아님"
[ "$(jq -r .source_after_tree "$REC")" = "$(src_tree)" ] || fail "사례12: source_after_tree 가 지금 원본 tree 와 다름"
[ "$(jq -r .base_tree "$REC")" = "$(jq -r .bootstrap_tree "$ADIR/agent-work/feature.json")" ] || fail "사례12: base_tree 가 bootstrap_tree 와 다름"
[ "$(jq -r '.cleanup.worktree_removed and .cleanup.branch_deleted' "$REC")" = true ] || fail "사례12: cleanup 기록이 완료가 아님"
grep -q '^+f1 change$' "$ADIR/feature.patch" || fail "사례12: feature.patch 에 피처 delta 가 없음"
pass "사례12: clean 원본 finalize — 반영·커밋 없음·index 불변·worktree/브랜치 제거·archive 생성"

# ===== 사례 13: 재실행 =====
fp_before="$(src_fp)"
rc="$(run_finalize f1)"
[ "$rc" = 0 ] || { cat "$TMP/fin-f1.log"; fail "사례13: 재실행 exit 0 기대, 실제 $rc"; }
grep -q 'already finalized' "$TMP/fin-f1.log" || fail "사례13: already finalized 안내 없음"
grep -q 'finalize 이후 변경 없음' "$TMP/fin-f1.log" || fail "사례13: finalize 결과 일치 확인이 출력되지 않음"
[ ! -e "$WT_F1" ] || fail "사례13: 재실행이 worktree 를 만듦"
git rev-parse --verify -q refs/heads/feature/f1 >/dev/null && fail "사례13: 재실행이 브랜치를 만듦"
[ "$(src_fp)" = "$fp_before" ] && [ "$(cat src/a.txt)" = "f1 change" ] || fail "사례13: 재실행이 원본을 바꿈(delta 중복 적용?)"
[ "$(ls -1d "$SRC/.agent-work/archive/worktree/f1"/* | wc -l | tr -d ' ')" = 1 ] || fail "사례13: 재실행이 archive 를 추가로 만듦"
# 원본을 고친 뒤의 재실행은 결과 불일치를 알린다(커밋 전 확인용) — 여전히 delta 재적용은 없다
echo "edited after finalize" >> src/a.txt
rc="$(run_finalize f1)"; [ "$rc" = 0 ] && grep -q 'FINALIZE_STALE' "$TMP/fin-f1.log" || fail "사례13: finalize 이후 원본 변경이 감지되지 않음 (exit $rc)"
pass "사례13: finalize 재실행 — worktree 재생성·delta 중복 적용 없음, 이후 원본 변경은 FINALIZE_STALE 로 알림"
commit_all "f1"

# ===== 사례 14: bootstrap 당시 원본 dirty X + 피처 Y → X + Y (X 중복 없음), untracked 신규 파일 =====
echo "X untracked" > src/x.txt
echo "b X" > src/b.txt
rc="$(run_feature f2)"; [ "$rc" = 3 ] || fail "사례14: bootstrap exit 3 기대, 실제 $rc"
WT_F2="$WORK/proj-feature-f2"
[ "$(cat "$WT_F2/src/x.txt")" = "X untracked" ] || fail "사례14: 전제 — dirty X 가 worktree 에 없음"
echo "Y" > "$WT_F2/src/y.txt"
mkdir -p "$WT_F2/src/newdir" && echo "nested" > "$WT_F2/src/newdir/n.txt"
mark_done "$WT_F2"
rc="$(run_finalize f2)"; [ "$rc" = 0 ] || { cat "$TMP/fin-f2.log"; fail "사례14: finalize exit 0 기대, 실제 $rc"; }
[ "$(cat src/x.txt)" = "X untracked" ] && [ "$(cat src/b.txt)" = "b X" ] || fail "사례14: 원본의 기존 dirty X 가 훼손됨"
[ "$(cat src/y.txt)" = "Y" ] && [ "$(cat src/newdir/n.txt)" = "nested" ] || fail "사례14: 피처 신규 파일이 원본에 없음"
st="$(git status --porcelain=v1 -uall)"
[ "$(echo "$st" | wc -l | tr -d ' ')" = 4 ] || fail "사례14: 원본 status 가 4줄이 아님(X 중복/누락?): $st"
ADIR="$(dirname "$(latest_record f2)")"
grep -q 'X untracked' "$ADIR/feature.patch" && fail "사례14: 원본의 기존 dirty X 가 피처 delta 로 잡힘"
grep -q '^+Y$' "$ADIR/feature.patch" || fail "사례14: feature.patch 에 Y 가 없음"
[ ! -e "$WT_F2" ] || fail "사례14: worktree 가 남음"
pass "사례14: bootstrap 당시 dirty X 는 중복 적용되지 않고 피처 Y·untracked 신규 파일(중첩 포함)만 더해짐"
commit_all "f2"

# ===== 사례 15: finalize 전 원본의 별도 변경 보존 + index(staged) 불변 =====
rc="$(run_feature f3)"; [ "$rc" = 3 ] || fail "사례15: bootstrap exit 3 기대, 실제 $rc"
WT_F3="$WORK/proj-feature-f3"
echo "f3 a" > "$WT_F3/src/a.txt"
mark_done "$WT_F3"
echo "c source" > src/c.txt                                   # 피처와 다른 파일의 원본 변경
echo "staged content" > src/staged.txt && git add src/staged.txt
echo "b staged" > src/b.txt && git add src/b.txt && echo "b after stage" > src/b.txt   # staged ≠ working tree ≠ HEAD
cached_before="$(cached_hash)"; index_before="$(index_hash)"
rc="$(run_finalize f3)"; [ "$rc" = 0 ] || { cat "$TMP/fin-f3.log"; fail "사례15: finalize exit 0 기대, 실제 $rc"; }
[ "$(cat src/a.txt)" = "f3 a" ] || fail "사례15: 피처 변경 미반영"
[ "$(cat src/c.txt)" = "c source" ] || fail "사례15: 원본의 별도 변경이 사라짐"
[ "$(cat src/b.txt)" = "b after stage" ] && [ -f src/staged.txt ] || fail "사례15: 원본의 staged/unstaged 상태가 훼손됨"
[ "$(cached_hash)" = "$cached_before" ] || fail "사례15: git diff --cached 가 바뀜"
[ "$(index_hash)" = "$index_before" ] || fail "사례15: 원본 index 가 바뀜"
[ "$(git diff --cached --name-only | sort | paste -sd, -)" = "src/b.txt,src/staged.txt" ] || fail "사례15: staged 목록이 바뀜"
pass "사례15: 원본의 별도 변경 보존, staged 상태·index byte 불변"
commit_all "f3"

# ===== 사례 16: 같은 파일의 떨어진 hunk → 3-way 자동 병합 =====
rc="$(run_feature f4)"; [ "$rc" = 3 ] || fail "사례16: bootstrap exit 3 기대, 실제 $rc"
WT_F4="$WORK/proj-feature-f4"
set_line "$WT_F4/src/long.txt" 1 "L01-feature"
mark_done "$WT_F4"
set_line src/long.txt 12 "L12-source"
rc="$(run_finalize f4)"; [ "$rc" = 0 ] || { cat "$TMP/fin-f4.log"; fail "사례16: finalize exit 0 기대, 실제 $rc"; }
[ "$(head -1 src/long.txt)" = "L01-feature" ] && [ "$(tail -1 src/long.txt)" = "L12-source" ] && [ "$(wc -l < src/long.txt | tr -d ' ')" = 12 ] \
  || fail "사례16: 3-way 병합 결과가 틀림: $(cat src/long.txt | paste -sd, -)"
pass "사례16: 같은 파일 비충돌 변경 자동 병합"
commit_all "f4"

# ===== 사례 17: 같은 hunk 충돌 → 거부, 전부 보존 =====
rc="$(run_feature f5)"; [ "$rc" = 3 ] || fail "사례17: bootstrap exit 3 기대, 실제 $rc"
WT_F5="$WORK/proj-feature-f5"
set_line "$WT_F5/src/long.txt" 6 "L06-feature"
mark_done "$WT_F5"
set_line src/long.txt 6 "L06-source"
echo "s2" > src/staged2.txt && git add src/staged2.txt
fp_before="$(src_fp)"; index_before="$(index_hash)"; cached_before="$(cached_hash)"
branch_before="$(git rev-parse refs/heads/feature/f5)"; wt_before="$(wt_tree "$WT_F5")"
rc="$(run_finalize f5)"
[ "$rc" = 2 ] || { cat "$TMP/fin-f5.log"; fail "사례17: 충돌 exit 2 기대, 실제 $rc"; }
grep -q 'FINALIZE_CONFLICT' "$TMP/fin-f5.log" && grep -q 'src/long.txt' "$TMP/fin-f5.log" || fail "사례17: FINALIZE_CONFLICT 와 충돌 경로가 보고되지 않음"
[ "$(src_fp)" = "$fp_before" ] || fail "사례17: 충돌인데 원본 working tree 가 바뀜"
[ "$(index_hash)" = "$index_before" ] && [ "$(cached_hash)" = "$cached_before" ] || fail "사례17: 충돌인데 원본 index 가 바뀜"
[ "$(sed -n 6p src/long.txt)" = "L06-source" ] || fail "사례17: 충돌 파일이 부분 변경됨"
[ -d "$WT_F5" ] && [ "$(wt_tree "$WT_F5")" = "$wt_before" ] || fail "사례17: worktree 가 제거되거나 바뀜"
[ "$(git rev-parse refs/heads/feature/f5)" = "$branch_before" ] || fail "사례17: 피처 브랜치가 삭제되거나 바뀜"
REC="$(latest_record f5)"; [ -n "$REC" ] || fail "사례17: 충돌 archive 가 없음"
[ "$(jq -r .status "$REC")" = CONFLICT ] && [ "$(jq -r '.conflict_files[0]' "$REC")" = "src/long.txt" ] || fail "사례17: finalize.json 에 CONFLICT/충돌 목록이 없음"
[ -f "$(dirname "$REC")/feature.patch" ] || fail "사례17: 충돌 archive 에 feature.patch 없음"
pass "사례17: 충돌 → FINALIZE_CONFLICT, 원본 내용·index·worktree·브랜치 불변, archive 에 충돌 목록"
commit_all "f5 source side"

# ===== 사례 18: binary =====
rc="$(run_feature f6)"; [ "$rc" = 3 ] || fail "사례18: bootstrap exit 3 기대, 실제 $rc"
WT_F6="$WORK/proj-feature-f6"
printf '\x00\xff\x10\x00' > "$TMP/exp-base.bin" && cp "$TMP/exp-base.bin" "$WT_F6/assets/base.bin"
printf '\x89PNG\x00\x01' > "$TMP/exp-new.bin" && cp "$TMP/exp-new.bin" "$WT_F6/assets/new.bin"
mark_done "$WT_F6"
rc="$(run_finalize f6)"; [ "$rc" = 0 ] || { cat "$TMP/fin-f6.log"; fail "사례18: finalize exit 0 기대, 실제 $rc"; }
cmp -s assets/base.bin "$TMP/exp-base.bin" && cmp -s assets/new.bin "$TMP/exp-new.bin" || fail "사례18: binary 내용이 원본에 정확히 전달되지 않음"
[ "$(grep -c 'GIT binary patch' "$(dirname "$(latest_record f6)")/feature.patch")" -ge 2 ] || fail "사례18: feature.patch 에 binary patch 가 없음"
pass "사례18: binary 변경·신규 전달, archive patch 에 binary 보존"
commit_all "f6"

# ===== 사례 19: 실행 권한·symlink =====
rc="$(run_feature f7)"; [ "$rc" = 3 ] || fail "사례19: bootstrap exit 3 기대, 실제 $rc"
WT_F7="$WORK/proj-feature-f7"
chmod +x "$WT_F7/bin/plain.sh"; chmod -x "$WT_F7/bin/run.sh"; ln -s ../src/a.txt "$WT_F7/bin/link-a"
mark_done "$WT_F7"
rc="$(run_finalize f7)"; [ "$rc" = 0 ] || { cat "$TMP/fin-f7.log"; fail "사례19: finalize exit 0 기대, 실제 $rc"; }
[ -x bin/plain.sh ] && [ ! -x bin/run.sh ] || fail "사례19: 실행 권한 변경이 전달되지 않음"
[ -L bin/link-a ] && [ "$(readlink bin/link-a)" = "../src/a.txt" ] || fail "사례19: symlink 가 전달되지 않음"
pass "사례19: 실행 권한 부여/제거·symlink 보존"
commit_all "f7"

# ===== 사례 20: archive 실패 → 아무것도 바꾸지 않음 =====
rc="$(run_feature f8)"; [ "$rc" = 3 ] || fail "사례20: bootstrap exit 3 기대, 실제 $rc"
WT_F8="$WORK/proj-feature-f8"
echo "f8" > "$WT_F8/src/a.txt"
mark_done "$WT_F8"
mkdir -p .agent-work/archive && chmod 000 .agent-work/archive
fp_before="$(src_fp)"
rc="$(run_finalize f8)"
chmod 755 .agent-work/archive
[ "$rc" = 1 ] || { cat "$TMP/fin-f8.log"; fail "사례20: archive 실패 exit 1 기대, 실제 $rc"; }
grep -q 'archive' "$TMP/fin-f8.log" || fail "사례20: archive 실패 사유 없음"
[ "$(src_fp)" = "$fp_before" ] && [ "$(cat src/a.txt)" != "f8" ] || fail "사례20: archive 실패인데 원본이 바뀜"
[ -d "$WT_F8" ] && git rev-parse --verify -q refs/heads/feature/f8 >/dev/null || fail "사례20: archive 실패인데 worktree/브랜치가 제거됨"
rc="$(run_finalize f8)"; [ "$rc" = 0 ] && [ "$(cat src/a.txt)" = "f8" ] || { cat "$TMP/fin-f8.log"; fail "사례20: 복구 후 재실행 실패 (exit $rc)"; }
pass "사례20: archive 실패 → 원본·worktree·브랜치 불변, 복구 후 재실행 성공"
commit_all "f8"

# ===== 사례 21: 반영 성공 뒤 브랜치 삭제 실패 → 반영 유지, cleanup incomplete, 재실행은 정리만 =====
rc="$(run_feature f9)"; [ "$rc" = 3 ] || fail "사례21: bootstrap exit 3 기대, 실제 $rc"
WT_F9="$WORK/proj-feature-f9"
echo "f9" > "$WT_F9/src/a.txt"
mark_done "$WT_F9"
mkdir -p .git/refs/heads/feature && : > .git/refs/heads/feature/f9.lock     # ref lock → git branch -D 실패
rc="$(run_finalize f9)"
[ "$rc" = 2 ] || { rm -f .git/refs/heads/feature/f9.lock; cat "$TMP/fin-f9.log"; fail "사례21: cleanup 실패 exit 2 기대, 실제 $rc"; }
grep -q 'APPLIED_CLEANUP_INCOMPLETE' "$TMP/fin-f9.log" || fail "사례21: cleanup incomplete 가 보고되지 않음"
[ "$(cat src/a.txt)" = "f9" ] || fail "사례21: cleanup 실패로 반영이 되돌려짐"
git rev-parse --verify -q refs/heads/feature/f9 >/dev/null || fail "사례21: 브랜치 삭제가 실패해야 하는데 사라짐"
REC="$(latest_record f9)"
[ "$(jq -r .status "$REC")" = APPLIED_CLEANUP_INCOMPLETE ] && [ "$(jq -r '.cleanup.branch_deleted' "$REC")" = false ] && [ "$(jq -r '.cleanup.error' "$REC")" != null ] \
  || fail "사례21: finalize.json 에 cleanup incomplete 가 기록되지 않음"
rm -f .git/refs/heads/feature/f9.lock
fp_before="$(src_fp)"
rc="$(run_finalize f9)"; [ "$rc" = 0 ] || { cat "$TMP/fin-f9.log"; fail "사례21: 정리 재시도 exit 0 기대, 실제 $rc"; }
grep -q '정리만 재시도' "$TMP/fin-f9.log" || fail "사례21: 재실행이 정리만 재시도하지 않음"
[ "$(src_fp)" = "$fp_before" ] || fail "사례21: 정리 재시도가 원본을 바꿈(delta 중복 적용?)"
git rev-parse --verify -q refs/heads/feature/f9 >/dev/null && fail "사례21: 재시도 후에도 브랜치가 남음"
[ ! -e "$WT_F9" ] || fail "사례21: worktree 가 남음"
[ "$(jq -r .status "$REC")" = FINALIZED ] || fail "사례21: 같은 기록이 FINALIZED 로 갱신되지 않음"
pass "사례21: 브랜치 삭제 실패 → 반영 유지·APPLIED_CLEANUP_INCOMPLETE, 재실행은 정리만 완료"
commit_all "f9"

# ===== 사례 22: 기준선을 모르는 이전 metadata → 거부 =====
rc="$(run_feature f10)"; [ "$rc" = 3 ] || fail "사례22: bootstrap exit 3 기대, 실제 $rc"
WT_F10="$WORK/proj-feature-f10"
echo "f10" > "$WT_F10/src/a.txt"
mark_done "$WT_F10"
META="$WT_F10/.agent-work/feature.json"; cp "$META" "$TMP/f10-meta.json"
jq 'del(.bootstrap_tree) | .version=1 | .mode="new-from-branch" | .snapshot_tree=null' "$TMP/f10-meta.json" > "$META"
fp_before="$(src_fp)"
rc="$(run_finalize f10)"; [ "$rc" = 1 ] || { cat "$TMP/fin-f10.log"; fail "사례22: exit 1 기대, 실제 $rc"; }
grep -q 'bootstrap_tree' "$TMP/fin-f10.log" || fail "사례22: 기준선 부재 사유가 보고되지 않음"
[ "$(src_fp)" = "$fp_before" ] && [ -d "$WT_F10" ] && git rev-parse --verify -q refs/heads/feature/f10 >/dev/null || fail "사례22: 거부됐는데 원본/worktree/브랜치가 바뀜"
# version 1 이라도 mode new 의 snapshot_tree 는 materialize 가 검증한 값이라 기준선으로 인정
jq 'del(.bootstrap_tree) | .version=1' "$TMP/f10-meta.json" > "$META"
rc="$(run_finalize f10)"; [ "$rc" = 0 ] && [ "$(cat src/a.txt)" = "f10" ] || { cat "$TMP/fin-f10.log"; fail "사례22: version 1 (mode new, snapshot_tree) finalize 실패 (exit $rc)"; }
pass "사례22: 기준선 없는 이전 metadata 는 거부, version 1 의 검증된 snapshot_tree 는 인정"
commit_all "f10"

# ===== 사례 23: 거부 조건들 — 아무것도 바꾸지 않음 =====
rc="$(run_feature f11)"; [ "$rc" = 3 ] || fail "사례23: bootstrap exit 3 기대, 실제 $rc"
WT_F11="$WORK/proj-feature-f11"
echo "f11" > "$WT_F11/src/a.txt"
mark_done "$WT_F11"
fp_before="$(src_fp)"
reject() { # label log-pattern
  [ "$rc" = 1 ] || { cat "$TMP/fin-f11.log" "$TMP/fin-f12.log" 2>/dev/null; fail "사례23($1): exit 1 기대, 실제 $rc"; }
  grep -q -e "$2" "$TMP/fin-f11.log" "$TMP/fin-f12.log" 2>/dev/null || fail "사례23($1): 사유 '$2' 가 보고되지 않음"
  [ "$(src_fp)" = "$fp_before" ] || fail "사례23($1): 거부됐는데 원본이 바뀜"
  [ -d "$WT_F11" ] && git rev-parse --verify -q refs/heads/feature/f11 >/dev/null || fail "사례23($1): 거부됐는데 worktree/브랜치가 사라짐"
}
mkdir -p "$WT_F11/.agent-work/.runner.lock" && printf '%s\n' "$$" > "$WT_F11/.agent-work/.runner.lock/pid"
rc="$(run_finalize f11)"; reject "worktree 러너" '피처 worktree 에서 러너가 실행 중'
rm -rf "$WT_F11/.agent-work/.runner.lock"
mkdir -p .agent-work/.runner.lock && printf '%s\n' "$$" > .agent-work/.runner.lock/pid
rc="$(run_finalize f11)"; reject "원본 러너" '원본 working tree 에서 러너가 실행 중'
rm -rf .agent-work/.runner.lock
rc="$( (cd "$WT_F11" && bash "$RUN" --feature f11 --finalize) > "$TMP/fin-f11.log" 2>&1; echo $?)"; reject "worktree 안에서 실행" '원본 working tree'
rc="$( (cd "$SRC" && bash "$RUN" --finalize) > "$TMP/fin-f11.log" 2>&1; echo $?)"; reject "--feature 없음" '--feature <id> 와 함께'
rc="$( (cd "$SRC" && bash "$RUN" --feature f11 --finalize --new) > "$TMP/fin-f11.log" 2>&1; echo $?)"; reject "--new 조합" '함께 쓸 수 없다'
rc="$(run_feature f12)"; [ "$rc" = 3 ] || fail "사례23: f12 bootstrap 실패"
WT_F12="$WORK/proj-feature-f12"; echo "f12" > "$WT_F12/src/a.txt"
rc="$(run_finalize f12)"; reject "DONE 아님" 'DONE 이 아님'
mark_done "$WT_F12"; echo "after approval" > "$WT_F12/src/b.txt"
rc="$(run_finalize f12)"; reject "승인 지문 stale" '승인 지문이 유효하지 않음'
[ ! -e "$WORK/proj-feature-nope" ] || fail "사례23: 전제"
rc="$(run_finalize nope)"; [ "$rc" = 1 ] && grep -q 'finalize 할 것이 없다' "$TMP/fin-nope.log" && [ ! -e "$WORK/proj-feature-nope" ] \
  || fail "사례23(worktree·기록 없음): 거부되지 않거나 worktree 를 만듦 (exit $rc)"
# 검증과 반영 사이 원본 변경 → 반영하지 않음, 원본의 그 변경도 건드리지 않음
rc="$( (cd "$SRC" && FEATURE_FINALIZE_DEBUG_HOOK='echo "concurrent" >> src/c.txt' bash "$RUN" --feature f11 --finalize) > "$TMP/fin-f11.log" 2>&1; echo $?)"
[ "$rc" = 1 ] && grep -q '검증 이후 원본 working tree 가 바뀜' "$TMP/fin-f11.log" || { cat "$TMP/fin-f11.log"; fail "사례23(검증 뒤 원본 변경): exit 1 과 사유 기대, 실제 $rc"; }
[ "$(tail -1 src/c.txt)" = "concurrent" ] && [ "$(cat src/a.txt)" != "f11" ] || fail "사례23(검증 뒤 원본 변경): 반영됐거나 원본 변경이 지워짐"
[ -d "$WT_F11" ] && [ "$(jq -r .status "$(latest_record f11)")" = FAILED ] || fail "사례23(검증 뒤 원본 변경): worktree 유지·FAILED 기록 기대"
# 원인 해소 뒤 정상 finalize
rc="$(run_finalize f11)"; [ "$rc" = 0 ] && [ "$(cat src/a.txt)" = "f11" ] && [ ! -e "$WT_F11" ] || { cat "$TMP/fin-f11.log"; fail "사례23: 정상 finalize 실패 (exit $rc)"; }
pass "사례23: 러너 실행 중·DONE 아님·승인 stale·잘못된 cwd/인자·기록 없음·검증 뒤 원본 변경 → 거부, 아무것도 바꾸지 않음"

echo "[SMOKE] 전부 통과 — 임시 저장소: $TMP (필요 없으면 직접 정리)"
