#!/usr/bin/env bash
# =============================================================
# 스모크: DESIGN_REVISION_MODEL 이 child DESIGNER(합의 문서 수정) 호출에만 쓰인다 — 실제 LLM 호출 없음 (mock claude / fake codex), 임시 저장소
# 파일 경로: tests/smoke-design-revision-model.sh
# 사용법: bash tests/smoke-design-revision-model.sh
#
# 사례:
#   A. role_model DESIGNER 는 DESIGN_REVISION_MODEL 을, role_effort/role_cli DESIGNER 는 DESIGNER_EFFORT/DESIGNER_CLI 를 그대로 읽는다
#   B. 검증자 PASS → design revision 모델(디자이너) 호출 0회
#   C. 검증자 BLOCK → 디자이너가 --model "$DESIGN_REVISION_MODEL" --effort "$DESIGNER_EFFORT" 로 1회 호출된다
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-drm-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
# 역할 CLI 고정: 디자이너=claude(mock), 검증자=codex(fake). 모델 ID 는 라우팅과 무관한 값으로 두어 DESIGNER_CLI 명시가 실제로 쓰이는지 확인한다.
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"true\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"true\"|; \
  s|^DESIGN_REVISION_MODEL=.*|DESIGN_REVISION_MODEL=\"smoke-revision-model\"|; s|^DESIGNER_EFFORT=.*|DESIGNER_EFFORT=\"smoke-effort\"|; s|^DESIGNER_CLI=.*|DESIGNER_CLI=\"claude\"|; \
  s|^VALIDATOR_MODEL=.*|VALIDATOR_MODEL=\"gpt-smoke\"|; s|^VALIDATOR_CLI=.*|VALIDATOR_CLI=\"codex\"|; s|^WORKER_CLI=.*|WORKER_CLI=\"codex\"|; s|^REVIEWER_CLI=.*|REVIEWER_CLI=\"claude\"|; s|^FIXER_CLI=.*|FIXER_CLI=\"claude\"|" "$CFG" && rm -f "$CFG.bak"
grep -q '^DESIGNER_MODEL=' "$CFG" && fail "config.sh 에 DESIGNER_MODEL 이 남아 있음(호환 alias 금지)"

# --- A. lookup ---
lookup="$(bash -c 'source "$1"; printf "%s|%s|%s" "$(role_model DESIGNER)" "$(role_effort DESIGNER)" "$(role_cli DESIGNER)"' _ "$CFG")" || fail "config.sh source 실패"
[ "$lookup" = "smoke-revision-model|smoke-effort|claude" ] || fail "DESIGNER lookup 불일치: $lookup"
others="$(bash -c 'source "$1"; printf "%s|%s" "$(role_model VALIDATOR)" "$(role_cli VALIDATOR)"' _ "$CFG")"
[ "$others" = "gpt-smoke|codex" ] || fail "다른 역할 lookup 이 깨짐: $others"
pass "A. role_model DESIGNER → DESIGN_REVISION_MODEL, DESIGNER_EFFORT/DESIGNER_CLI 유지"

cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && echo "base" > src/u01.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
: > .agent-work/decisions.md
LOOP=".claude/skills/feature/scripts/consensus-loop.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_VALIDATOR_CONTRACT="$CONTRACT" MOCK_VERDICT_FILE="$TMP/verdict"
: > "$MOCK_LOG"

# --- fake codex(검증자): MOCK_VERDICT_FILE 의 판정(PASS|BLOCK)을 -o 에 쓴다. BLOCK 은 1회만 내고 이후 PASS 로 수렴한다 ---
cat > "$TMP/bin/codex" <<'EOS'
#!/usr/bin/env bash
out=""; while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
echo "validator" >> "$MOCK_LOG"
v="$(cat "$MOCK_VERDICT_FILE" 2>/dev/null || echo PASS)"
if [ "$v" = BLOCK ]; then
  echo PASS > "$MOCK_VERDICT_FILE"
  printf '{"schema_version":%s,"verdict":"BLOCK","blocking_issues":[{"id":"B-01","action":"REVISE_DOC","category":"CONTRACT_GAP","change_relation":"NEW","evidence_type":"DIRECT_MISMATCH","basis_refs":["design.md:L1"],"conflict_refs":["design.md:L1"],"code_refs":[],"reachable_scenario":"","impact":"x","why_blocks_now":"y","minimum_contract_needed":"z","user_question":"","options":[],"origin":"ROUND_1","previous_issue_id":"","revision_ref":""}]}\n' "$MOCK_VALIDATOR_CONTRACT" > "$out"
else
  printf '{"schema_version":%s,"verdict":"PASS","blocking_issues":[]}\n' "$MOCK_VALIDATOR_CONTRACT" > "$out"
fi
exit 0
EOS
# --- mock claude(디자이너): --model/--effort 값을 기록하고 문서를 수정한다 ---
cat > "$TMP/bin/claude" <<'EOS'
#!/usr/bin/env bash
model=""; effort=""; while [ "$#" -gt 0 ]; do case "$1" in --model) model="$2"; shift 2;; --effort) effort="$2"; shift 2;; *) shift;; esac; done
echo "designer model=$model effort=$effort" >> "$MOCK_LOG"
echo "revised" >> .agent-work/design.md
printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"smoke","usage":{}}\n'
exit 0
EOS
chmod +x "$TMP/bin/codex" "$TMP/bin/claude"

# --- B. PASS → 디자이너 호출 0회 ---
echo PASS > "$MOCK_VERDICT_FILE"
bash "$LOOP" design > "$TMP/pass.log" 2>&1 || { cat "$TMP/pass.log"; fail "B. PASS 합의 루프 실패"; }
grep -q '^designer' "$MOCK_LOG" && fail "B. 검증자 PASS 인데 디자이너가 호출됨: $(cat "$MOCK_LOG")"
pass "B. 검증자 PASS → design revision 모델 호출 0회"

# --- C. BLOCK → 디자이너 1회, --model 이 DESIGN_REVISION_MODEL ---
: > "$MOCK_LOG"; rm -f .agent-work/consensus-design.json; echo BLOCK > "$MOCK_VERDICT_FILE"
bash "$LOOP" design > "$TMP/block.log" 2>&1 || { cat "$TMP/block.log"; fail "C. BLOCK→수정→PASS 합의 루프 실패"; }
[ "$(grep -c '^designer' "$MOCK_LOG")" = 1 ] || fail "C. 디자이너 호출 횟수 불일치: $(cat "$MOCK_LOG")"
grep -qx 'designer model=smoke-revision-model effort=smoke-effort' "$MOCK_LOG" || fail "C. 디자이너 --model/--effort 불일치: $(cat "$MOCK_LOG")"
pass "C. 검증자 BLOCK → 디자이너가 DESIGN_REVISION_MODEL/DESIGNER_EFFORT 로 호출됨"
echo "[SMOKE OK] design revision model"
