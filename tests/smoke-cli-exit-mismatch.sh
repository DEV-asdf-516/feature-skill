#!/usr/bin/env bash
# =============================================================
# 스모크: CLI 종료코드 ≠ 의미적 완료 — 편집 역할이 변경을 만든 뒤 non-zero 로 끝나도 같은 편집을 자동 반복하지 않는다
# 파일 경로: tests/smoke-cli-exit-mismatch.sh   (실제 LLM 호출 없음 — fake codex / fake claude, 임시 저장소)
# 사용법: bash tests/smoke-cli-exit-mismatch.sh
#
# 불변식: raw exit code 는 usage.jsonl 에 관측값 그대로(exit_code/success 위조 없음). 재실행 여부는 raw rc 하나가 아니라
#   이번 invocation 의 결과 JSON + 호출 전후 변경 + 기존 index/manifest/baseline/write-set 게이트 + 다음 독립 게이트가 정한다.
# 사례:
#   A. worker: 유효한 결과 JSON + 변경 + exit 1(그리고 7) → 워커 1회, CLI_EXIT_STATUS_MISMATCH WARN, 재호출 없음, targeted test → done.json → DONE,
#      usage.jsonl 의 워커 행은 exit_code=1/success=false 그대로, cli-anomalies.jsonl 에 STRUCTURED_RESULT
#   B. worker: 결과 없음/깨짐 + 변경 + non-zero → WORKER_OUTCOME_UNCERTAIN, 변경 보존(원복 없음), 같은 명령 재실행 시 워커 0회,
#      사용자가 호출 전 tree 로 복구한 뒤에만 워커 재호출
#   C. worker: 결과 없음 + non-zero + 변경 없음 → 기존 실행 실패(ENV_ERROR), 재실행 시 워커 재호출 허용
#   D. designer: 문서 수정 + exit non-zero → 디자이너 1회, 재호출 없음, 다음 체크포인트 VALIDATOR_PENDING, 검증자가 실제 판정 / 변경 없음 → 기존 실패(DESIGNER_PENDING 유지)
#   E. fixer: 코드 수정 + exit non-zero → 수정자 1회, 재호출 없음, 다음 체크포인트 REVIEWER_PENDING, 리뷰어가 실제 판정 / 변경 없음 → 기존 실패(FIXER_PENDING 유지)
#   F. 기존 안전 게이트 우선: non-zero + 유효 결과와 동시에 index 변경 / scope 위반 / 기준선 변조 / manifest 변경 → CLI mismatch 복구보다 먼저 보고, anomaly 기록 없음
#   G. read-only(검증자 codex): exit 1 이어도 이번 호출의 -o 결과가 있으면 사용 / 결과 없으면 실패(이전 $out 이 있어도 결과로 오인하지 않음) /
#      같은 JSON 을 두 번 연속 써도 두 번째도 새 결과 / 문법상 JSON 이지만 계약 위반이면 caller 검사에서 실패
#   H. designer: 합의 문서 밖 source 파일 변경(rc 0 / rc non-zero 모두) → DESIGNER_SCOPE_VIOLATION, 원복 없음, 검증자로 넘기지 않음,
#      재실행은 모델 0회로 재중단, 호출 전 tree 복구 후에만 재개
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-exit-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks" "$TMP/side"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"echo full-test >> $TMP/calls.log\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"echo full-lint >> $TMP/calls.log\"|" "$CFG" && rm -f "$CFG.bak"
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src/gen && echo "base 01" > src/u01.txt && echo "outside base" > src/outside.txt && echo "existing" > src/gen/existing.txt   # existing.txt: new_file_roots 아래 기준선 파일(사례 F baseline)
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/u01.txt"],"new_file_roots":["src/gen/"]}\n' > .agent-work/feature-scope.json
cat > .agent-work/implementation-units.json <<EOF
{"version":1,"units":[
 {"id":"01-intake","title":"접수","goal":"unit 01","requirements":["REQ-01"],"scope":{"files":["src/u01.txt"],"new_file_roots":["src/gen/"]},"references":["implementation.md#01"],"targeted_test":"echo test-01 >> $TMP/calls.log"}
]}
EOF
RUN=".claude/skills/feature/scripts/feature-run.sh"
LOOP=".claude/skills/feature/scripts/consensus-loop.sh"
REVIEW_LOOP=".claude/skills/feature/scripts/impl-review-loop.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" MOCK_REVIEW_CONTRACT="$REVIEW_CONTRACT" FEATURE_LIVE_TEE=1
mkdir -p "$MOCK_STATE"
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904

# --- fake codex ---
#   read-only(검증자): FAKE_VALIDATOR_MODE 가 비어 있으면 PASS 를 -o 에 쓰고 exit 0(픽스처).
#     pass-exit1     : PASS 를 -o 에 쓰고 exit 1
#     none-exit1     : 아무것도 쓰지 않고 exit 1
#     badjson-exit1  : 문법상 JSON 이지만 계약(verdict 없음)에 어긋나는 결과를 쓰고 exit 1
#     seq            : 호출 횟수 n 에 따라 $MOCK_STATE/validator-$n.json 을 -o 에 복사(내용이 CRASH 면 쓰지 않고 exit 1), exit ${FAKE_VALIDATOR_RC_$n:-0}
#   workspace-write(워커): FAKE_WORKER_MODE
#     valid          : src/u01.txt 수정 + 유효 결과 JSON, exit $FAKE_WORKER_RC
#     invalid-mut    : src/u01.txt 수정 + 깨진 JSON(또는 FAKE_WORKER_NO_RESULT=1 이면 결과 없음), exit $FAKE_WORKER_RC
#     invalid-nomut  : 변경 없음 + 결과 없음, exit $FAKE_WORKER_RC
#     FAKE_WORKER_EXTRA(index|outside|baseline|manifest): valid 에 더해 기존 안전 게이트 위반을 만든다
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
out=""; readonly_sb=0; prompt=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; --sandbox) [ "$2" = read-only ] && readonly_sb=1; shift 2;; *) prompt="$1"; shift;; esac; done
printf 'tokens used\n123\n'   # usage.jsonl 행이 기록되게(codex 로그 파서)
if [ "$readonly_sb" = 1 ]; then
  echo "validator" >> "$MOCK_LOG"
  case "${FAKE_VALIDATOR_MODE:-}" in
    "") printf '{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}\n' "$FAKE_CONTRACT" > "$out"; exit 0;;
    badjson-exit1) printf '{"schema_version":%s,"note":"no verdict"}\n' "$FAKE_CONTRACT" > "$out"; exit 1;;
    pass-exit1) printf '{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}\n' "$FAKE_CONTRACT" > "$out"; exit 1;;
    none-exit1) exit 1;;
    seq)
      n=$(( $(cat "$MOCK_STATE/validator.n" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$MOCK_STATE/validator.n"
      f="$MOCK_STATE/validator-$n.json"
      [ "$(cat "$f")" = CRASH ] && exit 1
      cp "$f" "$out"; v="FAKE_VALIDATOR_RC_$n"; exit "${!v:-0}";;
  esac
fi
echo "worker" >> "$MOCK_LOG"
ctx='{"upsert":[{"kind":"REUSE","subject":"X","note":"n"}],"remove":[]}'
result_json="$(printf '{"status":"DONE","undecided":[],"delegated_choices":[{"location":"src/u01.txt","technique":"t","basis":"b"}],"tests":[{"name":"u01","result":"PASS"}],"context_updates":%s}' "$ctx")"
case "${FAKE_WORKER_MODE:-valid}" in
  valid)
    echo "worker edit" >> src/u01.txt
    case "${FAKE_WORKER_EXTRA:-}" in
      index) git add src/u01.txt;;
      outside) echo "leak" >> src/outside.txt;;
      baseline) printf '%s\n' 4b825dc642cb6eb9a060e54bf8d69288fbee4904 > .agent-work/worker-baseline.tree; echo tampered >> src/gen/existing.txt;;
      manifest) for m in .agent-work/feature-scope.json .agent-work/feature-scope.lock.json; do jq -c '.files += ["src/outside.txt"]' "$m" > "$m.tmp" && mv "$m.tmp" "$m"; done;;
    esac
    printf '%s' "$result_json" > "$out";;
  invalid-mut)
    echo "worker edit (uncertain)" >> src/u01.txt
    [ "${FAKE_WORKER_NO_RESULT:-0}" = 1 ] || printf '{"status":"DONE","undecided":[' > "$out";;
  invalid-nomut) ;;
esac
exit "${FAKE_WORKER_RC:-0}"
EOF
# --- fake claude ---
#   --tools(리뷰어): FAKE_REVIEW_DIR 가 있으면 호출 횟수 n 에 따라 review-$n.json(내용 CRASH 면 exit 1, 출력 없음), 없으면 APPROVE
#   --permission-mode + 스키마 없음(디자이너/수정자): FAKE_EDIT_CMD 실행 후 exit ${FAKE_EDIT_RC:-0}
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
is_reviewer=0; is_editor=0; schema=""
while [ "$#" -gt 0 ]; do case "$1" in --tools) is_reviewer=1; shift 2;; --permission-mode) is_editor=1; shift 2;; --json-schema) schema="$2"; shift 2;; -p) shift;; --session-id|--resume|--model|--effort|--output-format|--allowedTools|--disallowedTools|--append-system-prompt) shift 2;; *) shift;; esac; done
usage='"session_id":"fake","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
if [ "$is_reviewer" = 1 ]; then
  echo "reviewer" >> "$MOCK_LOG"
  if [ -n "${FAKE_REVIEW_DIR:-}" ]; then
    n=$(( $(cat "$MOCK_STATE/reviewer.n" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$MOCK_STATE/reviewer.n"
    f="$FAKE_REVIEW_DIR/review-$n.json"
    [ "$(cat "$f")" = CRASH ] && exit 1
    jq -n -c --slurpfile r "$f" "{structured_output: \$r[0], $usage}"
  else
    printf '{"structured_output":{"schema_version":%s,"verdict":"APPROVE","issues":[]},%s}' "$MOCK_REVIEW_CONTRACT" "$usage"
  fi
elif [ "$is_editor" = 1 ] && [ -z "$schema" ]; then
  echo "editor" >> "$MOCK_LOG"
  eval "${FAKE_EDIT_CMD:-true}"
  printf '{"result":"ok",%s}' "$usage"
  exit "${FAKE_EDIT_RC:-0}"
fi
EOF
chmod +x "$TMP/bin/codex" "$TMP/bin/claude"
export FAKE_CONTRACT="$CONTRACT"

fake_pass() { # design|impl — 가짜 검증자(기본 모드)가 PASS 를 -o 에 써서 체크포인트를 만든다
  bash "$LOOP" "$1" > "$TMP/consensus-$1.log" 2>&1 || { cat "$TMP/consensus-$1.log"; fail "픽스처: $1 합의 PASS 체크포인트 생성 실패"; }
}
fake_pass design; fake_pass impl
run_runner() { : > "$MOCK_LOG"; bash "$RUN" > "$TMP/run.log" 2>&1; echo $?; }
reason() { jq -r '.reason' .agent-work/run-state.json; }
status() { jq -r '.status' .agent-work/run-state.json; }
calls() { grep -c "^$1\$" "$MOCK_LOG" 2>/dev/null || true; }
anomalies() { if [ -f .agent-work/cli-anomalies.jsonl ]; then grep -c . .agent-work/cli-anomalies.jsonl || true; else echo 0; fi; }
worker_usage_rows() { # → "exit_code,success" 행들(워커만)
  jq -r 'select(.role=="WORKER") | [.exit_code, .success] | @csv' .agent-work/usage.jsonl 2>/dev/null
}
reset_tree() { # 테스트 환경 정리(파이프라인 동작 아님)
  git checkout -q -- src; rm -rf src/gen/new.txt
  rm -rf .agent-work/units .agent-work/implementation-context.json .agent-work/implementation-units.lock.json .agent-work/feature-scope.lock.json \
    .agent-work/worker-baseline.tree .agent-work/worker-baseline.guard.json .agent-work/worker-outcome.guard.json .agent-work/worker-result.json \
    .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/reviews/impl-attempt-* .agent-work/.session-* .agent-work/usage.jsonl .agent-work/cli-anomalies.jsonl
  rm -f "$MOCK_STATE"/*.n
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
}

# ===== 사례 A: 유효한 결과 + 변경 + exit 1 / exit 7 → 워커 1회, WARN, 재호출 없음, targeted test → done.json → DONE =====
for wrc in 1 7; do
  reset_tree
  rc="$(FAKE_WORKER_MODE=valid FAKE_WORKER_RC=$wrc run_runner)"
  [ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "A(exit $wrc): exit 0/DONE 기대, 실제 $rc/$(status)"; }
  [ "$(calls worker)" -eq 1 ] || fail "A(exit $wrc): 워커 호출이 1회가 아님 ($(calls worker)회): $(paste -sd'|' "$MOCK_LOG")"
  [ "$(paste -sd'|' "$MOCK_LOG")" = "worker|test-01|reviewer|full-test|full-lint" ] || fail "A(exit $wrc): 호출 순서 불일치: $(paste -sd'|' "$MOCK_LOG")"
  grep -q "CLI_EXIT_STATUS_MISMATCH: WORKER codex exited $wrc, but current invocation produced a valid worker result" "$TMP/run.log" || fail "A(exit $wrc): CLI mismatch WARN 이 로그에 없음"
  grep -q '워커 실행 실패' "$TMP/run.log" && fail "A(exit $wrc): 유효 결과가 있는데 실행 실패로 처리됨"
  jq -e '.worker_status=="DONE" and .targeted_test_status=="PASS"' .agent-work/units/01-intake/done.json >/dev/null || fail "A(exit $wrc): unit done.json 이 없거나 계약 불일치"
  [ "$(tail -1 src/u01.txt)" = "worker edit" ] || fail "A(exit $wrc): 워커 변경이 보존되지 않음"
  [ "$(worker_usage_rows)" = "$wrc,false" ] || fail "A(exit $wrc): usage.jsonl 워커 행이 raw exit_code=$wrc/success=false 가 아님: $(worker_usage_rows)"
  [ "$(anomalies)" -eq 1 ] || fail "A(exit $wrc): cli-anomalies.jsonl 행 수가 1 이 아님 ($(anomalies))"
  jq -e --argjson rc "$wrc" '.role=="WORKER" and .cli=="codex" and .raw_exit_code==$rc and .recovery=="STRUCTURED_RESULT" and (.evidence|endswith("worker-result.json")) and (.label|test("unit 01-intake"))' .agent-work/cli-anomalies.jsonl >/dev/null \
    || fail "A(exit $wrc): anomaly 행 필드 불일치: $(cat .agent-work/cli-anomalies.jsonl)"
  grep -q 'CLI 종료코드 불일치 복구 1 건' "$TMP/run.log" || fail "A(exit $wrc): DONE 로그에 anomaly 건수가 없음"
  [ ! -f .agent-work/worker-outcome.guard.json ] || fail "A(exit $wrc): 유효 결과인데 outcome 가드가 생김"
done
pass "A: 유효 결과 + 변경 + exit 1/7 → 워커 1회·재호출 없음·WARN·targeted test·done.json·DONE, usage raw exit_code 보존, anomaly STRUCTURED_RESULT"

# ===== 사례 B: 결과 없음/깨짐 + 변경 + non-zero → WORKER_OUTCOME_UNCERTAIN, 원복 없음, 재실행 워커 0회, 복구 후에만 재호출 =====
for variant in broken missing; do
  reset_tree
  no_result=0; [ "$variant" = missing ] && no_result=1
  rc="$(FAKE_WORKER_MODE=invalid-mut FAKE_WORKER_NO_RESULT=$no_result FAKE_WORKER_RC=7 run_runner)"
  [ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] || { tail -20 "$TMP/run.log"; fail "B($variant): exit 2/WORKER_OUTCOME_UNCERTAIN 기대, 실제 $rc/$(reason)"; }
  [ "$(calls worker)" -eq 1 ] || fail "B($variant): 워커 호출이 1회가 아님"
  grep -q 'test-01' "$MOCK_LOG" && fail "B($variant): 불확실 결과인데 targeted test 로 진행함"
  [ "$(tail -1 src/u01.txt)" = "worker edit (uncertain)" ] || fail "B($variant): 워커 변경이 자동 원복됨(보존돼야 함)"
  [ "$(git status --porcelain=v1 -- src/u01.txt)" = " M src/u01.txt" ] || fail "B($variant): git status 가 바뀜"
  jq -e '.active==true and .role=="WORKER" and .raw_exit_code==7' .agent-work/worker-outcome.guard.json >/dev/null || fail "B($variant): outcome 가드가 기록되지 않음"
  [ "$(jq -r .expected .agent-work/worker-outcome.guard.json)" = "$(cat .agent-work/units/01-intake/worker-before.tree)" ] || fail "B($variant): 가드 expected 가 호출 전 tree 가 아님"
  [ ! -f .agent-work/units/01-intake/done.json ] || fail "B($variant): done.json 이 생김"
  grep -q 'CLI_EXIT_STATUS_MISMATCH' "$TMP/run.log" && fail "B($variant): 유효 결과가 없는데 mismatch 복구로 처리됨"
  [ "$(anomalies)" -eq 0 ] || fail "B($variant): anomaly 가 기록됨(복구가 아니다)"
  # 아무것도 고치지 않고 같은 명령 재실행 → 모델 호출 0회, 같은 사유
  rc="$(FAKE_WORKER_MODE=valid FAKE_WORKER_RC=0 run_runner)"
  [ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] || { tail -20 "$TMP/run.log"; fail "B($variant): 미복구 재실행이 exit 2/WORKER_OUTCOME_UNCERTAIN 이 아님 ($rc/$(reason))"; }
  [ ! -s "$MOCK_LOG" ] || fail "B($variant): 미복구 재실행에서 모델/테스트가 호출됨: $(paste -sd'|' "$MOCK_LOG")"
  [ "$(jq -r .active .agent-work/worker-outcome.guard.json)" = true ] || fail "B($variant): 미복구 재실행 뒤 가드가 풀림"
  [ "$(tail -1 src/u01.txt)" = "worker edit (uncertain)" ] || fail "B($variant): 재실행이 변경을 원복함"
  # 사용자가 호출 전 tree 로 명시적으로 복구 → 가드 해제, 워커 재호출 → DONE
  git checkout -q "$(jq -r .expected .agent-work/worker-outcome.guard.json)" -- src
  rc="$(FAKE_WORKER_MODE=valid FAKE_WORKER_RC=0 run_runner)"
  [ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -20 "$TMP/run.log"; fail "B($variant): 복구 후 재실행이 DONE 이 아님 ($rc/$(status))"; }
  [ "$(calls worker)" -eq 1 ] || fail "B($variant): 복구 후 워커가 재호출되지 않음"
  [ "$(jq -r .active .agent-work/worker-outcome.guard.json)" = false ] || fail "B($variant): 복구 후 가드가 비활성화되지 않음"
done
pass "B: 결과 깨짐/없음 + 변경 + exit 7 → WORKER_OUTCOME_UNCERTAIN(원복 없음), 미복구 재실행 모델 0회, 호출 전 tree 복구 후에만 재호출"

# ===== 사례 C: 결과 없음 + non-zero + 변경 없음 → 기존 실행 실패(ENV_ERROR), 재실행 시 워커 재호출 허용 =====
reset_tree
rc="$(FAKE_WORKER_MODE=invalid-nomut FAKE_WORKER_RC=7 run_runner)"
[ "$rc" -eq 1 ] && [ "$(status)" = ENV_ERROR ] || { tail -20 "$TMP/run.log"; fail "C: exit 1/ENV_ERROR 기대, 실제 $rc/$(status)"; }
grep -q '워커 실행 실패' "$TMP/run.log" || fail "C: 기존 실행 실패 메시지가 없음"
[ ! -f .agent-work/worker-outcome.guard.json ] || fail "C: 변경이 없는데 outcome 가드가 생김"
rc="$(FAKE_WORKER_MODE=valid FAKE_WORKER_RC=0 run_runner)"
[ "$rc" -eq 0 ] && [ "$(calls worker)" -eq 1 ] || fail "C: 재실행에서 워커가 다시 호출되지 않음 ($rc, $(calls worker)회)"
pass "C: 결과 없음 + exit 7 + 변경 없음 → 기존 실행 실패, 재실행 시 워커 재호출(중복 위험 없음)"

# ===== 사례 F: 기존 안전 게이트가 CLI mismatch 복구보다 먼저 =====
reset_tree
rc="$(FAKE_WORKER_MODE=valid FAKE_WORKER_RC=1 FAKE_WORKER_EXTRA=index run_runner)"
[ "$rc" -eq 1 ] && grep -q '워커가 git index 를 변경함' "$TMP/run.log" || { tail -20 "$TMP/run.log"; fail "F(index): index 변경이 먼저 보고되지 않음 ($rc)"; }
grep -q 'CLI_EXIT_STATUS_MISMATCH' "$TMP/run.log" && fail "F(index): index 변경보다 mismatch 복구가 먼저 나옴"
[ "$(anomalies)" -eq 0 ] || fail "F(index): anomaly 가 기록됨"
[ "$(git status --porcelain=v1 -- src/u01.txt)" = "M  src/u01.txt" ] || fail "F(index): index 를 임의로 복구함"
git restore --staged src/u01.txt
reset_tree
rc="$(FAKE_WORKER_MODE=valid FAKE_WORKER_RC=1 FAKE_WORKER_EXTRA=outside run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = SCOPE_VIOLATION ] || { tail -20 "$TMP/run.log"; fail "F(scope): SCOPE_VIOLATION 기대, 실제 $rc/$(reason)"; }
grep -q 'CLI_EXIT_STATUS_MISMATCH' "$TMP/run.log" && fail "F(scope): scope 위반보다 mismatch 복구가 먼저 나옴"
[ "$(tail -1 src/outside.txt)" = leak ] || fail "F(scope): 범위 밖 변경이 원복됨"
reset_tree
rc="$(FAKE_WORKER_MODE=valid FAKE_WORKER_RC=1 FAKE_WORKER_EXTRA=baseline run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = SCOPE_BASELINE_CHANGED ] || { tail -20 "$TMP/run.log"; fail "F(baseline): SCOPE_BASELINE_CHANGED 기대, 실제 $rc/$(reason)"; }
[ "$(jq -r .active .agent-work/worker-baseline.guard.json)" = true ] || fail "F(baseline): 기준선 가드가 남지 않음"
grep -q 'CLI_EXIT_STATUS_MISMATCH' "$TMP/run.log" && fail "F(baseline): 기준선 변조보다 mismatch 복구가 먼저 나옴"
reset_tree
rc="$(FAKE_WORKER_MODE=valid FAKE_WORKER_RC=1 FAKE_WORKER_EXTRA=manifest run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = SCOPE_MANIFEST_CHANGED ] || { tail -20 "$TMP/run.log"; fail "F(manifest): SCOPE_MANIFEST_CHANGED 기대, 실제 $rc/$(reason)"; }
grep -q 'CLI_EXIT_STATUS_MISMATCH' "$TMP/run.log" && fail "F(manifest): manifest 변경보다 mismatch 복구가 먼저 나옴"
[ "$(anomalies)" -eq 0 ] || fail "F: 안전 위반 경로에서 anomaly 가 기록됨"
printf '{"version":1,"files":["src/u01.txt"],"new_file_roots":["src/gen/"]}\n' > .agent-work/feature-scope.json   # manifest 원복(테스트 정리)
fake_pass impl
pass "F: non-zero + 유효 결과라도 index → manifest → 기준선 → scope 위반이 먼저 보고되고 anomaly 는 기록되지 않음"

# ===== 사례 G: read-only 검증자(codex) exit 1 — 이번 호출의 -o 결과가 있으면 사용, 없으면 실패, stale 파일은 결과가 아님 =====
reset_consensus() { rm -rf .agent-work/designer-scope.guard.json .agent-work/consensus-design.json .agent-work/reviews/validator-design-round-*.json .agent-work/reviews/docs-* .agent-work/usage.jsonl .agent-work/cli-anomalies.jsonl; : > .agent-work/decisions.md; printf '# design\n' > .agent-work/design.md; rm -f "$MOCK_STATE"/*.n; : > "$MOCK_LOG"; }
reset_consensus
FAKE_VALIDATOR_MODE=pass-exit1 bash "$LOOP" design > "$TMP/loop.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { tail -20 "$TMP/loop.log"; fail "G(pass-exit1): 결과 JSON 이 있는데 검증자 exit 1 로 실패 ($rc)"; }
[ "$(calls validator)" -eq 1 ] || fail "G(pass-exit1): 검증자 호출 1회가 아님"
grep -q 'CLI_EXIT_STATUS_MISMATCH: VALIDATOR codex exited 1' "$TMP/loop.log" || fail "G(pass-exit1): WARN 없음"
jq -e '.role=="VALIDATOR" and .recovery=="STRUCTURED_RESULT" and .raw_exit_code==1' .agent-work/cli-anomalies.jsonl >/dev/null || fail "G(pass-exit1): anomaly 행 불일치"
[ "$(jq -r 'select(.role=="VALIDATOR") | [.exit_code,.success] | @csv' .agent-work/usage.jsonl)" = "1,false" ] || fail "G(pass-exit1): usage 행이 raw exit 1/false 가 아님"
[ "$(jq -r .next_step .agent-work/consensus-design.json)" = PASS ] || fail "G(pass-exit1): PASS 체크포인트가 아님"
reset_consensus
FAKE_VALIDATOR_MODE=none-exit1 bash "$LOOP" design > "$TMP/loop.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q 'codex 실행 실패' "$TMP/loop.log" || fail "G(none-exit1): 결과 없는 exit 1 이 기존 실패로 처리되지 않음 ($rc)"
[ "$(anomalies)" -eq 0 ] || fail "G(none-exit1): anomaly 가 기록됨"
# 이전 실행의 $out 이 같은 경로에 남아 있어도 이번 호출이 쓰지 않았으면 결과로 쓰지 않는다
reset_consensus
printf '{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}\n' "$CONTRACT" > .agent-work/reviews/validator-design-round-01.json
FAKE_VALIDATOR_MODE=none-exit1 bash "$LOOP" design > "$TMP/loop.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { tail -20 "$TMP/loop.log"; fail "G(stale): 이전 파일을 이번 결과로 오인함 ($rc)"; }
ls .agent-work/reviews/ | grep -q 'invocation-.*\.tmp' && fail "G(stale): 임시 -o 파일이 남음"
# 같은 JSON 을 두 번 연속: 두 번째 invocation(exit 1)도 새 결과로 인정된다 — 내용·mtime 으로 provenance 를 추론하지 않는다
reset_consensus
FAKE_VALIDATOR_MODE=pass-exit1 bash "$LOOP" design > "$TMP/loop.log" 2>&1 || fail "G(same-twice): 1차 실패"
rm -f .agent-work/consensus-design.json   # 체크포인트만 무효화, round-01 리뷰 파일(동일 내용)은 그대로 둔다
: > "$MOCK_LOG"
FAKE_VALIDATOR_MODE=pass-exit1 bash "$LOOP" design > "$TMP/loop.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(calls validator)" -eq 1 ] || { tail -20 "$TMP/loop.log"; fail "G(same-twice): 동일 JSON 재출력이 stale 로 오판됨 ($rc)"; }
[ "$(anomalies)" -eq 2 ] || fail "G(same-twice): 두 invocation 모두 anomaly 로 기록돼야 함 ($(anomalies))"
# 문법상 JSON 이지만 계약 위반(verdict 없음) + exit 1: 헬퍼는 넘기고 caller 의 계약 검사가 실패시킨다(fail-closed)
reset_consensus
FAKE_VALIDATOR_MODE=badjson-exit1 bash "$LOOP" design > "$TMP/loop.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q '리뷰 JSON이 스키마와 다름' "$TMP/loop.log" || { tail -20 "$TMP/loop.log"; fail "G(badjson): 계약 위반 JSON 이 caller 검사에서 실패하지 않음 ($rc)"; }
[ ! -f .agent-work/consensus-design.json ] || ! jq -e '.next_step=="PASS"' .agent-work/consensus-design.json >/dev/null 2>&1 || fail "G(badjson): PASS 체크포인트가 생김"
pass "G: read-only codex exit 1 → 이번 -o 결과 있으면 사용(anomaly·usage raw 보존) / 없으면 실패·이전 파일 미사용 / 동일 JSON 재출력도 새 결과 / 계약 위반 JSON 은 caller 에서 실패"

blocker_h='{"id":"B-01","action":"REVISE_DOC","category":"CONTRACT_GAP","change_relation":"NEW","evidence_type":"DIRECT_MISMATCH","basis_refs":["design.md:L1"],"conflict_refs":["design.md:L1"],"code_refs":[],"reachable_scenario":"","impact":"x","why_blocks_now":"y","minimum_contract_needed":"z","user_question":"","options":[],"origin":"ROUND_1","previous_issue_id":"","revision_ref":""}'
# ===== 사례 H: designer 가 합의 문서 밖 source 파일을 변경 → DESIGNER_SCOPE_VIOLATION (rc 0 / rc 5), 원복·재호출·검증자 전달 없음 =====
for drc in 0 5; do
  reset_consensus; git checkout -q -- src
  printf '%s' "$blocker_h" | jq -c --argjson v "$CONTRACT" '{schema_version:$v,verdict:"BLOCK",blocking_issues:[.]}' > "$MOCK_STATE/validator-1.json"
  printf '{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}\n' "$CONTRACT" > "$MOCK_STATE/validator-2.json"
  # rc 0: source 만 변경(문서 불변) / rc 5: 문서 + source 변경 — 어느 쪽이든 source 변경이 먼저 잡혀야 한다
  doc_edit='true'; [ "$drc" -eq 0 ] || doc_edit='echo revised >> .agent-work/design.md'
  FAKE_VALIDATOR_MODE=seq FAKE_EDIT_CMD="$doc_edit; echo 'designer leak' >> src/u01.txt" FAKE_EDIT_RC=$drc bash "$LOOP" design > "$TMP/loop-h.log" 2>&1; rc=$?
  [ "$rc" -eq 2 ] || { tail -20 "$TMP/loop-h.log"; fail "H(rc $drc): exit 2 기대, 실제 $rc"; }
  [ "$(jq -r .status .agent-work/state.json)" = DESIGNER_SCOPE_VIOLATION ] || fail "H(rc $drc): state.json 이 DESIGNER_SCOPE_VIOLATION 이 아님"
  [ "$(calls editor)" -eq 1 ] && [ "$(calls validator)" -eq 1 ] || fail "H(rc $drc): 디자이너 1회·검증자 1회가 아님 ($(paste -sd'|' "$MOCK_LOG"))"
  [ "$(tail -1 src/u01.txt)" = "designer leak" ] || fail "H(rc $drc): source 변경이 자동 원복됨(보존돼야 함)"
  jq -e '.active==true and .target=="design"' .agent-work/designer-scope.guard.json >/dev/null || fail "H(rc $drc): designer-scope 가드가 없음"
  jq -e '.round==1 and .next_step=="DESIGNER_PENDING"' .agent-work/consensus-design.json >/dev/null || fail "H(rc $drc): 체크포인트가 VALIDATOR_PENDING 등으로 넘어감: $(cat .agent-work/consensus-design.json)"
  grep -q 'CLI_EXIT_STATUS_MISMATCH' "$TMP/loop-h.log" && fail "H(rc $drc): source 변경이 mismatch 복구로 처리됨"
  # 아무것도 고치지 않고 재실행 → 모델 호출 0회, 같은 사유
  : > "$MOCK_LOG"
  FAKE_VALIDATOR_MODE=seq FAKE_EDIT_CMD='echo AGAIN >> src/u01.txt' FAKE_EDIT_RC=0 bash "$LOOP" design > "$TMP/loop-h2.log" 2>&1; rc=$?
  [ "$rc" -eq 2 ] && [ "$(jq -r .status .agent-work/state.json)" = DESIGNER_SCOPE_VIOLATION ] || fail "H(rc $drc): 미복구 재실행이 같은 사유로 멈추지 않음 ($rc)"
  [ ! -s "$MOCK_LOG" ] || fail "H(rc $drc): 미복구 재실행에서 모델이 호출됨: $(paste -sd'|' "$MOCK_LOG")"
  grep -q AGAIN src/u01.txt && fail "H(rc $drc): 같은 디자이너가 재호출됨"
  # 러너도 같은 사유를 NEED_USER 로 전달한다(모델 0회)
  printf '{"stage":"design","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
  : > "$MOCK_LOG"; bash "$RUN" > "$TMP/run-h.log" 2>&1; rc=$?
  [ "$rc" -eq 2 ] && [ "$(reason)" = DESIGNER_SCOPE_VIOLATION ] || { tail -10 "$TMP/run-h.log"; fail "H(rc $drc): 러너가 NEED_USER/DESIGNER_SCOPE_VIOLATION 을 내지 않음 ($rc/$(reason))"; }
  [ ! -s "$MOCK_LOG" ] || fail "H(rc $drc): 러너 재실행에서 모델이 호출됨"
  # 사용자가 호출 전 tree 로 복구 → 가드 해제 → round 2 PASS.
  #   문서 불변(rc 0 변형): 디자이너가 다시 돈다(1회). 문서 변경(rc 5 변형): 기존 재개 규칙(디자이너 호출 중 문서 변경 흔적)대로 디자이너 0회, 검증자로.
  git checkout -q "$(jq -r .expected .agent-work/designer-scope.guard.json)" -- src
  : > "$MOCK_LOG"
  FAKE_VALIDATOR_MODE=seq FAKE_EDIT_CMD='echo revised2 >> .agent-work/design.md' FAKE_EDIT_RC=0 bash "$LOOP" design > "$TMP/loop-h3.log" 2>&1; rc=$?
  expect_editor=1; [ "$drc" -eq 0 ] || expect_editor=0
  [ "$rc" -eq 0 ] && [ "$(calls editor)" -eq "$expect_editor" ] && [ "$(calls validator)" -eq 1 ] || { tail -20 "$TMP/loop-h3.log"; fail "H(rc $drc): 복구 후 재개 불일치 (rc $rc, 기대 editor $expect_editor: $(paste -sd'|' "$MOCK_LOG"))"; }
  [ "$(jq -r .active .agent-work/designer-scope.guard.json)" = false ] || fail "H(rc $drc): 복구 후 가드가 비활성화되지 않음"
done
pass "H: 디자이너 source 변경(rc 0/5) → DESIGNER_SCOPE_VIOLATION, 원복·재호출·검증자 전달 없음, 미복구 재실행(루프·러너) 모델 0회, 복구 후 재개"
reset_consensus; git checkout -q -- src; fake_pass design

# ===== 사례 D: designer 문서 수정 + exit non-zero → 디자이너 1회, 재호출 없음, 다음 체크포인트 VALIDATOR_PENDING, 검증자가 판정 =====
blocker='{"id":"B-01","action":"REVISE_DOC","category":"CONTRACT_GAP","change_relation":"NEW","evidence_type":"DIRECT_MISMATCH","basis_refs":["design.md:L1"],"conflict_refs":["design.md:L1"],"code_refs":[],"reachable_scenario":"","impact":"x","why_blocks_now":"y","minimum_contract_needed":"z","user_question":"","options":[],"origin":"ROUND_1","previous_issue_id":"","revision_ref":""}'
printf '%s' "$blocker" | jq -c --argjson v "$CONTRACT" '{schema_version:$v,verdict:"BLOCK",blocking_issues:[.]}' > "$MOCK_STATE/validator-1.json"
printf 'CRASH' > "$MOCK_STATE/validator-2.json"
printf '{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}\n' "$CONTRACT" > "$MOCK_STATE/validator-3.json"
reset_consensus
# 1차: 검증자 BLOCK → 디자이너(문서+decisions 수정, exit 5) → 검증자 round 2 는 crash(exit 1, 출력 없음) → 루프 exit 1, 체크포인트 round 2 / VALIDATOR_PENDING
FAKE_VALIDATOR_MODE=seq FAKE_EDIT_CMD='echo revised >> .agent-work/design.md; echo "- [round 1] B-01 ACCEPT" >> .agent-work/decisions.md' FAKE_EDIT_RC=5 \
  bash "$LOOP" design > "$TMP/loop.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { tail -20 "$TMP/loop.log"; fail "D: 1차 exit 1(검증자 round 2 crash) 기대, 실제 $rc"; }
[ "$(calls editor)" -eq 1 ] || fail "D: 디자이너 호출이 1회가 아님 ($(calls editor))"
[ "$(calls validator)" -eq 2 ] || fail "D: 검증자 호출이 2회(round 1 BLOCK + round 2 crash)가 아님 ($(calls validator))"
grep -q 'CLI_EXIT_STATUS_MISMATCH: DESIGNER claude exited 5' "$TMP/loop.log" || fail "D: 디자이너 mismatch WARN 없음"
grep -q '디자이너 실행 실패' "$TMP/loop.log" && fail "D: 문서가 바뀌었는데 디자이너 실패로 처리됨"
jq -e '.round==2 and .next_step=="VALIDATOR_PENDING"' .agent-work/consensus-design.json >/dev/null || fail "D: 체크포인트가 round 2 / VALIDATOR_PENDING 이 아님: $(cat .agent-work/consensus-design.json)"
jq -e '.role=="DESIGNER" and .cli=="claude" and .raw_exit_code==5 and .recovery=="FORWARD_TO_VALIDATOR"' .agent-work/cli-anomalies.jsonl >/dev/null || fail "D: anomaly 행 불일치: $(cat .agent-work/cli-anomalies.jsonl)"
[ "$(jq -r 'select(.role=="DESIGNER") | [.exit_code,.success] | @csv' .agent-work/usage.jsonl)" = "5,false" ] || fail "D: usage 디자이너 행이 raw exit 5/false 가 아님"
grep -q revised .agent-work/design.md || fail "D: 디자이너 변경이 보존되지 않음"
# 2차 재실행: 디자이너 재호출 없이 검증자 round 2 만 → PASS
: > "$MOCK_LOG"
FAKE_VALIDATOR_MODE=seq FAKE_EDIT_CMD='echo AGAIN >> .agent-work/design.md' FAKE_EDIT_RC=0 bash "$LOOP" design > "$TMP/loop2.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { tail -20 "$TMP/loop2.log"; fail "D: 재실행 exit 0(round 2 PASS) 기대, 실제 $rc"; }
[ "$(calls editor)" -eq 0 ] || fail "D: 재실행에서 디자이너가 다시 호출됨"
[ "$(calls validator)" -eq 1 ] || fail "D: 재실행 검증자 호출이 1회가 아님"
grep -q AGAIN .agent-work/design.md && fail "D: 같은 디자이너 편집이 반복됨"
jq -e '.round==2 and .next_step=="PASS"' .agent-work/consensus-design.json >/dev/null || fail "D: 최종 체크포인트가 round 2 PASS 가 아님"
# 변경 없음 + exit non-zero → 기존 실패, DESIGNER_PENDING 유지(같은 디자이너 재실행이 안전)
reset_consensus
printf '%s' "$blocker" | jq -c --argjson v "$CONTRACT" '{schema_version:$v,verdict:"BLOCK",blocking_issues:[.]}' > "$MOCK_STATE/validator-1.json"
FAKE_VALIDATOR_MODE=seq FAKE_EDIT_CMD='true' FAKE_EDIT_RC=5 bash "$LOOP" design > "$TMP/loop3.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q '디자이너 실행 실패' "$TMP/loop3.log" || fail "D(no-mut): 변경 없는 exit 5 가 기존 실패로 처리되지 않음 ($rc)"
jq -e '.round==1 and .next_step=="DESIGNER_PENDING"' .agent-work/consensus-design.json >/dev/null || fail "D(no-mut): 체크포인트가 DESIGNER_PENDING 유지가 아님"
[ "$(anomalies)" -eq 0 ] || fail "D(no-mut): anomaly 가 기록됨"
pass "D: 디자이너 문서 수정 + exit 5 → 1회 호출·재호출 없음·VALIDATOR_PENDING·검증자 판정(FORWARD_TO_VALIDATOR) / 변경 없음 → 기존 실패"
reset_consensus; fake_pass design   # 이후 사례를 위해 design PASS 픽스처 복구

# ===== 사례 E: fixer 코드 수정 + exit non-zero → 수정자 1회, 재호출 없음, 다음 체크포인트 REVIEWER_PENDING, 리뷰어가 판정 =====
reset_tree
echo "worker edit" >> src/u01.txt   # 워커가 만든 변경(리뷰 대상)
( source "$CFG"; snapshot_worktree_tree ) > .agent-work/worker-baseline.tree.tmp   # 기준선은 워커 변경 '전' 이어야 한다 — 아래에서 다시 만든다
git checkout -q -- src/u01.txt
( source "$CFG"; snapshot_worktree_tree ) > .agent-work/worker-baseline.tree; rm -f .agent-work/worker-baseline.tree.tmp
echo "worker edit" >> src/u01.txt
cp .agent-work/feature-scope.json .agent-work/feature-scope.lock.json
printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}\n' > .agent-work/worker-result.json
review_issue='{"id":"R-01","action":"FIX_CODE","category":"CONTRACT_VIOLATION","evidence_type":"DIRECT_MISMATCH","basis_refs":["approach.md:L1"],"code_refs":["src/u01.txt:L1-L1"],"reachable_scenario":"","impact":"","why_blocks_now":"x","required_outcome":"y","origin":"ROUND_1","previous_issue_id":"","fix_ref":""}'
export FAKE_REVIEW_DIR="$TMP/side"
printf '%s' "$review_issue" | jq -c --argjson v "$REVIEW_CONTRACT" '{schema_version:$v,verdict:"REQUEST_CHANGES",issues:[.]}' > "$TMP/side/review-1.json"
printf 'CRASH' > "$TMP/side/review-2.json"
printf '{"schema_version":%s,"verdict":"APPROVE","issues":[]}\n' "$REVIEW_CONTRACT" > "$TMP/side/review-3.json"
: > "$MOCK_LOG"; rm -f "$MOCK_STATE"/*.n .agent-work/cli-anomalies.jsonl .agent-work/usage.jsonl
# 1차: 리뷰어 REQUEST_CHANGES → 수정자(코드 수정, exit 3) → 리뷰어 round 2 crash → 루프 exit 1, 체크포인트 round 2 / REVIEWER_PENDING
FAKE_EDIT_CMD='echo fixed >> src/u01.txt; echo "- [fix round 1] R-01 ACCEPT" >> .agent-work/decisions.md' FAKE_EDIT_RC=3 bash "$REVIEW_LOOP" > "$TMP/review.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { tail -20 "$TMP/review.log"; fail "E: 1차 exit 1(리뷰어 round 2 crash) 기대, 실제 $rc"; }
[ "$(calls editor)" -eq 1 ] || fail "E: 수정자 호출이 1회가 아님 ($(calls editor))"
[ "$(calls reviewer)" -eq 2 ] || fail "E: 리뷰어 호출이 2회가 아님 ($(calls reviewer))"
grep -q 'CLI_EXIT_STATUS_MISMATCH: FIXER claude exited 3' "$TMP/review.log" || fail "E: 수정자 mismatch WARN 없음"
grep -q '수정자 실행 실패' "$TMP/review.log" && fail "E: 코드가 바뀌었는데 수정자 실패로 처리됨"
jq -e '.round==2 and .next_step=="REVIEWER_PENDING" and .attempt==1' .agent-work/review-impl.json >/dev/null || fail "E: 체크포인트가 round 2 / REVIEWER_PENDING 이 아님: $(cat .agent-work/review-impl.json)"
jq -e '.role=="FIXER" and .cli=="claude" and .raw_exit_code==3 and .recovery=="FORWARD_TO_REVIEWER"' .agent-work/cli-anomalies.jsonl >/dev/null || fail "E: anomaly 행 불일치: $(cat .agent-work/cli-anomalies.jsonl)"
[ "$(jq -r 'select(.role=="FIXER") | [.exit_code,.success] | @csv' .agent-work/usage.jsonl)" = "3,false" ] || fail "E: usage 수정자 행이 raw exit 3/false 가 아님"
[ "$(tail -1 src/u01.txt)" = fixed ] || fail "E: 수정자 변경이 보존되지 않음"
# 2차 재실행: 수정자 재호출 없이 리뷰어 round 2 → APPROVE
: > "$MOCK_LOG"
FAKE_EDIT_CMD='echo AGAIN >> src/u01.txt' FAKE_EDIT_RC=0 bash "$REVIEW_LOOP" > "$TMP/review2.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { tail -20 "$TMP/review2.log"; fail "E: 재실행 exit 0(round 2 APPROVE) 기대, 실제 $rc"; }
[ "$(calls editor)" -eq 0 ] || fail "E: 재실행에서 수정자가 다시 호출됨"
[ "$(calls reviewer)" -eq 1 ] || fail "E: 재실행 리뷰어 호출이 1회가 아님"
grep -q AGAIN src/u01.txt && fail "E: 같은 수정자 편집이 반복됨"
jq -e '.next_step=="APPROVE" and .round==2' .agent-work/review-impl.json >/dev/null || fail "E: 최종 체크포인트가 APPROVE 가 아님"
# 변경 없음 + exit non-zero → 기존 실패, FIXER_PENDING 유지
rm -f "$MOCK_STATE"/*.n .agent-work/cli-anomalies.jsonl; printf '{"version":0}\n' > .agent-work/review-impl.json; : > "$MOCK_LOG"
FAKE_EDIT_CMD='true' FAKE_EDIT_RC=3 bash "$REVIEW_LOOP" > "$TMP/review3.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q '수정자 실행 실패' "$TMP/review3.log" || fail "E(no-mut): 변경 없는 exit 3 이 기존 실패로 처리되지 않음 ($rc)"
jq -e '.next_step=="FIXER_PENDING" and .round==1' .agent-work/review-impl.json >/dev/null || fail "E(no-mut): 체크포인트가 FIXER_PENDING 유지가 아님"
[ "$(anomalies)" -eq 0 ] || fail "E(no-mut): anomaly 가 기록됨"
unset FAKE_REVIEW_DIR
pass "E: 수정자 코드 수정 + exit 3 → 1회 호출·재호출 없음·REVIEWER_PENDING·리뷰어 판정(FORWARD_TO_REVIEWER) / 변경 없음 → 기존 실패"

rm -rf "$TMP"
echo "[SMOKE OK] CLI 종료코드 ≠ 의미적 완료 스모크 전체 통과"
