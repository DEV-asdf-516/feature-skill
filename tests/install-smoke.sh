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
# 디자이너·검증자 effort 는 소스 config.sh 값을 그대로 기대한다(프로젝트별로 바꾸는 값이라 고정 문자열로 두지 않는다)
src_designer_effort="$(sed -n 's/^DESIGNER_EFFORT="\([^"]*\)".*/\1/p' "$SOURCE_ROOT/.claude/skills/feature/config.sh")"
src_validator_effort="$(sed -n 's/^VALIDATOR_EFFORT="\([^"]*\)".*/\1/p' "$SOURCE_ROOT/.claude/skills/feature/config.sh")"
[ "$role_efforts" = "$src_designer_effort|$src_validator_effort|high|low|high" ] || fail "역할별 effort: config 값이 독립적으로 적용되지 않음 ($role_efforts, 기대 $src_designer_effort|$src_validator_effort|high|low|high)"
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
NO_NEWLINE_TARGET="$SCRATCH/no-newline-gitignore"
git init -q "$NO_NEWLINE_TARGET"
printf 'docs/' > "$NO_NEWLINE_TARGET/.gitignore"
bash "$SOURCE_ROOT/install.sh" "$NO_NEWLINE_TARGET" >/dev/null
[ "$(sed -n '1p' "$NO_NEWLINE_TARGET/.gitignore")" = 'docs/' ] || fail ".gitignore: 기존 마지막 줄이 변경됨"
[ "$(sed -n '2p' "$NO_NEWLINE_TARGET/.gitignore")" = '.agent-work/' ] || fail ".gitignore: 줄바꿈 없이 항목이 이어 붙음"
echo "[OK] 6. .gitignore 중복·줄바꿈 보존"

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
printf '{"cwd":"%s","tool_input":{"command":["bash","-lc","git add -A"]}}' "$TARGET" \
  | bash "$WORKER_GUARD" 2>/dev/null && fail "worker 가드: 워커 git add 가 통과됨"
printf '{"cwd":"%s","tool_input":{"command":["bash","-lc","git restore --staged src/a.txt"]}}' "$TARGET" \
  | bash "$WORKER_GUARD" 2>/dev/null && fail "worker 가드: 워커 git restore --staged 가 통과됨"
printf '{"cwd":"%s","tool_input":{"command":["bash","-lc","git restore --source=abc123 --worktree -- src/a.txt"]}}' "$TARGET" \
  | bash "$WORKER_GUARD" 2>/dev/null || fail "worker 가드: 작업 트리 전용 restore 가 차단됨"
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
[ -f "$LOG_TARGET/.agent-work/worker-baseline.tree" ] || fail "워커 기준선: 러너가 worker-baseline.tree 를 기록하지 않음"
(cd "$LOG_TARGET" && git cat-file -e "$(cat .agent-work/worker-baseline.tree)") || fail "워커 기준선: tree 객체가 저장소에 없음"
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

# ---------- 10. 구현 리뷰 루프 — 리뷰어 계약 연계 검사 (가짜 claude, LLM 호출 없음) ----------
REVIEW_TARGET="$SCRATCH/review"
REVIEW_SKILL="$REVIEW_TARGET/.claude/skills/feature"
REVIEW_SIDE="$SCRATCH/review.side"; mkdir -p "$REVIEW_SIDE"
git init -q "$REVIEW_TARGET"
bash "$SOURCE_ROOT/install.sh" "$REVIEW_TARGET" >/dev/null
chmod -x "$REVIEW_TARGET/feature-live"
# 가짜 claude: FAKE_REVIEW 파일을 structured_output 으로 감싸 출력 (카운터·픽스처는 저장소 밖 — 지문 보호)
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'jq -n -c --slurpfile r "$FAKE_REVIEW" '"'"'{structured_output: $r[0], session_id:"fake", total_cost_usd:0, usage:{input_tokens:0,output_tokens:0,cache_read_input_tokens:0,cache_creation_input_tokens:0}}'"'" \
  > "$REVIEW_SIDE/fake-claude"
chmod +x "$REVIEW_SIDE/fake-claude"
sed -i.sedbak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$REVIEW_SIDE/fake-claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"true\"|; s/^TEST_CMD=.*/TEST_CMD=\"true\"/; s/^LINT_CMD=.*/LINT_CMD=\"true\"/; s/^MAX_IMPL_ROUNDS=.*/MAX_IMPL_ROUNDS=0/" "$REVIEW_SKILL/config.sh" && rm -f "$REVIEW_SKILL/config.sh.sedbak"
mkdir -p "$REVIEW_TARGET/src" "$REVIEW_TARGET/.agent-work/reviews"
printf 'base\n' > "$REVIEW_TARGET/src/a.txt"
printf 'base\n' > "$REVIEW_TARGET/src/b.txt"
(cd "$REVIEW_TARGET" && git add -A && git -c user.email=t@t -c user.name=t commit -qm base)
# 피처 이전부터 있던 사용자의 미커밋 변경(b.txt) → 워커 진입 기준선에 포함돼 리뷰 diff 에 나오면 안 된다
printf 'user edit before feature\n' > "$REVIEW_TARGET/src/b.txt"
(cd "$REVIEW_TARGET" && bash -c 'source .claude/skills/feature/config.sh; snapshot_worktree_tree' > .agent-work/worker-baseline.tree)
printf 'changed\n' > "$REVIEW_TARGET/src/a.txt"
printf 'new\n' > "$REVIEW_TARGET/src/new.txt"
for doc in design implementation approach; do printf '# %s\n' "$doc" > "$REVIEW_TARGET/.agent-work/$doc.md"; done
printf '{"schema_version":3,"verdict":"PASS","blocking_issues":[]}\n' > "$REVIEW_TARGET/.agent-work/reviews/validator-impl-round-01.json"
printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[]}\n' > "$REVIEW_TARGET/.agent-work/worker-result.json"
review_issue='{"id":"R-01","action":"FIX_CODE","category":"CONTRACT_VIOLATION","evidence_type":"DIRECT_MISMATCH","basis_refs":["approach.md:L1"],"code_refs":["src/a.txt:L1-L1"],"reachable_scenario":"","impact":"","why_blocks_now":"x","required_outcome":"y","origin":"ROUND_1","previous_issue_id":"","fix_ref":""}'
run_review_loop() { # fake-review-json → exit code (stdout 은 run.log)
  printf '%s\n' "$1" > "$REVIEW_SIDE/review.json"
  local rc=0   # 함수 안에서 set ±e 를 토글하지 않는다 — 호출자의 errexit 상태를 바꾼다
  (cd "$REVIEW_TARGET" && FAKE_REVIEW="$REVIEW_SIDE/review.json" FEATURE_LIVE_TEE=1 bash "$REVIEW_SKILL/scripts/impl-review-loop.sh") > "$REVIEW_SIDE/run.log" 2>&1 || rc=$?
  return $rc
}
# (a) APPROVE → exit 0, 승인 지문 생성, diff 에 untracked 신규 파일 포함
run_review_loop '{"schema_version":6,"verdict":"APPROVE","issues":[]}' || fail "리뷰 루프: APPROVE 가 exit 0 이 아님"
[ -f "$REVIEW_TARGET/.agent-work/approved.fingerprint" ] || fail "리뷰 루프: 승인 지문 미생성"
grep -q 'src/new.txt' "$REVIEW_TARGET/.agent-work/reviews/impl-attempt-01/diff-round-01.patch" || fail "리뷰 루프: untracked 신규 파일이 리뷰 diff 에 없음"
grep -q 'src/b.txt' "$REVIEW_TARGET/.agent-work/reviews/impl-attempt-01/diff-round-01.patch" && fail "리뷰 루프: 기준선 이전 사용자 변경(b.txt)이 리뷰 diff 에 섞임"
grep -q '리뷰 기준선: 워커 진입 직전 tree' "$REVIEW_SIDE/run.log" || fail "리뷰 루프: 기준선 tree 를 쓰지 않음"
# (b) Round 1 인데 origin=FIX_REGRESSION → 연계 검사가 응답 오류로 거부 (exit 1)
run_review_loop "$(printf '%s' "$review_issue" | jq -c '{schema_version:6,verdict:"REQUEST_CHANGES",issues:[. + {origin:"FIX_REGRESSION",fix_ref:"src/a.txt:L1-L1"}]}')" && fail "리뷰 루프: Round 1 의 FIX_REGRESSION origin 이 통과됨"
grep -q '근거·연계 필드' "$REVIEW_SIDE/run.log" || fail "리뷰 루프: origin 위반 거부 사유가 기록되지 않음"
# (c) schema_version 불일치 → exit 1
run_review_loop '{"schema_version":1,"verdict":"APPROVE","issues":[]}' && fail "리뷰 루프: 구버전 schema_version 이 통과됨"
# (d) FIX_CODE 인데 required_outcome 비어 있음 → exit 1
run_review_loop "$(printf '%s' "$review_issue" | jq -c '{schema_version:6,verdict:"REQUEST_CHANGES",issues:[. + {required_outcome:""}]}')" && fail "리뷰 루프: required_outcome 없는 FIX_CODE 가 통과됨"
# (e) DOC_GAP → exit 3, 러너는 NEED_DOCS(APPROACH_GAP) + stage=impl 로 반환
set +e; run_review_loop "$(printf '%s' "$review_issue" | jq -c '{schema_version:6,verdict:"REQUEST_CHANGES",issues:[. + {action:"DOC_GAP"}]}')"; docgap_loop_rc=$?; set -e
[ "$docgap_loop_rc" = 3 ] || fail "리뷰 루프: DOC_GAP 종료 코드가 3 이 아님 ($docgap_loop_rc)"
[ "$(jq -r '.status' "$REVIEW_TARGET/.agent-work/state.json")" = DOC_GAP ] || fail "리뷰 루프: state.json 이 DOC_GAP 이 아님"
printf '{"stage":"review","test_retries":0,"stale_count":0,"history":[]}\n' > "$REVIEW_TARGET/.agent-work/run-state.json"
set +e
(cd "$REVIEW_TARGET" && FAKE_REVIEW="$REVIEW_SIDE/review.json" bash "$REVIEW_SKILL/scripts/feature-run.sh") >/dev/null 2>&1
review_docgap_rc=$?
set -e
[ "$review_docgap_rc" = 3 ] || fail "리뷰어 DOC_GAP: 러너 종료 코드가 3(NEED_DOCS)이 아님 ($review_docgap_rc)"
[ "$(jq -r '.reason' "$REVIEW_TARGET/.agent-work/run-state.json")" = APPROACH_GAP ] || fail "리뷰어 DOC_GAP: reason 이 APPROACH_GAP 이 아님"
[ "$(jq -r '.stage' "$REVIEW_TARGET/.agent-work/run-state.json")" = impl ] || fail "리뷰어 DOC_GAP: 재개 stage 가 impl 이 아님"
echo "[OK] 10. 구현 리뷰 루프 계약 연계 검사 (APPROVE / origin / schema_version / 필드 / DOC_GAP)"

# ---------- 11. 범위 밖 변경 원복 — 사용자의 index 상태 보존 (가짜 수정자가 프롬프트가 지시한 명령을 그대로 실행) ----------
# b.txt: 기준선 이전 사용자 unstaged 변경 → 워커가 추가 변경 → 리뷰어 OUT_OF_SCOPE_CHANGE → 수정자가 기준선으로 원복.
# 기대: 내용은 기준선(사용자 변경 유지), git status 는 원복 전과 동일(" M", staged 아님).
printf 'user edit before feature\nworker edit\n' > "$REVIEW_TARGET/src/b.txt"
baseline_tree="$(cat "$REVIEW_TARGET/.agent-work/worker-baseline.tree")"
status_before="$(cd "$REVIEW_TARGET" && git status --porcelain=v1 -- src/b.txt)"
[ "$status_before" = " M src/b.txt" ] || fail "원복 픽스처: b.txt 초기 상태가 unstaged 수정이 아님 ($status_before)"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# 리뷰어 호출: 1회차 REQUEST_CHANGES(OUT_OF_SCOPE_CHANGE), 2회차 APPROVE. 수정자 호출(--permission-mode): 프롬프트가 지시한 원복 명령 실행' \
  'case " $* " in *" --permission-mode "*) prompt="${@: -1}"; tree="$(printf "%s" "$prompt" | sed -n "s/.*기준 tree = \`\([0-9a-f]*\)\`.*/\1/p")"; git restore --source="$tree" --worktree -- src/b.txt; printf "%s\n" "{\"session_id\":\"fake\",\"total_cost_usd\":0,\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}"; exit 0;; esac' \
  'n=$(( $(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1 )); printf "%s" "$n" > "$FAKE_COUNT"' \
  'f="$FAKE_REVIEW"; [ "$n" -ge 2 ] && f="$FAKE_REVIEW2"' \
  'jq -n -c --slurpfile r "$f" '"'"'{structured_output: $r[0], session_id:"fake", total_cost_usd:0, usage:{input_tokens:0,output_tokens:0,cache_read_input_tokens:0,cache_creation_input_tokens:0}}'"'" \
  > "$REVIEW_SIDE/fake-claude-fix"
chmod +x "$REVIEW_SIDE/fake-claude-fix"
printf '%s\n' "$review_issue" | jq -c '{schema_version:6,verdict:"REQUEST_CHANGES",issues:[. + {category:"OUT_OF_SCOPE_CHANGE",code_refs:["src/b.txt:L2-L2"],required_outcome:"이번 작업이 src/b.txt 에 만든 변경이 없어진다"}]}' > "$REVIEW_SIDE/review-oos.json"
printf '{"schema_version":6,"verdict":"APPROVE","issues":[]}\n' > "$REVIEW_SIDE/review-approve.json"
sed -i.sedbak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$REVIEW_SIDE/fake-claude-fix\"|; s/^MAX_IMPL_ROUNDS=.*/MAX_IMPL_ROUNDS=1/" "$REVIEW_SKILL/config.sh" && rm -f "$REVIEW_SKILL/config.sh.sedbak"
: > "$REVIEW_TARGET/.agent-work/decisions.md"
set +e
(cd "$REVIEW_TARGET" && FAKE_COUNT="$REVIEW_SIDE/.fix-calls" FAKE_REVIEW="$REVIEW_SIDE/review-oos.json" FAKE_REVIEW2="$REVIEW_SIDE/review-approve.json" FEATURE_LIVE_TEE=1 \
  bash "$REVIEW_SKILL/scripts/impl-review-loop.sh") > "$REVIEW_SIDE/run-oos.log" 2>&1
oos_rc=$?
set -e
[ "$oos_rc" = 0 ] || { tail -5 "$REVIEW_SIDE/run-oos.log" >&2; fail "원복 루프: Round 2 APPROVE 로 끝나지 않음 (exit $oos_rc)"; }
[ "$(cat "$REVIEW_TARGET/src/b.txt")" = "user edit before feature" ] || fail "원복: b.txt 가 기준선 내용(사용자 변경 유지·워커 변경 제거)이 아님"
status_after="$(cd "$REVIEW_TARGET" && git status --porcelain=v1 -- src/b.txt)"
[ "$status_after" = "$status_before" ] || fail "원복: 수정자가 사용자 파일의 staged/unstaged 상태를 변경함 (전 '$status_before' → 후 '$status_after')"
grep -q 'src/b.txt' "$REVIEW_TARGET/.agent-work/reviews/impl-attempt-"*"/fix-diff-round-02.patch" || fail "원복: 수정 diff 에 b.txt 원복이 기록되지 않음"
echo "[OK] 11. 범위 밖 변경 원복 — 내용은 기준선, index 상태 보존"

# ---------- 11b. 수정자가 index 를 바꾸면 결과 기준으로 중단 (자동 복구 없음) ----------
sed 's|git restore --source="$tree" --worktree -- src/b.txt|git add src/b.txt|' "$REVIEW_SIDE/fake-claude-fix" > "$REVIEW_SIDE/fake-claude-stage"
chmod +x "$REVIEW_SIDE/fake-claude-stage"
sed -i.sedbak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$REVIEW_SIDE/fake-claude-stage\"|" "$REVIEW_SKILL/config.sh" && rm -f "$REVIEW_SKILL/config.sh.sedbak"
printf 'user edit before feature\nworker edit\n' > "$REVIEW_TARGET/src/b.txt"
set +e
(cd "$REVIEW_TARGET" && FAKE_COUNT="$REVIEW_SIDE/.stage-calls" FAKE_REVIEW="$REVIEW_SIDE/review-oos.json" FAKE_REVIEW2="$REVIEW_SIDE/review-approve.json" FEATURE_LIVE_TEE=1 \
  bash "$REVIEW_SKILL/scripts/impl-review-loop.sh") > "$REVIEW_SIDE/run-stage.log" 2>&1
stage_rc=$?
set -e
[ "$stage_rc" = 1 ] || fail "index 검사: 수정자의 git add 가 중단(exit 1)으로 이어지지 않음 (exit $stage_rc)"
grep -q '수정자가 git index 를 변경함' "$REVIEW_SIDE/run-stage.log" || fail "index 검사: 중단 사유가 기록되지 않음"
[ "$(cd "$REVIEW_TARGET" && git status --porcelain=v1 -- src/b.txt)" = "M  src/b.txt" ] || fail "index 검사: 중단 시 index 를 임의로 복구함(자동 복구 금지)"
(cd "$REVIEW_TARGET" && git restore --staged src/b.txt)   # 테스트 정리
echo "[OK] 11b. 수정자 index 변경 → 결과 기준 중단, 자동 복구 없음"

# ---------- 11c. index 변경 + CLI 실패 → CLI 실패보다 index 변경이 먼저 보고됨 (수정자 / 워커) ----------
# 11c-1 수정자: git add 후 exit 7
sed 's|git add src/b.txt;|git add src/b.txt; exit 7;|' "$REVIEW_SIDE/fake-claude-stage" > "$REVIEW_SIDE/fake-claude-stage-fail"
grep -q 'exit 7' "$REVIEW_SIDE/fake-claude-stage-fail" || fail "11c 픽스처: 실패하는 가짜 수정자 생성 실패"
chmod +x "$REVIEW_SIDE/fake-claude-stage-fail"
sed -i.sedbak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$REVIEW_SIDE/fake-claude-stage-fail\"|" "$REVIEW_SKILL/config.sh" && rm -f "$REVIEW_SKILL/config.sh.sedbak"
printf 'user edit before feature\nworker edit\n' > "$REVIEW_TARGET/src/b.txt"
set +e
(cd "$REVIEW_TARGET" && FAKE_COUNT="$REVIEW_SIDE/.stagefail-calls" FAKE_REVIEW="$REVIEW_SIDE/review-oos.json" FAKE_REVIEW2="$REVIEW_SIDE/review-approve.json" FEATURE_LIVE_TEE=1 \
  bash "$REVIEW_SKILL/scripts/impl-review-loop.sh") > "$REVIEW_SIDE/run-stagefail.log" 2>&1
stagefail_rc=$?
set -e
[ "$stagefail_rc" = 1 ] || fail "index 검사(수정자 실패 경로): exit 1 이 아님 ($stagefail_rc)"
grep -q '수정자가 git index 를 변경함' "$REVIEW_SIDE/run-stagefail.log" || fail "index 검사(수정자 실패 경로): CLI 가 실패해도 index 변경이 보고돼야 함"
grep -q 'claude 실행 실패' "$REVIEW_SIDE/run-stagefail.log" && fail "index 검사(수정자 실패 경로): index 변경보다 CLI 실패가 먼저 보고됨"
[ "$(cd "$REVIEW_TARGET" && git status --porcelain=v1 -- src/b.txt)" = "M  src/b.txt" ] || fail "index 검사(수정자 실패 경로): index 를 임의로 복구함"
(cd "$REVIEW_TARGET" && git restore --staged src/b.txt)
# 11c-2 워커: 가짜 codex 가 git add 후 (a) 정상 JSON + exit 0, (b) exit 7. 둘 다 러너가 index 변경으로 중단하고 복구하지 않는다
WIDX_TARGET="$SCRATCH/worker-index"; WIDX_SKILL="$WIDX_TARGET/.claude/skills/feature"; WIDX_SIDE="$SCRATCH/worker-index.side"; mkdir -p "$WIDX_SIDE"
git init -q "$WIDX_TARGET"; bash "$SOURCE_ROOT/install.sh" "$WIDX_TARGET" >/dev/null; chmod -x "$WIDX_TARGET/feature-live"
mkdir -p "$WIDX_TARGET/src" "$WIDX_TARGET/.agent-work/reviews"
printf 'base\n' > "$WIDX_TARGET/src/w.txt"
(cd "$WIDX_TARGET" && git add -A && git -c user.email=t@t -c user.name=t commit -qm base)
for doc in design implementation approach; do printf '# %s\n' "$doc" > "$WIDX_TARGET/.agent-work/$doc.md"; done
for stage in design impl; do printf '{"schema_version":3,"verdict":"PASS","blocking_issues":[]}\n' > "$WIDX_TARGET/.agent-work/reviews/validator-$stage-round-01.json"; done
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'out=""; while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done' \
  'printf "worker edit\n" >> src/w.txt; git add src/w.txt' \
  'printf '\''{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[]}'\'' > "$out"' \
  'exit "${FAKE_WORKER_RC:-0}"' \
  > "$WIDX_SIDE/fake-codex"
chmod +x "$WIDX_SIDE/fake-codex"
sed -i.sedbak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"true\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$WIDX_SIDE/fake-codex\"|; s/^TEST_CMD=.*/TEST_CMD=\"true\"/; s/^LINT_CMD=.*/LINT_CMD=\"true\"/" "$WIDX_SKILL/config.sh" && rm -f "$WIDX_SKILL/config.sh.sedbak"
for worker_rc_case in 0 7; do
  (cd "$WIDX_TARGET" && git restore --staged --worktree src/w.txt)
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > "$WIDX_TARGET/.agent-work/run-state.json"
  set +e
  (cd "$WIDX_TARGET" && FAKE_WORKER_RC="$worker_rc_case" bash "$WIDX_SKILL/scripts/feature-run.sh") > "$WIDX_SIDE/run-$worker_rc_case.log" 2>&1
  widx_rc=$?
  set -e
  [ "$widx_rc" = 1 ] || fail "index 검사(워커, codex exit $worker_rc_case): 러너 종료 코드가 1 이 아님 ($widx_rc)"
  grep -q '워커가 git index 를 변경함' "$WIDX_SIDE/run-$worker_rc_case.log" || fail "index 검사(워커, codex exit $worker_rc_case): index 변경이 보고되지 않음"
  grep -q 'codex 워커 실행 실패' "$WIDX_SIDE/run-$worker_rc_case.log" && fail "index 검사(워커, codex exit $worker_rc_case): index 변경보다 CLI 실패가 먼저 보고됨"
  [ "$(cd "$WIDX_TARGET" && git status --porcelain=v1 -- src/w.txt)" = "M  src/w.txt" ] || fail "index 검사(워커, codex exit $worker_rc_case): index 를 임의로 복구함"
done
# assume-unchanged 플래그 변경도 지문에 잡힌다
idx_a="$(cd "$WIDX_TARGET" && bash -c 'source .claude/skills/feature/config.sh; compute_index_fingerprint')"
(cd "$WIDX_TARGET" && git update-index --assume-unchanged src/w.txt)
idx_b="$(cd "$WIDX_TARGET" && bash -c 'source .claude/skills/feature/config.sh; compute_index_fingerprint')"
(cd "$WIDX_TARGET" && git update-index --no-assume-unchanged src/w.txt)
[ "$idx_a" != "$idx_b" ] || fail "index 지문: assume-unchanged 플래그 변경이 지문에 반영되지 않음"
echo "[OK] 11c. index 변경 + CLI 실패 → index 변경 우선 보고 (수정자·워커), assume-unchanged 감지"

# ---------- 12. 유료 회귀 승인 게이트 (실제 LLM 호출 없음) ----------
GATE_SOURCE="$SCRATCH/gate-source"
cp -R "$SOURCE_ROOT" "$GATE_SOURCE"
rm -f "$GATE_SOURCE/.claude/ALLOW_REAL_LLM_REGRESSION"
for script in reviewer-regression.sh validator-regression.sh; do
  set +e; bash "$GATE_SOURCE/tests/$script" > "$SCRATCH/gate.log" 2>&1; gate_rc=$?; set -e
  [ "$gate_rc" = 3 ] || fail "승인 게이트($script): 허용 파일 없이 exit 3 이 아님 ($gate_rc)"
  grep -q 'ALLOW_REAL_LLM_REGRESSION' "$SCRATCH/gate.log" || fail "승인 게이트($script): 안내 메시지 누락"
done
# 허용 파일이 있으면 게이트를 지나 소모된다 — 실제 호출 전에 CHANGE_ME 검사에서 멈추도록 모델을 비워 둔다
sed -i.sedbak 's/^REVIEWER_MODEL=.*/REVIEWER_MODEL="CHANGE_ME"/' "$GATE_SOURCE/.claude/skills/feature/config.sh" && rm -f "$GATE_SOURCE/.claude/skills/feature/config.sh.sedbak"
touch "$GATE_SOURCE/.claude/ALLOW_REAL_LLM_REGRESSION"
set +e; bash "$GATE_SOURCE/tests/reviewer-regression.sh" > "$SCRATCH/gate.log" 2>&1; gate_rc=$?; set -e
[ "$gate_rc" = 1 ] || fail "승인 게이트: 허용 파일이 있는데 게이트를 통과하지 못함 (exit $gate_rc)"
grep -q 'CHANGE_ME' "$SCRATCH/gate.log" || fail "승인 게이트: 게이트 다음 단계(CHANGE_ME 검사)에 도달하지 않음"
[ ! -f "$GATE_SOURCE/.claude/ALLOW_REAL_LLM_REGRESSION" ] || fail "승인 게이트: 허용 파일이 1회용으로 소모되지 않음"
ls "$GATE_SOURCE/.agent-work"/ALLOW_REAL_LLM_REGRESSION.used.* >/dev/null 2>&1 || fail "승인 게이트: 소모된 허용 파일 기록이 없음"
echo "[OK] 12. 유료 회귀 승인 게이트 (차단 / 1회용 소모)"

echo ""
echo "install.sh 스모크 테스트 전부 통과"
