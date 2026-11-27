#!/usr/bin/env bash
# =============================================================
# .claude/skills/feature/scripts/lib/telemetry.sh
# usage.jsonl 기록·요금표·비용 추정·usage_summary·usage_cost_report_line.
# scripts/lib/bootstrap.sh 가 정해진 순서로 source 한다 — 직접 실행하지 않는다.
# (분리 전 config.sh 기준 2599–3042)
# =============================================================

# =============================================================
# usage telemetry — $WORK_DIR/usage.jsonl
#   한 행 = CLI invocation 한 번의 관측값(세션 누계 아님). 같은 session 이 여러 행에 나와도 각 행은 독립된 실행 결과다.
#   writer 는 append-only 원시 기록만 한다 — session 별 delta·누적 total·가격 추정은 하지 않는다(집계는 usage_summary 참고).
#   null = "관측 불가"(0 이 아님).
#   input_effective = input_uncached + cache_read + cache_write — 진단용 파생값이지 provider billing 공식 필드가 아니다.
#   cache_read 는 invocation 안의 model turn 들에서 읽힌 cache 누계일 수 있으므로 num_turns 와 함께 해석한다.
#   input_per_turn = floor(input_effective / num_turns) — 턴당 평균 입력, 컨텍스트 점유량의 근사치(context_last_turn 이 null 일 때의 대체값). num_turns 없으면 null.
#   context_last_turn = 그 invocation 의 마지막 model 호출이 실제로 넣은 입력(claude: stream-json 마지막 assistant usage 합, codex: rollout 마지막 token_count.last_token_usage.input_tokens,
#     native Agent: 전사의 마지막 본 모델 호출 입력 — 출처는 context_source(last_message_iteration | last_request_usage), 비용 관측 판정(usage_observation_status)과 따로 검증한다).
#     = 그 시점의 컨텍스트 창 점유량. 세션 교체 판단은 이 값을 먼저 쓴다. context_window = 모델 창 크기(claude: result.modelUsage[<워커 모델>].contextWindow — 보조 모델 항목이 섞여 오므로 워커 모델 키 우선, codex: model_context_window).
#   CLI 종료 성공/실패와 무관하게 파싱 가능한 telemetry 가 있으면 기록한다(exit_code/success). 파싱 불가면 WARN 후 생략 —
#   telemetry 는 best effort 이며 파싱 실패로 작업을 실패시키거나 같은 유료 invocation 을 재실행하지 않는다.
#   비용 필드는 provenance 로 나눈다(섞지 않는다):
#     cost_usd           = provider 가 직접 보고한 비용(claude total_cost_usd). codex 는 항상 null.
#     estimated_cost_usd = 토큰 관측값 × 명시적 가격표(codex_model_pricing) 추정치. claude 는 null. 가격표에 없는 모델은 null.
#     cost_kind          = reported | estimated | unknown,  pricing_basis = 추정에 쓴 가격표 기준(estimated 일 때만).
#   codex(v3): `codex exec --json` 이벤트 JSONL 의 turn.completed.usage 를 invocation 안에서 합산한다 —
#     input_total=Σinput_tokens(cached 포함), cache_read=Σcached_input_tokens, cache_write=Σcache_write_input_tokens, output=Σoutput_tokens,
#     reasoning_output=Σreasoning_output_tokens(output 의 부분집합 — total/cost 에 다시 더하지 않음), num_turns=turn.completed 개수.
#     input_uncached = input_total − cache_read − cache_write (진단 partition), input_effective = 그 셋의 합 = input_total, tokens_total = input_total + output.
#   schema_version 3: codex 행에 input/cache/output/reasoning_output/num_turns 채움, cost_kind/estimated_cost_usd/pricing_basis 추가. usage_summary 는 v2·legacy 행도 읽는다.
#   schema_version 4 [Modified]: codex 추정 수식을 (uncached×input + cache_read×cached + cache_write×cache_write_rate + output×output)/1M 으로 바꾸고
#     turn 단위로 가격 구간(단문/장문)을 고른다. pricing_assumptions(판단 불가 과금 조건을 명시한 가정 목록)·long_context_turns 추가.
#     v3 까지는 cache_write 토큰을 일반 입력 단가로 계산했다(캐시 쓰기 별도율 없음) — 옛 행은 rewrite 하지 않는다.
# =============================================================
USAGE_SCHEMA_VERSION=4

# codex 모델 가격표 — 한 곳에만 둔다(파서 안에 숫자를 흩뿌리지 않는다). per 1M tokens USD, JSON:
#   {input, cached(캐시 입력), cache_write_30m, cache_write_12h, output, long:{같은 키}|null, long_context_input_tokens}
#   long = 장문 구간(요청 입력이 long_context_input_tokens 를 초과하면 그 요청 전체가 장문 요금).
#   등록된 5종은 cache_write_*·long 에 null 이 없다. 어떤 구간의 캐시 쓰기 단가가 null 이면 추측하지 않고 estimated=null(unknown) 로 둔다.
#   실제 청구(ChatGPT/Codex 구독 결제액·크레딧 차감·service tier·리전 할증)가 아니라 API 표준 요금 환산 추정치다.
#   여기 없는 모델은 estimated_cost_usd=null, cost_kind=unknown 으로 집계된다(추측 가격 금지).
# [Modified: GOAL-6] 등록 모델 전부 short/long 두 구간과 30분/12시간 캐시 쓰기 단가를 등록한다(null 없음). 기준: OpenAI API Standard, 2026-10-30 조회
#   (developers.openai.com/api/docs/pricing · /guides/prompt-caching · /models/<id>). 규칙: long = 요청 입력 > 272,000(정확히 272,000 은 short) 일 때
#   그 요청 전체에 적용, long 단가 = 입력·캐시 입력·캐시 쓰기 short×2 / 출력 short×1.5, 30분 캐시 쓰기 = 구간 입력 단가×1.25, 12시간 = ×2.5
#   (캐시 쓰기는 입력 단가 위에 더하는 할증이 아니라 배타적 입력 토큰 분류). 정확한 모델 ID 만 매칭한다(gpt-6-sol ≠ gpt-6.1-sol).
#   gpt-6.2-astra 는 2026-11-18 같은 페이지에서 추가 조회했다(같은 규칙을 따른다 — 캐시 입력만 입력의 5%).
#   gpt-5.6-sol 단가는 2026-11-30 까지 최소 유지 예정인 프로모션 단가다(2026-11-24 확인 — 종료일이 11-21 에서 연장됐고 단가는 그대로다) — 이 날짜 뒤에는 요금표 재확인이 필요하다.
CODEX_PRICING_BASIS="openai-api-standard-2026-10-30"
# Claude 모델 가격표 — native Agent(claude_native) 호출의 비용 추정에만 쓴다. claude -p 는 CLI 가 보고한 total_cost_usd(reported)를 그대로 쓴다.
#   native subagent 는 비용을 보고하지 않고 전사에 토큰만 남긴다 → 토큰 × API 표준 요금으로 환산한다(estimated). 구독 사용량·실제 청구액이 아니다.
#   per 1M tokens USD: {input, cache_read, cache_write_5m, cache_write_1h, output}. 기준: platform.claude.com/docs/en/about-claude/pricing (2026-11-24 조회).
#   등록한 모델은 전 구간 단일 요금이다(1M context 를 표준 요금에 포함). 프롬프트 길이로 요금이 갈리는 모델(claude-haiku-5-5: 100,000 토큰 초과 구간)은
#   요청별 프롬프트 길이가 있어야 계산할 수 있어 등록하지 않는다 — 여기 없는 모델은 estimated_cost_usd=null, cost_kind=unknown 이다(추측 가격 금지).
#   정확한 모델 ID 만 매칭한다. fast mode(usage.speed != standard)·US 전용 추론(inference_geo == us)은 요금이 달라 추정하지 않는다(unknown).
CLAUDE_PRICING_BASIS="anthropic-api-standard-2026-11-24"
claude_model_pricing() { # model → 가격 JSON / 가격표에 없으면 1
  case "$1" in
    claude-fable-5-2|claude-mythos-5-2) printf '%s' '{"input":8,"cache_read":0.2,"cache_write_5m":10,"cache_write_1h":16,"output":40}' ;;
    claude-opus-5-5)   printf '%s' '{"input":4,"cache_read":0.2,"cache_write_5m":5,"cache_write_1h":8,"output":20}' ;;
    claude-opus-5)     printf '%s' '{"input":5,"cache_read":0.5,"cache_write_5m":6.25,"cache_write_1h":10,"output":25}' ;;
    claude-sonnet-5-5) printf '%s' '{"input":2,"cache_read":0.1,"cache_write_5m":2.5,"cache_write_1h":4,"output":10}' ;;
    claude-sonnet-5)   printf '%s' '{"input":2,"cache_read":0.2,"cache_write_5m":2.5,"cache_write_1h":4,"output":10}' ;;
    *) return 1 ;;
  esac
}
# native Agent 전사에서 읽은 usage(capture.usage)의 관측 판정 — 추정과 usage 행이 같은 판정을 쓴다(jq 정의 한 벌).
#   transcript  : 모든 API 요청의 usage 를 읽었고 네 토큰 필드(input·output·cache_read·cache_creation)가 전부 0 이상의 숫자다.
#   partial     : 일부만 읽었다 — usage 가 없는 요청(USAGE_REQUESTS_MISSING), 필수 필드가 없거나 숫자가 아니거나 음수(USAGE_FIELDS_INCOMPLETE),
#                 요청 안의 보조 모델 호출(usage.iterations 의 advisor_message 등 — 그 토큰은 요청의 usage 합계에 들어 있지 않다, USAGE_ITERATIONS_EXCLUDED).
#                 message.id 가 없는 assistant 레코드(요청 단위로 묶을 수 없다 — 몇 건의 요청인지 모른다, USAGE_REQUEST_ID_MISSING).
#                 누락을 0 으로 읽지 않는다: 비용은 추정하지 않고(unknown) 토큰 합계도 행에 싣지 않는다(codex 의 USAGE_FIELDS_INCOMPLETE 와 같은 규칙).
#   unavailable : usage 를 하나도 읽지 못했다.
#   usage_missing_requests·usage_incomplete_requests·usage_side_iteration_requests·usage_unidentified_records 는 훅이 요청별로 센 값이다(이 값이 없는 옛 캡처는 0 으로 본다 — 합계 필드 검사는 그대로 적용된다).
CLAUDE_NATIVE_USAGE_JQ='
  def native_tok: type == "number" and . >= 0;
  def native_usage_check:
    . as $u
    | ["input_tokens","output_tokens","cache_read_input_tokens","cache_creation_input_tokens"] as $req
    | if ($u | type) != "object" or ([$req[] as $k | $u[$k]] | all(. == null)) then {status:"unavailable", error:null, detail:"usage 미관측"}
      else ([$req[] as $k | select($u[$k] | native_tok | not) | $k]
            + [("cache_write_5m_input_tokens","cache_write_1h_input_tokens") as $k | select($u[$k] != null and ($u[$k] | native_tok | not)) | $k]) as $bad
        | (($u.usage_missing_requests // 0) | if type == "number" then . else 1 end) as $miss
        | (($u.usage_incomplete_requests // 0) | if type == "number" then . else 1 end) as $inc
        | (($u.usage_side_iteration_requests // 0) | if type == "number" then . else 1 end) as $side
        | (($u.usage_unidentified_records // 0) | if type == "number" then . else 1 end) as $unid
        | if ($bad | length) > 0 or $inc > 0 then
            {status:"partial", error:"USAGE_FIELDS_INCOMPLETE",
             detail:("usage 필수 토큰 필드가 없거나 숫자가 아니거나 음수다(" + (if ($bad | length) > 0 then ($bad | join(", ")) else "요청 \($inc)건" end) + ") — 0 으로 읽지 않는다")}
          elif $unid > 0 then
            {status:"partial", error:"USAGE_REQUEST_ID_MISSING", detail:"assistant 레코드 \($unid)건에 message.id 가 없다 — API 요청 단위로 묶을 수 없어 합산·환산하지 않는다"}
          elif $miss > 0 then
            {status:"partial", error:"USAGE_REQUESTS_MISSING", detail:"API 요청 \($u.api_requests // "?")건 중 \($miss)건의 usage 가 전사에 없다 — 관측한 요청만으로 합산하지 않는다"}
          elif $side > 0 then
            {status:"partial", error:"USAGE_ITERATIONS_EXCLUDED", detail:"요청 \($side)건에 보조 모델 호출(usage.iterations 의 advisor_message 등)이 있다 — 그 토큰은 요청의 usage 합계에 들어 있지 않아 합산·환산하지 않는다"}
          else {status:"transcript", error:null, detail:null} end
      end;'
claude_native_usage_check() { # <capture.usage JSON> → {status, error, detail}
  jq -nc --argjson u "$1" "$CLAUDE_NATIVE_USAGE_JQ"' $u | native_usage_check'
}
# claude_native_estimate_cost <capture.usage JSON> <가격 JSON> → {estimated_cost_usd, assumptions}. 추정할 수 없으면 estimated_cost_usd=null 과 그 사유.
#   usage 가 불완전하면(위 판정이 transcript 가 아니면) 추정하지 않는다 — 누락 필드를 0 으로 계산한 금액은 정상 추정치처럼 보이는 틀린 값이다.
#   캐시 쓰기는 TTL 별 단가가 다르다 — 전사의 TTL 구분(5분/1시간) 합이 캐시 쓰기 총량과 맞을 때만 계산한다(구분이 없으면 추측하지 않는다).
#   speed·inference_geo 를 전사가 보고하지 않은 요청(unreported)은 표준 요금·global 로 가정해 추정하고, 그 가정을 assumptions 에 적는다
#   (codex 추정의 service tier/리전 가정과 같은 규칙. fast·us 로 보고된 요청이 하나라도 있으면 추정하지 않는다).
claude_native_estimate_cost() {
  jq -nc --argjson u "$1" --argjson r "$2" "$CLAUDE_NATIVE_USAGE_JQ"'
    ($u | native_usage_check) as $chk
    | if $chk.status != "transcript" then {estimated_cost_usd:null, assumptions:$chk.detail}
      else
        $u.cache_creation_input_tokens as $cw | ($u.cache_write_5m_input_tokens // 0) as $w5 | ($u.cache_write_1h_input_tokens // 0) as $w1
        | ($u.speeds // ["unreported"]) as $sp | ($u.inference_geos // ["unreported"]) as $geo
        | if ($w5 + $w1) != $cw then {estimated_cost_usd:null, assumptions:"캐시 쓰기 토큰의 TTL 구분(5분/1시간)이 전사에 없어 단가를 정할 수 없다"}
          elif ($sp - ["standard","unreported"] | length) > 0 then {estimated_cost_usd:null, assumptions:"fast mode 요청이 섞여 있다(표준 요금표로 환산하지 않는다)"}
          elif ($geo | index("us")) != null then {estimated_cost_usd:null, assumptions:"US 전용 추론(inference_geo us) 요청이 섞여 있다(1.1x — 표준 요금표로 환산하지 않는다)"}
          else {estimated_cost_usd: (($u.input_tokens * $r.input + $u.cache_read_input_tokens * $r.cache_read + $w5 * $r.cache_write_5m + $w1 * $r.cache_write_1h
                                      + $u.output_tokens * $r.output) / 1000000),
                assumptions: ("전사의 요청별 usage 합산 × API 표준 요금(캐시 쓰기는 TTL 별 단가). 구독 사용량·실제 청구액 아님"
                              + (if ($sp | index("unreported")) != null then " / speed 미보고 요청은 standard 로 가정" else "" end)
                              + (if ($geo | index("unreported")) != null then " / inference_geo 미보고 요청은 표준 요금(US 전용 아님)으로 가정" else "" end))} end
      end'
}
codex_model_pricing() { # model → 가격 JSON / 가격표에 없으면 1
  case "$1" in
    gpt-6.2-astra)
      printf '%s' '{"input":8,"cached":0.4,"cache_write_30m":10,"cache_write_12h":20,"output":40,"long_context_input_tokens":272000,"long":{"input":16,"cached":0.8,"cache_write_30m":20,"cache_write_12h":40,"output":60}}' ;;
    gpt-6-astra)
      printf '%s' '{"input":10,"cached":1,"cache_write_30m":12.5,"cache_write_12h":25,"output":50,"long_context_input_tokens":272000,"long":{"input":20,"cached":2,"cache_write_30m":25,"cache_write_12h":50,"output":75}}' ;;
    gpt-5.6-sol)
      printf '%s' '{"input":4,"cached":0.4,"cache_write_30m":5,"cache_write_12h":10,"output":20,"long_context_input_tokens":272000,"long":{"input":8,"cached":0.8,"cache_write_30m":10,"cache_write_12h":20,"output":30}}' ;;
    gpt-6-sol)
      printf '%s' '{"input":2,"cached":0.2,"cache_write_30m":2.5,"cache_write_12h":5,"output":10,"long_context_input_tokens":272000,"long":{"input":4,"cached":0.4,"cache_write_30m":5,"cache_write_12h":10,"output":15}}' ;;
    gpt-5.6-luna)
      printf '%s' '{"input":0.2,"cached":0.02,"cache_write_30m":0.25,"cache_write_12h":0.5,"output":1.2,"long_context_input_tokens":272000,"long":{"input":0.4,"cached":0.04,"cache_write_30m":0.5,"cache_write_12h":1,"output":1.8}}' ;;
    gpt-6-luna)
      printf '%s' '{"input":0.1,"cached":0.01,"cache_write_30m":0.125,"cache_write_12h":0.25,"output":0.5,"long_context_input_tokens":272000,"long":{"input":0.2,"cached":0.02,"cache_write_30m":0.25,"cache_write_12h":0.5,"output":0.75}}' ;;
    *) return 1 ;;
  esac
}
# codex turn 목록 [{i,c,w,w12,o,r}] + 가격 JSON → {estimated_cost_usd, long_context_turns, assumptions[]} (jq 만 사용).
#   turn 마다: uncached = max(0, i − c − w − w12) · 구간 = (long 이 있고 i > long_context_input_tokens 이면 long, 아니면 short — 272,000 은 short) ·
#   cache_write: w12(12시간 캐시 쓰기 토큰이 이벤트에 **관측**된 경우 — cache_write_12h_input_tokens)는 12시간 단가, 나머지 w 는 30분 단가.
#   w 와 w12 는 서로 겹치지 않는 분류라고 가정한다(w12 가 w 의 부분집합으로 중복 보고되면 캐시 쓰기가 이중 계산된다 — 그 가정도 assumptions 에 남긴다).
#   TTL 근거(observed/assumed)는 w 또는 w12 중 하나라도 0 보다 크면 기록한다(12시간만 있는 turn 도 포함).
#   TTL 분류가 관측되지 않으면(w12 없음) 전부 30분으로 보고 assumptions 에 남긴다. 구간의 캐시 쓰기 단가가 없으면(미등록) 추측하지 않고 estimated=null(unknown).
#   장문 기준은 API 요청 단위다. codex 이벤트는 요청 단위 입력을 주지 않으므로 turn.completed 입력을 proxy 로 쓰고 long_context_tier=turn_proxy 로 한계를 명시한다 —
#   invocation 누적 토큰으로 판정하지 않는다(작은 turn 여럿의 합이 272K 를 넘어도 long 이 아니다).
codex_estimate_cost() { # turns_json pricing_json → JSON
  jq -nc --argjson t "$1" --argjson p "$2" '
    def nz: if . == null or . < 0 then 0 else . end;
    def tier($i): if ($p.long != null and $p.long_context_input_tokens != null and $i > $p.long_context_input_tokens) then $p.long else $p end;
    [ $t[] | (.i|nz) as $i | (.c|nz) as $c | (.w|nz) as $w | (.w12|nz) as $w12 | (.o|nz) as $o | tier($i) as $r
      | { long: ($r != $p),
          rate_missing: (($w > 0 and $r.cache_write_30m == null) or ($w12 > 0 and $r.cache_write_12h == null)),
          cost: ( (([$i - $c - $w - $w12, 0] | max) * $r.input + $c * $r.cached + $w * ($r.cache_write_30m // 0) + $w12 * ($r.cache_write_12h // 0) + $o * $r.output) / 1000000 ) } ] as $rows
    | ($rows | any(.rate_missing)) as $missing
    | { estimated_cost_usd: (if $missing then null else ($rows | map(.cost) | add // 0) end),
        long_context_turns: ($rows | map(select(.long)) | length),
        assumptions: (if $missing then ["cache_write_rate=unregistered(estimate withheld — no guessed price)"] else
          ["service_tier=standard(assumed; Flex/Batch/Fast tier and regional surcharge not observable)"]
          + (if (($t | map(.w|nz) | add // 0) > 0) or (($t | map(.w12|nz) | add // 0) > 0) then
               (if ($t | map(.w12|nz) | add // 0) > 0 then ["cache_write_ttl=observed(30m/12h split from events; cache_write_12h_input_tokens assumed disjoint from cache_write_input_tokens)"]
                else ["cache_write_ttl=30m(assumed; TTL not observable in events)"] end) else [] end)
          + (if $p.long != null then ["long_context_tier=turn_proxy(per turn.completed input_tokens>\($p.long_context_input_tokens); request-level input not observable, a turn may aggregate several requests)"]
             else ["long_context_tier=not_registered(short tier applied to every turn)"] end) end) }'
}

new_invocation_id() { # 호출 직전 생성. 같은 label 재시도를 구분한다
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'
  else printf '%s-%s-%s' "$(date +%s)" "$$" "$RANDOM$RANDOM"; fi
}

# [Modified] claude stream-json JSONL → type=result 이벤트가 **정확히 하나**일 때만 그 객체(= --output-format json 과 같은 객체)를 out 에 쓴다(0).
# 그 외에는 out 을 만들지 않고 1 을 돌려주며 사유를 stderr 에 남긴다 — 중간의 유효해 보이는 이벤트를 골라 승인하지 않는다(`tail -1` 선택 제거):
#   CLAUDE_RESULT_MISSING  result 0개(빈 파일 포함)        CLAUDE_RESULT_MULTIPLE result n≥2 개(하위 Agent·백그라운드 실행이 result 를 여러 번 남긴 경우)
#   CLAUDE_RESULT_INVALID  result 0개 + JSON 으로 못 읽는 줄이 있음
# 레거시 단일 객체 경로(별도·명시): 파일 전체가 `type` 필드 없는 JSON 객체 정확히 한 줄이면(구형 --output-format json 출력, 테스트 mock) 그 객체를 result 로 쓴다.
# 실제 stream-json 은 모든 이벤트에 type 이 있으므로 이 경로에 들어오지 않는다. 판정은 셸/jq 만 쓴다(추가 모델 호출 없음).
CLAUDE_RESULT_DIAG=""   # 마지막 claude_stream_extract_result 의 진단 코드(성공이면 빈 값) — 호출자가 가드·메시지에 남긴다
claude_stream_extract_result() { # stream_jsonl out_json [label]
  local f="$1" out="$2" label="${3:-}" n_r=0 n_u=0 n_b=0 n_o=0 kind n
  CLAUDE_RESULT_DIAG=""
  rm -f "$out"
  [ -f "$f" ] || { CLAUDE_RESULT_DIAG=CLAUDE_RESULT_MISSING; echo "[FAIL] CLAUDE_RESULT_MISSING${label:+ ($label)}: stream 파일 없음 — $f" >&2; return 1; }
  while read -r n kind; do
    case "$kind" in R) n_r=$n;; U) n_u=$n;; B) n_b=$n;; O) n_o=$n;; esac
  done < <(jq -R -r 'if length==0 then empty else ((fromjson? // {"__bad__":true})
            | if (type=="object" and .__bad__==true) then "B"
              elif (type=="object" and .type=="result") then "R"
              elif (type=="object" and (has("type")|not)) then "U"
              else "O" end) end' "$f" 2>/dev/null | sort | uniq -c | awk '{print $1, $2}')
  # [Modified: GOAL-6] result 가 1개여도 JSON 으로 읽을 수 없는 줄이 섞여 있으면 조용히 성공시키지 않는다(원본 보존, INVALID)
  if [ "$n_r" -eq 1 ] && [ "$n_b" -gt 0 ]; then
    CLAUDE_RESULT_DIAG=CLAUDE_RESULT_INVALID
    echo "[FAIL] CLAUDE_RESULT_INVALID${label:+ ($label)}: result 이벤트 1개 + JSON 으로 읽을 수 없는 줄 $n_b 개 — 손상된 stream 을 수용하지 않는다. 원본: $f" >&2
    return 1
  fi
  if [ "$n_r" -eq 1 ]; then
    jq -c 'select(type=="object" and .type=="result")' "$f" > "$out" && return 0
    rm -f "$out"; CLAUDE_RESULT_DIAG=CLAUDE_RESULT_INVALID; echo "[FAIL] CLAUDE_RESULT_INVALID${label:+ ($label)}: result 이벤트를 다시 읽지 못함 — $f" >&2; return 1
  fi
  if [ "$n_r" -eq 0 ] && [ "$n_b" -eq 0 ] && [ "$n_o" -eq 0 ] && [ "$n_u" -eq 1 ]; then
    jq -c 'select(type=="object")' "$f" > "$out" && return 0   # 레거시 단일 객체 경로
    rm -f "$out"; CLAUDE_RESULT_DIAG=CLAUDE_RESULT_INVALID; echo "[FAIL] CLAUDE_RESULT_INVALID${label:+ ($label)}: 단일 객체를 다시 읽지 못함 — $f" >&2; return 1
  fi
  if [ "$n_r" -ge 2 ]; then
    CLAUDE_RESULT_DIAG=CLAUDE_RESULT_MULTIPLE
    echo "[FAIL] CLAUDE_RESULT_MULTIPLE${label:+ ($label)}: stream-json 에 result 이벤트가 $n_r 개 — 어느 것도 자동 선택하지 않는다(하위 Agent/백그라운드 실행 의심). 원본: $f" >&2
  elif [ "$n_b" -gt 0 ]; then
    CLAUDE_RESULT_DIAG=CLAUDE_RESULT_INVALID
    echo "[FAIL] CLAUDE_RESULT_INVALID${label:+ ($label)}: result 이벤트 없음 + JSON 으로 읽을 수 없는 줄 $n_b 개. 원본: $f" >&2
  else
    CLAUDE_RESULT_DIAG=CLAUDE_RESULT_MISSING
    echo "[FAIL] CLAUDE_RESULT_MISSING${label:+ ($label)}: stream-json 에 result 이벤트가 없음(이벤트 $((n_u + n_o))줄). 원본: $f" >&2
  fi
  return 1
}
# claude stream-json JSONL 의 마지막 assistant 메시지 usage → 그 호출 시점의 실제 컨텍스트(input + cache_read + cache_creation). 없으면 null.
claude_stream_context_last_turn() { # stream_jsonl
  jq -c 'select(type=="object" and .type=="assistant" and (.message.usage|type)=="object") | .message.usage
         | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))' "$1" 2>/dev/null | tail -1
}
# codex thread 의 rollout(~/.codex/sessions/**/rollout-*-<thread_id>.jsonl) 마지막 token_count 이벤트 → {context_last_turn, context_window}.
# 관측 전용: 완료 판정·재실행 판단에는 쓰지 않는다(cli-exit-mismatch 불변식). 파일이 없거나 이벤트가 없으면 null.
codex_rollout_context_last_turn() { # events_jsonl
  local tid f
  tid="$(jq -r 'select(type=="object" and .type=="thread.started") | .thread_id // empty' "$1" 2>/dev/null | head -1)"
  [ -n "$tid" ] || { echo '{"context_last_turn":null,"context_window":null}'; return 0; }
  # 이 invocation 의 thread.started.thread_id 와 파일명이 일치하는 rollout 만 읽는다 — '가장 최근 rollout' 을 집으면 다른 세션 값이 섞인다.
  # 정확히 1개가 아니면(없음·중복) 측정 불가로 null — 추측으로 고르지 않는다.
  local matches; matches="$(find "${CODEX_HOME:-$HOME/.codex}/sessions" -type f -name "rollout-*-$tid.jsonl" 2>/dev/null)"
  f="$(printf '%s\n' "$matches" | grep -c . | { read -r n; [ "$n" -eq 1 ] && printf '%s' "$matches"; })"
  [ -n "$f" ] || { echo '{"context_last_turn":null,"context_window":null}'; return 0; }
  jq -c 'select(type=="object" and .type=="event_msg" and .payload.type=="token_count" and (.payload.info|type)=="object") | .payload.info
         | {context_last_turn:(.last_token_usage.input_tokens // null), context_window:(.model_context_window // null)}' "$f" 2>/dev/null | tail -1 \
    || echo '{"context_last_turn":null,"context_window":null}'
}

# claude --output-format json 결과 파일 → 행 1개.  usage 핵심 필드(usage.input_tokens)가 없으면 경고 후 생략(pipeline 실패 아님).
# 옆에 <result_file>.stream.jsonl 이 있으면 context_last_turn(마지막 assistant 메시지의 입력 합)을 채운다. context_window 는 result.modelUsage 에서.
# [Added: GOAL-6] 결과를 판정할 수 없는 claude invocation(result 0개/복수/파싱 실패) 의 행 — 비용·토큰은 null(0 아님), cost_kind=unknown.
#   stream 에서 안전하게 관측되는 것(마지막 assistant usage 의 입력 합 = context_last_turn)만 채우고 중복 합산은 하지 않는다.
#   usage_observation_status: partial(일부 관측) | unavailable(관측 없음), usage_error: 진단 코드, raw_log: 원본 경로. 완료 판정과는 별개의 telemetry 다.
log_claude_usage_unavailable() { # label role model stream_file exit_code invocation_id diag
  local label="$1" role="$2" model="$3" stream="$4" rc="${5:-0}" inv="$6" diag="${7:-CLAUDE_RESULT_MISSING}" ctx='null' status=unavailable
  [ -n "$inv" ] || inv="$(new_invocation_id)"
  if [ -f "$stream" ]; then ctx="$(claude_stream_context_last_turn "$stream")"; [ -n "$ctx" ] || ctx='null'; fi
  [ "$ctx" = null ] || status=partial
  jq -nc --arg label "$label" --arg role "$role" --arg model "$model" --arg inv "$inv" --argjson ctx "$ctx" --arg status "$status" --arg err "$diag" \
    --arg raw "$stream" --argjson rc "$rc" --argjson v "$USAGE_SCHEMA_VERSION" --arg now "$(date '+%FT%T%z')" '
    { schema_version: $v, invocation_id: $inv, label: $label, role: $role, cli: "claude", model: $model, session: null,
      cost_usd: null, cost_kind: "unknown", estimated_cost_usd: null, pricing_basis: null, pricing_assumptions: null, long_context_turns: null,
      input_uncached: null, cache_read: null, cache_write: null, output: null, reasoning_output: null, input_effective: null, input_per_turn: null,
      context_last_turn: $ctx, context_window: null, tokens_total: null, num_turns: null, duration_ms: null, duration_api_ms: null,
      exit_code: $rc, success: false, usage_observation_status: $status, usage_error: $err, raw_log: $raw,
      source: "claude-stream", recorded_at: $now }' >> "$WORK_DIR/usage.jsonl"
}
# [Modified: GOAL-6] usage 핵심 필드(usage.input_tokens)가 없어도 행을 생략하지 않고 unknown 행으로 남긴다(실제로 시작한 invocation 1개 = 행 1개).
log_claude_usage() { # label role model result_file [exit_code] [invocation_id]
  local label="$1" role="$2" model="$3" result_file="$4" rc="${5:-0}" inv="${6:-}" ctx='null'
  [ -n "$inv" ] || inv="$(new_invocation_id)"
  if ! jq -e '.usage.input_tokens != null' "$result_file" >/dev/null 2>&1; then
    echo "[WARN] usage 필드 없음 — unknown 행으로 기록(비용·토큰 null): $result_file" >&2
    log_claude_usage_unavailable "$label" "$role" "$model" "$result_file.stream.jsonl" "$rc" "$inv" USAGE_FIELDS_MISSING
    return 0
  fi
  if [ -f "$result_file.stream.jsonl" ]; then ctx="$(claude_stream_context_last_turn "$result_file.stream.jsonl")"; [ -n "$ctx" ] || ctx='null'; fi
  jq -c --arg label "$label" --arg role "$role" --arg model "$model" --arg inv "$inv" --argjson ctx "$ctx" \
    --argjson rc "$rc" --argjson v "$USAGE_SCHEMA_VERSION" --arg now "$(date '+%FT%T%z')" '
    {
      schema_version: $v,
      invocation_id: $inv,
      label: $label, role: $role, cli: "claude", model: $model,
      session: (.session_id // null),
      cost_usd: (.total_cost_usd // null),
      cost_kind: (if .total_cost_usd != null then "reported" else "unknown" end),
      estimated_cost_usd: null, pricing_basis: null,
      pricing_assumptions: null, long_context_turns: null,
      input_uncached: (.usage.input_tokens // null),
      cache_read: (.usage.cache_read_input_tokens // 0),
      cache_write: (.usage.cache_creation_input_tokens // 0),
      output: (.usage.output_tokens // null),
      reasoning_output: null,
      input_effective: ((.usage.input_tokens // 0) + (.usage.cache_read_input_tokens // 0) + (.usage.cache_creation_input_tokens // 0)),
      input_per_turn: (if ((.num_turns // 0) > 0)
                       then ((((.usage.input_tokens // 0) + (.usage.cache_read_input_tokens // 0) + (.usage.cache_creation_input_tokens // 0)) / .num_turns) | floor)
                       else null end),
      context_last_turn: $ctx,
      context_window: ((.modelUsage // {}) as $mu | ($mu[$model].contextWindow? // ($mu | to_entries | first.value.contextWindow? // null))),
      tokens_total: null,
      num_turns: (.num_turns // null),
      duration_ms: (.duration_ms // null),
      duration_api_ms: (.duration_api_ms // null),
      exit_code: $rc, success: ($rc == 0),
      usage_observation_status: "complete", usage_error: null, raw_log: null,
      source: "claude-result",
      recorded_at: $now
    }' "$result_file" >> "$WORK_DIR/usage.jsonl"
}

# [Added: 리뷰 1] codex invocation 의 usage 를 판정할 수 없을 때의 행 — 비용·토큰 null(0 아님), cost_kind unknown. 모델 재호출 없음, 원본 경로 보존.
#   status: partial(유효한 turn 이 일부 있음) | unavailable(없음). err: USAGE_EVENTS_MISSING | USAGE_EVENTS_CORRUPT | USAGE_FIELDS_INCOMPLETE
codex_usage_unknown_row() { # label role model events rc inv err status
  jq -nc --arg label "$1" --arg role "$2" --arg model "$3" --arg raw "$4" --argjson rc "$5" --arg inv "$6" --arg err "$7" --arg status "$8" \
    --argjson v "$USAGE_SCHEMA_VERSION" --arg now "$(date '+%FT%T%z')" '
    { schema_version: $v, invocation_id: $inv, label: $label, role: $role, cli: "codex", model: $model, session: null,
      cost_usd: null, cost_kind: "unknown", estimated_cost_usd: null, pricing_basis: null, pricing_assumptions: null, long_context_turns: null,
      input_uncached: null, cache_read: null, cache_write: null, output: null, reasoning_output: null, input_effective: null, input_per_turn: null,
      context_last_turn: null, context_window: null, tokens_total: null, num_turns: null, duration_ms: null, duration_api_ms: null,
      exit_code: $rc, success: ($rc == 0), usage_observation_status: $status, usage_error: $err, raw_log: $raw,
      source: "codex-events", recorded_at: $now }' >> "$WORK_DIR/usage.jsonl"
}
# codex exec --json 이벤트 JSONL → 행 1개. invocation 의 모든 turn.completed.usage 를 합산한다(위 v3 매핑).
# [Modified: 리뷰 1] 관측하지 못한 비용을 0 달러로 적지 않는다 — 다음 중 하나면 합산하지 않고 unknown 행 1개를 남긴다(작업 실패 아님·재실행 없음):
#   · JSON 으로 읽을 수 없는 줄이 하나라도 있음(USAGE_EVENTS_CORRUPT — 정상 이벤트만 합산해 complete 로 적으면 과소 집계다)
#   · turn.completed 중 usage 가 객체가 아니거나 필수 필드(input_tokens·output_tokens)가 숫자가 아닌 것이 있음(USAGE_FIELDS_INCOMPLETE — `usage:{}` 를 0 으로 읽지 않는다)
#   · turn.completed 가 없음(USAGE_EVENTS_MISSING). plain "tokens used" 텍스트는 읽지 않는다.
#   선택 필드(cached/cache_write/cache_write_12h/reasoning)는 없으면 0, 있는데 숫자가 아니면 INCOMPLETE. 음수는 0 으로 본다.
log_codex_usage() { # label role model events_jsonl [exit_code] [invocation_id]
  local label="$1" role="$2" model="$3" events="$4" rc="${5:-0}" inv="${6:-}" agg rates basis='null'
  [ -n "$inv" ] || inv="$(new_invocation_id)"
  # 줄 분류: B=JSON 아님, T=turn.completed(유효 usage), X=turn.completed(usage 불완전), O=그 외 이벤트
  local scan n_b=0 n_t=0 n_x=0 n kind
  scan="$(jq -R -r 'if length==0 then empty else ((fromjson? // {"__bad__":true})
      | if (type=="object" and .__bad__==true) then "B"
        elif (type=="object" and .type=="turn.completed") then
          (if ((.usage|type)=="object" and (.usage.input_tokens|type)=="number" and (.usage.output_tokens|type)=="number"
               and ([.usage.cached_input_tokens, .usage.cache_write_input_tokens, .usage.cache_write_12h_input_tokens, .usage.reasoning_output_tokens]
                    | all(. == null or type=="number"))) then "T" else "X" end)
        else "O" end) end' "$events" 2>/dev/null | sort | uniq -c | awk '{print $1, $2}')"
  while read -r n kind; do case "$kind" in B) n_b=$n;; T) n_t=$n;; X) n_x=$n;; esac; done <<< "$scan"
  local status=unavailable; [ "$n_t" -eq 0 ] || status=partial
  if [ "$n_b" -gt 0 ]; then
    echo "[WARN] codex 이벤트 JSONL 에 JSON 으로 읽을 수 없는 줄 $n_b 개 — 과소 집계를 막기 위해 unknown 행으로 기록(비용·토큰 null, 유효 turn $n_t 개는 합산하지 않음): $events" >&2
    codex_usage_unknown_row "$label" "$role" "$model" "$events" "$rc" "$inv" USAGE_EVENTS_CORRUPT "$status"; return 0
  fi
  if [ "$n_x" -gt 0 ]; then
    echo "[WARN] codex turn.completed usage 에 필수 필드(input_tokens/output_tokens 숫자)가 없는 이벤트 $n_x 개 — unknown 행으로 기록(비용·토큰 null, 0 아님): $events" >&2
    codex_usage_unknown_row "$label" "$role" "$model" "$events" "$rc" "$inv" USAGE_FIELDS_INCOMPLETE "$status"; return 0
  fi
  if [ "$n_t" -eq 0 ]; then
    echo "[WARN] codex 이벤트 JSONL 에 turn.completed usage 없음 — unknown 행으로 기록(비용·토큰 null): $events" >&2
    codex_usage_unknown_row "$label" "$role" "$model" "$events" "$rc" "$inv" USAGE_EVENTS_MISSING unavailable; return 0
  fi
  # turn 목록을 그대로 보존해(turns) 구간별 가격을 turn 단위로 고른다. w12 = cache_write_12h_input_tokens(분리 관측 시만; 없으면 0 → 전부 30분 가정).
  local turns
  turns="$(jq -R -c 'fromjson? | select(type=="object" and .type=="turn.completed") | .usage' "$events" 2>/dev/null \
    | jq -s -c 'def nz: if . == null or . < 0 then 0 else . end;
        map({i:(.input_tokens|nz), c:(.cached_input_tokens|nz), w:(.cache_write_input_tokens|nz), w12:(.cache_write_12h_input_tokens|nz), o:(.output_tokens|nz), r:(.reasoning_output_tokens|nz)})' 2>/dev/null)"
  [ -n "$turns" ] && [ "$(printf '%s' "$turns" | jq 'length')" = "$n_t" ] || { codex_usage_unknown_row "$label" "$role" "$model" "$events" "$rc" "$inv" USAGE_EVENTS_CORRUPT unavailable; return 0; }
  agg="$(printf '%s' "$turns" | jq -c '{turns:length, input_total:(map(.i)|add // 0), cache_read:(map(.c)|add // 0), cache_write:(map(.w + .w12)|add // 0), output:(map(.o)|add // 0), reasoning:(map(.r)|add // 0)}')"
  # 가격표에 있는 모델만 추정한다. 없는 모델은 est=null → cost_kind=unknown (0 달러로 적지 않는다).
  local est='{"estimated_cost_usd":null,"long_context_turns":null,"assumptions":null}'
  if rates="$(codex_model_pricing "$model")"; then
    est="$(codex_estimate_cost "$turns" "$rates")" || est='{"estimated_cost_usd":null,"long_context_turns":null,"assumptions":null}'
    basis="\"$CODEX_PRICING_BASIS\""
  fi
  local ctx; ctx="$(codex_rollout_context_last_turn "$events")"; [ -n "$ctx" ] || ctx='{"context_last_turn":null,"context_window":null}'
  jq -nc --arg label "$label" --arg role "$role" --arg model "$model" --arg inv "$inv" --argjson a "$agg" --argjson est "$est" --argjson basis "$basis" \
    --argjson ctx "$ctx" \
    --argjson rc "$rc" --argjson v "$USAGE_SCHEMA_VERSION" --arg now "$(date '+%FT%T%z')" '
    ([$a.input_total - $a.cache_read - $a.cache_write, 0] | max) as $uncached
    | {
      schema_version: $v,
      invocation_id: $inv,
      label: $label, role: $role, cli: "codex", model: $model,
      session: null,
      cost_usd: null,
      cost_kind: (if $est.estimated_cost_usd == null then "unknown" else "estimated" end),
      estimated_cost_usd: $est.estimated_cost_usd, pricing_basis: (if $est.estimated_cost_usd == null then null else $basis end),
      pricing_assumptions: $est.assumptions, long_context_turns: $est.long_context_turns,
      input_uncached: $uncached, cache_read: $a.cache_read, cache_write: $a.cache_write, output: $a.output,
      reasoning_output: $a.reasoning,
      input_effective: ($uncached + $a.cache_read + $a.cache_write),
      input_per_turn: (if $a.turns > 0 then (($uncached + $a.cache_read + $a.cache_write) / $a.turns | floor) else null end),
      context_last_turn: $ctx.context_last_turn, context_window: $ctx.context_window,
      tokens_total: ($uncached + $a.cache_read + $a.cache_write + $a.output),
      num_turns: $a.turns, duration_ms: null, duration_api_ms: null,
      exit_code: $rc, success: ($rc == 0),
      usage_observation_status: "complete", usage_error: null, raw_log: null,
      source: "codex-events",
      recorded_at: $now
    }' >> "$WORK_DIR/usage.jsonl"
}

# 공통 진입점 — 모든 역할 invocation 이 여기를 지나 기록 누락을 막는다.
log_role_usage() { # cli role model label raw_or_log_path [exit_code] [invocation_id]
  local cli="$1"; shift
  case "$cli" in
    claude) log_claude_usage "$3" "$1" "$2" "$4" "${5:-0}" "${6:-}" ;;
    codex)  log_codex_usage  "$3" "$1" "$2" "$4" "${5:-0}" "${6:-}" ;;
    *) echo "[WARN] usage 기록: 알 수 없는 cli '$cli'" >&2 ;;
  esac
}

# 파생 집계(별도 명령). legacy 행(in/out, v2 codex tokens_total 만 있는 행)도 읽는다. 사용: usage_summary [usage.jsonl]
# 비용은 provenance 별로 따로 낸다 — 섞은 값은 이름에 estimate 를 붙인다:
#   reported_cost_usd        = provider 가 보고한 cost_usd 의 합(claude)            / cost_usd = 같은 값(외부 호환용 옛 이름, 의미 불변)
#   estimated_cost_usd       = 가격표 추정치 estimated_cost_usd 의 합(codex + native Agent 로 실행한 claude)
#   usage_unobserved_invocations = 사용량을 관측하지 못한 행 수(usage_observation_status 가 complete·transcript 가 아닌 것 — transcript 는 native Agent 전사에서 토큰을 읽은 관측이다)
#   combined_cost_usd_estimate = reported + estimated (실제 청구액이 아니라 비교용 추정치)
#   cost_unknown_invocations = 둘 다 null 인 행 수(가격표에 없는 codex 모델, telemetry 없는 행 등)
# by_role / by_label / by_session: 어느 역할·호출·Claude 세션이 cache read 를 만드는지 보는 그룹 합계(같은 지표 세트).
# cache_read_per_turn = cache_read 합 / num_turns 합(num_turns 를 보고한 행만) — turn 당 다시 읽히는 문맥 크기의 근사치.
# num_turns 가 하나도 없으면 null. 임계치·자동 판단은 두지 않는다(관측값만 제공).
usage_summary() {
  local f="${1:-$WORK_DIR/usage.jsonl}"
  [ -s "$f" ] || { echo '{}'; return 0; }
  jq -s '
    def metrics: {
      invocations: length,
      cost_usd: (map(.cost_usd // 0) | add),
      reported_cost_usd: (map(.cost_usd // 0) | add),
      estimated_cost_usd: (map(.estimated_cost_usd // 0) | add),
      combined_cost_usd_estimate: (map((.cost_usd // 0) + (.estimated_cost_usd // 0)) | add),
      cost_unknown_invocations: (map(select(.cost_usd == null and .estimated_cost_usd == null)) | length),
      usage_unobserved_invocations: (map(select((.usage_observation_status // "complete") as $s | $s != "complete" and $s != "transcript")) | length),
      pricing_bases: (map(.pricing_basis // empty) | unique),
      cache_read: (map(.cache_read // 0) | add),
      num_turns: (map(.num_turns // 0) | add),
      output: (map(.output // .out // 0) | add),
      reasoning_output: (map(.reasoning_output // 0) | add),
      cache_read_per_turn: (
        (map(select(.num_turns != null))) as $t
        | if ($t | map(.num_turns) | add // 0) > 0
          then (($t | map(.cache_read // 0) | add) / ($t | map(.num_turns) | add))
          else null end)
    };
    def grouped(key): group_by(key) | map({key: (.[0] | key), value: metrics}) | from_entries;
    metrics + {
      input_uncached: (map(.input_uncached // .in // 0) | add),
      cache_write: (map(.cache_write // 0) | add),
      tokens_total_codex: (map(select(.cli == "codex") | .tokens_total // 0) | add),
      cost_note: "reported_cost_usd = provider 보고(claude -p) / estimated_cost_usd = 토큰 × API 표준 요금 환산 추정치(codex, native Agent 로 실행한 claude — 구독 사용량·실제 청구액 아님) / combined 는 두 값의 합(실제 청구액 아님) / cost_unknown_invocations 는 둘 다 null 인 호출 수",
      by_role: grouped(.role // "legacy"),
      by_label: grouped(.label // "legacy"),
      by_session: grouped(.session // "none"),
      by_cli: grouped(.cli // "legacy"),
      by_source: grouped(.source // "legacy"),
      by_model: grouped(.model // "legacy")
    }' "$f"
}
# [Added] 러너 완료 보고용 한 줄 요약 — usage_summary 와 같은 숫자를 쓴다(별도 계산 없음). usage.jsonl 이 없으면 빈 출력.
usage_cost_report_line() { # [usage.jsonl]
  local s; s="$(usage_summary "${1:-$WORK_DIR/usage.jsonl}")"
  [ "$s" != '{}' ] || return 0
  printf '%s' "$s" | jq -r '
    def money: if . == null then "n/a" else ("$" + (. * 10000 | round / 10000 | tostring)) end;
    "비용(usage_summary, child invocation \(.invocations)건): Claude 보고 비용 \(.reported_cost_usd|money) (reported) / 추정 비용(codex·claude native) \(.estimated_cost_usd|money) (API 표준 요금 기준 환산, estimated) / 합계 추정 \(.combined_cost_usd_estimate|money) (실제 청구액 아님) / 추정 불가 \(.cost_unknown_invocations)건(사용량 미관측 \(.usage_unobserved_invocations)건 — 0달러 아님)"
    + " — by_cli: " + ([ .by_cli | to_entries[] | "\(.key)=\(.value.invocations)건(reported \(.value.reported_cost_usd|money), estimated \(.value.estimated_cost_usd|money), unknown \(.value.cost_unknown_invocations))" ] | join(", "))'
}
