#!/usr/bin/env bash
# =============================================================
# 스모크: 합의 단계 사용자 에스컬레이션 수리 — 실제 LLM 호출 없음 (공용 mock CLI: 역할은 스키마로 판별), 임시 저장소
# 파일 경로: tests/smoke-user-escalation-resume.sh
# 사용법: bash tests/smoke-user-escalation-resume.sh
#
# 불변식: design/impl 합의의 사용자 에스컬레이션(ASK_USER / DEADLOCK / MAX_ROUNDS_EXCEEDED)에 대한 명시적 사용자 결정은 최종이다.
#   모든 blocker 에 `[USER-QUESTION][scope=<target>][escalation=<id>]` 답이 추가되면 그 단계의 검증자·디자이너 호출 0회로 다음 단계로 간다
#   (design → impl 은 impl 합의를 정상 수행, impl → worker). USER_RESOLVED 는 검증자 PASS 가 아니다 — consensus-<target>.json·리뷰 JSON 을 위조하지 않는다.
# 사례:
#   1. design ASK_USER → 답 없는 재실행·빈 답·'<답>' 플레이스홀더·scope/id/질문 문구 불일치·태그 없는 답·문서 미반영(ASK_USER)은 NEED_USER(모델 0회) → 답 + design.md 반영 → design 검증자/디자이너 0회, impl 도달.
#      impl 검증자 crash 뒤 재개·합의 루프 단독 재실행도 design 검증자 0회. review/verify 를 거쳐서만 DONE.
#   2. impl ASK_USER(blocker 2개: ASK_USER + REVISE_DOC) → 하나만 답하면 NEED_USER(모델 0회) → 전부 답 → impl 검증자/디자이너 0회, worker 도달 → DONE
#   3. design/impl 각각 DEADLOCK · MAX_ROUNDS_EXCEEDED 도 같은 우회(마지막 실제 리뷰 보존, state.json.review)
#   7. 잘못된 우회 차단: 대기 중 request.md / conventions.md / implementation-units.json / decisions.md 기존 줄 변경 → SUPERSEDED + Round 1 재합의,
#      수리 뒤 문서 추가 변경·계약 버전 변경·리뷰 JSON 변조·손으로 만든 USER_RESOLVED → 무효
#   8. impl 사용자 수리 뒤 워커 DOC_GAP → 사용자 답 → 기존 doc-gap 직접 재개(검증자 0회, base_kind=USER_RESOLVED) → DONE
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-escalation-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
# 두 CLI 모두 mock 이다(역할 → CLI 매핑과 무관하게 실제 모델은 호출되지 않는다)
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"echo full-test >> $TMP/calls.log\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"echo full-lint >> $TMP/calls.log\"|" "$CFG" && rm -f "$CFG.bak"
set_max_rounds() { sed -i.bak "s/^MAX_SPEC_ROUNDS=.*/MAX_SPEC_ROUNDS=$1/" "$CFG" && rm -f "$CFG.bak"; }
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && echo "base 01" > src/u01.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
RUN=".claude/skills/feature/scripts/feature-run.sh"
LOOP=".claude/skills/feature/scripts/consensus-loop.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" FEATURE_LIVE_TEE=1 MOCK_VALIDATOR_CONTRACT="$CONTRACT" MOCK_REVIEW_CONTRACT="$REVIEW_CONTRACT"
mkdir -p "$MOCK_STATE"

# --- 공용 mock CLI. 검증자는 프롬프트로 target(design|impl)을 가리고 $MOCK_STATE/verdicts-<target> 의 첫 줄을 1회 소비한다(없으면 PASS).
#     모드: PASS | ASK(B-01 ASK_USER) | ASK2(B-01 ASK_USER + B-02 REVISE_DOC) | BLOCK <최소 계약 문구>(B-01 REVISE_DOC) | CRASH ---
cat > "$TMP/bin/mock-cli" <<'EOF'
#!/usr/bin/env bash
cli="$(basename "$0")"
out=""; schema=""; prompt=""; editing=0
while [ "$#" -gt 0 ]; do case "$1" in
  exec|-p|--json) shift;;
  -o) out="$2"; shift 2;;
  --output-schema) schema="$(cat "$2")"; shift 2;;
  --json-schema) schema="$2"; shift 2;;
  --sandbox) [ "$2" = workspace-write ] && editing=1; shift 2;;
  --permission-mode) editing=1; shift 2;;
  -m|-c|--model|--effort|--output-format|--tools|--allowedTools|--disallowedTools|--append-system-prompt|--session-id|--resume) shift 2;;
  *) prompt="$1"; shift;;
esac; done
usage='"session_id":"fake","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
[ "$cli" = codex ] && printf '{"type":"thread.started","thread_id":"mock-thread-%s"}\n' "$$"
emit() { if [ "$cli" = codex ]; then if [ -n "$out" ]; then printf '%s\n' "$1" > "$out"; else printf '%s\n' "$1"; fi; else printf '{"structured_output":%s,%s}\n' "$1" "$usage"; fi; }
role=""
case "$schema" in
  *'"blocking_issues"'*) role=validator;;
  *'"issues"'*) role=reviewer;;
  *'"context_updates"'*) role=worker;;
  "") [ "$editing" = 1 ] && role=editor;;
esac
[ -n "$role" ] || { echo "UNKNOWN-ROLE" >> "$MOCK_LOG"; exit 1; }
case "$role" in
  validator)
    target=unknown
    if printf '%s' "$prompt" | grep -q '구현 문서 검증자'; then target=impl; elif printf '%s' "$prompt" | grep -q '설계 검증자'; then target=design; fi
    q="$MOCK_STATE/verdicts-$target"; mode=PASS
    if [ -s "$q" ]; then mode="$(head -1 "$q")"; tail -n +2 "$q" > "$q.tmp"; mv "$q.tmp" "$q"; fi
    echo "validator $target" >> "$MOCK_LOG"
    origin=ROUND_1; prev=""
    if printf '%s' "$prompt" | grep -q '종결 검토'; then origin=UNRESOLVED_PREVIOUS; prev=B-01; fi
    ask='{"id":"B-01","action":"ASK_USER","category":"POLICY_UNDECIDED","change_relation":"INTRODUCED_BY_FEATURE","evidence_type":"UNDECIDED_CHOICE","basis_refs":["request.md:L1-L1"],"conflict_refs":[],"code_refs":[],"reachable_scenario":"","impact":"정책에 따라 동작이 갈림","why_blocks_now":"w","minimum_contract_needed":"","user_question":"어느 정책?","options":["a","b"],"origin":"ROUND_1","previous_issue_id":"","revision_ref":""}'
    revise() { # id minimum_contract origin previous_issue_id
      jq -nc --arg id "$1" --arg m "$2" --arg o "$3" --arg p "$4" '{id:$id, action:"REVISE_DOC", category:"REQUIREMENT_MISSING", change_relation:"INTRODUCED_BY_FEATURE", evidence_type:"DIRECT_MISMATCH",
        basis_refs:["request.md:L1-L1"], conflict_refs:["design.md:L1-L1"], code_refs:[], reachable_scenario:"", impact:"요구 누락", why_blocks_now:"w", minimum_contract_needed:$m,
        user_question:"", options:[], origin:$o, previous_issue_id:$p, revision_ref:""}'
    }
    case "$mode" in
      PASS) emit "{\"schema_version\":$MOCK_VALIDATOR_CONTRACT,\"verdict\":\"PASS\",\"blocking_issues\":[]}";;
      ASK) emit "{\"schema_version\":$MOCK_VALIDATOR_CONTRACT,\"verdict\":\"BLOCK\",\"blocking_issues\":[$ask]}";;
      ASK2) emit "{\"schema_version\":$MOCK_VALIDATOR_CONTRACT,\"verdict\":\"BLOCK\",\"blocking_issues\":[$ask,$(revise B-02 "오류 응답 계약을 명시한다" ROUND_1 "")]}";;
      BLOCK*) emit "{\"schema_version\":$MOCK_VALIDATOR_CONTRACT,\"verdict\":\"BLOCK\",\"blocking_issues\":[$(revise B-01 "${mode#BLOCK }" "$origin" "$prev")]}";;
      CRASH) exit 1;;
    esac; exit 0;;
  editor) echo "editor" >> "$MOCK_LOG"; if [ "$cli" = codex ]; then echo ok; else printf '{"result":"ok",%s}\n' "$usage"; fi; exit 0;;
  reviewer) echo "reviewer" >> "$MOCK_LOG"; emit "{\"schema_version\":$MOCK_REVIEW_CONTRACT,\"verdict\":\"APPROVE\",\"issues\":[]}"; exit 0;;
esac
unit="$(printf '%s' "$prompt" | grep -oE '"id": *"[0-9]+-[a-z0-9-]+"' | head -1 | sed -E 's/.*"([0-9]+-[a-z0-9-]+)"/\1/')"
n="${unit%%-*}"
echo "worker ${unit:-none}" >> "$MOCK_LOG"
echo "worker $unit" >> "src/u$n.txt"
if [ -f "$MOCK_STATE/undecided-$n" ]; then
  mv "$MOCK_STATE/undecided-$n" "$MOCK_STATE/undecided-$n.used"
  emit "$(printf '{"status":"UNDECIDED","undecided":[{"kind":"DOC_GAP","location":"src/u%s.txt","decision_needed":"상태 전이 위치","options":["서비스","도메인 객체"]}],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}' "$n")"; exit 0
fi
emit "$(printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[{"name":"u%s","result":"PASS"}],"context_updates":{"upsert":[],"remove":[]}}' "$n")"
exit 0
EOF
chmod +x "$TMP/bin/mock-cli"; cp "$TMP/bin/mock-cli" "$TMP/bin/claude"; cp "$TMP/bin/mock-cli" "$TMP/bin/codex"

N=0
fresh() { # max_rounds — 새 피처 상태(테스트 환경 정리: 이전 산출물은 옮겨 둔다)
  N=$((N + 1))
  [ ! -d .agent-work ] || mv .agent-work "$TMP/old-work-$N"
  mkdir -p "$TMP/old-state-$N"; mv "$MOCK_STATE"/* "$TMP/old-state-$N/" 2>/dev/null
  [ ! -e conventions.md ] || mv conventions.md "$TMP/old-conventions-$N"
  git checkout -q -- src
  mkdir -p .agent-work/reviews
  for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
  printf '\n## 01\nunit 01 contract\n\n## 02\nunit 02 contract\n\n## 03\nunit 03 contract\n' >> .agent-work/implementation.md   # unit references(implementation.md#NN)가 가리키는 절 — 러너가 그 절 본문으로 unit 별 계약 변경을 판정한다
  : > .agent-work/decisions.md
  printf '{"version":1,"files":["src/u01.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
  cat > .agent-work/implementation-units.json <<EOF
{"version":1,"units":[
 {"id":"01-intake","title":"접수","goal":"unit 01","requirements":["REQ-01"],"scope":{"files":["src/u01.txt"],"new_file_roots":[]},"references":["implementation.md#01"],"targeted_test":"echo test-01 >> $TMP/calls.log"}
]}
EOF
  set_max_rounds "${1:-1}"
}
verdicts() { printf '%s\n' "${@:2}" > "$MOCK_STATE/verdicts-$1"; } # target mode...
run_runner() { : > "$MOCK_LOG"; bash "$RUN" > "$TMP/run.log" 2>&1; echo $?; }
run_loop() { : > "$MOCK_LOG"; bash "$LOOP" "$1" > "$TMP/loop.log" 2>&1; echo $?; }
reason() { jq -r '.reason' .agent-work/run-state.json; }
status() { jq -r '.status' .agent-work/run-state.json; }
calls() { paste -sd'|' "$MOCK_LOG"; }
count() { grep -c "^$1" "$MOCK_LOG" 2>/dev/null || true; }
esc() { jq -r "$2" ".agent-work/user-escalation-resume-$1.json"; } # target filter
cfg() { ( source "$CFG"; "$@" ); }
answer() { printf -- '- [USER-QUESTION][scope=%s][escalation=%s] %s → %s\n' "$1" "$2" "$3" "$4" >> .agent-work/decisions.md; } # scope id question answer
no_models() { [ ! -s "$MOCK_LOG" ] || fail "$1: 모델/테스트가 호출됨: $(calls)"; }
DONE_TAIL="worker 01-intake|test-01|reviewer|full-test|full-lint"

# ===== 사례 1: design ASK_USER =====
fresh; verdicts design ASK
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(status)" = NEED_USER ] && [ "$(reason)" = ASK_USER ] || { tail -20 "$TMP/run.log"; fail "1: exit 2/NEED_USER/ASK_USER 기대, 실제 $rc/$(status)/$(reason)"; }
[ "$(calls)" = "validator design" ] || fail "1: 호출 불일치: $(calls)"
REVIEW_1="$(esc design .review)"
jq -e --argjson cv "$CONTRACT" '.version==1 and .target=="design" and .reason=="ASK_USER" and .next_step=="WAITING_USER" and .contract_version==$cv and (.issues|length)==1
  and .issues[0].id=="B-01" and .issues[0].tag=="escalation=B-01" and .issues[0].question=="어느 정책?" and (.issues[0].options|length)==2 and .issues[0].basis_refs==["request.md:L1-L1"]
  and .review_sha256!="" and .escalated.input_fingerprint!="" and .escalated.upstream_fingerprint!="" and .frozen_inputs_hash!="" and .resolved_input_fingerprint==""' \
  .agent-work/user-escalation-resume-design.json >/dev/null || fail "1: 에스컬레이션 체크포인트 불일치: $(cat .agent-work/user-escalation-resume-design.json)"
[ -f "$REVIEW_1" ] && jq -e '.verdict=="BLOCK"' "$REVIEW_1" >/dev/null || fail "1: 원본 리뷰가 보존되지 않음"
grep -q 'escalation=<id>' .agent-work/run-state.json && grep -q 'B-01' .agent-work/run-state.json && grep -q '어느 정책?' .agent-work/run-state.json || fail "1: detail 에 답 형식·blocker id·질문이 없음"
# (5) 답 없는 단순 재실행 — 모델 0회, 대기 유지
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = ASK_USER ] || fail "1(재실행): exit 2/ASK_USER 기대, 실제 $rc/$(reason)"
no_models "1(재실행)"; [ "$(esc design .next_step)" = WAITING_USER ] || fail "1(재실행): WAITING_USER 가 아님"
# (4) 태그 없는 답 / 빈 답 / scope 불일치 / id 불일치 — 전부 답이 아니다
echo '- [USER-QUESTION][scope=design] 어느 정책? → a' >> .agent-work/decisions.md
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = ASK_USER ] || fail "1(태그 없는 답): 수리됨 ($rc/$(reason))"; no_models "1(태그 없는 답)"
printf -- '- [USER-QUESTION][scope=design][escalation=B-01] 어느 정책? → \n' >> .agent-work/decisions.md
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = ASK_USER ] || fail "1(빈 답): 수리됨 ($rc/$(reason))"; no_models "1(빈 답)"
answer impl B-01 "어느 정책?" a
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = ASK_USER ] || fail "1(scope 불일치): 수리됨 ($rc/$(reason))"; no_models "1(scope 불일치)"
answer design B-99 "어느 정책?" a
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = ASK_USER ] || fail "1(id 불일치): 수리됨 ($rc/$(reason))"; no_models "1(id 불일치)"
# 플레이스홀더 답(안내 형식을 채우지 않음) / 그 blocker 의 질문 문구와 다른 줄 — 답이 아니다
answer design B-01 "어느 정책?" "<답>"
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = ASK_USER ] || fail "1(플레이스홀더 답): 수리됨 ($rc/$(reason))"; no_models "1(플레이스홀더 답)"
answer design B-01 "어느 정책?" "<선택한 option>"
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = ASK_USER ] || fail "1(플레이스홀더 답 2): 수리됨 ($rc/$(reason))"; no_models "1(플레이스홀더 답 2)"
answer design B-01 "다른 질문" a
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = ASK_USER ] || fail "1(질문 불일치): 수리됨 ($rc/$(reason))"; no_models "1(질문 불일치)"
[ "$(esc design .next_step)" = WAITING_USER ] && grep -q '답 없는 blocker: B-01' .agent-work/run-state.json || fail "1: 잘못된 답 뒤 WAITING_USER/미답 안내가 아님"
# 실제 답은 있지만 design.md 가 발생 시점과 같다 — ASK_USER 의 선택이 문서에 반영되지 않았으므로 수리되지 않는다(모델 0회)
answer design B-01 "어느 정책?" a
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = ASK_USER ] || fail "1(문서 미반영): 수리됨 ($rc/$(reason))"; no_models "1(문서 미반영)"
[ "$(esc design .next_step)" = WAITING_USER ] && grep -q '답 없는 blocker: 없음' .agent-work/run-state.json && grep -q '문서 미반영' .agent-work/run-state.json \
  && jq -e '.docs_unsynced==true' .agent-work/state.json >/dev/null || fail "1(문서 미반영): WAITING_USER/문서 미반영 안내가 아님"
pass "1: design ASK_USER → NEED_USER, 답 없음·태그 없음·빈 답·플레이스홀더·scope/id/질문 불일치·문서 미반영은 모델 0회로 대기"
# 답 + design.md 반영 → design 검증자/디자이너 0회, impl 로. impl 검증자가 crash 해도(중간 종료) 재개는 design 검증자를 부르지 않는다
printf '\n## 정책 (사용자 결정 B-01)\na 를 쓴다.\n' >> .agent-work/design.md
verdicts impl CRASH
rc="$(run_runner)"
[ "$rc" -eq 1 ] && [ "$(calls)" = "validator impl" ] || { tail -20 "$TMP/run.log"; fail "1: 수리 뒤 design 검증자/디자이너 0회·impl 도달 기대, 실제 exit $rc / $(calls)"; }
[ "$(esc design .next_step)" = USER_RESOLVED ] && [ -n "$(esc design .resolved_input_fingerprint)" ] && [ "$(esc design '.answers|length')" -eq 1 ] || fail "1: USER_RESOLVED 가 아님: $(cat .agent-work/user-escalation-resume-design.json)"
esc design '.answers[0].line' | grep -qF '[escalation=B-01] 어느 정책? → a' || fail "1: 수리된 답 줄이 기록되지 않음"
[ "$(jq -r .next_step .agent-work/consensus-design.json)" != PASS ] || fail "1: consensus-design.json 이 PASS 로 위조됨"
cfg consensus_pass_current design && fail "1: 사용자 수리가 검증자 PASS 로 판정됨"
jq -e '.verdict=="BLOCK"' "$REVIEW_1" >/dev/null || fail "1: 리뷰 JSON 의 BLOCK 이 덮어써짐"
grep -q 'USER_RESOLVED' "$TMP/run.log" || fail "1: 로그에 USER_RESOLVED(검증자 PASS 아님) 표시가 없음"
# (6) 합의 루프 단독 재실행 — 검증자 0회, exit 0, status USER_RESOLVED
rc="$(run_loop design)"; [ "$rc" -eq 0 ] && [ "$(jq -r .status .agent-work/state.json)" = USER_RESOLVED ] || { tail -10 "$TMP/loop.log"; fail "1: 루프 단독 재실행이 USER_RESOLVED exit 0 이 아님 ($rc)"; }
no_models "1(루프 단독)"
# (6)(9) 재개: design 검증자 0회, impl 합의는 정상 수행, review·verify 를 거쳐서만 DONE
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "1: 재개 exit 0/DONE 기대, 실제 $rc/$(status)"; }
[ "$(calls)" = "validator impl|$DONE_TAIL" ] || fail "1: 재개 호출 순서 불일치(design 검증자 0, impl 합의 정상, 리뷰·테스트 유지): $(calls)"
cfg consensus_pass_current impl || fail "1: impl 은 정상 검증자 PASS 여야 함"
pass "1: 답 + design.md 반영 → design 검증자·디자이너 0회, impl 합의 정상 수행, 중간 종료·루프 단독 재실행도 재검증 없음, review/verify 뒤 DONE"

# ===== 사례 2: impl ASK_USER (blocker 2개) =====
fresh; verdicts impl ASK2
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = ASK_USER ] && [ "$(calls)" = "validator design|validator impl" ] || { tail -20 "$TMP/run.log"; fail "2: exit 2/ASK_USER 기대, 실제 $rc/$(reason) / $(calls)"; }
[ "$(esc impl '[.issues[].id]|join(",")')" = "B-01,B-02" ] && [ "$(esc impl '.issues[1].action')" = REVISE_DOC ] || fail "2: 같은 리뷰의 REVISE_DOC blocker 가 에스컬레이션에 없음"
cfg consensus_pass_current design || fail "2: design PASS 가 유지되지 않음"
# 하나만 답 → NEED_USER, 모델 0회
answer impl B-01 "어느 정책?" b
printf '\n## 정책 (사용자 결정 B-01)\nb 를 쓴다.\n' >> .agent-work/approach.md
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = ASK_USER ] || fail "2(일부 답): 수리됨 ($rc/$(reason))"; no_models "2(일부 답)"
grep -q '답 없는 blocker: B-02' .agent-work/run-state.json && [ "$(esc impl .next_step)" = WAITING_USER ] || fail "2(일부 답): 미답 blocker 안내/WAITING_USER 가 아님"
# 나머지(REVISE_DOC 요구 기각)도 답 → impl 검증자/디자이너 0회, worker 로
answer impl B-02 "오류 응답 계약을 명시한다" "기각 — 기존 공통 오류 응답을 그대로 쓴다"
touch "$MOCK_STATE/undecided-01"   # 사례 8: 워커가 DOC_GAP 을 낸다
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] && [ "$(calls)" = "worker 01-intake" ] || { tail -20 "$TMP/run.log"; fail "2: 수리 뒤 impl 검증자/디자이너 0회·worker 도달 기대, 실제 $rc/$(reason) / $(calls)"; }
[ "$(esc impl .next_step)" = USER_RESOLVED ] && [ "$(esc impl '.answers|length')" -eq 2 ] || fail "2: impl USER_RESOLVED 가 아님"
[ "$(jq -r .next_step .agent-work/consensus-impl.json)" != PASS ] || fail "2: consensus-impl.json 이 PASS 로 위조됨"
pass "2: impl ASK_USER — 일부 답은 모델 0회 대기, 전부 답하면 impl 검증자·디자이너 0회로 worker 도달"
# ===== 사례 8: impl 사용자 수리 뒤 워커 DOC_GAP → 기존 doc-gap 직접 재개 =====
jq -e '.next_step=="WAITING_USER" and .origin=="worker" and .base_kind=="USER_RESOLVED" and .base_pass_fingerprint!=""' .agent-work/doc-gap-resume.json >/dev/null \
  || fail "8: doc-gap 체크포인트의 밑바탕이 USER_RESOLVED 가 아님: $(cat .agent-work/doc-gap-resume.json)"
[ "$(jq -r .base_pass_fingerprint .agent-work/doc-gap-resume.json)" = "$(esc impl .resolved_input_fingerprint)" ] || fail "8: 밑바탕 지문이 impl 수리 지문과 다름"
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] || fail "8(답 없음): $rc/$(reason)"; no_models "8(답 없음)"
printf -- '- [USER-QUESTION][scope=impl][worker-gap=01-intake#1] 상태 전이 위치 → 도메인 객체\n' >> .agent-work/decisions.md
printf '\n## 결정 01-intake (REQUIRED)\n상태 전이는 도메인 객체가 한다.\n' >> .agent-work/approach.md
cfg user_escalation_resolved_current impl && fail "8: 전제 — gap 해결로 impl 입력이 바뀌었는데 수리 지문이 여전히 현재와 같음"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "8: exit 0/DONE 기대, 실제 $rc/$(status)"; }
[ "$(calls)" = "$DONE_TAIL" ] || fail "8: 호출 순서 불일치(검증자·디자이너 0, 워커 → 테스트 → 리뷰): $(calls)"
[ "$(jq -r .next_step .agent-work/doc-gap-resume.json)" = RESOLVED ] && [ "$(esc impl .next_step)" = USER_RESOLVED ] || fail "8: doc-gap RESOLVED / impl USER_RESOLVED 가 아님"
pass "8: impl 사용자 수리 → 워커 DOC_GAP → 사용자 답 → 검증자 0회로 doc-gap 직접 재개(밑바탕 USER_RESOLVED) → DONE"

# ===== 사례 3: DEADLOCK · MAX_ROUNDS_EXCEEDED × design · impl =====
for target in design impl; do
  for kind in DEADLOCK MAX_ROUNDS_EXCEEDED; do
    if [ "$kind" = DEADLOCK ]; then fresh 2; verdicts "$target" "BLOCK 같은 불변식" "BLOCK 같은 불변식"
    else fresh 1; verdicts "$target" "BLOCK 불변식 v1" "BLOCK 불변식 v2"; fi
    want_reason="${kind%_EXCEEDED}"; pre=""; [ "$target" = design ] || pre="validator design|"
    rc="$(run_runner)"
    [ "$rc" -eq 2 ] && [ "$(reason)" = "$want_reason" ] || { tail -20 "$TMP/run.log"; fail "3($target/$kind): exit 2/$want_reason 기대, 실제 $rc/$(reason)"; }
    [ "$(calls)" = "${pre}validator $target|editor|validator $target" ] || fail "3($target/$kind): 호출 불일치: $(calls)"
    review="$(esc "$target" .review)"
    [ "$review" = ".agent-work/reviews/validator-$target-round-02.json" ] && [ "$(jq -r .review .agent-work/state.json)" = "$review" ] && [ "$(esc "$target" .reason)" = "$kind" ] \
      && [ "$(esc "$target" '.issues[0].id')" = B-01 ] && [ "$(esc "$target" .round)" -eq 2 ] || fail "3($target/$kind): 마지막 실제 리뷰가 보존되지 않음: $(cat ".agent-work/user-escalation-resume-$target.json")"
    [ "$(jq -r .next_step ".agent-work/consensus-$target.json")" = VALIDATOR_PENDING ] || fail "3($target/$kind): 합의 체크포인트 상태가 예상과 다름"
    rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = "$want_reason" ] || fail "3($target/$kind, 답 없음): $rc/$(reason)"; no_models "3($target/$kind, 답 없음)"
    answer "$target" B-01 "$(esc "$target" '.issues[0].question')" "기각 — 요구 범위 밖"
    rc="$(run_runner)"
    [ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "3($target/$kind): 답 뒤 exit 0/DONE 기대, 실제 $rc/$(status)"; }
    if [ "$target" = design ]; then want="validator impl|$DONE_TAIL"; else want="$DONE_TAIL"; fi
    [ "$(calls)" = "$want" ] || fail "3($target/$kind): 답 뒤 $target 검증자·디자이너가 호출됐거나 순서 불일치: $(calls)"
    [ "$(esc "$target" .next_step)" = USER_RESOLVED ] && jq -e '.verdict=="BLOCK"' "$review" >/dev/null || fail "3($target/$kind): USER_RESOLVED 가 아니거나 리뷰 BLOCK 이 덮어써짐"
  done
done
pass "3: design/impl × DEADLOCK/MAX_ROUNDS_EXCEEDED — 마지막 리뷰 보존, 답 전 모델 0회, 답 뒤 그 단계 검증자·디자이너 0회로 다음 단계"

# ===== 사례 7: 잘못된 우회 차단 =====
# 7-a 대기 중 request.md 변경(답은 있음) → SUPERSEDED, Round 1 재합의
fresh; verdicts design ASK; rc="$(run_loop design)"; [ "$rc" -eq 2 ] || fail "7-a: 전제 실패"
answer design B-01 "어느 정책?" a; echo "새 요구" >> .agent-work/request.md
rc="$(run_loop design)"
[ "$rc" -eq 0 ] && [ "$(calls)" = "validator design" ] && [ "$(esc design .next_step)" = SUPERSEDED ] && [ "$(jq -r .status .agent-work/state.json)" = PASS ] \
  || { tail -10 "$TMP/loop.log"; fail "7-a: request.md 변경이 사용자 결정으로 우회됨 ($rc / $(calls) / $(esc design .next_step))"; }
# 7-b 대기 중 conventions.md 생성 → 재합의
fresh; verdicts design ASK; rc="$(run_loop design)"; [ "$rc" -eq 2 ] || fail "7-b: 전제 실패"
answer design B-01 "어느 정책?" a; printf '# conventions\n- 규칙\n' > conventions.md
rc="$(run_loop design)"
[ "$(calls)" = "validator design" ] && [ "$(esc design .next_step)" = SUPERSEDED ] || fail "7-b: conventions 변경이 우회됨 ($(calls) / $(esc design .next_step))"
# 7-c 대기 중 decisions.md 기존 줄 수정 → 재합의
fresh; echo '- [round 0] 기존 이력' > .agent-work/decisions.md; verdicts design ASK; rc="$(run_loop design)"; [ "$rc" -eq 2 ] || fail "7-c: 전제 실패"
echo '- [round 0] 고친 이력' > .agent-work/decisions.md; answer design B-01 "어느 정책?" a
rc="$(run_loop design)"
[ "$(calls)" = "validator design" ] && [ "$(esc design .next_step)" = SUPERSEDED ] || fail "7-c: decisions.md 기존 줄 수정이 우회됨 ($(calls) / $(esc design .next_step))"
# 7-d impl 대기 중 범위(implementation-units.json) 변경 → 러너가 impl 재합의
fresh; verdicts impl ASK; rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = ASK_USER ] || fail "7-d: 전제 실패"
answer impl B-01 "어느 정책?" a
sed -i.bak 's/"goal":"unit 01"/"goal":"unit 01 확장"/' .agent-work/implementation-units.json && mv .agent-work/implementation-units.json.bak "$TMP/units.bak-$N"
rc="$(run_runner)"
[ "$(count 'validator impl')" -eq 1 ] && [ "$(count 'validator design')" -eq 0 ] && [ "$(esc impl .next_step)" = SUPERSEDED ] || { tail -20 "$TMP/run.log"; fail "7-d: 범위 변경이 우회됨 ($(calls) / $(esc impl .next_step))"; }
# 7-e 수리 뒤 design.md 추가 변경 → 이전 사용자 결정으로 계속 우회하지 않는다(러너가 design 부터 재합의)
fresh; verdicts design ASK; rc="$(run_loop design)"; [ "$rc" -eq 2 ] || fail "7-e: 전제 실패"
answer design B-01 "어느 정책?" a; echo "정책 a (사용자 결정 B-01)" >> .agent-work/design.md
rc="$(run_loop design)"; [ "$rc" -eq 0 ] && [ "$(esc design .next_step)" = USER_RESOLVED ] || fail "7-e: 전제(USER_RESOLVED) 실패"
cfg consensus_stage_accepted design || fail "7-e: 전제 — 수리 직후 design 진입 권한이 없음"
# 7-f 계약 버전이 바뀌면 수리 상태는 적용되지 않는다 / 7-g 리뷰 JSON 변조
( source "$CFG"; VALIDATOR_CONTRACT_VERSION=$((VALIDATOR_CONTRACT_VERSION + 1)); user_escalation_resolved_current design ) && fail "7-f: 검증 계약 버전이 바뀌었는데 수리 상태가 유효함"
( source "$CFG"; CONSENSUS_CHECKPOINT_VERSION=$((CONSENSUS_CHECKPOINT_VERSION + 1)); user_escalation_resolved_current design ) && fail "7-f: 체크포인트 버전이 바뀌었는데 수리 상태가 유효함"
review="$(esc design .review)"; cp "$review" "$TMP/review.keep"
jq '.verdict="PASS" | .blocking_issues=[]' "$TMP/review.keep" > "$review"
cfg user_escalation_resolved_current design && fail "7-g: 리뷰 JSON 이 변조됐는데 수리 상태가 유효함"
cp "$TMP/review.keep" "$review"; cfg user_escalation_resolved_current design || fail "7-g: 리뷰를 되돌렸는데 수리 상태가 복구되지 않음"
echo "수리 뒤 추가 변경" >> .agent-work/design.md
cfg consensus_stage_accepted design && fail "7-e: 수리 뒤 design.md 를 또 바꿨는데 design 진입 권한이 유지됨"
printf '{"stage":"impl","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
rc="$(run_runner)"
grep -q 'design 부터' "$TMP/run.log" && [ "$(count 'validator design')" -eq 1 ] && [ "$(esc design .next_step)" = SUPERSEDED ] || { tail -20 "$TMP/run.log"; fail "7-e: 수리 뒤 문서 변경이 design 재합의를 거치지 않음 ($(calls))"; }
# 7-h 손으로 만든 USER_RESOLVED(수리 지문·답 기록 없음)는 인정되지 않는다
fresh; verdicts design ASK; rc="$(run_loop design)"; [ "$rc" -eq 2 ] || fail "7-h: 전제 실패"
jq '.next_step="USER_RESOLVED"' .agent-work/user-escalation-resume-design.json > "$TMP/forged.json" && cp "$TMP/forged.json" .agent-work/user-escalation-resume-design.json
cfg consensus_stage_accepted design && fail "7-h: 답·수리 지문 없는 USER_RESOLVED 가 유효로 판정됨"
jq --arg fp "$(cfg consensus_pass_fingerprint design)" '.resolved_input_fingerprint=$fp' "$TMP/forged.json" > .agent-work/user-escalation-resume-design.json
cfg consensus_stage_accepted design && fail "7-h: 답 기록 없는 USER_RESOLVED 가 유효로 판정됨"
pass "7: request/conventions/범위/decisions 기존 줄 변경·수리 뒤 추가 변경·계약 버전 변경·리뷰 변조·손으로 만든 상태 → 우회 차단(정상 재합의 또는 무효)"

rm -rf "$TMP"
echo "smoke-user-escalation-resume: 전부 통과"
