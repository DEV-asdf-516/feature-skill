#!/usr/bin/env bash
# =============================================================
# 워커 code-spec 충실도 회귀 — 고정 픽스처로 **실제 워커**(config.sh 의 WORKER_MODEL/WORKER_EFFORT, CLI 는 모델 이름 또는 WORKER_CLI)를
# production 호출 경로(scripts/worker-invoke.sh 의 run_worker = feature-run.sh 가 쓰는 그 함수) 그대로 unit 하나당 정확히 1회 돌린다.
#
# 질문은 하나다: 현재 WORKER_MODEL 은 합의된 implementation.md + approach.md(code-spec) 를 그대로 코드로 옮기는가?
#   평가 대상은 워커 하나뿐 — 디자이너·검증자·리뷰어·수정자는 호출하지 않고, 판정에 LLM 을 쓰지 않는다(리뷰어로 채점하지 않는다).
#   흐름: fixture 준비 → 실제 워커 1회 → worker-result.json + 호출 전후 tree → deterministic assertion(expected.json + assert.py) → PASS/FAIL.
#   컴파일·행동 테스트가 통과해도 code-spec(helper 추출·이름·호출 순서·재사용·batch 구조)을 어기면 FAIL 이다.
#
# 사용법:
#   touch .claude/ALLOW_REAL_LLM_REGRESSION        # 유료 실행 1회 승인 (사용자 지시 후에만)
#   bash tests/worker-regression.sh                 # 전 사례
#   bash tests/worker-regression.sh case-05-...     # 사례 하나만
# 비용: 사례당 실제 워커 호출 1회. 워커가 실패하거나 UNDECIDED 를 잘못 내면 그대로 FAIL (재호출·수정자 없음).
# 픽스처: tests/worker-cases/case-*/ — base/(HEAD 커밋: src·run-tests.sh·선택 conventions.md), .agent-work/(합의 완료로 취급하는 문서 +
#   feature-scope.json + implementation-units.json — unit 은 정확히 하나), expected.json, 선택 assert.py(lib/javacheck.py 사용).
# 산출물: <작업 디렉터리>/<case>/ 에 temp 저장소 전체(.agent-work/units/<id>/worker-result.json·worker-before/after.tree·워커 원문 로그·
#   usage.jsonl), run.log, diff.patch, targeted-test.log, assert.log — 실패해도 지우지 않는다.
# =============================================================
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES_DIR="$SOURCE_ROOT/tests/worker-cases"
LIB_DIR="$CASES_DIR/lib"
SRC_CONFIG="$SOURCE_ROOT/.claude/skills/feature/config.sh"

# 사례 이름 인자는 승인 파일을 소모하기 전에 검사한다 (오타·셸 주석 잔재 '#' 로 승인이 낭비되지 않게)
if [ -n "${1:-}" ] && [ ! -f "$CASES_DIR/$1/expected.json" ]; then
  echo "[FAIL] 일치하는 회귀 사례가 없음: $1 (승인 파일은 소모하지 않음). 사용 가능: $(ls -d "$CASES_DIR"/case-* | xargs -n1 basename | tr '\n' ' ')" >&2; exit 1
fi

# ---------- 유료 실행 승인 게이트 ----------
# 이 스크립트는 실제 claude/codex 워커를 부르고 비용이 든다. 사용자가 명시적으로 승인한 실행만 허용한다:
# 사용자 지시 후 `touch .claude/ALLOW_REAL_LLM_REGRESSION` (1회용 — 실행 시 소모). 오케스트레이터가 지시 없이 만들면 안 된다.
APPROVAL_FILE="$SOURCE_ROOT/.claude/ALLOW_REAL_LLM_REGRESSION"
if [ ! -f "$APPROVAL_FILE" ]; then
  echo "[BLOCK] 이 회귀는 실제 워커 모델(claude/codex) 호출과 비용이 발생합니다. 사용자 승인 후 1회용 허용 파일을 만든 뒤 다시 실행: touch $APPROVAL_FILE" >&2
  echo "        워커 호출 0회로 종료합니다." >&2
  exit 3
fi
mkdir -p "$SOURCE_ROOT/.agent-work"
mv "$APPROVAL_FILE" "$SOURCE_ROOT/.agent-work/ALLOW_REAL_LLM_REGRESSION.used.$(date +%s)"   # 한 번 쓴 승인은 재사용하지 않는다

# 대입문만 검사 — config.sh 의 가드 코드 자체에 CHANGE_ME 문자열이 있으므로 전체 grep 은 항상 걸린다
if grep -Eq '^[[:space:]]*(WORKER_MODEL|WORKER_EFFORT|CLAUDE_BIN|CODEX_BIN)=.*CHANGE_ME' "$SRC_CONFIG"; then
  echo "[FAIL] config.sh 의 워커 설정(WORKER_MODEL/WORKER_EFFORT 등) CHANGE_ME 를 먼저 채우세요." >&2; exit 1
fi
# config.sh 를 여기서 source 하지 않는다 — TEST_CMD 등이 CHANGE_ME 면 가드가 exit 1 한다. 헤더 출력용으로 대입문만 읽고,
# 실제 호출은 사례별 temp 저장소에 복사한 config.sh(TEST_CMD/LINT_CMD 만 true) 를 source 해서 production 헬퍼로 한다.
read_assignment() { sed -n "s/^$1=\"\{0,1\}\([^\"#]*\)\"\{0,1\}[[:space:]]*\(#.*\)\{0,1\}$/\1/p" "$SRC_CONFIG" | tail -1 | sed 's/[[:space:]]*$//'; }
WORKER_MODEL_CFG="$(read_assignment WORKER_MODEL)"; WORKER_EFFORT_CFG="$(read_assignment WORKER_EFFORT)"; WORKER_CLI_CFG="$(read_assignment WORKER_CLI)"
CONFIGURED_CLAUDE_BIN="$(read_assignment CLAUDE_BIN)"; CONFIGURED_CODEX_BIN="$(read_assignment CODEX_BIN)"
[ -n "$CONFIGURED_CLAUDE_BIN" ] && [ -n "$CONFIGURED_CODEX_BIN" ] || { echo "[FAIL] config.sh 의 CLAUDE_BIN/CODEX_BIN 대입문을 읽지 못함" >&2; exit 1; }
# 역할 → CLI 는 config.sh 의 role_cli 와 같은 규칙(<ROLE>_CLI 우선, 아니면 모델 이름). source 하지 않으므로 여기서 다시 계산한다.
case "${WORKER_CLI_CFG:-}" in
  claude|codex) WORKER_CLI_KIND="$WORKER_CLI_CFG";;
  *) case "$WORKER_MODEL_CFG" in claude*) WORKER_CLI_KIND=claude;; gpt-*|o[0-9]*|codex*) WORKER_CLI_KIND=codex;;
       *) echo "[FAIL] 모델 '$WORKER_MODEL_CFG'(WORKER) 의 CLI 를 정하지 못함 — config.sh WORKER_CLI 지정" >&2; exit 1;; esac;;
esac
needed_bins=(jq uuidgen envsubst git python3 javac java)
case "$WORKER_CLI_KIND" in claude) needed_bins+=("$CONFIGURED_CLAUDE_BIN");; codex) needed_bins+=("$CONFIGURED_CODEX_BIN");; esac
for bin in "${needed_bins[@]}"; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[FAIL] '$bin' 미설치" >&2; exit 1; }
done
REAL_CLAUDE="$(command -v "$CONFIGURED_CLAUDE_BIN" || true)"
REAL_CODEX="$(command -v "$CONFIGURED_CODEX_BIN" || true)"

# fast/service tier: production 워커 호출(run_edit_role)은 service tier 플래그를 넘기지 않는다. codex 는 자기 전역 설정
# (${CODEX_HOME:-~/.codex}/config.toml 의 service_tier)을 스스로 읽으므로, 여기서는 그 값을 관측해 보고만 한다 — 호출 경로를 복제하지 않는다.
fast_tier_line() {
  local cfg="${CODEX_HOME:-$HOME/.codex}/config.toml" tier=""
  case "$WORKER_CLI_KIND" in
    codex)
      [ -f "$cfg" ] && tier="$(sed -n 's/^[[:space:]]*service_tier[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | tail -1)"
      case "$tier" in
        fast|priority) printf 'enabled (codex config service_tier="%s" — production 호출이 플래그 없이 그대로 상속)' "$tier";;
        "")            printf 'disabled (production 호출에 service tier 플래그 없음; codex config service_tier 미설정)';;
        *)             printf 'disabled (production 호출에 service tier 플래그 없음; codex config service_tier="%s")' "$tier";;
      esac;;
    claude) printf 'disabled (claude 호출 경로에 service tier 옵션 없음)';;
  esac
}
echo "Worker CLI: $WORKER_CLI_KIND ($( [ "$WORKER_CLI_KIND" = claude ] && printf '%s' "$REAL_CLAUDE" || printf '%s' "$REAL_CODEX" ))"
echo "Worker model: $WORKER_MODEL_CFG"
echo "Worker effort: $WORKER_EFFORT_CFG"
echo "Worker fast tier: $(fast_tier_line)"
echo "Worker prompt: prompts/worker-unit.md (production, run_worker 경유) / schema: schemas/worker-result.schema.json"

# 같은 WORKER_REGRESSION_DIR 를 반복 지정해도 이전 실행 산출물이 섞이지 않게 실행마다 하위 디렉터리를 만든다
if [ -n "${WORKER_REGRESSION_DIR:-}" ]; then
  mkdir -p "$WORKER_REGRESSION_DIR"; SCRATCH="$(mktemp -d "$WORKER_REGRESSION_DIR/run.XXXXXX")"
else
  SCRATCH="$(mktemp -d)"
fi
echo "작업 디렉터리: $SCRATCH (temp 저장소·워커 원문 로그·결과 JSON·diff 보존)"

# 실제 CLI 래퍼: Claude Code 세션 안에서 돌릴 때 중첩 실행 차단 변수를 지운다(밖에서는 무해). 인자는 그대로 통과 — 호출 형태를 바꾸지 않는다.
mkdir -p "$SCRATCH/bin"
printf '#!/usr/bin/env bash\nexec env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION "%s" "$@"\n' "$REAL_CLAUDE" > "$SCRATCH/bin/real-claude"
printf '#!/usr/bin/env bash\nexec env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION "%s" "$@"\n' "$REAL_CODEX" > "$SCRATCH/bin/real-codex"
chmod +x "$SCRATCH/bin/real-claude" "$SCRATCH/bin/real-codex"

# ---------- production 워커 stage 전제 + run_worker 1회 (temp 저장소 안에서, subshell) ----------
# feature-run.sh 의 worker stage 가 워커를 부르기 직전까지 하는 일(scope lock → units lock → 기준선 tree → units/<id>/unit.json·scope.json·
# before.tree → implementation-context.json) 을 같은 config.sh 헬퍼로 만든 뒤 run_worker 를 부른다. 그 뒤(targeted test·done.json·review)는 없다.
# 종료 코드는 direct run_worker 의 계약 그대로: 0 DONE / 2 NEED_USER(UNDECIDED — DOC_GAP·USER_DECISION 모두, 범위 위반, 결과 불확실) / 1 ENV_ERROR.
# (상위 feature-run 이 DOC_GAP 을 APPROACH_GAP/NEED_DOCS=exit 3 으로 바꾸는 것은 러너 층의 변환이지 워커 rc 가 아니다.)
invoke_unit_in_target() { # unit-id  (cwd = temp 저장소)
  local id="$1"
  source .claude/skills/feature/config.sh
  SKILL_DIR="$PWD/.claude/skills/feature"
  source "$SKILL_DIR/scripts/worker-invoke.sh"
  log() { echo "[$(date '+%F %T')] [worker-regression] $*"; }
  env_error() { log "ENV_ERROR: $*"; exit 1; }
  stop_need_user() { log "NEED_USER ($1): $2"; exit 2; }
  stop_need_docs() { log "NEED_DOCS ($1): $2"; exit 3; }
  STAGE=worker
  WORKER_RESULT="$WORK_DIR/worker-result.json"
  WORKER_SCHEMA="$SKILL_DIR/schemas/worker-result.schema.json"
  export FEATURE_LIVE_TEE=1
  require_role_bins WORKER jq uuidgen envsubst git || env_error "워커 CLI 확인 실패"
  feature_scope_valid_file "$FEATURE_SCOPE_FILE" || env_error "feature-scope.json 형식 오류"
  lock_feature_scope || env_error "feature-scope.lock.json 확정 실패"
  units_manifest_valid_file "$UNITS_MANIFEST_FILE" || env_error "implementation-units.json 형식 오류"
  local outside; outside="$(units_scope_outside_global "$UNITS_MANIFEST_FILE" "$FEATURE_SCOPE_LOCK")"
  [ -z "$outside" ] || env_error "unit scope 가 feature-scope 밖: $outside"
  lock_units_manifest || env_error "implementation-units.lock.json 확정 실패"
  snapshot_worktree_tree > "$WORK_DIR/worker-baseline.tree.tmp" && mv "$WORK_DIR/worker-baseline.tree.tmp" "$WORK_DIR/worker-baseline.tree" || env_error "기준선 tree 기록 실패"
  local unit_dir="$WORK_DIR/units/$id"; mkdir -p "$unit_dir"
  unit_json "$id" > "$unit_dir/unit.json" || env_error "unit.json 기록 실패"
  jq -e 'type=="object"' "$unit_dir/unit.json" >/dev/null || env_error "unit $id 가 manifest 에 없음"
  jq -c --argjson v "$FEATURE_SCOPE_VERSION" '{version:$v, files:.scope.files, new_file_roots:(.scope.new_file_roots // [])}' "$unit_dir/unit.json" > "$unit_dir/scope.json" || env_error "scope.json 기록 실패"
  feature_scope_valid_file "$unit_dir/scope.json" || env_error "unit scope 형식 오류"
  snapshot_worktree_tree > "$unit_dir/before.tree" || env_error "unit 시작 tree 기록 실패"
  impl_context_write "$id" || env_error "implementation-context.json 재구성 실패"
  log "=== unit $id : fresh 워커 — WORKER $(role_cli WORKER) $WORKER_MODEL/$WORKER_EFFORT — scope $(jq -c '{files:(.files|length), roots:(.new_file_roots|length)}' "$unit_dir/scope.json") ==="
  RUN_TAG=worker run_worker worker-unit.md "$unit_dir"
  log "워커 DONE (unit $id)"
}

pass=0; fail=0; selected=0; failed_cases=()
mark_fail() { echo "  [FAIL] $1"; fail=$((fail + 1)); failed_cases+=("$name"); }
: > "$SCRATCH/usage.jsonl"
: > "$SCRATCH/durations.tsv"

for case_dir in "$CASES_DIR"/case-*/; do
  case_dir="${case_dir%/}"; name="$(basename "$case_dir")"
  [ -z "${1:-}" ] || [ "$1" = "$name" ] || continue
  selected=$((selected + 1))
  expected="$case_dir/expected.json"
  expected_status="$(jq -r '.expected_status' "$expected")"
  expected_exit="$(jq -r '.expected_exit' "$expected")"
  target="$SCRATCH/$name"; mkdir -p "$target"; git -C "$target" init -q
  bash "$SOURCE_ROOT/install.sh" "$target" >/dev/null
  cfg="$target/.claude/skills/feature/config.sh"
  cp "$SRC_CONFIG" "$cfg"   # 실제 워커 설정 그대로 — TEST_CMD/LINT_CMD 와 CLI 실행 파일(래퍼)만 바꾼다
  sed -i.bak "s/^TEST_CMD=.*/TEST_CMD=\"true\"/; s/^LINT_CMD=.*/LINT_CMD=\"true\"/; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$SCRATCH/bin/real-claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$SCRATCH/bin/real-codex\"|" "$cfg"
  rm -f "$cfg.bak"
  cp -R "$case_dir/base/." "$target/"
  (cd "$target" && git add -A && git -c user.email=t@t -c user.name=t commit -qm fixture)
  mkdir -p "$target/.agent-work"
  cp "$case_dir/.agent-work/"* "$target/.agent-work/"
  : > "$target/.agent-work/decisions.md"
  unit_count="$(jq '.units|length' "$target/.agent-work/implementation-units.json")"
  if [ "$unit_count" != 1 ]; then mark_fail "픽스처 오류: unit 은 정확히 하나여야 함 ($unit_count)"; continue; fi
  unit_id="$(jq -r '.units[0].id' "$target/.agent-work/implementation-units.json")"
  targeted_test="$(jq -r '.units[0].targeted_test' "$target/.agent-work/implementation-units.json")"
  unit_dir="$target/.agent-work/units/$unit_id"

  echo "=== $name (기대 $expected_status, unit $unit_id) ==="
  t0="$(date +%s)"
  set +e
  (cd "$target" && invoke_unit_in_target "$unit_id") > "$target.run.log" 2>&1
  rc=$?
  set -e
  t1="$(date +%s)"; wall=$((t1 - t0))
  printf '%s\t%s\n' "$name" "$wall" >> "$SCRATCH/durations.tsv"
  cp "$target.run.log" "$target/run.log" 2>/dev/null || true
  [ -f "$target/.agent-work/usage.jsonl" ] && jq -c --arg case "$name" '. + {regression_case:$case}' "$target/.agent-work/usage.jsonl" >> "$SCRATCH/usage.jsonl"
  result="$unit_dir/worker-result.json"
  before_tree=""; after_tree=""
  [ -f "$unit_dir/worker-before.tree" ] && before_tree="$(cat "$unit_dir/worker-before.tree")"
  [ -f "$unit_dir/worker-after.tree" ] && after_tree="$(cat "$unit_dir/worker-after.tree")"
  if [ -n "$before_tree" ] && [ -n "$after_tree" ]; then
    git -C "$target" diff-tree -p "$before_tree" "$after_tree" > "$target/diff.patch" || true
    git -C "$target" diff-tree -r --name-status "$before_tree" "$after_tree" > "$target/changed-files.txt" || true
  fi

  failures=()
  # 1) 종료 코드·status — 워커 실패(exit 1)·범위 위반(exit 2)·기대와 다른 status 는 그대로 FAIL. 재호출·수정자 없음.
  actual_status="$(jq -r '.status // "NONE"' "$result" 2>/dev/null || echo NONE)"
  if [ "$rc" != "$expected_exit" ] || [ "$actual_status" != "$expected_status" ]; then
    failures+=("expected exit=$expected_exit status=$expected_status / actual exit=$rc status=$actual_status — $target/run.log")
  fi
  # 2) undecided kind
  for kind in $(jq -r '.undecided_kinds[]?' "$expected"); do
    jq -e --arg k "$kind" 'any(.undecided[]?; .kind==$k)' "$result" >/dev/null 2>&1 || failures+=("undecided 에 kind=$kind 없음: $(jq -c '[.undecided[]?.kind]' "$result" 2>/dev/null || echo '결과 없음')")
  done
  # 3) 신규 파일은 허용 목록 안에서만 (호출 전후 tree 의 A 상태 경로)
  if [ -f "$target/changed-files.txt" ]; then
    added="$(awk -F'\t' '$1 ~ /^A/ {print $NF}' "$target/changed-files.txt" | sort)"
    allowed="$(jq -r '.allowed_new_files[]?' "$expected" | sort)"
    extra="$(comm -23 <(printf '%s\n' "$added" | sed '/^$/d') <(printf '%s\n' "$allowed" | sed '/^$/d') || true)"
    [ -z "$extra" ] || failures+=("허용되지 않은 신규 파일: $(printf '%s' "$extra" | paste -sd, -)")
  fi
  # 4) 파일 존재/부재
  for f in $(jq -r '.files_must_exist[]?' "$expected"); do [ -f "$target/$f" ] || failures+=("파일 없음: $f"); done
  for f in $(jq -r '.files_must_not_exist[]?' "$expected"); do [ ! -e "$target/$f" ] || failures+=("존재하면 안 되는 파일: $f"); done
  # 5) 정규식 포함/미포함 (파일 원문 기준)
  # 항목마다 두 줄(파일, 정규식)로 읽는다 — @tsv 는 정규식의 백슬래시를 이중 이스케이프한다
  while IFS= read -r f && IFS= read -r pat; do
    [ -n "$f" ] || continue
    if [ ! -f "$target/$f" ] || ! grep -Eq -- "$pat" "$target/$f"; then failures+=("$f 에 /$pat/ 없음"); fi
  done < <(jq -r '.must_contain // {} | to_entries[] | .key as $f | .value[] | $f, .' "$expected")
  while IFS= read -r f && IFS= read -r pat; do
    [ -n "$f" ] || continue
    if [ -f "$target/$f" ] && grep -Eq -- "$pat" "$target/$f"; then failures+=("$f 에 /$pat/ 존재 (금지): $(grep -En -- "$pat" "$target/$f" | head -2 | paste -sd';' -)"); fi
  done < <(jq -r '.must_not_contain // {} | to_entries[] | .key as $f | .value[] | $f, .' "$expected")
  # 6) DONE 사례: unit 의 targeted_test(컴파일 + 행동 테스트). 통과해도 code-spec 위반이면 아래 assert 가 FAIL — 컴파일 성공은 판정이 아니다.
  if [ "$expected_status" = DONE ] && [ "$(jq -r '.run_targeted_test // true' "$expected")" = true ] && [ "$actual_status" = DONE ]; then
    set +e; (cd "$target" && bash -c "$targeted_test") > "$target/targeted-test.log" 2>&1; trc=$?; set -e
    [ "$trc" -eq 0 ] || failures+=("targeted test 실패 (exit $trc): $targeted_test — $target/targeted-test.log")
  fi
  # 7) 사례별 구조 assertion (Python, LLM 없음)
  if [ -f "$case_dir/assert.py" ]; then
    set +e; PYTHONPATH="$LIB_DIR" python3 "$case_dir/assert.py" "$target" "$result" > "$target/assert.log" 2>&1; arc=$?; set -e
    if [ "$arc" -ne 0 ]; then
      while IFS= read -r line; do failures+=("${line#  \[ASSERT FAIL\] }"); done < <(grep '^  \[ASSERT FAIL\]' "$target/assert.log" || true)
      grep -q '^  \[ASSERT FAIL\]' "$target/assert.log" || failures+=("assert.py 실행 오류 (exit $arc) — $target/assert.log")
    fi
  fi

  if [ "${#failures[@]}" -eq 0 ]; then
    echo "  [OK]  (${wall}s)"; pass=$((pass + 1))
  else
    mark_fail "${failures[0]}"
    for ((i = 1; i < ${#failures[@]}; i++)); do echo "         ${failures[$i]}"; done
    echo "         actual: status=$actual_status exit=$rc undecided=$(jq -c '[.undecided[]? | {kind,location}]' "$result" 2>/dev/null || echo '결과 없음')"
    [ -f "$target/diff.patch" ] && echo "         diff: $target/diff.patch"
    echo "         repo: $target (run.log, .agent-work/units/$unit_id/worker-*.log, worker-result.json)"
  fi
done
if [ "$selected" -eq 0 ]; then
  echo "[FAIL] 일치하는 회귀 사례가 없음: ${1:-$CASES_DIR/case-*}" >&2; exit 1
fi

# ---------- usage (production usage.jsonl 재사용 — 새 telemetry 없음) ----------
echo; echo "usage ($SCRATCH/usage.jsonl — 각 temp 저장소의 .agent-work/usage.jsonl 을 모은 것):"
if [ -s "$SCRATCH/usage.jsonl" ]; then
  jq -r '"  \(.regression_case): \(.cli) \(.model) exit=\(.exit_code) tokens_total=\(.tokens_total // "n/a") input_effective=\(.input_effective // "n/a") output=\(.output // "n/a") cost_usd=\(.cost_usd // "n/a") duration_ms=\(.duration_ms // "n/a")"' "$SCRATCH/usage.jsonl"
  jq -s -r '"  합계: invocations=\(length) tokens_total(codex)=\(map(select(.cli=="codex") | .tokens_total // 0) | add) input_effective(claude)=\(map(.input_effective // 0) | add) output(claude)=\(map(.output // 0) | add) cost_usd(보고된 행만)=\(map(.cost_usd // 0) | add) cost_unknown_invocations=\(map(select(.cost_usd == null)) | length)"' "$SCRATCH/usage.jsonl"
else
  echo "  (usage 행 없음 — 워커 CLI 가 telemetry 를 남기지 않았거나 호출 전에 실패)"
fi
echo "  wall-clock(초, 워커 호출 + 사후 게이트):"; awk -F'\t' '{printf "    %s: %ss\n", $1, $2}' "$SCRATCH/durations.tsv"

echo; echo "통과 $pass / 실패 $fail"
[ "$fail" -eq 0 ] || { printf '  - %s\n' "${failed_cases[@]}"; echo "실패 사례의 temp 저장소·워커 로그·결과 JSON: $SCRATCH/<case>/"; exit 1; }
