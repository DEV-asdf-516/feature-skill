#!/usr/bin/env bash
# =============================================================
# 스모크: 결정론적 검증 게이트 — Unit 정적 검사(UNIT_CHECK_CMD) · 위험도별 추가 검증(RISK_VERIFY_CMD) · DONE 뒤 사후 분석 보고서(post-run-report.json)
# 실제 LLM 호출 없음 (공용 mock CLI: 역할은 스키마로 판별, 모델→CLI 매핑 무관), 임시 fixture 프로젝트
# 파일 경로: tests/smoke-verification-gates.sh
# 사용법: bash tests/smoke-verification-gates.sh   (어디서든 실행 가능)
#
# fixture 프로젝트는 자기 검사 스크립트(tools/unit-check.sh — 변경 파일의 금지 토큰, tools/risk.sh — 위험도 판정 + 추가 검증)를 갖는다. 하네스에는 그 규칙이 없다.
# Unit 정적 검사:
#   U1. 미설정(빈 값 / 설정 줄이 없는 기존 config.sh): 종전 흐름 그대로, "생략" 로그, 실행 기록 없음
#   U2. PASS → targeted test → unit DONE. 변경 파일 목록은 그 unit 이 바꾼 파일만(다른 unit 의 파일 없음)
#   U3. VIOLATION → 리뷰어 호출 없이 unit 수정 턴(기존 worker-unit-fix 경로) → 재검사 → 다음 unit
#   U4. 정적 검사 위반 + targeted test 실패가 함께 → 수정 턴은 1회(검사용·테스트용을 따로 부르지 않는다)
#   U5. ERROR → 워커·테스트 호출 없이 중단, 재실행도 모델 0회, 고친 뒤에는 워커 재호출 없이 검사부터
#   U6. 검사가 코드를 바꿈(WORKTREE_MODIFIED) / index 를 바꿈 → 중단, 변경 보존, 되돌리기 전의 재실행은 검사·모델 0회
#   U7. 수정 턴이 unit scope 밖을 고침 → UNIT_SCOPE_VIOLATION(다음 unit 으로 가지 않음)
#   U8. 이전 PASS 재사용 없음: 수정 턴이 위반을 새로 만들면 재검사가 잡는다 / 한도 소진 뒤 재실행은 모델 0회로 같은 사유
#   U9. 뒤 unit 에서 멈춰도 앞 unit 의 완료 체크포인트는 유지되고 재실행이 앞 unit 의 워커·검사를 다시 부르지 않는다
#   U10. 설정 변경: 완료 뒤 명령이 바뀌면 워커 재호출 없이 검사만 다시(위반이면 UNIT_CHECK_STALE_VIOLATION), 승인 뒤 새로 켜도 증거 없이 verify 로 가지 않는다
#   U11. 증거는 코드·정책 입력에 결속: 검사 PASS 뒤 그 unit 의 코드가 바뀌면(worker-fix · 수정자 · 겹치는 scope 의 뒤 unit · 사용자 수동 수정) 검사만 다시,
#        명령 문자열이 같아도 검사 스크립트가 바뀌면 다시 — 모델 호출 없이, 위반이면 리뷰어·TEST_CMD 전에 멈춘다. 다른 unit 만의 변경은 무효화하지 않는다
#   U12. 정책 입력이 다른 unit 의 scope 안에 있을 때: UNIT_CHECK_POLICY_PATHS 로 선언했거나 명령 문자열이 그 파일을 가리키면 그 파일이 바뀔 때 완료 unit 을 다시 검사한다.
#        선언도 없고 명령에도 없으면 재검사하지 않는다(문서화된 한계 — 하네스는 검사기가 무엇을 읽는지 모른다). 선언한 경로가 없으면(오타) 워커 호출 전에 ENV_ERROR —
#        첫 unit 이 만들 파일(그 unit 의 scope 안)만 유예하고, 만들어지지 않으면 그 unit 의 검사에서 멈춘다
#   (U11f 보강) 수정자가 검사한 코드를 고치면 다음 리뷰어 호출 **전에** 검사만 다시 — 위반이면 두 번째 리뷰어를 부르지 않는다
#   (U6 보강) 읽기 전용 위반 뒤 다른 파일을 더 고쳐도 차단 유지 / index 를 되돌리기 전의 재실행은 통과하지 못한다  (U8 보강) 재개가 앞선 targeted test 로그를 덮어쓰지 않는다
# 위험도별 추가 검증:
#   R2. LOW → 추가 검사 없이 통과 / R3. HIGH → 프로젝트가 정한 추가 검사 실행 / R4. 위반이 남으면 TEST_CMD·DONE 차단, 재실행도 모델 0회(무한 재시도 없음)
#   R5. 위반 → 기존 worker-fix → 리뷰어 재승인 → 재검증 → DONE / R6. UNKNOWN·결과 없음·needs_human 은 LOW 로 간주하지 않는다
#   R7. 실행 오류는 위반과 다르다(워커 0회) / R8. 검증이 소스·index 를 바꾸면 차단, 바뀐 코드는 재리뷰를 지난다(index 는 되돌리기 전 재실행 차단) / R9. 코드가 바뀌어 재승인되면 검증도 다시 한다
#   R10. checks 에 FAIL 이 있는데 exit 0 → 통과도 코드 위반도 아닌 결과 계약 오류(RESULT_INCONSISTENT), checks·reasons 형식 오류 → RESULT_INVALID
#   R11. 같은 초에 verify 가 두 번 돌아도 최종 테스트 로그 경로가 겹치지 않는다(append-only 기록이 가리키는 앞선 로그 보존)
# DONE 뒤 분석:
#   D1~D12. 보고서 생성 · usage 집계와 숫자 일치 · reported/estimated 구분 · 미관측 ≠ 0 · 실패 없으면 RCA 없음 · 반복 오류 후보에 근거 · 근거 없으면 후보 없음 ·
#           재생성해도 같은 내용 · 생성 실패해도 DONE · 프로덕션 파일·승인 지문 불변 · DONE 재실행 = 모델·검증 명령 0회 · 완료 알림 중복 없음
#   D13. 손상된 실행 기록(JSONL)은 조용히 빠지지 않는다 — record_integrity 와 해당 집계의 corrupt_records 로 드러난다(미관측과 구분)
#   D14. usage.jsonl 이 손상돼도 보고서는 생성된다 — 읽힌 줄만의 하한값임을 밝히고(unreadable_usage_records·totals_are_lower_bound), 빠진 줄을 0 달러로 세지 않는다
# =============================================================
set -u
unset NTFY_TOPIC NTFY_TOKEN   # 사용자 셸의 알림 설정이 DONE 사례에서 실제 발송으로 이어지지 않게 한다(D 사례만 mock curl 로 명시 설정)
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-verification-gates-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks"
TMP="$(cd "$TMP" && pwd -P)"
fail() { echo "[SMOKE FAIL] $*" >&2; [ ! -f "$TMP/run.log" ] || tail -25 "$TMP/run.log" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

# --- fixture 프로젝트: 스킬 복사 + CHANGE_ME 채움 ---
mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
sed -i.bak "s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"legacy_cli\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"$TMP/bin/full-test\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"echo full-lint >> $TMP/calls.log\"|" "$CFG" && rm -f "$CFG.bak"
printf '%s\n' '#!/usr/bin/env bash' 'echo full-test >> "$MOCK_LOG"' '[ ! -f "$MOCK_STATE/fail-full-test" ] || { rm -f "$MOCK_STATE/fail-full-test"; echo "full test failed"; exit 1; }' > "$TMP/bin/full-test"
printf '%s\n' '#!/usr/bin/env bash' 'echo ntfy >> "$MOCK_LOG"' 'cat > /dev/null' 'printf 200' > "$TMP/bin/curl-mock"
chmod +x "$TMP/bin/full-test" "$TMP/bin/curl-mock"
for v in FAST_CHECK_CMD UNIT_CHECK_CMD RISK_VERIFY_CMD UNIT_CHECK_POLICY_PATHS; do
  grep -q "^$v=\"\"\$" "$CFG" || fail "픽스처: 소스 config.sh 의 $v 기본값이 빈 값(미설정)이 아님"
done
set_cfg() { sed -i.bak "s|^$1=.*|$1=\"$2\"|" "$CFG" && rm -f "$CFG.bak"; }   # VAR value
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src tools && echo "a base" > src/a.txt && echo "b base" > src/b.txt && echo "rule set v1" > tools/rules.txt

# fixture 프로젝트의 Unit 정적 검사: 변경 파일 목록(UNIT_CHECK_CHANGED_FILES)의 파일에서 금지 토큰을 찾는다. 계약(0 정상 / 1 위반 + 진단 / 그 외 오류)만 지킨다.
cat > tools/unit-check.sh <<'EOF'
#!/usr/bin/env bash
n="${UNIT_CHECK_UNIT_ID%%-*}"
echo "ucheck:$n" >> "$MOCK_LOG"
cat "${UNIT_CHECK_CHANGED_FILES:-/dev/null}" > "$MOCK_STATE/ucheck-changed-$n" 2>/dev/null
pwd -P > "$MOCK_STATE/ucheck-cwd"
mode=default; [ ! -f "$MOCK_STATE/ucheck-mode" ] || mode="$(cat "$MOCK_STATE/ucheck-mode")"
pattern='BAD'; [ "${1:-}" != "--strict" ] || pattern='BAD|impl'
case "$mode" in
  error) echo "unit checker crashed" >&2; exit 2;;
  error-02) [ "$n" != 02 ] || { echo "unit checker crashed on 02" >&2; exit 2; };;
  mutate) echo "autofixed by unit checker" >> src/a.txt; exit 0;;
  index) git add src/a.txt; exit 0;;
esac
found=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  if grep -nE "$pattern" "$f" > "$MOCK_STATE/ucheck-hits"; then
    found=1
    while IFS=: read -r line content; do echo "[no-bad-token] $f:$line: 금지 토큰 — $content"; done < "$MOCK_STATE/ucheck-hits"
  fi
done < "$UNIT_CHECK_CHANGED_FILES"
[ "$found" -eq 1 ] || echo "0 violations"
exit "$found"
EOF
# fixture 프로젝트의 위험도별 검증: 위험도 판정과 추가 검증을 명령 하나가 한다. mode 파일로 판정 결과를 흉내 낸다.
cat > tools/risk.sh <<'EOF'
#!/usr/bin/env bash
echo "risk" >> "$MOCK_LOG"
cat "${RISK_VERIFY_CHANGED_FILES:-/dev/null}" > "$MOCK_STATE/risk-changed" 2>/dev/null
mode=low; [ ! -f "$MOCK_STATE/risk-mode" ] || mode="$(cat "$MOCK_STATE/risk-mode")"
result() { printf '%s\n' "$1" > "$RISK_VERIFY_RESULT"; }
case "$mode" in
  low) result '{"risk_level":"LOW","checks":[],"reasons":["local change"]}'; exit 0;;
  auto)   # 인가 관련 변경으로 판정 → 권한 우회 검사를 추가로 실행
    if grep -q 'RISKY' src/a.txt; then
      echo "[authz-bypass] src/a.txt: 권한 우회 검사 실패 — RISKY call"
      result '{"risk_level":"HIGH","checks":[{"name":"authz-bypass","status":"FAIL"}],"reasons":["auth path changed"]}'; exit 1
    fi
    echo "risk-extra" >> "$MOCK_LOG"
    result '{"risk_level":"HIGH","checks":[{"name":"authz-bypass","status":"PASS"}],"reasons":["auth path changed"]}'; exit 0;;
  unknown) result '{"risk_level":"UNKNOWN","reasons":["no rule matched"]}'; exit 0;;
  noresult) exit 0;;
  human) result '{"risk_level":"CRITICAL","checks":[{"name":"migration-dry-run","status":"PASS"}],"needs_human":true}'; exit 0;;
  error) echo "risk tool crashed" >&2; exit 3;;
  fail-exit0) result '{"risk_level":"HIGH","checks":[{"name":"authz-bypass","status":"FAIL"}],"needs_human":false}'; exit 0;;   # 실패한 검증 + 정상 종료(모순)
  bad-status) result '{"risk_level":"LOW","checks":[{"name":"authz-bypass","status":"BROKEN"}]}'; exit 0;;
  bad-check) result '{"risk_level":"LOW","checks":[{"status":"PASS"}]}'; exit 0;;
  bad-reason) result '{"risk_level":"LOW","checks":[],"reasons":[{"why":"x"}]}'; exit 0;;
  mutate) echo "written by risk tool" >> src/a.txt; result '{"risk_level":"LOW"}'; exit 0;;
  index) git add src/a.txt; result '{"risk_level":"LOW"}'; exit 0;;
esac
EOF
chmod +x tools/unit-check.sh tools/risk.sh
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline

mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
printf '\n## 01\nunit 01 contract\n\n## 02\nunit 02 contract\n' >> .agent-work/implementation.md
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/a.txt","src/b.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
RUN=".claude/skills/feature/scripts/feature-run.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" FEATURE_LIVE_TEE=1 MOCK_VALIDATOR_CONTRACT="$CONTRACT" MOCK_REVIEW_CONTRACT="$REVIEW_CONTRACT"
mkdir -p "$MOCK_STATE"
for u in 01 02; do
  printf '%s\n' '#!/usr/bin/env bash' "echo test-$u >> \"\$MOCK_LOG\"" "[ ! -f \"\$MOCK_STATE/fail-test-$u\" ] || { rm -f \"\$MOCK_STATE/fail-test-$u\"; echo \"unit $u test failed\"; exit 1; }" > "$TMP/bin/test-$u"
  chmod +x "$TMP/bin/test-$u"
done
cat > .agent-work/implementation-units.json <<EOF
{"version":1,"units":[
 {"id":"01-a","title":"a","goal":"unit 01","requirements":["REQ-01"],"scope":{"files":["src/a.txt"],"new_file_roots":[]},"references":["implementation.md#01"],"targeted_test":"$TMP/bin/test-01"},
 {"id":"02-b","title":"b","goal":"unit 02","requirements":["REQ-02"],"scope":{"files":["src/b.txt"],"new_file_roots":[]},"references":["implementation.md#02"],"targeted_test":"$TMP/bin/test-02"}
]}
EOF

# --- 공용 mock CLI (bin/claude 와 bin/codex 는 같은 스크립트) — 역할은 스키마 내용으로 판별한다 ---
#   워커 호출의 종류는 프롬프트의 진단 로그 경로로 구분한다: unit-verify-NN.diag.log(검사 위반 묶음) / targeted-test-NN.log(테스트 실패) /
#   risk-verify/check-NNNN.diag.log(위험도 검증 위반) / reviews/verify-*.log(최종 테스트 실패) / 그 밖 = unit 워커 턴
cat > "$TMP/bin/mock-cli" <<'EOF'
#!/usr/bin/env bash
cli="$(basename "$0")"
out=""; schema=""; prompt=""; editing=0; resume_tid=""; want_help=0
while [ "$#" -gt 0 ]; do case "$1" in
  exec|-p) shift;;
  resume) if [ "$2" = "--help" ]; then want_help=1; else resume_tid="$2"; fi; shift 2;;
  --help) want_help=1; shift;;
  -o) out="$2"; shift 2;;
  --output-schema) schema="$(cat "$2")"; shift 2;;
  --json-schema) schema="$2"; shift 2;;
  --sandbox) [ "$2" = workspace-write ] && editing=1; shift 2;;
  --permission-mode) editing=1; shift 2;;
  --session-id|--resume|--output-format) shift 2;;
  --verbose) shift;;
  -m|-c|--model|--effort|--tools|--allowedTools|--disallowedTools|--append-system-prompt) shift 2;;
  *) prompt="$1"; shift;;
esac; done
[ "$want_help" = 1 ] && { echo "usage: codex exec resume [--json] [--output-schema] [--output-last-message] [--sandbox]"; exit 0; }
usage='"session_id":"fake","total_cost_usd":0.25,"num_turns":1,"duration_ms":1200,"usage":{"input_tokens":10,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
[ ! -f "$MOCK_STATE/claude-no-usage" ] || usage='"session_id":"fake","num_turns":1'
[ "$cli" = codex ] && printf '{"type":"thread.started","thread_id":"%s"}\n' "${resume_tid:-mock-thread-$$}"
emit() {
  if [ "$cli" = codex ]; then
    if [ -n "$out" ]; then printf '%s\n' "$1" > "$out"; else printf '%s\n' "$1"; fi
    printf '{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":100}}\n'
  else
    printf '{"structured_output":%s,%s}\n' "$1" "$usage"
  fi
}
role=""
case "$schema" in
  *'"blocking_issues"'*) role=validator;;
  *'"issues"'*) role=reviewer;;
  *'"context_updates"'*) role=worker;;
  "") [ "$editing" = 1 ] && role=fixer;;
esac
[ -n "$role" ] || { echo "UNKNOWN-ROLE cli=$cli editing=$editing" >> "$MOCK_LOG"; exit 1; }
done_json='{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}'
case "$role" in
  validator) emit "{\"schema_version\":$MOCK_VALIDATOR_CONTRACT,\"verdict\":\"PASS\",\"blocking_issues\":[]}"; exit 0;;
  reviewer) echo "reviewer" >> "$MOCK_LOG"
    if [ -f "$MOCK_STATE/review-rc" ]; then   # 1회만 수정 요청 → 기존 수정자 경로
      mv "$MOCK_STATE/review-rc" "$MOCK_STATE/review-rc.used"
      emit "{\"schema_version\":$MOCK_REVIEW_CONTRACT,\"verdict\":\"REQUEST_CHANGES\",\"issues\":[{\"id\":\"R-01\",\"action\":\"FIX_CODE\",\"category\":\"CONTRACT_VIOLATION\",\"evidence_type\":\"DIRECT_MISMATCH\",\"basis_refs\":[\"approach.md:L1\"],\"code_refs\":[\"src/a.txt:L1-L1\"],\"reachable_scenario\":\"\",\"impact\":\"\",\"why_blocks_now\":\"x\",\"required_outcome\":\"y\",\"origin\":\"ROUND_1\",\"previous_issue_id\":\"\",\"fix_ref\":\"\",\"user_question\":\"\",\"options\":[]}]}"
      exit 0
    fi
    emit "{\"schema_version\":$MOCK_REVIEW_CONTRACT,\"verdict\":\"APPROVE\",\"issues\":[]}"; exit 0;;
  fixer) echo "fixer" >> "$MOCK_LOG"
    echo "fixed by fixer" >> src/a.txt
    [ ! -f "$MOCK_STATE/fixer-adds-bad" ] || echo "BAD token by fixer" >> src/a.txt
    if [ "$cli" = codex ]; then echo ok; else printf '{"result":"ok",%s}\n' "$usage"; fi; exit 0;;
esac
uid="$(printf '%s' "$prompt" | grep -o '"id":"[0-9][0-9]-[a-z]*"' | head -1 | cut -d'"' -f4)"
n="${uid%%-*}"
ufile=src/a.txt; other=src/b.txt; [ "$n" != 02 ] || { ufile=src/b.txt; other=src/a.txt; }
strip() { grep -v "$1" "$2" > "$MOCK_STATE/strip.tmp"; cat "$MOCK_STATE/strip.tmp" > "$2"; }
if printf '%s' "$prompt" | grep -q 'unit-verify-[0-9]*\.diag\.log\|units/[^ ]*/targeted-test-[0-9]*\.log'; then
  kind=test; ! printf '%s' "$prompt" | grep -q 'unit-verify-[0-9]*\.diag\.log' || kind=diag
  echo "unit-fix:$n:$kind" >> "$MOCK_LOG"
  printf '%s' "$prompt" | grep -o '[^ ]*unit-verify-[0-9]*\.diag\.log' | head -1 > "$MOCK_STATE/unitfix-log-path"
  [ -f "$MOCK_STATE/unitfix-noop" ] || strip 'BAD' "$ufile"
  [ ! -f "$MOCK_STATE/unitfix-outside" ] || echo "unit fix leaked into the other unit" >> "$other"
  [ ! -f "$MOCK_STATE/unitfix-adds-bad" ] || echo "BAD token by unit fix" >> "$ufile"
  emit "$done_json"; exit 0
fi
if printf '%s' "$prompt" | grep -q 'risk-verify/check-[0-9]*\.diag\.log'; then
  echo "risk-fix" >> "$MOCK_LOG"
  [ -f "$MOCK_STATE/riskfix-noop" ] || strip 'RISKY' src/a.txt
  emit "$done_json"; exit 0
fi
if printf '%s' "$prompt" | grep -q 'reviews/verify-[0-9-]*\.log'; then
  echo "verify-fix" >> "$MOCK_LOG"; echo "verify fix by worker" >> src/a.txt
  [ ! -f "$MOCK_STATE/verifyfix-adds-bad" ] || echo "BAD token by verify fix" >> src/a.txt
  emit "$done_json"; exit 0
fi
echo "worker:$n" >> "$MOCK_LOG"
echo "impl $n" >> "$ufile"
[ ! -f "$MOCK_STATE/worker-bad-$n" ] || echo "BAD token by worker" >> "$ufile"
{ [ "$n" != 01 ] || [ ! -f "$MOCK_STATE/worker-risky" ]; } || echo "RISKY call by worker" >> src/a.txt
{ [ "$n" != 02 ] || [ ! -f "$MOCK_STATE/worker-02-touches-a" ]; } || echo "shared line by unit 02" >> src/a.txt
{ [ "$n" != 02 ] || [ ! -f "$MOCK_STATE/worker-02-touches-rules" ]; } || echo "rule set revised by unit 02" >> tools/rules.txt
{ [ "$n" != 01 ] || [ ! -f "$MOCK_STATE/worker-01-creates-rules" ]; } || echo "rule set created by unit 01" > tools/new-rules.txt
emit "$done_json"
exit 0
EOF
chmod +x "$TMP/bin/mock-cli"
cp "$TMP/bin/mock-cli" "$TMP/bin/claude"; cp "$TMP/bin/mock-cli" "$TMP/bin/codex"

fake_pass() { bash .claude/skills/feature/scripts/consensus-loop.sh "$1" > "$TMP/consensus-$1.log" 2>&1 || { cat "$TMP/consensus-$1.log"; fail "픽스처: $1 합의 PASS 체크포인트 생성 실패"; }; }
fake_pass design; fake_pass impl
run_runner() { : > "$MOCK_LOG"; bash "$RUN" "$@" > "$TMP/run.log" 2>&1; echo $?; }
reason() { jq -r '.reason' .agent-work/run-state.json; }
status() { jq -r '.status' .agent-work/run-state.json; }
calls() { grep -c "^$1" "$MOCK_LOG" || true; }
llm() { grep -cE '^(worker|unit-fix|risk-fix|verify-fix|reviewer|fixer)' "$MOCK_LOG" || true; }   # 워커·리뷰어·수정자 호출 수(검증자는 픽스처 준비 때만 돈다)
seq_all() { paste -sd'|' "$MOCK_LOG"; }
flag() { : > "$MOCK_STATE/$1"; }
umode() { printf '%s' "$1" > "$MOCK_STATE/ucheck-mode"; }
rmode() { printf '%s' "$1" > "$MOCK_STATE/risk-mode"; }
urec() { jq -r "$2" ".agent-work/units/$1/unit-check/last.json"; }
rrec() { jq -r "$1" .agent-work/risk-verify/last.json; }
reset_tree() { # 소스·산출물·mock 플래그·검사 설정을 처음 상태로 (테스트 환경 정리 — 파이프라인 동작 아님). 합의 PASS 체크포인트는 남긴다
  git reset -q; git checkout -q -- src tools
  rm -f "$MOCK_STATE"/*
  rm -rf .agent-work/units .agent-work/implementation-context.json .agent-work/implementation-units.lock.json .agent-work/feature-scope.lock.json .agent-work/worker-baseline.tree \
    .agent-work/worker-baseline.guard.json .agent-work/worker-result.json .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/reviews/impl-attempt-* \
    .agent-work/.session-* .agent-work/worker-session.json .agent-work/usage.jsonl .agent-work/usage-summary.json .agent-work/doc-gap-resume.json .agent-work/fast-check \
    .agent-work/risk-verify .agent-work/state.json .agent-work/notify-done.sent .agent-work/live.log .agent-work/.runner.lock .agent-work/post-run-report.json.tmp
  rm -f .agent-work/reviews/verify-* .agent-work/reviews/verify.history.jsonl .agent-work/reviews/worker-* .agent-work/post-run-report.json .agent-work/post-run-report.error.log*
  : > .agent-work/decisions.md
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
  set_cfg UNIT_CHECK_CMD ""; set_cfg RISK_VERIFY_CMD ""; set_cfg UNIT_CHECK_POLICY_PATHS ""
}
BASE_SEQ="worker:01|test-01|worker:02|test-02|reviewer|full-test|full-lint"

# ===================== Unit 정적 검사 =====================
# ===== U1: 미설정 — 종전 흐름, 생략 명시, 실행·통과로 집계하지 않음 =====
reset_tree
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "U1: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "$BASE_SEQ" ] || fail "U1: 미설정 호출 순서가 종전과 다름: $(seq_all)"
grep -q '\[unit-check\] 생략(.*UNIT_CHECK_CMD 미설정' "$TMP/run.log" || fail "U1: Unit 정적 검사 생략 로그가 없음"
grep -q '\[risk-verify\] 생략(.*RISK_VERIFY_CMD 미설정' "$TMP/run.log" || fail "U1: 위험도별 검증 생략 로그가 없음"
grep -q '\[unit-check\] #[0-9]* 통과\|\[risk-verify\] #[0-9]* 통과' "$TMP/run.log" && fail "U1: 미설정인데 통과로 기록됨"
[ ! -e .agent-work/units/01-a/unit-check ] && [ ! -e .agent-work/risk-verify ] || fail "U1: 미설정인데 검사 실행 기록이 생김"
jq -e '.verification_summary.unit.unit_check.configured==false and .verification_summary.unit.unit_check.runs==0 and (.verification_summary.unit.unit_check.by_unit | all(.final_status=="SKIPPED"))
       and .verification_summary.feature.risk_verify.last==null' .agent-work/post-run-report.json >/dev/null || fail "U1: 보고서가 미설정 검사를 SKIPPED 가 아닌 값으로 기록함"
LLM_BASE="$(llm)"
reset_tree
cp "$CFG" "$TMP/config.keep"
grep -v '^UNIT_CHECK_\|^RISK_VERIFY_\|^FAST_CHECK_' "$TMP/config.keep" > "$CFG"   # UNIT_CHECK_POLICY_PATHS 줄도 없는 config
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "$BASE_SEQ" ] || fail "U1: 설정 줄이 없는 기존 config.sh 에서 종전 흐름이 아님(exit $rc): $(seq_all)"
cp "$TMP/config.keep" "$CFG"
pass "U1: 미설정(빈 값·설정 줄 없는 기존 config) — 종전 흐름 그대로, '생략' 로그, 실행 기록 없음, 보고서는 SKIPPED"

# ===== U2: PASS → targeted test → unit DONE =====
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "U2: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "worker:01|ucheck:01|test-01|worker:02|ucheck:02|test-02|reviewer|full-test|full-lint" ] || fail "U2: 호출 순서 불일치: $(seq_all)"
[ "$(cat "$MOCK_STATE/ucheck-changed-01")" = "src/a.txt" ] && [ "$(cat "$MOCK_STATE/ucheck-changed-02")" = "src/b.txt" ] \
  || fail "U2: UNIT_CHECK_CHANGED_FILES 가 그 unit 이 바꾼 파일만이 아님: 01=[$(paste -sd, "$MOCK_STATE/ucheck-changed-01")] 02=[$(paste -sd, "$MOCK_STATE/ucheck-changed-02")]"
[ "$(cat "$MOCK_STATE/ucheck-cwd")" = "$TMP/repo" ] || fail "U2: 검사가 worktree 루트에서 실행되지 않음"
jq -e '.status=="PASS" and .unit_id=="02-b" and .cmd=="tools/unit-check.sh" and (.cmd_sha256|length)==64 and .tree_before==.tree_after and .index_modified==false' \
  .agent-work/units/02-b/unit-check/last.json >/dev/null || fail "U2: 실행 기록 계약 불일치: $(cat .agent-work/units/02-b/unit-check/last.json)"
[ -f .agent-work/units/01-a/done.json ] && [ -f .agent-work/units/02-b/done.json ] || fail "U2: done.json 이 없음"
[ "$(llm)" -eq "$LLM_BASE" ] || fail "U2: 검사가 통과했는데 LLM 호출 수가 미설정 때($LLM_BASE)와 다름: $(llm)"
jq -e '.failure_analysis==[] and .rule_candidates==[] and .verification_summary.unit.unit_check.pass==2' .agent-work/post-run-report.json >/dev/null \
  || fail "D5: 실패 이력이 없는데 보고서에 RCA·후보가 생김: $(jq -c '{failure_analysis, rule_candidates}' .agent-work/post-run-report.json)"
LLM_UNIT_CLEAN="$(llm)"
pass "U2: PASS → targeted test → unit DONE (unit 별 변경 파일만 전달, LLM 호출 수 불변) / D5: 실패 없으면 RCA·후보 없음"

# ===== U3: VIOLATION → 리뷰어 없이 unit 수정 턴 → 재검사 =====
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; flag worker-bad-01
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "U3: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "worker:01|ucheck:01|test-01|unit-fix:01:diag|ucheck:01|test-01|worker:02|ucheck:02|test-02|reviewer|full-test|full-lint" ] || fail "U3: 호출 순서 불일치: $(seq_all)"
[ "$(calls reviewer)" -eq 1 ] && [ "$(calls fixer)" -eq 0 ] || fail "U3: 위반 처리에 리뷰어·수정자가 쓰임"
diag="$(cat "$MOCK_STATE/unitfix-log-path")"
# 묶음은 원본 전체가 아니라 요약(색인)과 원본 경로를 싣는다 — 원본 로그는 그대로 남는다
u3_raw=".agent-work/units/01-a/unit-check/check-0001.log"
[ "$diag" = ".agent-work/units/01-a/unit-verify-01.diag.log" ] && grep -q 'L1: \[no-bad-token\] src/a.txt:3: 금지 토큰 — BAD token by worker' "$diag" \
  && grep -q "출력 원본: $u3_raw" "$diag" && grep -q "$u3_raw.digest.json" "$diag" && grep -q '^\[no-bad-token\] src/a.txt:3: 금지 토큰 — BAD token by worker$' "$u3_raw" \
  || fail "U3: 수정 턴이 검사 진단(요약 + 원본 경로)을 받지 못했거나 원본 로그가 보존되지 않음: $diag"
jq -e '.kind=="check-digest" and .status=="VIOLATION" and .exit_code==1 and .truncated==false and .matched_count==1 and .raw_log_path==$raw' --arg raw "$u3_raw" "$u3_raw.digest.json" >/dev/null \
  || fail "U3: 진단 요약의 상태·원본 경로·집계가 다름: $(cat "$u3_raw.digest.json" 2>/dev/null)"
grep -q 'targeted test(.*) = PASS' "$diag" || fail "U3: 진단 묶음에 targeted test 결과가 없음"
[ "$(jq -sr '[.[].status] | join(",")' .agent-work/units/01-a/unit-check/history.jsonl)" = "VIOLATION,PASS" ] || fail "U3: 검사 기록이 VIOLATION → PASS 가 아님"
grep -q 'BAD' src/a.txt && fail "U3: 완료된 unit 에 위반이 남아 있음"
jq -e '(.failure_analysis | map(select(.type=="UNIT_CHECK_VIOLATION")) | length)==1 and (.failure_analysis | all(.root_cause=="UNKNOWN" and .confirmed==false)) and .rule_candidates==[]' \
  .agent-work/post-run-report.json >/dev/null || fail "D7: 한 번뿐인 위반에 규칙 후보가 생겼거나 근본 원인을 단정함: $(jq -c '{failure_analysis, rule_candidates}' .agent-work/post-run-report.json)"
LLM_UNIT_VIOLATION="$(llm)"
pass "U3: VIOLATION — 리뷰어 호출 없이 unit 수정 턴 1회 → 재검사 통과 → 다음 unit / D7: 반복 근거 없는 위반은 후보로 승격하지 않음"

# ===== U4: 정적 검사 위반 + targeted test 실패 → 수정 턴 1회 =====
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; flag worker-bad-01; flag fail-test-01
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "U4: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "worker:01|ucheck:01|test-01|unit-fix:01:diag|ucheck:01|test-01|worker:02|ucheck:02|test-02|reviewer|full-test|full-lint" ] || fail "U4: 호출 순서 불일치: $(seq_all)"
[ "$(calls unit-fix)" -eq 1 ] || fail "U4: 두 검증이 함께 실패했는데 수정 턴이 1회가 아님: $(calls unit-fix)"
diag="$(cat "$MOCK_STATE/unitfix-log-path")"
grep -q 'no-bad-token' "$diag" && grep -q 'targeted test(.*) = FAIL' "$diag" && grep -q 'unit 01 test failed' "$diag" || fail "U4: 진단 묶음에 두 실패가 함께 들어 있지 않음"
[ "$(llm)" -eq "$LLM_UNIT_VIOLATION" ] || fail "U4: 두 검증 실패의 LLM 호출 수($(llm))가 검사 위반 하나일 때($LLM_UNIT_VIOLATION)보다 많음"
LLM_UNIT_BOTH="$(llm)"
pass "U4: 정적 검사 위반 + targeted test 실패 — 진단을 묶어 수정 턴 1회(중복 워커 호출 없음)"

# ===== U5: ERROR → 워커·테스트 없이 중단 / 재실행 모델 0회 / 고친 뒤 워커 재호출 없이 검사부터 =====
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; umode error
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_ERROR ] || fail "U5: NEED_USER/UNIT_CHECK_ERROR 기대(exit $rc, $(reason))"
[ "$(seq_all)" = "worker:01|ucheck:01" ] || fail "U5: 실행 오류 뒤에 테스트·수정 턴이 호출됨: $(seq_all)"
[ "$(urec 01-a .kind)" = UNEXPECTED_EXIT ] && [ ! -f .agent-work/units/01-a/done.json ] || fail "U5: 기록 kind 또는 done.json 상태가 다름"
grep -q '\[SKILL REFERENCE\] NEED_USER(UNIT_CHECK_ERROR)' "$TMP/run.log" || fail "U5: 참조 문서 안내 줄이 없음"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_ERROR ] && [ "$(seq_all)" = "ucheck:01" ] || fail "U5: 재실행이 검사 1회·모델 0회가 아님(exit $rc, $(reason)): $(seq_all)"
umode default
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "ucheck:01|test-01|worker:02|ucheck:02|test-02|reviewer|full-test|full-lint" ] || fail "U5: 고친 뒤 재실행이 워커 재호출 없이 검사부터가 아님(exit $rc): $(seq_all)"
pass "U5: ERROR — 워커·테스트 0회로 중단, 재실행도 모델 0회, 검사기를 고친 뒤 워커 재호출 없이 검사부터 재개 → DONE"

# ===== U6: 검사가 코드·index 를 바꿈 → 차단, 변경 보존, 되돌리기 전 재실행은 검사·모델 0회 =====
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; umode mutate
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_ERROR ] && [ "$(urec 01-a .kind)" = WORKTREE_MODIFIED ] || fail "U6: UNIT_CHECK_ERROR/WORKTREE_MODIFIED 기대(exit $rc, $(reason), $(urec 01-a .kind))"
grep -q 'autofixed by unit checker' src/a.txt || fail "U6: 검사가 만든 변경이 자동 원복됨"
[ "$(seq_all)" = "worker:01|ucheck:01" ] && [ ! -f .agent-work/units/01-a/done.json ] || fail "U6: 읽기 전용 위반 뒤 진행됨: $(seq_all)"
umode default
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_ERROR ] && [ -z "$(seq_all)" ] || fail "U6: 변경을 되돌리지 않은 재실행이 검사·모델 0회로 멈추지 않음(exit $rc, $(reason)): $(seq_all)"
# 다른 파일을 더 고쳐 tree 가 '검사 직후'와 달라져도, 검사가 만든 변경(src/a.txt)이 남아 있으면 복구가 아니다
echo "unrelated manual edit" >> src/b.txt
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_ERROR ] && [ -z "$(seq_all)" ] || fail "U6: 다른 파일 수정으로 읽기 전용 위반 차단이 풀림(exit $rc, $(reason)): $(seq_all)"
jq -r '.detail' .agent-work/run-state.json | grep -q 'WORKTREE_MODIFIED.*src/a.txt' || fail "U6: 중단 사유에 해소되지 않은 경로가 없음: $(jq -r '.detail' .agent-work/run-state.json)"
grep -q 'autofixed by unit checker' src/a.txt && grep -q 'unrelated manual edit' src/b.txt || fail "U6: 차단 중 변경이 자동 원복됨"
[ ! -e .agent-work/units/01-a/unit-check/readonly-restored.json ] || fail "U6: 복구되지 않았는데 복구 표식이 생김"
git checkout -q -- src/b.txt   # 사용자가 무관한 수정을 거둠(테스트 환경 정리)
grep -v 'autofixed by unit checker' src/a.txt > "$TMP/a.restore" && cat "$TMP/a.restore" > src/a.txt   # 사용자가 검사 전 tree 로 되돌림
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "ucheck:01|test-01|worker:02|ucheck:02|test-02|reviewer|full-test|full-lint" ] || fail "U6: 되돌린 뒤 재실행이 검사부터가 아님(exit $rc): $(seq_all)"
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; umode index
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_ERROR ] && [ "$(urec 01-a .kind)" = INDEX_MODIFIED ] || fail "U6: INDEX_MODIFIED 기대(exit $rc, $(reason), $(urec 01-a .kind))"
[ "$(calls unit-fix)" -eq 0 ] && [ "$(calls test-01)" -eq 0 ] || fail "U6: index 변경 뒤 수정 턴·테스트가 호출됨"
[ "$(urec 01-a '.index_before|length')" -eq 64 ] && [ "$(urec 01-a .index_before)" != "$(urec 01-a .index_after)" ] || fail "U6: 기록에 검사 전후 index 지문이 없음"
# 검사기를 고쳐도(더는 index 를 안 건드려도) 바뀐 index 가 그대로면 재실행이 통과하지 못한다 — '이번 실행 전후가 같다'는 복구가 아니다
umode default
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_ERROR ] && [ -z "$(seq_all)" ] || fail "U6: index 를 되돌리지 않은 재실행이 검사·모델 0회로 멈추지 않음(exit $rc, $(reason)): $(seq_all)"
jq -r '.detail' .agent-work/run-state.json | grep -q 'INDEX_MODIFIED' || fail "U6: 중단 사유가 INDEX_MODIFIED 가 아님"
[ "$(git diff --cached --name-only)" = "src/a.txt" ] || fail "U6: 검사가 바꾼 index 를 자동 복구함"
[ "$(urec 01-a .kind)" = INDEX_MODIFIED ] || fail "U6: 차단된 재실행이 위반 기록을 덮어씀"
git reset -q   # 사용자가 index 를 검사 전 상태로 되돌림
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "ucheck:01|test-01|worker:02|ucheck:02|test-02|reviewer|full-test|full-lint" ] || fail "U6: index 를 되돌린 뒤 재실행이 검사부터가 아님(exit $rc): $(seq_all)"
pass "U6: 검사가 소스·index 를 바꾸면 읽기 전용 위반으로 중단 — 변경 보존, 되돌리기 전 재실행은 검사·모델 0회(다른 파일 수정·검사기 수정으로는 풀리지 않는다)"

# ===== U7: 수정 턴이 unit scope 밖을 고침 → UNIT_SCOPE_VIOLATION =====
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; flag worker-bad-01; flag unitfix-outside
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_SCOPE_VIOLATION ] || fail "U7: UNIT_SCOPE_VIOLATION 기대(exit $rc, $(reason))"
[ "$(calls worker:02)" -eq 0 ] && [ ! -f .agent-work/units/01-a/done.json ] || fail "U7: unit scope 위반 뒤 다음 unit 으로 진행됨"
grep -q 'leaked into the other unit' src/b.txt || fail "U7: 범위 밖 변경이 자동 원복됨"
pass "U7: 검사 위반 수정 턴도 기존 unit scope 게이트를 지난다 — scope 밖 수정은 UNIT_SCOPE_VIOLATION(보존, 다음 unit 차단)"

# ===== U8: 이전 PASS 재사용 없음 / 한도 소진 뒤 재실행은 모델 0회 =====
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; flag fail-test-01; flag unitfix-adds-bad
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_RETRIES_EXHAUSTED ] || fail "U8: UNIT_CHECK_RETRIES_EXHAUSTED 기대(exit $rc, $(reason))"
[ "$(seq_all)" = "worker:01|ucheck:01|test-01|unit-fix:01:test|ucheck:01|test-01" ] || fail "U8: 호출 순서 불일치: $(seq_all)"
[ "$(jq -sr '[.[].status] | join(",")' .agent-work/units/01-a/unit-check/history.jsonl)" = "PASS,VIOLATION" ] || fail "U8: 수정 뒤 재검사가 앞선 PASS 를 재사용함"
[ ! -f .agent-work/units/01-a/done.json ] || fail "U8: 위반이 남았는데 done.json 이 확정됨"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_RETRIES_EXHAUSTED ] && [ "$(seq_all)" = "ucheck:01|test-01" ] || fail "U8: 한도 소진 뒤 재실행이 모델 0회가 아님(exit $rc, $(reason)): $(seq_all)"
# 재개한 실행은 앞선 실행의 targeted test 로그를 덮어쓰지 않는다 — append-only 기록의 각 행이 그 실행 당시의 로그를 계속 가리킨다
TH=.agent-work/units/01-a/targeted-test.history.jsonl
[ "$(jq -sr '[.[].status] | join(",")' "$TH")" = "FAIL,PASS,PASS" ] || fail "U8: targeted test 기록이 FAIL,PASS,PASS 가 아님: $(jq -sr '[.[].status] | join(",")' "$TH")"
[ "$(jq -sr '[.[].log] | unique | length' "$TH")" -eq 3 ] && [ "$(jq -sr '[.[].n] | join(",")' "$TH")" = "1,2,3" ] || fail "U8: 재개한 실행이 앞선 로그 경로를 다시 씀: $(jq -sc '[.[] | {n, log}]' "$TH")"
for f in $(jq -r '.log' "$TH"); do [ -f "$f" ] || fail "U8: 기록이 가리키는 로그가 없음: $f"; done
grep -q 'unit 01 test failed' "$(jq -sr '.[0].log' "$TH")" || fail "U8: 첫 실패 로그가 재개 뒤 덮어써짐: $(jq -sr '.[0].log' "$TH")"
[ "$(ls .agent-work/units/01-a/unit-check/check-*.log | wc -l | tr -d ' ')" -eq 3 ] || fail "U8: 검사 로그가 실행마다 따로 남지 않음"
pass "U8: 수정 턴 뒤에는 검사를 다시 실행한다(앞선 PASS 재사용 없음) — 한도 소진은 NEED_USER, 재실행도 모델 0회(무한 수정 없음), 재개가 앞선 실행 로그를 덮어쓰지 않는다"

# ===== U9: 뒤 unit 에서 멈춰도 앞 unit 의 완료 체크포인트 유지 =====
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; flag worker-bad-02; flag unitfix-noop
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_RETRIES_EXHAUSTED ] || fail "U9: UNIT_CHECK_RETRIES_EXHAUSTED 기대(exit $rc, $(reason))"
[ -f .agent-work/units/01-a/done.json ] && [ ! -f .agent-work/units/02-b/done.json ] || fail "U9: 체크포인트 상태가 01 완료·02 미완료가 아님"
cp .agent-work/units/01-a/done.json "$TMP/done-01.keep"
rc="$(run_runner)"
[ "$(seq_all)" = "ucheck:02|test-02" ] || fail "U9: 재실행이 앞 unit 의 워커·검사를 다시 부름: $(seq_all)"
cmp -s .agent-work/units/01-a/done.json "$TMP/done-01.keep" || fail "U9: 앞 unit 의 done.json 이 바뀜"
pass "U9: 앞 unit 의 유효한 완료 체크포인트는 그대로 — 재실행이 앞 unit 의 워커·검사를 다시 부르지 않는다"

# ===== U10: 설정 변경으로 검증을 우회할 수 없다 =====
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; umode error-02
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_ERROR ] && [ -f .agent-work/units/01-a/done.json ] || fail "U10: 픽스처 — 01 완료·02 실행 오류 상태가 아님(exit $rc, $(reason))"
umode default; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh --strict"   # 완료 뒤 더 엄격한 명령으로 변경
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_STALE_VIOLATION ] || fail "U10: UNIT_CHECK_STALE_VIOLATION 기대(exit $rc, $(reason))"
[ "$(seq_all)" = "ucheck:01" ] && [ "$(llm)" -eq 0 ] || fail "U10: 완료 unit 재검증이 검사 1회·모델 0회가 아님: $(seq_all)"
[ -f .agent-work/units/01-a/done.json ] || fail "U10: 재검증 위반이 완료 체크포인트를 지움"
set_cfg UNIT_CHECK_CMD "tools/unit-check.sh --v2"   # 통과하는 다른 명령(문자열이 다르면 다른 정책이다)
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "U10: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "ucheck:01|ucheck:02|test-02|reviewer|full-test|full-lint" ] || fail "U10: 명령 변경 뒤 재실행이 '완료 unit 은 검사만, 워커 재호출 없음'이 아님: $(seq_all)"
[ "$(urec 01-a .cmd)" = "tools/unit-check.sh --v2" ] || fail "U10: 완료 unit 의 증거가 현재 명령으로 갱신되지 않음"
# 승인까지 끝난 뒤(verify 에서 멈춘 상태) 검사를 새로 켜도, 완료 unit 의 증거 없이 verify 로 바로 가지 않는다
reset_tree; set_cfg RISK_VERIFY_CMD "tools/risk.sh"; rmode error
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = RISK_VERIFY_ERROR ] && [ -f .agent-work/approved.fingerprint ] || fail "U10: 픽스처 — 승인 뒤 verify 에서 멈춘 상태가 아님(exit $rc, $(reason))"
rmode low; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "U10: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "ucheck:01|ucheck:02|risk|full-test|full-lint" ] || fail "U10: 승인 뒤 새로 켠 검사가 완료 unit 에 적용되지 않았거나 모델을 다시 부름: $(seq_all)"
pass "U10: 설정 변경 — 완료 unit 은 워커 재호출 없이 새 명령으로 검사만 다시(위반이면 UNIT_CHECK_STALE_VIOLATION), 승인 뒤 새로 켠 검사도 증거 없이 통과하지 못함"

# ===== U11: 검사 증거는 검사 대상 코드·정책 입력에 결속된다 =====
UNIT_CLEAN_SEQ="worker:01|ucheck:01|test-01|worker:02|ucheck:02|test-02"
# (a) 최종 테스트 실패의 worker-fix 가 이미 검사한 unit 01 의 코드를 고침 → 리뷰어 전에 01 의 검사만 다시(02 는 그대로)
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; flag fail-full-test
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "U11a: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "$UNIT_CLEAN_SEQ|reviewer|full-test|verify-fix|ucheck:01|reviewer|full-test|full-lint" ] || fail "U11a: worker-fix 뒤 unit 01 재검증이 없거나 순서가 다름: $(seq_all)"
[ "$(urec 01-a .seq)" -eq 2 ] && [ "$(urec 02-b .seq)" -eq 1 ] || fail "U11a: 바뀌지 않은 unit 02 까지 다시 검사했거나 01 을 다시 검사하지 않음"
jq -e '.status=="PASS" and .evidence_version==2 and (.subject_fingerprint|length)==64 and (.policy_fingerprint|length)==64' .agent-work/units/01-a/unit-check/last.json >/dev/null \
  || fail "U11a: 검사 기록에 검사 대상·정책 지문이 없음: $(cat .agent-work/units/01-a/unit-check/last.json)"
[ "$(jq -sr '[.[].subject_fingerprint] | unique | length' .agent-work/units/01-a/unit-check/history.jsonl)" -eq 2 ] || fail "U11a: 두 검사의 검사 대상 지문이 같음(코드 변경이 지문에 없음)"
[ "$(jq -sr '[.[].policy_fingerprint] | unique | length' .agent-work/units/01-a/unit-check/history.jsonl)" -eq 1 ] || fail "U11a: 정책 입력이 그대로인데 정책 지문이 달라짐"
# (b) 그 worker-fix 가 위반을 새로 만들면 과거 PASS 로 넘어가지 않는다 — 리뷰어·TEST_CMD 전에 멈추고, 재실행도 모델 0회
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; flag fail-full-test; flag verifyfix-adds-bad
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_STALE_VIOLATION ] || fail "U11b: UNIT_CHECK_STALE_VIOLATION 기대(exit $rc, $(reason))"
[ "$(seq_all)" = "$UNIT_CLEAN_SEQ|reviewer|full-test|verify-fix|ucheck:01" ] || fail "U11b: 위반 코드가 리뷰어·TEST_CMD 로 넘어감: $(seq_all)"
[ -f .agent-work/units/01-a/done.json ] && [ -f .agent-work/units/02-b/done.json ] || fail "U11b: 재검증 위반이 완료 체크포인트를 지움"
grep -q '^\[no-bad-token\] src/a.txt' "$(urec 01-a .log)" || fail "U11b: 재검증 진단 원본이 없음"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_STALE_VIOLATION ] && [ "$(seq_all)" = "ucheck:01" ] && [ "$(llm)" -eq 0 ] || fail "U11b: 재실행이 검사 1회·모델 0회가 아님(exit $rc, $(reason)): $(seq_all)"
# (c) 사용자가 직접 고친 뒤 재개 — 그 코드도 검사부터 다시 지나고(워커 재호출 없음) 리뷰를 지난다
strip_bad() { grep -v 'BAD' "$1" > "$TMP/strip.user"; cat "$TMP/strip.user" > "$1"; }
strip_bad src/a.txt
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "U11c: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "ucheck:01|reviewer|full-test|full-lint" ] || fail "U11c: 수동 수정 뒤 재개가 '검사 → 리뷰 → 테스트'가 아님: $(seq_all)"
# (d) 완료된 unit 의 코드를 사용자가 고쳐 위반을 만들면 재개가 과거 PASS 로 건너뛰지 않는다(뒤 unit 진행 전, 모델 0회)
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; umode error-02
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_ERROR ] && [ -f .agent-work/units/01-a/done.json ] || fail "U11d: 픽스처 — 01 완료·02 실행 오류 상태가 아님(exit $rc, $(reason))"
umode default; echo "BAD token typed by user" >> src/a.txt
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_STALE_VIOLATION ] && [ "$(seq_all)" = "ucheck:01" ] || fail "U11d: 수동 수정된 완료 unit 이 재검증 없이 넘어감(exit $rc, $(reason)): $(seq_all)"
# (e) 명령 문자열은 같고 검사 스크립트만 바뀜 → 완료 unit 도 새 규칙으로 다시 검사한다(워커 재호출 없음). 독립 unit 변경만 있던 U9 와 달리 정책 입력은 전 unit 에 걸린다
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; umode error-02
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_ERROR ] && [ "$(urec 01-a .status)" = PASS ] || fail "U11e: 픽스처 — 01 완료·02 실행 오류 상태가 아님(exit $rc, $(reason))"
umode default; echo '# rule set revised (same command string)' >> tools/unit-check.sh
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "U11e: DONE 기대(exit $rc, $(status)/$(reason))"
# (미완료 unit 02 는 작업 트리가 직전 결과와 달라졌으므로 기존 재개 규칙대로 워커 턴부터 돈다 — 완료 unit 01 은 워커 없이 검사만)
[ "$(seq_all)" = "ucheck:01|worker:02|ucheck:02|test-02|reviewer|full-test|full-lint" ] && [ "$(calls worker:01)" -eq 0 ] || fail "U11e: 검사 스크립트가 바뀌었는데 완료 unit 을 다시 검사하지 않음(또는 완료 unit 의 워커를 다시 부름): $(seq_all)"
[ "$(jq -sr '[.[].cmd_sha256] | unique | length' .agent-work/units/01-a/unit-check/history.jsonl)" -eq 1 ] \
  && [ "$(jq -sr '[.[].policy_fingerprint] | unique | length' .agent-work/units/01-a/unit-check/history.jsonl)" -eq 2 ] || fail "U11e: 명령은 같고 정책 지문만 달라진 기록이 아님"
git checkout -q -- tools
# (f) 수정자가 이미 검사한 코드를 고침(리뷰 루프 안) → 다음 리뷰어 호출 전에 검사만 다시(리뷰 루프가 러너로 돌려보낸다). 위반이면 두 번째 리뷰어·TEST_CMD 로 가지 않는다
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; flag review-rc
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "U11f: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "$UNIT_CLEAN_SEQ|reviewer|fixer|ucheck:01|reviewer|full-test|full-lint" ] || fail "U11f: 수정자 변경 뒤·다음 리뷰어 전에 unit 01 재검증이 없거나 순서가 다름: $(seq_all)"
[ "$(jq -r '.next_step' .agent-work/review-impl.json)" = APPROVE ] && [ "$(ls -d .agent-work/reviews/impl-attempt-* | wc -l | tr -d ' ')" -eq 1 ] || fail "U11f: 재검증 뒤 같은 attempt 의 리뷰어로 이어지지 않음(새 attempt 가 생김)"
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; flag review-rc; flag fixer-adds-bad
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_STALE_VIOLATION ] || fail "U11f: 수정자가 만든 위반에 UNIT_CHECK_STALE_VIOLATION 기대(exit $rc, $(reason))"
[ "$(seq_all)" = "$UNIT_CLEAN_SEQ|reviewer|fixer|ucheck:01" ] && [ "$(calls reviewer)" -eq 1 ] && [ "$(calls full-test)" -eq 0 ] || fail "U11f: 수정자가 만든 위반에 두 번째 리뷰어를 불렀거나 TEST_CMD 로 넘어감: $(seq_all)"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECK_STALE_VIOLATION ] && [ "$(seq_all)" = "ucheck:01" ] || fail "U11f: 재실행이 검사 1회·모델 0회가 아님(exit $rc, $(reason)): $(seq_all)"
# (g) 뒤 unit 이 앞 unit 과 겹치는 scope 의 파일을 고침 → 리뷰 전에 앞 unit 의 검사를 다시(뒤 unit 은 방금 검사했으므로 그대로)
cp .agent-work/implementation-units.json "$TMP/units.keep"
jq '.units[1].scope.files = ["src/a.txt","src/b.txt"]' "$TMP/units.keep" > .agent-work/implementation-units.json
reset_tree; fake_pass impl
set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; flag worker-02-touches-a
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "U11g: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "$UNIT_CLEAN_SEQ|ucheck:01|reviewer|full-test|full-lint" ] || fail "U11g: 뒤 unit 이 같은 파일을 고쳤는데 앞 unit 을 다시 검사하지 않음: $(seq_all)"
grep -q 'shared line by unit 02' src/a.txt || fail "U11g: 픽스처 — 뒤 unit 이 앞 unit 의 파일을 고치지 않음"
cp "$TMP/units.keep" .agent-work/implementation-units.json
reset_tree; fake_pass impl
pass "U11: 검사 증거는 코드·정책 입력에 결속 — worker-fix·수정자·겹치는 뒤 unit·수동 수정·검사 스크립트 변경 뒤에는 모델 호출 없이 검사만 다시, 위반이면 리뷰어·TEST_CMD 전에 중단"

# ===== U12: 정책 입력이 다른 unit 의 scope 안에 있을 때 =====
# unit 02 의 scope 에 규칙 파일(tools/rules.txt)을 넣는다 — 'scope 밖 전부' 지문은 이 파일을 빼므로, unit 02 가 규칙을 고쳐도 unit 01 의 두 지문은 그대로다.
cp .agent-work/implementation-units.json "$TMP/units.keep"; cp .agent-work/feature-scope.json "$TMP/scope.keep"
jq '.units[1].scope.files = ["src/b.txt","tools/rules.txt"]' "$TMP/units.keep" > .agent-work/implementation-units.json
jq '.files = ["src/a.txt","src/b.txt","tools/rules.txt"]' "$TMP/scope.keep" > .agent-work/feature-scope.json
reset_tree; fake_pass impl
# (a) 선언 없음 + 명령 문자열에도 없음 → 재검사 없음(문서화된 한계: 하네스는 검사기가 그 파일을 읽는지 모른다)
set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; flag worker-02-touches-rules
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "U12a: DONE 기대(exit $rc, $(status)/$(reason))"
grep -q 'rule set revised by unit 02' tools/rules.txt || fail "U12a: 픽스처 — unit 02 가 규칙 파일을 고치지 않음"
[ "$(seq_all)" = "$UNIT_CLEAN_SEQ|reviewer|full-test|full-lint" ] || fail "U12a: 선언하지 않은 다른 unit 소유 파일의 변경이 재검사를 일으킴(범위가 문서와 다름): $(seq_all)"
# (b) UNIT_CHECK_POLICY_PATHS 로 선언 → 그 파일이 바뀌면 완료 unit 01 을 워커 없이 다시 검사한다(리뷰어 전)
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; set_cfg UNIT_CHECK_POLICY_PATHS "tools/rules.txt"; flag worker-02-touches-rules
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "U12b: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "$UNIT_CLEAN_SEQ|ucheck:01|reviewer|full-test|full-lint" ] || fail "U12b: 선언한 정책 파일(다른 unit 의 scope 안)이 바뀌었는데 완료 unit 을 다시 검사하지 않음: $(seq_all)"
[ "$(jq -sr '[.[].policy_fingerprint] | unique | length' .agent-work/units/01-a/unit-check/history.jsonl)" -eq 2 ] \
  && [ "$(jq -sr '[.[].subject_fingerprint] | unique | length' .agent-work/units/01-a/unit-check/history.jsonl)" -eq 1 ] || fail "U12b: 코드는 그대로이고 정책 지문만 달라진 기록이 아님"
# 선언은 재검사를 늘릴 뿐이다 — 규칙 파일이 바뀌지 않으면 독립 unit 의 변경은 여전히 재검사를 일으키지 않는다
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; set_cfg UNIT_CHECK_POLICY_PATHS "tools/rules.txt"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "$UNIT_CLEAN_SEQ|reviewer|full-test|full-lint" ] || fail "U12b: 선언한 파일이 그대로인데 완료 unit 을 다시 검사함(exit $rc): $(seq_all)"
# (c) 선언이 없어도 명령 문자열이 가리키는 파일은 정책 입력이다(어느 unit 의 scope 안에 있어도)
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh tools/rules.txt"; flag worker-02-touches-rules
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "$UNIT_CLEAN_SEQ|ucheck:01|reviewer|full-test|full-lint" ] || fail "U12c: 명령이 가리키는 파일(다른 unit 의 scope 안)이 바뀌었는데 완료 unit 을 다시 검사하지 않음(exit $rc): $(seq_all)"
# (d) 선언한 경로가 작업 트리에 없으면(오타) 빈 지문으로 넘어가지 않는다 — 검사 명령을 실행하지 않고 환경 오류
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; set_cfg UNIT_CHECK_POLICY_PATHS "tools/rulez.txt"
rc="$(run_runner)"
[ "$rc" -eq 1 ] && [ "$(status)" = ENV_ERROR ] && [ ! -s "$MOCK_LOG" ] || fail "U12d: 없는 정책 경로가 워커 호출 전의 ENV_ERROR(모델·검사 0회)가 아님(exit $rc, $(status)): $(seq_all)"
grep -q "UNIT_CHECK_POLICY_PATHS 의 경로 'tools/rulez.txt'" "$TMP/run.log" || fail "U12d: 어느 경로가 틀렸는지 로그에 없음"
[ ! -f .agent-work/units/01-a/done.json ] || fail "U12d: 정책 경로 오류인데 unit 이 완료됨"
set_cfg UNIT_CHECK_POLICY_PATHS "tools/rules.txt"   # 설정을 고치면 같은 명령으로 처음부터 정상 진행한다
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "$UNIT_CLEAN_SEQ|reviewer|full-test|full-lint" ] || fail "U12d: 정책 경로를 고친 뒤의 재실행이 정상 흐름이 아님(exit $rc): $(seq_all)"
# (e) 아직 없는 경로라도 첫 unit 이 만들 파일(그 unit 의 scope 안)이면 사전 검사를 통과한다 — 워커가 만들면 그 unit 의 검사부터 정책 입력에 들어간다
jq '.units[0].scope.files = ["src/a.txt","tools/new-rules.txt"] | .units[1].scope.files = ["src/b.txt","tools/later-rules.txt"]' "$TMP/units.keep" > .agent-work/implementation-units.json
jq '.files = ["src/a.txt","src/b.txt","tools/new-rules.txt","tools/later-rules.txt"]' "$TMP/scope.keep" > .agent-work/feature-scope.json
reset_tree; fake_pass impl
set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; set_cfg UNIT_CHECK_POLICY_PATHS "tools/new-rules.txt"; flag worker-01-creates-rules
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] && [ "$(seq_all)" = "$UNIT_CLEAN_SEQ|reviewer|full-test|full-lint" ] || fail "U12e: 첫 unit 이 만들 정책 파일의 선언이 사전 검사에서 막힘(exit $rc, $(status)/$(reason)): $(seq_all)"
grep -q "UNIT_CHECK_POLICY_PATHS 의 경로 'tools/new-rules.txt' 는 아직 없지만 첫 unit(01-a)의 scope 안" "$TMP/run.log" || fail "U12e: 유예한 경로가 로그에 없음"
# 유예는 통과가 아니다 — 워커가 그 파일을 만들지 않으면 종전대로 그 unit 의 검사에서 멈춘다(실행 시점 규칙 그대로)
git clean -qfd tools; reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; set_cfg UNIT_CHECK_POLICY_PATHS "tools/new-rules.txt"
rc="$(run_runner)"
[ "$rc" -eq 1 ] && [ "$(status)" = ENV_ERROR ] && [ "$(seq_all)" = "worker:01" ] && [ ! -f .agent-work/units/01-a/done.json ] || fail "U12e: 워커가 만들지 않은 정책 파일이 그 unit 의 검사에서 잡히지 않음(exit $rc, $(status)): $(seq_all)"
# (f) 뒤 unit 만 만들 수 있는 경로는 첫 unit 의 검사 시점에 없다 → 워커 호출 전에 멈춘다
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; set_cfg UNIT_CHECK_POLICY_PATHS "tools/later-rules.txt"
rc="$(run_runner)"
[ "$rc" -eq 1 ] && [ "$(status)" = ENV_ERROR ] && [ ! -s "$MOCK_LOG" ] || fail "U12f: 뒤 unit 만 만들 수 있는 정책 경로가 워커 호출 전에 막히지 않음(exit $rc, $(status)): $(seq_all)"
grep -q "UNIT_CHECK_POLICY_PATHS 의 경로 'tools/later-rules.txt'" "$TMP/run.log" || fail "U12f: 어느 경로가 틀렸는지 로그에 없음"
# 검사를 끄면(미설정) 선언은 보지 않는다 — 설정하지 않은 프로젝트의 흐름은 그대로다
reset_tree; set_cfg UNIT_CHECK_POLICY_PATHS "tools/rulez.txt"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "$BASE_SEQ" ] || fail "U12f: UNIT_CHECK_CMD 미설정인데 정책 경로 선언이 흐름을 바꿈(exit $rc): $(seq_all)"
cp "$TMP/units.keep" .agent-work/implementation-units.json; cp "$TMP/scope.keep" .agent-work/feature-scope.json
reset_tree; fake_pass impl
pass "U12: 다른 unit 의 scope 안 정책 파일 — 선언(UNIT_CHECK_POLICY_PATHS)·명령 문자열에 있으면 변경 시 완료 unit 재검사, 없으면 재검사 없음(문서화된 한계), 없는 경로 선언은 워커 호출 전에 ENV_ERROR(첫 unit 이 만들 파일만 유예)"

# ===================== 위험도별 추가 검증 =====================
# ===== R2: LOW → 추가 검사 없음 =====
reset_tree; set_cfg RISK_VERIFY_CMD "tools/risk.sh"; rmode low
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "R2: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "worker:01|test-01|worker:02|test-02|reviewer|risk|full-test|full-lint" ] || fail "R2: 호출 순서 불일치(리뷰 승인 뒤·TEST_CMD 앞이어야 한다): $(seq_all)"
[ "$(calls risk-extra)" -eq 0 ] || fail "R2: LOW 변경에 추가 검사가 실행됨"
[ "$(rrec .status)" = PASS ] && [ "$(rrec .risk_level)" = LOW ] && [ "$(rrec '.checks|length')" -eq 0 ] || fail "R2: 기록 불일치: $(cat .agent-work/risk-verify/last.json)"
[ "$(paste -sd, "$MOCK_STATE/risk-changed")" = "src/a.txt,src/b.txt" ] || fail "R2: RISK_VERIFY_CHANGED_FILES 가 피처 변경 파일 목록이 아님"
[ "$(llm)" -eq "$LLM_BASE" ] || fail "R2: 위험도 검증 통과에 LLM 호출이 늘어남: $(llm) (기준 $LLM_BASE)"
LLM_RISK_LOW="$(llm)"
pass "R2: LOW — 리뷰 승인 뒤·TEST_CMD 앞에서 1회, 추가 검사 없음, LLM 호출 수 불변"

# ===== R3: HIGH → 프로젝트가 정한 추가 검사 실행 =====
reset_tree; set_cfg RISK_VERIFY_CMD "tools/risk.sh"; rmode auto
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "worker:01|test-01|worker:02|test-02|reviewer|risk|risk-extra|full-test|full-lint" ] || fail "R3: 호출 순서 불일치(exit $rc): $(seq_all)"
jq -e '.status=="PASS" and .risk_level=="HIGH" and .checks==[{"name":"authz-bypass","status":"PASS"}] and .result_valid==true' .agent-work/risk-verify/last.json >/dev/null \
  || fail "R3: 위험도·실행한 검증이 기록되지 않음: $(cat .agent-work/risk-verify/last.json)"
[ "$(llm)" -eq "$LLM_BASE" ] || fail "R3: 위험도가 높다는 이유만으로 LLM 호출이 늘어남: $(llm)"
pass "R3: HIGH — 프로젝트 명령이 추가 검사를 실행, 위험도·검증 결과 기록, 추가 LLM 호출 없음"

# ===== R4: 위반이 남으면 TEST_CMD·DONE 차단 / 재실행도 모델 0회 =====
reset_tree; set_cfg RISK_VERIFY_CMD "tools/risk.sh"; rmode auto; flag worker-risky; flag riskfix-noop
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = RISK_VERIFY_RETRIES_EXHAUSTED ] || fail "R4: RISK_VERIFY_RETRIES_EXHAUSTED 기대(exit $rc, $(reason))"
[ "$(seq_all)" = "worker:01|test-01|worker:02|test-02|reviewer|risk|risk-fix|risk" ] || fail "R4: 호출 순서 불일치: $(seq_all)"
[ "$(calls full-test)" -eq 0 ] && [ "$(status)" != DONE ] || fail "R4: 위험도 검증 실패 상태에서 TEST_CMD·DONE 으로 감"
[ "$(rrec .status)" = VIOLATION ] && [ "$(rrec .risk_level)" = HIGH ] || fail "R4: 위반 기록에 위험도가 없음"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = RISK_VERIFY_RETRIES_EXHAUSTED ] && [ "$(seq_all)" = "risk" ] || fail "R4: 재실행이 검증 1회·모델 0회가 아님(exit $rc, $(reason)): $(seq_all)"
pass "R4: 위반이 남으면 TEST_CMD·DONE 차단 — 기존 한도(MAX_TEST_RETRIES) 공유, 재실행은 검증 1회·모델 0회(무한 재시도·추가 에이전트 없음)"

# ===== R5: 위반 → 기존 worker-fix → 리뷰어 재승인 → 재검증 → DONE =====
reset_tree; set_cfg RISK_VERIFY_CMD "tools/risk.sh"; rmode auto; flag worker-risky
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "R5: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "worker:01|test-01|worker:02|test-02|reviewer|risk|risk-fix|reviewer|risk|risk-extra|full-test|full-lint" ] || fail "R5: 수정 → 재승인 → 재검증 순서가 아님: $(seq_all)"
[ "$(calls fixer)" -eq 0 ] || fail "R5: 새 수정 경로(수정자)가 쓰임"
grep -q '^\[authz-bypass\]' .agent-work/risk-verify/check-0001.diag.log || fail "R5: 수정 턴 진단 묶음에 검증 출력 원본이 없음"
[ "$(jq -sr '[.[].status] | join(",")' .agent-work/risk-verify/history.jsonl)" = "VIOLATION,PASS" ] || fail "R5: 검증 기록이 VIOLATION → PASS 가 아님"
[ "$(cat .agent-work/approved.fingerprint)" = "$(cat .agent-work/reviews/impl-attempt-02/approved.fingerprint)" ] || fail "R5: 최종 승인 지문이 수정 뒤 재승인(attempt 02)의 것이 아님"
grep -q 'RISKY' src/a.txt && fail "R5: DONE 인데 위반 코드가 남아 있음"
LLM_RISK_FIX="$(llm)"
pass "R5: 위반 — 기존 worker-fix 1회 → 리뷰어 재승인(승인 없이 수정된 코드가 통과하지 않음) → 재검증 → TEST → DONE"

# ===== R6: 판정 불명확은 LOW 가 아니다 =====
for m in unknown human; do
  reset_tree; set_cfg RISK_VERIFY_CMD "tools/risk.sh"; rmode "$m"
  rc="$(run_runner)"
  [ "$rc" -eq 2 ] && [ "$(reason)" = RISK_VERIFY_NEEDS_USER ] || fail "R6($m): RISK_VERIFY_NEEDS_USER 기대(exit $rc, $(reason))"
  [ "$(calls full-test)" -eq 0 ] && [ "$(calls risk-fix)" -eq 0 ] && [ "$(status)" != DONE ] || fail "R6($m): 사용자 판단 없이 진행되거나 자동 수정이 호출됨: $(seq_all)"
done
[ "$(rrec .kind)" = HUMAN_REVIEW_REQUIRED ] && [ "$(rrec .risk_level)" = CRITICAL ] || fail "R6: needs_human 기록 불일치"
reset_tree; set_cfg RISK_VERIFY_CMD "tools/risk.sh"; rmode noresult
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = RISK_VERIFY_ERROR ] && [ "$(rrec .kind)" = RESULT_INVALID ] || fail "R6: 결과 없는 exit 0 이 RISK_VERIFY_ERROR/RESULT_INVALID 가 아님(exit $rc, $(reason), $(rrec .kind))"
[ "$(rrec .risk_level)" = UNKNOWN ] && [ "$(calls full-test)" -eq 0 ] || fail "R6: 결과가 없는데 위험도를 UNKNOWN 이 아닌 값으로 기록했거나 TEST_CMD 로 감"
pass "R6: 위험도 UNKNOWN·needs_human·결과 없음 — LOW 로 간주하지 않고 사용자에게(자동 수정·TEST_CMD 없음)"

# ===== R7: 실행 오류는 위반과 다르다 =====
reset_tree; set_cfg RISK_VERIFY_CMD "tools/risk.sh"; rmode error
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = RISK_VERIFY_ERROR ] && [ "$(rrec .kind)" = UNEXPECTED_EXIT ] || fail "R7: RISK_VERIFY_ERROR/UNEXPECTED_EXIT 기대(exit $rc, $(reason))"
[ "$(calls risk-fix)" -eq 0 ] && [ "$(calls full-test)" -eq 0 ] || fail "R7: 실행 오류에 워커 수정·TEST_CMD 가 호출됨"
jq -e '.test_retries==0' .agent-work/run-state.json >/dev/null || fail "R7: 실행 오류가 수정 한도를 소모함"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(seq_all)" = "risk" ] || fail "R7: 재실행이 검증 1회·모델 0회가 아님: $(seq_all)"
pass "R7: 실행 오류 — 코드 위반으로 처리하지 않는다(워커 0회, 한도 미소모), 재실행도 모델 0회"

# ===== R8: 검증이 소스·index 를 바꾸면 차단 =====
reset_tree; set_cfg RISK_VERIFY_CMD "tools/risk.sh"; rmode mutate
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = RISK_VERIFY_ERROR ] && [ "$(rrec .kind)" = WORKTREE_MODIFIED ] || fail "R8: WORKTREE_MODIFIED 기대(exit $rc, $(reason), $(rrec .kind))"
grep -q 'written by risk tool' src/a.txt && [ "$(calls full-test)" -eq 0 ] || fail "R8: 변경이 원복됐거나 TEST_CMD 로 감"
rmode low
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "reviewer|risk|full-test|full-lint" ] || fail "R8: 검증이 바꾼 코드가 재리뷰 없이 통과함(exit $rc): $(seq_all)"
reset_tree; set_cfg RISK_VERIFY_CMD "tools/risk.sh"; rmode index
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = RISK_VERIFY_ERROR ] && [ "$(rrec .kind)" = INDEX_MODIFIED ] || fail "R8: INDEX_MODIFIED 기대(exit $rc, $(reason), $(rrec .kind))"
# 검증 명령을 고쳐도 바뀐 index 가 그대로면 재실행이 통과하지 못한다(검증 명령·리뷰어·TEST_CMD 0회)
rmode low
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = RISK_VERIFY_ERROR ] && [ -z "$(seq_all)" ] || fail "R8: index 를 되돌리지 않은 재실행이 검증·모델 0회로 멈추지 않음(exit $rc, $(reason)): $(seq_all)"
[ "$(git diff --cached --name-only)" = "src/a.txt" ] && [ "$(rrec .kind)" = INDEX_MODIFIED ] && [ "$(status)" != DONE ] || fail "R8: index 를 자동 복구했거나 위반 기록을 덮어씀"
git reset -q   # 사용자가 index 를 검증 전 상태로 되돌림
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] && [ "$(seq_all)" = "risk|full-test|full-lint" ] || fail "R8: index 를 되돌린 뒤 재실행이 검증부터가 아님(exit $rc, $(reason)): $(seq_all)"
[ "$(jq -sr '[.[].status] | join(",")' .agent-work/risk-verify/history.jsonl)" = "ERROR,PASS" ] || fail "R8: 차단된 재실행이 검증 기록을 남김"
pass "R8: 검증이 소스·index 를 바꾸면 읽기 전용 위반으로 차단 — 남은 코드 변경은 재리뷰를 지나야 하고, index 는 되돌리기 전 재실행이 통과하지 못한다"

# ===== R9: 코드가 바뀌어 재승인되면 검증도 다시 =====
reset_tree; set_cfg RISK_VERIFY_CMD "tools/risk.sh"; rmode low; flag fail-full-test
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "worker:01|test-01|worker:02|test-02|reviewer|risk|full-test|verify-fix|reviewer|risk|full-test|full-lint" ] || fail "R9: 수정 뒤 재검증이 없음(exit $rc): $(seq_all)"
[ "$(jq -sr '[.[].tree_before] | unique | length' .agent-work/risk-verify/history.jsonl)" -eq 2 ] || fail "R9: 두 검증이 서로 다른 코드에 대한 것이 아님"
pass "R9: 승인 뒤 코드가 바뀌면 이전 검증 PASS 를 재사용하지 않는다 — 재승인 뒤 검증부터 다시"

# ===== R10: 종료 코드와 개별 검증 결과의 모순·형식 오류는 통과가 아니다 =====
reset_tree; set_cfg RISK_VERIFY_CMD "tools/risk.sh"; rmode fail-exit0
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = RISK_VERIFY_ERROR ] && [ "$(rrec .kind)" = RESULT_INCONSISTENT ] || fail "R10: checks FAIL + exit 0 이 RISK_VERIFY_ERROR/RESULT_INCONSISTENT 가 아님(exit $rc, $(status)/$(reason), $(rrec .kind))"
[ "$(calls full-test)" -eq 0 ] && [ "$(calls risk-fix)" -eq 0 ] && [ "$(status)" != DONE ] || fail "R10: 실패한 검증이 있는 결과가 통과했거나 코드 위반(워커 수정)으로 처리됨: $(seq_all)"
jq -e '.status=="ERROR" and .exit_code==0 and .risk_level=="HIGH" and .result_valid==true and .checks==[{"name":"authz-bypass","status":"FAIL"}]' .agent-work/risk-verify/last.json >/dev/null \
  || fail "R10: 모순된 결과의 기록 불일치: $(cat .agent-work/risk-verify/last.json)"
jq -e '.test_retries==0' .agent-work/run-state.json >/dev/null || fail "R10: 결과 계약 오류가 수정 한도를 소모함"
jq -r '.detail' .agent-work/run-state.json | grep -q 'authz-bypass' || fail "R10: 중단 사유에 실패한 검증 이름이 없음"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = RISK_VERIFY_ERROR ] && [ "$(seq_all)" = "risk" ] || fail "R10: 재실행이 검증 1회·모델 0회가 아님(exit $rc): $(seq_all)"
for m in bad-status bad-check bad-reason; do
  reset_tree; set_cfg RISK_VERIFY_CMD "tools/risk.sh"; rmode "$m"
  rc="$(run_runner)"
  [ "$rc" -eq 2 ] && [ "$(reason)" = RISK_VERIFY_ERROR ] && [ "$(rrec .kind)" = RESULT_INVALID ] || fail "R10($m): 형식이 틀린 결과가 RESULT_INVALID 가 아님(exit $rc, $(status)/$(reason), $(rrec .kind))"
  [ "$(rrec .risk_level)" = UNKNOWN ] && [ "$(calls full-test)" -eq 0 ] && [ "$(calls risk-fix)" -eq 0 ] || fail "R10($m): 형식이 틀린 결과의 위험도를 받아들였거나 진행함"
done
pass "R10: checks 에 FAIL 이 있는데 exit 0 → RESULT_INCONSISTENT(통과·코드 위반 아님, 워커 0회, 한도 미소모) / checks·reasons 형식 오류 → RESULT_INVALID"

# ===== R11: 같은 초에 verify 가 두 번 돌아도 로그 경로가 겹치지 않는다 =====
# 초 단위 타임스탬프가 항상 같은 값이 되게 date 를 감싼다(그 형식만 고정, 나머지는 실제 date).
mkdir -p "$TMP/datebin"
printf '%s\n' '#!/usr/bin/env bash' 'for a in "$@"; do [ "$a" != "+%Y%m%d-%H%M%S" ] || { echo 20260101-000000; exit 0; }; done' 'exec /bin/date "$@"' > "$TMP/datebin/date"
chmod +x "$TMP/datebin/date"
reset_tree; flag fail-full-test
: > "$MOCK_LOG"; PATH="$TMP/datebin:$PATH" bash "$RUN" > "$TMP/run.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "R11: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "worker:01|test-01|worker:02|test-02|reviewer|full-test|verify-fix|reviewer|full-test|full-lint" ] || fail "R11: 호출 순서 불일치: $(seq_all)"
VH=.agent-work/reviews/verify.history.jsonl
[ "$(jq -sr '[.[].status] | join(",")' "$VH")" = "FAIL,PASS" ] && [ "$(jq -sr '[.[].log] | unique | length' "$VH")" -eq 2 ] || fail "R11: 두 verify 실행의 로그 경로가 같음: $(jq -sc '[.[] | {status, log}]' "$VH")"
[ "$(jq -sr '.[0].log' "$VH")" = ".agent-work/reviews/verify-20260101-000000.log" ] && [ "$(jq -sr '.[1].log' "$VH")" = ".agent-work/reviews/verify-20260101-000000-2.log" ] \
  || fail "R11: 로그 이름이 기대와 다름: $(jq -sc '[.[].log]' "$VH")"
grep -q 'full test failed' "$(jq -sr '.[0].log' "$VH")" || fail "R11: 실패한 첫 실행의 로그가 두 번째 실행에 덮어써짐"
grep -q 'full test failed' "$(jq -sr '.[1].log' "$VH")" && fail "R11: 두 번째 실행의 로그에 첫 실행의 출력이 섞임"
pass "R11: 같은 초의 verify 재실행 — 로그 경로가 실행마다 고유(-2 …), 기록이 가리키는 앞선 실패 로그 보존"

# ===================== DONE 뒤 사후 분석 =====================
# 실패 이력이 있는 실행: unit 01·02 가 같은 규칙을 위반(서로 다른 검사 실행 2회) + 위험도 검증 위반 1회 + usage 미관측 행 1건
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; set_cfg RISK_VERIFY_CMD "tools/risk.sh"; rmode auto
flag worker-bad-01; flag worker-bad-02; flag worker-risky
: > "$MOCK_LOG"
NTFY_TOPIC=smoke-topic NTFY_CURL_BIN="$TMP/bin/curl-mock" bash "$RUN" > "$TMP/run.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "D: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(calls ntfy)" -eq 1 ] || fail "D12: 완료 알림이 1회가 아님: $(calls ntfy)"
REPORT=.agent-work/post-run-report.json
[ -f "$REPORT" ] || fail "D1: DONE 뒤 보고서가 없음"
jq -e --arg fp "$(cat .agent-work/approved.fingerprint)" '.version==1 and .status=="DONE" and .source_fingerprint==$fp and (.generated_at|type)=="string"
  and (.cost_summary|type)=="object" and (.verification_summary|type)=="object" and (.failure_analysis|type)=="array" and (.rule_candidates|type)=="array"' "$REPORT" >/dev/null \
  || fail "D1: 보고서 구조 불일치: $(jq -c 'keys' "$REPORT")"
grep -q '사후 분석 보고서: .agent-work/post-run-report.json' "$TMP/run.log" || fail "D1: 로그에 보고서 경로가 없음"
# D2/D3: 기존 usage 집계(usage-summary.json = usage_summary)와 같은 숫자, reported / estimated 분리
jq -e --slurpfile s .agent-work/usage-summary.json '.cost_summary.observed as $o | $s[0] as $u
  | $o.invocations==$u.invocations and $o.reported_cost_usd==$u.reported_cost_usd and $o.estimated_cost_usd==$u.estimated_cost_usd
    and $o.combined_cost_usd_estimate==$u.combined_cost_usd_estimate and $o.cost_unknown_invocations==$u.cost_unknown_invocations
    and .cost_summary.by_role.WORKER.reported_cost_usd==$u.by_role.WORKER.reported_cost_usd and .cost_summary.by_role.REVIEWER.estimated_cost_usd==$u.by_role.REVIEWER.estimated_cost_usd' "$REPORT" >/dev/null \
  || fail "D2: 보고서 비용이 usage-summary.json 과 다름: $(jq -c '.cost_summary.observed' "$REPORT") vs $(jq -c '{invocations, reported_cost_usd, estimated_cost_usd}' .agent-work/usage-summary.json)"
jq -e '.cost_summary.observed.reported_cost_usd > 0 and .cost_summary.observed.estimated_cost_usd > 0 and .cost_summary.by_role.REVIEWER.reported_cost_usd == 0
  and .cost_summary.by_role.WORKER.estimated_cost_usd == 0 and (.cost_summary.cost_note | test("추정"))' "$REPORT" >/dev/null || fail "D3: 보고 비용과 추정 비용이 구분되지 않음: $(jq -c '.cost_summary.by_role' "$REPORT")"
jq -e '.cost_summary.worker_fix_turns.unit_fix.invocations==2 and .cost_summary.worker_fix_turns.verify_fix.invocations==1 and .cost_summary.worker_fix_turns.total.invocations==3
  and .cost_summary.reviewer.invocations==2 and .cost_summary.reviewer.re_invocations==1 and .cost_summary.counterfactual_savings.usd==null and .cost_summary.counterfactual_savings.status=="unknown"
  and .cost_summary.counterfactual_savings.blocked_before_llm_review.unit_check_violations==2 and .cost_summary.model_invocations_total==(.cost_summary.observed.invocations)' "$REPORT" >/dev/null \
  || fail "D: 수정 턴·리뷰어 재호출 집계 또는 반사실적 절감(unknown) 표기가 다름: $(jq -c '.cost_summary | {worker_fix_turns, reviewer, counterfactual_savings}' "$REPORT")"
# unit 검사 5회 = unit 마다 위반 1 + 통과 1, 그리고 위험도 검증의 worker-fix 가 unit 01 의 코드(src/a.txt)를 고친 뒤 리뷰 전에 돈 01 재검증 1회(U11)
case "$(seq_all)" in *"|reviewer|risk|risk-fix|ucheck:01|reviewer|risk|risk-extra|full-test|"*) ;; *) false;; esac \
  || fail "D: 위험도 수정 턴 뒤·재리뷰 전에 unit 01 재검증이 없음: $(seq_all)"
jq -e '.verification_summary.unit.unit_check | .configured and .runs==5 and .violation==2 and .pass==3 and .corrupt_records==0' "$REPORT" >/dev/null || fail "D: unit 검사 집계 불일치: $(jq -c '.verification_summary.unit.unit_check' "$REPORT")"
jq -e '.record_integrity.complete==true and .record_integrity.corrupt==[]' "$REPORT" >/dev/null || fail "D13: 온전한 기록인데 record_integrity 가 complete 가 아님: $(jq -c '.record_integrity' "$REPORT")"
jq -e '.verification_summary.unit.targeted_test | .observed and .runs==4 and .failures==0' "$REPORT" >/dev/null || fail "D: targeted test 집계 불일치: $(jq -c '.verification_summary.unit.targeted_test' "$REPORT")"
jq -e '.verification_summary.feature | .risk_verify.runs==2 and .risk_verify.violation==1 and .risk_verify.last.risk_level=="HIGH" and .final_verify.observed and .final_verify.runs==1 and .final_verify.failures==0
  and .review.reviewer_outputs==2 and .fast_check.configured==false' "$REPORT" >/dev/null || fail "D: feature 단계 검증 집계 불일치: $(jq -c '.verification_summary.feature' "$REPORT")"
# D6: 반복 오류 후보에는 실제 근거가 붙고 자동 승격은 없다
jq -e '(.rule_candidates | length)==1 and (.rule_candidates[0] | .recommended_type=="CODEBASE_CONSTRAINT" and .auto_promote==false and (.observed_error | test("no-bad-token"))
  and .repetition_evidence.occurrences==2 and (.related | length)==2 and (.cross_feature_repetition | test("unverified")) and (.automatable|type)=="string" and (.false_positive_risk|type)=="string")' "$REPORT" >/dev/null \
  || fail "D6: 반복 오류 후보·근거가 기대와 다름: $(jq -c '.rule_candidates' "$REPORT")"
for f in $(jq -r '.rule_candidates[0].related[]' "$REPORT"); do grep -q 'no-bad-token' "$f" || fail "D6: 후보의 근거 로그에 그 규칙이 없음: $f"; done
jq -e '[.failure_analysis[].type] | index("UNIT_CHECK_VIOLATION") != null and index("RISK_VERIFY_VIOLATION") != null and index("UNIT_TEST_FAILURE") == null' "$REPORT" >/dev/null \
  || fail "D: failure_analysis 가 관측된 실패만 담지 않음: $(jq -c '[.failure_analysis[].type]' "$REPORT")"
pass "D1·D2·D3·D6: DONE 뒤 보고서 생성 — 비용은 usage 집계와 일치(reported/estimated 분리, 절감액 unknown), 반복 오류 후보에 근거 로그·자동 승격 false"

# D10/D11/D12: DONE 재실행 = 모델·검증 명령·알림 0회, 프로덕션 파일·승인 지문·기록 불변
cp "$REPORT" "$TMP/report.keep"
before_state="$(git status --porcelain; cat .agent-work/approved.fingerprint; cat .agent-work/usage.jsonl .agent-work/risk-verify/history.jsonl .agent-work/units/*/unit-check/history.jsonl | shasum)"
: > "$MOCK_LOG"
NTFY_TOPIC=smoke-topic NTFY_CURL_BIN="$TMP/bin/curl-mock" bash "$RUN" > "$TMP/run.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$MOCK_LOG" ] || fail "D11/D12: DONE 재실행이 모델·검증 명령·알림을 다시 부름(exit $rc): $(seq_all)"
cmp -s "$REPORT" "$TMP/report.keep" || fail "D8: 보고서가 있는 DONE 재실행이 보고서를 다시 씀"
# D8: 보고서가 없을 때만 모델 호출 없이 다시 만들고, 같은 입력이면 같은 내용이다(중복 집계 없음)
mv "$REPORT" "$TMP/report.moved"
: > "$MOCK_LOG"
NTFY_TOPIC=smoke-topic NTFY_CURL_BIN="$TMP/bin/curl-mock" bash "$RUN" > "$TMP/run.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$MOCK_LOG" ] && [ -f "$REPORT" ] || fail "D8: 누락된 보고서를 모델 호출 없이 다시 만들지 못함(exit $rc): $(seq_all)"
cmp -s "$REPORT" "$TMP/report.keep" || fail "D8: 다시 만든 보고서가 처음과 다름(중복 집계·비결정): $(diff <(jq -S . "$TMP/report.keep") <(jq -S . "$REPORT") | head -5)"
after_state="$(git status --porcelain; cat .agent-work/approved.fingerprint; cat .agent-work/usage.jsonl .agent-work/risk-verify/history.jsonl .agent-work/units/*/unit-check/history.jsonl | shasum)"
[ "$before_state" = "$after_state" ] && [ "$(status)" = DONE ] || fail "D10: 보고서 생성이 프로덕션 파일·승인 지문·기존 기록을 바꿈"
pass "D8·D10·D11·D12: DONE 재실행은 모델·검증 명령·알림 0회 — 누락된 보고서만 같은 내용으로 재생성, 코드·승인 지문·기록 불변"

# D4: 미관측 비용은 0 이 아니다
reset_tree; flag claude-no-usage
rc="$(run_runner)"
[ "$rc" -eq 0 ] || fail "D4: DONE 기대(exit $rc, $(reason))"
jq -e --slurpfile s .agent-work/usage-summary.json '.cost_summary.observed.cost_unknown_invocations > 0 and .cost_summary.observed.cost_unknown_invocations==$s[0].cost_unknown_invocations
  and .cost_summary.by_role.WORKER.cost_unknown_invocations==2 and .cost_summary.by_role.WORKER.reported_cost_usd==0' "$REPORT" >/dev/null \
  || fail "D4: 미관측 비용 호출 수가 보고서에 없음: $(jq -c '.cost_summary | {observed, worker:.by_role.WORKER}' "$REPORT")"
pass "D4: 비용을 관측하지 못한 호출은 cost_unknown_invocations 로 센다(0 달러로 합산하지 않음)"

# D9: 분석 실패는 DONE 을 바꾸지 않는다
reset_tree
mkdir .agent-work/post-run-report.json.tmp   # 보고서 임시 파일을 쓸 수 없게 한다
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "D9: 분석 실패가 DONE·exit 0 을 바꿈(exit $rc, $(status))"
[ ! -f "$REPORT" ] && grep -q '\[WARN\] 사후 분석 보고서 생성 실패' "$TMP/run.log" && [ -s .agent-work/post-run-report.error.log ] || fail "D9: 실패 경고·진단이 남지 않음"
grep -q '^\[.*DONE$' "$TMP/run.log" || fail "D9: DONE 로그가 없음"
rmdir .agent-work/post-run-report.json.tmp
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ -f "$REPORT" ] && [ ! -s "$MOCK_LOG" ] || fail "D9: 원인 해소 뒤 재실행이 모델 호출 없이 보고서를 만들지 못함(exit $rc): $(seq_all)"
pass "D9: 분석 실패는 경고·진단만 남기고 DONE(exit 0) 유지 — 원인 해소 뒤 재실행이 모델 호출 없이 보고서를 만든다"

# D13: 손상된 실행 기록은 조용히 빠지지 않는다 — 읽힌 줄만 센 집계라는 사실이 보고서에 남는다
reset_tree; set_cfg UNIT_CHECK_CMD "tools/unit-check.sh"; flag fail-test-01
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "D13: DONE 기대(exit $rc, $(status)/$(reason))"
jq -e '.record_integrity.complete==true and .verification_summary.unit.targeted_test.runs==3 and .verification_summary.unit.targeted_test.failures==1' "$REPORT" >/dev/null \
  || fail "D13: 픽스처 — 온전한 기록의 집계가 다름: $(jq -c '{record_integrity, t:.verification_summary.unit.targeted_test}' "$REPORT")"
TH=.agent-work/units/01-a/targeted-test.history.jsonl
{ printf '{"unit_id":"01-a","n":1,"status":"FA\n'; sed -n '2,$p' "$TH"; } > "$TMP/th.corrupt" && cat "$TMP/th.corrupt" > "$TH"   # 실패 행이 잘린 기록(디스크 오류·중단된 쓰기 흉내)
printf 'not json at all\n' >> .agent-work/units/02-b/unit-check/history.jsonl
mv "$REPORT" "$TMP/report.intact"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ -f "$REPORT" ] && [ ! -s "$MOCK_LOG" ] || fail "D13: 보고서를 모델 호출 없이 다시 만들지 못함(exit $rc): $(seq_all)"
jq -e --arg th "$TH" '.record_integrity.complete==false and (.record_integrity.corrupt | length)==2
  and (.record_integrity.corrupt | map(select(.source=="targeted_test" and (.file | endswith($th)) and .corrupt_lines==1)) | length)==1
  and (.record_integrity.corrupt | map(select(.source=="unit_check" and .corrupt_lines==1)) | length)==1
  and .verification_summary.unit.targeted_test.corrupt_records==1 and .verification_summary.unit.targeted_test.runs==2 and .verification_summary.unit.targeted_test.failures==0
  and .verification_summary.unit.unit_check.corrupt_records==1 and .verification_summary.feature.final_verify.corrupt_records==0' "$REPORT" >/dev/null \
  || fail "D13: 손상된 기록이 보고서에 드러나지 않음: $(jq -c '{record_integrity, t:.verification_summary.unit.targeted_test, u:.verification_summary.unit.unit_check.corrupt_records}' "$REPORT")"
grep -q '읽을 수 없는 실행 기록 2줄' "$TMP/run.log" || fail "D13: 로그에 손상 기록 경고가 없음"
# 기록이 통째로 읽히지 않으면 '미관측'이 아니라 '손상'이다
printf 'garbage\n' > .agent-work/reviews/verify.history.jsonl
mv "$REPORT" "$TMP/report.partial"
rc="$(run_runner)"
jq -e '.verification_summary.feature.final_verify | .observed==false and .corrupt_records==1 and (.note | test("손상"))' "$REPORT" >/dev/null \
  || fail "D13: 전부 손상된 기록이 미관측으로 보고됨: $(jq -c '.verification_summary.feature.final_verify' "$REPORT")"
pass "D13: 손상된 JSONL 기록 — record_integrity.complete=false, 파일·줄 수와 항목별 corrupt_records 로 구분(미관측과 다름), 읽힌 줄만 센 집계임을 명시"

# D14: usage.jsonl 이 손상돼도 보고서는 생성된다 — 읽힌 줄만의 하한값임을 밝히고 빠진 줄을 0 달러로 세지 않는다
reset_tree
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "D14: DONE 기대(exit $rc, $(status)/$(reason))"
jq -e '.cost_summary.unreadable_usage_records==0 and .cost_summary.totals_are_lower_bound==false and .cost_summary.corrupt_records==0' "$REPORT" >/dev/null \
  || fail "D14: 온전한 usage 기록인데 하한값으로 표시됨: $(jq -c '.cost_summary | {unreadable_usage_records, totals_are_lower_bound}' "$REPORT")"
cp "$REPORT" "$TMP/report.usage-intact"
printf '{"role":"WORKER","label":"worker-xx","cost_usd":0.\n' >> .agent-work/usage.jsonl   # 잘린 행(중단된 쓰기 흉내) — 이 호출의 비용은 읽을 수 없다
mv "$REPORT" "$TMP/report.before-usage-corrupt"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ -f "$REPORT" ] && [ ! -s "$MOCK_LOG" ] || fail "D14: 손상된 usage.jsonl 에서 보고서가 생성되지 않음(exit $rc): $(tail -3 .agent-work/post-run-report.error.log 2>/dev/null)"
jq -e --slurpfile a "$TMP/report.usage-intact" '.record_integrity.complete==false
  and (.record_integrity.corrupt | map(select(.source=="usage" and .corrupt_lines==1)) | length)==1
  and .cost_summary.unreadable_usage_records==1 and .cost_summary.totals_are_lower_bound==true and .cost_summary.corrupt_records==1
  and .cost_summary.observed==$a[0].cost_summary.observed and .cost_summary.model_invocations_total==$a[0].cost_summary.model_invocations_total
  and (.cost_summary.cost_note | test("하한값"))' "$REPORT" >/dev/null \
  || fail "D14: 손상된 usage 줄이 보고서에 드러나지 않거나 합계가 달라짐: $(jq -c '{ri:.record_integrity, c:(.cost_summary | {observed, unreadable_usage_records, totals_are_lower_bound, cost_note})}' "$REPORT")"
[ ! -e "$REPORT.usage.tmp" ] || fail "D14: 임시 사본이 남음"
# 전부 읽을 수 없으면 비용은 0 이 아니라 미관측이다
printf 'garbage one\ngarbage two\n' > .agent-work/usage.jsonl
mv "$REPORT" "$TMP/report.usage-partial"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ -f "$REPORT" ] || fail "D14: 전부 손상된 usage.jsonl 에서 보고서가 생성되지 않음(exit $rc)"
jq -e '.cost_summary.observed==null and .cost_summary.unreadable_usage_records==2 and .cost_summary.totals_are_lower_bound==true and (.cost_summary.cost_note | test("읽을 수 있는 줄이 없음"))' "$REPORT" >/dev/null \
  || fail "D14: 전부 손상된 usage 가 0 달러·기록 없음으로 보고됨: $(jq -c '.cost_summary | {observed, unreadable_usage_records, cost_note}' "$REPORT")"
pass "D14: 손상된 usage.jsonl — 보고서 생성, 읽힌 줄만의 하한값 표시(unreadable_usage_records·totals_are_lower_bound), 전부 손상이면 비용 미관측(0 달러 아님)"

# ===== LLM 호출 수 비교(mock 실측 — 워커·리뷰어·수정자 호출) =====
echo "[SMOKE INFO] LLM 호출 수(2 unit 피처, mock 실측): 미설정 기준 $LLM_BASE / Unit 검사 통과 $LLM_UNIT_CLEAN / Unit 검사 위반 1건 $LLM_UNIT_VIOLATION / 검사 위반+테스트 실패 동시 $LLM_UNIT_BOTH (수정 턴 1회) / 위험도 LOW 통과 $LLM_RISK_LOW / 위험도 검증 위반 수정 $LLM_RISK_FIX (worker-fix 1 + 재승인 리뷰 1)"
echo "[SMOKE DONE] tests/smoke-verification-gates.sh — 임시 디렉터리: $TMP"
