#!/usr/bin/env bash
# =============================================================
# 스모크: 구현 단위(implementation unit) 직렬 실행 — 실제 LLM 호출 없음 (mock claude / fake codex), 임시 저장소
# 파일 경로: tests/smoke-implementation-units.sh
# 사용법: bash tests/smoke-implementation-units.sh   (어디서든 실행 가능)
#
# 사례:
#   A. units 가 01 → 02 → 03 순서로만 호출된다
#   B. 동시에 워커가 둘 이상 실행되지 않는다 (호출 겹침 감지)
#   C. Unit 01 실패(USER_DECISION) 시 Unit 02 는 호출되지 않는다
#   D. Unit 01/02 완료 후 러너 재실행 시 Unit 03 부터 재개한다 (01/02 워커 재호출 없음)
#   E. unit manifest 가 lock 이후 변경되면 워커 호출 0회로 중단한다 (UNITS_MANIFEST_CHANGED)
#   F. unit 워커가 자기 unit scope 밖(전체 범위 안)을 수정하면 다음 unit 으로 가지 않는다 (UNIT_SCOPE_VIOLATION, 원복 없음)
#   G. unit 사이에는 리뷰어·수정자 호출이 없다 — 리뷰어 호출은 모든 unit 뒤 전체 review 한 번뿐
#   I. targeted test 실패 시 unit 범위 수정 → 재테스트(리뷰어 미호출), 재시도 소진 시 사용자 반환
#   J. 모든 unit 완료 후에만 기존 전체 review → verify(TEST_CMD/LINT_CMD) → DONE 으로 진입한다
#   K. implementation-units.json 변경 시 기존 impl consensus PASS 가 무효가 된다
#   S. manifest 스키마·부분집합 검사
#   T. claude 로 라우팅된 워커는 unit 마다 fresh 세션(--session-id)이다
#   X. unit 간 rolling implementation context (별도 모델 호출 없음, 러너가 upsert/remove 를 (kind,subject) 키로 fold):
#      X-A. Unit 01 PASS 후 Unit 02 워커 프롬프트에 01 의 확정 fact 가 들어간다
#      X-B. Unit 01 targeted test 가 끝내 실패하면 01 의 context 는 확정되지 않는다
#      X-C. test-fix 후 PASS 면 워커 → fix 순서로 fold 한 결과(fix 가 정정한 note)가 Unit 02 에 간다
#      X-D. 같은 (kind,subject) upsert 는 append 가 아니라 replace — facts 가 unit 수에 비례해 늘지 않는다
#      X-E. remove 된 fact 는 다음 워커에게 가지 않는다
#      X-F. 01/02 완료 후 03 부터 재개해도 01/02 의 rolling context 가 03 에 전달된다
#      X-G. spec_hash 로 무효화된 unit 체크포인트의 context-updates 는 조용히 재사용되지 않는다
#   D2. 앞 unit(02) 이 무효화됐는데 뒤 unit(03) 완료 체크포인트가 있으면 UNIT_CHECKPOINT_CHAIN_STALE (워커 0회, 원복 없음);
#       사용자가 02 의 before.tree 로 되돌리고 03 체크포인트를 치우면 02→03 순서로 다시 돈다
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-units-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

# --- 임시 저장소: 스킬 복사 + CHANGE_ME 채움 + 뷰어 비활성 ---
mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"echo full-test >> $TMP/calls.log\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"echo full-lint >> $TMP/calls.log\"|" "$CFG" && rm -f "$CFG.bak"
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && for u in 01 02 03; do echo "base $u" > "src/u$u.txt"; done; echo "shared base" > src/shared.txt; echo "outside base" > src/outside.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/u01.txt","src/u02.txt","src/u03.txt","src/shared.txt"],"new_file_roots":["src/gen/"]}\n' > .agent-work/feature-scope.json
RUN=".claude/skills/feature/scripts/feature-run.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" FEATURE_LIVE_TEE=1
mkdir -p "$MOCK_STATE"

# 3 unit manifest: 01 → 02(공유 파일 순차 수정) → 03. targeted test 는 unit 별 스크립트(플래그 파일로 통과/실패 제어)
for u in 01 02 03; do
  printf '%s\n' '#!/usr/bin/env bash' "echo test-$u >> \"$MOCK_LOG\"" "[ ! -f \"$MOCK_STATE/fail-test-$u\" ] || { rm -f \"$MOCK_STATE/fail-test-$u\"; echo \"unit $u test failed\"; exit 1; }" > "$TMP/bin/test-$u"
  chmod +x "$TMP/bin/test-$u"
done
write_units() { # → .agent-work/implementation-units.json (기본 3 unit)
  cat > .agent-work/implementation-units.json <<EOF
{"version":1,"units":[
 {"id":"01-intake","title":"접수","goal":"unit 01","requirements":["REQ-01"],"scope":{"files":["src/u01.txt","src/shared.txt"],"new_file_roots":[]},"references":["implementation.md#01"],"targeted_test":"$TMP/bin/test-01"},
 {"id":"02-drop","title":"Drop","goal":"unit 02","requirements":["REQ-02"],"scope":{"files":["src/u02.txt","src/shared.txt"],"new_file_roots":["src/gen/"]},"references":["implementation.md#02"],"targeted_test":"$TMP/bin/test-02"},
 {"id":"03-reassign","title":"재배정","goal":"unit 03","requirements":["REQ-03"],"scope":{"files":["src/u03.txt"],"new_file_roots":[]},"references":["implementation.md#03"],"targeted_test":"$TMP/bin/test-03"}
]}
EOF
}
write_units

# --- fake codex: 검증자(read-only) 는 아무것도 하지 않음(리뷰 파일은 픽스처). 워커(workspace-write) 는 unit id 를 프롬프트에서 읽어 기록·수정 ---
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
out=""; readonly_sb=0; prompt=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; --sandbox) [ "$2" = read-only ] && readonly_sb=1; shift 2;; *) prompt="$1"; shift;; esac; done
[ "$readonly_sb" = 1 ] && exit 0
unit="$(printf '%s' "$prompt" | grep -oE '"id": *"[0-9]+-[a-z0-9-]+"' | head -1 | sed -E 's/.*"([0-9]+-[a-z0-9-]+)"/\1/')"
kind=worker; printf '%s' "$prompt" | grep -qE 'targeted-test-[0-9]+\.log' && kind=test-fix   # 수정 프롬프트에만 실패 로그 경로(${TEST_LOG})가 있다
# 동시 실행 감지: 이미 다른 워커가 실행 중이면 즉시 실패
mkdir "$MOCK_STATE/worker.lock" 2>/dev/null || { echo "CONCURRENT WORKER" >> "$MOCK_LOG"; exit 9; }
echo "$kind ${unit:-none}" >> "$MOCK_LOG"
sleep 0.2
n="${unit%%-*}"
# 프롬프트의 [IMPLEMENTATION CONTEXT] 블록을 보존해 사례 X 가 검사한다
printf '%s' "$prompt" | sed -n '/^\[IMPLEMENTATION CONTEXT\]$/,/^\[\/IMPLEMENTATION CONTEXT\]$/p' > "$MOCK_STATE/ctx-$kind-$n.txt"
ctx='{"upsert":[],"remove":[]}'
case "$kind-$n" in
  worker-01) ctx='{"upsert":[{"kind":"REUSE","subject":"InquiryStatus.isAssignable","note":"01-note"},{"kind":"ENTRY_POINT","subject":"InquiryService.assignInitialAgent","note":"entry"}],"remove":[]}';;
  test-fix-01) ctx='{"upsert":[{"kind":"REUSE","subject":"InquiryStatus.isAssignable","note":"fixed-note"}],"remove":[]}';;
  worker-02) ctx='{"upsert":[{"kind":"REUSE","subject":"InquiryStatus.isAssignable","note":"02-note"},{"kind":"INVARIANT","subject":"inquiry version check","note":"vl"}],"remove":[{"kind":"ENTRY_POINT","subject":"InquiryService.assignInitialAgent"}]}';;
esac
case "$kind" in
  worker)
    [ -n "$unit" ] && echo "worker $unit" >> "src/u$n.txt"
    [ "$n" = 01 ] || [ "$n" = 02 ] && echo "shared by $unit" >> src/shared.txt
    [ "$n" = 02 ] && mkdir -p src/gen && echo "gen by 02" > src/gen/new.txt
    if [ -f "$MOCK_STATE/outside-$n" ]; then echo "outside by $unit" >> src/outside.txt; fi          # 전체 범위 밖
    if [ -f "$MOCK_STATE/unitscope-$n" ]; then echo "unit-scope leak by $unit" >> src/u03.txt; fi   # 전체 범위 안, unit scope 밖 (01/02 에서)
    if [ -f "$MOCK_STATE/undecided-$n" ]; then
      printf '{"status":"UNDECIDED","undecided":[{"kind":"USER_DECISION","location":"src/u%s.txt","decision_needed":"policy","options":["a","b"]}],"delegated_choices":[],"tests":[]}' "$n" > "$out"
      rmdir "$MOCK_STATE/worker.lock"; exit 0
    fi
    if [ -f "$MOCK_STATE/crash-$n" ]; then rm -f "$MOCK_STATE/crash-$n"; rmdir "$MOCK_STATE/worker.lock"; exit 7; fi
    printf '{"status":"DONE","undecided":[],"delegated_choices":[{"location":"src/u%s.txt","technique":"t","basis":"b"}],"tests":[{"name":"u%s","result":"PASS"}],"context_updates":%s}' "$n" "$n" "$ctx" > "$out";;
  test-fix)
    echo "test-fix $unit" >> "src/u$n.txt"
    printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":%s}' "$ctx" > "$out";;
esac
rmdir "$MOCK_STATE/worker.lock"
exit 0
EOF
# --- mock claude: --tools → 최종 리뷰어(항상 APPROVE) / --permission-mode → 편집 역할(스키마 있으면 claude 워커, 없으면 수정자) ---
# unit 별 리뷰어는 존재하지 않는다 — 리뷰어 호출 프롬프트에 unit JSON 이 들어 있으면 unit 리뷰로 보고 즉시 실패시킨다.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
is_reviewer=0; is_editor=0; schema=""; prompt=""; session_flag=""
while [ "$#" -gt 0 ]; do case "$1" in --tools) is_reviewer=1; shift 2;; --permission-mode) is_editor=1; shift 2;; --json-schema) schema="$2"; shift 2;; --session-id|--resume) session_flag="$1"; shift 2;; -p|--model|--effort|--output-format|--allowedTools|--disallowedTools|--append-system-prompt) [ "$1" = -p ] && shift || shift 2;; *) prompt="$1"; shift;; esac; done
usage='"session_id":"fake","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
if [ "$is_reviewer" = 1 ]; then
  if printf '%s' "$schema" | grep -q '"unit_id"'; then
    echo "UNIT-REVIEWER-CALLED" >> "$MOCK_LOG"; exit 1
  fi
  echo "final-review" >> "$MOCK_LOG"
  printf '{"structured_output":{"schema_version":%s,"verdict":"APPROVE","issues":[]},%s}' "$MOCK_REVIEW_CONTRACT" "$usage"
elif [ "$is_editor" = 1 ]; then
  unit="$(printf '%s' "$prompt" | grep -oE '"id": *"[0-9]+-[a-z0-9-]+"' | head -1 | sed -E 's/.*"([0-9]+-[a-z0-9-]+)"/\1/')"
  if [ -n "$schema" ]; then
    # claude 로 라우팅된 워커 (사례 T): 세션 플래그만 기록하고 DONE
    echo "claude-worker $unit $session_flag" >> "$MOCK_LOG"
    n="${unit%%-*}"; echo "claude worker $unit" >> "src/u$n.txt"
    printf '{"structured_output":{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}},%s}' "$usage"
  else
    echo "fixer ${unit:-none}" >> "$MOCK_LOG"
    printf '{"result":"ok",%s}' "$usage"
  fi
fi
EOF
chmod +x "$TMP/bin/codex" "$TMP/bin/claude"
export MOCK_REVIEW_CONTRACT="$REVIEW_CONTRACT"

# --- 합의 PASS 픽스처: 가짜 PASS 리뷰를 두고 합의 루프를 돌려 체크포인트를 만든다 (codex 검증자는 아무것도 쓰지 않는다) ---
fake_pass() { # design|impl
  printf '{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}\n' "$CONTRACT" > ".agent-work/reviews/validator-$1-round-01.json"
  bash .claude/skills/feature/scripts/consensus-loop.sh "$1" > "$TMP/consensus-$1.log" 2>&1 || { cat "$TMP/consensus-$1.log"; fail "픽스처: $1 합의 PASS 체크포인트 생성 실패"; }
}
fake_pass design; fake_pass impl
restore_units() { write_units; fake_pass impl; }   # manifest 원복 + impl PASS 지문 재동기화
run_runner() { # → exit code, 로그 $TMP/run.log
  : > "$MOCK_LOG"
  bash "$RUN" > "$TMP/run.log" 2>&1; echo $?
}
reason() { jq -r '.reason' .agent-work/run-state.json; }
status() { jq -r '.status' .agent-work/run-state.json; }
seq_of() { grep -E "$1" "$MOCK_LOG" | paste -sd' ' -; }
reset_tree() { # 소스 파일을 기준선으로, unit 산출물·lock·체크포인트를 치운다 (테스트 환경 정리 — 파이프라인 동작 아님)
  git checkout -q -- src; rm -rf src/gen
  rm -f "$MOCK_STATE"/ctx-*.txt
  rm -rf .agent-work/units .agent-work/implementation-context.json .agent-work/implementation-units.lock.json .agent-work/feature-scope.lock.json .agent-work/worker-baseline.tree .agent-work/worker-baseline.guard.json \
    .agent-work/worker-result.json .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/reviews/impl-attempt-* .agent-work/.session-*
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
}

# ===== 사례 A/B/G/J: 정상 경로 — 01→02→03 직렬, 겹침 없음, unit 마다 worker → targeted test 만, 이후 final review → verify → DONE =====
reset_tree
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -30 "$TMP/run.log"; fail "A: exit 0 기대, 실제 $rc"; }
[ "$(status)" = DONE ] || fail "A: run-state DONE 아님 ($(status))"
[ "$(seq_of '^worker ')" = "worker 01-intake worker 02-drop worker 03-reassign" ] || fail "A: 워커 호출 순서가 01→02→03 이 아님: $(seq_of '^worker ')"
grep -q 'CONCURRENT WORKER' "$MOCK_LOG" && fail "B: 워커가 동시에 실행됨"
expected_seq="worker 01-intake|test-01|worker 02-drop|test-02|worker 03-reassign|test-03|final-review|full-test|full-lint"
[ "$(paste -sd'|' "$MOCK_LOG")" = "$expected_seq" ] || fail "A/G/J: 호출 순서 불일치:\n  실제: $(paste -sd'|' "$MOCK_LOG")\n  기대: $expected_seq"
grep -q 'UNIT-REVIEWER-CALLED\|^fixer ' "$MOCK_LOG" && fail "G: unit 사이에 리뷰어/수정자가 호출됨"
[ "$(grep -c '^final-review' "$MOCK_LOG")" -eq 1 ] || fail "G: 전체 리뷰어 호출이 1회가 아님"
for u in 01-intake 02-drop 03-reassign; do
  d=".agent-work/units/$u"
  [ -f "$d/done.json" ] && [ -f "$d/before.tree" ] && [ -f "$d/worker-before.tree" ] && [ -f "$d/worker-after.tree" ] && [ -f "$d/worker-result.json" ] && [ -f "$d/targeted-test.log" ] || fail "A: $u 체크포인트 파일 누락"
  jq -e '.version==1 and .worker_status=="DONE" and .targeted_test_status=="PASS" and (has("convention_status")|not)' "$d/done.json" >/dev/null || fail "A: $u done.json 계약 불일치"
  ls "$d" | grep -q 'convention' && fail "G: $u 에 convention 산출물이 생김"
done
[ "$(tail -1 src/shared.txt)" = "shared by 02-drop" ] && grep -q 'shared by 01-intake' src/shared.txt || fail "A: 같은 파일의 순차 수정이 누적되지 않음"
jq -e '.status=="DONE" and (.delegated_choices|length)==3' .agent-work/worker-result.json >/dev/null || fail "J: 전체 review 용 worker-result.json 이 unit 결과를 합치지 않음"
[ -f .agent-work/implementation-units.lock.json ] || fail "E: lock 이 확정되지 않음"
pass "A/B/G/J: 01→02→03 직렬, 겹침 없음, unit 마다 worker→targeted test 만(리뷰어 0회), 전체 완료 후 final review 1회→verify→DONE"

# ===== 사례 X-A/D/E: rolling context — 01 의 fact 가 02 프롬프트에, 같은 키 upsert 는 replace, remove 는 03 에 전달되지 않음 (추가 호출 없음: 위 expected_seq 그대로) =====
CTX=.agent-work/implementation-context.json
grep -q '"facts": \[\]' "$MOCK_STATE/ctx-worker-01.txt" || fail "X-A: Unit 01 워커는 빈 context 를 받아야 함: $(cat "$MOCK_STATE/ctx-worker-01.txt")"
grep -q '01-note' "$MOCK_STATE/ctx-worker-02.txt" && grep -q 'InquiryService.assignInitialAgent' "$MOCK_STATE/ctx-worker-02.txt" || fail "X-A: Unit 02 프롬프트에 Unit 01 확정 fact 가 없음"
grep -q '"source_unit": "01-intake"' "$MOCK_STATE/ctx-worker-02.txt" || fail "X-A: fact 에 source_unit 이 없음"
grep -q '02-note' "$MOCK_STATE/ctx-worker-03.txt" && grep -q '"vl"' "$MOCK_STATE/ctx-worker-03.txt" || fail "X-D: Unit 03 프롬프트에 Unit 02 의 fact 가 없음"
grep -q '01-note' "$MOCK_STATE/ctx-worker-03.txt" && fail "X-D: 같은 (kind,subject) upsert 가 replace 되지 않고 옛 note 가 남음"
grep -q 'assignInitialAgent' "$MOCK_STATE/ctx-worker-03.txt" && fail "X-E: remove 된 fact 가 Unit 03 에 전달됨"
jq -e '.version==1 and .completed_units==["01-intake","02-drop","03-reassign"] and (.facts|length)==2
  and ([.facts[]|select(.kind=="REUSE" and .subject=="InquiryStatus.isAssignable")]|length)==1
  and (.facts[]|select(.kind=="REUSE")|.note=="02-note" and .source_unit=="02-drop")' "$CTX" >/dev/null \
  || fail "X-D: implementation-context.json 이 수렴하지 않음(중복 append 또는 remove 미적용): $(cat "$CTX")"
for u in 01-intake 02-drop 03-reassign; do
  jq -e --arg u "$u" '.version==1 and .unit_id==$u and (.updates|length)==1 and .updates[0].source=="worker"' ".agent-work/units/$u/context-updates.json" >/dev/null || fail "X-A: $u context-updates.json 계약 불일치"
done
jq -e '.context_updates=={upsert:[],remove:[]}' .agent-work/worker-result.json >/dev/null || fail "X-A: 합친 worker-result.json 에 빈 context_updates 가 없음"
pass "X-A/D/E: 01 fact → 02 프롬프트 / 같은 키 replace / remove 미전달 / 추가 모델 호출 없음"

# ===== 사례 C: Unit 01 이 USER_DECISION → exit 2 UNDECIDED, Unit 02 미호출 =====
reset_tree; touch "$MOCK_STATE/undecided-01"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] || { tail -20 "$TMP/run.log"; fail "C: exit 2/UNDECIDED 기대, 실제 $rc/$(reason)"; }
grep -q 'worker 02-drop' "$MOCK_LOG" && fail "C: Unit 01 실패인데 Unit 02 가 호출됨"
[ ! -f .agent-work/units/01-intake/done.json ] || fail "C: 실패한 unit 에 done.json 이 생김"
rm -f "$MOCK_STATE/undecided-01"
pass "C: Unit 01 UNDECIDED → 중단, Unit 02 미호출"

# ===== 사례 D: Unit 03 워커 실패(exit 7) 후 재실행 → 03 부터 재개, 01/02 워커 재호출 없음 =====
reset_tree; touch "$MOCK_STATE/crash-03"
rc="$(run_runner)"
[ "$rc" -eq 1 ] || { tail -20 "$TMP/run.log"; fail "D: 1차 exit 1 기대, 실제 $rc"; }
[ -f .agent-work/units/01-intake/done.json ] && [ -f .agent-work/units/02-drop/done.json ] && [ ! -f .agent-work/units/03-reassign/done.json ] || fail "D: 1차 체크포인트 상태 불일치"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "D: 재실행 exit 0 기대, 실제 $rc"; }
[ "$(seq_of '^worker ')" = "worker 03-reassign" ] || fail "D: 재실행이 03 부터 재개되지 않음: $(seq_of '^worker ')"
grep -q 'test-01\|test-02' "$MOCK_LOG" && fail "D: 완료된 unit 의 targeted test 가 다시 실행됨"
grep -q '02-note' "$MOCK_STATE/ctx-worker-03.txt" && grep -q '"vl"' "$MOCK_STATE/ctx-worker-03.txt" && ! grep -q 'assignInitialAgent' "$MOCK_STATE/ctx-worker-03.txt" \
  || fail "X-F: 재개된 Unit 03 프롬프트에 01/02 의 확정 rolling context 가 없음: $(cat "$MOCK_STATE/ctx-worker-03.txt")"
jq -e '.completed_units==["01-intake","02-drop","03-reassign"]' .agent-work/implementation-context.json >/dev/null || fail "X-F: 03 완료 후 context 가 갱신되지 않음"
pass "D: 중단 후 재실행은 첫 미완료 unit(03) 부터, 01/02 재호출 없음 / X-F: 01/02 rolling context 가 03 에 전달"

# ===== 사례 D2: 앞 unit(02) 무효화 + 뒤 unit(03) 완료 체크포인트 → UNIT_CHECKPOINT_CHAIN_STALE, 사용자 정리 후 02→03 재실행 =====
reset_tree; rc="$(run_runner)"; [ "$rc" -eq 0 ] || fail "D2: 전제 실행 실패"
jq '.spec_hash="stale"' .agent-work/units/02-drop/done.json > "$TMP/d.tmp" && mv "$TMP/d.tmp" .agent-work/units/02-drop/done.json
# 무효화된 02 체크포인트의 context-updates 에 STALE fact 를 심는다 — 재실행이 이를 조용히 재사용하면 안 된다
jq '.updates[0].upsert += [{"kind":"INVARIANT","subject":"STALE","note":"stale"}]' .agent-work/units/02-drop/context-updates.json > "$TMP/c.tmp" && mv "$TMP/c.tmp" .agent-work/units/02-drop/context-updates.json
rm -f "$MOCK_STATE"/ctx-*.txt
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
rm -f .agent-work/worker-result.json .agent-work/approved.fingerprint .agent-work/review-impl.json
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_CHECKPOINT_CHAIN_STALE ] || { tail -20 "$TMP/run.log"; fail "D2: exit 2/UNIT_CHECKPOINT_CHAIN_STALE 기대, 실제 $rc/$(reason)"; }
grep -q '^worker \|^test-' "$MOCK_LOG" && fail "D2: chain stale 인데 워커/targeted test 가 호출됨: $(paste -sd'|' "$MOCK_LOG")"
grep -q '03-reassign' .agent-work/run-state.json && grep -q "$(cat .agent-work/units/02-drop/before.tree)" .agent-work/run-state.json || fail "D2: detail 에 뒤 unit 목록과 02 의 before.tree 가 없음"
[ "$(tail -1 src/u03.txt)" = "worker 03-reassign" ] || fail "D2: 뒤 unit 의 코드가 자동 원복됨(보존돼야 함)"
[ -f .agent-work/units/03-reassign/done.json ] || fail "D2: 뒤 unit 체크포인트를 러너가 지움(사용자 몫)"
# 사용자 정리: worktree 를 02 시작 시점으로, 03 체크포인트 제거 → 재실행은 02 → 03 순서
git checkout -q "$(cat .agent-work/units/02-drop/before.tree)" -- src; rm -rf src/gen .agent-work/units/03-reassign
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "D2: 정리 후 재실행 exit 0 기대, 실제 $rc"; }
[ "$(seq_of '^worker ')" = "worker 02-drop worker 03-reassign" ] || fail "D2: 정리 후 02→03 순서로 재실행돼야 함: $(seq_of '^worker ')"
grep -q 'STALE' "$MOCK_STATE/ctx-worker-02.txt" && fail "X-G: 무효화된 체크포인트의 context 가 02 재실행 프롬프트에 재사용됨"
grep -q '01-note' "$MOCK_STATE/ctx-worker-02.txt" || fail "X-G: 02 재실행 프롬프트에 유효한 01 context 가 없음"
jq -e '(.facts|map(.subject)|index("STALE"))==null and .completed_units==["01-intake","02-drop","03-reassign"]' .agent-work/implementation-context.json >/dev/null \
  || fail "X-G: 재실행 뒤 context 에 STALE fact 가 남거나 완료 목록이 틀림: $(cat .agent-work/implementation-context.json)"
pass "D2: 앞 unit 무효화+뒤 unit 완료 → UNIT_CHECKPOINT_CHAIN_STALE(워커 0회, 원복 없음), 정리 후 02→03 / X-G: 무효 체크포인트의 context-updates 미재사용"

# ===== 사례 E: lock 이후 원본 manifest 변경 → impl 재합의를 거쳐도 lock≠원본이면 워커 0회로 중단 =====
reset_tree; touch "$MOCK_STATE/crash-03"; rc="$(run_runner)"; [ "$rc" -eq 1 ] || fail "E: 전제(03 중단) 실패"
jq '.units[2].goal="changed"' .agent-work/implementation-units.json > "$TMP/u.tmp" && mv "$TMP/u.tmp" .agent-work/implementation-units.json
rc="$(run_runner)"   # 원본 변경 → impl PASS 무효 → impl 재합의(가짜 검증자는 쓰지 않으므로 기존 PASS 파일 재사용) → worker 진입 시 lock 불일치
[ "$rc" -eq 2 ] && [ "$(reason)" = UNITS_MANIFEST_CHANGED ] || { tail -20 "$TMP/run.log"; fail "E: exit 2/UNITS_MANIFEST_CHANGED 기대, 실제 $rc/$(reason)"; }
grep -q '^worker ' "$MOCK_LOG" && fail "E: manifest 불일치인데 워커가 호출됨"
grep -q 'consensus-loop impl' "$TMP/run.log" || fail "E: 원본 manifest 변경이 impl 재합의를 거치지 않음"
# lock 을 지우고 재실행하면 새 lock 으로 03 부터 재개 (01/02 spec 은 그대로)
rm -f .agent-work/implementation-units.lock.json
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "E: lock 제거 후 재실행 exit 0 기대, 실제 $rc"; }
[ "$(seq_of '^worker ')" = "worker 03-reassign" ] || fail "E: lock 제거 후 spec 이 바뀐 03 만 실행돼야 함: $(seq_of '^worker ')"
restore_units
pass "E: lock≠원본 → UNITS_MANIFEST_CHANGED(워커 0회), lock 제거 후 새 lock 으로 재개"

# ===== 사례 E2: unit 워커 호출 중 manifest 가 바뀌면 중단 =====
reset_tree
cat > "$TMP/bin/codex-tamper" <<EOF
#!/usr/bin/env bash
jq '.units[0].title += "x"' .agent-work/implementation-units.json > .agent-work/u.tmp && mv .agent-work/u.tmp .agent-work/implementation-units.json
exec "$TMP/bin/codex" "\$@"
EOF
chmod +x "$TMP/bin/codex-tamper"
sed -i.bak "s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex-tamper\"|" "$CFG" && rm -f "$CFG.bak"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNITS_MANIFEST_CHANGED ] || { tail -20 "$TMP/run.log"; fail "E2: exit 2/UNITS_MANIFEST_CHANGED 기대, 실제 $rc/$(reason)"; }
grep -q 'test-01' "$MOCK_LOG" && fail "E2: manifest 변경 후 targeted test 로 진행함"
sed -i.bak "s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|" "$CFG" && rm -f "$CFG.bak"
restore_units
pass "E2: 워커 호출 중 manifest 변경 → 중단, targeted test 미진입"

# ===== 사례 F: unit 워커가 unit scope 밖(전체 범위 안) 수정 → UNIT_SCOPE_VIOLATION, 원복 없음, 다음 unit 미호출 =====
reset_tree; touch "$MOCK_STATE/unitscope-01"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_SCOPE_VIOLATION ] || { tail -20 "$TMP/run.log"; fail "F: exit 2/UNIT_SCOPE_VIOLATION 기대, 실제 $rc/$(reason)"; }
grep -q 'src/u03.txt' .agent-work/run-state.json || fail "F: 위반 경로(src/u03.txt)가 detail 에 없음"
[ "$(tail -1 src/u03.txt)" = "unit-scope leak by 01-intake" ] || fail "F: unit scope 밖 변경이 원복됨(보존돼야 함)"
grep -q 'worker 02-drop\|test-01' "$MOCK_LOG" && fail "F: 위반 후 targeted test 또는 다음 unit 이 실행됨"
rm -f "$MOCK_STATE/unitscope-01"
# 전체 범위 밖은 기존 SCOPE_VIOLATION 이 먼저 잡는다
reset_tree; touch "$MOCK_STATE/outside-01"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = SCOPE_VIOLATION ] || fail "F: 전체 범위 밖 변경이 SCOPE_VIOLATION 으로 잡히지 않음 ($rc/$(reason))"
rm -f "$MOCK_STATE/outside-01"
pass "F: unit scope 밖 → UNIT_SCOPE_VIOLATION(원복 없음, 다음 unit 미호출) / 전체 범위 밖 → SCOPE_VIOLATION"

# ===== 사례 I: targeted test 실패 → unit-scoped fix → 재테스트 (리뷰어·수정자 미호출) =====
reset_tree; touch "$MOCK_STATE/fail-test-01"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "I: exit 0 기대, 실제 $rc"; }
[ "$(seq_of '01-intake|test-01')" = "worker 01-intake test-01 test-fix 01-intake test-01" ] \
  || fail "I: unit 01 흐름 불일치: $(seq_of '01-intake|test-01')"
grep -q 'test-fix 01-intake' src/u01.txt || fail "I: test fix 변경이 반영되지 않음"
grep -q 'UNIT-REVIEWER-CALLED\|^fixer ' "$MOCK_LOG" && fail "I: test fix 경로에서 리뷰어/수정자가 호출됨"
grep -q '01-note' "$MOCK_STATE/ctx-test-fix-01.txt" && fail "X-C: test-fix 프롬프트에 확정 전(pending) 01 fact 가 들어감"
grep -q 'fixed-note' "$MOCK_STATE/ctx-worker-02.txt" || fail "X-C: fix 가 정정한 note 가 Unit 02 에 전달되지 않음"
grep -q '01-note' "$MOCK_STATE/ctx-worker-02.txt" && fail "X-C: fix 이전 note 가 Unit 02 에 남음"
jq -e '(.updates|map(.source))==["worker","test-fix-01"]' .agent-work/units/01-intake/context-updates.json >/dev/null || fail "X-C: context-updates.json 이 worker → test-fix 순서를 보존하지 않음"
# 재시도 소진: 두 번 연속 실패 (MAX_TEST_RETRIES=1)
reset_tree; touch "$MOCK_STATE/fail-test-01"
cat > "$TMP/bin/test-01-always-fail" <<EOF
#!/usr/bin/env bash
echo test-01 >> "$MOCK_LOG"; exit 1
EOF
chmod +x "$TMP/bin/test-01-always-fail"
sed -i.bak "s|$TMP/bin/test-01\"|$TMP/bin/test-01-always-fail\"|" .agent-work/implementation-units.json && rm -f .agent-work/implementation-units.json.bak
fake_pass impl
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNIT_TEST_RETRIES_EXHAUSTED ] || { tail -20 "$TMP/run.log"; fail "I: exit 2/UNIT_TEST_RETRIES_EXHAUSTED 기대, 실제 $rc/$(reason)"; }
[ "$(grep -c '^test-fix 01' "$MOCK_LOG")" -eq 1 ] || fail "I: test fix 가 MAX_TEST_RETRIES(1)회를 넘어 호출됨"
grep -q 'worker 02' "$MOCK_LOG" && fail "I: 재시도 소진인데 다음 unit 이 호출됨"
[ ! -f .agent-work/units/01-intake/context-updates.json ] || fail "X-B: targeted test 실패 unit 의 context-updates 가 확정됨"
jq -e '.completed_units==[] and .facts==[]' .agent-work/implementation-context.json >/dev/null || fail "X-B: 실패한 unit 의 fact 가 implementation-context.json 에 들어감"
restore_units; rm -f "$MOCK_STATE/fail-test-01"
pass "I: targeted test 실패 → fix → 재테스트(리뷰어 0회) / 재시도 소진 → 사용자 반환"

# ===== 사례 K: implementation-units.json 변경 시 impl consensus PASS 무효 =====
reset_tree
( source "$CFG"; consensus_pass_current impl ) || fail "K: 전제 — 현재 impl PASS 가 유효하지 않음"
cp .agent-work/implementation-units.json "$TMP/units.keep"
jq '.units[0].goal="edited"' "$TMP/units.keep" > .agent-work/implementation-units.json
( source "$CFG"; consensus_pass_current impl ) && fail "K: units manifest 가 바뀌었는데 impl PASS 가 유효함"
cp "$TMP/units.keep" .agent-work/implementation-units.json
( source "$CFG"; consensus_pass_current impl ) || fail "K: 되돌렸는데 impl PASS 가 복구되지 않음"
# 러너도 impl 부터 다시 간다 (units 없으면 IMPL_DOCS_MISSING)
mv .agent-work/implementation-units.json "$TMP/units.moved"
rc="$(run_runner)"
[ "$rc" -eq 3 ] && [ "$(reason)" = IMPL_DOCS_MISSING ] || fail "K: units 파일 없을 때 NEED_DOCS/IMPL_DOCS_MISSING 이 아님 ($rc/$(reason))"
mv "$TMP/units.moved" .agent-work/implementation-units.json
pass "K: units manifest 변경 → impl PASS 무효 / 부재 → IMPL_DOCS_MISSING"

# ===== 사례 S: manifest 검증 — 스키마 위반·중복 id·순번·부분집합 =====
units_ok() { ( source "$CFG"; units_manifest_valid_file .agent-work/implementation-units.json ); }
units_ok || fail "S: 정상 manifest 가 무효로 판정됨"
bad_cases=(
  '.version=2'
  '.units=[]'
  '.units[0].id="01-intake" | .units[1].id="01-intake"'
  '.units[0].id="02-intake" | .units[1].id="01-drop"'
  '.units[0].id="intake"'
  '.units[0].requirements=[]'
  '.units[0].references=[]'
  '.units[0].targeted_test=""'
  '.units[0].depends_on=[]'
  '.units[0].priority=1'
  '.units[0].parallel=true'
  '.units[0].scope={"files":[]}'
  '.units[0].scope.files=["./src/u01.txt"]'
  '.units[0].extra=1'
  '.extra=1'
  'del(.units[0].goal)'
)
for expr in "${bad_cases[@]}"; do
  jq "$expr" "$TMP/units.keep" > .agent-work/implementation-units.json
  units_ok && fail "S: 잘못된 manifest 가 유효로 통과함: $expr"
done
cp "$TMP/units.keep" .agent-work/implementation-units.json
# 스키마 파일 자체가 계약을 담는다
SCHEMA=".claude/skills/feature/schemas/implementation-units.schema.json"
jq -e '.additionalProperties==false and .properties.version.const==1 and .properties.units.minItems==1 and .properties.units.items.additionalProperties==false
  and (.properties.units.items.required|index("targeted_test")) and (.properties.units.items.properties|has("depends_on")|not) and (.properties.units.items.properties|has("priority")|not)' "$SCHEMA" >/dev/null \
  || fail "S: implementation-units.schema.json 계약 불일치"
# unit scope 가 전체 범위 밖이면 워커 진입 전에 NEED_DOCS (워커 0회)
reset_tree
jq '.units[0].scope.files += ["src/outside.txt"]' "$TMP/units.keep" > .agent-work/implementation-units.json; fake_pass impl
rc="$(run_runner)"
[ "$rc" -eq 3 ] && [ "$(reason)" = IMPL_DOCS_MISSING ] || { tail -10 "$TMP/run.log"; fail "S: 전체 범위 밖 unit scope 가 NEED_DOCS 로 막히지 않음 ($rc/$(reason))"; }
grep -q '^worker ' "$MOCK_LOG" && fail "S: 부분집합 위반인데 워커가 호출됨"
grep -q 'src/outside.txt' .agent-work/run-state.json || fail "S: 부분집합 위반 경로가 detail 에 없음"
cp "$TMP/units.keep" .agent-work/implementation-units.json; fake_pass impl
pass "S: manifest 스키마·중복·순번·금지 필드·부분집합 검증"

# ===== 사례 T: claude 로 라우팅된 워커는 unit 마다 fresh 세션 =====
reset_tree
sed -i.bak 's/^WORKER_MODEL=.*/WORKER_MODEL="claude-worker-x"/' "$CFG" && rm -f "$CFG.bak"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "T: exit 0 기대, 실제 $rc"; }
[ "$(seq_of '^claude-worker ')" = "claude-worker 01-intake --session-id claude-worker 02-drop --session-id claude-worker 03-reassign --session-id" ] \
  || fail "T: unit 워커가 fresh 세션이 아님: $(seq_of '^claude-worker ')"
pass "T: claude 워커도 unit 마다 --session-id (fresh)"

echo "[SMOKE] 전부 통과 — 임시 저장소: $TMP (필요 없으면 직접 정리)"
