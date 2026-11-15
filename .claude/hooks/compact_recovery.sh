#!/bin/bash
# SessionStart(matcher: compact) 훅: 컨텍스트 압축 직후 interactive 오케스트레이터에 최소 복구 지침을 넣는다.
# 이 이벤트에서 exit 0 + stdout 출력은 Claude 의 컨텍스트에 그대로 주입된다.
#
# 왜 필요한가:
#  - inject_conventions.sh(UserPromptSubmit)는 세션당 한 번만 conventions.md 를 넣는다. 압축 뒤에도 세션 마커가 남아 다시 넣지 않으므로,
#    압축으로 규칙 본문이 요약·소실되면 복구 경로가 없다. 그 "세션당 1회" 정책은 그대로 두고, 압축 직후 1회만 이 훅이 복구 경로를 준다.
#  - 압축 뒤 Claude Code 는 호출된 스킬의 앞부분만 다시 붙인다. 상세 절차는 references/ 에 있으므로 디스크에서 다시 읽게 한다.
#
# 무엇을 넣는가 (짧은 지침과 경로만 — 본문은 넣지 않는다):
#  - 항상: 스킬 진입 문서·참조 문서를 디스크에서 다시 읽으라는 지침(경로 포함).
#  - conventions.md: **본문을 싣지 않고 경로와 재확인 지침만** 준다. 훅 출력은 10,000자를 넘으면 전체 대신 파일 경로 + 앞부분 미리보기로
#    바뀌어 전달되므로, 크기 제한 없는 본문을 실으면 긴 conventions 는 조용히 잘린 채 "다시 실었다" 고 믿게 된다. 그래서 크기와 무관하게 경로만 준다.
#    · 피처 worktree(feature/* 브랜치)가 있으면 문서 작성 기준은 원본이 아니라 그 worktree 의 conventions.md(snapshot 사본, 피처가 고쳤을 수 있다)다.
#      이 훅은 지금 세션이 어느 피처를 다루는지 알 수 없으므로 임의로 고르지 않고 후보 경로만 알려 준다.
#    · 피처 worktree 가 없으면 프로젝트 루트의 conventions.md 경로를 알려 준다.
#  - 출력 전체는 10,000자보다 충분히 작게 유지한다(후보 worktree 목록은 MAX_WORKTREE_CANDIDATES 개까지만 나열).
#
# 주의:
#  - 파이프라인 child Claude(FEATURE_ROLE_CHILD=1)는 규칙을 프롬프트로 명시 전달받는다 — 아무것도 출력하지 않는다(중복 주입 금지).
#  - source 가 compact 가 아닌 SessionStart(startup/resume/clear)에는 아무것도 출력하지 않는다 — matcher 없이 등록돼도 반복 주입하지 않는다.
#  - 어떤 경우에도 exit 0 (세션 시작을 막지 않는다). 마커 파일을 만들지도 지우지도 않는다.

[ "${FEATURE_ROLE_CHILD:-}" = 1 ] && exit 0

source_kind=""
if [ ! -t 0 ]; then
  source_kind="$(jq -r '.source // empty' 2>/dev/null || true)"
fi
[ "$source_kind" = compact ] || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SKILL_DIR="$PROJECT_DIR/.claude/skills/feature"

echo "[FEATURE SKILL — 컨텍스트 압축 직후 복구]"
echo "방금 컨텍스트가 압축됐다. 압축 전에 읽은 규칙·절차 본문은 요약됐거나 사라졌을 수 있다 — 기억으로 진행하지 않는다."
echo "feature 스킬 작업을 이어 가는 중이면 다음 행동 전에:"
echo "1. $SKILL_DIR/SKILL.md 를 다시 읽는다."
echo "2. 현재 단계의 참조 문서를 $SKILL_DIR/references/ 에서 다시 읽는다(SKILL.md 의 '참조 문서' 표 — 러너 출력의 [SKILL REFERENCE] 줄이 가리킨 파일). 파일이 없으면 진행하지 말고 사용자에게 설치 누락을 보고한다."
echo "3. 진행 상태는 기억이 아니라 피처 worktree 의 .agent-work/run-state.json·decisions.md 와 러너 재실행 결과로 확인한다."

# 피처 worktree 후보: 이 저장소의 worktree 가운데 feature/* 브랜치를 체크아웃한 것
feature_worktrees=""
if command -v git >/dev/null 2>&1; then
  feature_worktrees="$(git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/feature\//{print p}' || true)"
fi

MAX_WORKTREE_CANDIDATES=20
if [ -n "$feature_worktrees" ]; then
  echo "4. conventions: 설계·구현 문서를 쓰거나 고치기 전에 **현재 피처 worktree 의** conventions.md 를 Read 로 다시 읽는다 — 프로젝트 루트(원본) 사본이 아니라 worktree 사본이 기준이다. 이 훅은 어느 피처가 진행 중인지 알 수 없고 본문도 싣지 않는다. 후보(임의로 고르지 말고 진행 중인 피처의 것을 읽는다. 없는 파일이면 그 피처에는 conventions 가 없다):"
  printf '%s\n' "$feature_worktrees" | awk -v max="$MAX_WORKTREE_CANDIDATES" '
    NF == 0 { next }
    { n++; if (n <= max) print "   - " $0 "/conventions.md" }
    END { if (n > max) print "   - … 외 " (n - max) "개 (git worktree list 로 확인한다)" }'
elif [ -f "$PROJECT_DIR/conventions.md" ]; then
  echo "4. conventions: 압축 전에 읽은 conventions 본문은 요약됐거나 사라졌을 수 있다. 이 훅은 본문을 싣지 않는다 — 다음 행동 전에 $PROJECT_DIR/conventions.md 를 Read 로 처음부터 끝까지 다시 읽는다(진행 중인 피처 worktree 가 없어 프로젝트 루트 파일이 기준이다. 이후 피처 worktree 가 생기면 문서 작성 기준은 그 worktree 사본이다)."
fi
exit 0
