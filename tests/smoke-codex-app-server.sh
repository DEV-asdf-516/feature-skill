#!/usr/bin/env bash
# =============================================================
# 스모크: Codex App Server backend — 하네스가 직접 띄운 `codex app-server`(stdio JSON-RPC)로 Codex 역할을 실행한다
# 파일 경로: tests/smoke-codex-app-server.sh   (실제 LLM 호출 없음 — 독립 프로세스 가짜 서버 tests/fake-codex-app-server.mjs, 임시 저장소)
# 사용법: bash tests/smoke-codex-app-server.sh
#
# 불변식:
#   - 기본 backend(app_server)에서 codex exec / exec resume 호출은 0회다. 실패해도 exec 로 대체하지 않는다.
#   - thread id 는 이 호출의 thread/start 응답에서만 얻고, 수용된 key 는 그 id 로만 thread/resume 한다(자동 검색 없음).
#   - turn/start 전에 전송 의도를 기록한다. 전송 뒤 불명은 재실행이 모델 0회로 멈추고, 조회(reconcile)는 새 turn 을 만들지 않는다.
#   - 결과는 이 호출의 thread/turn 에 결속된 완료 agentMessage 뿐이다(델타·다른 turn·다른 thread·과거 파일 아님).
#   - 사용량은 thread 누적값의 차이로만 내고, 근거가 없으면 unknown(null)이다.
# 사례:
#   H 핸드셰이크 / N 신규·재개 / S 스키마·결과 / P 역할 정책(읽기 전용 사후 대조·스냅샷 실패·하위 Agent 금지의 유효 적용 확인 포함) / C 재개 안전성(고유 key 역할·불명 호출의 세션 확정 거부 포함)
#   G 편집 역할의 필수 훅 게이트(hooks/list 로 등록·활성·신뢰 확인 — 워커·수정자·디자이너, 실패는 FAILED_BEFORE_SEND, linked worktree, 단독 판정 명령, 리뷰 루프·합의 루프)
#   T 완료 분기 / B 세션·backend 변경 / I 격리·설치 / U 사용량 / L 리뷰 루프·합의 루프 통합(불명 편집 결과는 다음 리뷰어·검증자로 가지 않는다) / X 단독 명령(상대·절대·심볼릭 링크 경로, worktree 루트)
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-appserver-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks" "$TMP/side" "$TMP/state"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }
command -v node >/dev/null 2>&1 || fail "node 가 없다 — Codex App Server backend 스모크는 Node.js 18+ 가 필요하다"
unset CODEX_APP_GUARD_REVIEWED_SHA256   # 사용자 환경에 등록된 가드 지문이 사례(배포본 지문 하나만 통과)를 흐리지 않게 한다

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
# 새 설치의 기본값을 검증한다 — CODEX_BACKEND 줄은 건드리지 않는다(소스 config.sh 의 기본값이 app_server 여야 한다).
grep -q '^CODEX_BACKEND="app_server"' "$CFG" || fail "소스 config.sh 의 CODEX_BACKEND 기본값이 app_server 가 아니다"
sed -i.bak "s|^CLAUDE_BACKEND=.*|CLAUDE_BACKEND=\"legacy_cli\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"true\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"true\"|" "$CFG" && rm -f "$CFG.bak"
# 역할 CLI 고정: 이 스모크는 Codex 어댑터 규약을 검증한다 — production config 의 모델→CLI 매핑이 바뀌어도 사례 의미가 유지된다.
sed -i.bak 's/^REVIEWER_CLI=.*/REVIEWER_CLI="codex"/; s/^VALIDATOR_CLI=.*/VALIDATOR_CLI="codex"/; s/^FIXER_CLI=.*/FIXER_CLI="claude"/; s/^DESIGNER_CLI=.*/DESIGNER_CLI="claude"/; s/^WORKER_CLI=.*/WORKER_CLI="codex"/; s/^WORKER_MODEL=.*/WORKER_MODEL="gpt-6-luna"/; s/^REVIEWER_MODEL=.*/REVIEWER_MODEL="gpt-5.6-sol"/' "$CFG" && rm -f "$CFG.bak"
cd "$TMP/repo" || exit 1
ROOT="$(pwd)"   # config.sh 의 PROJECT_ROOT 와 같은 표기(TMPDIR 끝의 / 로 생기는 // 없음)
git init -q
printf '.agent-work/\n.claude/\n.codex/\n' > .gitignore
# 편집 역할의 필수 훅 게이트: 훅이 부를 스크립트가 작업 루트에 있어야 한다(등록·활성·신뢰 상태는 가짜 서버의 hooks/list 가 돌려준다).
mkdir -p .codex/hooks && cp "$PROJECT_SRC/.codex/hooks/worker_guard.sh" .codex/hooks/worker_guard.sh   # 실제 가드를 쓴다 — 게이트가 선언이 아니라 본문의 지문을 배포본과 대조한다
printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash .codex/hooks/worker_guard.sh"}]}]}}\n' > .codex/hooks.json
mkdir -p src && echo "base 01" > src/u01.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/u01.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
REVIEW_LOOP=".claude/skills/feature/scripts/impl-review-loop.sh"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
SCHEMA=".claude/skills/feature/schemas/impl-review.schema.json"
WORKER_SCHEMA_FILE=".claude/skills/feature/schemas/worker-result.schema.json"
export FAKE_LOG="$TMP/calls.log" FAKE_STATE="$TMP/state" MOCK_LOG="$TMP/calls.log" FEATURE_LIVE_TEE=1
: > "$FAKE_LOG"

# --- 가짜 codex: 독립 프로세스 가짜 App Server(프로토콜을 실제로 주고받는다). exec 가 불리면 "EXEC ..." 를 남기고 실패한다 ---
printf '#!/usr/bin/env bash\nexec node "%s" "$@"\n' "$PROJECT_SRC/tests/fake-codex-app-server.mjs" > "$TMP/bin/codex"
# --- 가짜 claude (수정자 전용) ---
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude editor" >> "$MOCK_LOG"
eval "${FAKE_EDIT_CMD:-true}"
printf '{"type":"result","result":"ok","session_id":"fake","total_cost_usd":0,"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
EOF
chmod +x "$TMP/bin/codex" "$TMP/bin/claude"

turns() { grep -c '^rpc turn/start ' "$FAKE_LOG" || true; }
spawns() { grep -c '^spawn ' "$FAKE_LOG" || true; }
execs() { grep -c '^EXEC ' "$FAKE_LOG" || true; }
reset_case() {
  : > "$FAKE_LOG"; rm -rf "$FAKE_STATE"; mkdir -p "$FAKE_STATE"; printf '{"ok":true}' > "$FAKE_STATE/reply-default.txt"
  rm -rf .agent-work/.session-* .agent-work/usage.jsonl .agent-work/cli-anomalies.jsonl .agent-work/codex-app-server "$TMP/side"; mkdir -p "$TMP/side"
}
ro_call() { # key out [prompt]
  ( set -e; source "$CFG"; run_readonly_json_role REVIEWER "$1" "smoke-$1" "$SCHEMA" "$2" "${3:-prompt}" "" )
}
edit_call() { # ROLE key raw [schema out] → run_edit_role 의 반환값
  ( source "$CFG"; run_edit_role "$1" "$2" "smoke-$2" "$3" "prompt" "" "${4:-}" "${5:-}" )
}
accept() { ( set -e; source "$CFG"; role_session_accept "$1" "$2" "smoke-accept" ); }
rec() { printf '.agent-work/.session-%s.codex-turn.json' "$1"; }
state_of() { jq -r '.state' "$(rec "$1")"; }
code_of() { jq -r '.outcome.code // ""' "$(rec "$1")"; }
cli() { bash .claude/skills/feature/scripts/codex-app-server.sh "$@"; }
expect_fail() { # 사례이름 로그파일 기대문자열... (직전 명령이 실패했어야 한다 — 호출부가 && fail 로 확인)
  local name="$1" logf="$2"; shift 2
  local s; for s in "$@"; do grep -q -- "$s" "$logf" || { cat "$logf"; fail "$name: 로그에 '$s' 없음"; }; done
}

# ===== H1: 핸드셰이크 — initialize → initialized → thread/start → turn/start, 결과 수신 =====
reset_case
ro_call h1 "$TMP/side/h1.json" > "$TMP/h1.log" 2>&1 || { cat "$TMP/h1.log"; fail "H1: 정상 호출 실패"; }
[ "$(jq -c . "$TMP/side/h1.json")" = '{"ok":true}' ] || fail "H1: 결과 JSON 불일치: $(cat "$TMP/side/h1.json")"
[ "$(grep '^rpc ' "$FAKE_LOG" | awk '{print $2}' | paste -sd' ' -)" = "initialize initialized thread/start turn/start" ] \
  || fail "H1: 프로토콜 순서 불일치: $(grep '^rpc ' "$FAKE_LOG" | awk '{print $2}' | paste -sd' ' -)"
grep -q '^rpc initialize client=feature-skill optOut=[1-9]' "$FAKE_LOG" || fail "H1: 델타 알림 opt-out 이 전달되지 않음: $(grep '^rpc initialize' "$FAKE_LOG")"
[ "$(state_of h1)" = CONSUMED ] || fail "H1: 기록 상태가 CONSUMED 가 아님: $(state_of h1)"
[ "$(jq -r '[.history[].state] | join(">")' "$(rec h1)")" = "PREPARED>THREAD_READY>SEND_UNCONFIRMED>RUNNING>RESULT_READY>CONSUMED" ] \
  || fail "H1: 상태 전이 기록 불일치: $(jq -c '.history' "$(rec h1)")"
jq -e '.thread_id=="thr-1" and .turn_id=="turn-1" and .turn_status=="completed" and .final_message.item_id=="m-1"' "$(rec h1)" >/dev/null || fail "H1: thread/turn 결속 기록 없음"
[ -s "$TMP/side/h1.json.appserver.jsonl" ] && [ -f "$TMP/side/h1.json.stderr.log" ] && [ -s "$TMP/side/h1.json.appserver.sent.jsonl" ] || fail "H1: 원본 로그(appserver.jsonl / sent / stderr) 없음"
[ ! -f "$TMP/side/h1.json.events.jsonl" ] || fail "H1: codex exec 형식 이름(events.jsonl)으로 로그가 남음"
grep -q '"text_sha256"' "$TMP/side/h1.json.appserver.sent.jsonl" && ! grep -q '"text":"prompt"' "$TMP/side/h1.json.appserver.sent.jsonl" || fail "H1: 전송 로그에 프롬프트 원문이 남음"
[ "$(execs)" -eq 0 ] || fail "H1: codex exec 가 호출됨"
pass "H1: initialize → initialized → thread/start → turn/start, 결과 수신·상태 전이·원본 로그 분리"

# ===== H2~H5: 핸드셰이크 실패는 turn/start 전 실패(모델 0회)이고 서로 다른 오류 코드다 =====
for sc in "init_error:CODEX_APP_SERVER_INIT_FAILED" "exit_before_init:CODEX_APP_SERVER_EXITED" "garbage_before_init:CODEX_APP_SERVER_EVENT_PARSE"; do
  reset_case
  FAKE_SCENARIO="${sc%%:*}" ro_call h2 "$TMP/side/h2.json" > "$TMP/h2.log" 2>&1 && fail "H2(${sc%%:*}): 실패해야 하는데 성공"
  [ "$(state_of h2)" = FAILED_BEFORE_SEND ] && [ "$(code_of h2)" = "${sc#*:}" ] || { cat "$TMP/h2.log"; fail "H2(${sc%%:*}): 상태/코드 불일치: $(state_of h2) $(code_of h2)"; }
  [ "$(turns)" -eq 0 ] && [ ! -f "$TMP/side/h2.json" ] || fail "H2(${sc%%:*}): turn 이 전송됐거나 결과가 생김"
  [ ! -f .agent-work/usage.jsonl ] || fail "H2(${sc%%:*}): 모델 호출이 없는데 usage 행이 생김"
  # turn/start 미전송이 기록으로 확정됐으므로 재실행은 새 호출로 이어 간다
  ro_call h2 "$TMP/side/h2.json" > "$TMP/h2b.log" 2>&1 || { cat "$TMP/h2b.log"; fail "H2(${sc%%:*}): 미전송 실패 뒤 재실행이 막힘"; }
done
reset_case
CODEX_APP_SERVER_RPC_TIMEOUT_SEC=1 FAKE_SCENARIO=init_hang ro_call h3 "$TMP/side/h3.json" > "$TMP/h3.log" 2>&1 && fail "H3: 응답 없는 initialize 가 성공"
[ "$(code_of h3)" = CODEX_APP_SERVER_RPC_TIMEOUT ] && [ "$(state_of h3)" = FAILED_BEFORE_SEND ] || fail "H3: RPC timeout 코드 불일치: $(state_of h3) $(code_of h3)"
reset_case
FAKE_SCENARIO=reorder ro_call h4 "$TMP/side/h4.json" > "$TMP/h4.log" 2>&1 || { cat "$TMP/h4.log"; fail "H4: 응답보다 알림이 먼저 온 호출이 실패"; }
[ "$(jq -c . "$TMP/side/h4.json")" = '{"ok":true}' ] && [ "$(jq -r .turn_id "$(rec h4)")" = turn-1 ] || fail "H4: 순서가 바뀐 응답에서 turn 결속 실패"
[ "$(execs)" -eq 0 ] || fail "H: codex exec 가 호출됨"
pass "H2~H5: initialize 오류·조기 종료·깨진 출력·RPC timeout 은 각자 다른 코드의 '전송 전 실패'(모델 0회), 응답/알림 순서 뒤바뀜은 정상 수신"

# ===== N1: 같은 key 두 번, accept 없음 → 둘 다 thread/start (스테이징만으로는 resume 하지 않는다) =====
reset_case
ro_call n1 "$TMP/side/n1a.json" >/dev/null 2>&1 || fail "N1: 1차 호출 실패"
ro_call n1 "$TMP/side/n1b.json" >/dev/null 2>&1 || fail "N1: 2차 호출 실패"
[ "$(grep -c '^rpc thread/start ' "$FAKE_LOG")" -eq 2 ] && [ "$(grep -c '^rpc thread/resume ' "$FAKE_LOG")" -eq 0 ] || fail "N1: accept 없이 resume 이 일어남: $(grep '^rpc thread/' "$FAKE_LOG")"
[ -f .agent-work/.session-n1.codex.json.new ] && [ ! -f .agent-work/.session-n1.codex.json ] || fail "N1: 원장 스테이징/확정 상태 불일치"
pass "N1: 스테이징만으로는 resume 하지 않음"

# ===== N2: accept 후 같은 key → 원장의 thread id 로만 thread/resume, 다른 key 는 새 thread =====
reset_case
ro_call n2 "$TMP/side/n2a.json" >/dev/null 2>&1 && accept REVIEWER n2 || fail "N2: 준비 실패"
jq -e --argjson cv "$REVIEW_CONTRACT" --arg root "$ROOT" '.version==2 and .backend=="app_server" and .key=="n2" and .role=="REVIEWER" and .cli=="codex" and .thread_id=="thr-1"
  and .sandbox=="read-only" and (.contract_version|tonumber)==$cv and .project_root==$root and (.schema_sha256|length)==64 and .last_accepted_turn_id=="turn-1"' .agent-work/.session-n2.codex.json >/dev/null \
  || fail "N2: 원장 내용 불일치: $(cat .agent-work/.session-n2.codex.json)"
[ "$(state_of n2)" = ACCEPTED ] || fail "N2: accept 뒤 기록 상태가 ACCEPTED 가 아님"
ro_call n2 "$TMP/side/n2b.json" > "$TMP/n2.log" 2>&1 || { cat "$TMP/n2.log"; fail "N2: 재개 호출 실패"; }
grep -q '^rpc thread/resume thread=thr-1 .*sandbox=read-only approval=never excludeTurns=true' "$FAKE_LOG" || fail "N2: 저장된 thread 로 resume 하지 않음: $(grep '^rpc thread/' "$FAKE_LOG")"
[ "$(grep -c '^rpc thread/start ' "$FAKE_LOG")" -eq 1 ] || fail "N2: 재개인데 새 thread 를 만들었다"
grep '^rpc turn/start ' "$FAKE_LOG" | tail -1 | grep -q 'thread=thr-1 turn=turn-2 .*schema=yes approval=never' || fail "N2: 재개 turn 이 같은 thread·스키마·승인 정책이 아님: $(grep '^rpc turn/start' "$FAKE_LOG" | tail -1)"
grep '^rpc turn/start ' "$FAKE_LOG" | grep -vq 'effort=high' && fail "N2: 신규/재개 turn 의 effort 가 설정값(high)이 아님"
! grep -Eq 'thread/list|thread/loaded/list|--last' "$FAKE_LOG" || fail "N2: thread 자동 검색(list/--last)이 쓰였다"
ro_call n2other "$TMP/side/n2c.json" >/dev/null 2>&1 || fail "N2: 다른 key 호출 실패"
[ "$(jq -r .thread_id "$(rec n2other)")" = thr-2 ] || fail "N2: 다른 key 가 새 thread 를 쓰지 않음"
pass "N2: accept 된 key 는 원장 thread id 로만 thread/resume(모델·effort·sandbox·승인·스키마 유지), 다른 key 는 새 thread, 자동 검색 없음"

# ===== S1: 결과가 JSON 객체가 아니면 수용하지 않는다 / 과거 파일을 이번 결과로 쓰지 않는다 =====
reset_case
printf '{"stale":"previous-run"}' > "$TMP/side/s1.json"
printf 'sorry, not json' > "$FAKE_STATE/reply-1.txt"
ro_call s1 "$TMP/side/s1.json" > "$TMP/s1.log" 2>&1 && fail "S1: JSON 이 아닌 최종 메시지가 수용됨"
[ "$(state_of s1)" = REJECTED ] && [ "$(code_of s1)" = CODEX_APP_SERVER_RESULT_NOT_JSON ] || fail "S1: 상태/코드 불일치: $(state_of s1) $(code_of s1)"
[ ! -f .agent-work/.session-s1.codex.json.new ] || fail "S1: 결과 없는 호출이 세션을 스테이징함"
pass "S1: 최종 메시지가 JSON 객체가 아니면 REJECTED — 과거 \$out 을 이번 결과로 돌려주지 않는다(반환 실패)"

# ===== S2: outputSchema 미지원 서버 → 실행 전 오류, 무스키마·exec 대체 없음 =====
reset_case
rm -f .agent-work/.codex-app-server-preflight.json
FAKE_SCHEMA_DROP=outputSchema ro_call s2 "$TMP/side/s2.json" > "$TMP/s2.log" 2>&1 && fail "S2: outputSchema 미지원인데 성공"
expect_fail S2 "$TMP/s2.log" CODEX_APP_SERVER_PROTOCOL_UNSUPPORTED 'TurnStartParams.json#outputSchema'
[ "$(spawns)" -eq 0 ] && [ "$(execs)" -eq 0 ] && [ ! -f "$(rec s2)" ] || fail "S2: 서버를 띄웠거나 exec 로 대체했다"
rm -f .agent-work/.codex-app-server-preflight.json
pass "S2: outputSchema 미지원은 사전 오류(서버 미기동, exec 대체 없음)"

# ===== S3: 워커 결과(스키마 편집 역할) — 유효 JSON 은 \$out 으로, 무효는 불수용 =====
reset_case
printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}' > "$FAKE_STATE/reply-1.txt"
FAKE_APP_EDIT_CMD='echo "worker edit" >> src/u01.txt' edit_call WORKER w3 "$TMP/side/w3.log" "$WORKER_SCHEMA_FILE" "$TMP/side/w3-result.json" > "$TMP/s3.log" 2>&1 || { cat "$TMP/s3.log"; fail "S3: 워커 호출 실패"; }
[ "$(jq -r .status "$TMP/side/w3-result.json")" = DONE ] && grep -q 'worker edit' src/u01.txt || fail "S3: 워커 결과/편집이 반영되지 않음"
printf 'I finished everything!' > "$FAKE_STATE/reply-2.txt"
edit_call WORKER w3b "$TMP/side/w3b.log" "$WORKER_SCHEMA_FILE" "$TMP/side/w3b-result.json" > "$TMP/s3b.log" 2>&1; rc=$?
[ "$rc" -eq 20 ] && [ ! -f "$TMP/side/w3b-result.json" ] && [ "$(code_of w3b)" = CODEX_APP_SERVER_RESULT_NOT_JSON ] || { cat "$TMP/s3b.log"; fail "S3: 무효 워커 결과가 불수용되지 않음(rc=$rc)"; }
git checkout -q -- src/u01.txt
pass "S3: 워커 유효 결과는 \$out, 무효 결과는 rc 20 + 결과 파일 없음"

# ===== P1: 역할 정책 — sandbox·승인·모델·effort 는 프로세스 인자와 요청 양쪽에, 워커의 agents.enabled=false 는 워커 프로세스에만 =====
grep -q '^spawn app-server -c sandbox_mode="workspace-write" -c approval_policy="never" -c model="gpt-6-luna" -c model_reasoning_effort="medium" -c agents.enabled=false -c features.multi_agent_v2=false -c features.multi_agent=false --listen stdio://$' "$FAKE_LOG" \
  || fail "P1: 워커 프로세스 인자 불일치: $(grep '^spawn' "$FAKE_LOG" | head -1)"
grep -q '^rpc thread/start .*model=gpt-6-luna sandbox=workspace-write approval=never ephemeral=false' "$FAKE_LOG" || fail "P1: 워커 thread/start 설정 불일치"
grep '^rpc turn/start ' "$FAKE_LOG" | grep -q 'sandboxPolicy=yes' && fail "P1: turn 단위 sandboxPolicy 로 사용자 설정을 덮어썼다"
reset_case
ro_call p1 "$TMP/side/p1.json" >/dev/null 2>&1 || fail "P1: 리뷰어 호출 실패"
sed -i.bak 's/^FIXER_CLI=.*/FIXER_CLI="codex"/; s/^FIXER_MODEL=.*/FIXER_MODEL="gpt-6-sol"/' "$CFG" && rm -f "$CFG.bak"
edit_call FIXER p1fix "$TMP/side/p1fix.log" > "$TMP/p1.log" 2>&1 || { cat "$TMP/p1.log"; fail "P1: 수정자(codex) 호출 실패"; }
sed -i.bak 's/^FIXER_CLI=.*/FIXER_CLI="claude"/; s/^FIXER_MODEL=.*/FIXER_MODEL="claude-sonnet-5-5"/' "$CFG" && rm -f "$CFG.bak"
sed -i.bak 's/^DESIGNER_CLI=.*/DESIGNER_CLI="codex"/; s/^DESIGN_REVISION_MODEL=.*/DESIGN_REVISION_MODEL="gpt-6-astra"/' "$CFG" && rm -f "$CFG.bak"
edit_call DESIGNER designer-impl "$TMP/side/p1des.log" > "$TMP/p1d.log" 2>&1; drc=$?
sed -i.bak 's/^DESIGNER_CLI=.*/DESIGNER_CLI="claude"/; s/^DESIGN_REVISION_MODEL=.*/DESIGN_REVISION_MODEL="claude-fable-5-2"/' "$CFG" && rm -f "$CFG.bak"
[ "$drc" -eq 0 ] && grep -q '^spawn app-server -c sandbox_mode="workspace-write" .*model="gpt-6-astra"' "$FAKE_LOG" || { cat "$TMP/p1d.log"; fail "P1: 디자이너(codex) 편집 호출 실패(rc=$drc)"; }
grep '^spawn ' "$FAKE_LOG" | grep -Eq 'agents.enabled|features.multi_agent' && fail "P1: 워커가 아닌 역할의 프로세스에 하위 Agent 금지 설정이 새어 나감: $(grep '^spawn' "$FAKE_LOG")"
grep -Eq '^rpc (config/read|experimentalFeature/list)' "$FAKE_LOG" && fail "P1: 워커가 아닌 역할이 하위 Agent 금지 확인을 탔다"
grep -q '^spawn app-server -c sandbox_mode="read-only" ' "$FAKE_LOG" && grep -q '^spawn app-server -c sandbox_mode="workspace-write" .*model="gpt-6-sol"' "$FAKE_LOG" || fail "P1: 읽기 전용/편집 역할의 sandbox 인자 불일치"
[ -f "$TMP/side/p1fix.log.last-message.txt" ] || fail "P1: 스키마 없는 편집 역할의 최종 메시지 파일 없음"
pass "P1: 읽기 전용=read-only · 편집=workspace-write · 승인 never, agents.enabled=false 는 워커 프로세스에만(누출 없음)"

# ===== P2: 설치된 codex 가 agents.enabled 키를 받지 않으면 워커를 띄우지 않는다 / 서버가 다른 설정을 돌려주면 turn 전에 멈춘다 =====
reset_case
rm -f .agent-work/.codex-app-server-preflight.json
FAKE_AGENTS_KEY_UNSUPPORTED=1 edit_call WORKER p2 "$TMP/side/p2.log" "$WORKER_SCHEMA_FILE" "$TMP/side/p2-result.json" > "$TMP/p2.log" 2>&1 && fail "P2: agents 정책 미지원인데 성공"
expect_fail P2 "$TMP/p2.log" CODEX_APP_SERVER_AGENTS_POLICY_UNSUPPORTED
[ "$(spawns)" -eq 0 ] || fail "P2: 정책 미지원인데 서버를 띄웠다"
rm -f .agent-work/.codex-app-server-preflight.json
for sc in settings_model settings_sandbox settings_approval ephemeral_true resume_wrong_thread extra_thread_started; do
  reset_case
  if [ "$sc" = resume_wrong_thread ]; then ro_call p2s "$TMP/side/p2s.json" >/dev/null 2>&1 && accept REVIEWER p2s || fail "P2($sc): 준비 실패"; fi
  before="$(turns)"
  FAKE_SCENARIO="$sc" ro_call p2s "$TMP/side/p2s-b.json" > "$TMP/p2s.log" 2>&1 && fail "P2($sc): 설정·thread 불일치인데 성공"
  [ "$(state_of p2s)" = FAILED_BEFORE_SEND ] && [ "$(turns)" -eq "$before" ] || { cat "$TMP/p2s.log"; fail "P2($sc): turn 전송 전에 멈추지 않음: $(state_of p2s) $(code_of p2s)"; }
done
[ "$(code_of p2s)" = CODEX_APP_SERVER_THREAD_NOT_UNIQUE ] || fail "P2: thread 유일성 위반 코드 불일치: $(code_of p2s)"
pass "P2: agents 정책 미지원 → 서버 미기동 / 모델·sandbox·승인·ephemeral·thread id 불일치·thread 중복 → turn 전송 전 중단"

# ===== P3: 읽기 전용 역할이 작업 트리·index 를 바꾸면 판정을 수용하지 않는다(자동 원복 없음) =====
reset_case
FAKE_APP_EDIT_CMD='echo "reviewer touched source" >> src/u01.txt' ro_call p3 "$TMP/side/p3.json" > "$TMP/p3.log" 2>&1 && fail "P3: 읽기 전용 역할이 소스를 바꿨는데 결과가 수용됨"
expect_fail P3 "$TMP/p3.log" CODEX_APP_SERVER_READONLY_VIOLATION
[ ! -f "$TMP/side/p3.json" ] && [ "$(state_of p3)" = REJECTED ] && [ ! -f .agent-work/.session-p3.codex.json.new ] || fail "P3: 위반 결과가 넘어갔거나 세션이 스테이징됨"
grep -q 'reviewer touched source' src/u01.txt || fail "P3: 변경이 자동 원복됨"
git checkout -q -- src/u01.txt
reset_case
FAKE_APP_EDIT_CMD='echo staged > src/new.txt && git add src/new.txt' ro_call p3 "$TMP/side/p3.json" > "$TMP/p3.log" 2>&1 && fail "P3: 읽기 전용 역할이 index 를 바꿨는데 결과가 수용됨"
expect_fail P3 "$TMP/p3.log" CODEX_APP_SERVER_READONLY_VIOLATION
git reset -q -- src/new.txt; rm -f src/new.txt
pass "P3: 읽기 전용 역할의 작업 트리·index 변경 → CODEX_APP_SERVER_READONLY_VIOLATION(결과 불수용, 변경 보존)"

# ===== C1: turn/start 응답 전 서버 종료 → UNKNOWN, 재실행은 모델 0회, 조회로 복구 뒤 새 turn 없이 결과 수용 =====
reset_case
FAKE_SCENARIO=crash_before_turn_response ro_call c1 "$TMP/side/c1.json" > "$TMP/c1.log" 2>&1 && fail "C1: 응답 없이 죽은 호출이 성공"
[ "$(state_of c1)" = UNKNOWN ] && [ "$(code_of c1)" = CODEX_APP_SERVER_EXITED ] && [ "$(jq -r '.turn_id // "none"' "$(rec c1)")" = none ] || fail "C1: 상태 불일치: $(state_of c1) $(code_of c1)"
cp "$(rec c1)" "$TMP/c1-record.json"
for i in 1 2; do
  ro_call c1 "$TMP/side/c1.json" > "$TMP/c1b.log" 2>&1 && fail "C1: 불명 상태에서 재실행이 진행됨"
  expect_fail C1 "$TMP/c1b.log" CODEX_TURN_UNCERTAIN 'reconcile c1'
done
[ "$(turns)" -eq 1 ] && [ "$(spawns)" -eq 1 ] || fail "C1: 불명 상태 재실행이 서버·turn 을 다시 만들었다(turn $(turns), spawn $(spawns))"
cmp -s "$(rec c1)" "$TMP/c1-record.json" || fail "C1: 재실행이 불명 기록을 바꿨다"
[ ! -f .agent-work/.session-c1.codex.json ] && [ ! -f .agent-work/.session-c1.codex.json.new ] || fail "C1: 불명 호출이 세션을 만들었다"
verdict="$(cli reconcile c1 2>"$TMP/c1r.err")" || { cat "$TMP/c1r.err"; fail "C1: reconcile 실행 실패"; }
[ "$(printf '%s' "$verdict" | jq -r '.verdict')" = RECOVERED ] && [ "$(printf '%s' "$verdict" | jq -r '.evidence.client_id_match')" = true ] || fail "C1: reconcile 판정 불일치: $verdict"
[ "$(turns)" -eq 1 ] || fail "C1: reconcile 이 새 turn 을 보냈다"
grep -q '^rpc thread/turns/list thread=thr-1' "$FAKE_LOG" && grep -q '^rpc thread/items/list thread=thr-1 turn=turn-1' "$FAKE_LOG" || fail "C1: 조회가 paginated history 를 쓰지 않음"
[ "$(state_of c1)" = RESULT_READY ] && jq -e '.recovered==true and .turn_id=="turn-1"' "$(rec c1)" >/dev/null || fail "C1: 복구 뒤 기록 불일치"
ro_call c1 "$TMP/side/c1.json" > "$TMP/c1c.log" 2>&1 || { cat "$TMP/c1c.log"; fail "C1: 복구된 결과의 수용 실패"; }
[ "$(turns)" -eq 1 ] && [ "$(jq -c . "$TMP/side/c1.json")" = '{"ok":true}' ] && [ "$(state_of c1)" = CONSUMED ] || fail "C1: 복구 결과를 새 turn 없이 쓰지 않음"
[ "$(grep -c . .agent-work/usage.jsonl)" -eq 1 ] && jq -e '.usage_observation_status!="complete" and .input_uncached==null and .estimated_cost_usd==null' .agent-work/usage.jsonl >/dev/null || fail "C1: 사용량 행이 1개(unknown)가 아님: $(cat .agent-work/usage.jsonl)"
pass "C1: 전송 뒤 응답 소실 → UNKNOWN, 재실행 모델 0회·기록 보존, reconcile(clientId 증거)로 복구 뒤 새 turn 없이 수용, usage 1행(unknown)"

# ===== C2: thread 기록에도 없는 turn → 조회는 '미실행'으로 단정하지 않는다, 사용자가 discard 한 뒤에만 새 turn =====
reset_case
FAKE_SCENARIO=crash_before_turn_response,crash_unrecorded ro_call c2 "$TMP/side/c2.json" >/dev/null 2>&1 && fail "C2: 죽은 호출이 성공"
verdict="$(cli reconcile c2 2>/dev/null)"
[ "$(printf '%s' "$verdict" | jq -r '.verdict')" = NOT_FOUND ] && [ "$(state_of c2)" = UNKNOWN ] || fail "C2: 증거 없음이 NOT_FOUND/기록 유지가 아님: $verdict / $(state_of c2)"
ro_call c2 "$TMP/side/c2.json" > "$TMP/c2.log" 2>&1 && fail "C2: 조회만으로 불명이 풀렸다"
[ "$(turns)" -eq 1 ] || fail "C2: 재실행이 turn 을 보냈다"
cli discard c2 > "$TMP/c2d.log" 2>&1 || { cat "$TMP/c2d.log"; fail "C2: discard 실패"; }
[ ! -f "$(rec c2)" ] && ls .agent-work/codex-app-server/c2/*.json >/dev/null 2>&1 || fail "C2: discard 가 기록을 보관 위치로 옮기지 않음"
ro_call c2 "$TMP/side/c2.json" > "$TMP/c2e.log" 2>&1 || { cat "$TMP/c2e.log"; fail "C2: discard 뒤 재실행 실패"; }
[ "$(turns)" -eq 2 ] || fail "C2: discard 뒤 새 turn 이 1회가 아님"
pass "C2: 증거 없는 불명은 조회로 풀리지 않는다 — 사용자의 discard 뒤에만 새 turn"

# ===== C3: turn id 확정 뒤·완료 이벤트 전 종료, 끊긴 마지막 줄 → UNKNOWN + turn id 로 복구 =====
for sc in crash_after_turn_started crash_before_completed partial_line_exit; do
  reset_case
  FAKE_SCENARIO="$sc" ro_call c3 "$TMP/side/c3.json" > "$TMP/c3.log" 2>&1 && fail "C3($sc): 완료 전 종료가 성공으로 처리됨"
  [ "$(state_of c3)" = UNKNOWN ] && [ "$(jq -r .turn_id "$(rec c3)")" = turn-1 ] || { cat "$TMP/c3.log"; fail "C3($sc): UNKNOWN + turn id 기록이 아님: $(state_of c3) $(code_of c3)"; }
  ro_call c3 "$TMP/side/c3.json" >/dev/null 2>&1 && fail "C3($sc): 불명 재실행이 진행됨"
  [ "$(turns)" -eq 1 ] || fail "C3($sc): 중복 turn"
  [ "$(cli reconcile c3 2>/dev/null | jq -r .verdict)" = RECOVERED ] || fail "C3($sc): turn id 로 복구하지 못함"
done
pass "C3: turn 시작 뒤 종료·완료 이벤트 전 종료·끊긴 줄 → UNKNOWN, 중복 turn 0회, turn id 증거로 복구"

# ===== C4: 기록으로 판정 — 전송 전 상태는 이어 가고, 전송 뒤 상태는 멈춘다 / 다른 실행이 준비 중이면 끼어들지 않는다 =====
reset_case
ro_call c4 "$TMP/side/c4a.json" >/dev/null 2>&1 || fail "C4: 준비 실패"
for st in PREPARED THREAD_READY; do
  jq --arg s "$st" '.state=$s | .runner_pid=999999' "$(rec c4)" > t && mv t "$(rec c4)"
  before="$(turns)"
  ro_call c4 "$TMP/side/c4b.json" > "$TMP/c4.log" 2>&1 || { cat "$TMP/c4.log"; fail "C4($st): 전송 전 상태에서 이어 가지 못함"; }
  [ "$(turns)" -eq $((before + 1)) ] || fail "C4($st): 새 호출이 1회가 아님"
done
for st in SEND_UNCONFIRMED RUNNING; do
  jq --arg s "$st" '.state=$s' "$(rec c4)" > t && mv t "$(rec c4)"
  before="$(turns)"
  ro_call c4 "$TMP/side/c4c.json" > "$TMP/c4.log" 2>&1 && fail "C4($st): 전송 뒤 상태에서 재실행이 진행됨"
  expect_fail "C4($st)" "$TMP/c4.log" CODEX_TURN_UNCERTAIN
  [ "$(turns)" -eq "$before" ] || fail "C4($st): turn 이 전송됨"
done
sleep 30 & other_pid=$!
jq --argjson p "$other_pid" '.state="PREPARED" | .runner_pid=$p' "$(rec c4)" > t && mv t "$(rec c4)"
ro_call c4 "$TMP/side/c4d.json" > "$TMP/c4.log" 2>&1 && { kill "$other_pid" 2>/dev/null; fail "C4: 다른 실행이 준비 중인데 끼어들었다"; }
kill "$other_pid" 2>/dev/null; wait "$other_pid" 2>/dev/null
expect_fail C4 "$TMP/c4.log" CODEX_TURN_IN_PROGRESS
pass "C4: PREPARED/THREAD_READY(모델 0회 확정)는 이어 가고 SEND_UNCONFIRMED/RUNNING 은 멈춘다, 살아 있는 다른 실행의 준비 기록 위에는 끼어들지 않는다"

# ===== C5: 결과를 남기고 Shell 이 죽은 경우 — 읽기 전용은 입력 지문이 같을 때만 새 turn 없이 수용, 편집 역할·다른 입력은 멈춘다 =====
reset_case
( source "$CFG"; codex_app_invoke REVIEWER readonly c5 smoke-c5 "$SCHEMA" "$TMP/side/c5.json" "prompt" ) >/dev/null 2>&1 || fail "C5: 준비 실패"
[ "$(state_of c5)" = RESULT_READY ] && [ ! -f "$TMP/side/c5.json" ] || fail "C5: 준비 상태 불일치"
ro_call c5 "$TMP/side/c5.json" "another prompt" > "$TMP/c5.log" 2>&1 && fail "C5: 다른 프롬프트인데 저장된 결과를 썼다"
expect_fail C5 "$TMP/c5.log" CODEX_TURN_RESULT_UNCONSUMED
ro_call c5 "$TMP/side/c5.json" > "$TMP/c5b.log" 2>&1 || { cat "$TMP/c5b.log"; fail "C5: 같은 입력의 결과 재사용 실패"; }
[ "$(turns)" -eq 1 ] && [ "$(grep -c . .agent-work/usage.jsonl)" -eq 1 ] && [ "$(state_of c5)" = CONSUMED ] || fail "C5: 재사용이 새 turn·중복 usage 행을 만들었다"
( source "$CFG"; codex_app_invoke WORKER edit c5w smoke-c5w "$WORKER_SCHEMA_FILE" "$TMP/side/c5w.log" "prompt" ) >/dev/null 2>&1 || fail "C5: 편집 준비 실패"
edit_call WORKER c5w "$TMP/side/c5w.log" "$WORKER_SCHEMA_FILE" "$TMP/side/c5w-result.json" > "$TMP/c5w.log" 2>&1 && fail "C5: 편집 역할의 미소비 결과 위에서 진행됨"
expect_fail C5 "$TMP/c5w.log" CODEX_TURN_RESULT_UNCONSUMED
[ "$(turns)" -eq 2 ] || fail "C5: 편집 역할 재실행이 turn 을 보냈다"
pass "C5: 미소비 완료 결과 — 읽기 전용+같은 입력만 새 turn 없이 수용(usage 1행), 다른 입력·편집 역할은 CODEX_TURN_RESULT_UNCONSUMED"

# ===== C6: 수용되지 않은 재개 응답 위에 같은 thread 로 다시 보내지 않는다(읽기 전용) =====
reset_case
ro_call c6 "$TMP/side/c6a.json" >/dev/null 2>&1 && accept REVIEWER c6 || fail "C6: 준비 실패"
ro_call c6 "$TMP/side/c6b.json" >/dev/null 2>&1 || fail "C6: 재개 호출 실패"
ro_call c6 "$TMP/side/c6c.json" > "$TMP/c6.log" 2>&1 && fail "C6: 수용되지 않은 재개 응답 뒤에 다시 보냈다"
expect_fail C6 "$TMP/c6.log" SESSION_RESUME_UNCERTAIN
[ "$(turns)" -eq 2 ] || fail "C6: turn 이 추가로 전송됨"
accept REVIEWER c6 || fail "C6: accept 실패"
ro_call c6 "$TMP/side/c6c.json" >/dev/null 2>&1 || fail "C6: 수용 뒤 다음 재개 실패"
pass "C6: 미수용 재개 응답 → SESSION_RESUME_UNCERTAIN, 호출자가 수용한 뒤에만 같은 thread 로 다음 turn"

# ===== C7: 호출마다 key 가 바뀌는 역할(합의 루프의 검증자)도 같은 호출 지점의 불명 기록 위에서는 다시 보내지 않는다 =====
reset_case
val_call() { # key out [prompt] — consensus-loop 과 같이 key 는 호출마다 고유, label 은 호출 지점마다 고정
  ( set -e; source "$CFG"; run_readonly_json_role VALIDATOR "$1" "design-validator-round-01" "$SCHEMA" "$2" "${3:-prompt}" "" )
}
FAKE_SCENARIO=crash_before_turn_response val_call validator-design-round-01-aaaa "$TMP/side/c7.json" >/dev/null 2>&1 && fail "C7: 죽은 호출이 성공"
[ "$(state_of validator-design-round-01-aaaa)" = UNKNOWN ] || fail "C7: 준비 상태 불일치"
val_call validator-design-round-01-bbbb "$TMP/side/c7.json" > "$TMP/c7.log" 2>&1 && fail "C7: key 만 바뀐 재실행이 같은 프롬프트를 다시 보냈다"
expect_fail C7 "$TMP/c7.log" CODEX_TURN_UNCERTAIN 'reconcile validator-design-round-01-aaaa'
[ "$(turns)" -eq 1 ] && [ ! -f "$(rec validator-design-round-01-bbbb)" ] || fail "C7: 새 key 로 turn·기록이 만들어짐"
[ "$(cli reconcile validator-design-round-01-aaaa 2>/dev/null | jq -r .verdict)" = RECOVERED ] || fail "C7: 조회 복구 실패"
val_call validator-design-round-01-cccc "$TMP/side/c7.json" "changed docs" > "$TMP/c7b.log" 2>&1 && fail "C7: 입력이 바뀌었는데 복구된 결과를 썼다"
expect_fail C7 "$TMP/c7b.log" CODEX_TURN_RESULT_UNCONSUMED
val_call validator-design-round-01-dddd "$TMP/side/c7.json" > "$TMP/c7c.log" 2>&1 || { cat "$TMP/c7c.log"; fail "C7: 복구된 결과의 수용 실패"; }
[ "$(turns)" -eq 1 ] && [ "$(jq -c . "$TMP/side/c7.json")" = '{"ok":true}' ] && [ "$(state_of validator-design-round-01-aaaa)" = CONSUMED ] || fail "C7: 복구 결과를 새 turn 없이 쓰지 않음"
val_call validator-design-round-01-eeee "$TMP/side/c7b.json" >/dev/null 2>&1 || fail "C7: 정리된 뒤의 다음 검증 호출이 막힘"
[ "$(turns)" -eq 2 ] || fail "C7: 다음 검증 호출이 새 turn 1회가 아님"
pass "C7: 고유 key 역할(검증자)도 같은 호출 지점(역할+label)의 불명 기록 위에서는 모델 0회, 복구 결과는 입력 지문이 같을 때만 새 turn 없이 수용"

# ===== T1: 완료 분기 — failed / interrupted / 델타만 / 메시지+실패 / 최종 단계 아님 / 스트림 손상 / turn timeout =====
for sc in "turn_failed:TURN_FAILED:CODEX_APP_SERVER_TURN_FAILED" "turn_interrupted:TURN_FAILED:CODEX_APP_SERVER_TURN_INTERRUPTED" "delta_only:REJECTED:CODEX_APP_SERVER_RESULT_MISSING" \
          "failed_with_message:TURN_FAILED:CODEX_APP_SERVER_TURN_FAILED" "no_final_phase:REJECTED:CODEX_APP_SERVER_RESULT_MISSING" "rerouted:REJECTED:CODEX_APP_SERVER_MODEL_REROUTED" \
          "garbage_mid_turn:UNKNOWN:CODEX_APP_SERVER_EVENT_PARSE"; do
  reset_case; name="${sc%%:*}"; rest="${sc#*:}"
  FAKE_SCENARIO="$name" ro_call t1 "$TMP/side/t1.json" > "$TMP/t1.log" 2>&1 && fail "T1($name): 성공으로 처리됨"
  [ "$(state_of t1)" = "${rest%%:*}" ] && [ "$(code_of t1)" = "${rest#*:}" ] || { cat "$TMP/t1.log"; fail "T1($name): 상태/코드 불일치: $(state_of t1) $(code_of t1)"; }
  [ ! -f "$TMP/side/t1.json" ] && [ ! -f .agent-work/.session-t1.codex.json.new ] || fail "T1($name): 결과·세션이 생김"
  [ "$(grep -c . .agent-work/usage.jsonl)" -eq 1 ] || fail "T1($name): usage 행이 1개가 아님"
done
reset_case
CODEX_APP_SERVER_TURN_TIMEOUT_SEC=1 FAKE_SCENARIO=hang_turn ro_call t1 "$TMP/side/t1.json" > "$TMP/t1.log" 2>&1 && fail "T1(hang): 끝나지 않는 turn 이 성공"
[ "$(state_of t1)" = UNKNOWN ] && [ "$(code_of t1)" = CODEX_APP_SERVER_TURN_TIMEOUT ] || fail "T1(hang): timeout 상태 불일치: $(state_of t1) $(code_of t1)"
[ "$(execs)" -eq 0 ] || fail "T1: 실패를 codex exec 로 복구했다"
pass "T1: failed·interrupted·델타만·메시지 있는 실패 turn·비최종 메시지·모델 reroute·스트림 손상·timeout 은 어느 것도 완료로 승격되지 않는다(exec 대체 0회)"

# ===== T2: 다른 thread/turn 의 이벤트·늦게 온 완료·중복 item 은 결과에 섞이지 않는다 =====
reset_case
printf '{"mine":true}' > "$FAKE_STATE/reply-1.txt"
FAKE_SCENARIO=foreign_events,late_completed,dup_items ro_call t2 "$TMP/side/t2.json" > "$TMP/t2.log" 2>&1 || { cat "$TMP/t2.log"; fail "T2: 호출 실패"; }
[ "$(jq -c . "$TMP/side/t2.json")" = '{"mine":true}' ] || fail "T2: 다른 thread/turn 의 메시지가 결과가 됨: $(cat "$TMP/side/t2.json")"
jq -e '.final_message.agent_messages==1 and .foreign_events>=3' "$(rec t2)" >/dev/null || fail "T2: 중복 item·외부 이벤트 집계 불일치: $(jq -c '{final_message,foreign_events}' "$(rec t2)")"
jq -e '.input_effective==1000' .agent-work/usage.jsonl >/dev/null || fail "T2: 다른 turn 의 사용량이 섞였다: $(cat .agent-work/usage.jsonl)"
pass "T2: 이 호출의 thread/turn 에 결속된 완료 메시지만 결과다(외부 이벤트·늦은 완료·중복 item 무시)"

# ===== T3: 서버의 승인 요청은 자동 수락하지 않는다 =====
reset_case
FAKE_SCENARIO=approval ro_call t3 "$TMP/side/t3.json" > "$TMP/t3.log" 2>&1 && fail "T3: 승인 요청이 있었는데 성공"
grep -q '^approval-response {"decision":"decline"}' "$FAKE_LOG" || fail "T3: 승인 요청에 decline 으로 응답하지 않음: $(grep approval-response "$FAKE_LOG")"
! grep -q '^approval-response {"decision":"accept' "$FAKE_LOG" || fail "T3: 승인 요청을 수락했다"
[ "$(code_of t3)" = CODEX_APP_SERVER_REQUEST_DENIED ] && jq -e '.server_requests[0].method=="item/commandExecution/requestApproval"' "$(rec t3)" >/dev/null || fail "T3: 승인 요청 기록 불일치: $(state_of t3) $(code_of t3)"
grep -q '^rpc turn/interrupt thread=thr-1 turn=turn-1' "$FAKE_LOG" || fail "T3: 승인 요청 뒤 turn 을 중단하지 않음"
pass "T3: 서버 승인 요청 → decline 응답 + turn 중단 + 호출 불수용(무응답·자동 수락 없음)"

# ===== T4: 정상 완료 뒤 서버 프로세스의 비정상 종료 — turn 결과는 쓰되 숨기지 않는다 =====
reset_case
FAKE_SCENARIO=exit_nonzero_after_complete ro_call t4 "$TMP/side/t4.json" > "$TMP/t4.log" 2>&1 || { cat "$TMP/t4.log"; fail "T4: 완료한 turn 이 프로세스 종료 코드 때문에 실패 처리됨"; }
grep -q 'CLI_EXIT_STATUS_MISMATCH' "$TMP/t4.log" && jq -e '.cli=="codex_app_server" and .raw_exit_code==1 and .recovery=="STRUCTURED_RESULT"' .agent-work/cli-anomalies.jsonl >/dev/null \
  || fail "T4: 종료 코드 불일치가 기록되지 않음"
pass "T4: turn 완료 + 프로세스 exit 1 → 결과는 호출자 검사로, 불일치는 WARN + cli-anomalies.jsonl"

# ===== B1: 다른 backend 의 세션 위에서 자동 이관하지 않는다 =====
reset_case
jq -n --arg root "$TMP/repo" '{version:1, key:"b1", role:"REVIEWER", cli:"codex", model:"gpt-5.6-sol", effort:"high", contract_version:"17", project_root:$root, thread_id:"tid-legacy", created_at:"t", last_accepted_label:"", last_accepted_at:""}' > .agent-work/.session-b1.codex.json
ro_call b1 "$TMP/side/b1.json" > "$TMP/b1.log" 2>&1 && fail "B1: legacy_exec 원장 위에서 App Server 로 진행됨"
expect_fail B1 "$TMP/b1.log" SESSION_BACKEND_MISMATCH legacy_exec
printf '{"key":"b1m","invocation_id":"x","label":"y","recorded_at":"z"}\n' > .agent-work/.session-b1m.resume-pending.json
ro_call b1m "$TMP/side/b1m.json" > "$TMP/b1.log" 2>&1 && fail "B1: legacy resume marker 위에서 진행됨"
expect_fail B1 "$TMP/b1.log" SESSION_BACKEND_MISMATCH
echo "11111111-1111-1111-1111-111111111111" > .agent-work/.session-b1c
ro_call b1c "$TMP/side/b1c.json" > "$TMP/b1.log" 2>&1 && fail "B1: claude 세션 위에서 진행됨"
expect_fail B1 "$TMP/b1.log" SESSION_CLI_MISMATCH
echo '{}' > .agent-work/.session-b1n.native.json
ro_call b1n "$TMP/side/b1n.json" > "$TMP/b1.log" 2>&1 && fail "B1: native Agent 세션 위에서 진행됨"
expect_fail B1 "$TMP/b1.log" SESSION_CLI_MISMATCH
[ "$(spawns)" -eq 0 ] || fail "B1: 불일치인데 서버를 띄웠다"
pass "B1: legacy_exec 원장·marker / claude CLI / native Agent 세션 → App Server 로 자동 이관 없음(서버 미기동)"

# ===== B2: App Server 세션 → legacy_exec 로 바꿔도 잇지 않는다, 원장 설정 변경도 자동 fresh 없음 =====
reset_case
ro_call b2 "$TMP/side/b2a.json" >/dev/null 2>&1 && accept REVIEWER b2 || fail "B2: 준비 실패"
( set -e; source "$CFG"; CODEX_BACKEND=legacy_exec; run_readonly_json_role REVIEWER b2 smoke-b2 "$SCHEMA" "$TMP/side/b2b.json" prompt "" ) > "$TMP/b2.log" 2>&1 && fail "B2: App Server 세션을 codex exec 로 이었다"
expect_fail B2 "$TMP/b2.log" SESSION_BACKEND_MISMATCH
[ "$(execs)" -eq 0 ] || fail "B2: codex exec 가 호출됨"
before="$(turns)"; cp .agent-work/.session-b2.codex.json "$TMP/b2-ledger.json"
for edit in '.model="other-model"' '.effort="low"' '.project_root="/somewhere/else"' '.schema_sha256="0000"' '.sandbox="workspace-write"' '.contract_version="1"'; do
  jq "$edit" "$TMP/b2-ledger.json" > .agent-work/.session-b2.codex.json
  ro_call b2 "$TMP/side/b2c.json" > "$TMP/b2.log" 2>&1 && fail "B2($edit): 원장 불일치인데 진행됨"
  expect_fail "B2($edit)" "$TMP/b2.log" SESSION_LEDGER_MISMATCH
done
[ "$(turns)" -eq "$before" ] && [ "$(grep -c '^rpc thread/start ' "$FAKE_LOG")" -eq 1 ] || fail "B2: 불일치인데 turn·새 thread 가 만들어짐"
pass "B2: App Server 원장 → legacy_exec 금지(exec 0회), 모델·effort·root·schema·sandbox·계약 변경 → SESSION_LEDGER_MISMATCH(자동 fresh·fork 없음)"

# ===== B3: Feature Worker 저널이 codex exec 로 시작된 피처는 App Server 로 옮겨 가지 않는다 =====
reset_case
( set -e
  source "$CFG"
  SKILL_DIR="$TMP/repo/.claude/skills/feature"; WORKER_SCHEMA="$SKILL_DIR/schemas/worker-result.schema.json"
  log() { echo "$*"; }; env_error() { echo "[ENV] $*" >&2; exit 1; }
  stop_need_user() { echo "[STOP] $1 $2" >&2; exit 2; }; stop_need_docs() { exit 3; }
  source "$SKILL_DIR/scripts/worker-invoke.sh"
  fp="$(worker_contract_fingerprint)" || exit 1
  jq -n --arg model "$(role_model WORKER)" --arg effort "$(role_effort WORKER)" --arg fp "$fp" \
    '{version:1, session:"feature-worker", cli:"codex", model:$model, effort:$effort, contract_fingerprint:$fp,
      generation:1, session_bound:false, session_id:null, last_completed_unit_id:null, last_completed_tree:null, created_at:"t"}' > .agent-work/worker-session.json
  ensure_feature_worker_session
) > "$TMP/b3.log" 2>&1; rc=$?
[ "$rc" -eq 2 ] && grep -q 'WORKER_SESSION_MISMATCH' "$TMP/b3.log" && grep -q 'backend codex_cli→codex_app_server' "$TMP/b3.log" || { cat "$TMP/b3.log"; fail "B3: codex exec 로 시작한 워커 저널이 멈추지 않음(rc=$rc)"; }
rm -f .agent-work/worker-session.json
pass "B3: codex exec 로 시작한 Feature Worker 저널 → WORKER_SESSION_MISMATCH(backend codex_cli→codex_app_server)"

# ===== I1: 다른 작업 루트는 세션·호출 기록·출력을 공유하지 않는다 =====
reset_case
ro_call i1 "$TMP/side/i1.json" >/dev/null 2>&1 && accept REVIEWER i1 || fail "I1: 준비 실패"
rm -rf "$TMP/repo2"; cp -R "$TMP/repo" "$TMP/repo2"; rm -rf "$TMP/repo2/.agent-work/.session-"* "$TMP/repo2/.agent-work/codex-app-server"
( cd "$TMP/repo2" && set -e && source .claude/skills/feature/config.sh && run_readonly_json_role REVIEWER i1 smoke-i1 "$SCHEMA" "$TMP/side/i1-repo2.json" prompt "" ) > "$TMP/i1.log" 2>&1 || { cat "$TMP/i1.log"; fail "I1: 다른 루트의 호출 실패"; }
grep '^rpc thread/start ' "$FAKE_LOG" | tail -1 | grep -q "cwd=${ROOT}2\$" || fail "I1: 다른 루트의 호출이 자기 루트를 cwd 로 쓰지 않음: $(grep '^rpc thread/start' "$FAKE_LOG" | tail -1)"
[ "$(jq -r .project_root "$TMP/repo2/.agent-work/.session-i1.codex-turn.json")" = "${ROOT}2" ] && [ "$(jq -r .thread_id "$TMP/repo2/.agent-work/.session-i1.codex-turn.json")" != "$(jq -r .thread_id .agent-work/.session-i1.codex.json)" ] \
  || fail "I1: 두 루트가 같은 thread·기록을 공유한다"
cp .agent-work/.session-i1.codex.json "$TMP/repo2/.agent-work/.session-i1.codex.json"
( cd "$TMP/repo2" && set -e && source .claude/skills/feature/config.sh && run_readonly_json_role REVIEWER i1 smoke-i1 "$SCHEMA" "$TMP/side/i1-repo2b.json" prompt "" ) > "$TMP/i1.log" 2>&1 && fail "I1: 다른 루트의 원장으로 resume 됨"
expect_fail I1 "$TMP/i1.log" SESSION_LEDGER_MISMATCH
# 같은 저장소의 git worktree(Git common dir 공유): 러너와 같이 FEATURE_PROJECT_ROOT 로 worktree 를 넘긴다 — 기록 루트는 원본이 아니라 현재 worktree 다.
git worktree add -q "$TMP/wt" -b smoke-wt >/dev/null 2>&1 || fail "I1: git worktree 생성 실패"
WT="$(cd "$TMP/wt" && pwd)"
mkdir -p "$WT/.claude/hooks" "$WT/.agent-work" && cp .claude/hooks/core_rules.md "$WT/.claude/hooks/"
( cd "$WT" && set -e && FEATURE_PROJECT_ROOT="$WT" && export FEATURE_PROJECT_ROOT && source "$CFG" && run_readonly_json_role REVIEWER i1 smoke-i1 "$ROOT/$SCHEMA" "$TMP/side/i1-wt.json" prompt "" ) > "$TMP/i1.log" 2>&1 || { cat "$TMP/i1.log"; fail "I1: worktree 의 호출 실패"; }
grep '^rpc thread/start ' "$FAKE_LOG" | tail -1 | grep -q "cwd=$WT\$" && grep '^rpc turn/start ' "$FAKE_LOG" | tail -1 | grep -q "cwd=$WT " || fail "I1: worktree 호출의 thread/turn cwd 가 worktree 가 아님"
[ "$(jq -r .project_root "$WT/.agent-work/.session-i1.codex-turn.json")" = "$WT" ] && [ "$(jq -r .thread_id "$WT/.agent-work/.session-i1.codex-turn.json")" != "$(jq -r .thread_id .agent-work/.session-i1.codex.json)" ] \
  || fail "I1: worktree 가 원본 저장소의 세션을 이어 썼다"
[ "$(jq -r .state "$(rec i1)")" = ACCEPTED ] || fail "I1: worktree 호출이 원본 저장소의 호출 기록을 바꿨다"
git worktree remove --force "$TMP/wt" >/dev/null 2>&1; git branch -q -D smoke-wt >/dev/null 2>&1
pass "I1: 작업 루트마다(복사본·git worktree) 세션·호출 기록·thread 가 분리되고, 다른 루트의 원장은 project_root 불일치로 거부된다"

# ===== I2: 설치 — 새 설치는 app_server, 기존 config.sh 는 보존(줄이 없으면 legacy_exec), 혼합 버전은 사전 거부 =====
INST="$TMP/install-target"; mkdir -p "$INST" && git -C "$INST" init -q
bash "$PROJECT_SRC/install.sh" "$INST" > "$TMP/i2.log" 2>&1 || { tail -20 "$TMP/i2.log"; fail "I2: 새 설치 실패"; }
ICFG="$INST/.claude/skills/feature/config.sh"
grep -q '^CODEX_BACKEND="app_server"' "$ICFG" && [ -f "$INST/.claude/skills/feature/scripts/codex-app-server.sh" ] && [ -f "$INST/.claude/skills/feature/scripts/codex-app-server.mjs" ] \
  || fail "I2: 새 설치의 기본 backend·런타임 파일 불일치"
sed -i.bak '/^CODEX_BACKEND=/d; s/^TEST_CMD="CHANGE_ME"/TEST_CMD="true"/; s/^LINT_CMD="CHANGE_ME"/LINT_CMD="true"/' "$ICFG" && rm -f "$ICFG.bak"
cp "$ICFG" "$TMP/i2-config.keep"
bash "$PROJECT_SRC/install.sh" "$INST" > "$TMP/i2b.log" 2>&1 || { tail -20 "$TMP/i2b.log"; fail "I2: 재설치 실패"; }
cmp -s "$ICFG" "$TMP/i2-config.keep" || fail "I2: 재설치가 기존 config.sh 를 바꿨다"
grep -q 'CODEX_BACKEND 줄이 없습니다' "$TMP/i2b.log" && grep -q 'legacy_exec' "$TMP/i2b.log" || fail "I2: 명시적 전환 안내가 없다"
[ "$( cd "$INST" && source "$ICFG" && role_backend REVIEWER )" = codex_cli ] || fail "I2: CODEX_BACKEND 줄이 없는 기존 설정이 조용히 새 backend 로 취급됨"
sed -i.bak 's/^FEATURE_RUNTIME_CONTRACT_VERSION=.*/FEATURE_RUNTIME_CONTRACT_VERSION=2/' "$ICFG" && rm -f "$ICFG.bak"
cp "$ICFG" "$TMP/i2-config.old"
bash "$PROJECT_SRC/install.sh" "$INST" > "$TMP/i2c.log" 2>&1 && fail "I2: 옛 config.sh 본문(런타임 계약 2) 위에 새 스크립트가 설치됨"
grep -q '혼합 설치 방지' "$TMP/i2c.log" && cmp -s "$ICFG" "$TMP/i2-config.old" || fail "I2: 혼합 설치 거부·config 보존이 아님"
# 런타임 파일이 빠진 혼합 설치: Codex 역할 호출이 exec 로 대체되지 않고 명시적으로 실패한다
reset_case
mv .claude/skills/feature/scripts/codex-app-server.sh "$TMP/held-codex-app-server.sh"
ro_call i2 "$TMP/side/i2.json" > "$TMP/i2d.log" 2>&1; rc=$?
mv "$TMP/held-codex-app-server.sh" .claude/skills/feature/scripts/codex-app-server.sh
[ "$rc" -ne 0 ] && grep -q 'Codex App Server 런타임 없음' "$TMP/i2d.log" && [ "$(execs)" -eq 0 ] || { cat "$TMP/i2d.log"; fail "I2: 런타임 없는 혼합 설치가 명시적으로 실패하지 않음"; }
pass "I2: 새 설치 기본 app_server / 기존 config.sh 보존 + 명시적 전환 안내 / 옛 본문·런타임 누락은 사전 거부(exec 대체 없음)"

# ===== U1: 사용량 — thread 누적값의 차이, 호출당 1행, 중복 이벤트 무시, 근거 없으면 unknown =====
reset_case
FAKE_SCENARIO=usage_dup ro_call u1 "$TMP/side/u1a.json" >/dev/null 2>&1 && accept REVIEWER u1 || fail "U1: 준비 실패"
ro_call u1 "$TMP/side/u1b.json" >/dev/null 2>&1 || fail "U1: 재개 호출 실패"
[ "$(grep -c . .agent-work/usage.jsonl)" -eq 2 ] || fail "U1: usage 행이 호출당 1개가 아님"
jq -s -e 'all(.[]; .cli=="codex" and .backend=="codex_app_server" and .source=="codex-app-server" and .role=="REVIEWER" and .usage_observation_status=="complete"
  and .input_effective==1000 and .cache_read==200 and .input_uncached==800 and .output==50 and .reasoning_output==10 and .tokens_total==1050 and .num_turns==1
  and .context_last_turn==400 and .context_window==400000 and .cost_kind=="estimated" and (.estimated_cost_usd|type)=="number" and .estimated_cost_usd>0 and .cost_usd==null and .exit_code==0)' .agent-work/usage.jsonl >/dev/null \
  || fail "U1: 사용량 행 불일치(누적값을 그대로 썼거나 중복 합산): $(cat .agent-work/usage.jsonl)"
[ "$(jq -s '.[0].estimated_cost_usd == .[1].estimated_cost_usd' .agent-work/usage.jsonl)" = true ] || fail "U1: 재개 호출의 비용이 누적값으로 계산됨"
jq -s -e '(.[0].pricing_assumptions | any(test("baseline=new_thread"))) and (.[1].pricing_assumptions | any(test("baseline=previous_invocation_record")))' .agent-work/usage.jsonl >/dev/null || fail "U1: 기준(provenance) 기록 없음"
jq -e '.usage.duplicates==2 and .usage.updates==2' "$(ls .agent-work/codex-app-server/u1/*.json | head -1)" >/dev/null || fail "U1: 중복 이벤트가 집계되지 않음"
pass "U1: 호출당 1행, 누적값이 아니라 증분(재개 호출도 같은 값), 중복 이벤트는 합산하지 않음, context_last_turn·창 크기 기록"

# ===== U2: 이벤트 없음·필드 손상·기준 없음 → unknown(null) — 0 으로 적지 않는다 =====
reset_case
FAKE_SCENARIO=no_usage ro_call u2 "$TMP/side/u2.json" >/dev/null 2>&1 || fail "U2: no_usage 호출 실패"
jq -e '.usage_observation_status=="unavailable" and .usage_error=="USAGE_EVENTS_MISSING" and .input_effective==null and .output==null and .estimated_cost_usd==null and .cost_kind=="unknown" and (.raw_log|length)>0' .agent-work/usage.jsonl >/dev/null \
  || fail "U2: 이벤트 없는 호출이 unknown 행이 아님: $(cat .agent-work/usage.jsonl)"
reset_case
FAKE_SCENARIO=usage_bad ro_call u2 "$TMP/side/u2.json" >/dev/null 2>&1 || fail "U2: usage_bad 호출 실패"
jq -e '.usage_observation_status=="partial" and .usage_error=="USAGE_FIELDS_INCOMPLETE" and .input_effective==null and .estimated_cost_usd==null' .agent-work/usage.jsonl >/dev/null || fail "U2: 손상된 사용량이 unknown 이 아님: $(cat .agent-work/usage.jsonl)"
# 컨텍스트 측정은 '마지막으로 관측한' 이벤트에서만 읽는다: 첫 이벤트(입력 600)는 정상이고 마지막 이벤트가 불완전할 때 앞선 600 이 남으면 안 된다.
reset_case
FAKE_SCENARIO=usage_last_bad ro_call u2 "$TMP/side/u2.json" >/dev/null 2>&1 || fail "U2: usage_last_bad 호출 실패"
jq -e '.usage_observation_status=="partial" and .usage_error=="USAGE_FIELDS_INCOMPLETE" and .input_effective==null and .estimated_cost_usd==null and .context_last_turn==400 and .context_window==400000' .agent-work/usage.jsonl >/dev/null \
  || fail "U2: 마지막 이벤트의 유효한 입력값(400)이 컨텍스트로 남지 않았거나 앞선 이벤트 값(600)이 남았다: $(jq -c '{usage_error,context_last_turn,context_window}' .agent-work/usage.jsonl)"
reset_case
FAKE_SCENARIO=usage_last_no_input ro_call u2 "$TMP/side/u2.json" >/dev/null 2>&1 || fail "U2: usage_last_no_input 호출 실패"
jq -e '.usage_observation_status=="partial" and .usage_error=="USAGE_FIELDS_INCOMPLETE" and .context_last_turn==null and .context_window==null and .input_effective==null' .agent-work/usage.jsonl >/dev/null \
  || fail "U2: 마지막 이벤트에 입력값이 없는데 앞선 이벤트의 컨텍스트 값이 남았다: $(jq -c '{usage_error,context_last_turn,context_window}' .agent-work/usage.jsonl)"
reset_case
FAKE_SCENARIO=no_usage ro_call u2 "$TMP/side/u2a.json" >/dev/null 2>&1 && accept REVIEWER u2 || fail "U2: 준비 실패"
ro_call u2 "$TMP/side/u2b.json" >/dev/null 2>&1 || fail "U2: 재개 호출 실패"
jq -s -e '.[1].usage_error=="USAGE_BASELINE_UNAVAILABLE" and .[1].input_effective==null and .[1].estimated_cost_usd==null and .[1].context_last_turn==400' .agent-work/usage.jsonl >/dev/null \
  || fail "U2: 기준 없는 재개 호출이 누적값을 증분으로 썼다: $(tail -1 .agent-work/usage.jsonl)"
# 서버가 누적값을 프로세스마다 다시 세는 경우(재개 호출의 '마지막 − 기준' 이 양수여도 틀린 값) → 첫 이벤트가 기준을 증명하지 못하므로 unknown
reset_case
ro_call u3 "$TMP/side/u3a.json" >/dev/null 2>&1 && accept REVIEWER u3 || fail "U2: usage_reset 준비 실패"
FAKE_SCENARIO=usage_reset ro_call u3 "$TMP/side/u3b.json" >/dev/null 2>&1 || fail "U2: usage_reset 재개 호출 실패"
jq -s -e '.[0].input_effective==1000 and .[1].usage_error=="USAGE_BASELINE_MISMATCH" and .[1].input_effective==null and .[1].estimated_cost_usd==null and .[1].cost_kind=="unknown"' .agent-work/usage.jsonl >/dev/null \
  || fail "U2: 기준을 증명하지 못한 재개 사용량이 값으로 기록됨: $(tail -1 .agent-work/usage.jsonl)"
reset_case
FAKE_SCENARIO=no_usage ro_call u2 "$TMP/side/u2a.json" >/dev/null 2>&1 && accept REVIEWER u2 || fail "U2: 요약 준비 실패"
ro_call u2 "$TMP/side/u2b.json" >/dev/null 2>&1 || fail "U2: 요약용 재개 호출 실패"
printf '{"schema_version":4,"invocation_id":"legacy-1","label":"l","role":"VALIDATOR","cli":"codex","model":"gpt-6-astra","cost_usd":null,"estimated_cost_usd":0.5,"usage_observation_status":"complete","source":"codex-events","num_turns":1,"cache_read":0,"output":1}\n' >> .agent-work/usage.jsonl
( source "$CFG"; usage_summary ) > "$TMP/u2-summary.json" || fail "U2: usage_summary 실패"
jq -e '.invocations==3 and .by_source["codex-app-server"].invocations==2 and .by_source["codex-events"].invocations==1 and .by_cli.codex.invocations==3
  and .estimated_cost_usd==0.5 and .cost_unknown_invocations==2 and .usage_unobserved_invocations==2' "$TMP/u2-summary.json" >/dev/null || fail "U2: 두 backend 합산 요약 불일치: $(jq -c '{invocations,estimated_cost_usd,cost_unknown_invocations,usage_unobserved_invocations,by_source:(.by_source|map_values(.invocations))}' "$TMP/u2-summary.json")"
pass "U2: 이벤트 없음·필드 손상·기준 없음 → 토큰·비용 null(unknown), 컨텍스트는 마지막 관측 이벤트에서만(앞선 값 잔존 없음), usage_summary 가 exec 행과 App Server 행을 함께 집계"

# ===== U3: 재개 직후 서버가 직전 turn 의 사용량 이벤트를 그 turn 의 id 로 다시 보낸다(실제 서버 관측) — 이번 호출의 사용량·컨텍스트에 섞이지 않는다 =====
# 1회차는 사용량을 3배로 낸다(누적 3000, 마지막 요청 입력 1200) → 재전송 이벤트의 값(1200)이 2회차의 값(400)과 달라 섞였는지가 드러난다.
u3_resume() { # 시나리오(2회차에만) 기대-재전송-수 → 2회차 usage 행을 $TMP/u3-row.json 에 남긴다
  reset_case
  FAKE_USAGE_SCALE=3 ro_call u3r "$TMP/side/u3r-a.json" >/dev/null 2>&1 && accept REVIEWER u3r || fail "U3($1): 준비 실패"
  FAKE_SCENARIO="$1" ro_call u3r "$TMP/side/u3r-b.json" > "$TMP/u3.log" 2>&1 || { cat "$TMP/u3.log"; fail "U3($1): 재개 호출 실패"; }
  [ "$(jq -c 'select(.method=="thread/tokenUsage/updated" and .params.turnId=="turn-1")' "$TMP/side/u3r-b.json.appserver.jsonl" | grep -c .)" -eq "$2" ] \
    || fail "U3($1): 사례 전제 불일치 — 재개 호출이 받은 직전 turn 의 사용량 이벤트가 $2 개가 아님"
  jq -s -e '.[0].input_effective==3000 and .[0].context_last_turn==1200' .agent-work/usage.jsonl >/dev/null || fail "U3($1): 1회차 행 불일치: $(head -1 .agent-work/usage.jsonl)"
  [ "$(grep -c . .agent-work/usage.jsonl)" -eq 2 ] || fail "U3($1): usage 행이 호출당 1개가 아님"
  tail -1 .agent-work/usage.jsonl > "$TMP/u3-row.json"
}
u3_expect_current() { # 사례이름 — 2회차 행이 이번 turn 의 증분·컨텍스트만 담는다
  jq -e '.usage_observation_status=="complete" and .usage_error==null and .input_effective==1000 and .cache_read==200 and .input_uncached==800 and .output==50 and .tokens_total==1050
    and .context_last_turn==400 and .context_window==400000 and .cost_kind=="estimated" and (.pricing_assumptions | any(test("baseline=previous_invocation_record")))' "$TMP/u3-row.json" >/dev/null \
    || fail "U3($1): 재전송된 직전 turn 의 사용량이 이번 호출에 섞였다: $(jq -c '{usage_observation_status,usage_error,input_effective,cache_read,output,context_last_turn,estimated_cost_usd}' "$TMP/u3-row.json")"
}
u3_resume "" 1; u3_expect_current "재전송 1회"
u3_cost="$(jq -r '.estimated_cost_usd' "$TMP/u3-row.json")"
jq -e '.foreign_events>=1 and .usage.updates==2 and .usage.final_total.inputTokens==4000 and .usage.baseline_total.inputTokens==3000' "$(rec u3r)" >/dev/null \
  || fail "U3: 호출 기록의 사용량 집계 불일치(재전송 이벤트가 이번 turn 의 이벤트로 세어졌다): $(jq -c '{foreign_events,usage}' "$(rec u3r)")"
for sc in "no_resume_replay:0" "resume_replay_dup:2" "resume_replay_early:2" "resume_replay_late:2" "resume_replay_dup,resume_replay_early,resume_replay_late:4"; do
  u3_resume "${sc%%:*}" "${sc#*:}"; u3_expect_current "${sc%%:*}"
  [ "$(jq -r '.estimated_cost_usd' "$TMP/u3-row.json")" = "$u3_cost" ] || fail "U3(${sc%%:*}): 재전송 여부·횟수에 따라 이번 turn 의 비용이 달라졌다($(jq -r '.estimated_cost_usd' "$TMP/u3-row.json") ≠ $u3_cost)"
done
# 이번 turn 이 사용량 이벤트를 내지 않으면: 재전송된 과거 이벤트를 이번 호출의 관측값(토큰·비용·컨텍스트)으로 올리지 않는다
for sc in "no_usage:1" "no_usage,resume_replay_dup,resume_replay_early,resume_replay_late:4"; do
  u3_resume "${sc%%:*}" "${sc#*:}"
  jq -e '.usage_observation_status=="unavailable" and .usage_error=="USAGE_EVENTS_MISSING" and .input_effective==null and .cache_read==null and .output==null and .tokens_total==null
    and .estimated_cost_usd==null and .cost_kind=="unknown" and .context_last_turn==null and .context_window==null' "$TMP/u3-row.json" >/dev/null \
    || fail "U3(${sc%%:*}): 새 이벤트가 없는데 재전송된 과거 사용량이 이번 호출의 관측값이 됐다: $(jq -c '{usage_observation_status,usage_error,input_effective,context_last_turn,context_window,estimated_cost_usd}' "$TMP/u3-row.json")"
done
pass "U3: 재개 직후 직전 turn 의 사용량 재전송(0·1·2회, 재개 응답과 같은 묶음·turn id 확정 전·turn 시작 뒤) — 이번 호출의 증분·비용·context_last_turn 불변, 새 이벤트가 없으면 과거 값을 올리지 않고 unknown"

# ===== L1: 리뷰 루프 통합 — 리뷰어(App Server) Round 1 → 수정자(claude) → Round 2 같은 thread 재개 → APPROVE =====
reset_case
rm -rf .agent-work/reviews/impl-attempt-* .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/feature-scope.lock.json
git checkout -q -- src/u01.txt
( source "$CFG"; snapshot_worktree_tree ) > .agent-work/worker-baseline.tree
echo "worker edit" >> src/u01.txt
cp .agent-work/feature-scope.json .agent-work/feature-scope.lock.json
printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}\n' > .agent-work/worker-result.json
review_issue='{"id":"R-01","action":"FIX_CODE","category":"CONTRACT_VIOLATION","evidence_type":"DIRECT_MISMATCH","basis_refs":["approach.md:L1"],"code_refs":["src/u01.txt:L1-L1"],"reachable_scenario":"","impact":"","why_blocks_now":"x","required_outcome":"y","origin":"ROUND_1","previous_issue_id":"","fix_ref":"","user_question":"","options":[]}'
printf '%s' "$review_issue" | jq -c --argjson v "$REVIEW_CONTRACT" '{schema_version:$v,verdict:"REQUEST_CHANGES",issues:[.]}' > "$FAKE_STATE/reply-1.txt"
printf '{"schema_version":%s,"verdict":"APPROVE","issues":[]}\n' "$REVIEW_CONTRACT" > "$FAKE_STATE/reply-2.txt"
FAKE_EDIT_CMD='echo fixed >> src/u01.txt; echo "- [fix round 1] R-01 ACCEPT" >> .agent-work/decisions.md' bash "$REVIEW_LOOP" > "$TMP/l1.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { tail -30 "$TMP/l1.log"; fail "L1: 루프 exit 0 기대, 실제 $rc"; }
[ "$(grep -c '^rpc thread/start ' "$FAKE_LOG")" -eq 1 ] && grep -q '^rpc thread/resume thread=thr-1 ' "$FAKE_LOG" || fail "L1: Round 2 가 Round 1 의 thread 를 재개하지 않음: $(grep '^rpc thread/' "$FAKE_LOG")"
[ "$(turns)" -eq 2 ] && [ "$(grep -c '^claude editor' "$FAKE_LOG")" -eq 1 ] || fail "L1: 리뷰어 turn 2회 + 수정자 1회가 아님"
jq -e '.backend=="app_server" and .key=="reviewer-a01" and .thread_id=="thr-1" and .last_accepted_label=="impl-review-a01-round-02" and .last_accepted_turn_id=="turn-2"' .agent-work/.session-reviewer-a01.codex.json >/dev/null \
  || fail "L1: 리뷰어 원장 불일치: $(cat .agent-work/.session-reviewer-a01.codex.json)"
[ "$(state_of reviewer-a01)" = ACCEPTED ] || fail "L1: 리뷰어 호출 기록이 ACCEPTED 가 아님"
jq -e '.next_step=="APPROVE" and .round==2 and .attempt==1' .agent-work/review-impl.json >/dev/null || fail "L1: 체크포인트가 APPROVE 가 아님"
[ "$(jq -r 'select(.role=="REVIEWER") | .source' .agent-work/usage.jsonl | paste -sd, -)" = "codex-app-server,codex-app-server" ] || fail "L1: 리뷰어 usage 행 2개(App Server)가 아님"
[ "$(execs)" -eq 0 ] || fail "L1: codex exec 가 호출됨"
pass "L1: 리뷰 루프 — Round 1 thread/start → 수정자 → Round 2 같은 thread 재개 → APPROVE, 원장·기록 수용, exec 0회"

WORKER_DONE='{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}'
PREFLIGHT_CACHE=".agent-work/.codex-app-server-preflight.json"

# ===== P4: 워커의 하위 Agent 금지 — 전달이 아니라 '그 프로세스의 유효 설정'으로 확인하고, 확인하지 못하면 turn/start 전에 멈춘다 =====
# 사용자 설정이 multi_agent_v2 를 켠 상태: 워커 프로세스 인자가 그 프로세스에서만 끄고, 런타임이 유효 값을 읽어 확인한 뒤에 turn 을 보낸다.
reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
FAKE_USER_MULTI_AGENT_V2=1 edit_call WORKER p4 "$TMP/side/p4.log" "$WORKER_SCHEMA_FILE" "$TMP/side/p4-result.json" > "$TMP/p4.log" 2>&1 || { cat "$TMP/p4.log"; fail "P4: multi_agent_v2 를 켠 사용자 설정에서 워커 호출 실패"; }
[ "$(grep '^rpc ' "$FAKE_LOG" | awk '{print $2}' | paste -sd' ' -)" = "initialize initialized config/read experimentalFeature/list experimentalFeature/list hooks/list thread/start config/read experimentalFeature/list experimentalFeature/list hooks/list turn/start" ] \
  || fail "P4: 금지 확인이 thread 생성 전·turn 전송 전에 끝 페이지까지 돌지 않음: $(grep '^rpc ' "$FAKE_LOG" | awk '{print $2}' | paste -sd' ' -)"
grep -q "^rpc config/read cwd=$ROOT\$" "$FAKE_LOG" && grep -q '^rpc experimentalFeature/list thread=thr-1 cursor=page-2' "$FAKE_LOG" || fail "P4: 유효 설정 조회의 cwd·thread 기준 조회·페이지 이어 읽기 불일치"
jq -e '.agents_policy.ok==true and .agents_policy.observed.config["agents.enabled"]==false and .agents_policy.observed.config["features.multi_agent_v2"]==false
  and .agents_policy.observed.config["features.multi_agent"]==false and .agents_policy.observed.features.multi_agent_v2==false and .agents_policy.observed.thread_id=="thr-1"' "$(rec p4)" >/dev/null \
  || fail "P4: 확인 결과가 호출 기록에 없음: $(jq -c '.agents_policy' "$(rec p4)")"
# 덮어쓰기가 먹지 않는 경우·값이 null 인 경우·조회 실패·끝나지 않는 목록 — 어느 것도 turn 을 보내지 않는다(thread 도 만들지 않는다)
for sc in "policy_override_ignored:CODEX_APP_SERVER_AGENTS_POLICY_NOT_ENFORCED" "policy_agents_null:CODEX_APP_SERVER_AGENTS_POLICY_NOT_ENFORCED" \
          "policy_config_error:CODEX_APP_SERVER_AGENTS_POLICY_UNVERIFIED" "policy_list_endless:CODEX_APP_SERVER_AGENTS_POLICY_UNVERIFIED"; do
  reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
  FAKE_SCENARIO="${sc%%:*}" edit_call WORKER p4 "$TMP/side/p4.log" "$WORKER_SCHEMA_FILE" "$TMP/side/p4-result.json" > "$TMP/p4.log" 2>&1; rc=$?
  [ "$rc" -eq 10 ] && [ "$(state_of p4)" = FAILED_BEFORE_SEND ] && [ "$(code_of p4)" = "${sc#*:}" ] || { cat "$TMP/p4.log"; fail "P4(${sc%%:*}): 금지를 확인하지 못했는데 멈추지 않음(rc=$rc, $(state_of p4) $(code_of p4))"; }
  [ "$(turns)" -eq 0 ] && [ "$(grep -c '^rpc thread/start ' "$FAKE_LOG")" -eq 0 ] && [ ! -f "$TMP/side/p4-result.json" ] && [ ! -f .agent-work/usage.jsonl ] || fail "P4(${sc%%:*}): turn·thread·결과·usage 행이 생김"
done
# 설정은 꺼져 있는데 thread 기준 기능 상태가 켜진 경우 — thread 는 만들어졌지만 turn 은 보내지 않는다
reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
FAKE_SCENARIO=policy_thread_v2_on edit_call WORKER p4 "$TMP/side/p4.log" "$WORKER_SCHEMA_FILE" "$TMP/side/p4-result.json" > "$TMP/p4.log" 2>&1; rc=$?
[ "$rc" -eq 10 ] && [ "$(code_of p4)" = CODEX_APP_SERVER_AGENTS_POLICY_NOT_ENFORCED ] && [ "$(turns)" -eq 0 ] || { cat "$TMP/p4.log"; fail "P4(policy_thread_v2_on): thread 기준 확인이 turn 을 막지 못함(rc=$rc, $(code_of p4), turn $(turns))"; }
# 설치된 codex 에 조회 수단이 없으면 확인 자체가 불가능하다 — 서버를 띄우지 않는다
reset_case; rm -f "$PREFLIGHT_CACHE"
FAKE_SCHEMA_DROP=config/read edit_call WORKER p4 "$TMP/side/p4.log" "$WORKER_SCHEMA_FILE" "$TMP/side/p4-result.json" > "$TMP/p4.log" 2>&1 && fail "P4: 유효 설정 조회가 없는 codex 에서 워커가 실행됨"
expect_fail P4 "$TMP/p4.log" CODEX_APP_SERVER_AGENTS_POLICY_UNVERIFIABLE
[ "$(spawns)" -eq 0 ] && [ ! -f "$(rec p4)" ] || fail "P4: 확인 수단이 없는데 서버·기록을 만들었다"
# 같은 codex 에서 워커가 아닌 역할은 영향을 받지 않는다
FAKE_SCHEMA_DROP=config/read ro_call p4ro "$TMP/side/p4ro.json" > "$TMP/p4.log" 2>&1 || { cat "$TMP/p4.log"; fail "P4: 조회 수단이 없다는 이유로 읽기 전용 역할까지 막혔다"; }
# 사용자 설정이 strict 검사에 걸려 키만 따로 가릴 수 없는 경우: 경고하고 실행하던 경로가 아니라, 런타임 확인이 판정한다(통과면 실행, 아니면 중단)
reset_case; rm -f "$PREFLIGHT_CACHE"; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
FAKE_STRICT_BASE_FAIL=1 FAKE_SCENARIO=policy_override_ignored edit_call WORKER p4 "$TMP/side/p4.log" "$WORKER_SCHEMA_FILE" "$TMP/side/p4-result.json" > "$TMP/p4.log" 2>&1; rc=$?
[ "$rc" -eq 10 ] && [ "$(code_of p4)" = CODEX_APP_SERVER_AGENTS_POLICY_NOT_ENFORCED ] && [ "$(turns)" -eq 0 ] || { cat "$TMP/p4.log"; fail "P4: 사전 확인을 미룬 경우에 런타임 확인이 워커를 막지 못함(rc=$rc)"; }
FAKE_STRICT_BASE_FAIL=1 edit_call WORKER p4 "$TMP/side/p4.log" "$WORKER_SCHEMA_FILE" "$TMP/side/p4-result.json" > "$TMP/p4.log" 2>&1 || { cat "$TMP/p4.log"; fail "P4: 사전 확인을 미뤘고 런타임 확인이 통과했는데 워커가 실행되지 않음"; }
jq -e '.agents_policy.ok==true' "$(rec p4)" >/dev/null && ! grep -q '설정 값은 그대로 전달한다' "$TMP/p4.log" || fail "P4: 확인 없이 전달만 하는 종전 경로가 남아 있다"
rm -f "$PREFLIGHT_CACHE"
# 사후 탐지: 확인을 지나고도 turn 중 하위 Agent 활동이 관측되면 turn 을 중단하고 결과를 쓰지 않는다
for sc in subagent_item subagent_thread; do
  reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
  FAKE_SCENARIO="$sc" edit_call WORKER p4 "$TMP/side/p4.log" "$WORKER_SCHEMA_FILE" "$TMP/side/p4-result.json" > "$TMP/p4.log" 2>&1; rc=$?
  [ "$rc" -eq 20 ] && [ "$(state_of p4)" = REJECTED ] && [ "$(code_of p4)" = CODEX_APP_SERVER_SUBAGENT_OBSERVED ] && [ ! -f "$TMP/side/p4-result.json" ] \
    || { cat "$TMP/p4.log"; fail "P4($sc): 하위 Agent 활동이 관측됐는데 결과가 쓰였다(rc=$rc, $(state_of p4) $(code_of p4))"; }
  grep -q '^rpc turn/interrupt thread=thr-1 turn=turn-1' "$FAKE_LOG" && jq -e '.subagent_activity | length >= 1' "$(rec p4)" >/dev/null || fail "P4($sc): turn 중단·관측 기록이 없음"
done
# 읽기 전용 역할은 이 탐지의 대상이 아니다(금지 정책은 워커 전용)
reset_case
FAKE_SCENARIO=subagent_thread ro_call p4ro "$TMP/side/p4ro.json" > "$TMP/p4.log" 2>&1 || { cat "$TMP/p4.log"; fail "P4: 워커가 아닌 역할에 하위 Agent 탐지가 적용됨"; }
pass "P4: 워커 하위 Agent 금지 — 프로세스 한정 덮어쓰기(multi_agent_v2 포함) + 유효 설정·기능 상태 확인(끝 페이지·thread 기준), 미확인·미적용·조회 불가는 turn 0회, turn 중 관측은 중단·불수용"

# ===== P5: 읽기 전용 역할의 스냅샷 실패는 '바뀌지 않았다'가 아니다 — 호출 전 실패는 실행 전에, 호출 뒤 실패는 결과 불수용으로 =====
snap_fail_pre_tree() { snapshot_worktree_tree() { return 1; }; }
snap_fail_pre_index() { compute_index_fingerprint() { return 1; }; }
snap_fail_post_tree() {
  eval "orig_$(declare -f snapshot_worktree_tree)"
  snapshot_worktree_tree() { echo x >> "$TMP/side/snapcount"; [ "$(grep -c . "$TMP/side/snapcount")" -le 1 ] || return 1; orig_snapshot_worktree_tree; }
}
snap_fail_post_index() {
  eval "orig_$(declare -f compute_index_fingerprint)"
  compute_index_fingerprint() { echo x >> "$TMP/side/snapcount"; [ "$(grep -c . "$TMP/side/snapcount")" -le 1 ] || return 1; orig_compute_index_fingerprint; }
}
ro_call_hooked() { # hook key out
  ( set -e; source "$CFG"; "$1"; run_readonly_json_role REVIEWER "$2" "smoke-$2" "$SCHEMA" "$3" "prompt" "" )
}
for hook in snap_fail_pre_tree snap_fail_pre_index; do
  reset_case
  ro_call_hooked "$hook" p5 "$TMP/side/p5.json" > "$TMP/p5.log" 2>&1 && fail "P5($hook): 호출 전 스냅샷이 실패했는데 실행됨"
  expect_fail "P5($hook)" "$TMP/p5.log" CODEX_APP_SERVER_READONLY_SNAPSHOT_FAILED
  [ "$(spawns)" -eq 0 ] && [ "$(turns)" -eq 0 ] && [ ! -f "$(rec p5)" ] && [ ! -f "$TMP/side/p5.json" ] || fail "P5($hook): 스냅샷 없이 서버·turn·기록·결과가 만들어짐"
done
for hook in snap_fail_post_tree snap_fail_post_index; do
  reset_case
  ro_call_hooked "$hook" p5 "$TMP/side/p5.json" > "$TMP/p5.log" 2>&1 && fail "P5($hook): 호출 뒤 스냅샷이 실패했는데 결과가 수용됨"
  expect_fail "P5($hook)" "$TMP/p5.log" CODEX_APP_SERVER_READONLY_SNAPSHOT_FAILED
  [ "$(turns)" -eq 1 ] && [ "$(state_of p5)" = REJECTED ] && [ "$(code_of p5)" = CODEX_APP_SERVER_READONLY_SNAPSHOT_FAILED ] && [ ! -f "$TMP/side/p5.json" ] && [ ! -f .agent-work/.session-p5.codex.json.new ] \
    || fail "P5($hook): 대조하지 못한 결과가 넘어갔거나 세션이 스테이징됨($(state_of p5) $(code_of p5))"
done
# 호출 전 값이 없는 기록(예전 기록·손상)의 완료 결과를 재사용할 때도 검사를 건너뛰지 않는다
reset_case
( source "$CFG"; codex_app_invoke REVIEWER readonly p5r smoke-p5r "$SCHEMA" "$TMP/side/p5r.json" "prompt" ) >/dev/null 2>&1 || fail "P5: 준비 실패"
jq 'del(.pre_index)' "$(rec p5r)" > "$TMP/side/p5r.rec" && cp "$TMP/side/p5r.rec" "$(rec p5r)"
ro_call p5r "$TMP/side/p5r.json" > "$TMP/p5.log" 2>&1 && fail "P5: index 기준이 없는 기록의 결과가 수용됨"
expect_fail P5 "$TMP/p5.log" CODEX_APP_SERVER_READONLY_SNAPSHOT_FAILED
[ "$(turns)" -eq 1 ] && [ ! -f "$TMP/side/p5r.json" ] && [ "$(state_of p5r)" = REJECTED ] || fail "P5: 기준 없는 기록이 CONSUMED 까지 갔다($(state_of p5r))"
pass "P5: 읽기 전용 스냅샷 — 호출 전 tree·index 실패는 서버 미기동, 호출 뒤 실패·기준 없는 기록은 REJECTED(결과·세션 불수용)"

# ===== C8: 완료 여부 불명인 편집 호출은 세션으로 확정되지 않는다(스테이징 없음, accept 거부·원장 불변). 완료가 확인된 실패는 종전대로 수용된다 =====
reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
FAKE_SCENARIO=crash_before_turn_response FAKE_APP_EDIT_CMD='echo "partial edit" >> src/u01.txt' edit_call WORKER c8 "$TMP/side/c8.log" "$WORKER_SCHEMA_FILE" "$TMP/side/c8-result.json" > "$TMP/c8.log" 2>&1; rc=$?
[ "$rc" -eq 30 ] && [ "$(state_of c8)" = UNKNOWN ] && grep -q 'partial edit' src/u01.txt || { cat "$TMP/c8.log"; fail "C8: 준비 상태 불일치(rc=$rc, $(state_of c8))"; }
[ ! -f .agent-work/.session-c8.codex.json.new ] && [ ! -f .agent-work/.session-c8.codex.json ] || fail "C8: 불명 호출이 세션 원장을 스테이징했다"
accept WORKER c8 > "$TMP/c8.log" 2>&1 && fail "C8: 불명 상태인데 세션 수용이 성공(exit 0)했다"
expect_fail C8 "$TMP/c8.log" CODEX_TURN_UNCERTAIN
[ ! -f .agent-work/.session-c8.codex.json ] && [ "$(state_of c8)" = UNKNOWN ] || fail "C8: 거부된 수용이 원장·기록을 바꿨다"
( source "$CFG"; codex_app_stop_if_uncertain c8 "smoke" ) > "$TMP/c8.log" 2>&1 && fail "C8: 불명 편집 기록이 있는데 다음 단계로 가는 판정이 통과됨"
expect_fail C8 "$TMP/c8.log" CODEX_TURN_UNCERTAIN "status c8"
git checkout -q -- src/u01.txt
# 이미 확정된 세션 위의 재개 호출이 불명으로 끝난 경우: 원장은 직전 수용 그대로다
reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
edit_call WORKER c8 "$TMP/side/c8.log" "$WORKER_SCHEMA_FILE" "$TMP/side/c8-result.json" >/dev/null 2>&1 && accept WORKER c8 || fail "C8: 재개 준비 실패"
cp .agent-work/.session-c8.codex.json "$TMP/side/c8-ledger.keep"
FAKE_SCENARIO=crash_before_turn_response edit_call WORKER c8 "$TMP/side/c8.log" "$WORKER_SCHEMA_FILE" "$TMP/side/c8-result.json" > "$TMP/c8.log" 2>&1; rc=$?
[ "$rc" -eq 30 ] && [ "$(jq -r .mode "$(rec c8)")" = resume ] || fail "C8: 재개 호출이 불명으로 끝나지 않음(rc=$rc)"
accept WORKER c8 > "$TMP/c8.log" 2>&1 && fail "C8: 불명 재개 호출의 수용이 성공했다"
cmp -s .agent-work/.session-c8.codex.json "$TMP/side/c8-ledger.keep" && [ ! -f .agent-work/.session-c8.codex.json.new ] || fail "C8: 거부된 수용이 확정 원장을 바꿨다"
# turn 이 끝난 것이 확인된 실패(TURN_FAILED)는 호출자가 넘기기로 하면 수용된다 — 이 경로는 막지 않는다
reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
FAKE_SCENARIO=turn_failed edit_call WORKER c8f "$TMP/side/c8f.log" "$WORKER_SCHEMA_FILE" "$TMP/side/c8f-result.json" > "$TMP/c8.log" 2>&1; rc=$?
[ "$rc" -eq 20 ] && [ "$(state_of c8f)" = TURN_FAILED ] && [ -f .agent-work/.session-c8f.codex.json.new ] || { cat "$TMP/c8.log"; fail "C8: 확인된 실패의 준비 상태 불일치(rc=$rc)"; }
( source "$CFG"; codex_app_stop_if_uncertain c8f "smoke" ) || fail "C8: 완료가 확인된 실패를 불명으로 판정했다"
accept WORKER c8f > "$TMP/c8.log" 2>&1 || { cat "$TMP/c8.log"; fail "C8: 완료가 확인된 실패의 수용이 거부됨"; }
[ -f .agent-work/.session-c8f.codex.json ] && jq -e '.accepted_by_caller==true and .state=="TURN_FAILED"' "$(rec c8f)" >/dev/null || fail "C8: 확인된 실패의 수용 기록 불일치"
pass "C8: 불명(UNKNOWN) 편집 호출 — 원장 스테이징 없음·수용 거부(exit≠0)·확정 원장 불변, 완료가 확인된 실패(TURN_FAILED)의 수용은 그대로"

# ===== L2: 리뷰 루프 — Codex 수정자가 불명으로 끝나면 범위 안 변경이 있어도 리뷰어로 넘기지 않는다(재실행도 모델 0회). 조회로 완료가 확인된 뒤에만 리뷰어가 본다 =====
review_fixture() {
  reset_case
  rm -rf .agent-work/reviews/impl-attempt-* .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/feature-scope.lock.json
  : > .agent-work/decisions.md
  git checkout -q -- src/u01.txt
  ( source "$CFG"; snapshot_worktree_tree ) > .agent-work/worker-baseline.tree
  echo "worker edit" >> src/u01.txt
  cp .agent-work/feature-scope.json .agent-work/feature-scope.lock.json
  printf '%s\n' "$WORKER_DONE" > .agent-work/worker-result.json
  printf '%s' "$review_issue" | jq -c --argjson v "$REVIEW_CONTRACT" '{schema_version:$v,verdict:"REQUEST_CHANGES",issues:[.]}' > "$FAKE_STATE/reply-1.txt"   # turn 1: 리뷰어 Round 1
  printf '%s\n' 'echo fixed >> src/u01.txt' 'echo "- [fix round 1] R-01 ACCEPT" >> .agent-work/decisions.md' > "$FAKE_STATE/edit-2.sh"                      # turn 2: 수정자
  printf '{"schema_version":%s,"verdict":"APPROVE","issues":[]}\n' "$REVIEW_CONTRACT" > "$FAKE_STATE/reply-3.txt"                                           # turn 3: 리뷰어 Round 2
}
sed -i.bak 's/^FIXER_CLI=.*/FIXER_CLI="codex"/; s/^FIXER_MODEL=.*/FIXER_MODEL="gpt-6-sol"/' "$CFG" && rm -f "$CFG.bak"
review_fixture
printf 'crash_before_turn_response' > "$FAKE_STATE/scenario-2.txt"
bash "$REVIEW_LOOP" > "$TMP/l2.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q 'CODEX_TURN_UNCERTAIN' "$TMP/l2.log" || { tail -30 "$TMP/l2.log"; fail "L2: 불명 수정자 뒤 exit 1(CODEX_TURN_UNCERTAIN) 기대, 실제 $rc"; }
grep -q 'fixed' src/u01.txt || fail "L2: 사례 전제 불일치 — 수정자의 범위 안 변경이 없다"
! grep -q 'WARN\] CLI_EXIT_STATUS_MISMATCH' "$TMP/l2.log" && ! grep -q 'FORWARD_TO_REVIEWER' .agent-work/cli-anomalies.jsonl 2>/dev/null || fail "L2: 불명 호출을 '종료 코드만 비정상'으로 보고 리뷰어에게 넘겼다"
[ "$(turns)" -eq 2 ] && [ "$(jq -r .next_step .agent-work/review-impl.json)" = FIXER_PENDING ] || fail "L2: 리뷰어가 호출됐거나 체크포인트가 넘어갔다(turn $(turns), $(jq -r .next_step .agent-work/review-impl.json))"
[ ! -f .agent-work/.session-fixer-a01.codex.json ] && [ ! -f .agent-work/.session-fixer-a01.codex.json.new ] && [ "$(state_of fixer-a01)" = UNKNOWN ] || fail "L2: 불명 수정자의 세션이 확정·스테이징됐다"
l2_spawns="$(spawns)"
bash "$REVIEW_LOOP" > "$TMP/l2.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q 'CODEX_TURN_UNCERTAIN' "$TMP/l2.log" && [ "$(turns)" -eq 2 ] && [ "$(spawns)" -eq "$l2_spawns" ] && [ "$(jq -r .next_step .agent-work/review-impl.json)" = FIXER_PENDING ] \
  || { tail -30 "$TMP/l2.log"; fail "L2: 재실행이 '수정자가 고치다 죽음' 경로로 리뷰어에게 넘어갔다(rc=$rc, turn $(turns), spawn $(spawns), $(jq -r .next_step .agent-work/review-impl.json))"; }
[ "$(cli reconcile fixer-a01 2>/dev/null | jq -r .verdict)" = RECOVERED ] && [ "$(turns)" -eq 2 ] || fail "L2: 조회 복구 실패 또는 새 turn 발생"
bash "$REVIEW_LOOP" > "$TMP/l2.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(turns)" -eq 3 ] && jq -e '.next_step=="APPROVE" and .round==2' .agent-work/review-impl.json >/dev/null && [ "$(grep -c '^rpc turn/start .*thread=thr-2 ' "$FAKE_LOG")" -eq 1 ] \
  || { tail -30 "$TMP/l2.log"; fail "L2: 완료가 확인된 뒤의 재실행이 수정자 재호출 없이 리뷰어 Round 2 로 가지 않음(rc=$rc, turn $(turns))"; }
pass "L2: Codex 수정자 UNKNOWN + 범위 안 변경 → 리뷰어 0회·세션 미확정·FIXER_PENDING 유지(재실행도 모델 0회), reconcile 로 완료 확인 뒤에만 리뷰어 Round 2"

# ===== L3: 리뷰 루프 — turn 이 끝난 것이 확인된 실패(TURN_FAILED) + 범위 안 변경은 종전대로 리뷰어가 독립 판정한다 =====
review_fixture
printf 'turn_failed' > "$FAKE_STATE/scenario-2.txt"
bash "$REVIEW_LOOP" > "$TMP/l3.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q 'WARN\] CLI_EXIT_STATUS_MISMATCH' "$TMP/l3.log" && [ "$(turns)" -eq 3 ] && jq -e '.next_step=="APPROVE" and .round==2' .agent-work/review-impl.json >/dev/null \
  || { tail -30 "$TMP/l3.log"; fail "L3: 확인된 실패 + 변경이 리뷰어에게 전달되지 않음(rc=$rc, turn $(turns))"; }
jq -e '.recovery=="FORWARD_TO_REVIEWER"' .agent-work/cli-anomalies.jsonl >/dev/null && [ -f .agent-work/.session-fixer-a01.codex.json ] && jq -e '.accepted_by_caller==true' "$(rec fixer-a01)" >/dev/null \
  || fail "L3: 전달 기록·수정자 세션 수용 불일치"
sed -i.bak 's/^FIXER_CLI=.*/FIXER_CLI="claude"/; s/^FIXER_MODEL=.*/FIXER_MODEL="claude-sonnet-5-5"/' "$CFG" && rm -f "$CFG.bak"
git checkout -q -- src/u01.txt
pass "L3: Codex 수정자 TURN_FAILED + 범위 안 변경 → CLI_EXIT_STATUS_MISMATCH 로 리뷰어 전달·세션 수용(종전 경로 유지)"

# ===== D1: 합의 루프 — Codex 디자이너가 불명으로 끝나면 문서가 바뀌었어도 검증자로 넘기지 않는다(재실행도 모델 0회) =====
reset_case
VALIDATOR_CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
cp "$CFG" "$TMP/side-config.keep"
sed -i.bak 's/^DESIGNER_CLI=.*/DESIGNER_CLI="codex"/; s/^DESIGN_REVISION_MODEL=.*/DESIGN_REVISION_MODEL="gpt-6-astra"/; s/^VALIDATOR_PROFILE=.*/VALIDATOR_PROFILE="none"/' "$CFG" && rm -f "$CFG.bak"
rm -f .agent-work/consensus-design.json .agent-work/reviews/validator-design-*
printf '{"schema_version":%s,"verdict":"BLOCK","blocking_issues":[{"id":"B-01","action":"REVISE_DOC","category":"CONTRACT_GAP","change_relation":"NEW","evidence_type":"DIRECT_MISMATCH","basis_refs":["design.md:L1"],"conflict_refs":["design.md:L1"],"code_refs":[],"reachable_scenario":"","impact":"x","why_blocks_now":"y","minimum_contract_needed":"z","user_question":"","options":[],"origin":"ROUND_1","previous_issue_id":"","revision_ref":""}]}\n' "$VALIDATOR_CONTRACT" > "$FAKE_STATE/reply-1.txt"   # turn 1: 검증자 Round 1
printf '%s\n' 'echo "revised by designer" >> .agent-work/design.md' 'echo "- [design round 1] B-01 ACCEPT" >> .agent-work/decisions.md' > "$FAKE_STATE/edit-2.sh"   # turn 2: 디자이너
printf 'crash_before_turn_response' > "$FAKE_STATE/scenario-2.txt"
bash .claude/skills/feature/scripts/consensus-loop.sh design > "$TMP/d1.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q 'CODEX_TURN_UNCERTAIN' "$TMP/d1.log" && grep -q 'revised by designer' .agent-work/design.md || { tail -30 "$TMP/d1.log"; fail "D1: 불명 디자이너 뒤 exit 1(CODEX_TURN_UNCERTAIN) 기대, 실제 $rc"; }
! grep -q 'WARN\] CLI_EXIT_STATUS_MISMATCH' "$TMP/d1.log" && [ "$(turns)" -eq 2 ] && [ "$(jq -r .next_step .agent-work/consensus-design.json)" = DESIGNER_PENDING ] \
  || fail "D1: 불명 디자이너의 문서 변경이 검증자에게 넘어갔다(turn $(turns), $(jq -r .next_step .agent-work/consensus-design.json))"
[ ! -f .agent-work/.session-designer-design.codex.json ] && [ ! -f .agent-work/.session-designer-design.codex.json.new ] || fail "D1: 불명 디자이너의 세션이 확정·스테이징됐다"
d1_spawns="$(spawns)"
bash .claude/skills/feature/scripts/consensus-loop.sh design > "$TMP/d1.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q 'CODEX_TURN_UNCERTAIN' "$TMP/d1.log" && [ "$(turns)" -eq 2 ] && [ "$(spawns)" -eq "$d1_spawns" ] && [ "$(jq -r .next_step .agent-work/consensus-design.json)" = DESIGNER_PENDING ] \
  || { tail -30 "$TMP/d1.log"; fail "D1: 재실행이 '디자이너가 고치다 죽음' 경로로 검증자에게 넘어갔다(rc=$rc, turn $(turns), $(jq -r .next_step .agent-work/consensus-design.json))"; }
cp "$TMP/side-config.keep" "$CFG"
printf '# design\n' > .agent-work/design.md; : > .agent-work/decisions.md
rm -f .agent-work/consensus-design.json
pass "D1: Codex 디자이너 UNKNOWN + 문서 변경 → 검증자 0회·세션 미확정·DESIGNER_PENDING 유지(재실행도 모델 0회)"

# ===== G1: 편집 역할의 필수 훅 게이트 — 워커·수정자·디자이너 모두 hooks/list 로 등록·활성·신뢰를 확인한 뒤에만 turn 을 보낸다(읽기 전용 역할은 대상이 아니다) =====
cp "$CFG" "$TMP/g-config.keep"
sed -i.bak 's/^FIXER_CLI=.*/FIXER_CLI="codex"/; s/^FIXER_MODEL=.*/FIXER_MODEL="gpt-6-sol"/; s/^DESIGNER_CLI=.*/DESIGNER_CLI="codex"/; s/^DESIGN_REVISION_MODEL=.*/DESIGN_REVISION_MODEL="gpt-6-astra"/' "$CFG" && rm -f "$CFG.bak"
g_call() { # ROLE key → run_edit_role 의 반환값 (워커만 결과 스키마를 쓴다)
  if [ "$1" = WORKER ]; then edit_call WORKER "$2" "$TMP/side/$2.log" "$WORKER_SCHEMA_FILE" "$TMP/side/$2-result.json"; else edit_call "$1" "$2" "$TMP/side/$2.log"; fi
}
g_untouched() { # key 사례 — 모델 호출·결과·사용량·세션이 하나도 생기지 않았다
  [ "$(turns)" -eq 0 ] && [ ! -f .agent-work/usage.jsonl ] && [ ! -f "$TMP/side/$1-result.json" ] && [ ! -f ".agent-work/.session-$1.codex.json" ] && [ ! -f ".agent-work/.session-$1.codex.json.new" ] \
    || fail "$2: turn·결과·usage 행·세션 원장이 생겼다(turn $(turns))"
}
for role in WORKER FIXER DESIGNER; do
  reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
  g_call "$role" "g1$role" > "$TMP/g1.log" 2>&1 || { cat "$TMP/g1.log"; fail "G1($role): 훅이 건강한데 호출 실패"; }
  seq="$(grep '^rpc ' "$FAKE_LOG" | awk '{print $2}' | grep -v 'config/read\|experimentalFeature/list' | paste -sd' ' -)"
  [ "$seq" = "initialize initialized hooks/list thread/start hooks/list turn/start" ] || fail "G1($role): 훅 확인이 thread 생성 전·turn 전송 직전에 돌지 않음: $seq"
  grep -q "^rpc hooks/list thread=- cwds=$ROOT\$" "$FAKE_LOG" && grep -q '^rpc hooks/list thread=thr-1 cwds=-$' "$FAKE_LOG" || fail "G1($role): cwd 기준·thread 기준 조회 인자 불일치"
  jq -e --arg root "$ROOT" '.role_kind=="edit" and .required_hook.event=="preToolUse" and .required_hook.script==".codex/hooks/worker_guard.sh" and .required_hook.script_contract=="WORKER_GUARD_CONTRACT=3" and .required_hook.command=="bash .codex/hooks/worker_guard.sh" and .required_hook.list_supported==true and (.required_hook.reviewed_sha256 | length)==1 and (.required_hook.reviewed_sha256[0] | test("^[0-9a-f]{64}$"))
    and (.required_hook.source_paths | index($root + "/.codex/hooks.json") != null)
    and .hook_gate.ok==true and .hook_gate.reason=="ok" and .hook_gate.observed.mode=="thread" and .hook_gate.observed.thread_id=="thr-1"
    and (.hook_gate.observed.candidates | length)==1 and .hook_gate.observed.candidates[0].trust_status=="trusted" and .hook_gate.observed.candidates[0].enabled==true' "$(rec "g1$role")" >/dev/null \
    || fail "G1($role): 사양·확인 결과가 호출 기록에 없음: $(jq -c '{required_hook, hook_gate}' "$(rec "g1$role")")"
done
# 관리 정책(managed)으로 신뢰된 훅도 통과다
reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
FAKE_SCENARIO=hook_managed g_call WORKER g1m > "$TMP/g1.log" 2>&1 || { cat "$TMP/g1.log"; fail "G1: managed 훅에서 워커 호출 실패"; }
# 읽기 전용 역할은 hooks/list 를 보내지 않고, 훅 상태와 무관하게 돈다
reset_case
FAKE_SCENARIO=hook_missing ro_call g1ro "$TMP/side/g1ro.json" > "$TMP/g1.log" 2>&1 || { cat "$TMP/g1.log"; fail "G1: 읽기 전용 역할이 훅 게이트에 막혔다"; }
[ "$(grep -c '^rpc hooks/list ' "$FAKE_LOG")" -eq 0 ] && jq -e '.required_hook==null and (has("hook_gate")|not)' "$(rec g1ro)" >/dev/null || fail "G1: 읽기 전용 역할이 hooks/list 를 보냈거나 기록에 게이트가 남음"
pass "G1: 워커·수정자·디자이너는 hooks/list(cwd 기준 → thread 기준) 통과 뒤에만 turn/start, managed 통과, 읽기 전용 역할은 대상 아님"

# ===== G2: 훅 누락·비활성·미신뢰·변경됨·조회 실패·형식 불일치·출처 불일치 → FAILED_BEFORE_SEND, 모델 0회(thread 도 만들지 않는다) =====
for sc in "hook_missing:NOT_ACTIVE:missing" "hook_wrong_event:NOT_ACTIVE:missing" "hook_wrong_source:NOT_ACTIVE:source_mismatch" "hook_disabled:NOT_ACTIVE:disabled" \
          "hook_wrong_command:NOT_ACTIVE:command_mismatch" "hook_matcher:NOT_ACTIVE:matcher_scoped" "hook_async:NOT_ACTIVE:async" "hook_untrusted:NOT_ACTIVE:untrusted" "hook_modified:NOT_ACTIVE:modified" "hook_trust_weird:NOT_ACTIVE:trust_unknown" \
          "hook_list_error:UNVERIFIED:query_failed" "hook_bad_shape:UNVERIFIED:bad_shape" "hook_wrong_cwd:UNVERIFIED:bad_shape"; do
  name="${sc%%:*}"; rest="${sc#*:}"; code="CODEX_APP_SERVER_HOOK_GATE_${rest%%:*}"; reason="${rest#*:}"
  for role in WORKER FIXER DESIGNER; do
    reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
    FAKE_SCENARIO="$name" g_call "$role" g2 > "$TMP/g2.log" 2>&1; rc=$?
    [ "$rc" -eq 10 ] && [ "$(state_of g2)" = FAILED_BEFORE_SEND ] && [ "$(code_of g2)" = "$code" ] && [ "$(jq -r '.hook_gate.reason' "$(rec g2)")" = "$reason" ] && [ "$(jq -r '.hook_gate.ok' "$(rec g2)")" = false ] \
      || { cat "$TMP/g2.log"; fail "G2($name/$role): 멈추지 않았거나 판정이 다름(rc=$rc, $(state_of g2) $(code_of g2) $(jq -r '.hook_gate.reason' "$(rec g2)"))"; }
    [ "$(grep -c '^rpc thread/start ' "$FAKE_LOG")" -eq 0 ] || fail "G2($name/$role): 훅이 확인되지 않았는데 thread 를 만들었다"
    g_untouched g2 "G2($name/$role)"
    grep -q "$code" "$TMP/g2.log" && grep -q 'trust 를 대신 승인하지 않고' "$TMP/g2.log" || { cat "$TMP/g2.log"; fail "G2($name/$role): 사유·안내가 출력되지 않음"; }
  done
done
# 미전송 실패는 모델 0회가 확정된 상태다 — 훅이 건강해진 뒤의 재실행은 같은 key 로 그대로 이어 간다
reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
FAKE_SCENARIO=hook_untrusted g_call WORKER g2r > /dev/null 2>&1; [ "$(state_of g2r)" = FAILED_BEFORE_SEND ] || fail "G2: 재실행 사례 준비 실패"
g_call WORKER g2r > "$TMP/g2.log" 2>&1 || { cat "$TMP/g2.log"; fail "G2: 훅이 신뢰된 뒤의 재실행이 막힘"; }
[ "$(turns)" -eq 1 ] && [ "$(jq -r '.hook_gate.ok' "$(rec g2r)")" = true ] || fail "G2: 재실행이 turn 1회로 이어지지 않음(turn $(turns))"
pass "G2: 누락·다른 이벤트·출처 불일치·비활성·async·미신뢰·변경됨·모르는 신뢰 값·조회 실패·형식 불일치 × 워커·수정자·디자이너 → FAILED_BEFORE_SEND, thread·turn·usage·세션 0, 재실행은 이어 감"

# ===== G3: thread 기준 재확인 · 서버를 띄우기 전의 정적 조건(스크립트 없음·조회 수단 없음·사양 없음·게이트 없는 런타임) =====
reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
FAKE_SCENARIO=hook_thread_untrusted g_call WORKER g3 > "$TMP/g3.log" 2>&1; rc=$?
[ "$rc" -eq 10 ] && [ "$(state_of g3)" = FAILED_BEFORE_SEND ] && [ "$(code_of g3)" = CODEX_APP_SERVER_HOOK_GATE_NOT_ACTIVE ] && [ "$(jq -r '.hook_gate.observed.mode' "$(rec g3)")" = thread ] \
  && [ "$(grep -c '^rpc thread/start ' "$FAKE_LOG")" -eq 1 ] || { cat "$TMP/g3.log"; fail "G3: thread 기준 확인이 turn 을 막지 못함(rc=$rc, $(state_of g3) $(code_of g3))"; }
g_untouched g3 "G3(thread 기준)"
# 훅이 부를 스크립트가 작업 루트에 없다 — hooks/list 가 건강하다고 해도 서버를 띄우지 않는다
reset_case; mv .codex/hooks/worker_guard.sh "$TMP/worker_guard.keep"
g_call FIXER g3 > "$TMP/g3.log" 2>&1; rc=$?
mv "$TMP/worker_guard.keep" .codex/hooks/worker_guard.sh
[ "$rc" -eq 10 ] && [ "$(state_of g3)" = FAILED_BEFORE_SEND ] && [ "$(jq -r '.hook_gate.reason' "$(rec g3)")" = script_missing ] && [ "$(spawns)" -eq 0 ] || { cat "$TMP/g3.log"; fail "G3: 스크립트가 없는데 멈추지 않음(rc=$rc, spawn $(spawns))"; }
# 가드 스크립트가 옛 세대다(계약 세대 줄 없음 · 낮은 세대 · 주석으로만 적힘) — 훅이 신뢰돼 있어도 서버를 띄우지 않는다
for body in '#!/bin/sh\nexit 0\n' '#!/bin/sh\nWORKER_GUARD_CONTRACT=1\nexit 0\n' '#!/bin/sh\nWORKER_GUARD_CONTRACT=2\nexit 0\n' '#!/bin/sh\n# WORKER_GUARD_CONTRACT=3\nexit 0\n'; do
  reset_case; cp .codex/hooks/worker_guard.sh "$TMP/worker_guard.keep"; printf "$body" > .codex/hooks/worker_guard.sh
  g_call WORKER g3 > "$TMP/g3.log" 2>&1; rc=$?
  cp "$TMP/worker_guard.keep" .codex/hooks/worker_guard.sh
  [ "$rc" -eq 10 ] && [ "$(state_of g3)" = FAILED_BEFORE_SEND ] && [ "$(jq -r '.hook_gate.reason' "$(rec g3)")" = script_outdated ] && [ "$(spawns)" -eq 0 ] || { cat "$TMP/g3.log"; fail "G3: 옛 세대 가드인데 멈추지 않음(rc=$rc, $(jq -r '.hook_gate.reason' "$(rec g3)"), spawn $(spawns))"; }
  grep -q 'worker_guard.sh 가 옛 세대다' "$TMP/g3.log" || { cat "$TMP/g3.log"; fail "G3: 옛 세대 가드 안내가 없음"; }
done
# 계약 세대 줄은 선언일 뿐이다 — 줄은 맞지만 본문이 배포본과 다른 가드(아무것도 막지 않는 가드 · 모든 호출을 막는 가드)는 지문 대조로 걸러진다.
# 게이트는 그 가드를 실행하지 않는다: 실행되면 표식 파일을 남기는 가드를 놓고, 편집 호출과 단독 hooks 명령 뒤에 표식이 없는지 본다
# (신뢰가 확인되기 전에 sandbox 밖에서 작업 루트의 스크립트를 실행하던 결함의 회귀).
GUARD_MARK="$TMP/guard-was-executed.marker"
for body in "#!/bin/sh\nWORKER_GUARD_CONTRACT=3\ntouch $GUARD_MARK\nexit 0\n" "#!/bin/sh\nWORKER_GUARD_CONTRACT=3\ntouch $GUARD_MARK\ncat >/dev/null\nexit 2\n"; do
  reset_case; cp .codex/hooks/worker_guard.sh "$TMP/worker_guard.keep"; printf "$body" > .codex/hooks/worker_guard.sh; rm -f "$GUARD_MARK"
  g_call FIXER g3 > "$TMP/g3.log" 2>&1; rc=$?
  cli hooks > "$TMP/g3h.out" 2>&1; hrc=$?
  FAKE_SCENARIO=hook_untrusted cli hooks > "$TMP/g3h2.out" 2>&1
  cp "$TMP/worker_guard.keep" .codex/hooks/worker_guard.sh
  [ "$rc" -eq 10 ] && [ "$(state_of g3)" = FAILED_BEFORE_SEND ] && [ "$(code_of g3)" = CODEX_APP_SERVER_HOOK_GATE_NOT_ACTIVE ] && [ "$(jq -r '.hook_gate.reason' "$(rec g3)")" = script_unreviewed ] && [ "$(spawns)" -eq 0 ] \
    || { cat "$TMP/g3.log"; fail "G3: 세대 줄만 붙인 가드인데 멈추지 않음(rc=$rc, $(jq -r '.hook_gate.reason' "$(rec g3)"), spawn $(spawns))"; }
  grep -q 'CODEX_APP_GUARD_REVIEWED_SHA256' "$TMP/g3.log" && grep -q '현재 지문: [0-9a-f]\{64\}' "$TMP/g3.log" || { cat "$TMP/g3.log"; fail "G3: 지문 불일치 안내(현재 지문 · 등록 방법)가 없음"; }
  [ "$hrc" -ne 0 ] && grep -q '^판정: FAIL CODEX_APP_SERVER_HOOK_GATE_NOT_ACTIVE \[script_unreviewed\]' "$TMP/g3h.out" || { cat "$TMP/g3h.out"; fail "G3: hooks 명령이 검토되지 않은 가드를 통과시켰다(rc=$hrc)"; }
  [ ! -e "$GUARD_MARK" ] || fail "G3: 게이트가 작업 루트의 가드 스크립트를 실행했다(편집 호출 또는 hooks 명령) — 신뢰 확인 전에 sandbox 밖에서 실행하면 안 된다"
done
# 실제 가드의 본문에서 차단 한 줄만 무력화해도(삭제 판정을 건너뜀) 걸린다 — 지문이 달라진다
reset_case; cp .codex/hooks/worker_guard.sh "$TMP/worker_guard.keep"
sed -i.bak 's/^VERDICT=\$(printf .*$/VERDICT=$(printf "" | awk -v cwd="$CWD" '"'"'/' .codex/hooks/worker_guard.sh && rm -f .codex/hooks/worker_guard.sh.bak
cmp -s .codex/hooks/worker_guard.sh "$TMP/worker_guard.keep" && fail "G3: 사례 전제 불일치 — 가드 본문이 바뀌지 않았다"
g_call WORKER g3 > "$TMP/g3.log" 2>&1; rc=$?
cp "$TMP/worker_guard.keep" .codex/hooks/worker_guard.sh
[ "$rc" -eq 10 ] && [ "$(jq -r '.hook_gate.reason' "$(rec g3)")" = script_unreviewed ] && [ "$(spawns)" -eq 0 ] || { cat "$TMP/g3.log"; fail "G3: 삭제 판정을 건너뛰게 고친 가드가 통과됨(rc=$rc, $(jq -r '.hook_gate.reason' "$(rec g3)"))"; }
# 프로젝트에 맞게 고쳐 쓴 가드: 사용자가 그 지문을 등록하면 통과하고, 등록하지 않으면(또는 다른 지문을 등록하면) 통과하지 못한다
reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
printf '\n# project-specific rule placeholder\n' >> .codex/hooks/worker_guard.sh
custom_sha="$( source "$CFG"; sha256_stdin < .codex/hooks/worker_guard.sh )"
CODEX_APP_GUARD_REVIEWED_SHA256="0000000000000000000000000000000000000000000000000000000000000000 not-a-hash" g_call WORKER g3 > "$TMP/g3.log" 2>&1; rc=$?
[ "$rc" -eq 10 ] && [ "$(jq -r '.hook_gate.reason' "$(rec g3)")" = script_unreviewed ] || { cat "$TMP/g3.log"; cp "$TMP/worker_guard.keep" .codex/hooks/worker_guard.sh; fail "G3: 다른 지문을 등록했는데 고쳐 쓴 가드가 통과됨(rc=$rc)"; }
CODEX_APP_GUARD_REVIEWED_SHA256="$custom_sha" g_call WORKER g3 > "$TMP/g3.log" 2>&1; rc=$?
cp "$TMP/worker_guard.keep" .codex/hooks/worker_guard.sh
[ "$rc" -eq 0 ] && [ "$(turns)" -eq 1 ] && jq -e --arg h "$custom_sha" '.hook_gate.ok==true and (.required_hook.reviewed_sha256 | index($h) != null) and (.required_hook.reviewed_sha256 | length)==2' "$(rec g3)" >/dev/null \
  || { cat "$TMP/g3.log"; fail "G3: 사용자가 지문을 등록한 가드인데 실행되지 않음(rc=$rc, $(jq -c '.required_hook.reviewed_sha256' "$(rec g3)"))"; }
# 저장소가 배포하는 실제 가드의 지문은 게이트의 상수와 같다(가드를 고치고 상수를 안 고치면 새 설치의 편집 역할이 전부 멈춘다)
shipped_sha="$(grep -E '^CODEX_APP_REQUIRED_HOOK_SHA256=' .claude/skills/feature/scripts/codex-app-server.sh | cut -d'"' -f2)"
[ -n "$shipped_sha" ] && [ "$shipped_sha" = "$( source "$CFG"; sha256_stdin < "$PROJECT_SRC/.codex/hooks/worker_guard.sh" )" ] \
  || fail "G3: 배포 가드(.codex/hooks/worker_guard.sh)의 sha256 이 codex-app-server.sh 의 CODEX_APP_REQUIRED_HOOK_SHA256($shipped_sha)과 다르다 — 가드를 고쳤으면 상수도 고친다"
# 런타임에 가드를 실행하는 코드가 다시 들어오지 않았다(자식 프로세스는 codex app-server 하나뿐이다)
! grep -q 'spawnSync\|execSync\|execFileSync' .claude/skills/feature/scripts/codex-app-server.mjs || fail "G3: 런타임에 동기 자식 프로세스 실행이 있다 — 게이트는 가드 스크립트를 실행하지 않는다"
# 저장소가 배포하는 실제 가드는 요구 세대를 선언한다(게이트의 상수와 가드 파일이 어긋나지 않는다)
grep -qx "$(grep -E '^CODEX_APP_REQUIRED_HOOK_CONTRACT=' .claude/skills/feature/scripts/codex-app-server.sh | cut -d'"' -f2)" "$PROJECT_SRC/.codex/hooks/worker_guard.sh" || fail "G3: 배포 가드(.codex/hooks/worker_guard.sh)가 게이트가 요구하는 계약 세대 줄을 선언하지 않는다"
# 설치된 codex 에 hooks/list 가 없다 — 확인할 수단이 없으면 편집 역할은 실행하지 않고, 읽기 전용 역할은 그대로 돈다
reset_case; rm -f "$PREFLIGHT_CACHE"
FAKE_SCHEMA_DROP=hooks/list g_call DESIGNER g3 > "$TMP/g3.log" 2>&1; rc=$?
[ "$rc" -eq 10 ] && [ "$(state_of g3)" = FAILED_BEFORE_SEND ] && [ "$(code_of g3)" = CODEX_APP_SERVER_HOOK_GATE_UNVERIFIABLE ] && [ "$(spawns)" -eq 0 ] || { cat "$TMP/g3.log"; fail "G3: hooks/list 없는 codex 에서 편집 역할이 멈추지 않음(rc=$rc, $(code_of g3), spawn $(spawns))"; }
FAKE_SCHEMA_DROP=hooks/list ro_call g3ro "$TMP/side/g3ro.json" > "$TMP/g3.log" 2>&1 || { cat "$TMP/g3.log"; fail "G3: hooks/list 가 없다는 이유로 읽기 전용 역할까지 막혔다"; }
rm -f "$PREFLIGHT_CACHE"
# 기록에 사양이 없다(사양을 만들지 못한 Shell) — 건너뛰지 않고 멈춘다
reset_case
( source "$CFG"; codex_app_required_hook_json() { return 1; }; run_edit_role WORKER g3 smoke-g3 "$TMP/side/g3.log" prompt "" "$WORKER_SCHEMA_FILE" "$TMP/side/g3-result.json" ) > "$TMP/g3.log" 2>&1; rc=$?
[ "$rc" -eq 10 ] && [ "$(state_of g3)" = FAILED_BEFORE_SEND ] && [ "$(jq -r '.hook_gate.reason' "$(rec g3)")" = spec_missing ] && [ "$(spawns)" -eq 0 ] || { cat "$TMP/g3.log"; fail "G3: 사양 없는 기록이 게이트를 건너뛰었다(rc=$rc, spawn $(spawns))"; }
# 게이트 없는 런타임과 섞인 설치 — 기록도 서버도 만들지 않는다
reset_case; RT=".claude/skills/feature/scripts/codex-app-server.mjs"; cp "$RT" "$TMP/runtime.keep"
sed -i.bak "s/^const HOOK_GATE_VERSION = '3';/const HOOK_GATE_VERSION = '2';/" "$RT" && rm -f "$RT.bak"
g_call WORKER g3 > "$TMP/g3.log" 2>&1; g3rc=$?
ro_call g3ro2 "$TMP/side/g3ro2.json" > "$TMP/g3b.log" 2>&1; rorc=$?
cp "$TMP/runtime.keep" "$RT"
[ "$g3rc" -ne 0 ] || fail "G3: 게이트 세대가 다른 런타임으로 편집 역할이 실행됨"
expect_fail G3 "$TMP/g3.log" CODEX_APP_SERVER_HOOK_GATE_UNVERIFIABLE '혼합 설치'
[ ! -f "$(rec g3)" ] && [ "$rorc" -eq 0 ] || fail "G3: 혼합 설치에서 편집 기록이 생겼거나 읽기 전용 역할까지 막혔다(ro rc=$rorc)"
pass "G3: thread 기준 미신뢰는 thread 뒤·turn 전에 중단, 스크립트 없음·옛 세대 가드·검토되지 않은 지문·hooks/list 없음·사양 없음은 서버 미기동(가드 스크립트 실행 0회), 등록한 지문의 가드는 통과, 게이트 없는 런타임은 호출 전 거부"

# ===== G4: linked worktree — codex 는 훅 정의를 원본 저장소의 hooks.json 으로 돌려준다(그 경로는 허용), 무관한 hooks.json 은 불일치다 =====
reset_case
git worktree add -q "$TMP/wt-g4" -b smoke-wt-g4 >/dev/null 2>&1 || fail "G4: git worktree 생성 실패"
WTG="$(cd "$TMP/wt-g4" && pwd)"
mkdir -p "$WTG/.claude/hooks" "$WTG/.agent-work" "$WTG/.codex/hooks" && cp .claude/hooks/core_rules.md "$WTG/.claude/hooks/" && cp .codex/hooks.json "$WTG/.codex/" && cp .codex/hooks/worker_guard.sh "$WTG/.codex/hooks/"
wt_call() { ( cd "$WTG" && FEATURE_PROJECT_ROOT="$WTG" && export FEATURE_PROJECT_ROOT && source "$CFG" && run_edit_role WORKER "$1" "smoke-$1" "$TMP/side/$1.log" prompt "" "$ROOT/$WORKER_SCHEMA_FILE" "$TMP/side/$1-result.json" ); }
printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
FAKE_HOOK_SOURCE="$ROOT/.codex/hooks.json" wt_call g4 > "$TMP/g4.log" 2>&1 || { cat "$TMP/g4.log"; fail "G4: 원본 저장소의 hooks.json 에서 온 신뢰된 훅인데 worktree 의 워커가 막혔다"; }
jq -e '.hook_gate.ok==true and (.required_hook.source_paths | length)==2' "$WTG/.agent-work/.session-g4.codex-turn.json" >/dev/null || fail "G4: worktree 의 사양에 원본 저장소 경로가 없음: $(jq -c '.required_hook' "$WTG/.agent-work/.session-g4.codex-turn.json")"
mkdir -p "$TMP/elsewhere/.codex" && cp .codex/hooks.json "$TMP/elsewhere/.codex/"
FAKE_HOOK_SOURCE="$TMP/elsewhere/.codex/hooks.json" wt_call g4b > "$TMP/g4.log" 2>&1; rc=$?
[ "$rc" -eq 10 ] && [ "$(jq -r '.hook_gate.reason' "$WTG/.agent-work/.session-g4b.codex-turn.json")" = source_mismatch ] || { cat "$TMP/g4.log"; fail "G4: 무관한 hooks.json 의 훅이 통과됨(rc=$rc)"; }
git worktree remove --force "$TMP/wt-g4" >/dev/null 2>&1; git branch -q -D smoke-wt-g4 >/dev/null 2>&1
pass "G4: linked worktree 는 원본 저장소의 hooks.json 을 출처로 허용, 무관한 경로는 source_mismatch"

# ===== G5: 단독 판정 명령(hooks) — thread·turn 없이 판정만 하고 종료 코드로 알린다 =====
reset_case
cli hooks > "$TMP/g5.out" 2>&1 || { cat "$TMP/g5.out"; fail "G5: 건강한 훅에서 hooks 명령이 실패"; }
grep -q '^판정: PASS' "$TMP/g5.out" && grep -q 'trustStatus=trusted' "$TMP/g5.out" || { cat "$TMP/g5.out"; fail "G5: PASS 출력 불일치"; }
FAKE_SCENARIO=hook_untrusted cli hooks > "$TMP/g5.out" 2>&1 && fail "G5: 미신뢰 훅인데 hooks 명령이 성공(exit 0)"
grep -q '^판정: FAIL CODEX_APP_SERVER_HOOK_GATE_NOT_ACTIVE \[untrusted\]' "$TMP/g5.out" || { cat "$TMP/g5.out"; fail "G5: FAIL 출력 불일치"; }
FAKE_SCENARIO=hook_missing cli hooks > "$TMP/g5.out" 2>&1 && fail "G5: 훅이 없는데 hooks 명령이 성공"
[ "$(turns)" -eq 0 ] && [ "$(grep -c '^rpc thread/' "$FAKE_LOG")" -eq 0 ] && [ "$(grep -c '^rpc hooks/list thread=- ' "$FAKE_LOG")" -eq 3 ] || fail "G5: 판정 명령이 thread·turn 을 만들었다"
pass "G5: hooks 명령은 hooks/list(cwd 기준)만 보내고 PASS/FAIL 을 종료 코드와 함께 출력"

# ===== G5b: 프로젝트 명령이 아직 CHANGE_ME 인 config.sh(설치 직후) — 조회 전용 단독 명령만 가드를 지난다 =====
reset_case
cp "$CFG" "$TMP/cfg-g5b.keep"
sed -i.bak 's|^TEST_CMD=.*|TEST_CMD="CHANGE_ME"|; s|^LINT_CMD=.*|LINT_CMD="CHANGE_ME"|' "$CFG"
cli hooks > "$TMP/g5b.out" 2>&1 || { cat "$TMP/g5b.out"; fail "G5b: TEST_CMD/LINT_CMD 가 CHANGE_ME 인 config 에서 hooks 명령이 막혔다"; }
grep -q '^판정: PASS' "$TMP/g5b.out" || { cat "$TMP/g5b.out"; fail "G5b: hooks 판정 출력 없음"; }
cli status > "$TMP/g5b.out" 2>&1 || { cat "$TMP/g5b.out"; fail "G5b: status 명령이 막혔다"; }
cli preflight > "$TMP/g5b.out" 2>&1 || { cat "$TMP/g5b.out"; fail "G5b: preflight 명령이 막혔다"; }
for verb in reconcile discard; do
  cli "$verb" g5b > "$TMP/g5b.out" 2>&1 && fail "G5b: 호출 기록을 바꾸는 $verb 가 CHANGE_ME config 에서 실행됐다"
  grep -q 'CHANGE_ME 항목을 먼저' "$TMP/g5b.out" || { cat "$TMP/g5b.out"; fail "G5b: $verb 가 가드가 아닌 다른 이유로 멈췄다"; }
done
# 표식을 환경으로 넘겨도(부모 pid 든 임의 값이든) 하위 루프·config.sh 를 source 하는 다른 프로세스는 예외를 얻지 못한다
for leaked in "$$" 1; do
  FEATURE_CONFIG_QUERY_ONLY_PID="$leaked" bash "$REVIEW_LOOP" > "$TMP/g5b.out" 2>&1 && fail "G5b: 환경의 표식($leaked)으로 리뷰 루프가 가드를 지났다"
  grep -q 'CHANGE_ME 항목을 먼저' "$TMP/g5b.out" || { cat "$TMP/g5b.out"; fail "G5b: 리뷰 루프가 가드가 아닌 다른 이유로 멈췄다(표식 $leaked)"; }
  FEATURE_CONFIG_QUERY_ONLY_PID="$leaked" bash -c 'source "$1"' _ "$CFG" > "$TMP/g5b.out" 2>&1 && fail "G5b: 환경의 표식($leaked)으로 config.sh source 가 가드를 지났다"
done
# 표식을 자기 pid 로 심어도(BASH_ENV — bash 가 스크립트를 시작할 때 읽는 파일) 실행 중인 스크립트가 조회 명령이 아니면 예외를 얻지 못한다
printf 'FEATURE_CONFIG_QUERY_ONLY_PID=$$\n' > "$TMP/g5b-bashenv.sh"
BASH_ENV="$TMP/g5b-bashenv.sh" bash -c '[ "$FEATURE_CONFIG_QUERY_ONLY_PID" = "$$" ]' || fail "G5b: BASH_ENV 사례가 표식을 심지 못했다(사례가 아무것도 검증하지 않는다)"
for target in "$REVIEW_LOOP" ".claude/skills/feature/scripts/consensus-loop.sh" ".claude/skills/feature/scripts/feature-run.sh"; do
  BASH_ENV="$TMP/g5b-bashenv.sh" bash "$target" > "$TMP/g5b.out" 2>&1 && fail "G5b: BASH_ENV 로 심은 표식으로 $target 가 가드를 지났다"
  grep -q 'CHANGE_ME 항목을 먼저' "$TMP/g5b.out" || { cat "$TMP/g5b.out"; fail "G5b: $target 가 가드가 아닌 다른 이유로 멈췄다(BASH_ENV)"; }
done
BASH_ENV="$TMP/g5b-bashenv.sh" bash -c 'source "$1"' _ "$CFG" > "$TMP/g5b.out" 2>&1 && fail "G5b: BASH_ENV 로 심은 표식으로 config.sh source 가 가드를 지났다"
for verb in reconcile discard; do
  BASH_ENV="$TMP/g5b-bashenv.sh" bash "$ROOT/.claude/skills/feature/scripts/codex-app-server.sh" "$verb" g5b > "$TMP/g5b.out" 2>&1 && fail "G5b: BASH_ENV 로 심은 표식으로 $verb 가 실행됐다"
  grep -q 'CHANGE_ME 항목을 먼저' "$TMP/g5b.out" || { cat "$TMP/g5b.out"; fail "G5b: $verb 가 가드가 아닌 다른 이유로 멈췄다(BASH_ENV)"; }
done
# 조회 명령은 절대 경로·심볼릭 링크·하위 디렉터리에서의 상대 경로로 불러도 예외를 얻는다(실행 경로를 절대 경로로 고정한 뒤 판정한다)
ln -s "$ROOT/.claude/skills/feature/scripts/codex-app-server.sh" "$TMP/g5b-link" || fail "G5b: 심볼릭 링크 생성 실패"
bash "$ROOT/.claude/skills/feature/scripts/codex-app-server.sh" hooks > "$TMP/g5b.out" 2>&1 && grep -q '^판정: PASS' "$TMP/g5b.out" || { cat "$TMP/g5b.out"; fail "G5b: 절대 경로 hooks 가 막혔다"; }
bash "$TMP/g5b-link" hooks > "$TMP/g5b.out" 2>&1 && grep -q '^판정: PASS' "$TMP/g5b.out" || { cat "$TMP/g5b.out"; fail "G5b: 심볼릭 링크 hooks 가 막혔다"; }
( cd src && bash ../.claude/skills/feature/scripts/codex-app-server.sh hooks ) > "$TMP/g5b.out" 2>&1 && grep -q '^판정: PASS' "$TMP/g5b.out" || { cat "$TMP/g5b.out"; fail "G5b: 하위 디렉터리의 상대 경로 hooks 가 막혔다"; }
# 모델 자리의 CHANGE_ME 는 조회 명령에서도 거부한다(예외는 프로젝트 명령 두 값뿐이다)
cp "$TMP/cfg-g5b.keep" "$CFG"
sed -i.bak 's|^WORKER_MODEL=.*|WORKER_MODEL="CHANGE_ME"|' "$CFG"
cli hooks > "$TMP/g5b.out" 2>&1 && fail "G5b: WORKER_MODEL 이 CHANGE_ME 인데 hooks 명령이 실행됐다"
grep -q 'CHANGE_ME 항목을 먼저' "$TMP/g5b.out" || { cat "$TMP/g5b.out"; fail "G5b: 모델 CHANGE_ME 가 가드가 아닌 다른 이유로 멈췄다"; }
cp "$TMP/cfg-g5b.keep" "$CFG"
[ "$(turns)" -eq 0 ] && [ "$(grep -c '^rpc thread/' "$FAKE_LOG")" -eq 0 ] || fail "G5b: 조회 명령이 thread·turn 을 만들었다"
pass "G5b: TEST_CMD/LINT_CMD 가 CHANGE_ME 여도 status·preflight·hooks 는 실행, reconcile·discard·하위 루프·모델 CHANGE_ME 는 종전대로 거부(환경·BASH_ENV 로 심은 표식 무효 — 실행 스크립트가 조회 명령일 때만)"

# ===== G6: 리뷰 루프·합의 루프 — 훅이 신뢰되지 않으면 Codex 수정자·디자이너는 0회 실행되고 다음 리뷰어·검증자로 넘어가지 않는다 =====
review_fixture
FAKE_SCENARIO=hook_untrusted bash "$REVIEW_LOOP" > "$TMP/g6.log" 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'CODEX_APP_SERVER_HOOK_GATE_NOT_ACTIVE' "$TMP/g6.log" && [ "$(turns)" -eq 1 ] && ! grep -q 'fixed' src/u01.txt \
  || { tail -30 "$TMP/g6.log"; fail "G6: 미신뢰 훅에서 수정자가 실행됐거나 리뷰어 Round 2 로 넘어갔다(rc=$rc, turn $(turns))"; }
[ "$(state_of fixer-a01)" = FAILED_BEFORE_SEND ] && [ ! -f .agent-work/.session-fixer-a01.codex.json ] && [ "$(jq -r .next_step .agent-work/review-impl.json)" != APPROVE ] || fail "G6: 수정자 기록·세션·체크포인트 불일치($(state_of fixer-a01), $(jq -r .next_step .agent-work/review-impl.json))"
bash "$REVIEW_LOOP" > "$TMP/g6.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(turns)" -eq 3 ] && jq -e '.next_step=="APPROVE" and .round==2' .agent-work/review-impl.json >/dev/null || { tail -30 "$TMP/g6.log"; fail "G6: 훅이 신뢰된 뒤의 재실행이 수정자 → 리뷰어 Round 2 로 끝나지 않음(rc=$rc, turn $(turns))"; }
git checkout -q -- src/u01.txt
reset_case
sed -i.bak 's/^VALIDATOR_PROFILE=.*/VALIDATOR_PROFILE="none"/' "$CFG" && rm -f "$CFG.bak"
rm -f .agent-work/consensus-design.json .agent-work/reviews/validator-design-*
printf '{"schema_version":%s,"verdict":"BLOCK","blocking_issues":[{"id":"B-01","action":"REVISE_DOC","category":"CONTRACT_GAP","change_relation":"NEW","evidence_type":"DIRECT_MISMATCH","basis_refs":["design.md:L1"],"conflict_refs":["design.md:L1"],"code_refs":[],"reachable_scenario":"","impact":"x","why_blocks_now":"y","minimum_contract_needed":"z","user_question":"","options":[],"origin":"ROUND_1","previous_issue_id":"","revision_ref":""}]}\n' "$VALIDATOR_CONTRACT" > "$FAKE_STATE/reply-1.txt"
printf '%s\n' 'echo "revised by designer" >> .agent-work/design.md' > "$FAKE_STATE/edit-2.sh"
FAKE_SCENARIO=hook_untrusted bash .claude/skills/feature/scripts/consensus-loop.sh design > "$TMP/g6.log" 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'CODEX_APP_SERVER_HOOK_GATE_NOT_ACTIVE' "$TMP/g6.log" && [ "$(turns)" -eq 1 ] && ! grep -q 'revised by designer' .agent-work/design.md \
  || { tail -30 "$TMP/g6.log"; fail "G6: 미신뢰 훅에서 디자이너가 실행됐거나 검증자가 다시 불렸다(rc=$rc, turn $(turns))"; }
[ "$(state_of designer-design)" = FAILED_BEFORE_SEND ] && [ ! -f .agent-work/.session-designer-design.codex.json ] || fail "G6: 디자이너 기록·세션 불일치($(state_of designer-design))"
cp "$TMP/g-config.keep" "$CFG"
printf '# design\n' > .agent-work/design.md; : > .agent-work/decisions.md
rm -f .agent-work/consensus-design.json
pass "G6: 미신뢰 훅 → Codex 수정자·디자이너 0회(FAILED_BEFORE_SEND), 리뷰어 Round 2·검증자 재호출 없음, 신뢰된 뒤 재실행은 정상 진행"

# ===== G7: turn 이 가드 스크립트·훅 정의를 바꾸면 그 결과를 쓰지 않고, 다음 리뷰어 전달·세션 확정도 막는다(사후 탐지) =====
cp .codex/hooks/worker_guard.sh "$TMP/worker_guard.keep"; cp .codex/hooks.json "$TMP/hooks.json.keep"
for target in .codex/hooks/worker_guard.sh .codex/hooks.json; do
  reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
  FAKE_APP_EDIT_CMD="echo ' ' >> $target" edit_call WORKER g7 "$TMP/side/g7.log" "$WORKER_SCHEMA_FILE" "$TMP/side/g7-result.json" > "$TMP/g7.log" 2>&1; rc=$?
  cp "$TMP/worker_guard.keep" .codex/hooks/worker_guard.sh; cp "$TMP/hooks.json.keep" .codex/hooks.json
  [ "$rc" -eq 20 ] && [ "$(state_of g7)" = REJECTED ] && [ "$(code_of g7)" = CODEX_APP_SERVER_HOOK_FILES_CHANGED ] && [ ! -f "$TMP/side/g7-result.json" ] \
    || { cat "$TMP/g7.log"; fail "G7($target): turn 이 가드 파일을 바꿨는데 결과가 쓰였다(rc=$rc, $(state_of g7) $(code_of g7))"; }
  # 훅 정의는 작업 루트 표기와 원본 저장소(물리 경로) 표기로 두 번 잡힐 수 있다 — 바뀐 것이 그 파일뿐인지만 본다
  jq -e --arg t "/$target" '(.hook_files.changed | length) >= 1 and all(.hook_files.changed[]; endswith($t))' "$(rec g7)" >/dev/null || fail "G7($target): 바뀐 파일 기록 불일치: $(jq -c '.hook_files.changed' "$(rec g7)")"
  ( source "$CFG"; codex_app_stop_if_uncertain g7 "smoke" ) > "$TMP/g7.log" 2>&1 && fail "G7($target): 가드가 바뀐 호출인데 다음 단계로 가는 판정이 통과됨"
  expect_fail "G7($target)" "$TMP/g7.log" CODEX_APP_SERVER_HOOK_FILES_CHANGED "discard g7"
  accept WORKER g7 > "$TMP/g7.log" 2>&1 && fail "G7($target): 가드가 바뀐 호출의 세션 수용이 성공했다"
  expect_fail "G7($target)" "$TMP/g7.log" CODEX_APP_SERVER_HOOK_FILES_CHANGED
  [ ! -f .agent-work/.session-g7.codex.json ] || fail "G7($target): 거부된 수용이 원장을 확정했다"
  # 같은 key 의 재실행(워커는 루프의 중단 판정을 거치지 않는다): 가드를 되돌려 놓았어도 새 turn 을 보내지 않고 기록도 보관하지 않는다
  cp "$(rec g7)" "$TMP/g7-record.keep"; g7_turns="$(turns)"
  edit_call WORKER g7 "$TMP/side/g7.log" "$WORKER_SCHEMA_FILE" "$TMP/side/g7-result.json" > "$TMP/g7.log" 2>&1 && fail "G7($target): 가드가 바뀐 호출 위에서 재실행이 진행됨"
  expect_fail "G7($target)" "$TMP/g7.log" CODEX_APP_SERVER_HOOK_FILES_CHANGED "discard g7"
  [ "$(turns)" -eq "$g7_turns" ] && cmp -s "$(rec g7)" "$TMP/g7-record.keep" && [ ! -d .agent-work/codex-app-server/g7 ] || fail "G7($target): 재실행이 turn 을 보냈거나 기록을 바꿨다(turn $(turns))"
  # 사용자가 확인하고 discard 한 뒤에만 새 turn
  cli discard g7 > "$TMP/g7.log" 2>&1 || { cat "$TMP/g7.log"; fail "G7($target): discard 실패"; }
  edit_call WORKER g7 "$TMP/side/g7.log" "$WORKER_SCHEMA_FILE" "$TMP/side/g7-result.json" > "$TMP/g7.log" 2>&1 || { cat "$TMP/g7.log"; fail "G7($target): discard 뒤 재실행 실패"; }
  [ "$(turns)" -eq $((g7_turns + 1)) ] || fail "G7($target): discard 뒤 새 turn 이 1회가 아님"
done
# 가드 파일을 건드리지 않은 turn 은 기록에 '바뀐 파일 없음'만 남고 그대로 수용된다
reset_case; printf '%s' "$WORKER_DONE" > "$FAKE_STATE/reply-default.txt"
edit_call WORKER g7 "$TMP/side/g7.log" "$WORKER_SCHEMA_FILE" "$TMP/side/g7-result.json" > "$TMP/g7.log" 2>&1 && accept WORKER g7 || { cat "$TMP/g7.log"; fail "G7: 가드를 건드리지 않은 호출이 막힘"; }
jq -e '.hook_files.changed == [] and (.hook_files.before | length) >= 2' "$(rec g7)" >/dev/null || fail "G7: 호출 전후 지문 기록 없음: $(jq -c '.hook_files' "$(rec g7)")"
# 리뷰 루프: Codex 수정자가 범위 안 변경과 함께 가드를 바꿨다 — 리뷰어 Round 2 로 넘기지 않는다(재실행도 모델 0회)
sed -i.bak 's/^FIXER_CLI=.*/FIXER_CLI="codex"/; s/^FIXER_MODEL=.*/FIXER_MODEL="gpt-6-sol"/' "$CFG" && rm -f "$CFG.bak"
review_fixture
printf '%s\n' "echo ' ' >> .codex/hooks/worker_guard.sh" >> "$FAKE_STATE/edit-2.sh"
bash "$REVIEW_LOOP" > "$TMP/g7.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q 'CODEX_APP_SERVER_HOOK_FILES_CHANGED' "$TMP/g7.log" && grep -q 'fixed' src/u01.txt && [ "$(turns)" -eq 2 ] && [ "$(jq -r .next_step .agent-work/review-impl.json)" = FIXER_PENDING ] \
  || { tail -30 "$TMP/g7.log"; fail "G7: 가드를 바꾼 수정자의 변경이 리뷰어에게 넘어갔다(rc=$rc, turn $(turns), $(jq -r .next_step .agent-work/review-impl.json))"; }
! grep -q 'FORWARD_TO_REVIEWER' .agent-work/cli-anomalies.jsonl 2>/dev/null && [ ! -f .agent-work/.session-fixer-a01.codex.json ] || fail "G7: 리뷰어 전달 기록 또는 수정자 세션 확정이 생김"
cp "$TMP/worker_guard.keep" .codex/hooks/worker_guard.sh
g7_spawns="$(spawns)"
bash "$REVIEW_LOOP" > "$TMP/g7.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q 'CODEX_APP_SERVER_HOOK_FILES_CHANGED' "$TMP/g7.log" && [ "$(turns)" -eq 2 ] && [ "$(spawns)" -eq "$g7_spawns" ] || { tail -30 "$TMP/g7.log"; fail "G7: 가드를 되돌린 것만으로 재실행이 진행됨(rc=$rc, turn $(turns))"; }
cp "$TMP/g-config.keep" "$CFG"
git checkout -q -- src/u01.txt
pass "G7: turn 전후 가드·훅 정의 지문 대조 — 바뀌면 REJECTED(CODEX_APP_SERVER_HOOK_FILES_CHANGED), 세션 수용 거부, 리뷰 루프는 리뷰어 0회·FIXER_PENDING 유지(재실행도 모델 0회)"

# ===== X1: 단독 명령은 상대·절대·심볼릭 링크 경로 어느 것으로 불러도 끝난다(절대 경로의 config.sh 재진입 순환 회귀) =====
with_timeout() { # 초 명령... — 제한 시간을 넘기면 강제 종료하고 137 을 돌려준다(macOS 에는 timeout 이 없다)
  local secs="$1" pid watcher rc; shift
  "$@" & pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 & watcher=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  return "$rc"
}
reset_case
CAS_REL=".claude/skills/feature/scripts/codex-app-server.sh"; CAS_ABS="$ROOT/$CAS_REL"; CAS_LINK="$TMP/cas-link.sh"
ln -s "$CAS_ABS" "$CAS_LINK" || fail "X1: 심볼릭 링크 생성 실패"
for form in rel abs link; do
  case "$form" in rel) cas="$CAS_REL";; abs) cas="$CAS_ABS";; link) cas="$CAS_LINK";; esac
  key="x1-$form"
  FAKE_SCENARIO=crash_before_turn_response ro_call "$key" "$TMP/side/$key.json" >/dev/null 2>&1 && fail "X1($form): 준비 실패"
  with_timeout 30 bash "$cas" status "$key" > "$TMP/x1.out" 2> "$TMP/x1.err"; rc=$?
  [ "$rc" -eq 0 ] && grep -q "^$key  state=UNKNOWN" "$TMP/x1.out" || { cat "$TMP/x1.err"; fail "X1($form): status 가 끝나지 않거나 기록을 보여 주지 않음(rc=$rc — 137 이면 제한 시간 초과)"; }
  with_timeout 30 bash "$cas" preflight > "$TMP/x1.out" 2> "$TMP/x1.err"; rc=$?
  [ "$rc" -eq 0 ] && jq -e '.ok==true' "$TMP/x1.out" >/dev/null || { cat "$TMP/x1.err"; fail "X1($form): preflight 가 끝나지 않음(rc=$rc)"; }
  with_timeout 30 bash "$cas" reconcile "$key" > "$TMP/x1.out" 2> "$TMP/x1.err"; rc=$?
  [ "$rc" -eq 0 ] && [ "$(jq -r .verdict "$TMP/x1.out")" = RECOVERED ] || { cat "$TMP/x1.err"; fail "X1($form): reconcile 이 끝나지 않거나 복구하지 못함(rc=$rc)"; }
  with_timeout 30 bash "$cas" discard "$key" > "$TMP/x1.out" 2> "$TMP/x1.err"; rc=$?
  [ "$rc" -eq 0 ] && [ ! -f "$(rec "$key")" ] && ls ".agent-work/codex-app-server/$key/"*.json >/dev/null 2>&1 || { cat "$TMP/x1.err"; fail "X1($form): discard 가 끝나지 않거나 기록을 보관하지 않음(rc=$rc)"; }
  with_timeout 30 bash "$cas" > "$TMP/x1.out" 2> "$TMP/x1.err"; rc=$?
  [ "$rc" -eq 2 ] && grep -q '사용:' "$TMP/x1.err" || fail "X1($form): 인자 없는 실행이 사용법(exit 2)으로 끝나지 않음(rc=$rc)"
done
[ "$(turns)" -eq 3 ] || fail "X1: 단독 명령이 새 turn 을 보냈다(turn $(turns))"
# 중단 메시지가 안내하는 복구 명령을 그대로(다른 디렉터리에서) 실행해도 끝나고, 같은 프로젝트의 기록을 본다
FAKE_SCENARIO=crash_before_turn_response ro_call x1-hint "$TMP/side/x1-hint.json" >/dev/null 2>&1 && fail "X1: 안내 명령 준비 실패"
ro_call x1-hint "$TMP/side/x1-hint.json" > "$TMP/x1.log" 2>&1 && fail "X1: 불명 상태 재실행이 진행됨"
hint="$(grep -o 'cd .* status x1-hint' "$TMP/x1.log" | head -1)"
[ -n "$hint" ] || { cat "$TMP/x1.log"; fail "X1: 중단 메시지에 'cd <루트> && bash <절대 경로> status <key>' 안내가 없음"; }
( cd / && with_timeout 30 bash -c "$hint" ) > "$TMP/x1.out" 2> "$TMP/x1.err"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^x1-hint  state=UNKNOWN' "$TMP/x1.out" || { cat "$TMP/x1.err"; fail "X1: 안내된 복구 명령이 끝나지 않거나 기록을 찾지 못함(rc=$rc): $hint"; }
pass "X1: status·preflight·reconcile·discard × 상대·절대·심볼릭 링크 경로 모두 제한 시간 안에 종료, 안내된 복구 명령(cd + 절대 경로)도 그대로 동작"

# ===== X2: 단독 명령의 프로젝트 루트 — 현재 worktree 의 기록만 본다(설치 저장소의 기록으로 넘어가지 않는다) =====
reset_case
git worktree add -q "$TMP/wt2" -b smoke-wt2 >/dev/null 2>&1 || fail "X2: git worktree 생성 실패"
WT2="$(cd "$TMP/wt2" && pwd)"
mkdir -p "$WT2/.claude/hooks" "$WT2/.agent-work" && cp .claude/hooks/core_rules.md "$WT2/.claude/hooks/"
( cd "$WT2" && set -e && FEATURE_PROJECT_ROOT="$WT2" && export FEATURE_PROJECT_ROOT && source "$CFG" && FAKE_SCENARIO=crash_before_turn_response run_readonly_json_role REVIEWER x2 smoke-x2 "$ROOT/$SCHEMA" "$TMP/side/x2.json" prompt "" ) >/dev/null 2>&1 && fail "X2: 준비 실패"
[ "$(jq -r .state "$WT2/.agent-work/.session-x2.codex-turn.json")" = UNKNOWN ] && [ ! -f "$(rec x2)" ] || fail "X2: 준비 상태 불일치"
( cd "$WT2" && with_timeout 30 bash "$CAS_ABS" status x2 ) > "$TMP/x2.out" 2> "$TMP/x2.err"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^x2  state=UNKNOWN' "$TMP/x2.out" && grep -q "record=.agent-work/.session-x2.codex-turn.json" "$TMP/x2.out" || { cat "$TMP/x2.err" "$TMP/x2.out"; fail "X2: worktree 에서 실행한 status 가 그 worktree 의 기록을 보지 않음(rc=$rc)"; }
with_timeout 30 bash "$CAS_ABS" status x2 > "$TMP/x2.out" 2>&1
grep -q '호출 기록 없음' "$TMP/x2.out" || fail "X2: 설치 저장소에서 실행한 status 가 다른 worktree 의 기록을 보여 줬다"
( cd "$TMP/side" && with_timeout 30 bash "$CAS_ABS" status x2 ) > "$TMP/x2.out" 2>&1 && fail "X2: git 밖에서 실행했는데 설치 저장소의 기록으로 넘어갔다"
grep -q 'git working tree 안이 아니다' "$TMP/x2.out" || { cat "$TMP/x2.out"; fail "X2: git 밖 실행의 거부 사유가 없음"; }
mkdir -p "$TMP/other-repo" && git -C "$TMP/other-repo" init -q
( cd "$TMP/other-repo" && with_timeout 30 bash "$CAS_ABS" discard x2 ) > "$TMP/x2.out" 2>&1 && fail "X2: 무관한 저장소에서 discard 가 실행됨"
grep -q 'worktree 가 아니다' "$TMP/x2.out" && [ ! -d "$TMP/other-repo/.agent-work" ] || { cat "$TMP/x2.out"; fail "X2: 무관한 저장소 거부 사유가 없거나 그 저장소에 .agent-work 를 만들었다"; }
( cd "$TMP/side" && FEATURE_PROJECT_ROOT="$WT2" with_timeout 30 bash "$CAS_ABS" status x2 ) > "$TMP/x2.out" 2>&1 && grep -q '^x2  state=UNKNOWN' "$TMP/x2.out" || { cat "$TMP/x2.out"; fail "X2: FEATURE_PROJECT_ROOT 명시가 통하지 않음"; }
# 다른 루트의 기록이 이 루트에 놓여 있어도(복사·이동) 그 기록의 경로는 원래 루트 기준이다 — reconcile·discard 를 하지 않는다
cp "$WT2/.agent-work/.session-x2.codex-turn.json" "$(rec x2)"
for verb in reconcile discard; do
  with_timeout 30 bash "$CAS_ABS" "$verb" x2 > "$TMP/x2.out" 2>&1 && fail "X2: 다른 루트의 기록을 $verb 했다"
  grep -q 'project_root' "$TMP/x2.out" && [ "$(state_of x2)" = UNKNOWN ] || { cat "$TMP/x2.out"; fail "X2($verb): 루트 불일치 거부·기록 보존이 아님"; }
done
rm -f "$(rec x2)"
( cd "$WT2" && with_timeout 30 bash "$CAS_ABS" reconcile x2 ) > "$TMP/x2.out" 2> "$TMP/x2.err"; rc=$?
[ "$rc" -eq 0 ] && [ "$(jq -r .verdict "$TMP/x2.out")" = RECOVERED ] && [ "$(jq -r .state "$WT2/.agent-work/.session-x2.codex-turn.json")" = RESULT_READY ] && [ ! -f "$(rec x2)" ] \
  || { cat "$TMP/x2.err" "$TMP/x2.out"; fail "X2: worktree 에서 실행한 reconcile 이 그 worktree 의 기록을 복구하지 않음(rc=$rc)"; }
git worktree remove --force "$TMP/wt2" >/dev/null 2>&1; git branch -q -D smoke-wt2 >/dev/null 2>&1
pass "X2: 단독 명령은 현재 worktree(또는 FEATURE_PROJECT_ROOT)의 기록만 다룬다 — git 밖·무관한 저장소·다른 루트의 기록은 거부"

# ===== 종합: 이 스모크 전체에서 codex exec 는 한 번도 불리지 않았다(각 사례가 초기화하므로 사례별로 이미 확인) =====
rm -rf "$TMP"
echo "[SMOKE DONE] Codex App Server backend 스모크 통과"
