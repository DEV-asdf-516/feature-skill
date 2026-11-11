#!/usr/bin/env bash
# =============================================================
# 스모크: unit 유효 계약 스냅샷과 재개·완료 게이트(P1-1/P1-2), 사용자 결정 scope = 최초 영향 단계(P1) — 실제 LLM 호출 없음
# 파일 경로: tests/smoke-unit-contract.sh   (mock claude 하나로 모든 역할, 임시 저장소)
# 사용법: bash tests/smoke-unit-contract.sh
#
# 불변식:
#   - unit 완료는 unit JSON 해시만이 아니라 references 가 가리키는 문서 절 본문·그 unit 의 사용자 결정까지의 지문으로 판정한다.
#   - 계약이 바뀐 unit 은 과거 DONE 결과로 테스트만 다시 돌려 완료시키지 않는다 — [UNIT TURN]/[CHANGED CONTRACT](실제 diff)를 받은 워커 턴 뒤에만 새 done.json.
#   - 다른 unit 의 독립 절 변경은 앞 unit 의 완료를 깨지 않는다. 전역 입력 변경·해석 불가 references·스냅샷 없는 과거 산출물은 모델 0회로 멈춘다.
#   - scope=impl 결정은 design 검증자를 다시 부르지 않고, scope=design 결정(늦게 나온 제품 요구)은 design 검증자가 본다. 결정 파일과 지문은 같은 집합이다.
# 사례 (GOAL 회귀 ID):
#   R11/R7. unit 04 UNDECIDED → doc-gap-resume.json archive + 같은 절 본문만 변경(heading 유지) → kind=RESUME, 빈 [RESOLVED GAPS] 가 최초 턴으로 해석되지 않음,
#           [CHANGED CONTRACT] 에 실제 diff, 01~03 완료 재사용(R9)
#   R7b.    워커 DONE 뒤(테스트 재시도 소진) 계약 변경 → 과거 worker-result 의 테스트-only 재개 금지(변경 없으면 테스트부터 재개)
#   R8/R9.  이미 DONE 인 unit 04 의 절 변경 → stale, 워커 재대조 + targeted test 뒤 새 done.json(지문 변경), 01~03 은 건너뜀
#   R12.    stale 선행 unit(02) + 완료된 후행 unit → UNIT_CHECKPOINT_CHAIN_STALE, 워커 0회, source 불변
#   R10.    참조 절 삭제 / 모호한 heading / 전역 결정·request.md 변경 → UNIT_CONTRACT_IMPACT_REQUIRED, 모델 0회. unit-contract-impact.json 으로 명시 확정 후 진행
#   R10e.   확정 파일은 판단 당시의 계약 지문(target_fingerprint)을 든다 — 확정 뒤 계약이 또 바뀌면 대상 집합이 같아도 적용하지 않고 모델 0회로 재확정 요구. 지문 없는 version 1 거부
#   R17.    리뷰 DOC_GAP 사용자 해결 예외는 그 gap 과 연결된 unit(코드 위치가 scope 안)의 approach 절 가운데 gap tag 가 적힌 절의 변경에만 — 무관한 unit 의 절,
#           같은 unit 의 다른 절(B04), 표시 없는 절 변경은 stale(DOC_GAP_SCOPE_EXCEEDED, 모델 0회). new_file_roots 의 끝 슬래시는 정규화해 대조
#   R16.    done.json v1(스냅샷 없음)·검증/리뷰 계약 버전 변경 → 이전 DONE·PASS·APPROVE 를 재사용하지 않음
#   RV.     러너: 리뷰어 출력 계약 위반 → NEED_USER/REVIEW_OUTPUT_INVALID(ENV_ERROR 아님), 재실행 리뷰어 0회, --new-review-attempt 로만 새 리뷰
#   R13.    design PASS 뒤 scope=impl 순수 구현 결정 추가 → design 검증자 0회, impl 만 재검증
#   R14/R15. 늦게 나온 제품 요구: request.md '요구 변경/추가' append + scope=design 결정 + design 절 수정 → design 검증자가 그 결정을 입력으로 받고,
#           두 검증자 프롬프트가 "명시한 범위 안에서만 대체" 규칙을 든다. pending gap 은 재합의를 건너뛰는 데 쓰이지 않고 SUPERSEDED.
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-unit-contract-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks" "$TMP/side"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex-must-not-run\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"echo full-test >> $TMP/calls.log\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"true\"|" "$CFG" && rm -f "$CFG.bak"
# 역할별 CLI 고정: 이 스모크는 CLI 규약이 아니라 상태 전이를 보므로 모든 역할을 mock claude 로 고정한다(쓰지 않는 codex 는 호출되면 실패하는 스텁)
sed -i.bak 's/^REVIEWER_CLI=.*/REVIEWER_CLI="claude"/; s/^VALIDATOR_CLI=.*/VALIDATOR_CLI="claude"/; s/^FIXER_CLI=.*/FIXER_CLI="claude"/; s/^DESIGNER_CLI=.*/DESIGNER_CLI="claude"/; s/^WORKER_CLI=.*/WORKER_CLI="claude"/' "$CFG" && rm -f "$CFG.bak"
printf '#!/usr/bin/env bash\necho "CODEX-CALLED $*" >> "%s/calls.log"; exit 9\n' "$TMP" > "$TMP/bin/codex-must-not-run"; chmod +x "$TMP/bin/codex-must-not-run"
cp "$CFG" "$TMP/side/config.good.sh"
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && for u in 01 02 03 04; do echo "base $u" > "src/u$u.txt"; done
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
RUN=".claude/skills/feature/scripts/feature-run.sh"
VC="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
RC="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" FEATURE_LIVE_TEE=1 MOCK_VC="$VC" MOCK_RC="$RC"
mkdir -p "$MOCK_STATE"

# --- 문서 픽스처: unit NN 은 implementation.md#NN · approach.md#ANN · design.md#DNN 절에 의존한다 ---
write_docs() {
  mkdir -p .agent-work/reviews
  printf '# request\n원 요구: 문의 접근 권한 요청만 Slack 사유 표시\n' > .agent-work/request.md
  { printf '# design\n'; for u in 01 02 03 04; do printf '\n## D%s\ndesign of unit %s\n' "$u" "$u"; done; } > .agent-work/design.md
  { printf '# implementation\n'; for u in 01 02 03 04; do printf '\n## %s\nwhat unit %s does\n' "$u" "$u"; done; } > .agent-work/implementation.md
  { printf '# approach\n'; for u in 01 02 03 04; do printf '\n## A%s\nhow unit %s is built\n' "$u" "$u"; done; printf '\n## B04\nsecond approach rule of the last unit\n'; } > .agent-work/approach.md   # unit 04 는 approach 절 둘(A04·B04)에 의존한다
  : > .agent-work/decisions.md
  printf '{"version":1,"files":["src/u01.txt","src/u02.txt","src/u03.txt","src/u04.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
  {
    printf '{"version":1,"units":[\n'
    for u in 01 02 03 04; do
      extra=""; [ "$u" != 04 ] || extra=',"approach.md#B04"'
      printf ' {"id":"%s-unit","title":"u%s","goal":"unit %s","requirements":["REQ-%s"],"scope":{"files":["src/u%s.txt"],"new_file_roots":[]},"references":["implementation.md#%s","approach.md#A%s","design.md#D%s"%s],"targeted_test":"%s/bin/test-unit %s"}' \
        "$u" "$u" "$u" "$u" "$u" "$u" "$u" "$u" "$extra" "$TMP" "$u"
      [ "$u" = 04 ] || printf ','
      printf '\n'
    done
    printf ']}\n'
  } > .agent-work/implementation-units.json
}
printf '%s\n' '#!/usr/bin/env bash' 'echo "test-$1" >> "$MOCK_LOG"' '[ ! -f "$MOCK_STATE/fail-test-$1" ] || { echo "unit $1 test failed"; exit 1; }' > "$TMP/bin/test-unit"; chmod +x "$TMP/bin/test-unit"

# --- mock claude: 역할은 스키마 내용으로 판별(검증자 = blocking_issues, 리뷰어 = issues, 워커 = context_updates, 스키마 없는 편집 = 수정자) ---
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
schema=""; prompt=""; editing=0
while [ "$#" -gt 0 ]; do case "$1" in
  -p|--verbose) shift;;
  --json-schema) schema="$2"; shift 2;;
  --permission-mode) editing=1; shift 2;;
  --session-id|--resume|--output-format|--model|--effort|--tools|--allowedTools|--disallowedTools|--append-system-prompt) shift 2;;
  *) prompt="$1"; shift;;
esac; done
usage='"session_id":"fake","total_cost_usd":0,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
emit() { printf '{"structured_output":%s,%s}\n' "$1" "$usage"; }
case "$schema" in
  *'"blocking_issues"'*)
    target=impl; printf '%s' "$prompt" | grep -q '당신은 설계 검증자다' && target=design
    echo "validator $target" >> "$MOCK_LOG"; printf '%s' "$prompt" > "$MOCK_STATE/validator-prompt-$target.txt"
    emit "{\"schema_version\":$MOCK_VC,\"verdict\":\"PASS\",\"blocking_issues\":[]}"; exit 0;;
  *'"issues"'*)
    echo "reviewer" >> "$MOCK_LOG"
    if [ -f "$MOCK_STATE/review-docgap" ]; then
      mv "$MOCK_STATE/review-docgap" "$MOCK_STATE/review-docgap.used"
      emit "{\"schema_version\":$MOCK_RC,\"verdict\":\"REQUEST_CHANGES\",\"issues\":[{\"id\":\"R-01\",\"action\":\"DOC_GAP\",\"category\":\"UNDECIDED_APPROACH\",\"evidence_type\":\"DIRECT_MISMATCH\",\"basis_refs\":[\"approach.md:L1-L1\"],\"code_refs\":[\"src/u04.txt:L1-L1\"],\"reachable_scenario\":\"\",\"impact\":\"\",\"why_blocks_now\":\"x\",\"required_outcome\":\"y\",\"origin\":\"ROUND_1\",\"previous_issue_id\":\"\",\"fix_ref\":\"\",\"user_question\":\"어느 방식인가\",\"options\":[\"a\",\"b\"]}]}"; exit 0
    fi
    if [ -f "$MOCK_STATE/review-invalid" ]; then emit "{\"schema_version\":1,\"verdict\":\"APPROVE\",\"issues\":[]}"; exit 0; fi
    emit "{\"schema_version\":$MOCK_RC,\"verdict\":\"APPROVE\",\"issues\":[]}"; exit 0;;
  *'"context_updates"'*) ;;
  *) echo "fixer" >> "$MOCK_LOG"; printf '{"result":"ok",%s}\n' "$usage"; exit 0;;
esac
unit="$(printf '%s' "$prompt" | grep -oE '"id": *"[0-9]+-[a-z0-9-]+"' | head -1 | sed -E 's/.*"([0-9]+-[a-z0-9-]+)"/\1/')"
n="${unit%%-*}"
if printf '%s' "$prompt" | grep -qE 'targeted-test-[0-9]+\.log'; then
  echo "test-fix $unit" >> "$MOCK_LOG"; echo "test-fix $unit" >> "src/u$n.txt"
  emit '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}'; exit 0
fi
if printf '%s' "$prompt" | grep -q 'review-issue=R-01'; then   # review-gap 워커(리뷰 DOC_GAP 의 사용자 결정 구현) — unit 턴이 아니다
  echo "review-gap-worker" >> "$MOCK_LOG"; echo "review-gap fix" >> src/u04.txt
  emit '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}'; exit 0
fi
echo "worker $unit" >> "$MOCK_LOG"
printf '%s' "$prompt" > "$MOCK_STATE/prompt-$n.txt"
echo "worker $unit" >> "src/u$n.txt"
if [ -f "$MOCK_STATE/undecided-$n" ]; then
  rm -f "$MOCK_STATE/undecided-$n"
  emit "$(printf '{"status":"UNDECIDED","undecided":[{"kind":"USER_DECISION","location":"src/u%s.txt","decision_needed":"policy","options":["a","b"]}],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}' "$n")"; exit 0
fi
emit '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}'
EOF
chmod +x "$TMP/bin/claude"

run_runner() { : > "$MOCK_LOG"; bash "$RUN" "$@" > "$TMP/run.log" 2>&1; echo $?; }
reason() { jq -r '.reason' .agent-work/run-state.json; }
status() { jq -r '.status' .agent-work/run-state.json; }
calls() { grep -c "^$1" "$MOCK_LOG" || true; }
workers() { grep -E '^worker ' "$MOCK_LOG" | paste -sd' ' -; }
block() { sed -n "/^\[$2\]\$/,/^\[\/$2\]\$/p" "$MOCK_STATE/prompt-$1.txt"; }   # unit-번호 블록-이름
done_fp() { jq -r '.unit_contract_fingerprint' ".agent-work/units/$1-unit/done.json"; }
set_section() { # file heading new-body — heading 은 그대로 두고 그 절의 본문만 바꾼다
  awk -v h="## $2" -v body="$3" '$0==h{print; print body; skip=1; next} /^## /{skip=0} !skip{print}' ".agent-work/$1" > "$TMP/doc.tmp" && cp "$TMP/doc.tmp" ".agent-work/$1"
}
fresh() { # 테스트 환경 초기화(파이프라인 동작 아님)
  git checkout -q -- src; rm -rf .agent-work "$MOCK_STATE"/prompt-*.txt "$MOCK_STATE"/validator-prompt-*.txt "$MOCK_STATE"/undecided-* "$MOCK_STATE"/fail-test-* "$MOCK_STATE"/review-invalid
  cp "$TMP/side/config.good.sh" "$CFG"; write_docs
}
tree_now() { ( source "$CFG"; snapshot_worktree_tree ); }
# 사용자 역할: 러너가 내준 현재 확정 대상 지문(unit-contract-impact.request.json)을 그대로 적어 영향을 확정한다
impact() { # affected-json unaffected-json
  jq -n --arg fp "$(jq -r .target_fingerprint .agent-work/unit-contract-impact.request.json)" --argjson a "$1" --argjson u "$2" \
    '{version:2, target_fingerprint:$fp, affected_units:$a, unaffected_units:$u}' > .agent-work/unit-contract-impact.json
}

# ===== 기준선: 4 unit 정상 완료 — 계약 스냅샷·FIRST 턴 =====
fresh
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "기준선: 정상 실행이 DONE 이 아님 (rc $rc)"; }
[ "$(workers)" = "worker 01-unit worker 02-unit worker 03-unit worker 04-unit" ] || fail "기준선: 워커 순서 불일치: $(workers)"
block 01 'UNIT TURN' | grep -qx 'kind=FIRST' && [ "$(block 01 'CHANGED CONTRACT' | sed -n 2p)" = none ] || fail "기준선: 최초 턴이 kind=FIRST / 변경 계약 none 이 아님: $(block 01 'UNIT TURN')"
for u in 01 02 03 04; do
  d=".agent-work/units/$u-unit"
  jq -e '.version==2 and (.unit_contract_fingerprint|length)==64' "$d/done.json" >/dev/null && [ "$(done_fp "$u")" = "$(jq -r .fingerprint "$d/contract/contract.json")" ] || fail "기준선: unit $u done.json 에 계약 지문이 없음"
  grep -q "what unit $u does" "$d/contract/baseline/contract.txt" && grep -q "how unit $u is built" "$d/contract/baseline/contract.txt" && grep -q "design of unit $u" "$d/contract/baseline/contract.txt" \
    || fail "기준선: unit $u 스냅샷에 references 절 본문이 없음"
  grep -q 'what unit 0[1-4] does' "$d/contract/baseline/contract.txt" && [ "$(grep -c 'what unit' "$d/contract/baseline/contract.txt")" -eq 1 ] || fail "기준선: unit $u 스냅샷에 다른 unit 의 절이 섞임"
  jq -e '.baseline_source=="unit-done" and (.source_tree|length)>=40 and .consensus_provenance.design=="PASS" and .consensus_provenance.impl=="PASS"' "$d/contract/contract.json" >/dev/null || fail "기준선: unit $u contract.json 메타데이터 불일치"
  [ -f "$d/contract/first/contract.txt" ] && [ -f "$d/contract/first/global.txt" ] || fail "기준선: unit $u 최초 스냅샷(first/)이 없음"
done
grep -q '원 요구' .agent-work/units/01-unit/contract/baseline/global.txt || fail "기준선: 전역 스냅샷에 request.md 가 없음"
pass "기준선: unit 마다 references 절 본문 스냅샷 + done.json 계약 지문, 최초 턴 kind=FIRST"

# ===== R11/R7/R9: UNDECIDED → gap 체크포인트 archive + 같은 절 본문 변경 → RESUME + 실제 diff =====
fresh; touch "$MOCK_STATE/undecided-04"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] || { tail -20 "$TMP/run.log"; fail "R11: 전제(unit 04 UNDECIDED) 실패 (rc $rc/$(reason))"; }
fp03="$(done_fp 03)"
mkdir -p .agent-work/archive && mv .agent-work/doc-gap-resume.json .agent-work/archive/doc-gap-resume.archived.json   # scope 변경 등으로 체크포인트를 치운 상황
echo '- [USER-QUESTION][scope=impl][worker-gap=04-unit#1] policy → a 로 한다' >> .agent-work/decisions.md
set_section approach.md A04 'how unit 04 is built — 사용자 결정: policy a'
set_section implementation.md 04 'what unit 04 does (policy a 반영)'
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "R11: 재개 실행이 DONE 이 아님 (rc $rc/$(reason))"; }
[ "$(workers)" = "worker 04-unit" ] || fail "R9: 독립 절만 바뀌었는데 다른 unit 워커가 다시 호출됨: $(workers)"
[ "$(done_fp 03)" = "$fp03" ] || fail "R9: unit 03 완료 체크포인트가 다시 쓰임"
[ "$(calls 'validator design')" -eq 0 ] && [ "$(calls 'validator impl')" -eq 1 ] || fail "R11: 검증자 호출 불일치(design 0·impl 1 기대): $(paste -sd'|' "$MOCK_LOG")"
block 04 'UNIT TURN' | grep -qx 'kind=RESUME' || fail "R11: archive 뒤 재개 턴이 kind=RESUME 이 아님: $(block 04 'UNIT TURN')"
[ "$(block 04 'RESOLVED GAPS' | wc -l | tr -d ' ')" -le 3 ] && ! block 04 'RESOLVED GAPS' | grep -q 'policy' || fail "R11: 전제 — [RESOLVED GAPS] 가 비어 있지 않음"
grep -q '비어 있다는 것은' "$MOCK_STATE/prompt-04.txt" && ! grep -q '비어 있으면 이 unit 의 최초 턴이다' "$MOCK_STATE/prompt-04.txt" || fail "R11: 프롬프트가 빈 [RESOLVED GAPS] 를 최초 턴으로 설명함"
cc="$(block 04 'CHANGED CONTRACT')"
printf '%s' "$cc" | grep -q '^-how unit 04 is built$' && printf '%s' "$cc" | grep -q '^+how unit 04 is built — 사용자 결정: policy a$' || fail "R7: [CHANGED CONTRACT] 에 approach 절 본문의 실제 diff 가 없음: $cc"
printf '%s' "$cc" | grep -q '^+what unit 04 does (policy a 반영)$' && printf '%s' "$cc" | grep -q '^+- \[USER-QUESTION\]\[scope=impl\]\[worker-gap=04-unit#1\] policy → a 로 한다$' || fail "R7: [CHANGED CONTRACT] 에 implementation 절·사용자 결정 diff 가 없음"
printf '%s' "$cc" | grep -q 'unit 0[123]' && fail "R7: 변경 계약에 다른 unit 의 절이 섞임"
grep -q '^+how unit 04 is built — 사용자 결정: policy a$' .agent-work/units/04-unit/changed-contract.diff || fail "R7: changed-contract.diff 파일에 diff 가 남지 않음"
p="$(block 04 'UNIT TURN' | sed -n 's/^previous_contract_fingerprint=//p')"; c="$(block 04 'UNIT TURN' | sed -n 's/^current_contract_fingerprint=//p')"
[ -n "$p" ] && [ -n "$c" ] && [ "$p" != "$c" ] || fail "R11: [UNIT TURN] 의 이전·현재 계약 지문이 없거나 같음"
pass "R11/R7/R9: gap 체크포인트 archive 뒤에도 kind=RESUME + 실제 계약 diff(절 본문·사용자 결정), 다른 unit 완료는 그대로"

# ===== R7b: 워커 DONE 뒤 계약 변경 → 과거 worker-result 의 테스트-only 재개 금지 =====
fresh; touch "$MOCK_STATE/fail-test-04"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_TEST_RETRIES_EXHAUSTED ] || { tail -20 "$TMP/run.log"; fail "R7b: 전제(unit 04 테스트 재시도 소진) 실패 (rc $rc/$(reason))"; }
rm -f "$MOCK_STATE/fail-test-04"
cp -R .agent-work "$TMP/side/agent-work.r7b"; cp src/u04.txt "$TMP/side/u04.r7b"
rc="$(run_runner)"   # 계약 변경 없음 → 유효 결과 + tree 일치 + 계약 일치 → 테스트부터
[ "$rc" -eq 0 ] && [ -z "$(workers)" ] && [ "$(calls 'test-04')" -eq 1 ] || { tail -20 "$TMP/run.log"; fail "R7b: 계약이 그대로인데 테스트-only 재개가 아님 (rc $rc, workers: $(workers))"; }
rm -rf .agent-work; cp -R "$TMP/side/agent-work.r7b" .agent-work; cp "$TMP/side/u04.r7b" src/u04.txt   # 같은 중단 시점으로 되돌린 뒤 이번엔 문서를 바꾼다
set_section implementation.md 04 'what unit 04 does — 요구가 바뀜'
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -30 "$TMP/run.log"; fail "R7b: 계약 변경 뒤 재실행 실패 (rc $rc/$(reason))"; }
[ "$(workers)" = "worker 04-unit" ] || fail "R7b: 계약이 바뀌었는데 워커 없이 테스트만 재개됨: $(paste -sd'|' "$MOCK_LOG")"
grep -q '테스트-only 재개 금지' "$TMP/run.log" || fail "R7b: 테스트-only 재개 차단 사유가 로그에 없음"
block 04 'UNIT TURN' | grep -qx 'kind=RESUME' && block 04 'CHANGED CONTRACT' | grep -q '^+what unit 04 does — 요구가 바뀜$' || fail "R7b: 재개 턴에 RESUME·변경 diff 가 전달되지 않음"
grep -q '기존 구현 전체' "$MOCK_STATE/prompt-04.txt" || fail "R7b: 프롬프트가 기존 구현의 계약 대조를 요구하지 않음"
pass "R7b: 계약이 같으면 테스트부터, 바뀌었으면 과거 DONE 결과로 테스트만 돌리지 않고 워커 턴(RESUME + diff)"

# ===== RV: 러너 — 리뷰어 출력 계약 위반은 REVIEW_OUTPUT_INVALID (모든 unit 완료 뒤 review 에서 멈춘 상태를 R8 이 이어 쓴다) =====
fresh; touch "$MOCK_STATE/review-invalid"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(status)" = NEED_USER ] && [ "$(reason)" = REVIEW_OUTPUT_INVALID ] || { tail -20 "$TMP/run.log"; fail "RV: 무효 리뷰 출력이 NEED_USER/REVIEW_OUTPUT_INVALID 가 아님 (rc $rc/$(status)/$(reason))"; }
jq -e '.active==true and .errors[0].rule_id=="SCHEMA_VERSION_MISMATCH"' .agent-work/reviews/invalid-review.json >/dev/null || fail "RV: invalid-review.json 진단 불일치"
jq -r '.detail' .agent-work/run-state.json | grep -q -- '--new-review-attempt' || fail "RV: 복구 안내(--new-review-attempt)가 detail 에 없음"
rm -f "$MOCK_STATE/review-invalid"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = REVIEW_OUTPUT_INVALID ] && [ ! -s "$MOCK_LOG" ] || fail "RV: 일반 재실행이 모델을 호출하거나 같은 진단을 돌려주지 않음 (rc $rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"
cp -R .agent-work "$TMP/side/agent-work.rv"; for u in 01 02 03 04; do cp "src/u$u.txt" "$TMP/side/u$u.rv"; done
rc="$(run_runner --new-review-attempt)"
[ "$rc" -eq 0 ] && [ "$(calls reviewer)" -eq 1 ] && [ -z "$(workers)" ] && [ -f .agent-work/reviews/impl-attempt-02/reviewer-round-01.json ] || { tail -20 "$TMP/run.log"; fail "RV: --new-review-attempt 가 새 attempt 리뷰 1회 → DONE 이 아님 (rc $rc)"; }
pass "RV: 리뷰어 출력 계약 위반 → NEED_USER/REVIEW_OUTPUT_INVALID, 재실행 모델 0회, --new-review-attempt 로만 새 리뷰"
restore_rv() { rm -rf .agent-work; cp -R "$TMP/side/agent-work.rv" .agent-work; for u in 01 02 03 04; do cp "$TMP/side/u$u.rv" "src/u$u.txt"; done; cp "$TMP/side/config.good.sh" "$CFG"; }

# ===== R8/R9: 이미 DONE 인 unit 04 의 관련 절 변경 → stale, 워커 재대조 + 테스트 뒤 새 done.json =====
restore_rv
fp04="$(done_fp 04)"; fp01="$(done_fp 01)"
set_section design.md D04 'design of unit 04 — Drop/실주 승인 요청에도 사유 표시'
set_section implementation.md 04 'what unit 04 does + 사유 표시'
( source "$CFG"; unit_done_valid 04-unit ) && fail "R8: 문서가 바뀌었는데 unit 04 완료 체크포인트가 유효로 판정됨(unit JSON 은 그대로)"
( source "$CFG"; unit_done_valid 03-unit ) || fail "R9: unit 04 의 독립 절만 바뀌었는데 unit 03 완료가 무효가 됨"
rc="$(run_runner --new-review-attempt)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "R8: stale unit 재실행이 DONE 이 아님 (rc $rc/$(reason))"; }
[ "$(workers)" = "worker 04-unit" ] && [ "$(calls 'test-04')" -eq 1 ] || fail "R8: stale unit 04 가 워커 재대조 + targeted test 를 거치지 않음: $(paste -sd'|' "$MOCK_LOG")"
[ "$(done_fp 04)" != "$fp04" ] && [ "$(done_fp 01)" = "$fp01" ] || fail "R8: unit 04 의 done 지문이 갱신되지 않았거나 unit 01 이 다시 쓰임"
[ -f .agent-work/units/04-unit/contract/history/01/contract.txt ] && grep -q 'design of unit 04$' .agent-work/units/04-unit/contract/history/01/contract.txt || fail "R8: 이전 기준 계약이 history 에 보존되지 않음"
block 04 'UNIT TURN' | grep -qx 'kind=RESUME' && block 04 'CHANGED CONTRACT' | grep -q '^+design of unit 04 — Drop/실주 승인 요청에도 사유 표시$' || fail "R8: 재대조 턴에 design 절 diff 가 전달되지 않음"
[ "$(calls 'validator design')" -eq 1 ] && [ "$(calls 'validator impl')" -eq 1 ] || fail "R8: design.md 변경 뒤 정상 재합의(design 1·impl 1)가 아님: $(paste -sd'|' "$MOCK_LOG")"
pass "R8/R9: DONE 이던 unit 04 만 stale → 워커 재대조·테스트 뒤 새 done.json, 01~03 은 건너뜀"

# ===== R12: stale 선행 unit + 완료된 후행 unit → UNIT_CHECKPOINT_CHAIN_STALE =====
restore_rv
set_section approach.md A02 'how unit 02 is built — 방식 변경'
tree_before="$(tree_now)"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECKPOINT_CHAIN_STALE ] || { tail -20 "$TMP/run.log"; fail "R12: UNIT_CHECKPOINT_CHAIN_STALE 이 아님 (rc $rc/$(reason))"; }
[ -z "$(workers)" ] && [ "$(tree_now)" = "$tree_before" ] || fail "R12: 워커가 호출됐거나 source 가 자동 원복·변경됨"
[ -f .agent-work/units/03-unit/done.json ] && [ -f .agent-work/units/04-unit/done.json ] || fail "R12: 뒤 unit 체크포인트를 러너가 지움"
jq -e '.completed_units==["01-unit"]' .agent-work/implementation-context.json >/dev/null 2>&1 || true   # (context 는 유효한 완료 prefix 로만 재구성된다 — 아래 함수 검사)
( source "$CFG"; impl_context_write && jq -e '.completed_units==["01-unit"]' "$IMPL_CONTEXT_FILE" >/dev/null ) || fail "R12: implementation-context 가 유효한 완료 prefix(01)로만 재구성되지 않음"
pass "R12: 계약이 바뀐 선행 unit + 완료된 후행 unit → 기존 UNIT_CHECKPOINT_CHAIN_STALE, 자동 restore·재실행 없음"

# ===== R10: 해석 불가 references·전역 입력 변경 → 영향 없음으로 넘어가지 않고 모델 0회 =====
restore_rv   # (a) 참조 절 삭제
awk '$0=="## 03"{skip=1; next} /^## /{skip=0} !skip{print}' .agent-work/implementation.md > "$TMP/doc.tmp" && cp "$TMP/doc.tmp" .agent-work/implementation.md
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CONTRACT_IMPACT_REQUIRED ] && [ ! -s "$MOCK_LOG" ] || { tail -20 "$TMP/run.log"; fail "R10a: 참조 절 삭제가 0회 중단이 아님 (rc $rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"; }
jq -r '.detail' .agent-work/run-state.json | grep -q "implementation.md#03" || fail "R10a: 어느 reference 가 해석되지 않는지 detail 에 없음"
restore_rv   # (b) 모호한 heading(중복)
printf '\n## 02\n또 다른 02 절\n' >> .agent-work/implementation.md
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CONTRACT_IMPACT_REQUIRED ] && [ ! -s "$MOCK_LOG" ] || fail "R10b: 모호한 heading 이 0회 중단이 아님 (rc $rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"
jq -r '.detail' .agent-work/run-state.json | grep -q '둘 이상' || fail "R10b: 모호(복수 매칭) 사유가 detail 에 없음"
restore_rv   # (c) unit 에 묶이지 않은 전역 결정 추가
echo '- [USER-QUESTION][scope=impl] 공통 오류 응답 형식 → 기존 형식 유지' >> .agent-work/decisions.md
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CONTRACT_IMPACT_REQUIRED ] && [ ! -s "$MOCK_LOG" ] || { tail -20 "$TMP/run.log"; fail "R10c: 전역 결정 변경이 0회 중단이 아님 (rc $rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"; }
grep -q '공통 오류 응답 형식' .agent-work/units/01-unit/global-impact.diff || fail "R10c: 전역 변경 diff(global-impact.diff)가 남지 않음"
fp_req="$(jq -r .target_fingerprint .agent-work/unit-contract-impact.request.json)"
[ "${#fp_req}" -eq 64 ] && jq -r '.detail' .agent-work/run-state.json | grep -q "$fp_req" && jq -e '.version==2 and ([.units[].id]==["01-unit","02-unit","03-unit","04-unit"]) and all(.units[]; .status=="IMPACT_REQUIRED" and (.local_fingerprint|length)==64 and (.global_fingerprint|length)==64)' .agent-work/unit-contract-impact.request.json >/dev/null \
  || fail "R10c: 확정 대상 지문이 request 파일·detail 에 없음: $(cat .agent-work/unit-contract-impact.request.json)"
# 일부만 적은 확정 파일은 적용되지 않는다(모델 0회)
impact '["04-unit"]' '["01-unit"]'
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CONTRACT_IMPACT_REQUIRED ] && [ -f .agent-work/unit-contract-impact.json ] && [ ! -s "$MOCK_LOG" ] || fail "R10c: 대상 unit 을 빠뜨린 확정 파일이 적용됐거나 모델이 호출됨 (rc $rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"
# R10e: 확정(판단) 뒤 계약이 한 번 더 바뀌면 — 대상 unit 집합은 같아도 — 같은 확정 파일을 적용하지 않는다(모델 0회, 파일 미소비, 완료 체크포인트 불변)
impact '["04-unit"]' '["01-unit","02-unit","03-unit"]'
fp01="$(done_fp 01)"
echo '- [USER-QUESTION][scope=impl] 공통 로그 형식 → JSON 한 줄' >> .agent-work/decisions.md   # 사용자가 판단한 뒤에 들어온 또 다른 전역 변경
rc="$(run_runner --new-review-attempt)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CONTRACT_IMPACT_REQUIRED ] && [ ! -s "$MOCK_LOG" ] || { tail -20 "$TMP/run.log"; fail "R10e: 확정 뒤 계약이 바뀌었는데 옛 확정이 적용됐거나 모델이 호출됨 (rc $rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"; }
[ -f .agent-work/unit-contract-impact.json ] && ! ls .agent-work/unit-contract-impact.used.*.json >/dev/null 2>&1 && [ "$(done_fp 01)" = "$fp01" ] || fail "R10e: 지문이 다른 확정 파일이 소비됐거나 완료 체크포인트가 갱신됨"
jq -r '.detail' .agent-work/run-state.json | grep -q '계약 지문' || fail "R10e: 지문 불일치 사유가 detail 에 없음: $(jq -r .detail .agent-work/run-state.json)"
fp_req2="$(jq -r .target_fingerprint .agent-work/unit-contract-impact.request.json)"
[ "$fp_req2" != "$fp_req" ] && jq -r '.detail' .agent-work/run-state.json | grep -q "$fp_req2" || fail "R10e: 현재 확정 대상 지문이 갱신·안내되지 않음"
grep -q '공통 로그 형식' .agent-work/units/01-unit/global-impact.diff || fail "R10e: 다시 확인할 diff 에 새 변경이 없음"
# 지문 없는 옛 형식(version 1)은 대상 집합이 맞아도 적용하지 않는다
printf '{"version":1,"affected_units":["04-unit"],"unaffected_units":["01-unit","02-unit","03-unit"]}\n' > .agent-work/unit-contract-impact.json
rc="$(run_runner --new-review-attempt)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CONTRACT_IMPACT_REQUIRED ] && [ ! -s "$MOCK_LOG" ] && [ -f .agent-work/unit-contract-impact.json ] && jq -r '.detail' .agent-work/run-state.json | grep -q 'version 1' \
  || fail "R10e: 지문 없는 version 1 확정 파일이 적용됨 (rc $rc/$(reason))"
pass "R10e: 영향 확정은 판단 당시 계약 지문에 묶인다 — 확정 뒤 계약 변경·지문 없는 옛 형식은 모델 0회로 재확정 요구"
# 명시 확정(현재 지문으로 다시): 01~03 영향 없음, 04 영향 있음 → 04 만 변경 계약으로 다시 돈다
impact '["04-unit"]' '["01-unit","02-unit","03-unit"]'
fp01="$(done_fp 01)"
rc="$(run_runner --new-review-attempt)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "R10c: 영향 확정 뒤 실행이 DONE 이 아님 (rc $rc/$(reason))"; }
[ "$(workers)" = "worker 04-unit" ] || fail "R10c: affected 로 확정한 unit 04 만 다시 돌지 않음: $(workers)"
[ ! -f .agent-work/unit-contract-impact.json ] && ls .agent-work/unit-contract-impact.used.*.json >/dev/null 2>&1 || fail "R10c: 확정 파일이 소비(.used)되지 않음"
jq -e --arg fp "$fp_req2" '.version==2 and .contract_determinations[0].decision=="unaffected" and .contract_determinations[0].target_fingerprint==$fp' .agent-work/units/01-unit/done.json >/dev/null && [ "$(done_fp 01)" != "$fp01" ] || fail "R10c: unaffected unit 의 완료 체크포인트에 확정 기록(대상 지문 포함)·전역 지문 갱신이 없음"
ls .agent-work/unit-contract-impact.request.used.*.json >/dev/null 2>&1 && [ ! -f .agent-work/unit-contract-impact.request.json ] || fail "R10c: 적용된 확정의 request 내역이 .used 로 보존되지 않음"
block 04 'CHANGED CONTRACT' | grep -q '^+- \[USER-QUESTION\]\[scope=impl\] 공통 오류 응답 형식' || fail "R10c: affected unit 의 변경 계약에 전역 결정 diff 가 없음"
[ "$(calls 'validator design')" -eq 0 ] && [ "$(calls 'validator impl')" -eq 1 ] || fail "R10c: scope=impl 결정이 design 검증자를 다시 부름: $(paste -sd'|' "$MOCK_LOG")"
restore_rv   # (d) request.md 변경(전역) — 합의 검증자보다 먼저 멈춘다
printf '\n추가 문장\n' >> .agent-work/request.md
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CONTRACT_IMPACT_REQUIRED ] && [ ! -s "$MOCK_LOG" ] || fail "R10d: request.md 변경이 0회 중단이 아님 (rc $rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"
pass "R10: 절 삭제·모호한 heading·전역 결정·request.md 변경 → UNIT_CONTRACT_IMPACT_REQUIRED(모델 0회), 명시 확정 뒤에만 진행"

# ===== R16: 포맷·계약 버전이 다른 과거 DONE / PASS / APPROVE 를 재사용하지 않는다 =====
restore_rv   # done.json v1 + 스냅샷 없음(이 기능 이전의 산출물)
for u in 01 02 03 04; do
  jq '.version=1 | del(.unit_contract_fingerprint, .contract_local_fingerprint, .contract_global_fingerprint)' ".agent-work/units/$u-unit/done.json" > "$TMP/d.tmp" && cp "$TMP/d.tmp" ".agent-work/units/$u-unit/done.json"
  rm -rf ".agent-work/units/$u-unit/contract" ".agent-work/units/$u-unit/worker-contract.json"
done
( source "$CFG"; unit_done_valid 01-unit ) && fail "R16: 계약 지문 없는 done.json v1 이 유효로 판정됨"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CONTRACT_IMPACT_REQUIRED ] && [ ! -s "$MOCK_LOG" ] || { tail -20 "$TMP/run.log"; fail "R16: 스냅샷 없는 과거 unit 이 0회 중단이 아님 (rc $rc/$(reason))"; }
# 포맷만 v2 로 고쳐 써도(스냅샷 없이) 유효해지지 않는다
jq '.version=2 | .unit_contract_fingerprint="forged"' .agent-work/units/01-unit/done.json > "$TMP/d.tmp" && cp "$TMP/d.tmp" .agent-work/units/01-unit/done.json
( source "$CFG"; unit_done_valid 01-unit ) && fail "R16: done.json 포맷만 맞춘 위조가 유효로 판정됨"
impact '[]' '["01-unit","02-unit","03-unit","04-unit"]'
rc="$(run_runner --new-review-attempt)"
[ "$rc" -eq 0 ] && [ -z "$(workers)" ] || { tail -20 "$TMP/run.log"; fail "R16: 사용자가 baseline 을 확정했는데 진행되지 않거나 워커가 재호출됨 (rc $rc/$(reason))"; }
jq -e '.baseline_source=="user-confirmed-unaffected"' .agent-work/units/02-unit/contract/contract.json >/dev/null || fail "R16: 사용자 확정 baseline 의 출처가 기록되지 않음"
# 검증 계약·리뷰 계약 버전이 바뀌면 이전 PASS·APPROVE 는 현재 계약의 것이 아니다
( source "$CFG"; consensus_pass_current design && consensus_pass_current impl && impl_approval_current && all_units_done ) || fail "R16: 전제(현재 계약에서 PASS·APPROVE·DONE 유효) 실패"
sed -i.bak "s/^VALIDATOR_CONTRACT_VERSION=.*/VALIDATOR_CONTRACT_VERSION=$((VC + 1))/" "$CFG" && rm -f "$CFG.bak"
( source "$CFG"; consensus_pass_current design || consensus_pass_current impl || consensus_stage_accepted impl ) && fail "R16: 검증 계약 버전이 바뀌었는데 이전 PASS 가 유효로 판정됨"
cp "$TMP/side/config.good.sh" "$CFG"
sed -i.bak "s/^REVIEWER_CONTRACT_VERSION=.*/REVIEWER_CONTRACT_VERSION=$((RC + 1))/" "$CFG" && rm -f "$CFG.bak"
( source "$CFG"; impl_approval_current ) && fail "R16: 리뷰어 계약 버전이 바뀌었는데 이전 APPROVE 가 유효로 판정됨"
cp "$TMP/side/config.good.sh" "$CFG"
pass "R16: done.json v1·포맷만 맞춘 위조·계약 버전이 다른 PASS/APPROVE 는 재사용되지 않고, 과거 unit 은 명시적 baseline 확정 뒤에만 이어진다"

# ===== R13: design PASS 뒤 scope=impl 순수 구현 결정 → design 검증자 0회 =====
restore_rv
bash .claude/skills/feature/scripts/consensus-loop.sh design > "$TMP/c.log" 2>&1 || fail "R13: 전제(design PASS 재사용) 실패"
echo '- [USER-QUESTION][scope=impl] unit 04 scope 에 테스트 파일을 추가하는가 → 추가한다' >> .agent-work/decisions.md
: > "$MOCK_LOG"
bash .claude/skills/feature/scripts/consensus-loop.sh design > "$TMP/c.log" 2>&1 || { tail -10 "$TMP/c.log"; fail "R13: design 루프 실패"; }
[ "$(calls validator)" -eq 0 ] && grep -q '기존 PASS 체크포인트 재사용' "$TMP/c.log" || fail "R13: scope=impl 결정이 design 검증자를 다시 부름"
bash .claude/skills/feature/scripts/consensus-loop.sh impl > "$TMP/c.log" 2>&1 || { tail -10 "$TMP/c.log"; fail "R13: impl 루프 실패"; }
[ "$(calls 'validator impl')" -eq 1 ] && [ "$(calls 'validator design')" -eq 0 ] || fail "R13: impl 만 재검증되지 않음: $(paste -sd'|' "$MOCK_LOG")"
grep -q 'unit 04 scope 에 테스트 파일' .agent-work/reviews/user-decisions-impl.md || fail "R13: impl 검증자 입력에 scope=impl 결정이 없음"
grep -q 'unit 04 scope 에 테스트 파일' .agent-work/reviews/user-decisions-design.md && fail "R13: design 검증자 입력에 scope=impl 결정이 들어감(단계 격리 위반)"
pass "R13: scope=impl 순수 구현 결정은 design 재검증 0회, impl 만 갱신"

# ===== R14/R15: 늦게 나온 제품 요구 — request.md append + scope=design + design 절 수정 =====
fresh; touch "$MOCK_STATE/undecided-04"
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] || fail "R14: 전제(unit 04 UNDECIDED, pending gap) 실패 (rc $rc/$(reason))"
printf '\n## 요구 변경/추가\n- 2026-11-10 — Drop/실주 승인·취소 승인 요청 Slack 에도 사유를 표시한다. 원 요구 "문의 접근 권한 요청만 Slack 사유 표시"를 이 두 유형에 한해 대체한다. 리마인드 알림은 제외(원 요구 유지).\n' >> .agent-work/request.md
echo '- [USER-QUESTION][scope=design] Drop/실주 승인·취소 승인 요청 Slack 에도 사유를 넣는가 → 넣는다(리마인드 제외)' >> .agent-work/decisions.md
set_section design.md D04 'design of unit 04 — Drop/실주 승인·취소 승인 요청에도 사유 표시(리마인드 제외)'
set_section implementation.md 04 'what unit 04 does + 승인 요청 사유 표시'
# 전역 입력(request.md·묶이지 않은 결정)이 바뀌었으므로 완료된 unit 의 영향도 확정해야 한다 — 확정은 재합의로 문서가 확정된 뒤의 계약 지문에 묶이므로
# 먼저 재합의(design → impl)가 돌고 worker 진입에서 멈춘 다음, 러너가 내준 지문으로 확정한다(재실행은 PASS 재사용 — 검증자 0회).
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CONTRACT_IMPACT_REQUIRED ] && [ -z "$(workers)" ] || { tail -30 "$TMP/run.log"; fail "R14: 재합의 뒤 영향 확정 요구로 멈추지 않음 (rc $rc/$(reason))"; }
[ "$(calls 'validator design')" -eq 1 ] && [ "$(calls 'validator impl')" -eq 1 ] || fail "R14: 정상 design → impl 재합의(각 1회)가 아님: $(paste -sd'|' "$MOCK_LOG")"
impact '[]' '["01-unit","02-unit","03-unit"]'
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "R14: 제품 요구 추가 뒤 실행이 DONE 이 아님 (rc $rc/$(reason))"; }
[ "$(calls validator)" -eq 0 ] || fail "R14: 영향 확정 뒤 재실행이 검증자를 다시 부름: $(paste -sd'|' "$MOCK_LOG")"
grep -q 'Drop/실주 승인·취소 승인 요청 Slack 에도 사유를 넣는가' .agent-work/reviews/user-decisions-design.md || fail "R14: design 검증자 입력(user-decisions-design.md)에 최신 scope=design 결정이 없음"
grep -q 'user-decisions-design.md' "$MOCK_STATE/validator-prompt-design.txt" || fail "R14: design 검증자 프롬프트가 결정 파일을 입력으로 주지 않음"
[ "$( ( source "$CFG"; consensus_user_decision_lines design ) )" = "$(tail -n +2 .agent-work/reviews/user-decisions-design.md)" ] || fail "R14: 검증자에게 준 결정 집합과 지문에 들어가는 결정 집합이 다름"
for t in design impl; do
  grep -q '요구 변경/추가' "$MOCK_STATE/validator-prompt-$t.txt" && grep -q '명시한 대상·범위 안에서만' "$MOCK_STATE/validator-prompt-$t.txt" \
    && grep -q '원 요구가 그대로 기준' "$MOCK_STATE/validator-prompt-$t.txt" && grep -q '주장만으로는 옛 요구가 대체되지 않는다' "$MOCK_STATE/validator-prompt-$t.txt" \
    || fail "R15: $t 검증자 프롬프트에 '뒤 요구는 명시한 범위에서만 대체, 범위 밖은 원 요구 유지' 규칙이 없음"
done
[ "$(jq -r .next_step .agent-work/doc-gap-resume.json)" = SUPERSEDED ] || fail "R14: 재합의 뒤 옛 pending gap 이 SUPERSEDED 로 남지 않음($(jq -r .next_step .agent-work/doc-gap-resume.json))"
[ "$(workers)" = "worker 04-unit" ] && block 04 'UNIT TURN' | grep -qx 'kind=RESUME' && block 04 'CHANGED CONTRACT' | grep -q '^+design of unit 04 — Drop/실주 승인·취소 승인 요청에도 사유 표시(리마인드 제외)$' \
  || fail "R14: unit 04 가 변경 계약(RESUME + design 절 diff)으로 다시 돌지 않음: $(workers)"
( source "$CFG"; consensus_pass_current design && consensus_pass_current impl ) || fail "R14: 재합의 뒤 PASS 가 현재 입력에 대해 유효하지 않음"
pass "R14/R15: 늦게 나온 제품 요구는 request.md 변경 기록 + scope=design 으로 design 검증자 입력에 들어가고, 옛 gap 체크포인트로 재합의를 건너뛰지 않는다"

# ===== R17: 리뷰 DOC_GAP 사용자 해결 예외는 그 gap 과 연결된 unit 의 approach 절 변경에만 적용된다 =====
fresh; touch "$MOCK_STATE/review-docgap"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = REVIEW_DOC_GAP ] || { tail -20 "$TMP/run.log"; fail "R17: 전제(리뷰 DOC_GAP — 코드 위치 src/u04.txt) 실패 (rc $rc/$(reason))"; }
echo '- [USER-QUESTION][scope=impl][review-issue=R-01] 어느 방식인가 → a' >> .agent-work/decisions.md
set_section approach.md A04 'how unit 04 is built — [review-issue=R-01] 결정: a'   # gap 의 코드 위치(src/u04.txt)가 속한 unit 04 의 절 — 어느 gap 의 해결인지 tag 로 표시
cp -R .agent-work "$TMP/side/agent-work.r17"; for u in 01 02 03 04; do cp "src/u$u.txt" "$TMP/side/u$u.r17"; done
restore_r17() { mv .agent-work "$TMP/side/agent-work.r17.spent.$RANDOM"; cp -R "$TMP/side/agent-work.r17" .agent-work; for u in 01 02 03 04; do cp "$TMP/side/u$u.r17" "src/u$u.txt"; done; }
# (a) 연결된 unit 의 approach 절만 바뀜 → 예외 적용: unit 워커 재실행 없이 review-gap 워커 → 리뷰 → DONE
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "R17a: gap 과 연결된 unit 의 approach 절만 바뀌었는데 DONE 이 아님 (rc $rc/$(reason))"; }
[ -z "$(workers)" ] && [ "$(calls review-gap-worker)" -eq 1 ] && [ "$(calls validator)" -eq 0 ] || fail "R17a: review-gap 워커 1회(검증자·unit 워커 0회)가 아님: $(paste -sd'|' "$MOCK_LOG")"
[ "$( ( source "$CFG"; unit_contract_status 04-unit ) )" = STALE ] && ( source "$CFG"; unit_done_valid 04-unit && unit_done_valid 02-unit ) || fail "R17a: 연결된 unit 04 의 계약 변경이 gap 해결로 인정되지 않음"
# (b) 같은 해결에서 gap 과 무관한 unit 02 의 approach 절까지 고침 → 02 는 정상 stale. review-gap 워커·리뷰어를 부르기 전에 모델 0회로 멈춘다
restore_r17
set_section approach.md A02 'how unit 02 is built — gap 과 무관한 변경'
tree_before="$(tree_now)"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = DOC_GAP_SCOPE_EXCEEDED ] && [ ! -s "$MOCK_LOG" ] || { tail -30 "$TMP/run.log"; fail "R17b: 무관한 unit 의 계약 변경이 DOC_GAP 예외로 덮임 (rc $rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"; }
jq -r '.detail' .agent-work/run-state.json | grep -q '(02-unit)' || fail "R17b: stale unit(02-unit 만)이 detail 에 없음: $(jq -r .detail .agent-work/run-state.json)"
[ "$(tree_now)" = "$tree_before" ] || fail "R17b: source 가 변경·원복됨"
( source "$CFG"; doc_gap_resolved_current ) || fail "R17b: 전제 — 해결 provenance 자체는 유효해야 한다(예외 범위만 검증)"
( source "$CFG"; unit_done_valid 02-unit ) && fail "R17b: 유효한 리뷰 DOC_GAP 해결 기록이 있다는 이유로 무관한 unit 02 의 완료가 유지됨"
( source "$CFG"; unit_done_valid 04-unit && unit_done_valid 01-unit && unit_done_valid 03-unit ) || fail "R17b: 연결된 unit 04 또는 변경 없는 unit 의 완료가 무효가 됨"
# (c) 연결된 unit 이어도 전역 입력이 같이 바뀌면 gap 해결로 설명되지 않는다
restore_r17
echo '- [USER-QUESTION][scope=impl] 공통 오류 응답 형식 → 기존 형식 유지' >> .agent-work/decisions.md
( source "$CFG"; doc_gap_accept ) || fail "R17c: 전제(gap 수리) 실패"
( source "$CFG"; unit_done_valid 04-unit ) && fail "R17c: 전역 입력이 바뀌었는데 unit 04 완료가 gap 예외로 유지됨"
# (d) 같은 unit 의 다른 approach 절(B04 — gap 과 무관)까지 고침 → A04 에 tag 가 있어도 B04 변경은 덮이지 않는다
restore_r17
set_section approach.md B04 'second approach rule of the last unit — gap 과 무관하게 바뀐 계약'
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = DOC_GAP_SCOPE_EXCEEDED ] && [ ! -s "$MOCK_LOG" ] || { tail -30 "$TMP/run.log"; fail "R17d: 같은 unit 의 무관한 approach 절 변경이 DOC_GAP 예외로 덮임 (rc $rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"; }
jq -r '.detail' .agent-work/run-state.json | grep -q '(04-unit)' && jq -r '.detail' .agent-work/run-state.json | grep -q '\[review-issue=R-01\]' || fail "R17d: stale unit·필요한 tag 가 detail 에 없음: $(jq -r .detail .agent-work/run-state.json)"
( source "$CFG"; unit_done_valid 04-unit ) && fail "R17d: A04(gap 해결) + B04(무관) 변경인데 unit 04 완료가 유지됨"
# (e) 연결된 unit 의 절이어도 어느 gap 의 해결인지 표시가 없으면 확정할 수 없다 → 자동 승인하지 않는다
restore_r17
set_section approach.md A04 'how unit 04 is built — 결정: a (tag 없음)'
( source "$CFG"; doc_gap_accept ) || fail "R17e: 전제(gap 수리) 실패"
( source "$CFG"; unit_done_valid 04-unit ) && fail "R17e: gap tag 표시가 없는 approach 절 변경이 gap 해결로 인정됨"
# (f) new_file_roots 는 끝 슬래시가 있어도(src/gen/) 그 아래 파일을 가리킨 gap 과 연결된다. 접두만 같은 다른 디렉터리(src/generic/)는 아니다
printf '{"gaps":[{"tag":"review-issue=R-07","refs":["approach.md:L1-L1","src/gen/New.java:L3-L4"],"location":"src/gen/New.java:L3-L4"},{"tag":"review-issue=R-08","refs":[],"location":"src/generic/Other.java:L1-L1"}]}\n' > "$TMP/gaps.json"
for root in 'src/gen/' 'src/gen'; do
  uj_f="$(jq -nc --arg r "$root" '{scope:{files:[], new_file_roots:[$r]}}')"
  linked_f="$( ( source "$CFG"; DOC_GAP_RESUME="$TMP/gaps.json"; _unit_gap_linked_tags "$uj_f" ) )"
  [ "$linked_f" = '["review-issue=R-07"]' ] \
    || fail "R17f: new_file_roots '$root' 아래 파일의 gap 이 연결되지 않거나 다른 디렉터리의 gap 이 연결됨"
done
pass "R17: 리뷰 DOC_GAP 예외는 gap 의 코드 위치가 속한 unit 의, gap tag 가 적힌 approach 절 변경에만 — 무관한 unit·같은 unit 의 다른 절·표시 없는 절·전역 변경은 stale(모델 0회로 중단)"

grep -q 'CODEX-CALLED' "$MOCK_LOG" && fail "역할 CLI 고정 위반: codex 가 호출됨"
echo "[SMOKE OK] unit 계약·결정 scope 스모크 전체 통과"
rm -rf "$TMP"
