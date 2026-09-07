#!/bin/bash
# PreToolUse 훅 (matcher: Bash)
# "명시적 지시 전 커밋/푸시 금지"를 플래그 파일 방식으로 강제.
# 사용자가 커밋을 지시하면 Claude가 먼저 touch .claude/ALLOW_COMMIT 후 커밋.
# 플래그는 1회용 — 커밋 지시 없이 Claude가 임의 커밋하는 경로를 차단.

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
FLAG="$CLAUDE_PROJECT_DIR/.claude/ALLOW_COMMIT"

if echo "$CMD" | grep -qE 'git\s+(commit|push)'; then
  # force push는 플래그와 무관하게 항상 차단 (운영 안전성)
  if echo "$CMD" | grep -qE 'push\s+.*(--force|-f\b)'; then
    echo "차단: force push는 허용되지 않습니다." >&2
    exit 2
  fi
  if [ ! -f "$FLAG" ]; then
    echo "차단: 사용자의 명시적 커밋/푸시 지시가 필요합니다. 지시를 받았다면 'touch .claude/ALLOW_COMMIT' 후 재시도하세요." >&2
    exit 2
  fi
  rm -f "$FLAG"   # 1회용 소모
fi

# 파일 삭제 가드: rm/unlink/git rm/find -delete 차단 (.agent-work·임시 경로 제외).
# 파이프라인 워커(리뷰·수정 세션)는 지시 여부와 무관하게 삭제 금지 — 대상·사유를 보고만 한다.
# 사용자에게 직접 삭제 지시를 받은 세션만 touch .claude/ALLOW_DELETE (1회용) 후 실행.
DELETE_FLAG="$CLAUDE_PROJECT_DIR/.claude/ALLOW_DELETE"
if echo "$CMD" | grep -qE '(^|[;&|[:space:]])(rm|unlink)[[:space:]]|git[[:space:]]+rm[[:space:]]|-delete([[:space:]]|$)'; then
  if ! echo "$CMD" | grep -qE '(rm|unlink)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*("?\.agent-work/|"?/tmp/|"?/private/tmp/)'; then
    if [ ! -f "$DELETE_FLAG" ]; then
      echo "차단: 파일 삭제는 사용자의 명시적 지시가 필요합니다. 파이프라인 워커는 지시 여부와 무관하게 삭제 금지 — 삭제가 필요하면 대상과 사유를 결과 보고에 남기고 계속하세요. 사용자에게 직접 지시받은 오케스트레이터 세션만 'touch .claude/ALLOW_DELETE' 후 재시도(1회용, .agent-work·/tmp 하위는 플래그 불필요)." >&2
      exit 2
    fi
    rm -f "$DELETE_FLAG"   # 1회용 소모
  fi
fi

# 원복 가드: 작업 트리 파일을 다른 시점의 내용으로 되돌리는 명령 차단.
# 같은 working tree 에서 다른 세션이 작업 중일 수 있고 git 은 변경 소유자를 기록하지 않는다 —
# 파이프라인 수정자·리뷰어는 지시 여부와 무관하게 원복 금지(범위 밖 변경은 보존 후 보고).
# 사용자에게 직접 지시받은 세션만 touch .claude/ALLOW_RESTORE (1회용) 후 실행.
RESTORE_FLAG="$CLAUDE_PROJECT_DIR/.claude/ALLOW_RESTORE"
if echo "$CMD" | grep -qE 'git[[:space:]]+(restore[[:space:]]|checkout[[:space:]]+[^[:space:]]*[[:space:]]+--[[:space:]]|checkout[[:space:]]+--[[:space:]]|reset[[:space:]]+--(hard|merge)|stash[[:space:]]+(pop|apply|drop))'; then
  if [ ! -f "$RESTORE_FLAG" ]; then
    echo "차단: 작업 트리 원복(git restore/checkout -- /reset --hard/stash pop)은 사용자의 명시적 지시가 필요합니다. 파이프라인 수정자·리뷰어는 지시 여부와 무관하게 원복 금지 — 범위 밖 변경은 되돌리지 말고 대상·사유를 decisions.md 에 보고하세요(다른 세션의 작업일 수 있습니다). 사용자에게 직접 지시받은 세션만 'touch .claude/ALLOW_RESTORE' 후 재시도(1회용)." >&2
    exit 2
  fi
  rm -f "$RESTORE_FLAG"   # 1회용 소모
fi

exit 0
