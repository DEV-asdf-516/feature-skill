#!/usr/bin/env bash
# =============================================================
# install.sh 스모크 테스트 — LLM CLI 없이 git + jq 만으로 실행
# 사용법: bash tests/install-smoke.sh   (이 저장소 어디서든)
# =============================================================
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
fail() { echo "[FAIL] $1" >&2; exit 1; }

TARGET="$SCRATCH/target"
TARGET_SKILL="$TARGET/.claude/skills/feature"
git init -q "$TARGET"

# ---------- 1. 신규 설치 ----------
bash "$SOURCE_ROOT/install.sh" "$TARGET" >/dev/null
[ -x "$TARGET_SKILL/scripts/consensus-loop.sh" ] || fail "신규 설치: 스크립트 누락/실행권한 없음"
[ -x "$TARGET_SKILL/scripts/feature-run.sh" ] || fail "신규 설치: 러너 누락/실행권한 없음"
[ -f "$TARGET_SKILL/schemas/worker-result.schema.json" ] || fail "신규 설치: 워커 결과 스키마 누락"
[ -x "$TARGET/feature-live" ] || fail "신규 설치: feature-live 누락"
[ -x "$TARGET/.claude/hooks/inject_conventions.sh" ] || fail "신규 설치: conventions 훅 누락/실행권한 없음"
[ -f "$TARGET/.claude/hooks/core_rules.md" ] || fail "신규 설치: core_rules.md 누락"
jq -e '.hooks.UserPromptSubmit and .hooks.PreToolUse' "$TARGET/.claude/settings.json" >/dev/null \
  || fail "신규 설치: settings.json hooks 누락"
echo "[OK] 1. 신규 설치"

# ---------- 2. 재실행 멱등성 ----------
rerun_output="$(bash "$SOURCE_ROOT/install.sh" "$TARGET")"
echo "$rerun_output" | grep -q WARN && fail "재실행: 변경 없는데 WARN 발생"
echo "[OK] 2. 재실행 멱등성"

# ---------- 3. 사용자 수정 보존 (+ .new 생성) ----------
sed -i.sedbak 's/^TEST_CMD=.*/TEST_CMD="npm test"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
printf '# 프로젝트 커스텀 규칙\n' >> "$TARGET/.claude/hooks/core_rules.md"
bash "$SOURCE_ROOT/install.sh" "$TARGET" >/dev/null
grep -q 'npm test' "$TARGET_SKILL/config.sh" || fail "수정 보존: config.sh 덮어써짐"
grep -q '커스텀 규칙' "$TARGET/.claude/hooks/core_rules.md" || fail "수정 보존: core_rules.md 덮어써짐"
[ -f "$TARGET_SKILL/config.sh.new" ] || fail "수정 보존: config.sh.new 미생성"
echo "[OK] 3. 사용자 수정 보존 + .new"

# ---------- 3b. 역할별 모델/effort + 선택 conventions 규칙 병합 ----------
sed -i.sedbak 's/^LINT_CMD=.*/LINT_CMD="true"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^WORKER_EFFORT=.*/WORKER_EFFORT="high"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^REVIEWER_EFFORT=.*/REVIEWER_EFFORT="low"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^FIXER_EFFORT=.*/FIXER_EFFORT="high"/' "$TARGET_SKILL/config.sh" && rm -f "$TARGET_SKILL/config.sh.sedbak"
role_efforts="$(bash -c 'source "$1"; printf "%s|%s|%s|%s|%s" "$DESIGNER_EFFORT" "$VALIDATOR_EFFORT" "$WORKER_EFFORT" "$REVIEWER_EFFORT" "$FIXER_EFFORT"' _ "$TARGET_SKILL/config.sh")"
[ "$role_efforts" = "medium|medium|high|low|high" ] || fail "역할별 effort: config 값이 독립적으로 적용되지 않음 ($role_efforts)"
conventions_without_file="$(bash -c 'source "$1"; load_project_conventions' _ "$TARGET_SKILL/config.sh")"
[ -z "$conventions_without_file" ] || fail "규칙 병합: conventions.md가 없는데 내용이 생성됨"
worker_rules_without_conventions="$(bash -c 'source "$1"; load_worker_rules' _ "$TARGET_SKILL/config.sh")"
echo "$worker_rules_without_conventions" | grep -q '커스텀 규칙' || fail "워커 규칙: core_rules.md 누락"
echo "$worker_rules_without_conventions" | grep -q '\[PROJECT CONVENTIONS\]' \
  && fail "워커 규칙: conventions.md가 없는데 구획이 생성됨"
printf '# 프로젝트 컨벤션\n' > "$TARGET/conventions.md"
conventions_with_file="$(bash -c 'source "$1"; load_project_conventions' _ "$TARGET_SKILL/config.sh")"
echo "$conventions_with_file" | grep -q '\[PROJECT CONVENTIONS\]' || fail "규칙 병합: conventions 구획 누락"
echo "$conventions_with_file" | grep -q '프로젝트 컨벤션' || fail "규칙 병합: conventions.md 내용 누락"
echo "$conventions_with_file" | grep -q '커스텀 규칙' && fail "규칙 분리: core_rules.md가 비워커 규칙에 포함됨"
orchestrator_rules="$(CLAUDE_PROJECT_DIR="$TARGET" bash "$TARGET/.claude/hooks/inject_conventions.sh")"
echo "$orchestrator_rules" | grep -q '프로젝트 컨벤션' || fail "오케스트레이터 규칙: conventions.md 누락"
echo "$orchestrator_rules" | grep -q '커스텀 규칙' && fail "오케스트레이터 규칙: core_rules.md가 주입됨"
grep -Fq '${WORKER_RULES}' "$TARGET_SKILL/prompts/worker-implement.md" || fail "규칙 전달: 워커 프롬프트 누락"
grep -Fq '${PROJECT_CONVENTIONS}' "$TARGET_SKILL/prompts/validator-review-design.md" || fail "규칙 전달: 검증자 conventions 누락"
grep -Fq -- '--append-system-prompt "$PROJECT_CONVENTIONS"' "$TARGET_SKILL/scripts/impl-review-loop.sh" \
  || fail "규칙 전달: 리뷰어/수정자 system prompt 누락"
grep -Fq '.blocking_issues[]?' "$TARGET_SKILL/scripts/consensus-loop.sh" || fail "관찰성: 상세 blocking 이슈 출력 누락"
grep -q 'decisions_lines_before' "$TARGET_SKILL/scripts/consensus-loop.sh" || fail "관찰성: 신규 결정 출력 누락"
echo "[OK] 3b. 역할별 모델/effort + 선택 conventions + 합의 로그"

# ---------- 4. 비호환 구버전 config → 활성 코드 교체 전 중단 ----------
printf 'TEST_CMD="npm test"\nLINT_CMD="true"\n' > "$TARGET_SKILL/config.sh"
printf 'sentinel\n' > "$TARGET_SKILL/scripts/.pre-update-sentinel"
if bash "$SOURCE_ROOT/install.sh" "$TARGET" >/dev/null 2>&1; then
  fail "비호환 config: 중단 없이 성공함"
fi
[ -f "$TARGET_SKILL/scripts/.pre-update-sentinel" ] || fail "비호환 config: 중단 전에 활성 코드가 교체됨"
ls "$TARGET_SKILL"/.install-stage-* >/dev/null 2>&1 && fail "비호환 config: 스테이징 잔여물 남음"
echo "[OK] 4. 비호환 config 사전 중단 (활성 코드 무손상)"

# ---------- 4b. 세 번째 항목(schemas) 복사 실패 → 앞 항목도 기존 상태 유지 ----------
BROKEN_SOURCE="$SCRATCH/broken-source"
cp -R "$SOURCE_ROOT" "$BROKEN_SOURCE"
printf '\n<!-- BROKEN-SOURCE-SENTINEL -->\n' >> "$BROKEN_SOURCE/.claude/skills/feature/SKILL.md"
rm -rf "$BROKEN_SOURCE/.claude/skills/feature/schemas"
PARTIAL_TARGET="$SCRATCH/partial"
git init -q "$PARTIAL_TARGET"
bash "$SOURCE_ROOT/install.sh" "$PARTIAL_TARGET" >/dev/null
if bash "$BROKEN_SOURCE/install.sh" "$PARTIAL_TARGET" >/dev/null 2>&1; then
  fail "복사 실패: schemas 없는 소스인데 성공함"
fi
grep -q 'BROKEN-SOURCE-SENTINEL' "$PARTIAL_TARGET/.claude/skills/feature/SKILL.md" \
  && fail "복사 실패: 뒤 항목 실패에도 앞 항목(SKILL.md)이 교체됨"
ls "$PARTIAL_TARGET/.claude/skills/feature"/.install-stage-* >/dev/null 2>&1 \
  && fail "복사 실패: 스테이징 잔여물 남음"
echo "[OK] 4b. 항목 일부 복사 실패 시 전체 무손상"

# ---------- 5. 잘못된 이벤트에 등록된 훅 → 미등록으로 판정 ----------
WRONG_EVENT_TARGET="$SCRATCH/wrong-event"
git init -q "$WRONG_EVENT_TARGET"
mkdir -p "$WRONG_EVENT_TARGET/.claude"
jq -n '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: "$CLAUDE_PROJECT_DIR/.claude/hooks/pre_bash_guard.sh"}]}]}}' \
  > "$WRONG_EVENT_TARGET/.claude/settings.json"
wrong_event_output="$(bash "$SOURCE_ROOT/install.sh" "$WRONG_EVENT_TARGET")"
echo "$wrong_event_output" | grep -q 'PreToolUse 에 pre_bash_guard.sh 미등록' \
  || fail "훅 이벤트 검사: 잘못된 이벤트 등록을 설치됨으로 오판"
echo "[OK] 5. 훅 이벤트 단위 검사"

# ---------- 5b. 올바른 이벤트 + 가짜 command 문자열 → 미등록으로 판정 ----------
FAKE_COMMAND_TARGET="$SCRATCH/fake-command"
git init -q "$FAKE_COMMAND_TARGET"
mkdir -p "$FAKE_COMMAND_TARGET/.claude"
jq -n '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: "echo disabled pre_bash_guard.sh"}]}]}}' \
  > "$FAKE_COMMAND_TARGET/.claude/settings.json"
fake_command_output="$(bash "$SOURCE_ROOT/install.sh" "$FAKE_COMMAND_TARGET")"
echo "$fake_command_output" | grep -q 'PreToolUse 에 pre_bash_guard.sh 미등록' \
  || fail "훅 command 검사: 비활성 문자열(echo disabled ...)을 설치됨으로 오판"
echo "[OK] 5b. 가짜 command 문자열 미등록 판정"

# ---------- 5c. 레거시 core rules 주입 훅 → 교체 경고 ----------
LEGACY_HOOK_TARGET="$SCRATCH/legacy-hook"
git init -q "$LEGACY_HOOK_TARGET"
mkdir -p "$LEGACY_HOOK_TARGET/.claude"
jq -n '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: "$CLAUDE_PROJECT_DIR/.claude/hooks/inject_core_rules.sh"}]}]}}' \
  > "$LEGACY_HOOK_TARGET/.claude/settings.json"
legacy_hook_output="$(bash "$SOURCE_ROOT/install.sh" "$LEGACY_HOOK_TARGET")"
echo "$legacy_hook_output" | grep -q '레거시 inject_core_rules.sh' \
  || fail "훅 마이그레이션: 레거시 core rules 주입 훅 교체 경고 누락"
echo "$legacy_hook_output" | grep -q 'inject_conventions.sh로 교체' \
  || fail "훅 마이그레이션: 교체 대상 안내 누락"
echo "[OK] 5c. 레거시 core rules 훅 교체 안내"

# ---------- 6. .gitignore 중복 방지 ----------
duplicate_count="$(grep -c '^\.agent-work/$' "$TARGET/.gitignore")"
[ "$duplicate_count" = "1" ] || fail ".gitignore: .agent-work/ 항목 ${duplicate_count}개 (1개여야 함)"
echo "[OK] 6. .gitignore 중복 방지"

# ---------- 7. 삭제 가드 동작 검증 (pre_bash_guard / worker_guard) ----------
BASH_GUARD="$TARGET/.claude/hooks/pre_bash_guard.sh"
run_bash_guard() { printf '{"tool_input":{"command":"%s"}}' "$1" | CLAUDE_PROJECT_DIR="$TARGET" bash "$BASH_GUARD"; }
run_bash_guard 'rm -rf src/legacy' 2>/dev/null && fail "삭제 가드: 플래그 없는 rm 이 통과됨"
run_bash_guard 'git rm old_module.py' 2>/dev/null && fail "삭제 가드: 플래그 없는 git rm 이 통과됨"
run_bash_guard 'rm -rf .agent-work/reviews' 2>/dev/null || fail "삭제 가드: .agent-work 예외 경로가 차단됨"
run_bash_guard 'echo removed' 2>/dev/null || fail "삭제 가드: rm 을 포함하지 않는 명령이 차단됨"
touch "$TARGET/.claude/ALLOW_DELETE"
run_bash_guard 'rm src/legacy/old.txt' 2>/dev/null || fail "삭제 가드: ALLOW_DELETE 플래그가 있는데 차단됨"
[ ! -f "$TARGET/.claude/ALLOW_DELETE" ] || fail "삭제 가드: ALLOW_DELETE 플래그가 1회용으로 소모되지 않음"
WORKER_GUARD="$TARGET/.codex/hooks/worker_guard.sh"
printf '{"cwd":"%s","tool_input":{"command":["bash","-lc","rm -rf src/legacy"]}}' "$TARGET" \
  | bash "$WORKER_GUARD" 2>/dev/null && fail "worker 가드: rm 이 통과됨"
printf '{"cwd":"%s","tool_input":{"command":["bash","-lc","rm -rf .agent-work/tmp"]}}' "$TARGET" \
  | bash "$WORKER_GUARD" 2>/dev/null || fail "worker 가드: .agent-work 예외 경로가 차단됨"
printf '{"cwd":"%s","tool_input":{"command":["bash","-lc","git commit -m x"]}}' "$TARGET" \
  | bash "$WORKER_GUARD" 2>/dev/null && fail "worker 가드: 워커 커밋이 통과됨"
echo "[OK] 7. 삭제 가드 (pre_bash_guard / worker_guard)"

# ---------- 8. live.log 아카이브 + 중첩 tee 중복 방지 ----------
LOG_TARGET="$SCRATCH/logging"
LOG_SKILL="$LOG_TARGET/.claude/skills/feature"
git init -q "$LOG_TARGET"
bash "$SOURCE_ROOT/install.sh" "$LOG_TARGET" >/dev/null
sed -i.sedbak 's/^CLAUDE_BIN=.*/CLAUDE_BIN="true"/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^CODEX_BIN=.*/CODEX_BIN="true"/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^TEST_CMD=.*/TEST_CMD="true"/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
sed -i.sedbak 's/^LINT_CMD=.*/LINT_CMD="true"/' "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
chmod -x "$LOG_TARGET/feature-live"

mkdir -p "$LOG_TARGET/.agent-work"
printf '이전 피처 로그\n' > "$LOG_TARGET/.agent-work/live.log"
printf '이전 산출물\n' > "$LOG_TARGET/.agent-work/previous.txt"
set +e
(cd "$LOG_TARGET" && bash "$LOG_SKILL/scripts/feature-run.sh" --new --archive-as live-regression) >/dev/null 2>&1
new_rc=$?
set -e
[ "$new_rc" = 3 ] || fail "live.log 아카이브: 새 피처 초기화 종료 코드가 3이 아님 ($new_rc)"
[ "$(cat "$LOG_TARGET/.agent-work/archive/live-regression/live.log")" = '이전 피처 로그' ] \
  || fail "live.log 아카이브: 이전 로그 내용이 보존되지 않음"
[ -f "$LOG_TARGET/.agent-work/archive/live-regression/previous.txt" ] \
  || fail "live.log 아카이브: 다른 이전 산출물과 같은 디렉터리에 보관되지 않음"
grep -q '이전 피처 로그' "$LOG_TARGET/.agent-work/live.log" \
  && fail "live.log 아카이브: 새 로그에 이전 로그가 계속 누적됨"

printf '# design\n' > "$LOG_TARGET/.agent-work/design.md"
mkdir -p "$LOG_TARGET/.agent-work/reviews"
printf '{"schema_version":3,"verdict":"PASS","blocking_issues":[]}\n' \
  > "$LOG_TARGET/.agent-work/reviews/validator-design-round-01.json"
set +e
(cd "$LOG_TARGET" && bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
resume_rc=$?
set -e
[ "$resume_rc" = 3 ] || fail "중첩 tee: 설계 합의 후 구현 문서 대기 종료 코드가 3이 아님 ($resume_rc)"
consensus_start_count="$(grep -c 'consensus-loop design 시작' "$LOG_TARGET/.agent-work/live.log")"
[ "$consensus_start_count" = 1 ] \
  || fail "중첩 tee: consensus-loop 시작 로그가 ${consensus_start_count}회 기록됨 (1회여야 함)"

: > "$LOG_TARGET/.agent-work/live.log"
set +e
(cd "$LOG_TARGET" && FEATURE_LIVE_TEE=1 bash "$LOG_SKILL/scripts/impl-review-loop.sh") \
  >> "$LOG_TARGET/.agent-work/live.log" 2>&1
set -e
impl_start_count="$(grep -c 'impl-review-loop 시작' "$LOG_TARGET/.agent-work/live.log")"
[ "$impl_start_count" = 1 ] \
  || fail "중첩 tee: impl-review-loop 시작 로그가 ${impl_start_count}회 기록됨 (1회여야 함)"

# 워커 원문 로그를 reviews/에 보존하면서 live.log에도 실시간 전달한다.
FAKE_CODEX="$LOG_TARGET/fake-codex"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -e' \
  'output_file=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in -o) output_file="$2"; shift 2;; *) shift;; esac' \
  'done' \
  'printf "WORKER_STREAM_MARKER\\n"' \
  'printf '\''{"status":"UNDECIDED","undecided":[{"kind":"'"'"'"$FAKE_KIND"'"'"'","location":"test","decision_needed":"test decision","options":[]}],"delegated_choices":[],"tests":[]}'\'' > "$output_file"' \
  > "$FAKE_CODEX"
chmod +x "$FAKE_CODEX"
sed -i.sedbak "s|^CODEX_BIN=.*|CODEX_BIN=\"$FAKE_CODEX\"|" "$LOG_SKILL/config.sh" && rm -f "$LOG_SKILL/config.sh.sedbak"
printf '# implementation\n' > "$LOG_TARGET/.agent-work/implementation.md"
printf '# approach\n' > "$LOG_TARGET/.agent-work/approach.md"
printf '{"schema_version":3,"verdict":"PASS","blocking_issues":[]}\n' \
  > "$LOG_TARGET/.agent-work/reviews/validator-impl-round-01.json"
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' \
  > "$LOG_TARGET/.agent-work/run-state.json"
: > "$LOG_TARGET/.agent-work/live.log"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=USER_DECISION bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
worker_rc=$?
set -e
[ "$worker_rc" = 2 ] || fail "워커 스트리밍: USER_DECISION 종료 코드가 2가 아님 ($worker_rc)"
worker_raw="$(ls "$LOG_TARGET"/.agent-work/reviews/worker-*.log | tail -1)"
[ "$(grep -c 'WORKER_STREAM_MARKER' "$worker_raw")" = 1 ] \
  || fail "워커 스트리밍: reviews 원문 로그에 출력이 정확히 1회 보존되지 않음"
[ "$(grep -c 'WORKER_STREAM_MARKER' "$LOG_TARGET/.agent-work/live.log")" = 1 ] \
  || fail "워커 스트리밍: live.log에 출력이 정확히 1회 전달되지 않음"
# DOC_GAP 만 있으면 사용자에게 가지 않고 NEED_DOCS(exit 3), 재실행 시 검증자 재합의(stage=impl)
printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > "$LOG_TARGET/.agent-work/run-state.json"
set +e
(cd "$LOG_TARGET" && FAKE_KIND=DOC_GAP bash "$LOG_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
docgap_rc=$?
set -e
[ "$docgap_rc" = 3 ] || fail "DOC_GAP: 종료 코드가 3(NEED_DOCS)이 아님 ($docgap_rc)"
[ "$(jq -r '.reason' "$LOG_TARGET/.agent-work/run-state.json")" = APPROACH_GAP ] || fail "DOC_GAP: reason 이 APPROACH_GAP 이 아님"
[ "$(jq -r '.stage' "$LOG_TARGET/.agent-work/run-state.json")" = impl ] || fail "DOC_GAP: 재개 stage 가 impl 이 아님"
echo "[OK] 8. live.log 아카이브 + 중첩 tee 중복 방지 + 워커 출력 스트리밍"

# ---------- 9. feature-live 저장소별 단일 실행 lock ----------
chmod +x "$LOG_TARGET/feature-live"
: > "$LOG_TARGET/.agent-work/live.log"
"$LOG_TARGET/feature-live" >/dev/null 2>&1 &
viewer_pid=$!
for _ in $(seq 1 50); do
  [ -f "$LOG_TARGET/.agent-work/.feature-live.lock/viewer.pid" ] && break
  sleep 0.02
done
[ -f "$LOG_TARGET/.agent-work/.feature-live.lock/viewer.pid" ] \
  || fail "feature-live lock: viewer.pid가 생성되지 않음"
[ "$(cat "$LOG_TARGET/.agent-work/.feature-live.lock/viewer.pid")" = "$viewer_pid" ] \
  || fail "feature-live lock: 실제 뷰어 PID와 기록값이 다름"

duplicate_viewer_output="$("$LOG_TARGET/feature-live")"
echo "$duplicate_viewer_output" | grep -q '이미 실행 중' \
  || fail "feature-live lock: 두 번째 실행이 기존 뷰어를 감지하지 못함"
kill "$viewer_pid"
wait "$viewer_pid" 2>/dev/null || true
[ ! -e "$LOG_TARGET/.agent-work/.feature-live.lock" ] \
  || fail "feature-live lock: 뷰어 종료 후 lock이 정리되지 않음"

mkdir -p "$LOG_TARGET/.agent-work/.feature-live.lock"
printf '99999999\n' > "$LOG_TARGET/.agent-work/.feature-live.lock/viewer.pid"
"$LOG_TARGET/feature-live" >/dev/null 2>&1 &
replacement_viewer_pid=$!
for _ in $(seq 1 50); do
  replacement_recorded_pid="$(cat "$LOG_TARGET/.agent-work/.feature-live.lock/viewer.pid" 2>/dev/null || true)"
  [ "$replacement_recorded_pid" = "$replacement_viewer_pid" ] && break
  sleep 0.02
done
[ "$replacement_recorded_pid" = "$replacement_viewer_pid" ] \
  || fail "feature-live lock: stale lock을 회수하지 못함"
kill "$replacement_viewer_pid"
wait "$replacement_viewer_pid" 2>/dev/null || true
echo "[OK] 9. feature-live 저장소별 단일 실행 lock"

echo ""
echo "install.sh 스모크 테스트 전부 통과"
