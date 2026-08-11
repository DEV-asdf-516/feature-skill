#!/bin/bash
# codex PreToolUse 훅 (프로젝트 레벨)
# claude 쪽 pre_bash_guard.sh 와 동일한 커밋 통제를 codex 워커(Luna)에게 적용.
# exit 2 = 도구 호출 차단, stderr가 codex에게 거부 사유로 전달됨.
# Sol은 read-only 샌드박스라 이 훅에 걸릴 일이 없음.
#
# 프로젝트별 보호(생성 코드·마이그레이션 편집 금지 등)가 필요하면
# 같은 패턴(grep 검사 → exit 2)으로 이 아래에 추가하세요.
#
# 주의: hooks.json 의 command 경로가 상대 경로이므로 codex를 저장소 루트에서 실행해야 한다.

INPUT=$(cat)
TOOL_INPUT_TEXT=$(echo "$INPUT" | jq -r '.tool_input | tostring // empty')

[ -z "$TOOL_INPUT_TEXT" ] && exit 0

# 워커 커밋/푸시 금지 (스킬 강제 규칙: 커밋은 사용자 지시 시 Sonnet)
if echo "$TOOL_INPUT_TEXT" | grep -qE 'git\s+(commit|push)'; then
  echo "차단: 워커는 커밋/푸시할 수 없습니다. 커밋은 Sonnet이 사용자 지시를 받아 수행합니다." >&2
  exit 2
fi

# 워커 파일 삭제 금지 (.agent-work·임시 경로 제외) — 삭제가 필요하면 사유를 보고하고 중단
if echo "$TOOL_INPUT_TEXT" | grep -qE '(^|[;&|[:space:]"])(rm|unlink)[[:space:]]|git[[:space:]]+rm[[:space:]]|-delete([[:space:]"]|$)'; then
  if ! echo "$TOOL_INPUT_TEXT" | grep -qE '(rm|unlink)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*("?\.agent-work/|"?/tmp/|"?/private/tmp/)'; then
    echo "차단: 워커는 프로젝트 파일을 삭제할 수 없습니다. 삭제가 필요하면 대상과 사유를 결과 보고에 남기세요(.agent-work·/tmp 하위는 허용)." >&2
    exit 2
  fi
fi

exit 0
