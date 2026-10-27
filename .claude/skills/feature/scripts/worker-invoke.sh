#!/usr/bin/env bash
# =============================================================
# 워커 호출 — feature-run.sh 가 source 하는 공용 함수 (실행 파일이 아니다)
# 파일 경로: .claude/skills/feature/scripts/worker-invoke.sh
#
# run_worker 는 원래 feature-run.sh 안의 인라인 함수였고 본문은 그대로다. 파일만 분리한 이유는 하나 —
# tests/worker-regression.sh 가 검증자·리뷰어·수정자 없이 **production 워커 호출 경로 그대로**(프롬프트 조립·WORKER_RULES·
# REFERENCE CODE·implementation-context·스키마·WORKER_MODEL/EFFORT·CLI 라우팅·usage 기록·사후 게이트)를 1회 호출해
# 실제 WORKER_MODEL 의 material-contract 충실도를 재기 위해서다. 테스트용 별도 워커 구현·프롬프트·CLI 인자 복제는 없다.
#
# 호출자 계약(feature-run.sh 와 worker-regression.sh 가 동일하게 제공):
#   config.sh 가 먼저 source 되어 있고, 현재 디렉터리가 저장소 루트(WORK_DIR 상대 경로)다.
#   함수: log, env_error(exit 1), stop_need_user(reason detail → exit 2), stop_need_docs(reason detail → exit 3)
#   변수: SKILL_DIR, WORKER_SCHEMA, WORKER_RESULT, STAGE, 선택 RUN_TAG / TEST_LOG / REVIEW_FILE+GAP_CONTEXT+DOC_GAP_REVIEW(review-gap 호출)
#   UNDECIDED(DOC_GAP·USER_DECISION 모두) 는 impl 재합의가 아니라 doc-gap-resume.json + NEED_USER(UNDECIDED) 다.
# =============================================================

# ---------- 워커 호출 ----------
# run_worker <prompt-file> [unit-dir]
#   unit-dir 없음: 전체 피처 호출. RUN_TAG 기본(worker, verify 의 worker-fix.md)은 결과 $WORKER_RESULT, tree 는 $WORK_DIR/worker-*.tree.
#                  RUN_TAG=review-gap(worker-review-gap.md)은 결과 $WORK_DIR/review-gap-result.json, tree 는 $WORK_DIR/review-gap-*.tree.
#   unit-dir 있음: 구현 단위 호출. unit-dir/unit.json 을 ${UNIT_JSON} 으로 렌더링하고, 결과·tree·원문 로그를 unit-dir/<RUN_TAG>-* 에 남기며,
#                  전체 범위 검사 뒤에 unit-dir/scope.json 으로 같은 write-set 검사를 한 번 더 한다(UNIT_SCOPE_VIOLATION). units manifest 불변도 본다.
#   RUN_TAG (기본 worker): 산출물 접두(unit 의 test-fix 호출은 test-fix-NN). TEST_LOG 는 템플릿 변수로만 쓰인다.
# 세션: 모든 워커 호출(unit·test-fix·verify 의 worker-fix·review-gap)은 Feature 당 하나의 세션($FEATURE_WORKER_SESSION)을 쓴다 —
#        최초 호출이 --session-id, 이후엔 --resume(claude 라우팅일 때. codex exec 는 무상태라 이름이 같아도 호출마다 fresh 다).
#        Unit 은 구현·검증·재개 단위고 세션 단위가 아니다 — 러너가 Unit 마다 CLI 를 다시 부르되 같은 세션을 턴으로 이어 쓴다.
#        전제(cli·모델·effort·워커 규칙 지문)는 worker-session.json 저널로 고정하고, 불일치하면 자동 resume 도 자동 fresh 도 없이 멈춘다.

# ---------- Feature 단일 워커 세션 저널 ----------
# worker-session.json: {version, session, cli, model, effort, contract_fingerprint, generation, session_bound, session_id, last_completed_unit_id, last_completed_tree, created_at}
#   책임 분리 — 저널은 Feature Worker 의 실행 상태·계약·세대·unit 진행만 담는다. 실제 세션 ID 는 CLI 어댑터 한 곳에서만 관리한다:
#     claude 는 .session-feature-worker(평문 UUID — session_id 필드는 과도기 중복), codex 는 .session-feature-worker.codex.json 원장(thread_id).
#   codex thread_id 는 저널에 복사하지 않는다. 대신 session_bound(세션 연결 여부)만 둔다 — role_session_accept 성공 뒤에만 true 가 되고,
#   "아직 세션을 만들지 않음(false + 원장 없음)"과 "원장 소실(true + 원장 없음)"을 구별해 후자는 WORKER_SESSION_MISMATCH 로 멈춘다.
#   session_id 는 첫 '수용' 뒤 CLI 세션 파일(.session-feature-worker)에서 동기화된다(codex 는 null 유지).
#   세션 1개 ≠ 결과 파일 1개 — unit 별 산출물·호출별 usage 기록은 기존대로 분리된다.
#   Validator/Reviewer/Fixer 세션과 혼용하지 않고, 다른 피처·worktree 와도 공유하지 않는다(저널·세션 파일 모두 WORK_DIR 안).
FEATURE_WORKER_SESSION="feature-worker"
WORKER_SESSION_VERSION=1

# 세션 계약 지문: 워커 규칙(core_rules + conventions + WORKER_SKILLS) + 워커 프롬프트 템플릿 + 결과 스키마.
# 이 중 하나라도 피처 도중 바뀌면 같은 세션을 이어 쓰지 않는다(WORKER_SESSION_MISMATCH — 사용자가 재시작 방식을 명시).
worker_contract_fingerprint() {
  local rules p
  rules="$(load_worker_rules)" || return 1
  {
    printf 'worker-session-v%s\0%s\0' "$WORKER_SESSION_VERSION" "$rules"
    for p in worker-unit.md worker-unit-fix.md worker-fix.md worker-review-gap.md; do
      printf '%s\0' "$p"; cat "$SKILL_DIR/prompts/$p"; printf '\0'
    done
    cat "$WORKER_SCHEMA"
  } | sha256_stdin
}

worker_session_set_id() { # session-id — 확정(수용)된 세션 ID 반영이므로 결속 상태도 함께 true 가 된다
  local journal="$WORK_DIR/worker-session.json"
  jq --arg id "$1" '.session_id=$id | .session_bound=true' "$journal" > "$journal.tmp" && mv "$journal.tmp" "$journal"
}
# role_session_accept 성공 뒤에만 호출된다 — 세션 연결 여부만 기록하고 codex thread_id 는 원장에만 둔다(멱등).
worker_session_mark_bound() {
  local journal="$WORK_DIR/worker-session.json"
  jq -e '.session_bound==true' "$journal" >/dev/null 2>&1 && return 0
  jq '.session_bound=true' "$journal" > "$journal.tmp" && mv "$journal.tmp" "$journal"
}
# 수용 뒤 CLI 세션 파일의 ID 를 저널에 반영한다(claude 만 — codex 는 세션 파일이 없고 thread_id 를 저널에 복사하지 않는다).
worker_session_sync_id() {
  local journal="$WORK_DIR/worker-session.json" sid_file="$WORK_DIR/.session-$FEATURE_WORKER_SESSION"
  [ "$(role_cli WORKER)" = claude ] || return 0
  [ -f "$sid_file" ] || return 0
  [ "$(jq -r '.session_id // ""' "$journal")" = "$(cat "$sid_file")" ] && return 0
  worker_session_set_id "$(cat "$sid_file")"
}
worker_session_note_unit_done() { # unit-id tree
  local journal="$WORK_DIR/worker-session.json"
  [ -f "$journal" ] || return 0
  jq --arg id "$1" --arg tree "$2" '.last_completed_unit_id=$id | .last_completed_tree=$tree' \
    "$journal" > "$journal.tmp" && mv "$journal.tmp" "$journal"
}

# ---------- 세션 교체(회전): 논리적 워커는 하나, 물리적 CLI 세션만 unit 경계에서 교체 ----------
# worker-handoff.json (schemas/worker-handoff.schema.json): 세션 이관 '제어' 정보만 담는다 — 구현 사실은 implementation-context.json 이다.
# 교체는 unit 완료(targeted test PASS, done.json 확정) 직후에만 예약되고, 다음 세대의 첫 호출 전에
# ensure_feature_worker_session 이 스키마·계약 지문·git tree 일치를 검증한 뒤에만 fresh 세션을 만든다.
worker_handoff_valid_file() { # handoff-path
  [ -f "$1" ] && jq -e '
    type=="object" and ((keys - ["version","generation","last_completed_unit","next_unit","source_tree","contract_fingerprint","context_file"])|length)==0
    and .version==1 and (.generation|type=="number" and .>=2)
    and (.last_completed_unit|type=="string" and length>0) and (.next_unit|type=="string" and length>0)
    and (.source_tree|type=="string" and test("^[0-9a-f]{40,64}$"))
    and (.contract_fingerprint|type=="string" and length>0) and (.context_file|type=="string" and length>0)' \
    "$1" >/dev/null 2>&1
}

# unit 완료 직후에만 호출된다(run_unit). 판단값은 이 unit 에서 이 실행이 부른 마지막 워커 호출의 usage 행에서
# context_last_turn(마지막 model 호출의 실제 입력 = 컨텍스트 창 점유량; claude stream-json / codex rollout) 을 먼저 쓴다 — 창 크기(context_window)를
# 알면 비율(WORKER_SESSION_ROTATE_CONTEXT_RATIO), 모르면 고정 임계치. 실측이 없으면 input_per_turn(턴당 평균, 근사)과 고정 임계치를 비교하고 근사 사용을 로그에 남긴다. input_effective 는 invocation 안 모든 turn 의 누적 입력이라 컨텍스트 창 크기가 아니다
# (그걸 쓰면 매 unit 교체된다 — 2026-10-27). 둘 다 없으면 임의 추정 없이 세션을 유지한다. claude 세션 파일·codex 원장 모두 세대 접미사로 은퇴. 마지막 unit 뒤에는 교체하지 않는다(이관할 다음 unit 이 없다).
maybe_rotate_feature_worker_session() { # completed-unit-id completed-tree
  local journal="$WORK_DIR/worker-session.json" sid_file="$WORK_DIR/.session-$FEATURE_WORKER_SESSION"
  local handoff="$WORK_DIR/worker-handoff.json"
  local threshold="${WORKER_SESSION_ROTATE_INPUT_TOKENS:-0}" observed next="" u old_gen new_gen fp
  case "$threshold" in ''|*[!0-9]*) env_error "WORKER_SESSION_ROTATE_INPUT_TOKENS 가 정수가 아님: '$threshold'";; esac
  [ "$threshold" -gt 0 ] || return 0
  local cli ledger; cli="$(role_cli WORKER)" || return 0
  ledger="$(codex_session_ledger "$FEATURE_WORKER_SESSION")"
  [ -f "$journal" ] || return 0
  case "$cli" in claude) [ -f "$sid_file" ] || return 0;; codex) [ -f "$ledger" ] || return 0;; *) return 0;; esac
  # 이 unit 에서 이 프로세스가 실제로 부른 마지막 워커 호출의 행만 본다 — 재개(워커 미호출)나 label 부재면 이전 unit 값을 재사용하지 않고 유지
  local label_file="$WORK_DIR/units/$1/last-usage-label" label=""
  [ -f "$label_file" ] && label="$(cat "$label_file")"
  if [ -z "$label" ]; then
    log "세션 교체 판단 보류 — unit $1 에서 이 실행이 부른 워커 호출이 없음(재개 경로). 이전 unit 의 telemetry 는 재사용하지 않는다"
    return 0
  fi
  # 판정 순서:
  #   1) context_last_turn(실측) + context_window 둘 다 있음 → 비율 context_last_turn/context_window ≥ WORKER_SESSION_ROTATE_CONTEXT_RATIO
  #   2) context_last_turn 만 있음(창 크기 관측 불가)      → 고정 임계치 WORKER_SESSION_ROTATE_INPUT_TOKENS 와 비교
  #   3) 실측 없음                                        → input_per_turn(턴당 평균 근사) 과 고정 임계치 비교, 근사 사용을 로그에 남긴다
  #   4) 아무것도 없음                                    → 임의 추정 없이 유지
  local row basis window ratio="${WORKER_SESSION_ROTATE_CONTEXT_RATIO:-0.8}" hit=0
  case "$ratio" in ''|*[!0-9.]*|.|*.*.*) env_error "WORKER_SESSION_ROTATE_CONTEXT_RATIO 가 소수가 아님: '$ratio'";; esac
  row="$(jq -cs --arg l "$label" --arg c "$cli" '[ .[] | select(.role=="WORKER" and .cli==$c and .label==$l) ] | if length==0 then empty else last end' "$WORK_DIR/usage.jsonl" 2>/dev/null || true)"
  observed="$(printf '%s' "$row" | jq -r '.context_last_turn // empty' 2>/dev/null || true)"
  window="$(printf '%s' "$row" | jq -r 'if (.context_window // 0) > 0 then .context_window else empty end' 2>/dev/null || true)"
  if [ -n "$observed" ] && [ -n "$window" ]; then
    basis="context_last_turn/context_window(실측) ${observed}/${window}tok = $(awk -v a="$observed" -v b="$window" 'BEGIN{printf "%.3f", a/b}') ≥ 비율 $ratio"
    [ "$(awk -v a="$observed" -v b="$window" -v r="$ratio" 'BEGIN{print (a/b >= r) ? 1 : 0}')" = 1 ] && hit=1
  elif [ -n "$observed" ]; then
    basis="context_last_turn(실측, 창 크기 관측 불가 → 고정 임계치) ${observed}tok ≥ 임계치 ${threshold}tok"
    [ "$observed" -ge "$threshold" ] && hit=1
  else
    observed="$(printf '%s' "$row" | jq -r '.input_per_turn // empty' 2>/dev/null || true)"
    if [ -z "$observed" ]; then
      log "[WARN] 세션 교체 판단 보류 — usage telemetry 에 호출 $label 의 WORKER context_last_turn/input_per_turn 이 없어 측정 불가(임의 추정 없이 세션 유지)"
      return 0
    fi
    log "세션 교체 판단에 근사값 사용 — 호출 $label 의 실측 context_last_turn 관측 불가, input_per_turn(턴당 평균) ${observed}tok 으로 고정 임계치 ${threshold}tok 와 비교"
    basis="input_per_turn(턴당 평균 근사 — context_last_turn 관측 불가) ${observed}tok ≥ 임계치 ${threshold}tok"
    [ "$observed" -ge "$threshold" ] && hit=1
  fi
  [ "$hit" -eq 1 ] || return 0
  for u in $(unit_ids); do unit_done_valid "$u" || { next="$u"; break; }; done
  [ -n "$next" ] || return 0
  old_gen="$(jq -r '.generation // 1' "$journal")"; new_gen=$((old_gen + 1))
  fp="$(jq -r '.contract_fingerprint' "$journal")"
  git cat-file -e "$2^{tree}" 2>/dev/null || env_error "세션 교체: 완료 tree 가 유효하지 않음: $2"
  jq -n --argjson gen "$new_gen" --arg last "$1" --arg next "$next" --arg tree "$2" --arg fp "$fp" --arg ctx "$IMPL_CONTEXT_FILE" \
    '{version:1, generation:$gen, last_completed_unit:$last, next_unit:$next, source_tree:$tree, contract_fingerprint:$fp, context_file:$ctx}' \
    > "$handoff.tmp" && mv "$handoff.tmp" "$handoff" || env_error "worker-handoff.json 기록 실패"
  worker_handoff_valid_file "$handoff" || env_error "worker-handoff.json 이 스키마(schemas/worker-handoff.schema.json)와 다름"
  # 은퇴한 세션(claude 세션 파일 / codex 원장)은 지우지 않고 세대 접미사로 보존한다. 비워 두면 다음 호출이 fresh(--session-id / 새 exec)로 시작한다.
  case "$cli" in
    claude) mv "$sid_file" "$sid_file.gen$old_gen" || env_error "세션 파일 보존 실패";;
    codex)  mv "$ledger" "$ledger.gen$old_gen" || env_error "codex 세션 원장 보존 실패";;
  esac
  jq --argjson gen "$new_gen" '.generation=$gen | .session_id=null | .session_bound=false' "$journal" > "$journal.tmp" && mv "$journal.tmp" "$journal" \
    || env_error "worker-session.json 세대 갱신 실패"
  log "Feature Worker 세션 교체 예약: $basis — generation $new_gen, unit $next 부터 fresh $cli 세션(계약 문서·context 색인 재주입)"
}

# 워커 호출 전 세션 전제 확정(모델 호출 0회). 호출자 계약: stop_need_user / env_error / log 가 정의돼 있다.
#   저널 없음 + 이전 체계(unit 별 fresh 세션)의 흔적 또는 완료 unit 체크포인트 → 묵시적 마이그레이션 금지, 사용자에게.
#     이어 돌리기로 결정했으면 $WORK_DIR/worker-session.migrate 파일을 만들고 재실행(마커는 1회 소비되고 새 세션 저널이 생긴다).
#   저널 있음 + cli·모델·effort·계약 지문·세션 ID 불일치 → 자동 resume 금지, 자동 fresh 재생성 금지, 사용자에게.
# 세션 증거가 없는 상태에서 fresh 세션을 만들어도 되는지 — generation 1 이면 '아직 미생성'이라 통과, 교체된 세대면 그 세대의
# worker-handoff.json 이 스키마·계약 지문·현재 tree 와 일치해야만 통과한다(claude·codex 공용). 불일치는 모델 호출 0회로 멈춘다.
worker_handoff_gate_for_fresh() { # journal contract_fingerprint
  local journal="$1" fp="$2" gen; gen="$(jq -r '.generation // 1' "$journal")"
  if [ -f "$WORK_DIR/worker-handoff.json" ] && [ "$(jq -r '.generation' "$WORK_DIR/worker-handoff.json" 2>/dev/null)" = "$gen" ]; then
    # 세션 교체 직후의 fresh 세대 — 이관 정보(worker-handoff.json)가 스키마·계약 지문·현재 tree 와 일치해야만 새 세션을 만든다
    worker_handoff_valid_file "$WORK_DIR/worker-handoff.json" \
      || stop_need_user WORKER_SESSION_MISMATCH "worker-handoff.json 이 스키마(schemas/worker-handoff.schema.json)와 다르다 — 이관 정보를 신뢰할 수 없으므로 fresh 세션을 만들지 않는다. 체크포인트를 손으로 고치지 말고, --new 또는 사용자 정리 후 재실행"
    [ "$(jq -r '.contract_fingerprint' "$WORK_DIR/worker-handoff.json")" = "$fp" ] \
      || stop_need_user WORKER_SESSION_MISMATCH "worker-handoff.json 의 계약 지문이 현재 워커 규칙·프롬프트와 다르다 — 이관 시점과 계약이 달라졌으므로 자동으로 fresh 세션을 만들지 않는다. 규칙을 교체 시점으로 되돌리거나 --new"
    local handoff_tree cur_tree
    handoff_tree="$(jq -r '.source_tree' "$WORK_DIR/worker-handoff.json")"
    cur_tree="$(snapshot_worktree_tree)" || env_error "작업 트리 스냅샷 실패"
    [ "$handoff_tree" = "$cur_tree" ] \
      || stop_need_user WORKER_SESSION_MISMATCH "세션 이관 시점 tree($handoff_tree)와 현재 작업 트리($cur_tree)가 다르다 — 이관 전제 위에서만 fresh 세션을 만든다. 변경을 확인한 뒤 그 tree 로 명시적으로 되돌리고 재실행하거나, 의도한 변경이면 사용자가 재시작 방식을 명시하라. 자동 원복 없음"
    if [ "${_HANDOFF_VERIFIED_GEN:-}" != "$gen" ]; then   # run_unit·run_worker 가 각각 검증하므로 같은 세대는 한 번만 기록
      _HANDOFF_VERIFIED_GEN="$gen"
      log "세션 이관 검증 통과 (generation $gen, next unit $(jq -r '.next_unit' "$WORK_DIR/worker-handoff.json")) — fresh 세션으로 계약 문서·context 색인을 다시 받는다"
    fi
  elif [ "$gen" -gt 1 ]; then
    # 교체된 세대인데 세대가 일치하는 이관 정보가 없다(handoff 삭제·변조) — 검증 없는 fresh 세션을 만들지 않는다
    stop_need_user WORKER_SESSION_MISMATCH "worker-session.json 은 generation $gen(교체된 세대)인데 그 세대의 worker-handoff.json 이 없다 — 이관 검증 없이 fresh 세션을 만들지 않는다. 체크포인트를 손으로 고치지 말고 --new 또는 사용자 정리 후 재실행"
  fi
}
ensure_feature_worker_session() {
  local journal="$WORK_DIR/worker-session.json" sid_file="$WORK_DIR/.session-$FEATURE_WORKER_SESSION"
  local cli model effort fp legacy jsid
  cli="$(role_cli WORKER)" || env_error "WORKER CLI 라우팅 실패"
  model="$(role_model WORKER)"; effort="$(role_effort WORKER)"
  fp="$(worker_contract_fingerprint)" || env_error "워커 세션 계약 지문 계산 실패 — 워커 규칙 또는 필수 워커 스킬(WORKER_SKILLS) 로드 실패"
  if [ ! -f "$journal" ]; then
    if [ -f "$WORK_DIR/worker-session.migrate" ]; then
      mv "$WORK_DIR/worker-session.migrate" "$WORK_DIR/worker-session.migrate.used.$(date '+%s')" || env_error "마이그레이션 마커 소비 실패"
      log "worker-session.migrate 확인 — 사용자 승인으로 남은 unit 을 새 Feature Worker 세션으로 이어 간다"
    else
      legacy="$(ls "$WORK_DIR"/.session-worker-unit-* "$WORK_DIR/.session-worker" "$WORK_DIR/.session-review-gap" 2>/dev/null | paste -sd, - || true)"
      [ -z "$legacy" ] || stop_need_user WORKER_SESSION_MISSING "worker-session.json 없이 이전 fresh-워커 체계의 세션 파일($legacy)이 남아 있다 — 예전 실행을 묵시적으로 단일 워커 세션으로 마이그레이션하지 않는다. --new 로 새로 시작하거나, 이어 돌리려면 사용자가 $WORK_DIR/worker-session.migrate 파일을 만들고 재실행(유효한 완료 체크포인트는 건너뛰고 첫 미완료 unit 부터 새 세션으로)"
      if ls "$WORK_DIR"/units/*/done.json >/dev/null 2>&1; then
        stop_need_user WORKER_SESSION_MISSING "완료된 unit 체크포인트가 있는데 worker-session.json 이 없다(이 변경 이전의 fresh-워커 실행이거나 저널 삭제) — 자동으로 fresh 세션을 만들어 잇지 않는다. --new 로 새로 시작하거나, 이어 돌리려면 사용자가 $WORK_DIR/worker-session.migrate 파일을 만들고 재실행"
      fi
    fi
    jq -n --arg session "$FEATURE_WORKER_SESSION" --arg cli "$cli" --arg model "$model" --arg effort "$effort" \
      --arg fp "$fp" --arg now "$(date '+%FT%T%z')" --argjson v "$WORKER_SESSION_VERSION" \
      '{version:$v, session:$session, cli:$cli, model:$model, effort:$effort, contract_fingerprint:$fp,
        generation:1, session_bound:false, session_id:null, last_completed_unit_id:null, last_completed_tree:null, created_at:$now}' \
      > "$journal.tmp" && mv "$journal.tmp" "$journal" || env_error "worker-session.json 기록 실패"
    log "Feature Worker 세션 저널 생성: $journal (cli $cli, $model/$effort)"
    return 0
  fi
  jq -e --argjson v "$WORKER_SESSION_VERSION" '.version==$v' "$journal" >/dev/null 2>&1 \
    || stop_need_user WORKER_SESSION_MISMATCH "worker-session.json 버전이 다르다(기대 $WORKER_SESSION_VERSION) — 다른 형식의 세션 저널을 해석하지 않는다. --new 또는 사용자 정리 후 재실행"
  local mism
  mism="$(jq -r --arg cli "$cli" --arg model "$model" --arg effort "$effort" --arg fp "$fp" \
    '[ (select(.cli!=$cli)       | "cli \(.cli)→\($cli)"),
       (select(.model!=$model)   | "model \(.model)→\($model)"),
       (select(.effort!=$effort) | "effort \(.effort)→\($effort)"),
       (select(.contract_fingerprint!=$fp) | "워커 규칙·프롬프트 계약 지문") ] | join(", ")' "$journal")"
  [ -z "$mism" ] || stop_need_user WORKER_SESSION_MISMATCH "Feature Worker 세션 전제가 저널(worker-session.json)과 다르다($mism) — 다른 전제의 세션을 자동 resume 하지 않고 자동으로 새 세션을 만들지도 않는다. 설정·규칙을 피처 시작 시점으로 되돌려 재실행하거나, 의도한 변경이면 --new(또는 사용자가 재시작 방식을 명시)"
  if [ "$cli" = claude ]; then
    jsid="$(jq -r '.session_id // ""' "$journal")"
    if [ -n "$jsid" ]; then
      [ -f "$sid_file" ] && [ "$(cat "$sid_file")" = "$jsid" ] \
        || stop_need_user WORKER_SESSION_MISMATCH "저널의 Feature Worker 세션 ID($jsid)와 CLI 세션 파일($sid_file: $([ -f "$sid_file" ] && cat "$sid_file" || echo 없음))이 다르다 — 그 세션 없이 자동으로 fresh 워커를 만들어 잇지 않는다. 사용자가 복구(세션 파일 원복) 또는 재시작(--new / worker-session 정리) 방식을 명시하라"
    elif [ -f "$sid_file" ]; then
      # 첫 수용 뒤 저널 동기화 전에 죽은 경우 — 수용이 확정된(commit 된) 세션 ID 이므로 저널에 반영하고 잇는다
      worker_session_set_id "$(cat "$sid_file")" || env_error "worker-session.json 세션 ID 동기화 실패"
      log "Feature Worker 세션 ID 를 세션 파일에서 저널로 동기화: $(cat "$sid_file")"
    elif jq -e '.session_bound==true' "$journal" >/dev/null 2>&1; then
      # 결속 기록은 있는데 세션 증거(ID·세션 파일)가 모두 없다 — 소실이지 '아직 미생성'이 아니다. 자동 fresh 금지.
      stop_need_user WORKER_SESSION_MISMATCH "worker-session.json 은 session_bound=true 인데 세션 ID 도 CLI 세션 파일($sid_file)도 없다 — 수용된 세션이 소실됐다. 자동으로 fresh 세션을 만들지 않는다. 세션 파일을 복구하거나 --new(또는 사용자가 재시작 방식을 명시)"
    else
      worker_handoff_gate_for_fresh "$journal" "$fp"
    fi
  fi
  if [ "$cli" = codex ]; then
    # codex thread_id 는 원장(.session-<key>.codex.json) 한 곳에서만 관리한다 — 저널은 결속 여부(session_bound)만 기록하고
    # 두 파일의 불변식을 대조한다. 원장 내용(모델·effort·계약·thread_id)의 호출 전 대조는 codex_session_begin 이 한다.
    local ledger bound
    ledger="$(codex_session_ledger "$FEATURE_WORKER_SESSION")"
    bound="$(jq -r '.session_bound // false' "$journal")"
    if [ "$bound" = true ] && [ ! -f "$ledger" ]; then
      # '아직 세션 미생성'(false + 원장 없음)과 달리 이것은 수용된 세션의 소실이다 — 자동 fresh 금지
      stop_need_user WORKER_SESSION_MISMATCH "worker-session.json 은 session_bound=true 인데 codex 세션 원장($ledger)이 없다 — 수용된 세션이 소실됐다. 자동으로 fresh 세션을 만들지 않는다. 원장을 복구하거나 --new(또는 사용자가 재시작 방식을 명시)"
    elif [ "$bound" != true ] && [ -f "$ledger" ]; then
      # accept(원장 확정)와 저널 갱신 사이에 죽은 경우 포함 — 두 기록의 불일치 위에서 조용히 resume 하지 않는다
      stop_need_user WORKER_SESSION_MISMATCH "codex 세션 원장($ledger)은 확정돼 있는데 worker-session.json 은 미결속(session_bound=false)이다 — 불일치 위에서 자동 resume 도 자동 fresh 도 하지 않는다. 원장과 저널을 확인한 뒤 사용자가 정리하고 재실행(--new 포함)"
    elif [ "$bound" != true ]; then
      # 미결속 + 원장 없음: generation 1 이면 아직 미생성, 교체된 세대면 handoff 검증을 통과해야 새 exec 를 연다
      worker_handoff_gate_for_fresh "$journal" "$fp"
    fi
  fi
}
run_worker() { # prompt-file [unit-dir]
  local prompt_file="$1" unit_dir="${2:-}" tag="${RUN_TAG:-worker}"
  local prompt worker_rules reference_code result out_dir tree_prefix unit_json="" unit_id="" unit_scope=""
  # 세션은 산출물 경로와 달리 분기하지 않는다 — Feature 전체가 하나의 Worker 세션이다(상단 저널 참고)
  local session="$FEATURE_WORKER_SESSION"
  if [ -n "$unit_dir" ]; then
    unit_json="$(cat "$unit_dir/unit.json")" && unit_id="$(jq -er '.id' "$unit_dir/unit.json")" || env_error "unit.json 읽기 실패: $unit_dir"
    out_dir="$unit_dir"; result="$unit_dir/$tag-result.json"; tree_prefix="$unit_dir/$tag"; unit_scope="$unit_dir/scope.json"
  elif [ "$tag" = worker ]; then
    out_dir="$WORK_DIR/reviews"; result="$WORKER_RESULT"; tree_prefix="$WORK_DIR/worker"
  else
    # 전체 호출이지만 다른 RUN_TAG(review-gap): 결과·tree 를 태그 이름으로 남겨 unit 결과를 합친 worker-result.json 을 덮어쓰지 않는다
    out_dir="$WORK_DIR/reviews"; result="$WORK_DIR/$tag-result.json"; tree_prefix="$WORK_DIR/$tag"
  fi
  # 직전 실행이 기준선 변조로 멈췄으면 복구 전에는 워커를 부르지 않는다(변조된 값을 새 기준선으로 읽는 재실행 우회 차단)
  require_baseline_guard_resolved \
    || stop_need_user SCOPE_BASELINE_CHANGED "worker-baseline.tree 가 직전 중단 시점의 기대값($(jq -r .expected "$BASELINE_GUARD"))으로 복구되지 않음 — 되돌린 뒤 재실행. 자동 복구 없음"
  # 직전 워커 호출 결과가 불확실한 채 남은 변경 위에 같은 워커를 다시 부르지 않는다(사용자가 호출 전 tree 로 복구한 뒤에만)
  require_worker_outcome_guard_resolved \
    || stop_need_user WORKER_OUTCOME_UNCERTAIN "직전 워커 호출($(jq -r '.label' "$WORKER_OUTCOME_GUARD"))의 완료 여부가 불확실한데 작업 트리가 호출 전 tree($(jq -r '.expected' "$WORKER_OUTCOME_GUARD"))로 복구되지 않음 — 되돌린 뒤 재실행. 자동 원복·자동 재호출 없음"
  # 세션 전제(저널) 확정·검증 — 불일치는 모델 호출 0회로 멈춘다
  ensure_feature_worker_session
  # 턴 구분: 이 key 의 '수용된' 세션이 있으면(claude 평문 파일 또는 codex 원장 — session_exists) 후속 턴(resume)이다 —
  # 공통 규칙·참조 코드는 최초 턴에 이미 세션에 있으므로 전체를 중복 주입하지 않고 짧은 재명시만 넣는다.
  # 실제 강제는 러너의 shell 게이트(write-set·index·manifest)가 하므로 재명시가 잊혀도 통과하지 않는다.
  # unit 템플릿 본문(턴별 필수 계약)은 매 턴 그대로 간다.
  local resumed_turn=0
  session_exists "$FEATURE_WORKER_SESSION" && resumed_turn=1
  if [ "$resumed_turn" -eq 1 ]; then
    worker_rules="[CORE RULES]
(이 Feature Worker 세션의 최초 턴에 전달된 [CORE RULES]/[PROJECT CONVENTIONS]/[WORKER SKILL] 블록이 이 턴에도 그대로 계약이다. 필수 제약 재명시: 현재 unit scope 밖 편집 금지 · 이후 unit 선행 구현 금지 · 범위 밖 리팩터링·cleanup 금지 · git commit/push 금지 · git index 조작 금지 · 파일 삭제 금지 · 전체 테스트 스위트 실행 금지 · 최종 출력은 결과 JSON 스키마로만. 세션 기억이 문서·현재 코드와 충돌하면 합의 문서 → 현재 코드 → 세션 기억 순서로 판단하고, 컨텍스트가 압축·재개됐으면 $WORK_DIR/implementation-context.json 과 합의 문서를 다시 읽는다.)"
    reference_code="[REFERENCE CODE 생략 — 이 세션 최초 턴에 전달됨. 앞선 구현으로 인용 줄 범위가 바뀌었을 수 있으니 approach.md 가 인용한 참조가 필요하면 현재 파일에서 다시 읽는다.]"
  else
    # 환경 변수 대입 안의 command substitution 실패는 뒤의 render_prompt 가 성공하면 묻힌다 — 먼저 별도 변수로 받아 실패를 확정한다
    worker_rules="$(load_worker_rules)" || env_error "워커 규칙 또는 필수 워커 스킬(WORKER_SKILLS) 로드 실패 — 워커를 실행하지 않음"
    reference_code="$(load_reference_code)" || env_error "REFERENCE CODE 로드 실패"
  fi
  # unit 호출: run_unit 이 워커 호출 전에 갱신한 implementation-context.json(앞 unit 확정 사실)을 그대로 넣는다 — test-fix 도 같은 파일(확정 전 상태)
  local impl_context=""
  if [ -n "$unit_dir" ]; then impl_context="$(cat "$IMPL_CONTEXT_FILE")" || env_error "implementation-context.json 읽기 실패"; fi
  # REVIEW_FILE / GAP_CONTEXT 는 review-gap 호출(worker-review-gap.md)에서만 채워진다 — 다른 템플릿에는 그 변수가 없다
  prompt="$(WORKER_RULES="$worker_rules" REFERENCE_CODE="$reference_code" WORK_DIR="$WORK_DIR" TEST_CMD="$TEST_CMD" TEST_LOG="${TEST_LOG:-}" \
    UNIT_JSON="$unit_json" UNIT_ID="$unit_id" IMPL_CONTEXT="$impl_context" REVIEW_FILE="${REVIEW_FILE:-}" GAP_CONTEXT="${GAP_CONTEXT:-}" \
    render_prompt "$SKILL_DIR/prompts/$prompt_file" '${WORKER_RULES} ${REFERENCE_CODE} ${WORK_DIR} ${TEST_CMD} ${TEST_LOG} ${UNIT_JSON} ${UNIT_ID} ${IMPL_CONTEXT} ${REVIEW_FILE} ${GAP_CONTEXT}')" \
    || env_error "워커 프롬프트 렌더링 실패"
  local stamp raw; stamp="$(date '+%Y%m%d-%H%M%S')"; raw="$out_dir/$tag-$stamp.log"
  mkdir -p "$out_dir"
  rm -f "$result"
  local index_before index_after worker_rc before_tree after_tree violations scope_hash_before scope_hash_after baseline_before baseline_after units_hash_before=""
  index_before="$(compute_index_fingerprint)" || env_error "워커 호출 전 git index 지문 계산 실패"
  scope_hash_before="$(feature_scope_hash)"
  [ -z "$unit_dir" ] || units_hash_before="$(units_manifest_hash)"
  # 소유권 기준선은 호출 전에 확정해 사후 판정에 그대로 넘긴다 — 파일은 워커가 쓸 수 있는 .agent-work 안에 있다
  baseline_before="$(read_worker_baseline_tree)" || env_error "worker-baseline.tree 가 유효한 tree 를 가리키지 않음"
  [ -n "$baseline_before" ] || log "[WARN] worker-baseline.tree 없음 — new_file_roots 아래는 신규 생성(A)만 허용하는 규칙으로 검사"
  before_tree="$(snapshot_worktree_tree)" || env_error "워커 호출 전 tree 스냅샷 실패"
  printf '%s\n' "$before_tree" > "$tree_prefix-before.tree"
  set +e
  # 워커 CLI 는 WORKER_MODEL 로 라우팅. 프롬프트에 conventions·core_rules 가 이미 있으므로 conventions 는 "".
  run_edit_role WORKER "$session" "$tag-$stamp" "$raw" "$prompt" "" "$WORKER_SCHEMA" "$result" --allowedTools "Bash"
  worker_rc=$?
  set -e
  # 세션 교체 판단이 '이 unit 의 이 호출' usage 행만 보도록 label 을 남긴다(usage.jsonl 의 마지막 WORKER 행 = 이전 unit 일 수 있다)
  [ -z "$unit_dir" ] || printf '%s\n' "$tag-$stamp" > "$unit_dir/last-usage-label"
  # codex resume marker 는 "호출이 스레드에 도달했는지 모른다"를 막는 장치다 — CLI 가 반환된 지금은 그 불확실성이 해소됐다.
  # 결과를 수용할지는 아래 게이트·가드(index·manifest·기준선·write-set·결과 계약·worker-outcome)가 따로 판정하고,
  # 게이트 중단 뒤 사용자가 복구하고 재실행하는 재호출은 같은 스레드에 보내는 '의도된 새 턴'이다 — marker 로 막지 않는다.
  # (호출 도중 프로세스가 죽으면 marker 가 남아 codex_session_begin 이 모델 0회로 멈춘다 — 그 계약은 그대로다.)
  [ "$(role_cli WORKER)" != codex ] || rm -f "$(codex_resume_marker "$FEATURE_WORKER_SESSION")"
  # 기준선 변경은 다른 사후 조건보다 먼저 '기록'만 한다 — index·manifest 검사가 앞서 종료하면 가드가 남지 않아
  # 사용자가 보고된 문제만 고치고 재실행할 때 변조된 기준선이 새 기준선으로 읽힌다. 종료 우선순위(index → manifest → 기준선)는 그대로.
  local baseline_changed=0
  baseline_after=""; [ -f "$WORK_DIR/worker-baseline.tree" ] && baseline_after="$(cat "$WORK_DIR/worker-baseline.tree")"
  if [ "$baseline_after" != "$baseline_before" ]; then
    record_baseline_guard "$baseline_before" "$baseline_after" worker || env_error "worker-baseline 가드 기록 실패"
    baseline_changed=1
  fi
  # 사후 조건을 CLI 성공 여부보다 먼저 본다 — 워커는 작업 트리만 바꿀 수 있고, index 가 바뀌었으면
  # (worker_guard 정규식을 우회한 git add 등) 실패한 실행이라도 복구하지 않고 그 사실부터 보고한다
  index_after="$(compute_index_fingerprint)" || env_error "워커 호출 후 git index 지문 계산 실패"
  [ "$index_after" = "$index_before" ] \
    || env_error "워커가 git index 를 변경함 — 자동 복구하지 않음. git status 로 확인 후 재실행"
  # manifest 불변 검사: 워커가 원본이나 lock 을 고쳐 범위를 넓히면 write-set 검사가 무력화된다 — CLI 성공 여부보다 먼저 본다
  scope_hash_after="$(feature_scope_hash)"
  [ "$scope_hash_after" = "$scope_hash_before" ] \
    || stop_need_user SCOPE_MANIFEST_CHANGED "워커 호출 중 feature-scope.json 또는 feature-scope.lock.json 이 바뀜 — 자동 복구하지 않음. 원본과 lock 을 확인하고, 의도한 범위 변경이면 lock 을 지운 뒤 재실행(impl 재합의)"
  # units manifest 불변 검사(unit 호출): 워커가 원본이나 lock 을 고쳐 unit 범위·순서를 바꾸면 이후 unit 검사가 무력화된다
  if [ -n "$unit_dir" ] && [ "$(units_manifest_hash)" != "$units_hash_before" ]; then
    stop_need_user UNITS_MANIFEST_CHANGED "unit $unit_id 호출 중 implementation-units.json 또는 implementation-units.lock.json 이 바뀜 — 자동 복구하지 않음. 원본과 lock 을 확인하고, 의도한 분할 변경이면 lock 을 지운 뒤 재실행(impl 재합의 후 새 lock 확정)"
  fi
  # write-set 검사: 호출 전후 tree 사이 변경이 feature-scope.json 범위를 벗어나면 자동 원복 없이 보존하고 중단.
  # (같은 working tree 의 다른 세션 변경도 여기 잡힐 수 있다 — 그래서 원복하지 않고 사람이 본다)
  after_tree="$(snapshot_worktree_tree)" || env_error "워커 호출 후 tree 스냅샷 실패"
  printf '%s\n' "$after_tree" > "$tree_prefix-after.tree"
  # 기준선 불변 검사: 워커가 worker-baseline.tree 를 바꾸면(예: 빈 tree) roots 아래 기존 파일이 전부 '피처가 만든 것'으로 보인다 (가드는 위에서 이미 기록)
  [ "$baseline_changed" -eq 0 ] \
    || stop_need_user SCOPE_BASELINE_CHANGED "워커 호출 중 worker-baseline.tree 가 변경됨(전: ${baseline_before:-없음} / 후: ${baseline_after:-없음}) — 자동 복구하지 않음. 파일을 원래 값으로 되돌리고 워커 변경을 확인한 뒤 재실행"
  violations="$(feature_scope_violations "$before_tree" "$after_tree" "$baseline_before")"
  if [ -n "$violations" ]; then
    log "[SCOPE_VIOLATION] 워커 호출 중 범위 밖 경로 변경 — 자동 원복하지 않음:"; printf '  %s\n' $violations
    stop_need_user SCOPE_VIOLATION "feature-scope.json 범위 밖 경로가 바뀜($(printf '%s' "$violations" | paste -sd, -)). 워커 과잉 변경이면 범위를 넓히거나 되돌릴지 사용자가 결정, 다른 세션 변경이면 보존. 자동 원복 금지"
  fi
  # unit 범위 검사: 전체 범위 안이라도 현재 unit 의 scope 밖이면 같은 규칙(같은 함수, manifest 만 unit scope)으로 위반이다 — 원복 없이 중단
  if [ -n "$unit_scope" ]; then
    violations="$(SCOPE_MANIFEST_OVERRIDE="$unit_scope" feature_scope_violations "$before_tree" "$after_tree" "$baseline_before")"
    if [ -n "$violations" ]; then
      log "[UNIT_SCOPE_VIOLATION] unit $unit_id 호출 중 unit scope 밖 경로 변경 — 자동 원복하지 않음:"; printf '  %s\n' $violations
      stop_need_user UNIT_SCOPE_VIOLATION "unit $unit_id 의 scope 밖 경로가 바뀜($(printf '%s' "$violations" | paste -sd, -)). 과잉 구현이면 되돌릴지, unit 분할이 잘못됐으면 implementation-units.json 을 고쳐 impl 재합의할지 사용자가 결정. 자동 원복 금지, 다음 unit 으로 가지 않음"
    fi
  fi
  # ---------- CLI/result 판정 (위 index → manifest → 기준선 → write-set 게이트를 모두 지난 뒤에만) ----------
  # raw rc 는 usage.jsonl 에 그대로 남는다. 호출 직전 $result 를 지웠으므로 지금 있는 $result 는 이번 invocation 의 산출물이다.
  #   rc≠0 + 유효한 결과 JSON(worker_result_valid: parse·필드 구조·DONE/UNDECIDED 모순) → CLI 종료코드 불일치로 기록하고 재실행 없이 계속
  #   rc≠0 + 결과 없음/깨짐 + 작업 트리 변화 없음 → 기존 실행 실패(재실행해도 같은 편집이 중복될 위험이 없다)
  #   rc≠0 + 결과 없음/깨짐 + 작업 트리 변화 있음 → WORKER_OUTCOME_UNCERTAIN 으로 중단, 가드 기록, 자동 원복·자동 재호출 없음
  if [ "$worker_rc" -ne 0 ]; then
    local worker_cli; worker_cli="$(role_cli WORKER)"
    if worker_result_valid "$result"; then
      log "[WARN] CLI_EXIT_STATUS_MISMATCH: WORKER $worker_cli exited $worker_rc, but current invocation produced a valid worker result ($result); continuing without replay"
      record_cli_anomaly WORKER "$worker_cli" "$tag-$stamp${unit_id:+ (unit $unit_id)}" "$worker_rc" STRUCTURED_RESULT "$result" || env_error "cli-anomalies.jsonl 기록 실패"
    elif [ "$after_tree" = "$before_tree" ]; then
      role_raw_diag_tail "$raw" >&2
      env_error "워커 실행 실패 (모델 '$WORKER_MODEL' 확인)"
    else
      record_worker_outcome_guard "$before_tree" "$after_tree" WORKER "$tag-$stamp${unit_id:+ (unit $unit_id)}" "$worker_rc" "$result" || env_error "worker-outcome 가드 기록 실패"
      role_raw_diag_tail "$raw" >&2
      stop_need_user WORKER_OUTCOME_UNCERTAIN "워커${unit_id:+ (unit $unit_id)} $worker_cli 가 exit $worker_rc 로 끝났고 유효한 결과 JSON($result)이 없는데 작업 트리는 바뀜(전: $before_tree / 후: $after_tree). 완료 여부를 알 수 없으므로 같은 워커를 자동 재호출하지 않고 변경도 원복하지 않음 — 사용자가 변경을 확인한 뒤 호출 전 tree 로 명시적으로 되돌리면 재실행 시 워커가 다시 돈다(worker-outcome.guard.json)"
    fi
  fi
  jq -e '.status' "$result" >/dev/null 2>&1 || env_error "워커 결과 JSON 이 스키마와 다름: $result"
  local status; status="$(jq -r '.status' "$result")"
  local n; n="$(jq '.undecided|length' "$result")"
  if { [ "$status" = DONE ] && [ "$n" -gt 0 ]; } || { [ "$status" = UNDECIDED ] && [ "$n" -eq 0 ]; }; then
    env_error "모순된 워커 결과: status=$status / undecided=$n"
  fi
  # ---------- 결과 수용: 모든 게이트(index·manifest·기준선·write-set)와 결과 계약 검사를 지난 뒤에만 ----------
  # 세션 확정은 어댑터 공용 role_session_accept 가 한다 — claude 는 .new 세션 ID 커밋, codex 는 원장 .new 확정 + resume marker 해제.
  # 워커는 세션 재사용이 계약이므로 수용 실패(codex thread.started 미확정 등)는 조용히 fresh 로 돌지 않고 명시적으로 멈춘다.
  # UNDECIDED 결과도 유효한 턴이다(사용자 결정 뒤 같은 세션이 이어 받는다) — 수용은 status 와 무관하게 여기서 한다.
  role_session_accept WORKER "$FEATURE_WORKER_SESSION" "$tag-$stamp${unit_id:+ (unit $unit_id)}" \
    || env_error "워커 세션 수용(role_session_accept) 실패 — 이번 호출의 세션을 확정하지 못했다(codex 면 thread.started.thread_id 미확정). 자동 fresh 전환 없음"
  # 수용 뒤 저널 갱신: claude 는 세션 ID 동기화(+결속), codex 는 결속 여부만 — thread_id 는 원장에만 둔다
  worker_session_sync_id || env_error "worker-session.json 세션 ID 동기화 실패"
  worker_session_mark_bound || env_error "worker-session.json 세션 결속(session_bound) 기록 실패"
  log "워커${unit_id:+ (unit $unit_id)} status: $status / undecided: $n / delegated_choices: $(jq '.delegated_choices|length' "$result")"
  jq -r '.undecided[]? | "  [UNDECIDED] \(.location): \(.decision_needed)"' "$result"
  if [ "$status" = UNDECIDED ]; then
    # DOC_GAP 이든 USER_DECISION 이든 구현 시점에 워커가 정할 권한이 없는 solution-shape 선택이다 — 둘 다 사용자 판단으로 간다(kind 는 진단 정보).
    # impl 재합의(검증자·디자이너)로 돌아가지 않는다: 체크포인트(doc-gap-resume.json, 이 호출 후 tree 포함)를 남기고 NEED_USER. 사용자가 답하면
    # 같은 워커(unit 이면 그 unit 부터, review-gap 이면 같은 리뷰로)가 바로 다시 돈다. 이 unit 은 완료 처리하지 않는다.
    doc_gap_record_worker "$result" "$unit_id" "${DOC_GAP_REVIEW:-}" "$after_tree" || env_error "doc-gap-resume.json 기록 실패"
    log "워커 미결정 항목 — 사용자 결정 필요:"; doc_gap_report
    stop_need_user UNDECIDED "워커${unit_id:+ (unit $unit_id)} 의 undecided 항목을 사용자에게 질문 → 답을 decisions.md 에 '- [USER-QUESTION][scope=impl][worker-gap=<key>] <질문> → <답>' 으로 기록 → approach.md 에 결정 반영 → 재실행(검증자·디자이너 없이 ${unit_id:+unit $unit_id 부터 }워커 재개). 항목: $(doc_gap_field '[.gaps[] | "[\(.key)] \(.question) (options: \(.options|join(" | ")); tag: \(.tag))"] | join(" ; ")')"
  fi
}

