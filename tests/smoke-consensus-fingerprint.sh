#!/usr/bin/env bash
# =============================================================
# 스모크: 사용자 결정([USER-QUESTION][scope=…])의 의존성 범위 분리 — 실제 LLM 호출 없음 (mock claude / fake codex), 임시 저장소
# 파일 경로: tests/smoke-consensus-fingerprint.sh
# 사용법: bash tests/smoke-consensus-fingerprint.sh   (어디서든 실행 가능)
#
# 불변식: design ← scope=design / impl ← scope=design + scope=impl. downstream 은 upstream 결정을 상속하지만 upstream 은 downstream 결정을 보지 않는다.
# 사례:
#   A. impl 결정(scope=impl)은 design PASS 를 깨지 않고 impl PASS 만 깬다
#   B. design 결정(scope=design)은 design·impl PASS 를 모두 깬다
#   C. 일반 decision audit line([round N] … REJECT)은 어느 PASS 지문도 바꾸지 않는다
#   D. stage=worker 에서 scope=impl 결정 추가 후 러너 재실행 → design 으로 내려가지 않고 impl 로만 내려간다 (design 검증자 호출 0회, impl 검증자 1회)
#   E. design.md 변경은 impl 결정 여부와 무관하게 design PASS 를 깬다
#   F. scope 없는 옛 형식 [USER-QUESTION] 이 있으면 LLM 호출 0회로 DECISION_SCOPE_REQUIRED (러너·합의 루프 단독 모두)
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-fp-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

# --- 임시 저장소: 스킬 복사 + CHANGE_ME 채움 ---
mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"true\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"true\"|" "$CFG" && rm -f "$CFG.bak"
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && echo "base" > src/u01.txt
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
LOOP=".claude/skills/feature/scripts/consensus-loop.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
CHECKPOINT_VERSION="$(grep -E '^CONSENSUS_CHECKPOINT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" FEATURE_LIVE_TEE=1
: > "$MOCK_LOG"

# --- fake codex: 모든 호출을 기록한다. 검증자(read-only)는 대상별로 기록만 하고 리뷰 파일은 픽스처를 쓴다. 워커는 USER_DECISION 으로 멈춘다 ---
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
out=""; readonly_sb=0; prompt=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; --sandbox) [ "$2" = read-only ] && readonly_sb=1; shift 2;; *) prompt="$1"; shift;; esac; done
if [ "$readonly_sb" = 1 ]; then
  if printf '%s' "$prompt" | grep -q '설계 검증자'; then echo "validator design" >> "$MOCK_LOG"
  elif printf '%s' "$prompt" | grep -q '구현 문서 검증자'; then echo "validator impl" >> "$MOCK_LOG"
  else echo "readonly unknown" >> "$MOCK_LOG"; fi
  exit 0
fi
echo "worker" >> "$MOCK_LOG"
printf '{"status":"UNDECIDED","undecided":[{"kind":"USER_DECISION","location":"src/u01.txt","decision_needed":"policy","options":["a","b"]}],"delegated_choices":[],"tests":[]}' > "$out"
exit 0
EOF
# --- mock claude: 디자이너·리뷰어·수정자 — 이 스모크에서는 호출되면 안 된다 (검증자 픽스처가 항상 PASS) ---
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude-called" >> "$MOCK_LOG"; exit 1
EOF
chmod +x "$TMP/bin/codex" "$TMP/bin/claude"

# --- 합의 PASS 픽스처: 가짜 PASS 리뷰를 두고 합의 루프를 돌려 체크포인트를 만든다 ---
fake_pass() { # design|impl
  printf '{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}\n' "$CONTRACT" > ".agent-work/reviews/validator-$1-round-01.json"
  bash "$LOOP" "$1" > "$TMP/consensus-$1.log" 2>&1 || { cat "$TMP/consensus-$1.log"; fail "픽스처: $1 합의 PASS 체크포인트 생성 실패"; }
}
current() { ( source "$CFG"; consensus_pass_current "$1" ) && echo true || echo false; }
pass_fp() { ( source "$CFG"; consensus_pass_fingerprint "$1" ); }
upstream_fp() { ( source "$CFG"; consensus_upstream_fingerprint "$1" ); }
run_runner() { : > "$MOCK_LOG"; bash "$RUN" > "$TMP/run.log" 2>&1; echo $?; }
reason() { jq -r '.reason' .agent-work/run-state.json; }
detail() { jq -r '.detail // .message // ""' .agent-work/run-state.json; }
llm_calls() { grep -c . "$MOCK_LOG" || true; }

fake_pass design; fake_pass impl
[ "$(current design)" = true ] && [ "$(current impl)" = true ] || fail "전제: design/impl PASS 체크포인트가 유효하지 않음"
jq -e --argjson cv "$CHECKPOINT_VERSION" '.version==$cv' .agent-work/consensus-design.json >/dev/null || fail "전제: 체크포인트 포맷 버전이 $CHECKPOINT_VERSION 이 아님"
[ "$CHECKPOINT_VERSION" -ge 3 ] || fail "전제: 지문 의미가 바뀌었으므로 CONSENSUS_CHECKPOINT_VERSION 은 3 이상이어야 함 (현재 $CHECKPOINT_VERSION)"

# ===== 사례 A: impl 결정은 design PASS 를 깨지 않는다 =====
design_fp_before="$(pass_fp design)"; design_up_before="$(upstream_fp design)"
echo '- [USER-QUESTION][scope=impl] GeminiClient 단위 테스트 요구 → 기각' >> .agent-work/decisions.md
[ "$(current design)" = true ] || fail "A: scope=impl 결정이 design PASS 를 무효화함"
[ "$(current impl)" = false ] || fail "A: scope=impl 결정인데 impl PASS 가 그대로 유효함"
[ "$(pass_fp design)" = "$design_fp_before" ] || fail "A: design PASS 지문이 scope=impl 결정으로 바뀜"
[ "$(upstream_fp design)" = "$design_up_before" ] || fail "A: design upstream 지문이 scope=impl 결정으로 바뀜"
pass "A: scope=impl 결정 → design PASS 유지, impl PASS 만 무효"

# ===== 사례 B: design 결정은 둘 다 깬다 =====
fake_pass impl
[ "$(current impl)" = true ] || fail "B: 전제 — impl PASS 재동기화 실패"
echo '- [USER-QUESTION][scope=design] API 동작 선택 → B' >> .agent-work/decisions.md
[ "$(current design)" = false ] || fail "B: scope=design 결정인데 design PASS 가 유효함"
[ "$(current impl)" = false ] || fail "B: scope=design 결정인데 impl PASS 가 유효함 (downstream 은 upstream 결정을 상속해야 함)"
pass "B: scope=design 결정 → design·impl PASS 모두 무효"

# ===== 사례 C: 합의 이력 줄은 PASS 지문을 바꾸지 않는다 =====
fake_pass design; fake_pass impl
d0="$(pass_fp design)"; i0="$(pass_fp impl)"
printf '%s\n' '- [round 3] TEST-01 REJECT: 기존 계약에 없는 요구' '- [fix round 1] R-02 REJECT: diff 밖' >> .agent-work/decisions.md
[ "$(pass_fp design)" = "$d0" ] && [ "$(pass_fp impl)" = "$i0" ] || fail "C: 합의 이력 줄이 PASS 지문을 바꿈"
[ "$(current design)" = true ] && [ "$(current impl)" = true ] || fail "C: 합의 이력 줄이 PASS 를 무효화함"
pass "C: [round N]/[fix round N] 이력 → PASS 지문 동일"

# ===== 사례 D: stage=worker 에서 scope=impl 결정 추가 → impl 로만 내려감, design 검증자 0회 =====
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
echo '- [USER-QUESTION][scope=impl] 재시도 정책 → 없음' >> .agent-work/decisions.md
rc="$(run_runner)"
grep -q 'impl 합의 PASS 가 현재 입력에 대해 유효하지 않음 — impl 부터' "$TMP/run.log" || { tail -20 "$TMP/run.log"; fail "D: 러너가 impl 로 내려가지 않음"; }
grep -q 'design 합의 PASS 가 현재 입력에 대해 유효하지 않음' "$TMP/run.log" && fail "D: scope=impl 결정인데 러너가 design 으로 내려감"
[ "$(grep -c '^validator design' "$MOCK_LOG")" -eq 0 ] || fail "D: design 검증자가 호출됨 ($(grep -c '^validator design' "$MOCK_LOG")회)"
[ "$(grep -c '^validator impl' "$MOCK_LOG")" -eq 1 ] || fail "D: impl 검증자 호출이 1회가 아님: $(paste -sd'|' "$MOCK_LOG")"
grep -q 'claude-called' "$MOCK_LOG" && fail "D: 디자이너/리뷰어가 호출됨 (PASS 픽스처인데)"
[ "$(current impl)" = true ] || fail "D: impl 재합의 뒤 impl PASS 가 현재 입력(새 scope=impl 결정 포함)에 대해 유효하지 않음"
# 이후 워커가 진행되고(USER_DECISION 픽스처로 멈춤) 러너 detail 이 써야 할 태그를 알려 준다
[ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] || { tail -20 "$TMP/run.log"; fail "D: impl 재합의 후 워커 진행 → exit 2/UNDECIDED 기대, 실제 $rc/$(reason)"; }
grep -q '^worker' "$MOCK_LOG" || fail "D: impl 재합의 후 워커가 진행되지 않음"
detail | grep -q '\[USER-QUESTION\]\[scope=impl\]' || fail "D: UNDECIDED detail 에 기록할 태그([USER-QUESTION][scope=impl])가 없음: $(detail)"
pass "D: scope=impl 결정 후 재실행 → design PASS 재사용(검증자 0회), impl 만 재검증(1회), 워커 진행"

# ===== 사례 E: design.md 변경은 impl 결정 여부와 무관하게 design 을 깬다 =====
cp .agent-work/design.md "$TMP/design.keep"
echo "changed" >> .agent-work/design.md
[ "$(current design)" = false ] || fail "E: design.md 가 바뀌었는데 design PASS 가 유효함"
[ "$(current impl)" = false ] || fail "E: design.md 가 바뀌었는데 impl PASS 가 유효함"
cp "$TMP/design.keep" .agent-work/design.md
[ "$(current design)" = true ] || fail "E: design.md 를 되돌렸는데 design PASS 가 복구되지 않음"
pass "E: design.md 변경 → design(과 impl) PASS 무효, 되돌리면 복구"

# ===== 사례 F: scope 없는 옛 형식 → LLM 호출 0회, DECISION_SCOPE_REQUIRED =====
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
echo '- [USER-QUESTION] 옛 형식 질문 → 답' >> .agent-work/decisions.md
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = DECISION_SCOPE_REQUIRED ] || { tail -20 "$TMP/run.log"; fail "F: exit 2/DECISION_SCOPE_REQUIRED 기대, 실제 $rc/$(reason)"; }
[ "$(llm_calls)" -eq 0 ] || fail "F: 옛 형식 결정이 있는데 LLM 이 호출됨: $(paste -sd'|' "$MOCK_LOG")"
detail | grep -q '옛 형식 질문' || fail "F: detail 에 해당 줄이 없음: $(detail)"
detail | grep -q '\[USER-QUESTION\]\[scope=design\]' && detail | grep -q '\[USER-QUESTION\]\[scope=impl\]' || fail "F: detail 에 바꿔야 할 두 형식이 없음: $(detail)"
# 합의 루프 단독 실행도 같은 검사로 유료 호출 전에 멈춘다
: > "$MOCK_LOG"
bash "$LOOP" impl > "$TMP/loop-legacy.log" 2>&1 && fail "F: 옛 형식 결정이 있는데 합의 루프가 진행됨"
grep -q 'DECISION_SCOPE_REQUIRED' "$TMP/loop-legacy.log" || { cat "$TMP/loop-legacy.log"; fail "F: 합의 루프 단독 실행이 DECISION_SCOPE_REQUIRED 로 멈추지 않음"; }
[ "$(llm_calls)" -eq 0 ] || fail "F: 합의 루프 단독 실행에서 LLM 이 호출됨"
# 태그를 붙이면 진행된다 (자동 추정은 없었음 — 사용자가 고친 뒤에야 지문에 들어간다)
sed -i.bak 's/^- \[USER-QUESTION\] 옛 형식/- [USER-QUESTION][scope=impl] 옛 형식/' .agent-work/decisions.md && rm -f .agent-work/decisions.md.bak
( source "$CFG"; [ -z "$(consensus_unscoped_user_decisions)" ] ) || fail "F: 태그를 붙였는데 여전히 unscoped 로 판정"
[ "$(current design)" = true ] || fail "F: 태그(scope=impl)를 붙인 뒤 design PASS 가 깨짐"
[ "$(current impl)" = false ] || fail "F: 태그(scope=impl)를 붙인 뒤 impl PASS 가 무효화되지 않음"
pass "F: 옛 형식 [USER-QUESTION] → LLM 0회, DECISION_SCOPE_REQUIRED(러너·루프 모두), 태그 후 정상 분리"

rm -rf "$TMP"
echo "[SMOKE OK] 사용자 결정 scope 분리 스모크 전체 통과"
