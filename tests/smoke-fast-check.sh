#!/usr/bin/env bash
# =============================================================
# 스모크: 프로젝트 빠른 검사 연결(FAST_CHECK_CMD) — 실제 LLM 호출 없음 (공용 mock CLI: 역할은 스키마로 판별, 모델→CLI 매핑 무관), 임시 fixture 프로젝트
# 파일 경로: tests/smoke-fast-check.sh
# 사용법: bash tests/smoke-fast-check.sh   (어디서든 실행 가능)
#
# fixture 프로젝트는 자기 검사 스크립트(tools/check.sh — src/a.txt 의 금지 토큰 검사)를 갖는다. 하네스에는 그 규칙이 없다.
# 사례:
#   A. 미설정: 종전 흐름 그대로(worker → targeted test → reviewer → TEST/LINT → DONE), 로그에 "생략 … 미설정", 검사 실행 기록 없음
#   B. 정상: 첫 리뷰어 호출 전에 검사 1회(리뷰어 호출 1회당 검사 1회), worktree 루트에서 실행, 명령·원본 로그·실행 시간·결과 기록, 변경 파일 목록 전달
#   C. 첫 검사 위반: 리뷰어 0회로 멈추고 워커 수정(check-fix) → 재검사 통과 → 리뷰 → TEST → LINT → DONE. 진단 원본 보존, 리뷰 JSON 위조 없음
#   D. 위반이 수정 뒤에도 남음: FAST_CHECK_RETRIES_EXHAUSTED, 리뷰어 0회·승인 없음. 그대로 재실행 = 검사 1회·모델 0회(무한 루프 없음). 직접 고친 뒤 재실행 → 검사부터 → DONE
#   E. 수정자(Fixer) 뒤 검사: 수정자가 위반을 만들면 다음 리뷰어 호출 0회. 워커 수정 → 재검사 → 새 attempt Round 1 리뷰(수정 전 리뷰 재사용 없음) → DONE
#   F. 실행 오류: 해석 불가 종료 코드 / 도구 누락 / 타임아웃 / 진단 없는 exit 1 / 잘못된 타임아웃 설정 → FAST_CHECK_ERROR, 리뷰어·수정자·워커 0회, 재실행도 같은 결과, 고친 뒤 재실행 → DONE
#   G. 읽기 전용 위반: 검사가 범위 안 파일 수정 / 범위 밖 파일 수정 / git index 변경 → FAST_CHECK_ERROR, 변경 보존(원복 없음),
#      이후 통과한 검사 뒤의 리뷰는 바뀐 코드를 본다. 승인 뒤 검사가 코드를 바꾸면 그 승인은 재사용되지 않는다
#   H. 기존 성공 기록 오용 방지: 승인 + verify 재개 힌트가 있어도 설정된 검사를 먼저 지난다(규칙 입력이 바뀌어 위반이면 TEST 0회, DONE 아님),
#      승인 뒤 새로 설정한 검사도 같다. 통과하면 리뷰어 0회로 승인 재사용 → TEST → DONE. 과거 PASS 기록(last.json/history)은 검사를 건너뛰게 하지 않는다
#   I. 워커 수정의 기존 게이트: 범위 밖 수정 → SCOPE_VIOLATION(보존), 미결정 → UNDECIDED(한도 미소모) → 사용자 결정 뒤 같은 한도로 수정 재개
#   J. --feature worktree: 검사는 원본이 아니라 피처 worktree 루트에서 돈다. 위반으로 멈춘 상태에서는 finalize 가 거부된다
#   K. 혼합 설치: scripts/fast-check.sh 가 없으면 러너·리뷰 루프 모두 모델 호출 전에 멈춘다
#   M. 변경 파일 목록의 경로: 한글 파일명이 인용 표기 없이 실제 문자열로 전달돼, 목록으로 대상을 고르는 검사가 그 파일의 위반을 놓치지 않는다
#   N. 타임아웃 정리: TERM 을 무시하는 검사 자식 프로세스까지 정리한 뒤에 사후 비교를 한다(타임아웃 판정 뒤 늦게 소스를 바꾸는 프로세스가 남지 않는다)
#   O. 수정 턴 도중 러너 강제 종료: 재실행은 검사·모델 0회로 WORKER_OUTCOME_UNCERTAIN(범위 밖 변경 보존, DONE 아님), 호출 전 tree 로 되돌린 뒤에만 수정 턴 재개.
#      범위 위반으로 멈춘 수정 턴(I1)을 그대로 재실행해도 같은 사유로 다시 멈추고, 범위 밖 변경을 정리한 뒤에는 그 턴의 결과로 이어간다(재호출 없음)
#   R. codex 워커의 수정 턴 도중 강제 종료(resume marker 남음): 호출이 SESSION_RESUME_UNCERTAIN 으로 거부돼도 marker 를 지우지 않는다 —
#      재실행을 반복해도 모델 0회로 같은 거부, 사람이 marker 를 치운 뒤에만 수정 턴이 다시 돈다
#   P. 미결정 수정 턴이 체크포인트(doc-gap-resume.json) 기록 전에 중단: 재실행은 검사·모델 0회로 미결정을 다시 기록해 NEED_USER(UNDECIDED) — 질문이 사라진 채 DONE 으로 가지 않는다.
#      호출 후 tree 가 달라져 있으면 다시 기록하지 않고 WORKER_OUTCOME_UNCERTAIN
#   Q. 끝난 수정 턴의 확정 도중(한도 저장 뒤·진행 기록 닫기 전) 중단: 재실행이 같은 DONE 을 다시 확정해도 한도·리뷰 입력 병합은 한 번만 반영된다
#   L. 다른 수정 경로: verify(TEST_CMD) 실패의 워커 수정 뒤 리뷰로 돌아올 때도 검사를 먼저 지난다(우회 없음, 리뷰어 호출 1회당 검사 1회)
# =============================================================
set -u
unset NTFY_TOPIC NTFY_TOKEN   # 사용자 셸의 알림 설정이 DONE 사례에서 실제 발송으로 이어지지 않게 한다
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-fast-check-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks"
TMP="$(cd "$TMP" && pwd -P)"   # macOS /var → /private/var: 검사가 기록하는 물리 경로와 맞춘다
fail() { echo "[SMOKE FAIL] $*" >&2; [ ! -f "$TMP/run.log" ] || tail -25 "$TMP/run.log" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

# --- fixture 프로젝트: 스킬 복사 + CHANGE_ME 채움 ---
mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
sed -i.bak "s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"legacy_cli\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BACKEND=.*|CODEX_BACKEND=\"legacy_exec\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"$TMP/bin/full-test\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"echo full-lint >> $TMP/calls.log\"|" "$CFG" && rm -f "$CFG.bak"
printf '%s\n' '#!/usr/bin/env bash' 'echo full-test >> "$MOCK_LOG"' '[ ! -f "$MOCK_STATE/fail-full-test" ] || { rm -f "$MOCK_STATE/fail-full-test"; echo "full test failed"; exit 1; }' > "$TMP/bin/full-test"
chmod +x "$TMP/bin/full-test"
grep -q '^FAST_CHECK_CMD=""$' "$CFG" || fail "픽스처: 소스 config.sh 의 FAST_CHECK_CMD 기본값이 빈 값(미설정)이 아님"
set_check() { sed -i.bak "s|^FAST_CHECK_CMD=.*|FAST_CHECK_CMD=\"$1\"|" "$CFG" && rm -f "$CFG.bak"; }
set_timeout() { sed -i.bak "s|^FAST_CHECK_TIMEOUT_SEC=.*|FAST_CHECK_TIMEOUT_SEC=$1|" "$CFG" && rm -f "$CFG.bak"; }
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src tools && echo "a base" > src/a.txt && echo "outside base" > src/outside.txt && echo "규칙 base" > "src/규칙.txt"

# fixture 프로젝트의 검사 스크립트: 계약(0 정상 / 1 위반 + 진단 / 그 외 오류)만 지키면 무엇이든 된다. mode 파일로 오류·계약 위반 동작을 흉내 낸다.
cat > tools/check.sh <<'EOF'
#!/usr/bin/env bash
echo "check" >> "$MOCK_LOG"
pwd -P > "$MOCK_STATE/check-cwd"
printf '%s\n' "${FAST_CHECK_ROOT:-}" > "$MOCK_STATE/check-root"
cat "${FAST_CHECK_CHANGED_FILES:-/dev/null}" > "$MOCK_STATE/check-changed" 2>/dev/null
mode=default; [ ! -f "$MOCK_STATE/check-mode" ] || mode="$(cat "$MOCK_STATE/check-mode")"
pattern='BAD'
case "$mode" in
  error) echo "checker crashed: internal error" >&2; exit 2;;
  timeout) sleep 30; exit 0;;
  silent) exit 1;;
  mutate) echo "autofixed by checker" >> src/a.txt; exit 0;;
  mutate-outside) echo "formatted by checker" >> src/outside.txt; exit 0;;
  index) git add src/a.txt; exit 0;;
  strict) pattern='BAD|impl';;
  timeout-stubborn)   # TERM 을 무시하는 자식이 제한 시간 뒤에 소스를 바꾸려 한다
    ( trap '' TERM; sleep 4; echo "late write by checker child" >> src/a.txt ) &
    sleep 30; exit 0;;
  list)               # 변경 파일 목록에서 대상을 고르는 어댑터 형태
    found=0
    while IFS= read -r f; do
      case "$f" in *.txt) ;; *) continue;; esac
      [ -f "$f" ] || continue
      echo "checked $f"
      if grep -n 'BAD' "$f" > "$MOCK_STATE/check-hits"; then
        found=1
        while IFS=: read -r line content; do echo "[no-bad-token] $f:$line: 금지 토큰 — $content"; done < "$MOCK_STATE/check-hits"
      fi
    done < "$FAST_CHECK_CHANGED_FILES"
    exit "$found";;
esac
if grep -nE "$pattern" src/a.txt > "$MOCK_STATE/check-hits"; then
  while IFS=: read -r line content; do echo "[no-bad-token] src/a.txt:$line: 금지 토큰 — $content"; done < "$MOCK_STATE/check-hits"
  exit 1
fi
echo "0 violations"
exit 0
EOF
chmod +x tools/check.sh
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline

mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
printf '\n## 01\nunit 01 contract\n' >> .agent-work/implementation.md
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/a.txt","src/규칙.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
RUN=".claude/skills/feature/scripts/feature-run.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" FEATURE_LIVE_TEE=1 MOCK_VALIDATOR_CONTRACT="$CONTRACT" MOCK_REVIEW_CONTRACT="$REVIEW_CONTRACT"
mkdir -p "$MOCK_STATE"
write_units() { # dir
  cat > "$1/implementation-units.json" <<EOF
{"version":1,"units":[
 {"id":"01-core","title":"core","goal":"unit 01","requirements":["REQ-01"],"scope":{"files":["src/a.txt","src/규칙.txt"],"new_file_roots":[]},"references":["implementation.md#01"],"targeted_test":"echo unit-test >> $MOCK_LOG"}
]}
EOF
}
write_units .agent-work

# --- 공용 mock CLI (bin/claude 와 bin/codex 는 같은 스크립트) — 역할은 스키마 내용으로 판별한다 ---
#   spec-review(blocking_issues) → 검증자 PASS / impl-review(issues) → 리뷰어(review-rc 플래그가 있으면 1회 REQUEST_CHANGES, 아니면 APPROVE)
#   worker-result(context_updates) → 워커(프롬프트의 로그 경로로 unit 워커 / check-fix 구분) / 스키마 없는 편집 호출 → 수정자
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
usage='"session_id":"fake","total_cost_usd":0,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
[ "$cli" = codex ] && printf '{"type":"thread.started","thread_id":"%s"}\n' "${resume_tid:-mock-thread-$$}"
emit() {
  if [ "$cli" = codex ]; then
    if [ -n "$out" ]; then printf '%s\n' "$1" > "$out"; else printf '%s\n' "$1"; fi
    printf '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0}}\n'
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
done_json='{"status":"DONE","undecided":[],"delegated_choices":[{"location":"src/a.txt","technique":"t","basis":"b"}],"tests":[],"context_updates":{"upsert":[],"remove":[]}}'
case "$role" in
  validator) emit "{\"schema_version\":$MOCK_VALIDATOR_CONTRACT,\"verdict\":\"PASS\",\"blocking_issues\":[]}"; exit 0;;
  reviewer)
    echo "reviewer" >> "$MOCK_LOG"
    if [ -f "$MOCK_STATE/review-rc" ]; then
      rm -f "$MOCK_STATE/review-rc"
      emit "{\"schema_version\":$MOCK_REVIEW_CONTRACT,\"verdict\":\"REQUEST_CHANGES\",\"issues\":[{\"id\":\"R-01\",\"action\":\"FIX_CODE\",\"category\":\"CONTRACT_VIOLATION\",\"evidence_type\":\"DIRECT_MISMATCH\",\"basis_refs\":[\"approach.md:L1\"],\"code_refs\":[\"src/a.txt:L1-L1\"],\"reachable_scenario\":\"\",\"impact\":\"\",\"why_blocks_now\":\"x\",\"required_outcome\":\"y\",\"origin\":\"ROUND_1\",\"previous_issue_id\":\"\",\"fix_ref\":\"\",\"user_question\":\"\",\"options\":[]}]}"
    else
      emit "{\"schema_version\":$MOCK_REVIEW_CONTRACT,\"verdict\":\"APPROVE\",\"issues\":[]}"
    fi
    exit 0;;
  fixer)
    echo "fixer" >> "$MOCK_LOG"
    echo "fixed by fixer" >> src/a.txt
    [ ! -f "$MOCK_STATE/fixer-violation" ] || echo "BAD token by fixer" >> src/a.txt
    echo "- [fix round 1] R-01 ACCEPT: src/a.txt:L1" >> .agent-work/decisions.md
    if [ "$cli" = codex ]; then echo ok; else printf '{"result":"ok",%s}\n' "$usage"; fi
    exit 0;;
esac
# ---- 워커: 수정 프롬프트에만 진단 로그 경로(${TEST_LOG})가 있다 ----
if printf '%s' "$prompt" | grep -q 'fast-check/check-[0-9]*\.log'; then
  echo "check-fix" >> "$MOCK_LOG"
  printf '%s' "$prompt" | grep -o '[^ ]*fast-check/check-[0-9]*\.log' | head -1 > "$MOCK_STATE/check-fix-log-path"
  if [ -f "$MOCK_STATE/checkfix-undecided" ]; then
    rm -f "$MOCK_STATE/checkfix-undecided"
    emit '{"status":"UNDECIDED","undecided":[{"kind":"DOC_GAP","location":"src/a.txt","paths":["src/a.txt"],"decision_needed":"rule conflicts with approach","options":["follow rule","follow approach"]}],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}'
    exit 0
  fi
  if [ -f "$MOCK_STATE/checkfix-crash" ]; then   # 위반을 고치고 범위 밖도 건드린 직후 러너가 강제 종료된다(결과 JSON·호출 후 tree 없음)
    rm -f "$MOCK_STATE/checkfix-crash"
    grep -v 'BAD' src/a.txt > "$MOCK_STATE/a.fixed"; cat "$MOCK_STATE/a.fixed" > src/a.txt
    echo "crash leaked outside" >> src/outside.txt
    kill -KILL "$(cat .agent-work/.runner.lock/pid)"
    exit 0
  fi
  [ ! -f "$MOCK_STATE/checkfix-outside" ] || echo "check-fix leaked outside" >> src/outside.txt
  if [ ! -f "$MOCK_STATE/checkfix-noop" ]; then
    grep -v 'BAD' src/a.txt > "$MOCK_STATE/a.fixed"; cat "$MOCK_STATE/a.fixed" > src/a.txt
  fi
  emit "$done_json"; exit 0
fi
if printf '%s' "$prompt" | grep -q 'reviews/verify-[0-9-]*\.log'; then
  echo "verify-fix" >> "$MOCK_LOG"
  echo "verify fix by worker" >> src/a.txt
  [ ! -f "$MOCK_STATE/verifyfix-violation" ] || echo "BAD token by verify fix" >> src/a.txt
  emit "$done_json"; exit 0
fi
echo "worker" >> "$MOCK_LOG"
echo "impl by worker" >> src/a.txt
[ ! -f "$MOCK_STATE/worker-violation" ] || echo "BAD token by worker" >> src/a.txt
[ ! -f "$MOCK_STATE/worker-korean" ] || echo "BAD 토큰 by worker" >> "src/규칙.txt"
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
calls() { grep -c "^$1\$" "$MOCK_LOG" || true; }
seq_all() { paste -sd'|' "$MOCK_LOG"; }
last_record() { jq -r "$1" .agent-work/fast-check/last.json; }
flag() { : > "$MOCK_STATE/$1"; }
mode() { printf '%s' "$1" > "$MOCK_STATE/check-mode"; }
reset_tree() { # 소스·산출물·mock 플래그를 처음 상태로 (테스트 환경 정리 — 파이프라인 동작 아님). 합의 PASS 체크포인트는 남긴다
  git reset -q; git checkout -q -- src
  rm -f "$MOCK_STATE"/*
  rm -rf .agent-work/units .agent-work/implementation-context.json .agent-work/implementation-units.lock.json .agent-work/feature-scope.lock.json .agent-work/worker-baseline.tree \
    .agent-work/worker-baseline.guard.json .agent-work/worker-result.json .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/reviews/impl-attempt-* \
    .agent-work/.session-* .agent-work/worker-session.json .agent-work/usage.jsonl .agent-work/doc-gap-resume.json .agent-work/fast-check .agent-work/state.json \
    .agent-work/notify-done.sent .agent-work/live.log .agent-work/check-fix.pending.json .agent-work/.runner.lock .agent-work/doc-gap-resume.json.lost
  rm -f .agent-work/check-fix-* .agent-work/reviews/check-fix-* .agent-work/reviews/verify-*
  : > .agent-work/decisions.md
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
  set_timeout 120
}
restore_approach() { git checkout -q -- src 2>/dev/null; printf '# approach\n' > .agent-work/approach.md; fake_pass impl; }
interrupted_running() { # 러너가 review 단계 실행 중에 죽은 상태의 재개 힌트(산출물은 그대로)
  jq '.stage="review" | .status="RUNNING" | .reason=null | .detail=null' .agent-work/run-state.json > .agent-work/run-state.json.tmp && mv .agent-work/run-state.json.tmp .agent-work/run-state.json
}
resume_at_verify() { # 러너가 review 승인 직후 죽은 상태를 흉내 낸다(재개 힌트만 verify 로 — 승인·체크포인트는 그대로)
  jq '.stage="verify" | .status="RUNNING" | .reason=null' .agent-work/run-state.json > .agent-work/run-state.json.tmp && mv .agent-work/run-state.json.tmp .agent-work/run-state.json
}

# ===== 사례 A: 미설정 — 종전 흐름, 생략 명시, 실행·통과로 집계하지 않음 =====
reset_tree; set_check ""
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "A: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "worker|unit-test|reviewer|full-test|full-lint" ] || fail "A: 미설정 호출 순서가 종전과 다름: $(seq_all)"
grep -q '\[fast-check\] 생략(.*FAST_CHECK_CMD 미설정' "$TMP/run.log" || fail "A: 로그에 미설정 생략 표시가 없음"
grep -q '\[fast-check\] #[0-9]* 통과' "$TMP/run.log" && fail "A: 미설정인데 통과로 기록됨"
[ ! -e .agent-work/fast-check ] || fail "A: 미설정인데 검사 실행 기록(fast-check/)이 생김"
jq -e '.fast_check_retries==0' .agent-work/run-state.json >/dev/null || fail "A: run-state 의 fast_check_retries 가 0 이 아님"
pass "A: 미설정 — 종전 흐름 그대로, '생략(미설정)' 로그, 실행 기록 없음"

# ===== 사례 A2: FAST_CHECK_* 줄이 아예 없는 기존 config.sh — 같은 결과 =====
reset_tree
cp "$CFG" "$TMP/config.keep"
grep -v '^FAST_CHECK_' "$TMP/config.keep" > "$CFG"
grep -q '^FAST_CHECK_' "$CFG" && fail "A2: 픽스처 config 에 FAST_CHECK_ 줄이 남음"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "worker|unit-test|reviewer|full-test|full-lint" ] || fail "A2: 설정 줄이 없는 config 에서 종전 흐름이 아님(exit $rc): $(seq_all)"
grep -q '\[fast-check\] 생략(' "$TMP/run.log" || fail "A2: 생략 로그 없음"
cp "$TMP/config.keep" "$CFG"
pass "A2: FAST_CHECK_* 줄이 없는 기존 config.sh — 미설정으로 안전하게 동작"

# ===== 사례 B: 정상 — 첫 리뷰어 호출 전 1회, worktree 루트, 기록 =====
reset_tree; set_check "tools/check.sh"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "B: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "worker|unit-test|check|reviewer|full-test|full-lint" ] || fail "B: 호출 순서 불일치: $(seq_all)"
[ "$(cat "$MOCK_STATE/check-cwd")" = "$TMP/repo" ] && [ "$(cat "$MOCK_STATE/check-root")" = "$TMP/repo" ] || fail "B: 검사가 worktree 루트에서 실행되지 않음: $(cat "$MOCK_STATE/check-cwd")"
[ "$(cat "$MOCK_STATE/check-changed")" = "src/a.txt" ] || fail "B: FAST_CHECK_CHANGED_FILES 가 범위 안 변경 파일 목록이 아님: $(cat "$MOCK_STATE/check-changed")"
[ "$(wc -l < .agent-work/fast-check/history.jsonl | tr -d ' ')" -eq 1 ] || fail "B: 검사 실행 기록이 1건이 아님"
jq -e --arg root "$TMP/repo" '.version==1 and .status=="PASS" and .kind==null and .cmd=="tools/check.sh" and .cwd==$root and .exit_code==0 and .timed_out==false
  and (.duration_sec|type)=="number" and (.cmd_sha256|length)==64 and .tree_before==.tree_after and .index_modified==false and (.modified_paths|length)==0' .agent-work/fast-check/last.json >/dev/null \
  || fail "B: 실행 기록 계약 불일치: $(cat .agent-work/fast-check/last.json)"
grep -q '0 violations' "$(last_record .log)" || fail "B: 원본 로그가 보존되지 않음"
pass "B: 정상 — 첫 리뷰 전 검사 1회 → 리뷰 → TEST → LINT, worktree 루트 실행, 명령·로그·시간·결과 기록"

# ===== 사례 C: 첫 검사 위반 → 리뷰어 0회로 중단 → 워커 수정 → 재검사 통과 → 리뷰 → 최종 테스트·린트 =====
reset_tree; flag worker-violation
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "C: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "worker|unit-test|check|check-fix|check|reviewer|full-test|full-lint" ] || fail "C: 수정 → 재검사 → 리뷰 → 테스트 → 린트 순서가 아님: $(seq_all)"
[ "$(calls fixer)" -eq 0 ] || fail "C: 리뷰 JSON 없이 수정자가 호출됨"
[ "$(jq -sr '[.[].status] | join(",")' .agent-work/fast-check/history.jsonl)" = "VIOLATION,PASS" ] || fail "C: 실행 기록이 VIOLATION → PASS 가 아님"
grep -q '^\[no-bad-token\] src/a.txt:3: 금지 토큰 — BAD token by worker$' .agent-work/fast-check/check-0001.log || fail "C: 위반 진단(규칙·파일·위치·내용)이 보존되지 않음: $(cat .agent-work/fast-check/check-0001.log)"
[ "$(cat "$MOCK_STATE/check-fix-log-path")" = ".agent-work/fast-check/check-0001.log" ] || fail "C: 워커 수정 프롬프트에 진단 로그 경로가 없음: $(cat "$MOCK_STATE/check-fix-log-path")"
[ "$(ls -d .agent-work/reviews/impl-attempt-* | wc -l | tr -d ' ')" -eq 1 ] && [ "$(ls .agent-work/reviews/impl-attempt-01/reviewer-round-*.json | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "C: 리뷰 산출물이 실제 리뷰어 호출 1회분이 아님(위조된 리뷰 JSON 의심): $(ls -R .agent-work/reviews | paste -sd' ' -)"
grep -q 'BAD' src/a.txt && fail "C: 승인된 코드에 위반이 남아 있음"
jq -e '.fast_check_retries==1' .agent-work/run-state.json >/dev/null || fail "C: fast_check_retries 가 1 이 아님"
jq -e '(.delegated_choices|length)==2' .agent-work/worker-result.json >/dev/null || fail "C: 수정의 delegated_choices 가 리뷰 입력에 합쳐지지 않음"
[ -f .agent-work/check-fix-01-result.json ] || fail "C: 수정 결과 파일이 없음"
pass "C: 첫 검사 위반 — 리뷰어 호출 전에 멈추고 워커 수정 → 재검사 통과 → 리뷰 → TEST → LINT → DONE (진단 보존, 리뷰 JSON 위조 없음)"

# ===== 사례 D: 수정 뒤에도 위반 → 한도 소진, 리뷰어 0회 / 재실행도 모델 0회 / 직접 고치면 검사부터 재개 =====
reset_tree; flag worker-violation; flag checkfix-noop
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = FAST_CHECK_RETRIES_EXHAUSTED ] || fail "D: NEED_USER/FAST_CHECK_RETRIES_EXHAUSTED 기대(exit $rc, $(reason))"
[ "$(seq_all)" = "worker|unit-test|check|check-fix|check" ] || fail "D: 호출 순서 불일치: $(seq_all)"
[ "$(calls reviewer)" -eq 0 ] || fail "D: 첫 검사 실패인데 리뷰어가 호출됨"
[ ! -f .agent-work/approved.fingerprint ] && ! ls .agent-work/reviews/impl-attempt-* >/dev/null 2>&1 || fail "D: 검사 실패 상태에서 승인·리뷰 산출물이 생김"
jq -r '.detail' .agent-work/run-state.json | grep -q 'fast-check/check-0002.log' || fail "D: 중단 사유에 진단 로그 경로가 없음"
grep -q '\[SKILL REFERENCE\] NEED_USER(FAST_CHECK_RETRIES_EXHAUSTED)' "$TMP/run.log" || fail "D: 참조 문서 안내 줄이 없음"
rc="$(run_runner)"   # 아무것도 바꾸지 않은 재실행
[ "$rc" -eq 2 ] && [ "$(reason)" = FAST_CHECK_RETRIES_EXHAUSTED ] && [ "$(seq_all)" = "check" ] || fail "D: 재실행이 검사 1회·모델 0회가 아님(exit $rc, $(reason)): $(seq_all)"
[ "$(status)" != DONE ] && [ ! -f .agent-work/approved.fingerprint ] || fail "D: 실패 상태에서 DONE/승인으로 넘어감"
[ "$(wc -l < .agent-work/fast-check/history.jsonl | tr -d ' ')" -eq 3 ] && ls .agent-work/fast-check/check-000{1,2,3}.log >/dev/null || fail "D: 실행마다 로그·기록이 보존되지 않음"
grep -v 'BAD' src/a.txt > "$TMP/a.manual" && cat "$TMP/a.manual" > src/a.txt   # 사용자가 범위 안에서 직접 수정
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "check|reviewer|full-test|full-lint" ] || fail "D: 직접 수정 뒤 재실행이 검사 → 리뷰 → 테스트 순서가 아님(exit $rc): $(seq_all)"
pass "D: 한도 소진 — 리뷰어 0회·승인 없음, 재실행은 검사 1회·모델 0회, 직접 고친 뒤 같은 명령으로 검사부터 재개 → DONE"

# ===== 사례 E: 수정자 뒤 검사 — 위반이면 다음 리뷰어 0회 / 워커 수정 뒤 새 attempt 로 리뷰 =====
reset_tree; flag review-rc; flag fixer-violation; flag checkfix-noop
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = FAST_CHECK_RETRIES_EXHAUSTED ] || fail "E1: FAST_CHECK_RETRIES_EXHAUSTED 기대(exit $rc, $(reason))"
[ "$(seq_all)" = "worker|unit-test|check|reviewer|fixer|check|check-fix|check" ] || fail "E1: 호출 순서 불일치: $(seq_all)"
[ "$(calls reviewer)" -eq 1 ] || fail "E1: 수정자 뒤 검사 실패인데 다음 리뷰어가 호출됨"
jq -e '.next_step=="REVIEWER_PENDING" and .round==2' .agent-work/review-impl.json >/dev/null || fail "E1: 리뷰 체크포인트가 다음 라운드 리뷰 대기가 아님: $(cat .agent-work/review-impl.json)"
[ ! -f .agent-work/approved.fingerprint ] || fail "E1: 승인 지문이 생김"
reset_tree; flag review-rc; flag fixer-violation
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "E2: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "worker|unit-test|check|reviewer|fixer|check|check-fix|check|reviewer|full-test|full-lint" ] || fail "E2: 호출 순서 불일치: $(seq_all)"
jq -e '.next_step=="APPROVE" and .attempt==2 and .round==1' .agent-work/review-impl.json >/dev/null || fail "E2: 수정 뒤 리뷰가 새 attempt Round 1 이 아님: $(cat .agent-work/review-impl.json)"
grep -q 'fixed by fixer' src/a.txt && ! grep -q 'BAD' src/a.txt || fail "E2: 최종 코드가 수정자 변경 + 위반 제거 상태가 아님"
pass "E: 수정자 뒤 검사 — 실패면 다음 리뷰어 0회, 워커 수정 → 재검사 통과 → 새 attempt Round 1 리뷰(수정 전 리뷰 재사용 없음) → DONE"

# ===== 사례 F: 실행 오류 — 통과·생략·위반으로 숨기지 않고, 자동 수정 루프로 보내지 않는다 =====
expect_error() { # 사례 kind
  [ "$rc" -eq 2 ] && [ "$(reason)" = FAST_CHECK_ERROR ] || fail "$1: NEED_USER/FAST_CHECK_ERROR 기대(exit $rc, $(reason))"
  [ "$(last_record .status)" = ERROR ] && [ "$(last_record .kind)" = "$2" ] || fail "$1: 기록이 ERROR/$2 가 아님: $(cat .agent-work/fast-check/last.json)"
  jq -r '.detail' .agent-work/run-state.json | grep -q "$2" || fail "$1: 중단 사유에 kind($2)가 없음"
  [ "$(calls reviewer)" -eq 0 ] && [ "$(calls fixer)" -eq 0 ] && [ "$(calls check-fix)" -eq 0 ] || fail "$1: 실행 오류인데 모델(리뷰어·수정자·워커 수정)이 호출됨: $(seq_all)"
  [ "${3:-}" = had-approval ] || [ ! -f .agent-work/approved.fingerprint ] || fail "$1: 실행 오류인데 승인 지문이 생김"
  jq -e '.fast_check_retries==0' .agent-work/run-state.json >/dev/null || fail "$1: 실행 오류가 수정 한도를 소모함"
}
reset_tree; mode error
rc="$(run_runner)"; expect_error F1 UNEXPECTED_EXIT
[ "$(seq_all)" = "worker|unit-test|check" ] || fail "F1: 호출 순서 불일치: $(seq_all)"
grep -q 'checker crashed: internal error' "$(last_record .log)" && [ "$(last_record .exit_code)" = 2 ] || fail "F1: 원본 로그·종료 코드가 보존되지 않음"
rc="$(run_runner)"; expect_error F1-rerun UNEXPECTED_EXIT
[ "$(seq_all)" = "check" ] || fail "F1: 재실행이 검사 1회·모델 0회가 아님: $(seq_all)"
mode default
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "check|reviewer|full-test|full-lint" ] || fail "F1: 검사 복구 뒤 재실행이 검사 → 리뷰 → 테스트가 아님(exit $rc): $(seq_all)"
reset_tree; set_check "tools/missing-checker.sh"
rc="$(run_runner)"; expect_error F2 COMMAND_NOT_RUNNABLE
[ "$(last_record .exit_code)" = 127 ] || fail "F2: 도구 누락의 종료 코드가 127 이 아님"
set_check "tools/check.sh"
reset_tree; mode timeout; set_timeout 1
t0=$SECONDS; rc="$(run_runner)"; elapsed=$((SECONDS - t0)); expect_error F3 TIMEOUT
[ "$elapsed" -lt 20 ] || fail "F3: 타임아웃 검사가 ${elapsed}s 걸림(제한 1s — 명령이 끝날 때까지 기다림)"
[ "$(last_record .timed_out)" = true ] && [ -f .agent-work/fast-check/check-0001.timeout ] || fail "F3: 타임아웃 표식이 기록되지 않음"
reset_tree; mode silent
rc="$(run_runner)"; expect_error F4 NO_DIAGNOSTICS
reset_tree; set_timeout abc
rc="$(run_runner)"; expect_error F5 INVALID_CONFIG
[ "$(calls check)" -eq 0 ] || fail "F5: 잘못된 설정인데 검사 명령이 실행됨"
pass "F: 실행 오류(종료 코드·도구 누락·타임아웃·무진단·설정 오류) — FAST_CHECK_ERROR, 모델 0회·한도 미소모, 재실행도 같은 진단, 복구 뒤 검사부터 재개"

# ===== 사례 G: 읽기 전용 위반 — 변경 감지, 보존(원복 없음), 바뀐 코드는 검사·리뷰를 다시 지난다 =====
reset_tree; mode mutate
rc="$(run_runner)"; expect_error G1 WORKTREE_MODIFIED
grep -q 'autofixed by checker' src/a.txt || fail "G1: 검사가 만든 변경을 원복함"
jq -e '.modified_paths==["M src/a.txt"] and (.out_of_scope_paths|length)==0 and .tree_before!=.tree_after' .agent-work/fast-check/last.json >/dev/null || fail "G1: 변경 경로 기록 불일치: $(cat .agent-work/fast-check/last.json)"
mode default
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "check|reviewer|full-test|full-lint" ] || fail "G1: 재실행이 검사 → 리뷰가 아님(exit $rc): $(seq_all)"
grep -q 'autofixed by checker' .agent-work/reviews/impl-attempt-01/diff-round-01.patch || fail "G1: 리뷰어가 받은 diff 에 검사 중 바뀐 코드가 없음"
reset_tree; mode mutate-outside
rc="$(run_runner)"; expect_error G2 WORKTREE_MODIFIED
grep -q 'formatted by checker' src/outside.txt || fail "G2: 범위 밖 변경을 원복함"
jq -e '.out_of_scope_paths==["src/outside.txt"]' .agent-work/fast-check/last.json >/dev/null || fail "G2: 범위 밖 경로가 기록되지 않음: $(cat .agent-work/fast-check/last.json)"
jq -r '.detail' .agent-work/run-state.json | grep -q 'feature-scope 밖: src/outside.txt' || fail "G2: 중단 사유에 범위 밖 경로가 없음"
reset_tree; mode index
rc="$(run_runner)"; expect_error G3 INDEX_MODIFIED
[ "$(git diff --cached --name-only)" = "src/a.txt" ] || fail "G3: 검사가 바꾼 index 를 자동 복구함"
# G4: 승인 뒤(verify 재개 힌트) 검사가 범위 안 코드를 바꾸면 그 승인은 재사용되지 않는다 — 통과한 재검사 뒤에 리뷰어가 다시 본다
reset_tree
rc="$(run_runner)"; [ "$rc" -eq 0 ] || fail "G4: 픽스처 DONE 실패(exit $rc)"
resume_at_verify; mode mutate
rc="$(run_runner)"; expect_error G4 WORKTREE_MODIFIED had-approval
( source "$CFG"; ! impl_approval_current ) 2>/dev/null || fail "G4: 검사가 코드를 바꾼 뒤에도 기존 승인이 현재 코드에 유효하다고 판정됨"
[ "$(calls full-test)" -eq 0 ] || fail "G4: 검사가 코드를 바꿨는데 verify 로 넘어감"
mode default
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "check|reviewer|full-test|full-lint" ] || fail "G4: 바뀐 코드가 재리뷰 없이 통과함(exit $rc): $(seq_all)"
jq -e '.attempt==2' .agent-work/review-impl.json >/dev/null || fail "G4: 기존 승인이 무효화되지 않음(새 attempt 아님)"
pass "G: 읽기 전용 위반(범위 안·범위 밖·index) — FAST_CHECK_ERROR, 변경 보존, 바뀐 코드는 재검사·재리뷰, 기존 승인 무효"

# ===== 사례 H: 기존 성공 기록 오용 방지 =====
# H1: 검사 통과 → 승인 → (verify 재개) 규칙 입력이 바뀌어 지금은 위반 — 과거 PASS 기록·승인으로 verify 에 들어가지 않는다
reset_tree
rc="$(run_runner)"; [ "$rc" -eq 0 ] || fail "H1: 픽스처 DONE 실패(exit $rc)"
[ "$(last_record .status)" = PASS ] || fail "H1: 픽스처에 PASS 기록이 없음"
resume_at_verify; mode strict; flag checkfix-noop
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = FAST_CHECK_RETRIES_EXHAUSTED ] || fail "H1: FAST_CHECK_RETRIES_EXHAUSTED 기대(exit $rc, $(reason))"
[ "$(seq_all)" = "check|check-fix|check" ] && [ "$(calls full-test)" -eq 0 ] || fail "H1: 과거 승인·PASS 기록으로 검사를 건너뜀: $(seq_all)"
grep -q 'verify 로 바로 가지 않고 review 를 지난다' "$TMP/run.log" || fail "H1: verify 직행 차단 로그가 없음"
# H3: 미설정으로 승인 → 검사를 새로 설정(통과) → 검사 1회 뒤 리뷰어 0회로 승인 재사용 → TEST → DONE
reset_tree; set_check ""
rc="$(run_runner)"; [ "$rc" -eq 0 ] || fail "H3: 픽스처 DONE 실패(exit $rc)"
resume_at_verify; set_check "tools/check.sh"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "check|full-test|full-lint" ] || fail "H3: 새로 설정한 검사를 지난 뒤 승인 재사용 → 테스트가 아님(exit $rc): $(seq_all)"
# H2: 미설정으로 승인 → 검사를 새로 설정(위반) → TEST 0회, DONE 아님
reset_tree; set_check ""
rc="$(run_runner)"; [ "$rc" -eq 0 ] || fail "H2: 픽스처 DONE 실패(exit $rc)"
resume_at_verify; set_check "tools/check.sh"; mode strict
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(status)" = NEED_USER ] || fail "H2: NEED_USER 기대(exit $rc, $(status)/$(reason))"
[ "$(calls check)" -ge 1 ] && [ "$(calls full-test)" -eq 0 ] && [ "$(calls reviewer)" -eq 0 ] || fail "H2: 새로 설정한 검사의 위반을 건너뛰고 verify 로 감: $(seq_all)"
[ "$(reason)" = WORKER_SESSION_MISMATCH ] || fail "H2: 피처 도중 검사를 새로 켠 뒤의 워커 수정은 세션 전제 불일치로 멈춰야 함(실제 $(reason))"
pass "H: 승인·과거 PASS 기록이 있어도 설정된 검사를 먼저 지남 — 위반이면 TEST 0회, 통과면 리뷰어 0회로 승인 재사용, 피처 도중 새로 켠 검사의 자동 수정은 세션 불일치로 중단"

# ===== 사례 I: 워커 수정의 기존 게이트 — 범위 밖 수정·미결정 =====
reset_tree; set_check "tools/check.sh"; flag worker-violation; flag checkfix-outside
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = SCOPE_VIOLATION ] || fail "I1: SCOPE_VIOLATION 기대(exit $rc, $(reason))"
grep -q 'check-fix leaked outside' src/outside.txt || fail "I1: 범위 밖 변경을 원복함"
[ "$(calls reviewer)" -eq 0 ] || fail "I1: 범위 위반인데 리뷰어가 호출됨"
rc="$(run_runner)"   # 아무것도 정리하지 않은 재실행 — 위반은 이미 고쳐져 있어 검사는 통과할 상태다
[ "$rc" -eq 2 ] && [ "$(reason)" = SCOPE_VIOLATION ] && [ ! -s "$MOCK_LOG" ] || fail "I1: 범위 위반으로 멈춘 수정 턴을 그대로 재실행했는데 다시 멈추지 않음(exit $rc, $(reason)): $(seq_all)"
grep -q 'check-fix leaked outside' src/outside.txt && [ "$(status)" != DONE ] || fail "I1: 재실행이 범위 밖 변경을 원복했거나 DONE 으로 넘어감"
git checkout -q -- src/outside.txt   # 사용자가 범위 밖 변경을 정리
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "check|reviewer|full-test|full-lint" ] || fail "I1: 범위 밖 변경 정리 뒤 그 턴의 결과로 이어가지 않음(exit $rc): $(seq_all)"
jq -e '.fast_check_retries==1' .agent-work/run-state.json >/dev/null && jq -e '.active==false and .outcome=="DONE"' .agent-work/check-fix.pending.json >/dev/null || fail "I1: 재개로 확정된 수정 턴이 한도·진행 기록에 반영되지 않음"
reset_tree; flag worker-violation; flag checkfix-undecided
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] || fail "I2: UNDECIDED 기대(exit $rc, $(reason))"
jq -e '.fast_check_retries==0' .agent-work/run-state.json >/dev/null || fail "I2: 미결정 반환이 수정 한도를 소모함"
[ "$(calls reviewer)" -eq 0 ] || fail "I2: 미결정인데 리뷰어가 호출됨"
tag="$(jq -r '.gaps[0].tag' .agent-work/doc-gap-resume.json)"; question="$(jq -r '.gaps[0].question' .agent-work/doc-gap-resume.json)"
printf -- '- [USER-QUESTION][scope=impl][%s] %s → follow rule\n' "$tag" "$question" >> .agent-work/decisions.md
printf '\n## 결정\n규칙을 따른다 [%s]\n' "$tag" >> .agent-work/approach.md
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "I2: 사용자 결정 뒤 DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "check|check-fix|check|reviewer|full-test|full-lint" ] || fail "I2: 사용자 결정 뒤 검사 → 수정 → 재검사 → 리뷰 순서가 아님: $(seq_all)"
restore_approach   # 다음 사례를 위해 approach.md 와 impl PASS 지문 원복
pass "I: 워커 수정의 범위 밖 변경 → SCOPE_VIOLATION(보존) / 미결정 → UNDECIDED(한도 미소모) → 사용자 결정 뒤 검사 → 수정 → 재검사 → 리뷰 → DONE"

# ===== 사례 M: 변경 파일 목록은 실제 경로 문자열 — 한글 파일명의 위반을 놓치지 않는다 =====
reset_tree; mode list; flag worker-korean; flag checkfix-noop
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = FAST_CHECK_RETRIES_EXHAUSTED ] || fail "M: 한글 파일의 위반으로 FAST_CHECK_RETRIES_EXHAUSTED 기대(exit $rc, $(reason)) — 목록: $(cat "$MOCK_STATE/check-changed" 2>/dev/null | paste -sd'|' -)"
grep -qx 'src/규칙.txt' "$MOCK_STATE/check-changed" || fail "M: 변경 파일 목록에 실제 경로 src/규칙.txt 가 없음: $(paste -sd'|' "$MOCK_STATE/check-changed")"
grep -q '["\\]' "$MOCK_STATE/check-changed" && fail "M: 변경 파일 목록에 git 인용 표기가 섞임: $(paste -sd'|' "$MOCK_STATE/check-changed")"
grep -q '^\[no-bad-token\] src/규칙.txt:2: ' "$(last_record .log)" || fail "M: 진단에 한글 파일 위반이 없음: $(cat "$(last_record .log)")"
[ "$(calls reviewer)" -eq 0 ] || fail "M: 위반이 남았는데 리뷰어가 호출됨"
pass "M: 변경 파일 목록이 한글 경로를 실제 문자열로 전달 — 목록 기반 검사가 그 파일의 위반을 잡는다"

# ===== 사례 N: 타임아웃 뒤 TERM 을 무시하는 검사 자식까지 정리하고 나서 사후 비교 =====
reset_tree; mode timeout-stubborn; set_timeout 1
rc="$(run_runner)"; expect_error N TIMEOUT
sleep 5   # 정리되지 않았다면 자식이 4초 시점에 src/a.txt 를 바꾼다
grep -q 'late write by checker child' src/a.txt && fail "N: 타임아웃 뒤에도 검사 자식 프로세스가 살아남아 소스를 바꿈"
[ "$( (source "$CFG"; snapshot_worktree_tree) 2>/dev/null )" = "$(last_record .tree_after)" ] || fail "N: 사후 스냅샷 이후 작업 트리가 바뀜(정리 전에 스냅샷함)"
pass "N: 타임아웃 — 프로세스 그룹 단위로 TERM 을 무시하는 자식까지 정리한 뒤 사후 비교, 늦은 소스 변경 없음"

# ===== 사례 O: 수정 턴 도중 러너 강제 종료 → 재실행은 범위 검사 없이 넘어가지 않는다 =====
sed -i.bak 's|^WORKER_CLI=.*|WORKER_CLI="claude"|' "$CFG" && rm -f "$CFG.bak"   # 중단된 CLI 호출의 재개 규칙은 CLI 마다 다르다(codex 는 resume marker) — 이 사례는 claude 규약으로 고정
reset_tree; flag worker-violation; flag checkfix-crash
rc="$(run_runner 2>/dev/null)"
[ "$rc" -ne 0 ] && [ ! -f .agent-work/check-fix-01-after.tree ] && [ ! -f .agent-work/check-fix-01-result.json ] || fail "O: 픽스처 — 수정 턴 도중 강제 종료 상태가 만들어지지 않음(exit $rc)"
rc="$(run_runner)"   # 체크포인트를 건드리지 않은 재실행 — 위반은 고쳐져 있고 범위 밖 변경이 남아 있다
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] || fail "O: WORKER_OUTCOME_UNCERTAIN 기대(exit $rc, $(status)/$(reason)): $(seq_all)"
[ ! -s "$MOCK_LOG" ] || fail "O: 중단된 수정 턴 판정 전에 검사·모델이 호출됨: $(seq_all)"
grep -q 'crash leaked outside' src/outside.txt && [ "$(status)" != DONE ] && [ ! -f .agent-work/approved.fingerprint ] || fail "O: 범위 밖 변경을 원복했거나 승인·DONE 으로 넘어감"
git checkout -q "$(cat .agent-work/check-fix-01-before.tree)" -- src && git reset -q   # 사용자가 호출 전 tree 로 명시적으로 되돌림
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "O: 호출 전 tree 로 되돌린 뒤 DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "check|check-fix|check|reviewer|full-test|full-lint" ] || fail "O: 복구 뒤 검사 → 수정 턴 1회 → 재검사 → 리뷰 순서가 아님(이중 적용 의심): $(seq_all)"
[ "$(cat src/outside.txt)" = "outside base" ] && ! grep -q 'BAD' src/a.txt || fail "O: 최종 코드에 범위 밖 변경 또는 위반이 남음"
sed -i.bak 's|^WORKER_CLI=.*|WORKER_CLI=""|' "$CFG" && rm -f "$CFG.bak"
pass "O: 수정 턴 도중 강제 종료 — 재실행은 검사·모델 0회로 WORKER_OUTCOME_UNCERTAIN(변경 보존), 호출 전 tree 복구 뒤에만 수정 턴 1회 재개 → DONE"

# ===== 사례 R: codex 워커 — 거부된 호출(SESSION_RESUME_UNCERTAIN)이 resume marker 를 지우지 않는다 =====
# unit 워커 턴이 codex 세션(원장)을 확정하므로 수정 턴은 exec resume 이고, 호출 직전에 marker 가 기록된다. 그 호출 도중 러너가 죽으면 marker 가 남는다.
sed -i.bak 's|^WORKER_CLI=.*|WORKER_CLI="codex"|' "$CFG" && rm -f "$CFG.bak"
MARKER=.agent-work/.session-feature-worker.resume-pending.json
reset_tree; flag worker-violation; flag checkfix-crash
rc="$(run_runner 2>/dev/null)"
[ "$rc" -ne 0 ] && [ -f "$MARKER" ] && [ ! -f .agent-work/check-fix-01-after.tree ] || fail "R: 픽스처 — codex resume 도중 강제 종료 상태(marker 남음)가 만들어지지 않음(exit $rc)"
marker_inv="$(jq -r '.invocation_id' "$MARKER")"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] && [ ! -s "$MOCK_LOG" ] && [ -f "$MARKER" ] || fail "R: 중단된 수정 턴 판정(WORKER_OUTCOME_UNCERTAIN·호출 0회·marker 유지) 기대(exit $rc, $(reason)): $(seq_all)"
git checkout -q "$(cat .agent-work/check-fix-01-before.tree)" -- src && git reset -q   # 사용자가 호출 전 tree 로 되돌림(marker 는 아직 확인하지 않았다)
for i in 1 2; do   # 거부된 호출이 marker 를 지우면 두 번째 재실행에서 같은 스레드로 프롬프트가 나간다
  rc="$(run_runner)"
  [ "$rc" -eq 1 ] && grep -q 'SESSION_RESUME_UNCERTAIN' "$TMP/run.log" || fail "R: 재실행 $i 이 SESSION_RESUME_UNCERTAIN 으로 멈추지 않음(exit $rc, $(status)/$(reason)): $(seq_all)"
  [ "$(calls check-fix)" -eq 0 ] && [ "$(calls worker)" -eq 0 ] || fail "R: 재실행 $i 에서 확인되지 않은 스레드로 워커가 호출됨: $(seq_all)"
  [ -f "$MARKER" ] && [ "$(jq -r '.invocation_id' "$MARKER")" = "$marker_inv" ] || fail "R: 거부된 호출(재실행 $i)이 resume marker 를 지우거나 바꿈"
  [ "$(status)" != DONE ] && [ ! -f .agent-work/approved.fingerprint ] || fail "R: marker 가 남은 상태에서 승인·DONE 으로 넘어감"
done
mv "$MARKER" "$MARKER.checked"   # 사람이 중복 전송 여부를 확인하고 marker 를 치움
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] && [ "$(seq_all)" = "check|check-fix|check|reviewer|full-test|full-lint" ] || fail "R: marker 를 치운 뒤 검사 → 수정 턴 1회 → 재검사 → 리뷰가 아님(exit $rc, $(status)/$(reason)): $(seq_all)"
[ ! -f "$MARKER" ] || fail "R: 수용된 resume 호출의 marker 가 해제되지 않음"
sed -i.bak 's|^WORKER_CLI=.*|WORKER_CLI=""|' "$CFG" && rm -f "$CFG.bak"
pass "R: codex 워커 — 거부된 호출은 resume marker 를 지우지 않음(재실행 반복에도 모델 0회), marker 를 치운 뒤에만 수정 턴 재개 → DONE"

# ===== 사례 P: 미결정 수정 턴이 체크포인트 기록 전에 중단 → 질문을 잃지 않는다 =====
# run_worker 는 결과 JSON·호출 후 tree 를 남긴 뒤에 doc-gap-resume.json 을 쓴다. 그 사이에 러너가 죽은 상태를 만든다: 정상 UNDECIDED 중단에서 체크포인트만 없앤다.
reset_tree; flag worker-violation; flag checkfix-undecided
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] || fail "P: 픽스처 — 미결정 수정 턴 중단 상태가 아님(exit $rc, $(reason))"
# P0: 정상 종료한 미결정 턴은 사용자에게 돌아가기 전에 진행 기록을 닫는다(한도 미소모) — 재실행의 재개 판정에 기대지 않는다
jq -e '.active==false and .outcome=="UNDECIDED" and .tag=="check-fix-01"' .agent-work/check-fix.pending.json >/dev/null && jq -e '.fast_check_retries==0' .agent-work/run-state.json >/dev/null \
  || fail "P0: 미결정을 사용자에게 돌려줬는데 수정 턴 진행 기록이 active 로 남음: $(cat .agent-work/check-fix.pending.json)"
jq -e '.next_step=="WAITING_USER" and .origin=="worker"' .agent-work/doc-gap-resume.json >/dev/null || fail "P0: 미결정 체크포인트가 없음"
cp .agent-work/check-fix.pending.json "$TMP/pending.closed"
rc="$(run_runner)"   # 답 없이 재실행 — 닫힌 기록을 다시 판정하지 않고 사용자 대기
[ "$rc" -eq 2 ] && [ "$(status)" = NEED_USER ] && [ ! -s "$MOCK_LOG" ] && cmp -s .agent-work/check-fix.pending.json "$TMP/pending.closed" || fail "P0: 답 없는 재실행이 호출 0회·기록 불변의 사용자 대기가 아님(exit $rc, $(status)/$(reason)): $(seq_all)"
# 체크포인트 기록 전에 러너가 죽은 상태(진행 기록은 아직 active, 체크포인트 없음)를 만든다 — 이전 버전이 남긴 active 기록의 복구 경로이기도 하다
reopen_pending() { jq '.active=true | del(.outcome, .closed_at)' .agent-work/check-fix.pending.json > .agent-work/check-fix.pending.json.tmp && mv .agent-work/check-fix.pending.json.tmp .agent-work/check-fix.pending.json; }
reopen_pending
mv .agent-work/doc-gap-resume.json .agent-work/doc-gap-resume.json.lost; interrupted_running
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] || fail "P: 체크포인트 없이 중단된 미결정 턴의 재실행이 NEED_USER/UNDECIDED 가 아님(exit $rc, $(status)/$(reason)): $(seq_all)"
[ ! -s "$MOCK_LOG" ] || fail "P: 미결정 복구 전에 검사·모델이 호출됨: $(seq_all)"
jq -e '.next_step=="WAITING_USER" and .origin=="worker" and (.gaps|length)==1 and .gaps[0].question=="rule conflicts with approach" and .gaps[0].paths==["src/a.txt"]' .agent-work/doc-gap-resume.json >/dev/null \
  || fail "P: 미결정이 체크포인트로 복구되지 않음: $(cat .agent-work/doc-gap-resume.json 2>/dev/null)"
[ "$(jq -r '.source_tree' .agent-work/doc-gap-resume.json)" = "$(cat .agent-work/check-fix-01-after.tree)" ] || fail "P: 복구된 체크포인트의 source tree 가 그 턴의 호출 후 tree 가 아님"
jq -e '.active==false and .outcome=="UNDECIDED"' .agent-work/check-fix.pending.json >/dev/null && jq -e '.fast_check_retries==0' .agent-work/run-state.json >/dev/null || fail "P: 진행 기록·한도 상태 불일치"
[ ! -f .agent-work/approved.fingerprint ] && [ ! -s .agent-work/decisions.md ] || fail "P: 사용자 답 없이 승인·결정이 생김"
rc="$(run_runner)"   # 답 없이 재실행 — 여전히 사용자 대기
[ "$rc" -eq 2 ] && [ "$(status)" = NEED_USER ] && [ "$(calls reviewer)" -eq 0 ] && [ "$(calls check-fix)" -eq 0 ] || fail "P: 답 없는 재실행이 사용자 대기가 아님(exit $rc, $(status)/$(reason)): $(seq_all)"
tag="$(jq -r '.gaps[0].tag' .agent-work/doc-gap-resume.json)"; question="$(jq -r '.gaps[0].question' .agent-work/doc-gap-resume.json)"
printf -- '- [USER-QUESTION][scope=impl][%s] %s → follow rule\n' "$tag" "$question" >> .agent-work/decisions.md
printf '\n## 결정\n규칙을 따른다 [%s]\n' "$tag" >> .agent-work/approach.md
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] && [ "$(seq_all)" = "check|check-fix|check|reviewer|full-test|full-lint" ] || fail "P: 사용자 결정 뒤 검사 → 수정 → 재검사 → 리뷰가 아님(exit $rc, $(status)/$(reason)): $(seq_all)"
jq -e '.fast_check_retries==1' .agent-work/run-state.json >/dev/null || fail "P: 복구된 미결정 턴이 한도를 소모했거나 수정 턴이 세어지지 않음"
restore_approach
# P2: 같은 중단인데 작업 트리가 그 턴의 호출 후 tree 와 다르다 → 미결정을 다시 기록하지 않고 멈춘다
reset_tree; flag worker-violation; flag checkfix-undecided
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] || fail "P2: 픽스처 실패(exit $rc, $(reason))"
reopen_pending
mv .agent-work/doc-gap-resume.json .agent-work/doc-gap-resume.json.lost; interrupted_running
echo "edited after the interrupted turn" >> src/a.txt
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] && [ ! -s "$MOCK_LOG" ] || fail "P2: WORKER_OUTCOME_UNCERTAIN·호출 0회 기대(exit $rc, $(reason)): $(seq_all)"
[ ! -f .agent-work/doc-gap-resume.json ] && jq -e '.active==true' .agent-work/check-fix.pending.json >/dev/null || fail "P2: 다른 코드 상태 위에 미결정을 기록했거나 진행 기록을 닫음"
jq -r '.detail' .agent-work/run-state.json | grep -q 'rule conflicts with approach' || fail "P2: 중단 사유에 미결정 항목이 없음"
# P3: 이전 버전이 남긴 상태(체크포인트는 있고 진행 기록만 active) — 재개 판정이 종전대로 닫고 사용자 결정 경로로 간다
reset_tree; flag worker-violation; flag checkfix-undecided
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] || fail "P3: 픽스처 실패(exit $rc, $(reason))"
reopen_pending
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(status)" = NEED_USER ] && [ ! -s "$MOCK_LOG" ] && jq -e '.active==false and .outcome=="UNDECIDED"' .agent-work/check-fix.pending.json >/dev/null \
  || fail "P3: 남아 있던 active 기록이 재개 판정으로 닫히지 않음(exit $rc, $(status)/$(reason)): $(seq_all)"
pass "P: 미결정 수정 턴은 사용자에게 돌아가기 전에 진행 기록을 닫는다(한도 미소모, 남은 active 기록은 재개 판정이 닫음) / 체크포인트 전에 중단 — 재실행은 호출 0회로 미결정 복구 → NEED_USER(UNDECIDED), 결정 뒤 수정 재개 → DONE / tree 가 달라졌으면 WORKER_OUTCOME_UNCERTAIN"

# ===== 사례 Q: 끝난 수정 턴의 확정 도중 중단 → 재실행이 다시 확정해도 한 번만 반영 =====
reset_tree; flag worker-violation
rc="$(run_runner)"; [ "$rc" -eq 0 ] && jq -e '.fast_check_retries==1' .agent-work/run-state.json >/dev/null || fail "Q: 픽스처 DONE 실패(exit $rc)"
jq -e '.retries_before==0 and .outcome=="DONE"' .agent-work/check-fix.pending.json >/dev/null && [ -f .agent-work/check-fix-01-merge-base.json ] || fail "Q: 진행 기록에 호출 전 한도 값·병합 기준 사본이 없음"
merged="$(jq -Sc . .agent-work/worker-result.json)"
for i in 1 2; do   # 한도 저장·병합까지 끝났고 진행 기록만 닫히지 않은 상태를 두 번 반복한다
  jq '.active=true | del(.outcome, .closed_at)' .agent-work/check-fix.pending.json > .agent-work/check-fix.pending.json.tmp && mv .agent-work/check-fix.pending.json.tmp .agent-work/check-fix.pending.json
  interrupted_running
  rc="$(run_runner)"
  [ "$rc" -eq 0 ] && [ "$(status)" = DONE ] && [ "$(calls check-fix)" -eq 0 ] || fail "Q: 재확정 실행 $i 이 워커 재호출 없이 DONE 이 아님(exit $rc, $(status)/$(reason)): $(seq_all)"
  jq -e '.fast_check_retries==1' .agent-work/run-state.json >/dev/null || fail "Q: 같은 수정 턴을 다시 확정하면서 한도를 또 셈(재확정 $i): $(jq -c '.fast_check_retries' .agent-work/run-state.json)"
  [ "$(jq -Sc . .agent-work/worker-result.json)" = "$merged" ] || fail "Q: 같은 수정 결과가 리뷰 입력에 두 번 합쳐짐(재확정 $i): delegated_choices $(jq '.delegated_choices|length' .agent-work/worker-result.json)"
  jq -e '.active==false and .outcome=="DONE"' .agent-work/check-fix.pending.json >/dev/null || fail "Q: 재확정 뒤 진행 기록이 닫히지 않음"
done
pass "Q: 수정 턴 확정 도중 중단 — 재실행이 같은 DONE 을 다시 확정해도 한도 1회·리뷰 입력 병합 1회"

# ===== 사례 L: verify 실패의 워커 수정 뒤 리뷰로 돌아오는 경로도 검사를 지난다 =====
reset_tree; flag fail-full-test
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || fail "L1: DONE 기대(exit $rc, $(status)/$(reason))"
[ "$(seq_all)" = "worker|unit-test|check|reviewer|full-test|verify-fix|check|reviewer|full-test|full-lint" ] || fail "L1: verify 수정 뒤 검사 → 리뷰 → 테스트 순서가 아님: $(seq_all)"
jq -e '.attempt==2 and .next_step=="APPROVE"' .agent-work/review-impl.json >/dev/null || fail "L1: verify 수정 뒤 리뷰가 새 attempt 가 아님(수정 전 승인 재사용)"
# 그 수정이 위반을 만들면 리뷰어 재호출 없이 멈춘다(검사 수정 한도는 verify 한도와 따로 센다)
reset_tree; flag fail-full-test; flag verifyfix-violation; flag checkfix-noop
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = FAST_CHECK_RETRIES_EXHAUSTED ] || fail "L2: FAST_CHECK_RETRIES_EXHAUSTED 기대(exit $rc, $(reason))"
[ "$(seq_all)" = "worker|unit-test|check|reviewer|full-test|verify-fix|check|check-fix|check" ] || fail "L2: 호출 순서 불일치: $(seq_all)"
[ "$(calls reviewer)" -eq 1 ] && [ "$(status)" != DONE ] || fail "L2: verify 수정이 만든 위반이 리뷰·DONE 으로 넘어감"
jq -e '.test_retries==1 and .fast_check_retries==1' .agent-work/run-state.json >/dev/null || fail "L2: verify 한도와 검사 수정 한도가 따로 세어지지 않음: $(jq -c '{test_retries, fast_check_retries}' .agent-work/run-state.json)"
( source "$CFG"; ! impl_approval_current ) 2>/dev/null || fail "L2: verify 수정 전의 승인이 여전히 유효하다고 판정됨"
pass "L: verify 실패의 워커 수정 뒤에도 검사 → 새 attempt 리뷰 → 테스트, 수정이 만든 위반은 리뷰어 0회로 중단(한도는 verify 와 따로)"

# ===== 사례 K: 혼합 설치 — fast-check.sh 없음 → 모델 호출 전 중단 =====
reset_tree
mv .claude/skills/feature/scripts/fast-check.sh "$TMP/fast-check.sh.keep"
rc="$(run_runner)"
[ "$rc" -eq 1 ] && grep -q '스크립트 없음: fast-check.sh' "$TMP/run.log" && [ ! -s "$MOCK_LOG" ] || fail "K: 러너가 fast-check.sh 누락을 모델 호출 전에 막지 않음(exit $rc): $(seq_all)"
bash .claude/skills/feature/scripts/impl-review-loop.sh > "$TMP/run.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q '스크립트 없음: .*fast-check.sh' "$TMP/run.log" && [ ! -s "$MOCK_LOG" ] || fail "K: 리뷰 루프가 fast-check.sh 누락을 막지 않음(exit $rc)"
mv "$TMP/fast-check.sh.keep" .claude/skills/feature/scripts/fast-check.sh
pass "K: scripts/fast-check.sh 누락(혼합 설치) — 러너·리뷰 루프 모두 모델 0회로 중단"

# ===== 사례 J: --feature worktree — 검사는 피처 worktree 루트에서, 위반 중단 상태의 finalize 는 거부 =====
SRC="$TMP/wt/proj"; WT="$TMP/wt/proj-feature-fc"
mkdir -p "$SRC/.claude/hooks" "$SRC/.claude/skills" "$SRC/.codex/hooks"
cp -R "$TMP/repo/.claude/skills/feature" "$SRC/.claude/skills/feature" && cp "$TMP/repo/.claude/hooks/core_rules.md" "$SRC/.claude/hooks/" || fail "J: 픽스처 복사 실패"
printf '{"hooks":{}}\n' > "$SRC/.claude/settings.json"; printf '#!/bin/sh\nexit 0\n' > "$SRC/.codex/hooks/worker_guard.sh"
cd "$SRC" || exit 1
git init -q -b main
printf '.agent-work/\n.claude/\n.codex/\n' > .gitignore
mkdir -p src tools && echo "a base" > src/a.txt && echo "outside base" > src/outside.txt && cp "$TMP/repo/tools/check.sh" tools/check.sh
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
rm -f "$MOCK_STATE"/*
run_feature() { : > "$MOCK_LOG"; (cd "$SRC" && bash "$SRC/$RUN" --feature fc "$@") > "$TMP/run.log" 2>&1; echo $?; }
rc="$(run_feature)"
[ "$rc" -eq 3 ] && [ -d "$WT" ] || fail "J: 첫 실행 exit 3(DESIGN_MISSING) + worktree 생성 기대(exit $rc)"
for doc in request design implementation approach; do printf '# %s\n' "$doc" > "$WT/.agent-work/$doc.md"; done
printf '\n## 01\nunit 01 contract\n' >> "$WT/.agent-work/implementation.md"
printf '{"version":1,"files":["src/a.txt","src/규칙.txt"],"new_file_roots":[]}\n' > "$WT/.agent-work/feature-scope.json"
write_units "$WT/.agent-work"
flag worker-violation; flag checkfix-noop
rc="$(run_feature)"
[ "$rc" -eq 2 ] && [ "$(jq -r .reason "$WT/.agent-work/run-state.json")" = FAST_CHECK_RETRIES_EXHAUSTED ] || fail "J: worktree 모드에서 FAST_CHECK_RETRIES_EXHAUSTED 기대(exit $rc, $(jq -r .reason "$WT/.agent-work/run-state.json"))"
[ "$(cat "$MOCK_STATE/check-cwd")" = "$WT" ] && [ "$(cat "$MOCK_STATE/check-root")" = "$WT" ] || fail "J: 검사가 피처 worktree 루트가 아닌 곳에서 실행됨: $(cat "$MOCK_STATE/check-cwd") (기대 $WT)"
[ -f "$WT/.agent-work/fast-check/check-0001.log" ] && [ ! -e "$SRC/.agent-work/fast-check" ] || fail "J: 검사 산출물이 worktree 의 .agent-work 에 없음"
[ "$(cat "$SRC/src/a.txt")" = "a base" ] || fail "J: 원본 working tree 가 바뀜"
rc="$(run_feature --finalize)"
[ "$rc" -ne 0 ] && [ "$(cat "$SRC/src/a.txt")" = "a base" ] && [ -d "$WT" ] || fail "J: 검사 실패 상태에서 finalize 가 거부되지 않음(exit $rc)"
grep -v 'BAD' "$WT/src/a.txt" > "$TMP/a.manual" && cat "$TMP/a.manual" > "$WT/src/a.txt"
rc="$(run_feature)"
[ "$rc" -eq 0 ] && [ "$(seq_all)" = "check|reviewer|full-test|full-lint" ] && [ "$(cat "$MOCK_STATE/check-cwd")" = "$WT" ] || fail "J: 직접 수정 뒤 worktree 에서 검사 → 리뷰 → 테스트가 아님(exit $rc): $(seq_all)"
pass "J: --feature worktree — 검사·산출물 모두 피처 worktree 기준, 원본 불변, 검사 실패 상태의 finalize 거부, 수정 뒤 재개 → DONE"

echo "[SMOKE DONE] tests/smoke-fast-check.sh — 임시 디렉터리: $TMP"
