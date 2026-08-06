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

exit 0
