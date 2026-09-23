#!/usr/bin/env bash
# =============================================================
# 워커 호출 — feature-run.sh 가 source 하는 공용 함수 (실행 파일이 아니다)
# 파일 경로: .claude/skills/feature/scripts/worker-invoke.sh
#
# run_worker 는 원래 feature-run.sh 안의 인라인 함수였고 본문은 그대로다. 파일만 분리한 이유는 하나 —
# tests/worker-regression.sh 가 검증자·리뷰어·수정자 없이 **production 워커 호출 경로 그대로**(프롬프트 조립·WORKER_RULES·
# REFERENCE CODE·implementation-context·스키마·WORKER_MODEL/EFFORT·CLI 라우팅·usage 기록·사후 게이트)를 1회 호출해
# 실제 WORKER_MODEL 의 code-spec 충실도를 재기 위해서다. 테스트용 별도 워커 구현·프롬프트·CLI 인자 복제는 없다.
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
# 세션: 전체 호출은 worker, unit 호출은 worker-unit-<id> — unit 마다 fresh 세션이며 이전 unit 의 문맥을 잇지 않는다(잇는 것은 worktree 뿐).
run_worker() { # prompt-file [unit-dir]
  local prompt_file="$1" unit_dir="${2:-}" tag="${RUN_TAG:-worker}"
  local prompt worker_rules result out_dir tree_prefix unit_json="" unit_id="" unit_scope="" session
  if [ -n "$unit_dir" ]; then
    unit_json="$(cat "$unit_dir/unit.json")" && unit_id="$(jq -er '.id' "$unit_dir/unit.json")" || env_error "unit.json 읽기 실패: $unit_dir"
    out_dir="$unit_dir"; result="$unit_dir/$tag-result.json"; tree_prefix="$unit_dir/$tag"; unit_scope="$unit_dir/scope.json"
    session="worker-unit-$unit_id"
  elif [ "$tag" = worker ]; then
    out_dir="$WORK_DIR/reviews"; result="$WORKER_RESULT"; tree_prefix="$WORK_DIR/worker"; session=worker
  else
    # 전체 호출이지만 다른 RUN_TAG(review-gap): 결과·tree 를 태그 이름으로 남겨 unit 결과를 합친 worker-result.json 을 덮어쓰지 않는다
    out_dir="$WORK_DIR/reviews"; result="$WORK_DIR/$tag-result.json"; tree_prefix="$WORK_DIR/$tag"; session="$tag"
  fi
  # 직전 실행이 기준선 변조로 멈췄으면 복구 전에는 워커를 부르지 않는다(변조된 값을 새 기준선으로 읽는 재실행 우회 차단)
  require_baseline_guard_resolved \
    || stop_need_user SCOPE_BASELINE_CHANGED "worker-baseline.tree 가 직전 중단 시점의 기대값($(jq -r .expected "$BASELINE_GUARD"))으로 복구되지 않음 — 되돌린 뒤 재실행. 자동 복구 없음"
  # 직전 워커 호출 결과가 불확실한 채 남은 변경 위에 같은 워커를 다시 부르지 않는다(사용자가 호출 전 tree 로 복구한 뒤에만)
  require_worker_outcome_guard_resolved \
    || stop_need_user WORKER_OUTCOME_UNCERTAIN "직전 워커 호출($(jq -r '.label' "$WORKER_OUTCOME_GUARD"))의 완료 여부가 불확실한데 작업 트리가 호출 전 tree($(jq -r '.expected' "$WORKER_OUTCOME_GUARD"))로 복구되지 않음 — 되돌린 뒤 재실행. 자동 원복·자동 재호출 없음"
  # 환경 변수 대입 안의 command substitution 실패는 뒤의 render_prompt 가 성공하면 묻힌다 — 먼저 별도 변수로 받아 실패를 확정한다
  worker_rules="$(load_worker_rules)" || env_error "워커 규칙 또는 필수 워커 스킬(WORKER_SKILLS) 로드 실패 — 워커를 실행하지 않음"
  # unit 호출: run_unit 이 워커 호출 전에 갱신한 implementation-context.json(앞 unit 확정 사실)을 그대로 넣는다 — test-fix 도 같은 파일(확정 전 상태)
  local impl_context=""
  if [ -n "$unit_dir" ]; then impl_context="$(cat "$IMPL_CONTEXT_FILE")" || env_error "implementation-context.json 읽기 실패"; fi
  # REVIEW_FILE / GAP_CONTEXT 는 review-gap 호출(worker-review-gap.md)에서만 채워진다 — 다른 템플릿에는 그 변수가 없다
  prompt="$(WORKER_RULES="$worker_rules" REFERENCE_CODE="$(load_reference_code)" WORK_DIR="$WORK_DIR" TEST_CMD="$TEST_CMD" TEST_LOG="${TEST_LOG:-}" \
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

