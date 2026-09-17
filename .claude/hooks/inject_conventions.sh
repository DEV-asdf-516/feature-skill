#!/bin/bash
# UserPromptSubmit 훅: 선택적 conventions.md를 interactive 오케스트레이터에 세션당 한 번만 주입한다.
# 이 이벤트에서 exit 0 + stdout 출력은 Claude의 컨텍스트에 그대로 주입된다.
#
# 주의:
#  - 매 턴 주입은 턴마다 conventions 분량만큼 cache read 를 만든다. 첫 프롬프트에 한 번 넣으면 이후 턴은 대화 문맥에 남아 있다.
#    세션 판별은 훅 stdin JSON 의 session_id 로 하고, 주입 기록은 임시 디렉터리의 마커 파일이다(저장소에 남기지 않는다).
#    --resume 된 세션은 session_id 가 같으므로 다시 넣지 않는다. stdin 에 session_id 가 없으면(수동 실행) 매번 주입한다.
#  - 파이프라인 child Claude(run_readonly_json_role / run_edit_role)는 FEATURE_ROLE_CHILD=1 로 호출되며 conventions 를
#    프롬프트 또는 --append-system-prompt 로 이미 받는다. 이 훅은 그 경우 아무것도 출력하지 않는다(중복 주입 금지).
#  - exit 2는 이 이벤트에서 '프롬프트 자체를 차단'하므로 절대 사용 금지.

[ "${FEATURE_ROLE_CHILD:-}" = 1 ] && exit 0

CONVENTIONS_FILE="$CLAUDE_PROJECT_DIR/conventions.md"
# conventions.md가 없어도 사용자 프롬프트를 막으면 안 되므로 조용히 통과
[ -f "$CONVENTIONS_FILE" ] || exit 0

session_id=""
if [ ! -t 0 ]; then
  session_id="$(jq -r '.session_id // empty' 2>/dev/null || true)"
fi
if [ -n "$session_id" ]; then
  marker_dir="${TMPDIR:-/tmp}/claude-conventions-injected"
  marker="$marker_dir/$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_')"
  [ -f "$marker" ] && exit 0
  mkdir -p "$marker_dir" 2>/dev/null && : > "$marker" 2>/dev/null
fi
cat "$CONVENTIONS_FILE"
exit 0
