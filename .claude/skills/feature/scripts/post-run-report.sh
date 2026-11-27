#!/usr/bin/env bash
# =============================================================
# DONE 뒤 사후 분석 보고서 — 비용·검증·실패 회고와 규칙 승격 "후보" (모델 호출 0회, 기존 기록의 결정론적 집계만)
# 파일 경로: .claude/skills/feature/scripts/post-run-report.sh   (source 전용 — feature-run.sh 가 로더·fast-check.sh 뒤에 읽는다)
#
# 산출물: $WORK_DIR/post-run-report.json 하나 —
#   {version, status:"DONE", source_fingerprint, generated_at, cost_summary, verification_summary, failure_analysis[], rule_candidates[]}
#
# 이 파일이 하는 일과 하지 않는 일:
#   - 읽기만 한다: usage.jsonl(+ scripts/lib/telemetry.sh usage_summary 의 같은 숫자), run-state.json, fast-check/·units/<id>/unit-check/·risk-verify/ 의 history.jsonl,
#     units/<id>/targeted-test.history.jsonl, reviews/verify.history.jsonl, reviews/impl-attempt-*/reviewer-round-*.json, cli-anomalies.jsonl.
#     그 파일들을 다시 쓰거나 지우지 않고, 프로덕션 코드·git index·계약 문서·승인 지문을 건드리지 않는다. 쓰는 파일은 보고서 하나뿐이다.
#   - 멱등: 유효한 보고서가 이미 있고 source_fingerprint(승인 지문)가 같으면 다시 만들지 않는다. generated_at 은 벽시계가 아니라 DONE 기록 시각이라
#     보고서를 치우고 다시 만들어도 같은 입력이면 같은 내용이 나온다(비용·이슈가 두 번 세어지지 않는다 — 매번 원본 기록에서 처음부터 집계한다).
#   - 실패해도 DONE 을 바꾸지 않는다: 호출자(post_run_report_ensure)가 경고와 진단 파일만 남긴다.
#   - 손상된 기록을 조용히 빼고 완전한 기록처럼 집계하지 않는다: JSON 객체로 읽을 수 없는 줄은 파일별로 세어 record_integrity 에 남기고(complete:false),
#     그 기록에서 나온 집계(verification_summary 의 각 항목·cost_summary)에 corrupt_records 를 붙인다. 손상(기록은 있었는데 읽지 못함)과 미관측(기록 자체가 없음)은 다르다.
#   - 관측되지 않은 값은 0 이 아니라 null/observed:false 다. 실행하지 않은 LLM 호출의 비용(반사실적 절감액)은 계산하지 않는다(unknown).
#   - 근본 원인을 지어내지 않는다: failure_analysis 의 candidate_cause 는 후보 분류일 뿐이고 root_cause 는 직접 증거가 없으면 "UNKNOWN" 이다.
#   - rule_candidates 는 후보 제시까지다. auto_promote 는 항상 false — 코드·conventions·검사 규칙을 고치는 것은 사용자가 고른 별도 작업이다.
#     후보는 '같은 오류'라는 근거가 기록에 있을 때만 만든다: 같은 규칙 id(진단 줄 맨 앞의 "[rule-id]")가 서로 다른 검사 실행에서 반복됐거나,
#     리뷰어가 같은 근거(basis_refs[0])로 서로 다른 issue 를 냈거나, 같은 issue 가 수정 뒤에도 남았을 때(UNRESOLVED_PREVIOUS). 같은 category 가 여러 번 나왔다는
#     것만으로는 만들지 않는다. 단일 Feature 의 기록만 보므로 Feature 간 반복 여부는 항상 "unverified" 다(전역 오류 DB 없음).
# =============================================================

POST_RUN_REPORT="$WORK_DIR/post-run-report.json"
POST_RUN_REPORT_VERSION=1

_prr_jsonl() { # file... → JSON 객체로 읽히는 줄만 모은 배열. 읽지 못한 줄은 버리는 것이 아니라 _prr_corrupt 가 따로 센다(없는 파일 = 미관측)
  local f
  { for f in "$@"; do [ ! -f "$f" ] || cat "$f"; done; } | jq -R 'fromjson? | objects' | jq -cs '.'
}
_prr_corrupt() { # source file... → [{source, file, corrupt_lines}] — 비어 있지 않은데 JSON 객체로 읽을 수 없는 줄이 있는 파일만
  local source="$1" f n; shift
  for f in "$@"; do
    [ -f "$f" ] || continue
    n="$(jq -R 'select(length > 0) | (try (fromjson | type) catch "unreadable") | select(. != "object")' "$f" | grep -c . || true)"
    [ "${n:-0}" -eq 0 ] || jq -nc --arg source "$source" --arg f "$f" --argjson n "$n" '{source:$source, file:$f, corrupt_lines:$n}'
  done | jq -cs '.'
}
_prr_reviews() { # 리뷰어 출력(실제 호출분) → [{file, attempt, round, verdict, issues[]}]
  local f
  for f in "$WORK_DIR"/reviews/impl-attempt-*/reviewer-round-*.json; do
    [ -f "$f" ] || continue
    jq -c --arg f "$f" 'select(type=="object" and (.verdict|type=="string")) | {file:$f,
        attempt:($f | capture("impl-attempt-(?<a>[0-9]+)") | .a | tonumber), round:($f | capture("reviewer-round-(?<r>[0-9]+)") | .r | tonumber),
        verdict, issues:[(.issues // [])[] | {id, category, action, origin, basis_refs:(.basis_refs // []), code_refs:(.code_refs // [])}]}' "$f" 2>/dev/null || true
  done | jq -cs '.'
}
# 위반 진단의 규칙 id: 진단 줄 맨 앞의 "[rule-id]" 만 쓴다(프로젝트 검사기의 출력 형식을 추측해 파싱하지 않는다 — 이 형식이 없으면 공통성 미확인으로 남는다).
_prr_rule_signatures() { # source history.jsonl... → [{source, unit_id, seq, log, rule}]
  local source="$1" hist row log; shift
  for hist in "$@"; do
    [ -f "$hist" ] || continue
    while IFS= read -r row; do
      log="$(jq -r '.log' <<< "$row")"
      [ -f "$log" ] || continue
      grep -oE '^\[[A-Za-z0-9_.:/-]+\]' "$log" 2>/dev/null | sort -u | jq -R --arg source "$source" --argjson r "$row" \
        '{source:$source, unit_id:($r.unit_id // null), seq:$r.seq, log:$r.log, rule:.}'
    done < <(jq -R 'fromjson? | objects' "$hist" | jq -c 'select(.status=="VIOLATION")')
  done | jq -cs '.'
}

post_run_report_write() { # 성공하면 0(새로 만들었으면 한 줄 요약 출력, 이미 있으면 무출력), 실패하면 1(사유는 stderr)
  local state="$WORK_DIR/run-state.json" fp="" done_at
  jq -e '.status=="DONE"' "$state" >/dev/null 2>&1 || { echo "run-state.json 이 DONE 이 아니다 — 사후 분석은 DONE 뒤에만 만든다" >&2; return 1; }
  [ ! -f "$WORK_DIR/approved.fingerprint" ] || fp="$(cat "$WORK_DIR/approved.fingerprint")" || return 1
  if [ -f "$POST_RUN_REPORT" ] && jq -e --argjson v "$POST_RUN_REPORT_VERSION" --arg fp "$fp" \
       '.version==$v and .status=="DONE" and (.source_fingerprint // "")==$fp' "$POST_RUN_REPORT" >/dev/null 2>&1; then
    return 0
  fi
  done_at="$(jq -r '.updated_at // ""' "$state")" || return 1

  local usage_rows usage_sum unit_checks tests fast risk verify reviews units verify_labels signatures corrupt anomalies=0 usage_clean
  local unit_hist=() test_hist=() d
  for d in "$WORK_DIR"/units/*/; do
    [ -d "$d" ] || continue
    unit_hist+=("${d}unit-check/history.jsonl"); test_hist+=("${d}targeted-test.history.jsonl")
  done
  usage_rows="$(_prr_jsonl "$WORK_DIR/usage.jsonl")" || return 1
  # scripts/lib/telemetry.sh usage_summary — 종료 보고·usage-summary.json 과 같은 함수(숫자를 따로 계산하지 않는다). 그 함수는 파일 전체를 한 번에 파싱하므로 읽을 수 없는 줄이
  # 하나라도 있으면 실패한다 — 그때는 읽힌 줄만 담은 임시 사본으로 같은 함수를 부르고, 빠진 줄은 아래 record_integrity·cost_summary 가 드러낸다(0 달러로 세지 않는다).
  if [ "$(_prr_corrupt usage "$WORK_DIR/usage.jsonl" | jq 'length')" -gt 0 ]; then
    usage_clean="$POST_RUN_REPORT.usage.tmp"
    jq -c '.[]' <<< "$usage_rows" > "$usage_clean" || return 1
    usage_sum="$(usage_summary "$usage_clean")" || { rm -f "$usage_clean"; return 1; }
    rm -f "$usage_clean"
  else
    usage_sum="$(usage_summary)" || return 1
  fi
  unit_checks="$(_prr_jsonl ${unit_hist[@]+"${unit_hist[@]}"})" || return 1
  tests="$(_prr_jsonl ${test_hist[@]+"${test_hist[@]}"})" || return 1
  fast="$(_prr_jsonl "$WORK_DIR/fast-check/history.jsonl")" || return 1
  risk="$(_prr_jsonl "$WORK_DIR/risk-verify/history.jsonl")" || return 1
  verify="$(_prr_jsonl "$WORK_DIR/reviews/verify.history.jsonl")" || return 1
  reviews="$(_prr_reviews)" || return 1
  corrupt="$( { _prr_corrupt usage "$WORK_DIR/usage.jsonl"; _prr_corrupt unit_check ${unit_hist[@]+"${unit_hist[@]}"}; _prr_corrupt targeted_test ${test_hist[@]+"${test_hist[@]}"}
                _prr_corrupt fast_check "$WORK_DIR/fast-check/history.jsonl"; _prr_corrupt risk_verify "$WORK_DIR/risk-verify/history.jsonl"
                _prr_corrupt final_verify "$WORK_DIR/reviews/verify.history.jsonl"; } | jq -cs 'add // []')" || return 1
  units='[]'; [ ! -f "$WORK_DIR/implementation-units.lock.json" ] || units="$(jq -c '[.units[].id]' "$WORK_DIR/implementation-units.lock.json")" || return 1
  # verify 단계의 worker-fix(최종 테스트·위험도 검증 실패 수정)는 unit 워커 턴과 label 접두(worker-)가 같다 — 원문 로그가 reviews/ 에 있는 것으로 구분한다
  verify_labels="$( { for d in "$WORK_DIR"/reviews/worker-*.log; do [ -f "$d" ] || continue; basename "$d" .log; done; } | jq -R . | jq -cs '.')" || return 1
  signatures="$( { _prr_rule_signatures unit_check ${unit_hist[@]+"${unit_hist[@]}"}; _prr_rule_signatures fast_check "$WORK_DIR/fast-check/history.jsonl"
                   _prr_rule_signatures risk_verify "$WORK_DIR/risk-verify/history.jsonl"; } | jq -cs 'add // []')" || return 1
  [ ! -f "$WORK_DIR/cli-anomalies.jsonl" ] || anomalies="$(grep -c . "$WORK_DIR/cli-anomalies.jsonl" || true)"

  jq -n --argjson v "$POST_RUN_REPORT_VERSION" --arg fp "$fp" --arg done_at "$done_at" \
    --argjson usage "$usage_rows" --argjson sum "$usage_sum" --argjson unit_checks "$unit_checks" --argjson tests "$tests" --argjson fast "$fast" \
    --argjson risk "$risk" --argjson verify "$verify" --argjson reviews "$reviews" --argjson units "$units" --argjson verify_labels "$verify_labels" \
    --argjson signatures "$signatures" --argjson corrupt "$corrupt" --argjson anomalies "${anomalies:-0}" --slurpfile state "$state" \
    --argjson unit_check_on "$(unit_check_configured && echo true || echo false)" --argjson fast_check_on "$(fast_check_configured && echo true || echo false)" \
    --argjson risk_on "$(risk_verify_configured && echo true || echo false)" '
    # 비용 지표는 usage_summary 와 같은 정의다: reported = Σ cost_usd(provider 보고), estimated = Σ estimated_cost_usd(가격표 환산), 둘 다 null 인 행은 unknown(0 달러 아님)
    def cost(rows): {
      invocations: (rows | length),
      reported_cost_usd: (rows | map(.cost_usd // 0) | add // 0),
      estimated_cost_usd: (rows | map(.estimated_cost_usd // 0) | add // 0),
      combined_cost_usd_estimate: (rows | map((.cost_usd // 0) + (.estimated_cost_usd // 0)) | add // 0),
      cost_unknown_invocations: (rows | map(select(.cost_usd == null and .estimated_cost_usd == null)) | length)
    };
    def pick_cost: {invocations, reported_cost_usd, estimated_cost_usd, combined_cost_usd_estimate, cost_unknown_invocations};
    def tally(rows): {runs: (rows | length), pass: (rows | map(select(.status=="PASS")) | length), violation: (rows | map(select(.status=="VIOLATION")) | length),
                      error: (rows | map(select(.status=="ERROR")) | length), needs_user: (rows | map(select(.status=="NEEDS_USER")) | length)};
    def secs(rows): (rows | map(.duration_sec // 0) | add // 0);
    def bad(src): ($corrupt | map(select(.source==src) | .corrupt_lines) | add // 0);
    ($state[0]) as $st
    | ($usage | map(select(.role=="WORKER"))) as $w
    | ($w | map(select((.label // "") | startswith("test-fix-")))) as $unit_fix
    | ($w | map(select((.label // "") | startswith("check-fix-")))) as $check_fix
    | ($w | map(select((.label // "") | startswith("review-gap-")))) as $gap_fix
    | ($w | map(select((.label // "") as $l | ($verify_labels | index($l)) != null))) as $verify_fix
    | ($usage | map(select(.role=="REVIEWER"))) as $rv
    | ($reviews | map(select(.verdict=="REQUEST_CHANGES"))) as $rc
    | ([$rc[] | . as $r | .issues[] | . + {file:$r.file, attempt:$r.attempt, round:$r.round}]) as $issues
    | ($st.history // []) as $hist
    | ($tests | map(select(.status=="FAIL"))) as $test_fail
    | ($verify | map(select(.status=="FAIL"))) as $verify_fail
    | (($unit_checks + $fast + $risk) | map(select(.status=="ERROR"))) as $check_errors
    | ($hist | map(select(.status=="NEED_USER")) | group_by(.reason) | map({reason: .[0].reason, count: length})) as $need_user
    | {
        version: $v, status: "DONE",
        source_fingerprint: (if $fp == "" then null else $fp end),
        generated_at: (if $done_at == "" then null else $done_at end),
        generated_at_note: "DONE 기록 시각(run-state.json) — 같은 입력으로 다시 만들어도 같은 값이다",
        record_integrity: {
          complete: (($corrupt | length) == 0), corrupt: $corrupt,
          note: (if ($corrupt | length) == 0 then "집계에 쓴 실행 기록(JSONL)의 모든 줄을 읽었다. 기록 자체가 없는 항목은 손상이 아니라 미관측이다(각 항목의 observed·runs 참고)"
                 else "읽을 수 없는 기록 줄이 있다 — 아래 집계는 읽힌 줄만 센 것이고 완전한 기록이 아니다(해당 항목의 corrupt_records > 0). 누락된 실행이 통과·실패 어느 쪽인지 추정하지 않는다" end)
        },
        cost_summary: {
          source: "usage.jsonl — 러너가 띄운 child CLI invocation 만(대화형 오케스트레이터 자체 비용은 범위 밖). usage_summary 와 같은 집계",
          observed: (if ($usage | length) == 0 then null
                     else ($sum | {invocations, reported_cost_usd, estimated_cost_usd, combined_cost_usd_estimate, cost_unknown_invocations, usage_unobserved_invocations, pricing_bases}) end),
          # usage.jsonl 의 읽을 수 없는 줄 = 호출은 있었는데 비용·횟수를 읽지 못한 것. 그때 이 절의 모든 합계·횟수는 읽힌 줄만 센 하한값이다(빠진 줄을 0 달러로 더한 값이 아니다)
          unreadable_usage_records: bad("usage"),
          totals_are_lower_bound: (bad("usage") > 0),
          by_role: (($sum.by_role // {}) | map_values(pick_cost)),
          by_model: (($sum.by_model // {}) | map_values(pick_cost)),
          worker_fix_turns: {
            unit_fix: cost($unit_fix), fast_check_fix: cost($check_fix), verify_fix: cost($verify_fix), review_gap: cost($gap_fix),
            total: cost($unit_fix + $check_fix + $verify_fix + $gap_fix),
            note: "unit_fix = unit 의 targeted test 실패·Unit 정적 검사 위반 수정 턴(한 턴이 둘을 함께 고친다) / verify_fix = 최종 테스트·위험도 검증 실패 수정 턴"
          },
          reviewer: (cost($rv) + {re_invocations: ([($rv | length) - 1, 0] | max), re_invocation_cost: (cost($rv[1:]) | del(.invocations))}),
          fixer: cost($usage | map(select(.role=="FIXER"))),
          model_invocations_total: ($usage | length),
          corrupt_records: bad("usage"),
          duration: {
            model_invocation_ms_observed: ($usage | map(.duration_ms // 0) | add // 0),
            model_invocation_duration_unobserved: ($usage | map(select(.duration_ms == null)) | length),
            deterministic_verification_sec: (secs($unit_checks) + secs($tests) + secs($fast) + secs($risk) + secs($verify)),
            first_recorded_at: ($hist | first | .at // null), done_at: (if $done_at == "" then null else $done_at end),
            note: "first_recorded_at → done_at 은 사용자 대기 시간을 포함한다. 실행 기록이 없는 구간의 시간은 0 이 아니라 미관측이다"
          },
          cost_note: (($sum.cost_note // (if bad("usage") > 0 then "usage.jsonl 에 읽을 수 있는 줄이 없음 — 비용 미관측(0 달러 아님)" else "usage.jsonl 없음 — 비용 미관측(0 달러 아님)" end))
                      + " / CLI 구독 사용량과 API 환산 추정 비용은 같은 값이 아니다"
                      + (if bad("usage") > 0 then " / usage.jsonl 에 읽을 수 없는 줄 \(bad("usage"))개 — 그 호출의 비용·횟수는 미관측이고 위 합계는 읽힌 줄만의 하한값이다" else "" end)),
          counterfactual_savings: {
            usd: null, status: "unknown",
            note: "기계적 검증이 막은 지점의 횟수만 관측값이다. 그때 실행되지 않은 LLM 호출의 비용은 관측할 수 없으므로 절감액을 계산하지 않는다",
            blocked_before_llm_review: {
              unit_check_violations: ($unit_checks | map(select(.status=="VIOLATION")) | length),
              fast_check_violations: ($fast | map(select(.status=="VIOLATION")) | length),
              risk_verify_violations: ($risk | map(select(.status=="VIOLATION")) | length)
            }
          }
        },
        verification_summary: {
          unit: {
            units: ($units | length),
            unit_check: (tally($unit_checks) + {configured: $unit_check_on, corrupt_records: bad("unit_check"),
              by_unit: [$units[] as $id | ($unit_checks | map(select(.unit_id==$id))) as $r
                | {unit_id: $id, runs: ($r | length), violations: ($r | map(select(.status=="VIOLATION")) | length),
                   final_status: (if ($r | length) == 0 then "SKIPPED" else ($r | last | .status) end)}]}),
            targeted_test: (if ($tests | length) == 0 then {observed: false, corrupt_records: bad("targeted_test"),
                                  note: (if bad("targeted_test") > 0 then "실행 기록이 있으나 읽을 수 있는 줄이 없다 — 0 회가 아니라 손상" else "실행 기록 없음(이 기록이 생기기 전의 실행) — 0 회가 아니라 미관측" end)}
                            else {observed: true, corrupt_records: bad("targeted_test"), runs: ($tests | length), failures: ($test_fail | length),
                                  by_unit: [$units[] as $id | ($tests | map(select(.unit_id==$id))) as $r | select(($r | length) > 0)
                                    | {unit_id: $id, runs: ($r | length), failures: ($r | map(select(.status=="FAIL")) | length)}]} end),
            fix_turns: ($unit_fix | length)
          },
          feature: {
            fast_check: (tally($fast) + {configured: $fast_check_on, corrupt_records: bad("fast_check"), fix_turns: ($st.fast_check_retries // 0)}),
            review: {attempts: ($reviews | map(.attempt) | unique | length), reviewer_outputs: ($reviews | length),
                     approve: ($reviews | map(select(.verdict=="APPROVE")) | length), request_changes: ($rc | length), issues: ($issues | length),
                     invalid_output_stops: ($hist | map(select(.reason=="REVIEW_OUTPUT_INVALID")) | length)},
            risk_verify: (tally($risk) + {configured: $risk_on, corrupt_records: bad("risk_verify"),
              last: (if ($risk | length) == 0 then null else ($risk | last | {status, kind, risk_level, needs_human, checks, log}) end),
              note: "실행 기록이 없으면 위험도는 판정되지 않은 것이다(LOW 가 아니다)"}),
            final_verify: (if ($verify | length) == 0 then {observed: false, corrupt_records: bad("final_verify"), fix_budget_used: ($st.test_retries // 0),
                                 note: (if bad("final_verify") > 0 then "실행 기록이 있으나 읽을 수 있는 줄이 없다 — 0 회가 아니라 손상" else "실행 기록 없음 — 0 회가 아니라 미관측" end)}
                           else {observed: true, corrupt_records: bad("final_verify"), runs: ($verify | length), failures: ($verify_fail | length), fix_budget_used: ($st.test_retries // 0)} end)
          }
        },
        failure_analysis: ([
          (select(($test_fail | length) > 0) | {type: "UNIT_TEST_FAILURE", count: ($test_fail | length), evidence: ($test_fail | map(.log) | unique),
            candidate_cause: (if ($test_fail | group_by(.unit_id) | any(length > 1)) then "같은 unit 의 targeted test 가 수정 뒤에도 실패 — 구현 계약 불일치 가능성(실패 내용의 동일성은 확인하지 않았다)" else null end)}),
          (($unit_checks | map(select(.status=="VIOLATION"))) as $x | select(($x | length) > 0)
            | {type: "UNIT_CHECK_VIOLATION", count: ($x | length), evidence: ($x | map(.log) | unique), candidate_cause: "구현 중 해당 규칙 확인 누락 가능성"}),
          (($fast | map(select(.status=="VIOLATION"))) as $x | select(($x | length) > 0)
            | {type: "FAST_CHECK_VIOLATION", count: ($x | length), evidence: ($x | map(.log) | unique), candidate_cause: "unit 단계에서 걸리지 않은 규칙(전역 규칙이거나 Unit 정적 검사에 연결되지 않음) 가능성"}),
          (select(($issues | length) > 0) | {type: "REVIEW_ISSUE", count: ($issues | length), evidence: ($issues | map(.file) | unique),
            by_category: ($issues | group_by(.category) | map({category: .[0].category, count: length})), candidate_cause: null}),
          (($issues | map(select(.category=="SECURITY_OR_DATA_RISK"))) as $x | select(($x | length) > 0)
            | {type: "SECURITY_OR_DATA_RISK", count: ($x | length), evidence: ($x | map("\(.file)#\(.id)") | unique), candidate_cause: null}),
          (($risk | map(select(.status=="VIOLATION"))) as $x | select(($x | length) > 0)
            | {type: "RISK_VERIFY_VIOLATION", count: ($x | length), evidence: ($x | map(.log) | unique), risk_levels: ($x | map(.risk_level) | unique), candidate_cause: null}),
          (select(($verify_fail | length) > 0) | {type: "FINAL_VERIFY_FAILURE", count: ($verify_fail | length), evidence: ($verify_fail | map(.log) | unique), candidate_cause: null}),
          (([($unit_fix | length), ($check_fix | length), ($verify_fix | length)] | map(select(. > 1)) | length) as $n | select($n > 0)
            | {type: "REPEATED_WORKER_FIX", count: (($unit_fix + $check_fix + $verify_fix) | length), evidence: (($unit_fix + $check_fix + $verify_fix) | map(.label)), candidate_cause: null}),
          ((($hist | map(select(.status=="ENV_ERROR")) | length) + ($check_errors | length) + $anomalies) as $n | select($n > 0)
            | {type: "ENVIRONMENT_ERROR", count: $n, evidence: ($check_errors | map(.log) | unique),
               detail: {env_error_stops: ($hist | map(select(.status=="ENV_ERROR")) | length), check_execution_errors: ($check_errors | map({kind, log})), cli_exit_anomalies: $anomalies},
               candidate_cause: "실행 환경 문제(도구·CLI·검사 어댑터)"}),
          (($hist | map(select(.reason=="REVIEW_OUTPUT_INVALID")) | length) as $n | select($n > 0)
            | {type: "REVIEW_OUTPUT_INVALID", count: $n, evidence: ["reviews/invalid-review.json"], candidate_cause: "리뷰어 출력 계약 또는 검사기 문제"}),
          (select(($need_user | length) > 0) | {type: "USER_INTERVENTION", count: ($need_user | map(.count) | add), by_reason: $need_user, evidence: ["run-state.json#history"], candidate_cause: null})
        ] | map(. + {root_cause: "UNKNOWN", confirmed: false})),
        rule_candidates: ([
          # ① 같은 규칙 id 가 서로 다른 검사 실행에서 반복
          [$signatures | group_by([.source, .rule])[] | select((map([.unit_id, .seq]) | unique | length) > 1)
            | (map([.unit_id, .seq]) | unique | length) as $n | .[0] as $f
            | {observed_error: "\($f.source) 규칙 \($f.rule) 위반",
               repetition_evidence: {basis: "같은 규칙 id 가 서로 다른 검사 실행 \($n)회의 진단에 나옴", occurrences: $n},
               related: (map(.log) | unique)}
              + (if $f.source == "fast_check" then {recommended_type: "STATIC_CHECK", automatable: "yes — 이미 결정론적 검사로 검출된다. Unit 단계(UNIT_CHECK_CMD)로 앞당길 수 있는지 검토", false_positive_risk: "low — 기존 규칙의 실행 시점만 바뀐다"}
                 elif $f.source == "unit_check" then {recommended_type: "CODEBASE_CONSTRAINT", automatable: "unknown — 구조로 위반 자체를 만들 수 없게 할 수 있는지는 사람이 판단(불가능하면 지금의 정적 검사 유지)", false_positive_risk: "unknown"}
                 else {recommended_type: "RUNTIME_TEST", automatable: "unknown — unit targeted test·TEST_CMD 로 앞당길 수 있는지 검토", false_positive_risk: "unknown"} end)],
          # ② 리뷰어가 같은 근거(basis_refs[0])로 서로 다른 issue 를 냄
          [$issues | map(select(.origin=="ROUND_1" and (.basis_refs | length) > 0)) | group_by([.category, .basis_refs[0]])[]
            | select((map([.attempt, .id]) | unique | length) > 1) | .[0] as $f
            | {observed_error: "리뷰 issue \($f.category) — 근거 \($f.basis_refs[0])",
               repetition_evidence: {basis: "같은 category·같은 근거로 서로 다른 issue \(map([.attempt, .id]) | unique | length)건", occurrences: (map([.attempt, .id]) | unique | length)},
               related: (map("\(.file)#\(.id)") | unique)}
              + (if ($f.basis_refs[0] | test("conventions\\.md")) then {recommended_type: "STATIC_CHECK", automatable: "unknown — 그 컨벤션 규칙이 기계적으로 판정 가능한지 사람이 확인", false_positive_risk: "unknown"}
                 else {recommended_type: "LLM_REVIEW_REQUIRED", automatable: "no — 합의 문서 기준의 판정", false_positive_risk: "n/a"} end)],
          # ③ 같은 issue 가 수정 뒤에도 남음
          [$issues | map(select(.origin=="UNRESOLVED_PREVIOUS")) | group_by([.attempt, .id])[] | .[0] as $f
            | {observed_error: "리뷰 issue \($f.id)(\($f.category))가 수정 뒤에도 해결되지 않음",
               repetition_evidence: {basis: "리뷰어가 같은 issue id 를 UNRESOLVED_PREVIOUS 로 다시 보고", occurrences: (length + 1)},
               related: (map("\(.file)#\(.id)") | unique),
               recommended_type: "NEEDS_HUMAN_ANALYSIS", automatable: "unknown", false_positive_risk: "unknown"}]
        ] | add | map(. + {auto_promote: false, cross_feature_repetition: "unverified — 이 Feature 의 기록만 사용했다"}))
      }' > "$POST_RUN_REPORT.tmp" || return 1
  mv "$POST_RUN_REPORT.tmp" "$POST_RUN_REPORT" || return 1
  printf '사후 분석 보고서: %s — 실패 유형 %s종, 규칙 개선 후보 %s건(자동 승격·자동 수정 없음 — 개선은 사용자가 고른 별도 작업으로)%s' "$POST_RUN_REPORT" \
    "$(jq '.failure_analysis | length' "$POST_RUN_REPORT")" "$(jq '.rule_candidates | length' "$POST_RUN_REPORT")" \
    "$(jq -r 'if .record_integrity.complete then "" else " — [주의] 읽을 수 없는 실행 기록 \(.record_integrity.corrupt | map(.corrupt_lines) | add)줄: 집계가 완전하지 않다(record_integrity)" end' "$POST_RUN_REPORT")"
}
