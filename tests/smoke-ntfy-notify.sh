#!/usr/bin/env bash
# =============================================================
# 스모크: DONE 완료 ntfy 푸시 알림 — 실제 HTTP/LLM 호출 없음 (mock curl + 공용 mock CLI), 임시 저장소
# 파일 경로: tests/smoke-ntfy-notify.sh
# 사용법: bash tests/smoke-ntfy-notify.sh
#
# 사례:
#   A. 정상 DONE → mock curl 정확히 1회: URL=$NTFY_URL/$NTFY_TOPIC, --max-time 설정, body 에
#      project/feature/DONE/completed_at/finalize — uname 이 미지의 OS(SmokeOS)를 돌려줘도 발송된다
#      (OS 분기 없음), live.log 에 topic 미노출, notify-done.sent 마커 생성
#   B. NTFY_TOKEN 설정 → Authorization 은 argv 가 아니라 stdin(curl --config)으로 전달, live.log·run-state 에 토큰 없음
#   C. NTFY_TOPIC 미설정 → curl 0회 + "완료 알림 미설정" 로그 + exit 0 / DONE 유지
#   D. HTTP 500 / curl 자체 실패(exit 7) → exit 0, DONE 유지, [WARN] 로그, 마커 없음, 재시도 없음(1회 호출)
#   E. 이미 DONE 인 재실행 → curl 0회 (조기 종료) / done stage 재진입(stage 힌트 done·status RUNNING) → 마커가 재발송 차단
#   F. DONE 이전 종료(워커 UNDECIDED, exit 2) → curl 0회
#   G. 정적: notify-done.sh 에 uname/OSTYPE/OS 분기 없음, 토픽·토큰 하드코딩 없음
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-ntfy-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

# ===== 사례 G: 정적 — 발송 경로에 OS 분기·하드코딩 없음 =====
NOTIFY_SRC="$SKILL_SRC/scripts/notify-done.sh"
[ -f "$NOTIFY_SRC" ] || fail "G: notify-done.sh 없음"
grep -vE '^[[:space:]]*#' "$NOTIFY_SRC" | grep -nE 'uname|OSTYPE|Darwin|MINGW|Windows' && fail "G: notify-done.sh 에 OS 분기가 있음"
grep -nE 'NTFY_TOPIC="[^$]|NTFY_TOKEN="[^$]' "$NOTIFY_SRC" "$SKILL_SRC/config.sh" | grep -v ':-' && fail "G: 토픽/토큰이 하드코딩됨"
pass "G: 발송 경로에 uname/OS 조건문 없음, 토픽·토큰 하드코딩 없음"

# --- 임시 저장소: 스킬 복사 + CHANGE_ME 채움 ---
mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"true\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"true\"|" "$CFG" && rm -f "$CFG.bak"
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && echo "base 01" > src/u01.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/u01.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
cat > .agent-work/implementation-units.json <<'EOF'
{"version":1,"units":[
 {"id":"01-intake","title":"접수","goal":"unit 01","requirements":["REQ-01"],"scope":{"files":["src/u01.txt"],"new_file_roots":[]},"references":["implementation.md#01"],"targeted_test":"true"}
]}
EOF
RUN=".claude/skills/feature/scripts/feature-run.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" FEATURE_LIVE_TEE=1 \
  MOCK_VALIDATOR_CONTRACT="$CONTRACT" MOCK_REVIEW_CONTRACT="$REVIEW_CONTRACT"
mkdir -p "$MOCK_STATE"

# --- 공용 mock CLI (역할은 스키마로 판별 — tests/smoke-implementation-units.sh 와 같은 방식) ---
cat > "$TMP/bin/mock-cli" <<'EOF'
#!/usr/bin/env bash
cli="$(basename "$0")"
out=""; schema=""; prompt=""
while [ "$#" -gt 0 ]; do case "$1" in
  exec|-p) shift;;
  -o) out="$2"; shift 2;;
  --output-schema) schema="$(cat "$2")"; shift 2;;
  --json-schema) schema="$2"; shift 2;;
  --sandbox|--permission-mode|--session-id|--resume|-m|-c|--model|--effort|--output-format|--tools|--allowedTools|--disallowedTools|--append-system-prompt) shift 2;;
  *) prompt="$1"; shift;;
esac; done
usage='"session_id":"fake","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
emit() { if [ "$cli" = codex ]; then if [ -n "$out" ]; then printf '%s\n' "$1" > "$out"; else printf '%s\n' "$1"; fi; else printf '{"structured_output":%s,%s}\n' "$1" "$usage"; fi; }
case "$schema" in
  *'"blocking_issues"'*) emit "{\"schema_version\":$MOCK_VALIDATOR_CONTRACT,\"verdict\":\"PASS\",\"blocking_issues\":[]}"; exit 0;;
  *'"issues"'*) emit "{\"schema_version\":$MOCK_REVIEW_CONTRACT,\"verdict\":\"APPROVE\",\"issues\":[]}"; exit 0;;
  *'"context_updates"'*)
    echo "worker" >> "$MOCK_LOG"
    if [ -f "$MOCK_STATE/undecided-01" ]; then
      emit '{"status":"UNDECIDED","undecided":[{"kind":"USER_DECISION","location":"src/u01.txt","decision_needed":"policy","options":["a","b"]}],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}'
      exit 0
    fi
    echo "worker 01" >> src/u01.txt
    emit '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[{"name":"u01","result":"PASS"}],"context_updates":{"upsert":[],"remove":[]}}'
    exit 0;;
  *) echo "UNKNOWN-ROLE" >> "$MOCK_LOG"; exit 1;;
esac
EOF
chmod +x "$TMP/bin/mock-cli"
cp "$TMP/bin/mock-cli" "$TMP/bin/claude"; cp "$TMP/bin/mock-cli" "$TMP/bin/codex"

# --- mock curl: 호출 argv/stdin 기록, -w '%{http_code}' 만 흉내. 실제 네트워크 없음 ---
cat > "$TMP/bin/mock-curl" <<'EOF'
#!/usr/bin/env bash
n=0; while [ -f "$MOCK_STATE/curl-$n.args" ]; do n=$((n+1)); done
printf '%s\n' "$@" > "$MOCK_STATE/curl-$n.args"
cat > "$MOCK_STATE/curl-$n.stdin"
[ ! -f "$MOCK_STATE/curl-exit" ] || exit "$(cat "$MOCK_STATE/curl-exit")"
if [ -f "$MOCK_STATE/curl-http" ]; then printf '%s' "$(cat "$MOCK_STATE/curl-http")"; else printf '200'; fi
EOF
chmod +x "$TMP/bin/mock-curl"
# uname 스텁: 미지의 OS 를 돌려줘도 발송 경로는 영향이 없어야 한다 (OS 독립 증명)
printf '#!/usr/bin/env bash\necho SmokeOS\n' > "$TMP/bin/uname"; chmod +x "$TMP/bin/uname"

# --- 합의 PASS 픽스처 ---
fake_pass() { bash .claude/skills/feature/scripts/consensus-loop.sh "$1" > "$TMP/consensus-$1.log" 2>&1 || { cat "$TMP/consensus-$1.log"; fail "픽스처: $1 합의 PASS 생성 실패"; }; }
fake_pass design; fake_pass impl

run_runner() { # [NTFY_*=... ...] → exit code, 로그 $TMP/run.log. mock curl·uname 스텁은 항상 적용
  : > "$MOCK_LOG"
  env PATH="$TMP/bin:$PATH" NTFY_CURL_BIN="$TMP/bin/mock-curl" "$@" bash "$RUN" > "$TMP/run.log" 2>&1
  echo $?
}
status() { jq -r '.status' .agent-work/run-state.json; }
curl_calls() { ls "$MOCK_STATE"/curl-*.args 2>/dev/null | wc -l | tr -d ' '; }
reset_tree() { # 소스·산출물을 처음 상태로 (테스트 환경 정리)
  git checkout -q -- src
  rm -f "$MOCK_STATE"/curl-* "$MOCK_STATE"/undecided-01
  rm -rf .agent-work/units .agent-work/implementation-context.json .agent-work/implementation-units.lock.json \
    .agent-work/feature-scope.lock.json .agent-work/worker-baseline.tree .agent-work/worker-result.json \
    .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/reviews/impl-attempt-* \
    .agent-work/.session-* .agent-work/doc-gap-resume.json .agent-work/notify-done.sent .agent-work/live.log
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
}

# ===== 사례 A: 정상 DONE → 발송 1회, 내용·URL·타임아웃, OS 분기 없음, topic 미노출, 마커 =====
reset_tree
rc="$(run_runner NTFY_URL=https://smoke.ntfy.test NTFY_TOPIC=smoke-topic-9f2)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "A: exit 0/DONE 기대, 실제 $rc/$(status)"; }
[ "$(curl_calls)" = 1 ] || fail "A: curl 호출 1회 기대, 실제 $(curl_calls)회"
grep -qx 'https://smoke.ntfy.test/smoke-topic-9f2' "$MOCK_STATE/curl-0.args" || fail "A: 발송 URL 이 NTFY_URL/NTFY_TOPIC 이 아님: $(cat "$MOCK_STATE/curl-0.args")"
grep -qx -- '--max-time' "$MOCK_STATE/curl-0.args" || fail "A: HTTP 타임아웃(--max-time) 미설정"
body="$(cat "$MOCK_STATE/curl-0.args")"
printf '%s' "$body" | grep -q 'project: repo' || fail "A: body 에 프로젝트명 없음"
printf '%s' "$body" | grep -q 'feature: (지정 없음)' || fail "A: body 에 feature id 없음"
printf '%s' "$body" | grep -q 'status: DONE' || fail "A: body 에 완료 상태 없음"
printf '%s' "$body" | grep -q 'completed_at: ' || fail "A: body 에 완료 시각 없음"
printf '%s' "$body" | grep -q 'finalize: ' || fail "A: body 에 finalize 대기 여부 없음"
grep -q 'smoke-topic-9f2' .agent-work/live.log && fail "A: live.log 에 topic 이 노출됨"
grep -q '완료 알림 발송됨' .agent-work/live.log || fail "A: 발송 로그 없음"
[ -f .agent-work/notify-done.sent ] || fail "A: notify-done.sent 마커 없음"
[ -s "$MOCK_STATE/curl-0.stdin" ] && fail "A: 토큰 없는 호출에 stdin config 가 전달됨"
pass "A: DONE → 발송 1회 (URL·타임아웃·본문 project/feature/DONE/시각/finalize), uname=SmokeOS 에서도 발송, topic 미노출, 마커 생성"

# ===== 사례 B: 토큰은 argv 가 아니라 stdin(curl --config), 로그에 미노출 =====
reset_tree
rc="$(run_runner NTFY_URL=https://smoke.ntfy.test NTFY_TOPIC=smoke-topic-9f2 NTFY_TOKEN=tk_smokesecret42)"
[ "$rc" -eq 0 ] && [ "$(curl_calls)" = 1 ] || { tail -20 "$TMP/run.log"; fail "B: exit 0/발송 1회 기대 ($rc/$(curl_calls))"; }
grep -q 'tk_smokesecret42' "$MOCK_STATE/curl-0.args" && fail "B: 토큰이 curl argv 에 노출됨"
grep -qx -- '--config' "$MOCK_STATE/curl-0.args" || fail "B: curl --config(stdin) 경로를 쓰지 않음"
grep -q 'Authorization: Bearer tk_smokesecret42' "$MOCK_STATE/curl-0.stdin" || fail "B: stdin config 에 Authorization 없음"
grep -rq 'tk_smokesecret42' .agent-work/live.log .agent-work/run-state.json && fail "B: 토큰이 로그/상태 파일에 노출됨"
pass "B: 토큰은 stdin config 로만 전달, argv·live.log·run-state 미노출"

# ===== 사례 C: 미설정 → curl 0회, 명확한 로그, DONE 유지 =====
reset_tree
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -20 "$TMP/run.log"; fail "C: exit 0/DONE 기대 ($rc/$(status))"; }
[ "$(curl_calls)" = 0 ] || fail "C: 미설정인데 curl 이 호출됨"
grep -q '완료 알림 미설정' .agent-work/live.log || fail "C: 미설정 로그 없음"
[ ! -f .agent-work/notify-done.sent ] || fail "C: 미발송인데 마커가 생김"
pass "C: NTFY_TOPIC 미설정 → 발송 0회 + 명확한 로그, DONE 유지"

# ===== 사례 D: HTTP 실패·curl 실패 → DONE 유지, WARN, 마커 없음, 재시도 없음 =====
reset_tree; echo 500 > "$MOCK_STATE/curl-http"
rc="$(run_runner NTFY_TOPIC=smoke-topic-9f2)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -20 "$TMP/run.log"; fail "D: HTTP 500 에도 exit 0/DONE 이어야 함 ($rc/$(status))"; }
[ "$(curl_calls)" = 1 ] || fail "D: 실패 시 재시도 없이 1회여야 함 ($(curl_calls)회)"
grep -q '\[WARN\] 완료 알림 발송 실패' .agent-work/live.log || fail "D: HTTP 실패 WARN 로그 없음"
[ ! -f .agent-work/notify-done.sent ] || fail "D: 실패했는데 마커가 생김"
rm -f "$MOCK_STATE/curl-http"
reset_tree; echo 7 > "$MOCK_STATE/curl-exit"
rc="$(run_runner NTFY_TOPIC=smoke-topic-9f2)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] && grep -q '\[WARN\] 완료 알림 발송 실패' .agent-work/live.log \
  || { tail -20 "$TMP/run.log"; fail "D: curl exit 7 에도 exit 0/DONE + WARN 이어야 함 ($rc/$(status))"; }
[ ! -f .agent-work/notify-done.sent ] || fail "D: curl 실패인데 마커가 생김"
rm -f "$MOCK_STATE/curl-exit"
pass "D: HTTP 500·curl 실패 → DONE(exit 0) 유지 + WARN, 마커 없음, 재시도 없음"

# ===== 사례 E: 재실행 중복 발송 방지 =====
reset_tree
rc="$(run_runner NTFY_TOPIC=smoke-topic-9f2)"; [ "$rc" -eq 0 ] && [ "$(curl_calls)" = 1 ] || fail "E: 전제(정상 DONE+발송) 실패"
# E-1: 이미 DONE 상태 재실행 → 조기 종료, curl 추가 호출 없음
rc="$(run_runner NTFY_TOPIC=smoke-topic-9f2)"
[ "$rc" -eq 0 ] || fail "E-1: 재실행 exit 0 기대, 실제 $rc"
grep -q '이미 DONE 상태' "$TMP/run.log" || fail "E-1: 이미 DONE 조기 종료 로그 없음"
[ "$(curl_calls)" = 1 ] || fail "E-1: 재실행에서 중복 발송됨 ($(curl_calls)회)"
# E-2: done stage 재진입(DONE 기록 직전 중단 가정) → 마커가 재발송 차단
jq '.status="RUNNING"' .agent-work/run-state.json > "$TMP/s.tmp" && mv "$TMP/s.tmp" .agent-work/run-state.json
rc="$(run_runner NTFY_TOPIC=smoke-topic-9f2)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -20 "$TMP/run.log"; fail "E-2: done 재진입 exit 0/DONE 기대 ($rc/$(status))"; }
[ "$(curl_calls)" = 1 ] || fail "E-2: done stage 재진입에서 중복 발송됨 ($(curl_calls)회)"
grep -q '이미 발송됨' .agent-work/live.log || fail "E-2: 마커 생략 로그 없음"
pass "E: 이미 DONE 재실행·done stage 재진입 모두 재발송 없음 (마커·조기 종료)"

# ===== 사례 F: DONE 이전 종료 → 발송 없음 =====
reset_tree; touch "$MOCK_STATE/undecided-01"
rc="$(run_runner NTFY_TOPIC=smoke-topic-9f2)"
[ "$rc" -eq 2 ] || { tail -20 "$TMP/run.log"; fail "F: 전제(UNDECIDED exit 2) 실패, 실제 $rc"; }
[ "$(curl_calls)" = 0 ] || fail "F: DONE 전 중단인데 발송됨"
[ ! -f .agent-work/notify-done.sent ] || fail "F: DONE 전인데 마커가 생김"
rm -f "$MOCK_STATE/undecided-01"
pass "F: DONE 이전 종료(exit 2) → 발송 0회"

trap 'rm -rf "$TMP"' EXIT
echo "[SMOKE OK] ntfy done notification"
