#!/usr/bin/env bash
# =============================================================
# 스모크: codex PreToolUse 훅 .codex/hooks/worker_guard.sh 의 차단 판정 (실제 LLM·codex 호출 없음 — 훅 입력 JSON 을 직접 넣는다)
# 파일 경로: tests/smoke-worker-guard.sh
# 사용법: bash tests/smoke-worker-guard.sh
#
# 불변식:
#   - 검사하지 못한 호출(빈 입력·JSON 아님·tool_input 없음·jq 없음)은 허용되지 않는다(exit 2).
#   - git 전역 옵션을 끼운 커밋·푸시·index 조작도 막힌다.
#   - 삭제는 명령 단위다: 허용 경로를 지우는 명령이 같은 호출에 있어도 다른 삭제는 통과하지 못한다.
#   - apply_patch 의 `*** Delete File:` 은 삭제다.
#   - 삭제 대상은 글자 그대로 읽을 수 있는 경로여야 한다: 허용 접두사 뒤의 변수·치환·글로브·중괄호 확장은 막힌다.
#   - 프로젝트 안의 이동(mv · apply_patch 의 Move to)은 통과다. 프로젝트 밖으로 옮기는 것은 원래 경로의 삭제다. git mv 는 index 조작이다.
#     허용 경로 안의 심볼릭 링크를 거쳐 가는 대상도 막힌다.
#   - .codex/(가드·훅 정의)를 대상으로 한 apply_patch 는 막힌다(셸 명령의 읽기는 막지 않는다).
#   - 금지 대상이 아닌 호출(읽기·작업 트리 전용 restore·허용 경로 삭제·본문에 금지 단어가 든 patch)은 막지 않는다.
# 이 스모크가 보는 것은 스크립트의 판정뿐이다. codex 가 실제 turn 에서 이 훅을 부르는지, 훅 입력의 실제 모양은 여기서 확인하지 않는다.
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$PROJECT_SRC/.codex/hooks/worker_guard.sh"
ROOT="/work/repo"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }
command -v jq >/dev/null 2>&1 || fail "jq 가 없다"
[ -f "$GUARD" ] || fail "가드 없음: $GUARD"

shell_input() { jq -nc --arg cwd "$ROOT" --arg c "$1" '{cwd:$cwd, tool_name:"shell", tool_input:{command:["bash","-lc",$c]}}'; }
string_input() { jq -nc --arg cwd "$ROOT" --arg c "$1" '{cwd:$cwd, tool_name:"shell", tool_input:{command:$c}}'; }
patch_input() { jq -nc --arg cwd "$ROOT" --arg p "$1" '{cwd:$cwd, tool_name:"apply_patch", tool_input:{input:$p}}'; }
verdict() { bash "$GUARD" 2>/dev/null; echo $?; }   # stdin 의 훅 입력 → 종료 코드
blocked() { # 사례 명령
  [ "$(shell_input "$2" | verdict)" = 2 ] || fail "$1: 차단돼야 하는데 통과(argv 형태): $2"
  [ "$(string_input "$2" | verdict)" = 2 ] || fail "$1: 차단돼야 하는데 통과(문자열 형태): $2"
}
allowed() { # 사례 명령
  [ "$(shell_input "$2" | verdict)" = 0 ] || fail "$1: 허용돼야 하는데 차단(argv 형태): $2"
  [ "$(string_input "$2" | verdict)" = 0 ] || fail "$1: 허용돼야 하는데 차단(문자열 형태): $2"
}

# ===== W1: 검사하지 못한 호출은 허용하지 않는다 =====
[ "$(printf '' | verdict)" = 2 ] || fail "W1: 빈 입력이 통과"
[ "$(printf 'this is not json' | verdict)" = 2 ] || fail "W1: JSON 이 아닌 입력이 통과"
[ "$(printf '["rm","-rf","src"]' | verdict)" = 2 ] || fail "W1: 객체가 아닌 입력이 통과"
[ "$(printf '{"cwd":"/x"}' | verdict)" = 2 ] || fail "W1: tool_input 없는 입력이 통과"
[ "$(printf '{"tool_input":null}' | verdict)" = 2 ] || fail "W1: tool_input null 이 통과"
[ "$(printf '{"tool_input":{"command":"git commit -m x"}' | verdict)" = 2 ] || fail "W1: 끊긴 JSON 이 통과"
# jq 가 PATH 에 없으면 검사 자체가 불가능하다
NOJQ="$(mktemp -d "${TMPDIR:-/tmp}/feature-smoke-guard-XXXXXX")" || fail "임시 디렉터리 생성 실패"
for tool in bash cat awk grep tr; do ln -s "$(command -v "$tool")" "$NOJQ/$tool" 2>/dev/null; done
[ "$(shell_input 'ls' | PATH="$NOJQ" bash "$GUARD" 2>/dev/null; echo $?)" = 2 ] || fail "W1: jq 가 없는데 통과"
[ "$(printf '{"tool_input":{}}' | verdict)" = 0 ] || fail "W1: 문자열 인자가 없는 호출이 차단됨"
pass "W1: 빈 입력·JSON 아님·객체 아님·tool_input 없음·끊긴 JSON·jq 없음 → 차단"

# ===== W2: 커밋·푸시 — 전역 옵션을 끼워도 막힌다 =====
blocked W2 'git commit -m x'
blocked W2 'git -C . commit -m x'
blocked W2 'git -C "sub dir" commit -m x'
blocked W2 'git -c user.name=x -c user.email=y commit -m x'
blocked W2 'git --git-dir .git --work-tree . commit -m x'
blocked W2 'git --no-pager -C . push origin main'
blocked W2 '/usr/bin/git commit -m x'
blocked W2 'cd src && git   commit --amend'
blocked W2 'git commit-tree abc -m x'
blocked W2 'git update-ref refs/heads/main abc'
blocked W2 "$(printf 'git \\\n  -C . \\\n  commit -m x')"
allowed W2 'git log --oneline -5'
allowed W2 'git -C . status --short'
allowed W2 'git diff HEAD -- src/a.txt'
allowed W2 'git show HEAD:src/a.txt'
allowed W2 'echo "see the commit message"'
pass "W2: git commit/push 는 -C · -c · --git-dir · 절대 경로 · 줄 이어 쓰기와 함께 써도 차단, 읽기 명령은 통과"

# ===== W3: index 조작 =====
blocked W3 'git add -A'
blocked W3 'git -C . add src/a.txt'
blocked W3 'git reset --hard HEAD'
blocked W3 'git stash'
blocked W3 'git restore --staged src/a.txt'
blocked W3 'git -C . restore -S src/a.txt'
blocked W3 'git update-index --assume-unchanged src/a.txt'
allowed W3 'git restore --source=abc123 --worktree -- src/a.txt'
allowed W3 'git stash-list-helper'
pass "W3: git add/reset/stash/restore --staged/update-index 차단, 작업 트리 전용 restore 는 통과"

# ===== W4: 삭제 — 명령 단위, 모든 대상이 허용 경로일 때만 =====
blocked W4 'rm -rf src/legacy'
blocked W4 'rm -rf .agent-work/tmp && rm -rf src/legacy'
blocked W4 'rm -rf src/legacy; rm -rf .agent-work/tmp'
blocked W4 'rm -rf .agent-work/tmp src/legacy'
blocked W4 'rm -f /tmp/x; unlink src/a.txt'
blocked W4 'rm -rf .agent-work/../src'
blocked W4 'rm -rf "$TARGET"'
blocked W4 'sudo rm -rf src'
blocked W4 'env X=1 /bin/rm -f src/a.txt'
blocked W4 'ls src | xargs rm -f'
blocked W4 'find src -name "*.bak" -delete'
blocked W4 'find src -name "*.bak" -exec rm {} +'
blocked W4 'git rm old_module.py'
blocked W4 'git -C . rm -r src'
blocked W4 'git clean -fdx'
blocked W4 'rmdir src/empty'
# 감싸는 명령·인자 자리에 있어도 삭제 명령 이름이면 삭제로 본다(감싸는 명령 목록으로 가려내지 않는다)
blocked W4 'timeout 5 rm -rf src'
blocked W4 'sudo -u root rm -rf src'
blocked W4 'nice -n 5 rm -rf src'
blocked W4 'ls src | xargs -n 1 rm -f'
blocked W4 'eval "rm -rf src"'
blocked W4 'bash -c "rm -rf src"'
blocked W4 'watch -n 1 rm -f src/a.txt'
blocked W4 'grep -n "rm -rf" README.md'
blocked W4 "$(printf 'echo start\nrm -rf src/legacy\necho done')"
allowed W4 'rm -rf .agent-work/tmp'
allowed W4 'rm -f ./.agent-work/a.log .agent-work/b.log /tmp/feature-x/c.log'
allowed W4 "rm -rf $ROOT/.agent-work/tmp"
allowed W4 'rm -f .agent-work/x.log 2>/dev/null; echo ok'
allowed W4 'rm -rf /private/tmp/feature-x && ls'
allowed W4 'echo removed'
allowed W4 'cat docs/firmware.md'
pass "W4: 삭제는 명령마다 모든 대상이 .agent-work·/tmp 하위일 때만 통과 — 허용 삭제에 끼워 넣은 다른 삭제·경로 거슬러 오르기·변수 대상·xargs·find·git rm/clean·감싸는 명령 뒤의 삭제 차단(삭제 명령 이름을 인자로 넘기는 읽기 명령도 막힌다)"

# ===== W5: apply_patch =====
[ "$(patch_input "$(printf '*** Begin Patch\n*** Delete File: src/a.txt\n*** End Patch')" | verdict)" = 2 ] || fail "W5: apply_patch 의 Delete File 이 통과"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Update File: src/b.txt\n@@\n-x\n+y\n*** Delete File: src/a.txt\n*** End Patch')" | verdict)" = 2 ] || fail "W5: 다른 변경에 섞인 Delete File 이 통과"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Delete File: .agent-work/../src/a.txt\n*** End Patch')" | verdict)" = 2 ] || fail "W5: 경로 거슬러 오르기 Delete File 이 통과"
[ "$(shell_input "$(printf "apply_patch <<'EOF'\n*** Begin Patch\n*** Delete File: src/a.txt\n*** End Patch\nEOF")" | verdict)" = 2 ] || fail "W5: 셸로 부른 apply_patch 의 Delete File 이 통과"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Delete File: .agent-work/tmp/a.txt\n*** End Patch')" | verdict)" = 0 ] || fail "W5: 허용 경로의 Delete File 이 차단됨"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Update File: docs/guide.md\n@@\n-run git commit -m x\n+run git add -A then rm -rf build\n*** End Patch')" | verdict)" = 0 ] || fail "W5: 본문에 금지 단어가 든 patch(파일 내용)가 차단됨"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Add File: src/new.txt\n+hello\n*** End Patch')" | verdict)" = 0 ] || fail "W5: 파일 추가 patch 가 차단됨"
pass "W5: apply_patch 의 Delete File 차단(셸로 부른 경우 포함), 허용 경로·파일 내용에 든 금지 단어는 통과"

# ===== W6: 삭제 대상은 글자 그대로 읽을 수 있는 경로여야 한다 — 허용 접두사 뒤의 변수·치환·글로브·중괄호 확장은 차단 =====
blocked W6 'TARGET=../src; rm -rf .agent-work/$TARGET'
blocked W6 'rm -rf ".agent-work/$TARGET"'
blocked W6 'rm -rf .agent-work/${TARGET}'
blocked W6 'rm -rf .agent-work/x$(echo /../../src)'
blocked W6 'rm -rf .agent-work/x`echo /../../src`'
blocked W6 'rm -rf .agent-work/a{,/../../src}'
blocked W6 'rm -rf .agent-work/*'
blocked W6 'rm -rf .agent-work/tm?'
blocked W6 'rm -rf .agent-work/[a-z]'
blocked W6 'rm -rf /tmp/$X'
blocked W6 'rm -rf .agent-work/a\ ../src'
blocked W6 'rm -rf ~/.agent-work/x'
blocked W6 '(rm -rf src)'
blocked W6 'x=$(rm -rf src)'
blocked W6 '{ rm -rf src; }'
allowed W6 '{ rm -rf .agent-work/tmp; }'
allowed W6 'rm -rf .agent-work/run-01/logs/a.b_c-d.log'
pass "W6: 허용 접두사 뒤의 변수·명령 치환·백틱·중괄호 확장·글로브·역슬래시·~ 는 차단, 괄호·치환 안의 삭제 명령도 인식"

# ===== W7: 프로젝트 안의 이동은 허용, 프로젝트 밖으로 옮기는 것은 원래 경로의 삭제다 — mv · apply_patch 의 Move to =====
# 프로젝트 안(목적지가 글자 그대로 읽히는 상대 경로 또는 작업 루트 아래의 절대 경로)
allowed W7 'mv src/a.txt src/b.txt'
allowed W7 'mv src/a.txt src/b.txt src/sub/'
allowed W7 'mv -t src/sub src/a.txt src/b.txt'
allowed W7 'mv --target-directory=src/sub src/a.txt'
allowed W7 "mv src/a.txt $ROOT/src/b.txt"
allowed W7 'mv "src/a.txt" "src/b.txt" && ls src'
allowed W7 'mv src/*.txt src/sub/'
allowed W7 'mv -f -- src/a.txt ./src/b.txt'
# 통과하는 이동의 원본·옵션 자리에 다른 명령을 숨길 수 없다
blocked W7 'mv $(rm -rf src) dst'
blocked W7 'mv `rm -rf src` dst'
blocked W7 'mv -$(rm${IFS}-rf${IFS}src) src/a.txt src/b.txt'
blocked W7 'mv src/$X src/b.txt'
blocked W7 'mv src/{a,b}.txt src/sub/'
blocked W7 'mv .agent-work/$X src/a.txt'
# 삭제 허용 경로로 옮기는 것은 두 단계 삭제의 앞 절반이다 — 프로젝트 안 이동으로 치지 않는다
blocked W7 'mv -f src/a.txt .agent-work/a.txt'
blocked W7 'mv src/a.txt .agent-work/a.txt && rm .agent-work/a.txt'
blocked W7 'mv src/a.txt .agent-work'
blocked W7 'mv src/a.txt ./.agent-work/'
blocked W7 "mv src/a.txt $ROOT/.agent-work/a.txt"
blocked W7 'mv -t .agent-work/trash src/a.txt'
allowed W7 'mv .agent-work/out.tmp src/generated.txt'
allowed W7 'mv /tmp/feature-x/a.txt .agent-work/a.txt'
# 프로젝트 밖 · 읽을 수 없는 목적지 — 원본이 허용 경로일 때만 통과
blocked W7 'mv src /tmp/gone'
blocked W7 'mv .agent-work/a.txt src/a.txt /tmp/out/'
blocked W7 'mv -t /tmp/out src/a.txt'
blocked W7 'mv --target-directory /tmp/out src/a.txt'
blocked W7 'mv src/a.txt ../outside.txt'
blocked W7 'mv src/a.txt /work/other/a.txt'
blocked W7 'mv src/a.txt ~/a.txt'
blocked W7 'mv src/a.txt "$DEST"'
blocked W7 'mv src/a.txt src/$NAME'
blocked W7 'mv src/* /tmp/out/'
blocked W7 'mv src'
blocked W7 'mv -t src/sub'
allowed W7 'mv .agent-work/a.txt /tmp/feature-x/a.txt'
# git mv 는 index 를 바꾼다 — 프로젝트 안이어도 막힌다
blocked W7 'git mv src/a.txt src/b.txt'
blocked W7 'git -C . mv src/a.txt src/b.txt'
# .codex/ 는 원본으로도 목적지로도 옮길 수 없다
blocked W7 'mv .codex/hooks/worker_guard.sh src/guard.bak'
blocked W7 'mv src/fake.sh .codex/hooks/worker_guard.sh'
blocked W7 'mv .codex .codex.off'
blocked W7 'mv -t .codex/hooks src/fake.sh'
[ "$(patch_input "$(printf '*** Begin Patch\n*** Update File: src/a.txt\n*** Move to: /tmp/x/a.txt\n@@\n-x\n+y\n*** End Patch')" | verdict)" = 2 ] || fail "W7: apply_patch 의 Move to(프로젝트 파일을 밖으로)가 통과"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Update File: src/a.txt\n*** Move to: src/b.txt\n@@\n-x\n+y\n*** End Patch')" | verdict)" = 0 ] || fail "W7: apply_patch 의 Move to(프로젝트 안 이름 바꾸기)가 차단됨"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Update File: src/a.txt\n*** Move to: ../outside/a.txt\n@@\n-x\n+y\n*** End Patch')" | verdict)" = 2 ] || fail "W7: apply_patch 의 Move to(.. 로 프로젝트 밖)가 통과"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Update File: src/a.txt\n*** Move to: .agent-work/a.txt\n@@\n-x\n+y\n*** End Patch')" | verdict)" = 2 ] || fail "W7: apply_patch 의 Move to(삭제 허용 경로로 — 두 단계 삭제)가 통과"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Update File: src/a.txt\n*** Move to: %s/.agent-work/a.txt\n@@\n-x\n+y\n*** End Patch' "$ROOT")" | verdict)" = 2 ] || fail "W7: apply_patch 의 Move to(절대 경로의 삭제 허용 경로로)가 통과"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Update File: src/a.txt\n*** Move to: %s/src/b.txt\n@@\n-x\n+y\n*** End Patch' "$ROOT")" | verdict)" = 0 ] || fail "W7: apply_patch 의 Move to(작업 루트 아래 절대 경로)가 차단됨"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Move to: src/b.txt\n*** End Patch')" | verdict)" = 2 ] || fail "W7: 원본을 알 수 없는 Move to 가 통과"
[ "$(shell_input "$(printf "apply_patch <<'EOF'\n*** Begin Patch\n*** Update File: src/a.txt\n*** Move to: /tmp/x/b.txt\n*** End Patch\nEOF")" | verdict)" = 2 ] || fail "W7: 셸로 부른 apply_patch 의 Move to(프로젝트 밖)가 통과"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Update File: .agent-work/a.txt\n*** Move to: src/a.txt\n@@\n-x\n+y\n*** End Patch')" | verdict)" = 0 ] || fail "W7: 허용 경로에서 나오는 Move to 가 차단됨"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Update File: src/a.txt\n@@\n-x\n+y\n*** Add File: src/c.txt\n+z\n*** End Patch')" | verdict)" = 0 ] || fail "W7: 이동 없는 수정·추가 patch 가 차단됨"
pass "W7: 프로젝트 안의 mv · Move to 는 통과(원본에 숨긴 치환은 차단), 프로젝트 밖·삭제 허용 경로·읽을 수 없는 목적지는 원본이 허용 경로일 때만 통과, git mv(index)와 .codex/ 를 옮기는 mv 는 차단"

# ===== W8: 가드·훅 정의(.codex/)를 가리키는 호출은 차단(인계철선) =====
[ "$(patch_input "$(printf '*** Begin Patch\n*** Update File: .codex/hooks/worker_guard.sh\n@@\n-block() {\n+exit 0\n*** End Patch')" | verdict)" = 2 ] || fail "W8: 가드 스크립트를 고치는 patch 가 통과"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Update File: %s/.codex/hooks.json\n@@\n-x\n+y\n*** End Patch' "$ROOT")" | verdict)" = 2 ] || fail "W8: 절대 경로로 훅 정의를 고치는 patch 가 통과"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Add File: .codex/hooks/extra.sh\n+exit 0\n*** End Patch')" | verdict)" = 2 ] || fail "W8: .codex/ 아래에 파일을 추가하는 patch 가 통과"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Update File: .agent-work/a.txt\n*** Move to: .codex/hooks/worker_guard.sh\n@@\n-x\n+y\n*** End Patch')" | verdict)" = 2 ] || fail "W8: 가드 위로 옮기는 patch 가 통과"
[ "$(patch_input "$(printf '*** Begin Patch\n*** Update File: src/my.codex.d/a.txt\n@@\n-x\n+y\n*** End Patch')" | verdict)" = 0 ] || fail "W8: 이름만 비슷한 경로의 patch 가 차단됨"
# 셸 명령의 .codex/ 언급은 막지 않는다 — 이 훅은 읽기 전용 역할의 호출에도 걸린다(쓰기 차단은 sandbox 의 몫이다)
allowed W8 'cat .codex/hooks.json'
allowed W8 'grep -n block .codex/hooks/worker_guard.sh'
pass "W8: .codex/ 를 대상으로 한 patch(수정·추가·삭제 대신 이동 포함)는 차단, 이름만 비슷한 경로와 .codex/ 읽기 명령은 통과"

# ===== W9: 허용 경로 안의 심볼릭 링크를 거쳐 가는 삭제(검사 시점에 있는 링크) =====
SYM="$NOJQ/sym"; mkdir -p "$SYM/.agent-work/real" "$SYM/src" && ln -s ../src "$SYM/.agent-work/link" || fail "W9: 픽스처 생성 실패"
sym_verdict() { jq -nc --arg cwd "$SYM" --arg c "$1" '{cwd:$cwd, tool_name:"shell", tool_input:{command:["bash","-lc",$c]}}' | verdict; }
[ "$(sym_verdict 'rm -rf .agent-work/link/sub')" = 2 ] || fail "W9: 링크를 거쳐 가는 삭제가 통과"
[ "$(sym_verdict 'rm -rf .agent-work/link/')" = 2 ] || fail "W9: 링크 끝에 / 를 붙인 삭제가 통과"
[ "$(sym_verdict "rm -rf $SYM/.agent-work/link/sub")" = 2 ] || fail "W9: 절대 경로로 링크를 거쳐 가는 삭제가 통과"
[ "$(sym_verdict 'mv .agent-work/link/sub /tmp/feature-x-out')" = 2 ] || fail "W9: 링크를 거쳐 가는 이동이 통과"
[ "$(jq -nc --arg cwd "$SYM" --arg p "$(printf '*** Begin Patch\n*** Delete File: .agent-work/link/a.txt\n*** End Patch')" '{cwd:$cwd, tool_name:"apply_patch", tool_input:{input:$p}}' | verdict)" = 2 ] || fail "W9: 링크를 거쳐 가는 Delete File 이 통과"
[ "$(sym_verdict 'rm -f .agent-work/link')" = 0 ] || fail "W9: 링크 자신을 지우는 삭제가 차단됨"
[ "$(sym_verdict 'rm -rf .agent-work/real/sub')" = 0 ] || fail "W9: 링크가 없는 허용 경로 삭제가 차단됨"
pass "W9: 허용 경로 안의 심볼릭 링크를 거쳐 가는 삭제·이동·Delete File 차단, 링크 자신의 삭제는 통과"

echo "[SMOKE DONE] worker_guard 차단 판정 스모크 통과"
