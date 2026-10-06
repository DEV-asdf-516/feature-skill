#!/usr/bin/env bash
# =============================================================
# 스모크: 합의 루프의 판정 격리 — 실제 LLM 호출 없음 (mock claude, codex 는 호출되면 실패하는 스텁), 임시 저장소
# 파일 경로: tests/smoke-consensus-isolation.sh
# 사용법: bash tests/smoke-consensus-isolation.sh   (어디서든 실행 가능)
#
# 불변식: 사실·계약(문서, 사용자 결정, 직전 blocker 의 주장·증거 위치, 실제 문서 diff)은 공유하고 판단 과정은 격리한다.
# 사례:
#   A. BLOCK → 디자이너 → BLOCK → 디자이너 → PASS (MAX_SPEC_ROUNDS=2)
#      - 검증자는 호출마다 fresh 세션(--session-id, 서로 다른 id, --resume 없음)
#      - 디자이너는 stage 세션을 이어간다(1회차 --session-id, 2회차 같은 id 로 --resume)
#      - 종결 검증자 입력에 디자이너 ACCEPT/REJECT 사유·직전 검증자 서술이 없다(프롬프트·prev-blockers·docs diff)
#      - 종결 검증자는 직전 blocker 의 구조화된 주장·증거(refs·reachable_scenario·impact·불변식)와 문서 diff 를 받는다
#      - [USER-QUESTION] 사용자 결정은 매 라운드 검증자에게 전달된다 — decisions.md 원본이 아니라 scope 로 추린 확정 결정 파일로, 합의 이력 줄 없이
#      - 디자이너는 blocker 의 구조화된 주장·증거를 받고 검증자 자유 서술(why_blocks_now)은 받지 않는다
#   B. 같은 내용의 blocker 2라운드 연속 → DEADLOCK (exit 2)
#   C. ASK_USER → exit 2, 디자이너 0회. 재실행(Round 1 재시작)도 검증자는 옛 세션을 --resume 하지 않는다
#   D. MAX_SPEC_ROUNDS=1 에서 수렴 실패 → MAX_ROUNDS_EXCEEDED (exit 2)
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-isolation-$$"
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/repo/.claude/hooks"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
# 역할 CLI 를 claude 로 고정한다(세션 플래그는 claude 경로에만 있다). codex 는 쓰이지 않으므로 호출되면 실패하는 스텁.
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^VALIDATOR_CLI=.*|VALIDATOR_CLI=\"claude\"|; s|^DESIGNER_CLI=.*|DESIGNER_CLI=\"claude\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"true\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"true\"|" "$CFG" && rm -f "$CFG.bak"
set_max_rounds() { sed -i.bak "s/^MAX_SPEC_ROUNDS=.*/MAX_SPEC_ROUNDS=$1/" "$CFG" && rm -f "$CFG.bak"; }
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && echo "base" > src/u01.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
LOOP=".claude/skills/feature/scripts/consensus-loop.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/state" FEATURE_LIVE_TEE=1

cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
echo "codex-called" >> "$MOCK_LOG"; exit 1
EOF
# --- mock claude: --json-schema 가 있으면 검증자(읽기 전용), --permission-mode 가 있으면 디자이너.
#     검증자 n 번째 호출은 $MOCK_STATE/verdict-n.json 을 structured_output 으로 낸다. 프롬프트와 세션 플래그를 기록한다. ---
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
kind=""; session=""; prompt=""
while [ "$#" -gt 0 ]; do case "$1" in
  --session-id|--resume) session="$1 $2"; shift 2;;
  --json-schema) kind=validator; shift 2;;
  --permission-mode) kind=designer; shift 2;;
  --model|--effort|--output-format|--tools|--allowedTools|--disallowedTools|--append-system-prompt) shift 2;;
  -p) shift;;
  *) prompt="$1"; shift;;
esac; done
count_file="$MOCK_STATE/$kind.n"; n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$count_file"
echo "$kind $n $session" >> "$MOCK_LOG"
printf '%s' "$prompt" > "$MOCK_STATE/$kind-$n.prompt"
usage='"session_id":"fake","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
if [ "$kind" = validator ]; then
  cp .agent-work/reviews/user-decisions-design.md "$MOCK_STATE/user-decisions-$n.md"   # 호출 시점의 확정 사용자 결정 파일
  jq -c --slurpfile r "$MOCK_STATE/verdict-$n.json" '{structured_output: $r[0]} + .' <<< "{$usage}"
else
  echo "revised by designer call $n" >> .agent-work/design.md
  echo "- [round $n] B-01 ACCEPT: DESIGNER-PRIVATE-REASON-$n" >> .agent-work/decisions.md
  printf '{%s}\n' "$usage"
fi
EOF
chmod +x "$TMP/bin/codex" "$TMP/bin/claude"

issue() { # origin previous_issue_id minimum_contract action
  local action="${4:-REVISE_DOC}"
  jq -nc --arg o "$1" --arg p "$2" --arg m "$3" --arg a "$action" '
    {id:"B-01", action:$a, category:(if $a=="ASK_USER" then "POLICY_UNDECIDED" else "REQUIREMENT_MISSING" end), change_relation:"INTRODUCED_BY_FEATURE",
     evidence_type:(if $a=="ASK_USER" then "UNDECIDED_CHOICE" else "DIRECT_MISMATCH" end), basis_refs:["request.md:L1-L1"],
     conflict_refs:(if $a=="ASK_USER" then [] else ["design.md:L1-L1"] end), code_refs:[], reachable_scenario:"",
     impact:"IMPACT-CLAIM", why_blocks_now:"VALIDATOR-PRIVATE-WHY",
     minimum_contract_needed:(if $a=="ASK_USER" then "" else $m end), user_question:(if $a=="ASK_USER" then "어느 정책?" else "" end),
     options:(if $a=="ASK_USER" then ["a","b"] else [] end), origin:$o, previous_issue_id:$p, revision_ref:""}'
}
verdict() { # n PASS | n BLOCK <issue-json>
  if [ "$2" = PASS ]; then printf '{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}\n' "$CONTRACT" > "$MOCK_STATE/verdict-$1.json"
  else printf '{"schema_version":%s,"verdict":"BLOCK","blocking_issues":[%s]}\n' "$CONTRACT" "$3" > "$MOCK_STATE/verdict-$1.json"; fi
}
reset_case() { # max_rounds
  mkdir -p "$TMP/old-$1-$RANDOM" && mv .agent-work "$_" 2>/dev/null
  mkdir -p .agent-work/reviews
  for doc in request design; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
  printf '%s\n' '- [USER-QUESTION][scope=design] 보존 기간 → 30일 USER-DECISION-MARK' '- [USER-QUESTION][scope=impl] 재시도 → 없음 IMPL-DECISION-MARK' > .agent-work/decisions.md
  mkdir -p "$TMP/state-old-$RANDOM" && mv "$MOCK_STATE"/* "$_" 2>/dev/null
  : > "$MOCK_LOG"; set_max_rounds "$1"
}
run_loop() { bash "$LOOP" design > "$TMP/loop.log" 2>&1; echo $?; }
status() { jq -r '.status' .agent-work/state.json; }
session_ids() { grep "^$1 " "$MOCK_LOG" | awk '{print $4}'; }
session_flags() { grep "^$1 " "$MOCK_LOG" | awk '{print $3}' | paste -sd' ' -; }

# ===== 사례 A =====
reset_case 2
verdict 1 BLOCK "$(issue ROUND_1 "" "불변식 v1")"
verdict 2 BLOCK "$(issue UNRESOLVED_PREVIOUS B-01 "불변식 v2")"
verdict 3 PASS
rc="$(run_loop)"
[ "$rc" -eq 0 ] && [ "$(status)" = PASS ] || { tail -30 "$TMP/loop.log"; fail "A: BLOCK→수정→BLOCK→수정→PASS 흐름 실패 (exit $rc / $(status))"; }
grep -q 'codex-called' "$MOCK_LOG" && fail "A: 역할 CLI 를 claude 로 고정했는데 codex 가 호출됨"
[ "$(grep -c '^validator ' "$MOCK_LOG")" -eq 3 ] && [ "$(grep -c '^designer ' "$MOCK_LOG")" -eq 2 ] || fail "A: 호출 횟수 불일치: $(paste -sd'|' "$MOCK_LOG")"
pass "A: BLOCK → 디자이너 수정 → 재검증 → PASS 흐름 정상"

[ "$(session_flags validator)" = "--session-id --session-id --session-id" ] || fail "A: 검증자가 fresh 세션이 아님: $(session_flags validator)"
[ "$(session_ids validator | sort -u | grep -c .)" -eq 3 ] || fail "A: 검증자 라운드별 세션 id 가 서로 다르지 않음: $(session_ids validator | paste -sd, -)"
pass "A: 검증자 Round 1/2/3 이 서로 다른 fresh 세션"
[ "$(session_flags designer)" = "--session-id --resume" ] || fail "A: 디자이너 세션 재사용 정책이 깨짐: $(session_flags designer)"
[ "$(session_ids designer | sort -u | grep -c .)" -eq 1 ] || fail "A: 디자이너 2회차가 같은 세션을 잇지 않음"
session_ids validator | grep -qx "$(session_ids designer | head -1)" && fail "A: 검증자와 디자이너가 같은 세션을 씀"
pass "A: 디자이너는 stage 세션 유지(--session-id → --resume), 검증자와 분리"

r2="$MOCK_STATE/validator-2.prompt"; prev=".agent-work/reviews/prev-blockers-design-round-02.json"; diff=".agent-work/reviews/docs-diff-design-round-02.diff"
grep -q 'DESIGNER-PRIVATE-REASON' .agent-work/decisions.md || fail "A: 전제 — 디자이너 사유가 decisions.md 에 기록되지 않음"
grep -q 'DESIGNER-PRIVATE-REASON\|VALIDATOR-PRIVATE-WHY' "$r2" && fail "A: 종결 검증자 프롬프트에 디자이너 사유 또는 직전 검증자 서술이 들어감"
grep -q '디자이너의 ACCEPT/REJECT 판정 =' "$r2" && fail "A: 종결 검증자 프롬프트가 디자이너 ACCEPT/REJECT 기록을 입력으로 지정함"
grep -q 'validator-design-round-01.json' "$r2" && fail "A: 종결 검증자에게 직전 리뷰 원문(JSON) 경로가 전달됨"
[ -f "$diff" ] && grep -q 'revised by designer call 1' "$diff" || fail "A: 문서 diff 에 실제 design.md 변경이 없음"
grep -q 'DESIGNER-PRIVATE-REASON\|decisions.md' "$diff" && fail "A: 검증자용 문서 diff 에 decisions.md(디자이너 사유)가 들어감"
jq -e 'length==1 and .[0].id=="B-01" and .[0].minimum_contract_needed=="불변식 v1" and .[0].basis_refs==["request.md:L1-L1"] and .[0].conflict_refs==["design.md:L1-L1"]
       and .[0].impact=="IMPACT-CLAIM" and (.[0] | has("reachable_scenario") and (has("why_blocks_now") | not))' "$prev" >/dev/null || fail "A: prev-blockers 가 구조화된 주장·증거(why_blocks_now 제외)가 아님: $(cat "$prev")"
pass "A: 종결 검증자 입력에 디자이너 ACCEPT/REJECT 사유·직전 검증자 서술 없음"
grep -qF "$prev" "$r2" && grep -qF "$diff" "$r2" || fail "A: 종결 검증자 프롬프트에 직전 blocker 요약·문서 diff 경로가 없음"
grep -q 'UNRESOLVED_PREVIOUS' "$r2" && grep -q 'NEWLY_EXPOSED_BY_REVISION' "$r2" || fail "A: 종결 검토의 origin 제한 계약이 프롬프트에서 사라짐"
pass "A: 종결 검증자는 직전 blocker identity·증거 위치와 문서 diff 를 받음"
view=".agent-work/reviews/user-decisions-design.md"
for n in 1 2 3; do
  grep -qF '[USER-QUESTION][scope=design]' "$MOCK_STATE/validator-$n.prompt" && grep -qF "$view" "$MOCK_STATE/validator-$n.prompt" || fail "A: 검증자 $n 회차 프롬프트에 사용자 결정 계약(확정 결정 파일)이 없음"
  grep -q 'USER-DECISION-MARK' "$MOCK_STATE/user-decisions-$n.md" || fail "A: 검증자 $n 회차의 확정 결정 파일에 scope=design 사용자 결정이 없음"
  grep -q 'IMPL-DECISION-MARK' "$MOCK_STATE/user-decisions-$n.md" && fail "A: design 검증자의 확정 결정 파일에 scope=impl 결정이 들어감"
  grep -q 'ACCEPT\|REJECT\|\[round ' "$MOCK_STATE/user-decisions-$n.md" && fail "A: 검증자 $n 회차의 확정 결정 파일에 합의 이력 줄이 들어감: $(cat "$MOCK_STATE/user-decisions-$n.md")"
done
grep -q 'USER-DECISION-MARK' .agent-work/decisions.md || fail "A: 사용자 결정 줄이 decisions.md 에서 사라짐"
pass "A: [USER-QUESTION] 사용자 결정은 매 라운드 검증자 계약에 포함 (scope 필터된 확정 결정 파일)"
# 검증자가 받은 입력 어디에도 디자이너 사유·직전 검증자 서술이 없다: 프롬프트가 decisions.md 원본을 가리키지 않고, 프롬프트가 지정한 .agent-work 파일 전부에 그 문장이 없다
for n in 1 2 3; do
  grep -q 'decisions\.md' "$MOCK_STATE/validator-$n.prompt" && fail "A: 검증자 $n 회차 프롬프트가 decisions.md 원본을 가리킴"
done
for n in 2 3; do
  for f in $(grep -oE '\.agent-work/[A-Za-z0-9._/-]+' "$MOCK_STATE/validator-$n.prompt" | sed 's/[.]$//' | sort -u); do
    [ -f "$f" ] || continue
    grep -q 'DESIGNER-PRIVATE-REASON\|VALIDATOR-PRIVATE-WHY' "$f" && fail "A: 검증자 $n 회차 프롬프트가 지정한 입력 파일($f)에서 디자이너 사유 또는 직전 검증자 서술을 읽을 수 있음"
  done
done
pass "A: 검증자 입력(프롬프트 + 지정된 모든 파일)에 REJECT/ACCEPT 문장이 없음 — decisions.md 원본 미전달"
din=".agent-work/reviews/designer-input-design-round-01.json"
grep -qF "$din" "$MOCK_STATE/designer-1.prompt" || fail "A: 디자이너 프롬프트가 구조화 입력 파일을 가리키지 않음"
grep -q 'validator-design-round-01.json' "$MOCK_STATE/designer-1.prompt" && fail "A: 디자이너에게 리뷰 원문 경로가 전달됨"
jq -e '.blocking_issues | length==1 and (.[0] | .id=="B-01" and .category=="REQUIREMENT_MISSING" and .evidence_type=="DIRECT_MISMATCH" and .basis_refs==["request.md:L1-L1"]
       and .conflict_refs==["design.md:L1-L1"] and .code_refs==[] and .impact=="IMPACT-CLAIM" and .minimum_contract_needed=="불변식 v1" and has("reachable_scenario") and (has("why_blocks_now")|not))' "$din" >/dev/null \
  || fail "A: 디자이너 입력이 구조화된 주장·증거가 아님: $(cat "$din")"
pass "A: 디자이너는 blocker 의 구조화된 주장·증거를 받고 검증자 자유 서술은 받지 않음"

# ===== 사례 B: DEADLOCK =====
reset_case 2
verdict 1 BLOCK "$(issue ROUND_1 "" "같은 불변식")"
verdict 2 BLOCK "$(issue UNRESOLVED_PREVIOUS B-01 "같은 불변식")"
rc="$(run_loop)"
[ "$rc" -eq 2 ] && [ "$(status)" = DEADLOCK ] || { tail -30 "$TMP/loop.log"; fail "B: exit 2/DEADLOCK 기대, 실제 $rc/$(status)"; }
[ "$(grep -c '^designer ' "$MOCK_LOG")" -eq 1 ] || fail "B: DEADLOCK 인데 디자이너가 다시 호출됨"
pass "B: 같은 내용 blocker 2라운드 연속 → DEADLOCK"

# ===== 사례 C: ASK_USER + Round 1 재시작 =====
reset_case 2
verdict 1 BLOCK "$(issue ROUND_1 "" "" ASK_USER)"
rc="$(run_loop)"
[ "$rc" -eq 2 ] && [ "$(status)" = ASK_USER ] || { tail -30 "$TMP/loop.log"; fail "C: exit 2/ASK_USER 기대, 실제 $rc/$(status)"; }
grep -q '^designer ' "$MOCK_LOG" && fail "C: ASK_USER 인데 디자이너가 호출됨"
echo '- [USER-QUESTION][scope=design] 어느 정책? → a' >> .agent-work/decisions.md
verdict 2 PASS
rc="$(run_loop)"
[ "$rc" -eq 0 ] && [ "$(status)" = PASS ] || { tail -30 "$TMP/loop.log"; fail "C: 사용자 답 뒤 재실행이 PASS 로 끝나지 않음 ($rc/$(status))"; }
[ "$(session_flags validator)" = "--session-id --session-id" ] && [ "$(session_ids validator | sort -u | grep -c .)" -eq 2 ] \
  || fail "C: Round 1 재시작이 옛 검증자 세션을 이어감: $(grep '^validator ' "$MOCK_LOG" | paste -sd'|' -)"
pass "C: ASK_USER → exit 2·디자이너 0회, 재실행 Round 1 도 fresh 검증자"

# ===== 사례 D: MAX_ROUNDS =====
reset_case 1
verdict 1 BLOCK "$(issue ROUND_1 "" "불변식 v1")"
verdict 2 BLOCK "$(issue UNRESOLVED_PREVIOUS B-01 "불변식 v2")"
rc="$(run_loop)"
[ "$rc" -eq 2 ] && [ "$(status)" = MAX_ROUNDS_EXCEEDED ] || { tail -30 "$TMP/loop.log"; fail "D: exit 2/MAX_ROUNDS_EXCEEDED 기대, 실제 $rc/$(status)"; }
[ "$(grep -c '^validator ' "$MOCK_LOG")" -eq 2 ] && [ "$(grep -c '^designer ' "$MOCK_LOG")" -eq 1 ] || fail "D: 호출 횟수 불일치: $(paste -sd'|' "$MOCK_LOG")"
pass "D: MAX_SPEC_ROUNDS=1 수렴 실패 → MAX_ROUNDS_EXCEEDED"

rm -rf "$TMP"
echo "[SMOKE OK] 합의 루프 판정 격리 스모크 전체 통과"
