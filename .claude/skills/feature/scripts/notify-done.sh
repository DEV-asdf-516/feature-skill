#!/usr/bin/env bash
# =============================================================
# DONE 완료 푸시 알림 — ntfy HTTP API
# 파일 경로: .claude/skills/feature/scripts/notify-done.sh
# feature-run.sh 가 source 하고, done stage 에서 write_state done DONE 성공 직후 1회 호출한다.
#
# 계약:
#   - OS 독립: 발송 경로는 curl HTTP 요청 하나뿐이다. uname/OSTYPE/OS 조건문으로 발송 여부를 정하지 않는다.
#   - 알림은 부수 효과다: 미설정·발송 실패 어느 쪽도 DONE 결과(exit 0)·상태 전이를 바꾸지 않는다 — 항상 return 0.
#   - DONE 은 "리뷰 승인 + 테스트·린트 통과"다. FINALIZED(사용자 승인 뒤 --finalize)가 아니므로 본문에 finalize 대기 여부를 담는다.
#   - 피처(.agent-work)당 최대 1회: 성공 시 $WORK_DIR/notify-done.sent 마커를 남긴다. 이미 DONE 인 재실행은
#     러너가 done stage 전에 조기 종료하고, done stage 로 재진입하는 경로(stage 힌트 done/RUNNING)는 마커가 막는다.
#     --new 는 마커도 archive/ 로 옮기므로 새 피처는 다시 발송된다.
#   - 민감정보: 토픽·토큰은 환경변수/config.sh 로만 받고(하드코딩 금지) live.log 에 쓰지 않는다. 토큰은 argv 가
#     아니라 curl --config(stdin)으로 전달하고(ps 노출 방지), HTTP 결과는 -w '%{http_code}' 로만 판정해
#     curl 오류 메시지(URL=topic 포함)가 로그에 남지 않는다.
# 설정은 config.sh 의 "ntfy 완료 푸시 알림" 절: NTFY_TOPIC(필수)·NTFY_URL·NTFY_TOKEN(선택)·NTFY_TIMEOUT·NTFY_CURL_BIN.
# 호출 문맥 의존: config.sh 가 먼저 source 돼 있고, log 함수와 WORK_DIR·ROOT·FEATURE_ID 가 정의돼 있어야 한다.
# =============================================================

NOTIFY_DONE_MARKER="$WORK_DIR/notify-done.sent"

notify_feature_done() {
  local project feature finalize_note body ts http_code="" rc=0
  if [ -z "${NTFY_TOPIC:-}" ]; then
    log "완료 알림 미설정 — 발송 생략 (NTFY_TOPIC 환경변수를 설정하면 DONE 시 ntfy 푸시 알림을 보낸다. README 'ntfy 완료 푸시 알림' 참고)"
    return 0
  fi
  if [ -f "$NOTIFY_DONE_MARKER" ]; then
    log "완료 알림 생략 — 이미 발송됨 ($NOTIFY_DONE_MARKER)"
    return 0
  fi
  command -v "$NTFY_CURL_BIN" >/dev/null 2>&1 \
    || { log "[WARN] 완료 알림 발송 실패 — HTTP 클라이언트 '$NTFY_CURL_BIN' 없음 (DONE 결과에는 영향 없음)"; return 0; }
  ts="$(date '+%F %T')"
  project="$(basename "$ROOT")"
  feature="${FEATURE_ID:-}"
  if [ -n "$feature" ]; then
    finalize_note="finalize: 승인 대기 — 사용자 승인 뒤에만 feature-run.sh --feature $feature --finalize"
  else
    feature="(지정 없음)"
    finalize_note="finalize: 해당 없음(수동 모드) — 반영·커밋은 사용자 지시 시에만"
  fi
  body="$(printf 'project: %s\nfeature: %s\nstatus: DONE (리뷰 승인 + 테스트·린트 통과)\ncompleted_at: %s\n%s' \
    "$project" "$feature" "$ts" "$finalize_note")"
  local args=(-s -o /dev/null -w '%{http_code}' --max-time "$NTFY_TIMEOUT"
    -H "Title: feature DONE: $project" -H "Tags: white_check_mark"
    --data-binary "$body" "$NTFY_URL/$NTFY_TOPIC")
  if [ -n "${NTFY_TOKEN:-}" ]; then
    http_code="$(printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN" | "$NTFY_CURL_BIN" --config - "${args[@]}")" || rc=$?
  else
    http_code="$("$NTFY_CURL_BIN" "${args[@]}" </dev/null)" || rc=$?
  fi
  case "$rc:$http_code" in
    0:2[0-9][0-9])
      jq -n --arg at "$ts" '{version:1, sent_at:$at}' > "$NOTIFY_DONE_MARKER.tmp" && mv "$NOTIFY_DONE_MARKER.tmp" "$NOTIFY_DONE_MARKER" \
        || log "[WARN] 완료 알림은 발송됐지만 마커 기록 실패: $NOTIFY_DONE_MARKER"
      log "완료 알림 발송됨 (ntfy HTTP $http_code — topic·token 은 로그에 남기지 않는다)"
      ;;
    *)
      log "[WARN] 완료 알림 발송 실패 (curl exit $rc, HTTP ${http_code:-없음}) — DONE 결과에는 영향 없음. NTFY_URL/NTFY_TOPIC/NTFY_TOKEN·네트워크 확인"
      ;;
  esac
  return 0
}
