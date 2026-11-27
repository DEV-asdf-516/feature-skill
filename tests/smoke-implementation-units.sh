#!/usr/bin/env bash
# =============================================================
# 스모크: 구현 단위(implementation unit) 직렬 실행 — 실제 LLM 호출 없음 (공용 mock CLI: 역할은 스키마로 판별, 모델→CLI 매핑 무관), 임시 저장소
# 파일 경로: tests/smoke-implementation-units.sh
# 사용법: bash tests/smoke-implementation-units.sh   (어디서든 실행 가능)
#
# 사례:
#   A. units 가 01 → 02 → 03 순서로만 호출된다
#   B. 동시에 워커가 둘 이상 실행되지 않는다 (호출 겹침 감지)
#   C. Unit 01 실패(USER_DECISION) 시 Unit 02 는 호출되지 않는다
#   D. Unit 01/02 완료 후 러너 재실행 시 Unit 03 부터 재개한다 (01/02 워커 재호출 없음) — 03 의 실패는 변경 없는 실행 실패(exit 7, 결과 없음)
#   E. unit manifest 가 lock 이후 변경되면 워커 호출 0회로 중단한다 (UNITS_MANIFEST_CHANGED)
#   F. unit 워커가 자기 unit scope 밖(전체 범위 안)을 수정하면 다음 unit 으로 가지 않는다 (UNIT_SCOPE_VIOLATION, 원복 없음)
#   G. unit 사이에는 리뷰어·수정자 호출이 없다 — 리뷰어 호출은 모든 unit 뒤 전체 review 한 번뿐
#   I. targeted test 실패 시 unit 범위 수정 → 재테스트(리뷰어 미호출), 재시도 소진 시 사용자 반환
#   J. 모든 unit 완료 후에만 기존 전체 review → verify(TEST_CMD/LINT_CMD) → DONE 으로 진입한다
#   K. implementation-units.json 변경 시 기존 impl consensus PASS 가 무효가 된다
#   S. manifest 스키마·부분집합 검사
#   T. 워커는 Feature 당 단일 세션 — Unit 3개에 세션 ID 1개, 01 은 --session-id, 02/03 은 같은 ID 로 --resume (저널 worker-session.json 일치)
#   I-S. targeted test 실패의 수정 호출도 같은 세션의 --resume 다
#   U. 워커 응답 직후·targeted test 직전 중단 — 유효한 결과 + after-tree 일치면 CLI 재호출 없이 테스트부터 재개
#   V. 세션 전제(모델·세션 파일) 불일치 → 자동 resume·자동 fresh 금지(모델 호출 0회), 복구 후에만 같은 세션 재개
#   W. 예전 fresh-워커 실행 잔존 → WORKER_SESSION_MISSING(묵시적 마이그레이션 금지), worker-session.migrate 후에만 새 세션 재개
#   R. 관측 토큰 임계치 도달 → unit 경계에서만 결정론적 세션 교체(worker-handoff.json 스키마·지문·tree 검증, test-fix 는 교체 지점 아님)
#   Y. codex 워커도 Feature 당 세션 1 thread — thread_id 는 원장(.session-feature-worker.codex.json)에만, 저널은 session_bound 만;
#      원장 소실(bound=true)·원장 존재+미결속(bound=false) 모두 WORKER_SESSION_MISMATCH 로 fail-closed(자동 fresh 금지)
#   X. unit 간 rolling implementation context (별도 모델 호출 없음, 러너가 upsert/remove 를 (kind,subject) 키로 fold):
#      X-A. Unit 01 PASS 후 Unit 02 워커 프롬프트에 01 의 확정 fact 가 들어간다
#      X-B. Unit 01 targeted test 가 끝내 실패하면 01 의 context 는 확정되지 않는다
#      X-C. test-fix 후 PASS 면 워커 → fix 순서로 fold 한 결과(fix 가 정정한 note)가 Unit 02 에 간다
#      X-D. 같은 (kind,subject) upsert 는 append 가 아니라 replace — facts 가 unit 수에 비례해 늘지 않는다
#      X-E. remove 된 fact 는 다음 워커에게 가지 않는다
#      X-F. 01/02 완료 후 03 부터 재개해도 01/02 의 rolling context 가 03 에 전달된다
#      X-G. spec_hash 로 무효화된 unit 체크포인트의 context-updates 는 조용히 재사용되지 않는다
#   P. 워커 규칙 원문 전달 범위(GOAL-44) — 최초 unit(fresh)=전문 / 같은 unit 의 test-fix=짧은 불변식+원문 경로만 / 후속 unit 첫 턴=전문 재전달 /
#      러너 재실행 뒤 첫 턴=전문 재전달 / 압축 관측 뒤 다음 턴=전문 재전달 / handoff 뒤 fresh 세대=전문 / conventions 변경=현재 파일 내용.
#      어느 경우에도 세션은 그대로 resume(재전달 때문에 fresh 세션을 만들지 않음), 규칙 변경은 기존 게이트대로 멈춘다
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
LOADER="$TMP/repo/.claude/skills/feature/scripts/lib/bootstrap.sh"
RUNTIME_LIB="$TMP/repo/.claude/skills/feature/scripts/lib/runtime.sh"
sed -i.bak "s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"legacy_cli\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"echo full-test >> $TMP/calls.log\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"echo full-lint >> $TMP/calls.log\"|" "$CFG" && rm -f "$CFG.bak"
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && for u in 01 02 03; do echo "base $u" > "src/u$u.txt"; done; echo "shared base" > src/shared.txt; echo "outside base" > src/outside.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
printf '\n## 01\nunit 01 contract\n\n## 02\nunit 02 contract\n\n## 03\nunit 03 contract\n' >> .agent-work/implementation.md   # unit references(implementation.md#NN)가 가리키는 절 — 러너가 그 절 본문으로 unit 별 계약 변경을 판정한다
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/u01.txt","src/u02.txt","src/u03.txt","src/shared.txt"],"new_file_roots":["src/gen/"]}\n' > .agent-work/feature-scope.json
RUN=".claude/skills/feature/scripts/feature-run.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$RUNTIME_LIB" | cut -d= -f2 | cut -d' ' -f1)"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$RUNTIME_LIB" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" FEATURE_LIVE_TEE=1 MOCK_VALIDATOR_CONTRACT="$CONTRACT"
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

# --- 공용 mock CLI: bin/claude 와 bin/codex 는 같은 스크립트의 사본이다 ---
# 역할(검증자·리뷰어·워커·수정자)은 호출된 CLI 가 아니라 **스키마 내용**으로 판별한다. production config 의 모델→CLI 매핑
# (REVIEWER_MODEL/VALIDATOR_MODEL/WORKER_MODEL 이 claude 든 codex 든)을 전제하지 않으므로 사용자가 역할별 모델을 바꿔도 깨지지 않는다.
#   spec-review 스키마(blocking_issues) → 검증자 PASS / impl-review 스키마(issues) → 최종 리뷰어 APPROVE
#   worker-result 스키마(context_updates) → 워커(unit id 는 프롬프트에서) / 스키마 없는 편집 호출 → 수정자
#   unit_id 스키마 → 존재하지 않는 unit 리뷰어이므로 즉시 실패
# 출력 규약만 CLI 별로 다르다: codex 는 -o 경로에 JSON, claude 는 stdout 에 {"structured_output":…, usage}.
cat > "$TMP/bin/mock-cli" <<'EOF'
#!/usr/bin/env bash
cli="$(basename "$0")"   # claude | codex — 출력 규약 선택에만 쓴다
outfmt=""
out=""; schema=""; prompt=""; session_flag=""; session_value=""; editing=0; resume_tid=""; want_help=0
while [ "$#" -gt 0 ]; do case "$1" in
  exec|-p) shift;;
  resume) if [ "$2" = "--help" ]; then want_help=1; else resume_tid="$2"; fi; shift 2;;   # codex: exec resume <thread-id> | exec resume --help
  --help) want_help=1; shift;;
  -o) out="$2"; shift 2;;
  --output-schema) schema="$(cat "$2")"; shift 2;;            # codex: 스키마 파일 경로
  --json-schema) schema="$2"; shift 2;;                         # claude: 스키마 본문
  --sandbox) [ "$2" = workspace-write ] && editing=1; shift 2;;
  --permission-mode) editing=1; shift 2;;
  --session-id|--resume) session_flag="$1"; session_value="$2"; shift 2;;
  --output-format) outfmt="$2"; shift 2;;
  --verbose) shift;;
  -m|-c|--model|--effort|--tools|--allowedTools|--disallowedTools|--append-system-prompt) shift 2;;
  *) prompt="$1"; shift;;
esac; done
# codex_resume_cli_check 의 `exec resume --help` — resume 계약 플래그를 가진 도움말을 돌려준다
[ "$want_help" = 1 ] && { echo "usage: codex exec resume [--json] [--output-schema] [--output-last-message] [--sandbox]"; exit 0; }
usage='"session_id":"fake","total_cost_usd":0,"num_turns":4,"usage":{"input_tokens":400,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'   # input 400 / 4 turns → input_per_turn 100: 세션 교체 임계치 사례(R)의 관측값 — 기본 임계치(1000000)보다 작아 다른 사례에선 교체되지 않는다
# 실제 codex exec --json 은 첫 이벤트로 thread.started 를 낸다 — 세션 원장(config.sh codex 어댑터)이 이 계약을 읽는다.
# resume 호출이면 같은 thread id 를 돌려준다(codex_session_check_resumed 가 원장과 대조한다).
[ "$cli" = codex ] && printf '{"type":"thread.started","thread_id":"%s"}\n' "${resume_tid:-mock-thread-$$}"
emit() { # 결과 JSON 을 호출된 CLI 의 규약대로 돌려준다
  if [ "$cli" = codex ]; then
    if [ -n "$out" ]; then printf '%s\n' "$1" > "$out"; else printf '%s\n' "$1"; fi
    # 실제 codex exec --json 은 turn.completed.usage 를 낸다 — usage.jsonl 행(input_per_turn 400)이 생겨 사례 Z 의 교체 판단 입력이 된다
    printf '{"type":"turn.completed","usage":{"input_tokens":400,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0}}\n'
  elif [ "${outfmt:-json}" = stream-json ] && [ -f "$MOCK_STATE/stream-ctx" ]; then
    # 실제 claude stream-json: model 호출마다 assistant 메시지(usage), 마지막에 result(= json 출력과 같은 객체). 사례 R2 가 context_last_turn 을 본다
    # stream-ctx: "<context_last_turn> [context_window]" — 창 크기가 있으면 result.modelUsage 에 contextWindow 로 싣는다(실제 claude result 형태)
    read -r sc_ctx sc_win < "$MOCK_STATE/stream-ctx"
    # 사례 P: 실제 claude stream-json 은 컨텍스트 압축 때 system/compact_boundary 이벤트를 낸다 — 플래그가 있으면 이 호출에서 1회 방출
    if [ -f "$MOCK_STATE/compact-next" ]; then rm -f "$MOCK_STATE/compact-next"; printf '{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto"}}\n'; fi
    printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}\n' "$sc_ctx"
    if [ -n "$sc_win" ]; then printf '{"type":"result","structured_output":%s,%s,"modelUsage":{"mock-model":{"contextWindow":%s}}}\n' "$1" "$usage" "$sc_win"
    else printf '{"type":"result","structured_output":%s,%s}\n' "$1" "$usage"; fi
  else
    printf '{"structured_output":%s,%s}\n' "$1" "$usage"
  fi
}
role=""
case "$schema" in
  *'"unit_id"'*) role=unit-reviewer;;
  *'"blocking_issues"'*) role=validator;;
  *'"issues"'*) role=reviewer;;
  *'"context_updates"'*) role=worker;;
  "") [ "$editing" = 1 ] && role=fixer;;
esac
[ -n "$role" ] || { echo "UNKNOWN-ROLE cli=$cli editing=$editing" >> "$MOCK_LOG"; exit 1; }

case "$role" in
  unit-reviewer) echo "UNIT-REVIEWER-CALLED" >> "$MOCK_LOG"; exit 1;;
  validator) emit "{\"schema_version\":$MOCK_VALIDATOR_CONTRACT,\"verdict\":\"PASS\",\"blocking_issues\":[]}"; exit 0;;
  reviewer) echo "final-review" >> "$MOCK_LOG"; emit "{\"schema_version\":$MOCK_REVIEW_CONTRACT,\"verdict\":\"APPROVE\",\"issues\":[]}"; exit 0;;
  fixer)
    unit="$(printf '%s' "$prompt" | grep -oE '"id": *"[0-9]+-[a-z0-9-]+"' | head -1 | sed -E 's/.*"([0-9]+-[a-z0-9-]+)"/\1/')"
    echo "fixer ${unit:-none}" >> "$MOCK_LOG"
    if [ "$cli" = codex ]; then echo ok; else printf '{"result":"ok",%s}\n' "$usage"; fi
    exit 0;;
esac

# ---- 워커 / test-fix (CLI 무관하게 같은 동작) ----
unit="$(printf '%s' "$prompt" | grep -oE '"id": *"[0-9]+-[a-z0-9-]+"' | head -1 | sed -E 's/.*"([0-9]+-[a-z0-9-]+)"/\1/')"
kind=worker; printf '%s' "$prompt" | grep -qE 'targeted-test-[0-9]+\.log' && kind=test-fix   # 수정 프롬프트에만 실패 로그 경로(${TEST_LOG})가 있다
# 동시 실행 감지: 이미 다른 워커가 실행 중이면 즉시 실패
mkdir "$MOCK_STATE/worker.lock" 2>/dev/null || { echo "CONCURRENT WORKER" >> "$MOCK_LOG"; exit 9; }
release() { rmdir "$MOCK_STATE/worker.lock"; }
echo "$kind ${unit:-none}" >> "$MOCK_LOG"
[ "$cli" = claude ] && echo "claude-$kind $unit $session_flag $session_value" >> "$MOCK_LOG.sessions"   # 사례 I/T/U/V/W 전용 계측 — 공용 로그를 오염시키지 않게 분리(워커가 claude 로 라우팅돼도 A/I 순서 비교 유지)
if [ "$cli" = codex ]; then   # 사례 Y 전용 계측
  if [ -n "$resume_tid" ]; then echo "codex-$kind $unit resume $resume_tid" >> "$MOCK_LOG.sessions"; else echo "codex-$kind $unit new" >> "$MOCK_LOG.sessions"; fi
fi
sleep 0.2
n="${unit%%-*}"
# 사례 P: 워커 프롬프트 전문과 규칙 전달 형태(recheck=경계 재전달 / short=짧은 재명시 / fresh=최초 턴 전문)를 호출 순서대로 남긴다
printf '%s' "$prompt" > "$MOCK_STATE/prompt-$kind-$n.txt"
rules_mode=fresh
if printf '%s' "$prompt" | grep -q '^\[RULES RECHECK — '; then rules_mode=recheck
elif printf '%s' "$prompt" | grep -q '최초 턴에 전달된 \[CORE RULES\]'; then rules_mode=short; fi
echo "$kind $n $rules_mode" >> "$MOCK_STATE/rules-seq.log"
[ ! -f "$MOCK_STATE/compact-$kind-$n" ] || { rm -f "$MOCK_STATE/compact-$kind-$n"; : > "$MOCK_STATE/compact-next"; }
# 프롬프트의 [IMPLEMENTATION CONTEXT] 블록을 보존해 사례 X 가 검사한다
printf '%s' "$prompt" | sed -n '/^\[IMPLEMENTATION CONTEXT\]$/,/^\[\/IMPLEMENTATION CONTEXT\]$/p' > "$MOCK_STATE/ctx-$kind-$n.txt"
ctx='{"upsert":[],"remove":[]}'
case "$kind-$n" in
  worker-01) ctx='{"upsert":[{"kind":"REUSE","subject":"TicketStatus.isAssignable","note":"01-note"},{"kind":"ENTRY_POINT","subject":"TicketService.assignInitialAgent","note":"entry"}],"remove":[]}';;
  test-fix-01) ctx='{"upsert":[{"kind":"REUSE","subject":"TicketStatus.isAssignable","note":"fixed-note"}],"remove":[]}';;
  worker-02) ctx='{"upsert":[{"kind":"REUSE","subject":"TicketStatus.isAssignable","note":"02-note"},{"kind":"INVARIANT","subject":"ticket version check","note":"vl"}],"remove":[{"kind":"ENTRY_POINT","subject":"TicketService.assignInitialAgent"}]}';;
esac
case "$kind" in
  worker)
    # 실행 실패(exit 7)는 작업 트리를 바꾸기 전에 낸다 — 변경 뒤 non-zero 는 결과 JSON 이 없으면 WORKER_OUTCOME_UNCERTAIN(자동 재실행 금지)이며 tests/smoke-cli-exit-mismatch.sh 가 본다
    if [ -f "$MOCK_STATE/crash-$n" ]; then rm -f "$MOCK_STATE/crash-$n"; release; exit 7; fi
    [ -n "$unit" ] && echo "worker $unit" >> "src/u$n.txt"
    [ "$n" = 01 ] || [ "$n" = 02 ] && echo "shared by $unit" >> src/shared.txt
    [ "$n" = 02 ] && mkdir -p src/gen && echo "gen by 02" > src/gen/new.txt
    if [ -f "$MOCK_STATE/outside-$n" ]; then echo "outside by $unit" >> src/outside.txt; fi          # 전체 범위 밖
    if [ -f "$MOCK_STATE/unitscope-$n" ]; then echo "unit-scope leak by $unit" >> src/u03.txt; fi   # 전체 범위 안, unit scope 밖 (01/02 에서)
    if [ -f "$MOCK_STATE/undecided-$n" ]; then
      emit "$(printf '{"status":"UNDECIDED","undecided":[{"kind":"USER_DECISION","location":"src/u%s.txt","paths":["src/u%s.txt"],"decision_needed":"policy","options":["a","b"]}],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}' "$n" "$n")"
      release; exit 0
    fi
    emit "$(printf '{"status":"DONE","undecided":[],"delegated_choices":[{"location":"src/u%s.txt","technique":"t","basis":"b"}],"tests":[{"name":"u%s","result":"PASS"}],"context_updates":%s}' "$n" "$n" "$ctx")";;
  test-fix)
    echo "test-fix $unit" >> "src/u$n.txt"
    emit "$(printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":%s}' "$ctx")";;
esac
release
exit 0
EOF
chmod +x "$TMP/bin/mock-cli"
cp "$TMP/bin/mock-cli" "$TMP/bin/claude"; cp "$TMP/bin/mock-cli" "$TMP/bin/codex"
export MOCK_REVIEW_CONTRACT="$REVIEW_CONTRACT"

# --- 합의 PASS 픽스처: 가짜 PASS 리뷰를 두고 합의 루프를 돌려 체크포인트를 만든다 (codex 검증자는 아무것도 쓰지 않는다) ---
fake_pass() { # design|impl — 가짜 검증자가 PASS 를 -o 에 쓴다
  bash .claude/skills/feature/scripts/consensus-loop.sh "$1" > "$TMP/consensus-$1.log" 2>&1 || { cat "$TMP/consensus-$1.log"; fail "픽스처: $1 합의 PASS 체크포인트 생성 실패"; }
}
fake_pass design; fake_pass impl
restore_units() { write_units; fake_pass impl; }   # manifest 원복 + impl PASS 지문 재동기화
run_runner() { # → exit code, 로그 $TMP/run.log
  : > "$MOCK_LOG"; : > "$MOCK_LOG.sessions"
  bash "$RUN" > "$TMP/run.log" 2>&1; echo $?
}
reason() { jq -r '.reason' .agent-work/run-state.json; }
status() { jq -r '.status' .agent-work/run-state.json; }
seq_of() { grep -E "$1" "$MOCK_LOG" | paste -sd' ' -; }
reset_tree() { # 소스 파일을 기준선으로, unit 산출물·lock·체크포인트를 치운다 (테스트 환경 정리 — 파이프라인 동작 아님)
  git checkout -q -- src; rm -rf src/gen
  rm -f "$MOCK_STATE"/ctx-*.txt
  rm -rf .agent-work/units .agent-work/implementation-context.json .agent-work/implementation-units.lock.json .agent-work/feature-scope.lock.json .agent-work/worker-baseline.tree .agent-work/worker-baseline.guard.json \
    .agent-work/worker-result.json .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/reviews/impl-attempt-* .agent-work/.session-* \
    .agent-work/worker-session.json .agent-work/worker-session.migrate* .agent-work/worker-handoff.json .agent-work/usage.jsonl \
    .agent-work/doc-gap-resume.json   # 사례 C 의 UNDECIDED 가 남긴 사용자 대기 체크포인트(tests/smoke-doc-gap.sh 가 검증) — 다음 사례는 pending 없이 시작
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
  jq -e '.version==2 and .worker_status=="DONE" and .targeted_test_status=="PASS" and (.unit_contract_fingerprint|length)>0 and (has("convention_status")|not)' "$d/done.json" >/dev/null || fail "A: $u done.json 계약 불일치"
  [ "$(jq -r .unit_contract_fingerprint "$d/done.json")" = "$(jq -r .fingerprint "$d/contract/contract.json")" ] && [ -f "$d/contract/first/contract.txt" ] && [ -f "$d/worker-contract.json" ] || fail "A: $u 계약 스냅샷(contract/)·worker-contract.json 이 done.json 과 맞지 않음"
  ls "$d" | grep -q 'convention' && fail "G: $u 에 convention 산출물이 생김"
done
[ "$(tail -1 src/shared.txt)" = "shared by 02-drop" ] && grep -q 'shared by 01-intake' src/shared.txt || fail "A: 같은 파일의 순차 수정이 누적되지 않음"
jq -e '.status=="DONE" and (.delegated_choices|length)==3' .agent-work/worker-result.json >/dev/null || fail "J: 전체 review 용 worker-result.json 이 unit 결과를 합치지 않음"
[ -f .agent-work/implementation-units.lock.json ] || fail "E: lock 이 확정되지 않음"
pass "A/B/G/J: 01→02→03 직렬, 겹침 없음, unit 마다 worker→targeted test 만(리뷰어 0회), 전체 완료 후 final review 1회→verify→DONE"

# ===== 사례 X-A/D/E: rolling context — 01 의 fact 가 02 프롬프트에, 같은 키 upsert 는 replace, remove 는 03 에 전달되지 않음 (추가 호출 없음: 위 expected_seq 그대로) =====
CTX=.agent-work/implementation-context.json
grep -q '"facts": \[\]' "$MOCK_STATE/ctx-worker-01.txt" || fail "X-A: Unit 01 워커는 빈 context 를 받아야 함: $(cat "$MOCK_STATE/ctx-worker-01.txt")"
grep -q '01-note' "$MOCK_STATE/ctx-worker-02.txt" && grep -q 'TicketService.assignInitialAgent' "$MOCK_STATE/ctx-worker-02.txt" || fail "X-A: Unit 02 프롬프트에 Unit 01 확정 fact 가 없음"
grep -q '"source_unit": "01-intake"' "$MOCK_STATE/ctx-worker-02.txt" || fail "X-A: fact 에 source_unit 이 없음"
grep -q '02-note' "$MOCK_STATE/ctx-worker-03.txt" && grep -q '"vl"' "$MOCK_STATE/ctx-worker-03.txt" || fail "X-D: Unit 03 프롬프트에 Unit 02 의 fact 가 없음"
grep -q '01-note' "$MOCK_STATE/ctx-worker-03.txt" && fail "X-D: 같은 (kind,subject) upsert 가 replace 되지 않고 옛 note 가 남음"
grep -q 'assignInitialAgent' "$MOCK_STATE/ctx-worker-03.txt" && fail "X-E: remove 된 fact 가 Unit 03 에 전달됨"
jq -e '.version==1 and .completed_units==["01-intake","02-drop","03-reassign"] and (.facts|length)==2
  and ([.facts[]|select(.kind=="REUSE" and .subject=="TicketStatus.isAssignable")]|length)==1
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
# 워커가 어느 CLI 로 라우팅되든 첫 호출에서 탬퍼가 일어나도록 두 CLI 를 모두 감싼다 (impl PASS 픽스처라 첫 호출이 worker 01)
for c in claude codex; do
  cat > "$TMP/bin/$c-tamper" <<EOF
#!/usr/bin/env bash
jq '.units[0].title += "x"' .agent-work/implementation-units.json > .agent-work/u.tmp && mv .agent-work/u.tmp .agent-work/implementation-units.json
exec "$TMP/bin/$c" "\$@"
EOF
  chmod +x "$TMP/bin/$c-tamper"
done
sed -i.bak "s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"legacy_cli\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude-tamper\"|; s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex-tamper\"|" "$CFG" && rm -f "$CFG.bak"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNITS_MANIFEST_CHANGED ] || { tail -20 "$TMP/run.log"; fail "E2: exit 2/UNITS_MANIFEST_CHANGED 기대, 실제 $rc/$(reason)"; }
grep -q 'test-01' "$MOCK_LOG" && fail "E2: manifest 변경 후 targeted test 로 진행함"
sed -i.bak "s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"legacy_cli\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|" "$CFG" && rm -f "$CFG.bak"
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
# I-S: test-fix 는 새 세션이 아니라 같은 Feature Worker 세션의 resume 다 (워커 01 → fix 01 → 워커 02 → 워커 03, 세션 ID 1개)
[ "$(awk '{print $1" "$3}' "$MOCK_LOG.sessions" | paste -sd'|' -)" = "claude-worker --session-id|claude-test-fix --resume|claude-worker --resume|claude-worker --resume" ] \
  || fail "I-S: test-fix/후속 unit 이 같은 세션 resume 이 아님: $(cat "$MOCK_LOG.sessions")"
[ "$(awk '{print $4}' "$MOCK_LOG.sessions" | sort -u | grep -c .)" -eq 1 ] || fail "I-S: 세션 ID 가 하나가 아님: $(cat "$MOCK_LOG.sessions")"
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
( source "$LOADER"; consensus_pass_current impl ) || fail "K: 전제 — 현재 impl PASS 가 유효하지 않음"
cp .agent-work/implementation-units.json "$TMP/units.keep"
jq '.units[0].goal="edited"' "$TMP/units.keep" > .agent-work/implementation-units.json
( source "$LOADER"; consensus_pass_current impl ) && fail "K: units manifest 가 바뀌었는데 impl PASS 가 유효함"
cp "$TMP/units.keep" .agent-work/implementation-units.json
( source "$LOADER"; consensus_pass_current impl ) || fail "K: 되돌렸는데 impl PASS 가 복구되지 않음"
# 러너도 impl 부터 다시 간다 (units 없으면 IMPL_DOCS_MISSING)
mv .agent-work/implementation-units.json "$TMP/units.moved"
rc="$(run_runner)"
[ "$rc" -eq 3 ] && [ "$(reason)" = IMPL_DOCS_MISSING ] || fail "K: units 파일 없을 때 NEED_DOCS/IMPL_DOCS_MISSING 이 아님 ($rc/$(reason))"
mv "$TMP/units.moved" .agent-work/implementation-units.json
pass "K: units manifest 변경 → impl PASS 무효 / 부재 → IMPL_DOCS_MISSING"

# ===== 사례 S: manifest 검증 — 스키마 위반·중복 id·순번·부분집합 =====
units_ok() { ( source "$LOADER"; units_manifest_valid_file .agent-work/implementation-units.json ); }
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

# ===== 사례 T: 워커는 Feature 당 단일 세션 — Unit 3개에 세션 ID 1개, 01 은 --session-id, 02/03 은 같은 ID 로 --resume =====
# (라우팅은 WORKER_CLI 로 명시 고정 — 모델 이름 추론에 의존하지 않는다)
reset_tree
sed -i.bak 's/^WORKER_MODEL=.*/WORKER_MODEL="claude-worker-x"/; s/^WORKER_CLI=.*/WORKER_CLI="claude"/' "$CFG" && rm -f "$CFG.bak"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "T: exit 0 기대, 실제 $rc"; }
sid="$(awk 'NR==1{print $4}' "$MOCK_LOG.sessions")"
[ -n "$sid" ] || fail "T: 세션 ID 계측 없음: $(cat "$MOCK_LOG.sessions")"
t_seq="$(paste -sd' ' "$MOCK_LOG.sessions")"
[ "$t_seq" = "claude-worker 01-intake --session-id $sid claude-worker 02-drop --resume $sid claude-worker 03-reassign --resume $sid" ] \
  || fail "T: Feature 단일 세션(첫 unit --session-id, 이후 같은 ID --resume)이 아님: $t_seq"
[ "$(cat .agent-work/.session-feature-worker)" = "$sid" ] || fail "T: .session-feature-worker 가 확정되지 않음"
jq -e --arg sid "$sid" '.version==1 and .cli=="claude" and .model=="claude-worker-x" and .session_bound==true and .session_id==$sid and .last_completed_unit_id=="03-reassign" and (.contract_fingerprint|length)==64' \
  .agent-work/worker-session.json >/dev/null || fail "T: worker-session.json 저널 계약 불일치: $(cat .agent-work/worker-session.json)"
pass "T: Unit 3개 = Worker 세션 1개 (01 --session-id, 02/03 --resume 같은 ID), 저널 기록 일치"

# ===== 사례 U: 워커 응답 직후·targeted test 직전 중단 → 유효한 결과 + after-tree 일치면 CLI 재호출 없이 테스트부터 재개 =====
reset_tree; touch "$MOCK_STATE/crash-02"
rc="$(run_runner)"
[ "$rc" -eq 1 ] || { tail -20 "$TMP/run.log"; fail "U: 전제(02 호출 실패) exit 1 기대, 실제 $rc"; }
[ -f .agent-work/units/01-intake/done.json ] && [ ! -f .agent-work/units/02-drop/done.json ] || fail "U: 전제 체크포인트 불일치"
sid="$(cat .agent-work/.session-feature-worker)"
# '02 워커 턴은 끝났는데 targeted test 전에 러너가 죽은' 상태를 만든다 — 유효한 DONE 결과 + after-tree == 현재 tree
echo "worker 02-drop" >> src/u02.txt; echo "shared by 02-drop" >> src/shared.txt; mkdir -p src/gen; echo "gen by 02" > src/gen/new.txt
printf '%s\n' '{"status":"DONE","undecided":[],"delegated_choices":[{"location":"src/u02.txt","technique":"t","basis":"b"}],"tests":[{"name":"u02","result":"PASS"}],"context_updates":{"upsert":[{"kind":"REUSE","subject":"TicketStatus.isAssignable","note":"02-note"},{"kind":"INVARIANT","subject":"ticket version check","note":"vl"}],"remove":[{"kind":"ENTRY_POINT","subject":"TicketService.assignInitialAgent"}]}}' \
  > .agent-work/units/02-drop/worker-result.json
( source "$LOADER"; snapshot_worktree_tree ) > .agent-work/units/02-drop/worker-after.tree || fail "U: after-tree 조작 실패"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "U: 재실행 exit 0 기대, 실제 $rc"; }
grep -q '^worker 02-drop' "$MOCK_LOG" && fail "U: 유효 결과가 있는데 02 워커가 재호출됨"
[ "$(paste -sd'|' "$MOCK_LOG")" = "test-02|worker 03-reassign|test-03|final-review|full-test|full-lint" ] \
  || fail "U: 테스트부터 재개되지 않음: $(paste -sd'|' "$MOCK_LOG")"
[ "$(paste -sd' ' "$MOCK_LOG.sessions")" = "claude-worker 03-reassign --resume $sid" ] || fail "U: 03 이 같은 세션을 resume 하지 않음: $(cat "$MOCK_LOG.sessions")"
jq -e '.last_completed_unit_id=="03-reassign"' .agent-work/worker-session.json >/dev/null || fail "U: 저널 last_completed_unit_id 미갱신"
grep -q '02-note' "$MOCK_STATE/ctx-worker-03.txt" || fail "U: 재개 확정된 02 context 가 03 에 전달되지 않음"
pass "U: 유효 결과 + after-tree 일치 → CLI 재호출 없이 테스트만 재개, 이후 unit 은 같은 세션 resume"

# ===== 사례 V: 세션 전제(모델·세션 파일) 불일치 → 자동 resume 금지 (워커·테스트 0회), 복구 후에만 같은 세션 재개 =====
reset_tree; touch "$MOCK_STATE/crash-03"
rc="$(run_runner)"; [ "$rc" -eq 1 ] || fail "V: 전제(03 중단) 실패"
cp .agent-work/worker-session.json "$TMP/journal.keep"
jq '.model="other-model"' "$TMP/journal.keep" > .agent-work/worker-session.json
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_SESSION_MISMATCH ] || { tail -20 "$TMP/run.log"; fail "V: exit 2/WORKER_SESSION_MISMATCH 기대, 실제 $rc/$(reason)"; }
grep -q '^worker \|^test-' "$MOCK_LOG" && fail "V: 전제 불일치인데 워커/테스트가 호출됨: $(paste -sd'|' "$MOCK_LOG")"
cp "$TMP/journal.keep" .agent-work/worker-session.json
sid="$(jq -r '.session_id' "$TMP/journal.keep")"
rm -f .agent-work/.session-feature-worker
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_SESSION_MISMATCH ] || fail "V: 세션 파일 소실인데 자동 fresh 세션으로 이어 감 ($rc/$(reason))"
grep -q '^worker ' "$MOCK_LOG" && fail "V: 세션 파일 소실인데 워커가 호출됨"
printf '%s' "$sid" > .agent-work/.session-feature-worker
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "V: 복구 후 재실행 exit 0 기대, 실제 $rc"; }
[ "$(paste -sd' ' "$MOCK_LOG.sessions")" = "claude-worker 03-reassign --resume $sid" ] || fail "V: 복구 후 03 이 같은 세션으로 재개되지 않음: $(cat "$MOCK_LOG.sessions")"
pass "V: 모델 불일치·세션 파일 소실 → WORKER_SESSION_MISMATCH(모델 호출 0회), 복구 후에만 같은 세션 재개"

# ===== 사례 W: 예전 fresh-워커 실행 잔존 → 묵시적 단일 세션 마이그레이션 금지, 명시 마커 후에만 새 세션으로 재개 =====
reset_tree; touch "$MOCK_STATE/crash-03"
rc="$(run_runner)"; [ "$rc" -eq 1 ] || fail "W: 전제(03 중단) 실패"
rm -f .agent-work/worker-session.json .agent-work/.session-feature-worker
printf 'legacy' > .agent-work/.session-worker-unit-01-intake   # 예전 체계(unit 별 fresh 세션)의 흔적
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_SESSION_MISSING ] || { tail -20 "$TMP/run.log"; fail "W: exit 2/WORKER_SESSION_MISSING 기대, 실제 $rc/$(reason)"; }
grep -q '^worker \|^test-' "$MOCK_LOG" && fail "W: 묵시적 마이그레이션 금지인데 워커/테스트가 호출됨"
touch .agent-work/worker-session.migrate   # 사용자의 명시적 마이그레이션 결정
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "W: 마커 후 재실행 exit 0 기대, 실제 $rc"; }
[ "$(seq_of '^worker ')" = "worker 03-reassign" ] || fail "W: 마커 후 첫 미완료 unit(03)부터 재개되지 않음: $(seq_of '^worker ')"
[ "$(awk '{print $1" "$2" "$3}' "$MOCK_LOG.sessions")" = "claude-worker 03-reassign --session-id" ] || fail "W: 마이그레이션이 새 세션(--session-id)으로 시작하지 않음: $(cat "$MOCK_LOG.sessions")"
[ ! -f .agent-work/worker-session.migrate ] && ls .agent-work/worker-session.migrate.used.* >/dev/null 2>&1 || fail "W: 마이그레이션 마커가 1회 소비되지 않음"
pass "W: 잔존 fresh-워커 세션 → WORKER_SESSION_MISSING(워커 0회), worker-session.migrate 후에만 새 세션으로 재개"

# ===== 사례 R: 관측 토큰 임계치 도달 → unit 경계에서만 결정론적 세션 교체 (handoff 검증, test-fix 는 교체 지점 아님) =====
reset_tree
sed -i.bak 's/^WORKER_SESSION_ROTATE_INPUT_TOKENS=.*/WORKER_SESSION_ROTATE_INPUT_TOKENS=1/' "$CFG" && rm -f "$CFG.bak"
touch "$MOCK_STATE/fail-test-01"   # unit 01 에 test-fix 를 끼워 넣는다 — 교체는 unit 완료 뒤에만, fix 는 같은 세션이어야 한다
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "R: exit 0 기대, 실제 $rc"; }
sidA="$(awk 'NR==1{print $4}' "$MOCK_LOG.sessions")"; sidB="$(awk 'NR==3{print $4}' "$MOCK_LOG.sessions")"; sidC="$(awk 'NR==4{print $4}' "$MOCK_LOG.sessions")"
[ "$(paste -sd' ' "$MOCK_LOG.sessions")" = "claude-worker 01-intake --session-id $sidA claude-test-fix 01-intake --resume $sidA claude-worker 02-drop --session-id $sidB claude-worker 03-reassign --session-id $sidC" ] \
  || fail "R: 교체 시퀀스 불일치(기대: 01→fix 같은 세션, 02/03 은 unit 경계마다 fresh): $(cat "$MOCK_LOG.sessions")"
[ "$sidA" != "$sidB" ] && [ "$sidB" != "$sidC" ] && [ "$sidA" != "$sidC" ] || fail "R: 세대별 세션 ID 가 구분되지 않음"
grep -q '세션 교체 예약: input_per_turn(턴당 평균 근사' "$TMP/run.log" || fail "R: context_last_turn 관측 불가 시 input_per_turn 근사로 판단했다는 로그가 없음"
grep -q '세션 교체 판단에 근사값 사용' "$TMP/run.log" || fail "R: 근사값 사용 사실이 로그에 없음"
[ -f .agent-work/.session-feature-worker.gen1 ] && [ -f .agent-work/.session-feature-worker.gen2 ] || fail "R: 은퇴 세션 파일이 세대 접미사로 보존되지 않음"
jq -e --arg sid "$sidC" '.generation==3 and .session_bound==true and .session_id==$sid and .last_completed_unit_id=="03-reassign"' .agent-work/worker-session.json >/dev/null \
  || fail "R: 저널 세대·세션 ID 불일치: $(cat .agent-work/worker-session.json)"
jq -e '.version==1 and .generation==3 and .last_completed_unit=="02-drop" and .next_unit=="03-reassign" and (.source_tree|test("^[0-9a-f]{40,64}$")) and .context_file==".agent-work/implementation-context.json"' \
  .agent-work/worker-handoff.json >/dev/null || fail "R: worker-handoff.json 계약 불일치: $(cat .agent-work/worker-handoff.json)"
[ -f .claude/skills/feature/schemas/worker-handoff.schema.json ] || fail "R: worker-handoff 스키마 파일 없음"
# 교체 직후(세대 ≠ 이관 정보) 상태의 변조 — handoff 의 tree 가 현재와 다르면 fresh 세션을 만들지 않는다
rm -rf .agent-work/units/03-reassign .agent-work/worker-result.json .agent-work/approved.fingerprint .agent-work/review-impl.json .agent-work/.session-feature-worker
jq '.session_id=null' .agent-work/worker-session.json > "$TMP/j.tmp" && mv "$TMP/j.tmp" .agent-work/worker-session.json
jq '.source_tree="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' .agent-work/worker-handoff.json > "$TMP/h.tmp" && mv "$TMP/h.tmp" .agent-work/worker-handoff.json
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_SESSION_MISMATCH ] || { tail -20 "$TMP/run.log"; fail "R: 이관 tree 불일치가 막히지 않음 ($rc/$(reason))"; }
grep -q '^worker ' "$MOCK_LOG" && fail "R: 이관 검증 실패인데 워커가 호출됨"
sed -i.bak 's|^WORKER_SESSION_ROTATE_INPUT_TOKENS=.*|WORKER_SESSION_ROTATE_INPUT_TOKENS="${WORKER_SESSION_ROTATE_INPUT_TOKENS:-1000000}"|' "$CFG" && rm -f "$CFG.bak"
pass "R: 임계치 도달 시 unit 경계에서만 세션 교체(fix 는 같은 세션), handoff 스키마·tree 검증, 변조 시 fresh 세션 거부"

# ===== 사례 R2: claude stream-json 의 context_last_turn(마지막 model 호출 실제 입력)이 input_per_turn 보다 우선한다 =====
# 턴당 평균(400/4=100)은 임계치 이상이지만 실측 컨텍스트 7 은 임계치 10 미만 → 교체하지 않는다. 임계치 5 → 실측 근거로 교체.
reset_tree
echo 7 > "$MOCK_STATE/stream-ctx"
sed -i.bak 's/^WORKER_SESSION_ROTATE_INPUT_TOKENS=.*/WORKER_SESSION_ROTATE_INPUT_TOKENS=10/' "$CFG" && rm -f "$CFG.bak"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "R2: exit 0 기대, 실제 $rc"; }
[ "$(awk '{print $4}' "$MOCK_LOG.sessions" | sort -u | grep -c .)" -eq 1 ] || fail "R2: 실측 컨텍스트(7) < 임계치(10)인데 세션이 교체됨: $(cat "$MOCK_LOG.sessions")"
[ "$(jq -rs '[ .[] | select(.role=="WORKER") ] | last | [.context_last_turn, .input_per_turn] | @csv' .agent-work/usage.jsonl)" = "7,100" ] \
  || fail "R2: usage 행의 context_last_turn/input_per_turn 불일치: $(tail -1 .agent-work/usage.jsonl)"
ls .agent-work/units/01-intake/worker-*.log.stream.jsonl >/dev/null 2>&1 || fail "R2: stream-json 원본이 보존되지 않음: $(ls .agent-work/units/01-intake)"
reset_tree
sed -i.bak 's/^WORKER_SESSION_ROTATE_INPUT_TOKENS=.*/WORKER_SESSION_ROTATE_INPUT_TOKENS=5/' "$CFG" && rm -f "$CFG.bak"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "R2: (임계치 5) exit 0 기대, 실제 $rc"; }
[ "$(awk '{print $4}' "$MOCK_LOG.sessions" | sort -u | grep -c .)" -eq 3 ] || fail "R2: 실측 컨텍스트(7) ≥ 임계치(5)인데 unit 마다 교체되지 않음: $(cat "$MOCK_LOG.sessions")"
grep -q '세션 교체 예약: context_last_turn(실측, 창 크기 관측 불가 → 고정 임계치) 7tok' "$TMP/run.log" || fail "R2: 실측(고정 임계치) 근거 로그가 없음"
grep -q '근사값 사용' "$TMP/run.log" && fail "R2: 실측이 있는데 근사값 사용 로그가 찍힘"
# 창 크기까지 관측되면 고정 임계치(1000000) 대신 비율: 7/10=0.7 < 0.8 유지, 8/10=0.8 ≥ 0.8 교체
reset_tree
sed -i.bak 's|^WORKER_SESSION_ROTATE_INPUT_TOKENS=.*|WORKER_SESSION_ROTATE_INPUT_TOKENS="${WORKER_SESSION_ROTATE_INPUT_TOKENS:-1000000}"|' "$CFG" && rm -f "$CFG.bak"
echo "7 10" > "$MOCK_STATE/stream-ctx"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "R2: (비율 0.7) exit 0 기대, 실제 $rc"; }
[ "$(awk '{print $4}' "$MOCK_LOG.sessions" | sort -u | grep -c .)" -eq 1 ] || fail "R2: 비율 0.7 < 0.8 인데 세션이 교체됨: $(cat "$MOCK_LOG.sessions")"
[ "$(jq -rs '[ .[] | select(.role=="WORKER") ] | last | [.context_last_turn, .context_window] | @csv' .agent-work/usage.jsonl)" = "7,10" ] \
  || fail "R2: usage 행의 context_window 불일치: $(tail -1 .agent-work/usage.jsonl)"
reset_tree
echo "8 10" > "$MOCK_STATE/stream-ctx"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "R2: (비율 0.8) exit 0 기대, 실제 $rc"; }
[ "$(awk '{print $4}' "$MOCK_LOG.sessions" | sort -u | grep -c .)" -eq 3 ] || fail "R2: 비율 0.8 ≥ 0.8 인데 교체되지 않음: $(cat "$MOCK_LOG.sessions")"
grep -q '세션 교체 예약: context_last_turn/context_window(실측) 8/10tok = 0.800 ≥ 비율 0.8' "$TMP/run.log" || fail "R2: 비율 근거 로그가 없음"
rm -f "$MOCK_STATE/stream-ctx"
sed -i.bak 's|^WORKER_SESSION_ROTATE_INPUT_TOKENS=.*|WORKER_SESSION_ROTATE_INPUT_TOKENS="${WORKER_SESSION_ROTATE_INPUT_TOKENS:-1000000}"|' "$CFG" && rm -f "$CFG.bak"
pass "R2: claude stream-json 실측 context_last_turn 우선(창 크기 없음→고정 임계치 7<10 유지·7≥5 교체, 창 크기 있음→비율 0.7 유지·0.8 교체), stream 원본 보존·result 추출"

# ===== 사례 Y: codex 워커도 Feature 당 세션 1개 — thread_id 는 원장에만, 저널은 session_bound 만 (불변식 fail-closed) =====
reset_tree
sed -i.bak 's/^WORKER_CLI=.*/WORKER_CLI="codex"/' "$CFG" && rm -f "$CFG.bak"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "Y: exit 0 기대, 실제 $rc"; }
LEDGER=.agent-work/.session-feature-worker.codex.json
[ -f "$LEDGER" ] || fail "Y: codex 세션 원장이 확정되지 않음"
tid="$(jq -r '.thread_id' "$LEDGER")"
y_seq="$(grep '^codex-worker' "$MOCK_LOG.sessions" | paste -sd'|' -)"
[ "$y_seq" = "codex-worker 01-intake new|codex-worker 02-drop resume $tid|codex-worker 03-reassign resume $tid" ] \
  || fail "Y: codex 워커가 같은 thread 를 resume 하지 않음(기대 tid $tid): $y_seq"
jq -e '.cli=="codex" and .session_bound==true and .session_id==null' .agent-work/worker-session.json >/dev/null \
  || fail "Y: 저널은 session_bound 만 기록해야 함(thread_id 복사 금지): $(cat .agent-work/worker-session.json)"
grep -q "$tid" .agent-work/worker-session.json && fail "Y: codex thread_id 가 저널에 중복 저장됨"
# 03 재실행 상태를 만든다(마지막 호출은 수용 완료 — resume marker 없음)
prep_rerun_03() {
  rm -rf .agent-work/units/03-reassign .agent-work/worker-result.json .agent-work/approved.fingerprint .agent-work/review-impl.json
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
}
# 불변식 1: session_bound=true 인데 원장 소실 → '미생성'과 구별해 중단 (자동 fresh 금지)
prep_rerun_03; cp "$LEDGER" "$TMP/ledger.keep"; rm -f "$LEDGER"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_SESSION_MISMATCH ] || { tail -20 "$TMP/run.log"; fail "Y: 원장 소실이 막히지 않음 ($rc/$(reason))"; }
grep -q '^worker \|^test-' "$MOCK_LOG" && fail "Y: 원장 소실인데 워커/테스트가 호출됨"
# 불변식 2: 원장은 확정돼 있는데 저널이 미결속(session_bound=false) → 불일치 중단
cp "$TMP/ledger.keep" "$LEDGER"
jq '.session_bound=false' .agent-work/worker-session.json > "$TMP/j.tmp" && mv "$TMP/j.tmp" .agent-work/worker-session.json
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_SESSION_MISMATCH ] || { tail -20 "$TMP/run.log"; fail "Y: 원장+미결속 불일치가 막히지 않음 ($rc/$(reason))"; }
grep -q '^worker ' "$MOCK_LOG" && fail "Y: 불일치인데 워커가 호출됨"
# 복구(결속 기록 원복) 후에만 같은 thread 로 재개
jq '.session_bound=true' .agent-work/worker-session.json > "$TMP/j.tmp" && mv "$TMP/j.tmp" .agent-work/worker-session.json
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "Y: 복구 후 재실행 exit 0 기대, 실제 $rc"; }
[ "$(grep '^codex-worker' "$MOCK_LOG.sessions")" = "codex-worker 03-reassign resume $tid" ] \
  || fail "Y: 복구 후 03 이 같은 thread 로 재개되지 않음: $(grep '^codex-worker' "$MOCK_LOG.sessions")"
pass "Y: codex 워커 세션 1 thread(원장에만 저장, 저널은 session_bound), 원장 소실·결속 불일치 → 중단(자동 fresh 금지), 복구 후 같은 thread 재개"

# ===== 사례 Z: codex 워커도 임계치 도달 시 unit 경계에서 교체 — 원장은 세대 접미사로 은퇴, 다음 unit 은 새 exec(resume 아님), handoff 검증 =====
reset_tree
sed -i.bak 's/^WORKER_SESSION_ROTATE_INPUT_TOKENS=.*/WORKER_SESSION_ROTATE_INPUT_TOKENS=1/' "$CFG" && rm -f "$CFG.bak"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/run.log"; fail "Z: exit 0 기대, 실제 $rc"; }
[ "$(grep '^codex-worker' "$MOCK_LOG.sessions" | paste -sd'|' -)" = "codex-worker 01-intake new|codex-worker 02-drop new|codex-worker 03-reassign new" ] \
  || fail "Z: codex 교체 시퀀스 불일치(기대: unit 마다 새 exec): $(grep '^codex-worker' "$MOCK_LOG.sessions")"
[ -f "$LEDGER.gen1" ] && [ -f "$LEDGER.gen2" ] && [ -f "$LEDGER" ] || fail "Z: 은퇴 원장이 세대 접미사로 보존되지 않음: $(ls .agent-work/.session-feature-worker* )"
jq -e '.generation==3 and .session_bound==true and .session_id==null' .agent-work/worker-session.json >/dev/null || fail "Z: 저널 세대 불일치: $(cat .agent-work/worker-session.json)"
jq -e '.generation==3 and .last_completed_unit=="02-drop" and .next_unit=="03-reassign"' .agent-work/worker-handoff.json >/dev/null || fail "Z: handoff 불일치: $(cat .agent-work/worker-handoff.json)"
grep -q '세션 교체 예약: input_per_turn(턴당 평균 근사.*fresh codex 세션' "$TMP/run.log" || fail "Z: codex 교체 로그가 없음"
# 교체된 세대인데 handoff 가 없으면 새 exec 를 열지 않는다(claude 와 같은 게이트)
prep_rerun_03; rm -f "$LEDGER" .agent-work/worker-handoff.json
jq '.session_bound=false' .agent-work/worker-session.json > "$TMP/j.tmp" && mv "$TMP/j.tmp" .agent-work/worker-session.json
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_SESSION_MISMATCH ] || { tail -20 "$TMP/run.log"; fail "Z: 교체 세대 + handoff 없음이 막히지 않음 ($rc/$(reason))"; }
grep -q '^worker ' "$MOCK_LOG" && fail "Z: 이관 검증 실패인데 워커가 호출됨"
sed -i.bak 's|^WORKER_SESSION_ROTATE_INPUT_TOKENS=.*|WORKER_SESSION_ROTATE_INPUT_TOKENS="${WORKER_SESSION_ROTATE_INPUT_TOKENS:-1000000}"|' "$CFG" && rm -f "$CFG.bak"
pass "Z: codex 워커 임계치 교체 — 원장 세대 은퇴·새 exec·handoff 검증, 교체 세대 handoff 부재 시 fresh 거부"

# ===== 사례 P: 워커 규칙 원문 전달 범위 (GOAL-44) — 경계에서만 전문, 그 밖에는 짧은 불변식. 세션·게이트는 그대로 =====
# 워커 CLI 는 명시 고정(claude) — 모델 이름 추론에 의존하지 않는다. conventions.md 는 범위 밖 파일이라 합의 PASS 를 다시 만든다.
sed -i.bak 's/^WORKER_CLI=.*/WORKER_CLI="claude"/' "$CFG" && rm -f "$CFG.bak"
printf '# conventions\n- CONV-SENTINEL-V1 규칙\n' > conventions.md
printf '\n- CORE-SENTINEL 워커 규칙\n' >> .claude/hooks/core_rules.md
fake_pass design; fake_pass impl
rules_seq() { paste -sd'|' "$MOCK_STATE/rules-seq.log"; }
p_reset() { reset_tree; rm -f "$MOCK_STATE"/prompt-*.txt "$MOCK_STATE/rules-seq.log" "$MOCK_STATE/compact-next" "$MOCK_STATE"/compact-worker-* "$MOCK_STATE"/compact-test-fix-*; }
has_full_rules() { grep -q 'CORE-SENTINEL' "$1" && grep -q 'CONV-SENTINEL-V1' "$1"; }
# P-1: 01(fresh) → 01 test-fix(short) → 02(recheck) → 03(recheck), 세션 1개
p_reset; touch "$MOCK_STATE/fail-test-01"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -30 "$TMP/run.log"; fail "P-1: exit 0 기대, 실제 $rc ($(reason))"; }
[ "$(rules_seq)" = "worker 01 fresh|test-fix 01 short|worker 02 recheck|worker 03 recheck" ] || fail "P-1: 규칙 전달 형태 순서 불일치: $(rules_seq)"
has_full_rules "$MOCK_STATE/prompt-worker-01.txt" || fail "P-1: 최초 unit 워커가 core_rules·conventions 원문을 받지 못함"
grep -q 'RULES RECHECK' "$MOCK_STATE/prompt-worker-01.txt" && fail "P-1: fresh 세션 최초 턴에 재전달 블록이 붙음(중복)"
grep -q 'CORE-SENTINEL\|CONV-SENTINEL-V1' "$MOCK_STATE/prompt-test-fix-01.txt" && fail "P-1: 같은 unit 의 test-fix 턴에 규칙 전문이 중복 삽입됨"
grep -q '필수 제약 재명시' "$MOCK_STATE/prompt-test-fix-01.txt" && grep -q "디스크에서 다시 읽는다: .*core_rules.md, .*conventions.md" "$MOCK_STATE/prompt-test-fix-01.txt" \
  || fail "P-1: test-fix 턴에 짧은 필수 불변식·규칙 원문 경로가 없음"
for u in 02 03; do
  has_full_rules "$MOCK_STATE/prompt-worker-$u.txt" || fail "P-1: 후속 unit $u 첫 턴에 규칙 원문이 재전달되지 않음"
  grep -q '^\[RULES RECHECK — 규칙 원문 재전달: 작업 단위 변경' "$MOCK_STATE/prompt-worker-$u.txt" && grep -q '필수 제약 재명시' "$MOCK_STATE/prompt-worker-$u.txt" \
    || fail "P-1: 후속 unit $u 첫 턴의 재전달 사유(작업 단위 변경)·짧은 불변식이 없음"
done
[ "$(awk '{print $4}' "$MOCK_LOG.sessions" | sort -u | grep -c .)" -eq 1 ] && [ "$(grep -c -- '--resume' "$MOCK_LOG.sessions")" -eq 3 ] \
  || fail "P-1: 규칙 재전달이 세션을 바꿈(기대: 세션 1개, resume 3회): $(cat "$MOCK_LOG.sessions")"
[ "$(grep -c '워커 규칙 전달' "$TMP/run.log")" -eq 4 ] && grep -q '워커 규칙 전달 (unit 01-intake) \[test-fix-01\]: short' "$TMP/run.log" \
  && grep -q '워커 규칙 전달 (unit 02-drop) \[worker\]: full — 작업 단위 변경' "$TMP/run.log" || fail "P-1: 전달 범위 로그 불일치: $(grep '워커 규칙 전달' "$TMP/run.log")"
short_bytes="$(sed -n 's/.*\[test-fix-01\]: short.*, \([0-9]*\) bytes$/\1/p' "$TMP/run.log")"; full_bytes="$(sed -n 's/.*(unit 02-drop) \[worker\]: full.*, \([0-9]*\) bytes$/\1/p' "$TMP/run.log")"
[ -n "$short_bytes" ] && [ -n "$full_bytes" ] && [ "$short_bytes" -lt "$full_bytes" ] || fail "P-1: short($short_bytes) 가 full($full_bytes) 보다 작지 않음"
pass "P-1: 최초 unit 전문 / 같은 unit test-fix 는 짧은 불변식+원문 경로(${short_bytes}B) / 후속 unit 첫 턴 전문 재전달(${full_bytes}B) / 세션 1개 유지"
# P-2: 러너 재실행(03 재개) — 같은 세션 resume 이지만 이 실행의 첫 워커 턴이라 원문 재전달
prep_rerun_03; rm -f "$MOCK_STATE/rules-seq.log" "$MOCK_STATE"/prompt-*.txt
sid_before="$(cat .agent-work/.session-feature-worker)"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -30 "$TMP/run.log"; fail "P-2: exit 0 기대, 실제 $rc ($(reason))"; }
[ "$(rules_seq)" = "worker 03 recheck" ] && grep -q '^\[RULES RECHECK — 규칙 원문 재전달: 러너 (재)실행 뒤 첫 워커 턴' "$MOCK_STATE/prompt-worker-03.txt" && has_full_rules "$MOCK_STATE/prompt-worker-03.txt" \
  || fail "P-2: 재개 뒤 첫 워커 턴에 규칙 원문이 재전달되지 않음: $(rules_seq)"
[ "$(cat "$MOCK_LOG.sessions")" = "claude-worker 03-reassign --resume $sid_before" ] || fail "P-2: 재개가 같은 세션 resume 이 아님: $(cat "$MOCK_LOG.sessions")"
pass "P-2: 러너 재실행 뒤 첫 워커 턴 — 같은 세션 resume + 규칙 원문 재전달"
# P-3: 압축 관측 — 02 워커 호출의 stream 에 compact_boundary → 같은 unit 의 다음 턴(test-fix)이 원문을 다시 받는다(압축 없던 P-1 의 test-fix 는 short)
p_reset; echo "7" > "$MOCK_STATE/stream-ctx"; touch "$MOCK_STATE/compact-worker-02" "$MOCK_STATE/fail-test-02"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -30 "$TMP/run.log"; fail "P-3: exit 0 기대, 실제 $rc ($(reason))"; }
[ "$(rules_seq)" = "worker 01 fresh|worker 02 recheck|test-fix 02 recheck|worker 03 recheck" ] || fail "P-3: 압축 뒤 규칙 전달 순서 불일치: $(rules_seq)"
grep -q '^\[RULES RECHECK — 규칙 원문 재전달: 직전 워커 호출에서 컨텍스트 압축 관측' "$MOCK_STATE/prompt-test-fix-02.txt" && has_full_rules "$MOCK_STATE/prompt-test-fix-02.txt" \
  || fail "P-3: 압축 관측 뒤 턴에 규칙 원문이 재전달되지 않음"
grep -q '컨텍스트 압축 관측 — 다음 워커 턴에 규칙 원문 재전달' "$TMP/run.log" || fail "P-3: 압축 관측 로그가 없음"
[ "$(awk '{print $4}' "$MOCK_LOG.sessions" | sort -u | grep -c .)" -eq 1 ] || fail "P-3: 압축 관측이 세션을 바꿈: $(cat "$MOCK_LOG.sessions")"
rm -f "$MOCK_STATE/stream-ctx"
pass "P-3: 직전 호출에서 압축 관측 → 다음 턴(test-fix 포함) 규칙 원문 재전달, 세션 유지"
# P-4: handoff — 교체된 fresh 세대의 첫 턴은 전문(재전달 블록 없이 최초 턴 형태), 세션은 unit 마다 새로
p_reset
sed -i.bak 's/^WORKER_SESSION_ROTATE_INPUT_TOKENS=.*/WORKER_SESSION_ROTATE_INPUT_TOKENS=1/' "$CFG" && rm -f "$CFG.bak"
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -30 "$TMP/run.log"; fail "P-4: exit 0 기대, 실제 $rc ($(reason))"; }
[ "$(rules_seq)" = "worker 01 fresh|worker 02 fresh|worker 03 fresh" ] || fail "P-4: handoff 뒤 fresh 세대가 최초 턴 전문을 받지 않음: $(rules_seq)"
for u in 02 03; do has_full_rules "$MOCK_STATE/prompt-worker-$u.txt" || fail "P-4: handoff 뒤 unit $u 가 규칙 원문을 받지 못함"; done
[ "$(grep -c -- '--session-id' "$MOCK_LOG.sessions")" -eq 3 ] && [ -f .agent-work/worker-handoff.json ] || fail "P-4: handoff 세션 교체가 일어나지 않음: $(cat "$MOCK_LOG.sessions")"
sed -i.bak 's|^WORKER_SESSION_ROTATE_INPUT_TOKENS=.*|WORKER_SESSION_ROTATE_INPUT_TOKENS="${WORKER_SESSION_ROTATE_INPUT_TOKENS:-1000000}"|' "$CFG" && rm -f "$CFG.bak"
pass "P-4: handoff 뒤 fresh 세대 첫 턴은 규칙 전문(최초 턴 형태)"
# P-5: 범위 밖 conventions.md 가 피처 도중 바뀌면 기존 게이트대로 멈춘다 — 규칙이 바뀌었다는 이유로 조용히 fresh 세션을 만들거나 재전달로 넘어가지 않는다
p_reset
rc="$(run_runner)"; [ "$rc" -eq 0 ] || fail "P-5: 전제 실행 실패 ($rc)"
prep_rerun_03; rm -f "$MOCK_STATE/rules-seq.log"
sid_before="$(cat .agent-work/.session-feature-worker)"; journal_before="$(cat .agent-work/worker-session.json)"
printf '# conventions\n- CONV-SENTINEL-V2 바뀐 규칙\n' > conventions.md
rc="$(run_runner)"
[ "$rc" -eq 2 ] || { tail -30 "$TMP/run.log"; fail "P-5: conventions 변경 뒤 exit 2 기대, 실제 $rc ($(reason))"; }
case "$(reason)" in WORKER_SESSION_MISMATCH|UNIT_CONTRACT_IMPACT_REQUIRED) ;; *) fail "P-5: 기존 게이트 사유가 아님: $(reason)";; esac
[ ! -f "$MOCK_STATE/rules-seq.log" ] || fail "P-5: 규칙이 바뀌었는데 워커가 호출됨: $(rules_seq)"
[ "$(cat .agent-work/.session-feature-worker)" = "$sid_before" ] && [ "$(cat .agent-work/worker-session.json)" = "$journal_before" ] || fail "P-5: 세션 파일·저널이 바뀜(조용한 fresh 세션)"
p5_reason="$(reason)"
# 되돌리면(피처 시작 시점의 규칙) 같은 세션으로 재개되고, 재개 턴은 현재 파일 원문을 받는다
printf '# conventions\n- CONV-SENTINEL-V1 규칙\n' > conventions.md
rc="$(run_runner)"
[ "$rc" -eq 0 ] || { tail -30 "$TMP/run.log"; fail "P-5: 규칙 복구 뒤 exit 0 기대, 실제 $rc ($(reason))"; }
[ "$(rules_seq)" = "worker 03 recheck" ] && has_full_rules "$MOCK_STATE/prompt-worker-03.txt" && [ "$(grep '^claude-worker' "$MOCK_LOG.sessions")" = "claude-worker 03-reassign --resume $sid_before" ] \
  || fail "P-5: 복구 뒤 같은 세션 재개·규칙 원문 재전달이 아님: $(rules_seq) / $(cat "$MOCK_LOG.sessions")"
pass "P-5: 범위 밖 conventions 변경 → 기존 게이트($p5_reason, 워커 0회·세션 불변), 복구 뒤 같은 세션 재개 + 현재 규칙 원문 재전달"

echo "[SMOKE] 전부 통과 — 임시 저장소: $TMP (필요 없으면 직접 정리)"
