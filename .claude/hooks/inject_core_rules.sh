#!/bin/bash
# UserPromptSubmit 훅: 사용자가 프롬프트를 보낼 때마다 실행된다.
# 이 이벤트에서 exit 0 + stdout 출력은 Claude의 컨텍스트에 그대로 주입된다.
# → 세션이 길어져 CLAUDE.md가 컨텍스트에서 밀려나도 핵심 룰은 매 턴 다시 들어간다.
#
# 주의:
#  - 주입 분량 = 매 턴 토큰 비용. core_rules.md는 압축 상태를 유지할 것.
#  - exit 2는 이 이벤트에서 '프롬프트 자체를 차단'하므로 절대 사용 금지.

RULES_FILE="$CLAUDE_PROJECT_DIR/.claude/hooks/core_rules.md"

# 룰 파일이 없어도 사용자 프롬프트를 막으면 안 되므로 조용히 통과
[ -f "$RULES_FILE" ] || exit 0

cat "$RULES_FILE"
exit 0
