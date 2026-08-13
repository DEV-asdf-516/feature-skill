#!/bin/bash
# UserPromptSubmit 훅: 선택적 conventions.md를 오케스트레이터에 주입한다.
# 이 이벤트에서 exit 0 + stdout 출력은 Claude의 컨텍스트에 그대로 주입된다.
#
# 주의:
#  - 주입 분량 = 매 턴 토큰 비용. conventions.md는 압축 상태를 유지할 것.
#  - exit 2는 이 이벤트에서 '프롬프트 자체를 차단'하므로 절대 사용 금지.

CONVENTIONS_FILE="$CLAUDE_PROJECT_DIR/conventions.md"

# conventions.md가 없어도 사용자 프롬프트를 막으면 안 되므로 조용히 통과
[ -f "$CONVENTIONS_FILE" ] && cat "$CONVENTIONS_FILE"
exit 0
