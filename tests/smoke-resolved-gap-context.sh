#!/usr/bin/env bash
# =============================================================
# 스모크: unit 워커 미결정 해결 후 정상 재개 (P0-3) — 실제 LLM 호출 없음(공용 mock CLI 가 프롬프트를 저장), 임시 저장소.
# 파일 경로: tests/smoke-resolved-gap-context.sh
# 사용법: bash tests/smoke-resolved-gap-context.sh
#
# 사례:
#   A. 정상 최초 호출: worker-unit.md 의 [RESOLVED GAPS] 블록이 비어 있다(unit 01·02 모두). 동작은 기존과 같다(DONE, 호출 횟수 불변).
#   B. unit 02 UNDECIDED → 답(decisions.md [worker-gap=02-drop#1]) + approach.md 반영 → 재실행: unit 02 워커 프롬프트에만 그 ID·원 질문·답 줄·approach 참조가 들어간다.
#      다른 unit(01) 은 건너뛰고(완료 체크포인트), resolved-gaps.json 에 전달 항목이 남는다. 검증자·디자이너 0회.
#   C. 재개된 워커가 같은 ID·같은 질문·같은 위치를 다시 undecided 로 내면 RESOLVED_GAP_REPEATED — 세션 수용 전에 판정, 근거 파일(units/02-drop/resolved-gap-repeated.json: ID·답·반환 항목·전/후 tree),
#      재실행은 반복 턴의 변경을 사용자가 확인하고 턴 이전 tree 로 되돌린 뒤에만(가드 파일만 지우면 DOC_GAP_SOURCE_CHANGED, 모델 0회),
#      새 doc-gap 체크포인트 없음(사용자 답 유지), 워커 1회. 재실행은 모델 0회로 같은 사유(자동 재시도 없음). 사용자가 근거 파일을 지운 뒤에만 재호출 → DONE.
#   D. 재개된 워커가 **다른 새 질문**을 내면 오탐 없이 정상 UNDECIDED(새 체크포인트 02-drop#1 갱신), RESOLVED_GAP_REPEATED 아님.
#   D2. 같은 질문 문구라도 **다른 위치(location)** 에서 새로 생긴 미결정은 오탐 없이 정상 UNDECIDED.
#   E. 답이 일부만 있으면(gap 2개 중 1개) 해결로 추정하지 않는다 — WAITING_USER 유지, 모델 0회(기존 계약).
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-resolved-gap-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"echo full-test >> $TMP/calls.log\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"echo full-lint >> $TMP/calls.log\"|" "$CFG" && rm -f "$CFG.bak"
sed -i.bak 's/^WORKER_CLI=.*/WORKER_CLI="claude"/' "$CFG" && rm -f "$CFG.bak"
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && for u in 01 02; do echo "base $u" > "src/u$u.txt"; done
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/u01.txt","src/u02.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
cat > .agent-work/implementation-units.json <<EOF
{"version":1,"units":[
 {"id":"01-intake","title":"접수","goal":"unit 01","requirements":["REQ-01"],"scope":{"files":["src/u01.txt"],"new_file_roots":[]},"references":["implementation.md#01"],"targeted_test":"echo test-01 >> $TMP/calls.log"},
 {"id":"02-drop","title":"Drop","goal":"unit 02","requirements":["REQ-02"],"scope":{"files":["src/u02.txt"],"new_file_roots":[]},"references":["implementation.md#02"],"targeted_test":"echo test-02 >> $TMP/calls.log"}
]}
EOF
RUN=".claude/skills/feature/scripts/feature-run.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" FEATURE_LIVE_TEE=1 MOCK_VALIDATOR_CONTRACT="$CONTRACT" MOCK_REVIEW_CONTRACT="$REVIEW_CONTRACT"
mkdir -p "$MOCK_STATE"

# --- 공용 mock CLI (역할은 스키마로 판별). 워커는 unit 프롬프트를 $MOCK_STATE/prompt-<unit>-<n>.txt 에 저장하고,
#     $MOCK_STATE/undecided-<n> 파일이 있으면 그 안의 JSON 항목들을 undecided 로 낸다(1회 소비). ---
cat > "$TMP/bin/mock-cli" <<'EOF'
#!/usr/bin/env bash
cli="$(basename "$0")"
out=""; schema=""; prompt=""; editing=0; outfmt=json
while [ "$#" -gt 0 ]; do case "$1" in
  exec|-p|--json|--verbose) shift;;
  -o) out="$2"; shift 2;;
  --output-schema) schema="$(cat "$2")"; shift 2;;
  --json-schema) schema="$2"; shift 2;;
  --sandbox) [ "$2" = workspace-write ] && editing=1; shift 2;;
  --permission-mode) editing=1; shift 2;;
  --output-format) outfmt="$2"; shift 2;;
  -m|-c|--model|--effort|--tools|--allowedTools|--disallowedTools|--append-system-prompt|--session-id|--resume) shift 2;;
  *) prompt="$1"; shift;;
esac; done
usage='"session_id":"fake","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
[ "$cli" = codex ] && printf '{"type":"thread.started","thread_id":"mock-thread-%s"}\n' "$$"
emit() { if [ "$cli" = codex ]; then if [ -n "$out" ]; then printf '%s\n' "$1" > "$out"; else printf '%s\n' "$1"; fi
        elif [ "$outfmt" = stream-json ]; then printf '{"type":"result","structured_output":%s,%s}\n' "$1" "$usage"
        else printf '{"structured_output":%s,%s}\n' "$1" "$usage"; fi; }
role=""
case "$schema" in *'"blocking_issues"'*) role=validator;; *'"issues"'*) role=reviewer;; *'"context_updates"'*) role=worker;; "") [ "$editing" = 1 ] && role=editor;; esac
[ -n "$role" ] || { echo "UNKNOWN-ROLE" >> "$MOCK_LOG"; exit 1; }
case "$role" in
  validator) echo "validator" >> "$MOCK_LOG"; emit "{\"schema_version\":$MOCK_VALIDATOR_CONTRACT,\"verdict\":\"PASS\",\"blocking_issues\":[]}"; exit 0;;
  editor) echo "editor" >> "$MOCK_LOG"; if [ "$cli" = codex ]; then echo ok; else printf '{"result":"ok",%s}\n' "$usage"; fi; exit 0;;
  reviewer) echo "reviewer" >> "$MOCK_LOG"; emit "{\"schema_version\":$MOCK_REVIEW_CONTRACT,\"verdict\":\"APPROVE\",\"issues\":[]}"; exit 0;;
esac
unit="$(printf '%s' "$prompt" | grep -oE '"id": *"[0-9]+-[a-z0-9-]+"' | head -1 | sed -E 's/.*"([0-9]+-[a-z0-9-]+)"/\1/')"
n="${unit%%-*}"
k=$(( $(cat "$MOCK_STATE/count-$unit" 2>/dev/null || echo 0) + 1 )); printf '%s' "$k" > "$MOCK_STATE/count-$unit"
printf '%s' "$prompt" > "$MOCK_STATE/prompt-$unit-$k.txt"
echo "worker $unit" >> "$MOCK_LOG"
echo "worker $unit #$k" >> "src/u$n.txt"
if [ -f "$MOCK_STATE/undecided-$n" ]; then
  items="$(cat "$MOCK_STATE/undecided-$n")"; rm -f "$MOCK_STATE/undecided-$n"
  emit "{\"status\":\"UNDECIDED\",\"undecided\":$items,\"delegated_choices\":[],\"tests\":[],\"context_updates\":{\"upsert\":[],\"remove\":[]}}"; exit 0
fi
emit "$(printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[{"name":"u%s","result":"PASS"}],"context_updates":{"upsert":[],"remove":[]}}' "$n")"
exit 0
EOF
chmod +x "$TMP/bin/mock-cli"; cp "$TMP/bin/mock-cli" "$TMP/bin/claude"; cp "$TMP/bin/mock-cli" "$TMP/bin/codex"

fake_pass() { bash .claude/skills/feature/scripts/consensus-loop.sh "$1" > "$TMP/consensus-$1.log" 2>&1 || { cat "$TMP/consensus-$1.log"; fail "픽스처: $1 합의 PASS 체크포인트 생성 실패"; }; }
fake_pass design; fake_pass impl
run_runner() { : > "$MOCK_LOG"; bash "$RUN" > "$TMP/run.log" 2>&1; echo $?; }
reason() { jq -r '.reason' .agent-work/run-state.json; }
status() { jq -r '.status' .agent-work/run-state.json; }
calls() { grep -c "^$1" "$MOCK_LOG" 2>/dev/null || true; }
gap() { jq -r "$1" .agent-work/doc-gap-resume.json; }
block_of() { # prompt-file → [RESOLVED GAPS] 블록 본문
  awk '/^\[RESOLVED GAPS\]$/{f=1; next} /^\[\/RESOLVED GAPS\]$/{f=0} f' "$1"
}
no_reconsensus() {
  [ "$(calls validator)" -eq 0 ] && [ "$(calls editor)" -eq 0 ] || fail "$1: 검증자/디자이너가 호출됨 ($(paste -sd'|' "$MOCK_LOG"))"
  grep -q 'impl 부터\|NEED_DOCS' "$TMP/run.log" && fail "$1: impl 재합의 경로로 빠짐"
  return 0
}
reset_tree() {
  git checkout -q -- src
  rm -rf .agent-work/units .agent-work/implementation-context.json .agent-work/implementation-units.lock.json .agent-work/feature-scope.lock.json .agent-work/worker-baseline.tree \
    .agent-work/worker-result.json .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/reviews/impl-attempt-* .agent-work/.session-* \
    .agent-work/worker-session.json .agent-work/worker-handoff.json .agent-work/doc-gap-resume.json .agent-work/worker-outcome.guard.json .agent-work/usage.jsonl "$MOCK_STATE"/*
  : > .agent-work/decisions.md; printf '# approach\n' > .agent-work/approach.md
  fake_pass impl
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
}
Q1='drop 시 상태 전이 위치'
undecided_q1='[{"kind":"DOC_GAP","location":"src/u02.txt","decision_needed":"drop 시 상태 전이 위치","options":["서비스","도메인 객체"]}]'
answer_q1() {
  printf -- '- [USER-QUESTION][scope=impl][worker-gap=02-drop#1] %s → 도메인 객체\n' "$Q1" >> .agent-work/decisions.md
  printf '\n## 결정 02-drop (REQUIRED)\n상태 전이는 도메인 객체가 한다.\n' >> .agent-work/approach.md
}

# ===== 사례 A: 정상 최초 호출 — 블록 비어 있음, 동작 불변 =====
reset_tree
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -20 "$TMP/run.log"; fail "A: exit 0/DONE 기대, 실제 $rc/$(status)"; }
[ "$(paste -sd'|' "$MOCK_LOG")" = "worker 01-intake|test-01|worker 02-drop|test-02|reviewer|full-test|full-lint" ] || fail "A: 호출 순서/횟수 불일치: $(paste -sd'|' "$MOCK_LOG")"
for u in 01-intake 02-drop; do
  grep -q '^\[RESOLVED GAPS\]$' "$MOCK_STATE/prompt-$u-1.txt" || fail "A: $u 프롬프트에 [RESOLVED GAPS] 블록이 없음"
  [ -z "$(block_of "$MOCK_STATE/prompt-$u-1.txt" | tr -d '[:space:]')" ] || fail "A: 정상 최초 호출인데 $u 의 블록이 비어 있지 않음: $(block_of "$MOCK_STATE/prompt-$u-1.txt")"
  [ ! -f ".agent-work/units/$u/resolved-gaps.json" ] || fail "A: 해결 항목이 없는데 resolved-gaps.json 이 생김"
done
pass "A: 정상 최초 호출 — [RESOLVED GAPS] 비어 있음, 호출 횟수·순서 불변"

# ===== 사례 B: unit 02 UNDECIDED → 답 → 재개 프롬프트에 ID·질문·답·approach 참조 =====
reset_tree; printf '%s' "$undecided_q1" > "$MOCK_STATE/undecided-02"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] && [ "$(gap .gaps[0].key)" = "02-drop#1" ] || { tail -20 "$TMP/run.log"; fail "B: 전제(UNDECIDED 02-drop#1) 실패 ($rc/$(reason))"; }
answer_q1
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "B: 답 후 exit 0/DONE 기대, 실제 $rc/$(status)"; }
[ "$(paste -sd'|' "$MOCK_LOG")" = "worker 02-drop|test-02|reviewer|full-test|full-lint" ] || fail "B: 답 후 unit 02 부터 재개되지 않음: $(paste -sd'|' "$MOCK_LOG")"
no_reconsensus B
p2="$MOCK_STATE/prompt-02-drop-2.txt"; [ -f "$p2" ] || fail "B: 재개 턴 프롬프트가 저장되지 않음"
blk="$(block_of "$p2")"
printf '%s' "$blk" | grep -q '^- \[02-drop#1\] (src/u02.txt) 질문: drop 시 상태 전이 위치$' || fail "B: 블록에 ID·위치·원 질문이 없음: $blk"
printf '%s' "$blk" | grep -q '선택지: 서비스 | 도메인 객체' || fail "B: 블록에 선택지가 없음: $blk"
printf '%s' "$blk" | grep -qF -- '- [USER-QUESTION][scope=impl][worker-gap=02-drop#1] drop 시 상태 전이 위치 → 도메인 객체' || fail "B: 블록에 decisions.md 답 줄이 없음: $blk"
printf '%s' "$blk" | grep -q 'approach.md' || fail "B: 블록에 approach.md 참조가 없음: $blk"
grep -q 'RESOLVED_GAP_REPEATED' "$p2" || fail "B: 재개 프롬프트에 재반환 금지 안내가 없음"
jq -e '.[0].key=="02-drop#1" and .[0].tag=="worker-gap=02-drop#1" and (.[0].answer|test("도메인 객체"))' .agent-work/units/02-drop/resolved-gaps.json >/dev/null || fail "B: resolved-gaps.json 불일치: $(cat .agent-work/units/02-drop/resolved-gaps.json)"
[ -z "$(block_of "$MOCK_STATE/prompt-01-intake-1.txt" | tr -d '[:space:]')" ] || fail "B: unit 01 프롬프트에 다른 unit 의 gap 이 들어감"
[ "$(gap .next_step)" = RESOLVED ] || fail "B: 체크포인트가 RESOLVED 가 아님"
pass "B: 답 후 unit 02 재개 프롬프트에 [02-drop#1]·원 질문·선택지·답 줄·approach 참조, unit 01 은 무관, 검증자·디자이너 0회"

# ===== 사례 C: 같은 ID·같은 질문 재반환 → RESOLVED_GAP_REPEATED, 자동 재시도 없음, 근거 파일 삭제 후에만 재호출 =====
reset_tree; printf '%s' "$undecided_q1" > "$MOCK_STATE/undecided-02"
rc="$(run_runner)"; [ "$rc" -eq 2 ] || fail "C: 전제 실패"
answer_q1
printf '%s' "$undecided_q1" > "$MOCK_STATE/undecided-02"   # 재개 턴이 같은 질문을 다시 낸다
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = RESOLVED_GAP_REPEATED ] || { tail -20 "$TMP/run.log"; fail "C: exit 2/RESOLVED_GAP_REPEATED 기대, 실제 $rc/$(reason)"; }
[ "$(paste -sd'|' "$MOCK_LOG")" = "worker 02-drop" ] || fail "C: 워커 1회 뒤 즉시 중단이 아님: $(paste -sd'|' "$MOCK_LOG")"
guard=.agent-work/units/02-drop/resolved-gap-repeated.json
jq -e '.active==true and .unit_id=="02-drop" and .repeated[0].key=="02-drop#1" and .repeated[0].location=="src/u02.txt" and (.repeated[0].answer|test("도메인 객체")) and .repeated[0].returned.decision_needed=="drop 시 상태 전이 위치" and (.result|endswith("worker-result.json")) and .session_accepted==false and (.expected|length==40) and (.observed|length==40) and .expected!=.observed' "$guard" >/dev/null \
  || fail "C: 근거 파일 불일치: $(cat "$guard" 2>/dev/null)"
# [리뷰 2] 반복 판정은 세션 수용 앞 — 근거 파일의 session_accepted:false 가 그 순서의 증거(위 jq)
[ "$(gap .next_step)" = WORKER_PENDING ] && [ "$(gap '.gaps|length')" = 1 ] || fail "C: 새 체크포인트가 기록되거나 사용자 답 상태가 바뀜 ($(gap .next_step))"
grep -q '02-drop#1' .agent-work/run-state.json && grep -q 'resolved-gap-repeated.json' .agent-work/run-state.json || fail "C: detail 에 ID·근거 파일이 없음"
[ "$(tail -1 src/u02.txt)" = "worker 02-drop #2" ] || fail "C: 워커 변경이 원복됨"
[ ! -f .agent-work/.session-feature-worker.gen1 ] && jq -e '.generation==1' .agent-work/worker-session.json >/dev/null || fail "C: 세션이 초기화/교체됨"
# 재실행 → 모델 0회, 같은 사유
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = RESOLVED_GAP_REPEATED ] && [ ! -s "$MOCK_LOG" ] || fail "C(재실행): 근거 파일이 있는데 모델이 호출됨: $(paste -sd'|' "$MOCK_LOG")"
# [리뷰 2/우회 차단] 근거 파일만 지우고 코드를 되돌리지 않은 재실행도 모델 0회 — 체크포인트 source_tree 와 다르므로 DOC_GAP_SOURCE_CHANGED
cp "$guard" "$TMP/guard.bak"; rm -f "$guard"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = DOC_GAP_SOURCE_CHANGED ] && [ ! -s "$MOCK_LOG" ] || { tail -10 "$TMP/run.log"; fail "C(가드 삭제 우회): 코드 미복구인데 모델이 호출됨 또는 사유 불일치 ($rc/$(reason)/$(paste -sd'|' "$MOCK_LOG"))"; }
[ "$(tail -1 src/u02.txt)" = "worker 02-drop #2" ] || fail "C(가드 삭제 우회): 자동 원복됨"
cp "$TMP/guard.bak" "$guard"
# 변경을 확인한 뒤 턴 이전 tree 로 되돌려야 가드가 풀린다 — 반복 턴의 변경(u02.txt 마지막 줄 "#2")을 되돌림 → 가드 비활성화 → 같은 세션으로 재호출 → DONE
sed -i.bak '$d' src/u02.txt && rm -f src/u02.txt.bak
[ "$(tail -1 src/u02.txt)" = "worker 02-drop #1" ] || fail "C: 픽스처 복구 실패: $(cat src/u02.txt)"
rc="$(run_runner)"
jq -e '.active==false' "$guard" >/dev/null || fail "C(복구 후): tree 복구 뒤 가드가 비활성화되지 않음: $(cat "$guard")"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "C(복구 후): exit 0/DONE 기대, 실제 $rc/$(status)/$(reason)"; }
[ "$(paste -sd'|' "$MOCK_LOG")" = "worker 02-drop|test-02|reviewer|full-test|full-lint" ] || fail "C(복구 후): 호출 순서 불일치: $(paste -sd'|' "$MOCK_LOG")"
no_reconsensus C
p3="$MOCK_STATE/prompt-02-drop-3.txt"; [ -f "$p3" ] && printf '%s' "$(block_of "$p3")" | grep -q '02-drop#1' || fail "C(복구 후): 세 번째 턴에도 해결 항목이 전달돼야 함"
pass "C: 같은 ID·질문·위치 재반환 → RESOLVED_GAP_REPEATED(세션 미수용, 근거 파일: ID·답·반환 항목·전/후 tree), 체크포인트·답 유지, 재실행 모델 0회, 가드 파일 삭제 우회는 DOC_GAP_SOURCE_CHANGED 모델 0회, 턴 이전 tree 복구 후에만 재호출 → DONE"

# ===== 사례 D: 다른 새 질문 → 정상 UNDECIDED(오탐 없음) =====
reset_tree; printf '%s' "$undecided_q1" > "$MOCK_STATE/undecided-02"
rc="$(run_runner)"; [ "$rc" -eq 2 ] || fail "D: 전제 실패"
answer_q1
printf '[{"kind":"USER_DECISION","location":"src/u02.txt","decision_needed":"drop 시 상태 전이 위치를 어느 모듈이 호출하는가","options":["컨트롤러","서비스"]}]' > "$MOCK_STATE/undecided-02"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] || { tail -20 "$TMP/run.log"; fail "D: 새 질문이 UNDECIDED 로 가지 않음 ($rc/$(reason))"; }
[ ! -f .agent-work/units/02-drop/resolved-gap-repeated.json ] || fail "D: 표현이 비슷한 새 질문이 RESOLVED_GAP_REPEATED 로 오탐됨"
[ "$(gap .next_step)" = WAITING_USER ] && [ "$(gap .gaps[0].question)" = "drop 시 상태 전이 위치를 어느 모듈이 호출하는가" ] || fail "D: 새 체크포인트 불일치: $(cat .agent-work/doc-gap-resume.json)"
pass "D: 유사하지만 다른 새 질문 → 정상 UNDECIDED(새 체크포인트), 오탐 없음"

# ===== 사례 D2 (리뷰 1): 같은 질문 문구 + 다른 위치 → 정상 UNDECIDED(오탐 없음) =====
reset_tree; printf '%s' "$undecided_q1" > "$MOCK_STATE/undecided-02"
rc="$(run_runner)"; [ "$rc" -eq 2 ] || fail "D2: 전제 실패"
answer_q1
printf '[{"kind":"DOC_GAP","location":"src/u02.txt#L40 (drop 재시도 경로)","decision_needed":"drop 시 상태 전이 위치","options":["서비스","도메인 객체"]}]' > "$MOCK_STATE/undecided-02"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] || { tail -20 "$TMP/run.log"; fail "D2: 다른 위치의 같은 질문이 UNDECIDED 로 가지 않음 ($rc/$(reason))"; }
[ ! -f .agent-work/units/02-drop/resolved-gap-repeated.json ] || fail "D2: 다른 위치에서 새로 생긴 같은 문구의 미결정이 RESOLVED_GAP_REPEATED 로 오탐됨"
[ "$(gap .next_step)" = WAITING_USER ] && [ "$(gap .gaps[0].location)" = "src/u02.txt#L40 (drop 재시도 경로)" ] || fail "D2: 새 체크포인트 불일치: $(cat .agent-work/doc-gap-resume.json)"
pass "D2: 같은 질문 문구·다른 위치 → 정상 UNDECIDED(새 체크포인트), 오탐 없음"

# ===== 사례 E: 일부만 해결 → 해결로 추정하지 않음 =====
reset_tree
printf '[{"kind":"DOC_GAP","location":"src/u02.txt","decision_needed":"drop 시 상태 전이 위치","options":["서비스","도메인 객체"]},{"kind":"DOC_GAP","location":"src/u02.txt","decision_needed":"정렬 기준","options":["이름","날짜"]}]' > "$MOCK_STATE/undecided-02"
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(gap '.gaps|length')" = 2 ] || fail "E: 전제(gap 2개) 실패"
answer_q1   # 1개만 답
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] && [ ! -s "$MOCK_LOG" ] && [ "$(gap .next_step)" = WAITING_USER ] || fail "E: 일부 답으로 워커가 재개됨 ($rc/$(reason), $(paste -sd'|' "$MOCK_LOG"))"
grep -q '답 없는 gap: worker-gap=02-drop#2' .agent-work/run-state.json || fail "E: 답 없는 gap 이 보고되지 않음"
pass "E: 일부만 해결 → WAITING_USER 유지, 모델 0회"

rm -rf "$TMP"
echo "smoke-resolved-gap-context: 전부 통과"
