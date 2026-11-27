#!/usr/bin/env bash
# Codex App Server: 실제 읽기 전용 신규 1 turn + 같은 key 재개 1 turn만 실행한다.
# 사용: 피처 저장소 루트에서 LIVE_CODEX_PROBE_APPROVED=1 bash <이 파일>
#       LIVE_CODEX_PROBE_DRY_RUN=1 bash <이 파일>   설정·preflight 까지만 확인하고 끝낸다(모델 호출 0회, 승인 변수 불필요)
# 외부 패키지 설치·커밋·푸시·기존 세션 수정 없음. 결과·원장은 .agent-work에 보존.
set -eo pipefail
dry_run="${LIVE_CODEX_PROBE_DRY_RUN:-}"
if [ "$dry_run" != 1 ] && [ "${LIVE_CODEX_PROBE_APPROVED:-}" != 1 ]; then
  echo '[STOP] 유료 모델 호출 2회가 발생한다. LIVE_CODEX_PROBE_APPROVED=1이 필요하다.' >&2
  exit 2
fi
root="$(git rev-parse --show-toplevel)" || exit 1
cd "$root" || exit 1
[ -f .claude/skills/feature/config.sh ] || { echo '[FAIL] 피처 저장소 루트에서 실행해야 한다.' >&2; exit 1; }
key="appserver-live-probe-$(date -u +%Y%m%dT%H%M%SZ)-$$"
work_dir=".agent-work"
base="$work_dir/reviews/$key"
mkdir -p "$base" || exit 1
# 소스 저장소의 config.sh 는 TEST_CMD/LINT_CMD 가 CHANGE_ME 라서 가드가 source 를 거부한다(source 한 셸이 그대로 exit 1).
# 저장소의 config.sh 는 건드리지 않고, 스킬 사본을 .agent-work 아래(작업 트리 스냅샷 제외 영역)에 두고 그 두 줄만 채워 쓴다.
# 사본은 지우지 않는다 — 불명 상태가 남으면 중단 메시지의 status/reconcile 명령이 이 사본의 스크립트를 가리킨다.
skill_copy="$root/$base/skill/.claude/skills/feature"
mkdir -p "$(dirname "$skill_copy")" && cp -R .claude/skills/feature "$skill_copy" || exit 1
sed 's|^TEST_CMD="CHANGE_ME"|TEST_CMD="true"|; s|^LINT_CMD="CHANGE_ME"|LINT_CMD="true"|' .claude/skills/feature/config.sh > "$skill_copy/config.sh" || exit 1
export FEATURE_PROJECT_ROOT="$root"
# shellcheck source=/dev/null
source "$skill_copy/scripts/lib/bootstrap.sh"
[ "$WORK_DIR" = "$work_dir" ] || { echo "[FAIL] WORK_DIR($WORK_DIR)이 $work_dir 가 아니다." >&2; exit 1; }
[ "$(role_backend REVIEWER)" = codex_app_server ] || { echo '[FAIL] REVIEWER가 Codex App Server backend가 아니다.' >&2; exit 1; }
command -v "$CODEX_BIN" >/dev/null 2>&1 || { echo '[FAIL] codex 바이너리가 없다.' >&2; exit 1; }
schema="$base/schema.json"
cat > "$schema" <<'JSON'
{
  "type": "object",
  "properties": {
    "probe": {"type": "string", "enum": ["appserver-readonly"]},
    "turn": {"type": "integer", "enum": [1, 2]}
  },
  "required": ["probe", "turn"],
  "additionalProperties": false
}
JSON
codex_app_preflight || { echo '[FAIL] preflight 실패. 모델 호출 0회.' >&2; exit 1; }
if [ "$dry_run" = 1 ]; then
  echo "[DRY RUN] 모델 호출 0회 — 설정·preflight 통과. 실제 실행 시: REVIEWER $(role_model REVIEWER)/$(role_effort REVIEWER), key=$key 형식, root=$PROJECT_ROOT"
  cat "$(codex_app_preflight_cache)"
  exit 0
fi

for turn in 1 2; do
  out="$base/turn-$turn.json"
  prompt="Return only this JSON object, without using any tools or modifying any files: {\"probe\":\"appserver-readonly\",\"turn\":$turn}"
  echo "[LIVE] turn $turn/2, key=$key" >&2
  run_readonly_json_role REVIEWER "$key" "appserver-live-probe-$key-turn-$turn" "$schema" "$out" "$prompt" '' || {
    echo "[FAIL] turn $turn 호출 실패. 자동 재호출 없음. $base 와 호출 기록을 확인한다." >&2
    exit 1
  }
  jq -e --argjson n "$turn" '.probe=="appserver-readonly" and .turn==$n' "$out" >/dev/null || {
    echo "[FAIL] turn $turn의 JSON 내용 불일치. 세션 미수용. 자동 재호출 없음." >&2
    exit 1
  }
  role_session_accept REVIEWER "$key" "appserver-live-probe-$key-turn-$turn" || {
    echo "[FAIL] turn $turn 세션 수용 실패. 자동 재호출 없음." >&2
    exit 1
  }
  ledger="$WORK_DIR/.session-$key.codex.json"
  if [ "$turn" = 1 ]; then
    thread1="$(jq -r .thread_id "$ledger")"
    turn1="$(jq -r .last_accepted_turn_id "$ledger")"
  else
    thread2="$(jq -r .thread_id "$ledger")"
    turn2="$(jq -r .last_accepted_turn_id "$ledger")"
  fi
done
[ "$thread1" = "$thread2" ] && [ -n "$thread1" ] && [ "$turn1" != "$turn2" ] || {
  echo "[FAIL] 세션 재개 결속 불일치: thread=$thread1/$thread2, turn=$turn1/$turn2" >&2
  exit 1
}
[ "$(jq -sr --arg k "$key" '[.[] | select(.label|startswith("appserver-live-probe-" + $k))] | length' "$WORK_DIR/usage.jsonl")" = 2 ] || {
  echo '[FAIL] probe 사용량 행이 정확히 두 개가 아니다.' >&2
  exit 1
}
echo "[PASS] 신규 1회 + 같은 thread 재개 1회, 서로 다른 turn id, 결과 JSON 2회, usage 행 2개"
echo "thread_id=$thread1; turn_ids=$turn1,$turn2; records=$base"
jq -c --arg k "$key" 'select(.label|startswith("appserver-live-probe-" + $k)) | {label,usage_observation_status,usage_error,input_effective,cache_read,output,estimated_cost_usd,context_last_turn}' "$WORK_DIR/usage.jsonl"
