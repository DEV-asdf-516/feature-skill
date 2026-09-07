#!/usr/bin/env bash
# =============================================================
# 스모크: 다른 세션의 변경을 피처 파이프라인이 원복하지 않는가 (실제 LLM 호출 없음, mock claude)
# 파일 경로: tests/smoke-foreign-change.sh
# 사용법: bash tests/smoke-foreign-change.sh   (어디서든 실행 가능, 임시 저장소를 만든다)
#
# 재현 사례 (2026-09-04 사고):
#   기준선: src/feature.txt, src/foreign.txt
#   기준선 기록 후: 워커 역할이 src/feature.txt 수정, 다른 세션 역할이 src/foreign.txt 수정
#   리뷰어: OUT_OF_SCOPE_CHANGE(src/foreign.txt) 반환
# 기대:
#   루프 exit 2 / 상태 FOREIGN_WORKTREE_CHANGE / 수정자 호출 0회
#   src/foreign.txt · src/feature.txt 내용 그대로 / git index 불변
#   리뷰어에게 간 diff 가 실제로 캡처됐고, src/feature.txt 는 있고 src/foreign.txt 는 없다 (feature-scope.json 범위 한정)
# 추가 사례:
#   2. 수정자가 범위 밖 파일을 쓰면 SCOPE_VIOLATION 으로 중단하고 그 내용도 원복하지 않는다
#   3. 범위 밖 외부 변경은 승인을 유지한다 / 범위 안 내용 변경·실행 권한 변경은 승인을 무효화한다 (양방향)
#   4. 범위 밖 파일을 범위 안 경로로 rename 해도 출발지가 위반으로 잡힌다 (--no-renames)
#   5. manifest 가 있는데 잘못됐으면 전체 트리 지문으로 조용히 돌아가지 않고 실패한다
#   8. 수정자가 manifest(원본·lock)를 넓혀 범위 밖 파일을 수정하면 SCOPE_MANIFEST_CHANGED — 원복 없음, 리뷰어 재호출 없음
#   9. new_file_roots 아래 기준선에 있던 파일 수정은 위반, 새 파일 생성은 허용. 승인 지문도 기준선에 있던 root 파일은 제외
#  10. 이전 호출이 roots 아래 만든 파일을 다음 호출(수정자·worker-fix)이 수정 → 위반 아님 (소유 분류는 기준선 기준)
#  11. APPROVE 후 lock 은 그대로 두고 원본 manifest 만 바뀜 → 승인 지문 실패, 승인 재사용 불가, 모델 호출 0
#  12. 피처가 만든 root 파일의 삭제(D)·symlink 화(T) 는 위반 (허용은 A/M 만)
#  13. 수정자가 worker-baseline.tree 를 빈 tree 로 바꾸고 root 아래 기존 파일 수정 → SCOPE_BASELINE_CHANGED, 원복 없음
#  14. 수정자가 기준선과 manifest 를 함께 바꿈 → SCOPE_MANIFEST_CHANGED 로 먼저 멈춰도 가드 기록, manifest 만 복구한 재실행은 재중단
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-foreign-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

# --- 임시 저장소: 스킬 복사 + CHANGE_ME 채움 ---
mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
sed -i.bak 's/^TEST_CMD="CHANGE_ME"/TEST_CMD="true"/; s/^LINT_CMD="CHANGE_ME"/LINT_CMD="true"/' "$TMP/repo/.claude/skills/feature/config.sh"
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && echo "feature base" > src/feature.txt && echo "foreign base" > src/foreign.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work
printf '{"version":1,"files":["src/feature.txt"],"new_file_roots":["src/owned/"]}' > .agent-work/feature-scope.json

# --- mock claude: --tools 가 있으면 리뷰어, 아니면 수정자 ---
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
is_reviewer=0; for a in "$@"; do [ "$a" = "--tools" ] && is_reviewer=1; done
if [ "$is_reviewer" = 1 ]; then
  echo reviewer >> "$MOCK_LOG"
  d=$(printf '%s\n' "$@" | grep -o '\.agent-work/reviews/[^ ]*diff-round-[0-9]*\.patch' | head -1)
  [ -n "$d" ] && cp "$d" "$MOCK_LOG.diff"
  case "${MOCK_REVIEW:-FOREIGN}" in
    APPROVE) printf '{"structured_output":{"schema_version":%s,"verdict":"APPROVE","issues":[]},"usage":{}}' "$MOCK_SCHEMA";;
    FIX) printf '{"structured_output":{"schema_version":%s,"verdict":"REQUEST_CHANGES","issues":[{"id":"I-001","action":"FIX_CODE","category":"REACHABLE_BUG","evidence_type":"REACHABLE_FAILURE","basis_refs":[],"code_refs":["src/feature.txt:1"],"reachable_scenario":"s","impact":"i","why_blocks_now":"w","required_outcome":"r","origin":"ROUND_1","previous_issue_id":"","fix_ref":""}]},"usage":{}}' "$MOCK_SCHEMA";;
    *) printf '{"structured_output":{"schema_version":%s,"verdict":"REQUEST_CHANGES","issues":[{"id":"I-001","action":"FIX_CODE","category":"OUT_OF_SCOPE_CHANGE","evidence_type":"DIRECT_MISMATCH","basis_refs":["implementation.md:1"],"code_refs":["src/foreign.txt:1"],"reachable_scenario":"","impact":"i","why_blocks_now":"w","required_outcome":"src/foreign.txt 의 변경이 범위 밖","origin":"ROUND_1","previous_issue_id":"","fix_ref":""}]},"usage":{}}' "$MOCK_SCHEMA";;
  esac
else
  echo fixer >> "$MOCK_LOG"
  [ "${MOCK_FIX_OUTSIDE:-0}" = 1 ] && echo "fixer wrote outside" >> src/foreign.txt
  if [ "${MOCK_FIX_RENAME:-0}" = 1 ]; then mkdir -p src/owned && mv src/foreign.txt src/owned/foreign.txt; fi
  if [ "${MOCK_FIX_BROADEN:-0}" = 1 ]; then
    # manifest 를 넓혀 범위 밖 파일을 범위 안으로 만든 뒤 그 파일을 수정 — 우회 시도
    for m in .agent-work/feature-scope.json .agent-work/feature-scope.lock.json; do
      [ -f "$m" ] && jq -c '.files += ["src/foreign.txt"]' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
    done
    echo "fixer broadened scope" >> src/foreign.txt
  fi
  if [ "${MOCK_FIX_TAMPER_BASELINE:-0}" = 1 ]; then
    # 소유권 기준선을 빈 tree 로 바꿔 roots 아래 기존 파일을 '피처가 만든 것'으로 보이게 한 뒤 수정 — 우회 시도
    printf '%s\n' 4b825dc642cb6eb9a060e54bf8d69288fbee4904 > .agent-work/worker-baseline.tree
    echo "tampered by fixer" >> src/owned/existing.txt
  fi
  if [ "${MOCK_FIX_TAMPER_BOTH:-0}" = 1 ]; then
    printf '%s\n' 4b825dc642cb6eb9a060e54bf8d69288fbee4904 > .agent-work/worker-baseline.tree
    for m in .agent-work/feature-scope.json .agent-work/feature-scope.lock.json; do
      [ -f "$m" ] && jq -c '.files += ["src/foreign.txt"]' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
    done
    echo "tampered by fixer (both)" >> src/owned/existing.txt
  fi
  echo "fixed" >> src/feature.txt; echo "- [fix round] I-001 ACCEPT" >> .agent-work/decisions.md
  printf '{"result":"ok","usage":{}}'
fi
EOF
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH" MOCK_LOG="$TMP/calls.log" FEATURE_LIVE_TEE=1
MOCK_SCHEMA="$(grep -E '^REVIEWER_CONTRACT_VERSION=' .claude/skills/feature/config.sh | cut -d= -f2 | cut -d' ' -f1)"; export MOCK_SCHEMA
LOOP=".claude/skills/feature/scripts/impl-review-loop.sh"
CFG="./.claude/skills/feature/config.sh"
index_hash() { git ls-files --stage -v -z | shasum -a 256; }
approval_ok() { ( source "$CFG"; verify_approved_fingerprint >/dev/null 2>&1 ); }
BL() { cat .agent-work/worker-baseline.tree; }   # 러너·루프가 호출 전에 읽어 넘기는 소유권 기준선
viol() { ( source "$CFG"; feature_scope_violations "$1" "$2" "$(BL)" | paste -sd, - ); }

# --- 기준선 기록 (러너가 worker 진입 직전 하는 것과 동일) ---
( source "$CFG"; snapshot_worktree_tree > .agent-work/worker-baseline.tree ) || fail "기준선 tree 기록 실패"

# --- 기준선 이후: 워커 역할 / 다른 세션 역할 변경 ---
echo "worker change" >> src/feature.txt
echo "other session change" >> src/foreign.txt
cp src/foreign.txt "$TMP/foreign.expected"; cp src/feature.txt "$TMP/feature.expected"
index_before="$(index_hash)"

# ===== 사례 1: 리뷰어 OUT_OF_SCOPE_CHANGE → 수정자 미호출, 보존, diff 범위 한정 =====
: > "$MOCK_LOG"; rm -f "$MOCK_LOG.diff"
MOCK_REVIEW=FOREIGN bash "$LOOP" >"$TMP/case1.log" 2>&1; rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/case1.log"; fail "사례1: exit 2 기대, 실제 $rc"; }
[ "$(jq -r .status .agent-work/state.json)" = FOREIGN_WORKTREE_CHANGE ] || fail "사례1: 상태 FOREIGN_WORKTREE_CHANGE 기대, 실제 $(jq -r .status .agent-work/state.json)"
fixer_calls="$(grep -c '^fixer$' "$MOCK_LOG")"
[ "$fixer_calls" -eq 0 ] || fail "사례1: 범위 밖 변경인데 수정자가 호출됨 ($fixer_calls 회)"
cmp -s "$TMP/foreign.expected" src/foreign.txt || fail "사례1: 다른 세션 작업(src/foreign.txt)이 변경됨"
cmp -s "$TMP/feature.expected" src/feature.txt || fail "사례1: 피처 파일(src/feature.txt)이 변경됨"
[ "$(index_hash)" = "$index_before" ] || fail "사례1: git index 가 변경됨"
[ -f "$MOCK_LOG.diff" ] || fail "사례1: 리뷰어에게 전달된 diff 를 캡처하지 못함"
grep -q 'src/feature.txt' "$MOCK_LOG.diff" || fail "사례1: 리뷰어 diff 에 피처 파일이 없음"
if grep -q 'src/foreign.txt' "$MOCK_LOG.diff"; then fail "사례1: 리뷰어 diff 에 범위 밖 파일이 포함됨"; fi
pass "사례1: OUT_OF_SCOPE_CHANGE → FOREIGN_WORKTREE_CHANGE, 수정자 0회, 두 파일·index 보존, diff 캡처됨(feature 있음/foreign 없음)"

# ===== 사례 2: 수정자가 범위 밖 파일을 쓰면 SCOPE_VIOLATION, 그 내용도 원복 없음 =====
: > "$MOCK_LOG"
MOCK_REVIEW=FIX MOCK_FIX_OUTSIDE=1 bash "$LOOP" >"$TMP/case2.log" 2>&1; rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/case2.log"; fail "사례2: exit 2 기대, 실제 $rc"; }
[ "$(jq -r .status .agent-work/state.json)" = SCOPE_VIOLATION ] || fail "사례2: 상태 SCOPE_VIOLATION 기대, 실제 $(jq -r .status .agent-work/state.json)"
[ "$(jq -r .files .agent-work/state.json)" = "src/foreign.txt" ] || fail "사례2: 위반 파일 목록이 src/foreign.txt 가 아님: $(jq -r .files .agent-work/state.json)"
[ "$(tail -1 src/foreign.txt)" = "fixer wrote outside" ] || fail "사례2: 범위 밖 변경이 원복됨(보존돼야 함)"
[ "$(index_hash)" = "$index_before" ] || fail "사례2: git index 가 변경됨"
pass "사례2: 수정자 범위 밖 쓰기 → SCOPE_VIOLATION, 원복 없이 보존, index 불변"

# ===== 사례 3: 승인 지문 양방향 — 범위 밖 변경은 유지, 범위 안 내용·권한 변경은 무효 =====
: > "$MOCK_LOG"
MOCK_REVIEW=APPROVE bash "$LOOP" >"$TMP/case3.log" 2>&1 || { cat "$TMP/case3.log"; fail "사례3: APPROVE 실패"; }
echo "another external edit" >> src/foreign.txt
approval_ok || fail "사례3: 범위 밖 변경으로 승인이 무효화됨"
: > "$MOCK_LOG"; bash "$LOOP" >"$TMP/case3b.log" 2>&1 || fail "사례3: 승인 재사용 실패"
[ "$(wc -l < "$MOCK_LOG" | tr -d ' ')" -eq 0 ] || fail "사례3: 승인 재사용인데 모델이 호출됨"
# 음성 대조군 1: 범위 안 내용 변경
cp src/feature.txt "$TMP/feature.approved"
echo "post-approval edit" >> src/feature.txt
approval_ok && fail "사례3: 범위 안 내용 변경인데 승인이 유지됨"
cp "$TMP/feature.approved" src/feature.txt
approval_ok || fail "사례3: 내용을 되돌렸는데 승인이 복구되지 않음"
# 음성 대조군 2: 실행 권한 변경 (내용 동일)
chmod +x src/feature.txt
approval_ok && fail "사례3: 범위 안 실행 권한 변경인데 승인이 유지됨"
chmod -x src/feature.txt
approval_ok || fail "사례3: 권한을 되돌렸는데 승인이 복구되지 않음"
# 음성 대조군 3: 범위 정의 자체 변경
cp .agent-work/feature-scope.json "$TMP/scope.approved"
printf '{"version":1,"files":["src/feature.txt","src/foreign.txt"],"new_file_roots":["src/owned/"]}' > .agent-work/feature-scope.json
approval_ok && fail "사례3: 범위 정의가 바뀌었는데 승인이 유지됨"
cp "$TMP/scope.approved" .agent-work/feature-scope.json
pass "사례3: 범위 밖 변경 → 승인 유지·재사용(모델 0회) / 범위 안 내용·실행 권한·범위 정의 변경 → 승인 무효"

# ===== 사례 4: 범위 밖 파일을 범위 안 경로로 rename → 출발지 삭제가 위반으로 잡힌다 =====
echo "new worker change" >> src/feature.txt   # 사례 3 의 승인을 무효화해 새 리뷰가 돌게 한다
: > "$MOCK_LOG"
MOCK_REVIEW=FIX MOCK_FIX_RENAME=1 bash "$LOOP" >"$TMP/case4.log" 2>&1; rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/case4.log"; fail "사례4: exit 2 기대, 실제 $rc"; }
[ "$(jq -r .status .agent-work/state.json)" = SCOPE_VIOLATION ] || fail "사례4: 상태 SCOPE_VIOLATION 기대, 실제 $(jq -r .status .agent-work/state.json)"
case ",$(jq -r .files .agent-work/state.json)," in *,src/foreign.txt,*) ;; *) fail "사례4: rename 출발지 src/foreign.txt 가 위반 목록에 없음: $(jq -r .files .agent-work/state.json)";; esac
[ -f src/owned/foreign.txt ] || fail "사례4: rename 결과가 원복됨(보존돼야 함)"
[ ! -e src/foreign.txt ] || fail "사례4: rename 출발지가 되살아남(원복 금지)"
[ "$(index_hash)" = "$index_before" ] || fail "사례4: git index 가 변경됨"
pass "사례4: 범위 밖→범위 안 rename → SCOPE_VIOLATION(출발지 포함), 원복 없음"
mv src/owned/foreign.txt src/foreign.txt   # 다음 사례를 위해 시험 환경만 되돌린다(파이프라인 동작 아님)

# ===== 사례 5: manifest 가 있는데 잘못됐으면 전체 트리 지문으로 조용히 돌아가지 않는다 =====
cp .agent-work/feature-scope.json "$TMP/scope.valid"
printf '{"version":1,"files":[]}' > .agent-work/feature-scope.json
if ( source "$CFG"; compute_approval_fingerprint >/dev/null 2>"$TMP/case5.err" ); then fail "사례5: 잘못된 manifest 인데 지문 계산이 성공함(전체 트리 fallback)"; fi
grep -q "유효하지 않은 feature-scope.json" "$TMP/case5.err" || fail "사례5: 실패 사유 메시지 없음"
: > "$MOCK_LOG"
MOCK_REVIEW=APPROVE bash "$LOOP" >"$TMP/case5.log" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/case5.log"; fail "사례5: 리뷰 루프가 잘못된 manifest 로 진행됨 (exit $rc, 1 기대)"; }
[ "$(grep -c '^reviewer$' "$MOCK_LOG")" -eq 0 ] || fail "사례5: 잘못된 manifest 인데 리뷰어가 호출됨"
cp "$TMP/scope.valid" .agent-work/feature-scope.json
pass "사례5: 잘못된 manifest → 지문 계산 실패 + 리뷰 루프 exit 1, 모델 호출 0"

# ===== 사례 6: manifest 계약 — roots 만 있는 피처는 유효, 비-canonical 경로는 무효 =====
scope_ok() { ( source "$CFG"; feature_scope_valid ); }
printf '{"version":1,"files":[],"new_file_roots":["src/owned/"]}' > .agent-work/feature-scope.json
scope_ok || fail "사례6: files=[] + new_file_roots 1개가 유효하지 않음"
printf '{"version":1,"files":[],"new_file_roots":["src/owned"]}' > .agent-work/feature-scope.json
scope_ok || fail "사례6: 후행 / 없는 root 가 유효하지 않음"
printf '{"version":1,"files":["./src/feature.txt"]}' > .agent-work/feature-scope.json
scope_ok && fail "사례6: 선행 ./ 경로가 유효로 통과함"
printf '{"version":1,"files":["src/feature.txt/"]}' > .agent-work/feature-scope.json
scope_ok && fail "사례6: 후행 / 파일 경로가 유효로 통과함"
printf '{"version":1,"files":["src//feature.txt"]}' > .agent-work/feature-scope.json
scope_ok && fail "사례6: 빈 세그먼트 경로가 유효로 통과함"
printf '{"version":1,"files":["src/../feature.txt"]}' > .agent-work/feature-scope.json
scope_ok && fail "사례6: .. 세그먼트 경로가 유효로 통과함"
printf '{"version":1,"files":[],"new_file_roots":[]}' > .agent-work/feature-scope.json
scope_ok && fail "사례6: files 와 roots 가 모두 비었는데 유효로 통과함"
cp "$TMP/scope.valid" .agent-work/feature-scope.json
pass "사례6: roots-only manifest 유효 / 선행 ./ · 후행 / · 빈·.. 세그먼트 · 전부 빈 manifest 무효"

# ===== 사례 7: 워커 프롬프트에 ponytail 이 실제로 주입된다 (vendored 사본 경로 포함) =====
worker_rules="$(bash -c 'source "$1"; load_worker_rules' _ "$CFG")" || fail "사례7: load_worker_rules 실패"
echo "$worker_rules" | grep -q '\[WORKER SKILL: ponytail\]' || fail "사례7: ponytail 이 워커 프롬프트에 주입되지 않음"
echo "$worker_rules" | grep -q 'DELEGATED 결정과 로컬 구현 방식에만' || fail "사례7: ponytail 어댑터 블록 없음"
pass "사례7: ponytail 워커 프롬프트 주입 (worker-skills/ vendored 사본)"

# ===== 사례 8: 수정자가 manifest 를 넓혀 범위 우회 → SCOPE_MANIFEST_CHANGED, 원복 없음 =====
echo "new worker change 2" >> src/feature.txt      # 직전 승인 무효화
cp .agent-work/feature-scope.json .agent-work/feature-scope.lock.json   # 러너가 워커 진입 시 확정하는 lock 을 흉내
cp src/foreign.txt "$TMP/foreign.before8"
: > "$MOCK_LOG"
MOCK_REVIEW=FIX MOCK_FIX_BROADEN=1 bash "$LOOP" >"$TMP/case8.log" 2>&1; rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/case8.log"; fail "사례8: exit 2 기대, 실제 $rc"; }
[ "$(jq -r .status .agent-work/state.json)" = SCOPE_MANIFEST_CHANGED ] || fail "사례8: 상태 SCOPE_MANIFEST_CHANGED 기대, 실제 $(jq -r .status .agent-work/state.json)"
[ "$(grep -c '^reviewer$' "$MOCK_LOG")" -eq 1 ] || fail "사례8: 리뷰어가 1회가 아닌 $(grep -c '^reviewer$' "$MOCK_LOG")회 호출됨 (중단 후 재호출 금지)"
[ "$(tail -1 src/foreign.txt)" = "fixer broadened scope" ] || fail "사례8: 범위 밖 변경이 원복됨(보존돼야 함)"
grep -q 'src/foreign.txt' .agent-work/feature-scope.lock.json || fail "사례8: 넓혀진 manifest 를 파이프라인이 임의로 되돌림(자동 복구 금지)"
[ "$(index_hash)" = "$index_before" ] || fail "사례8: git index 가 변경됨"
# 다음 실행도 lock≠원본이면 진행하지 않는다 (원본만 되돌린 상태)
cp "$TMP/scope.valid" .agent-work/feature-scope.json
: > "$MOCK_LOG"; MOCK_REVIEW=APPROVE bash "$LOOP" >"$TMP/case8b.log" 2>&1; rc=$?
[ "$rc" -eq 2 ] && [ "$(jq -r .status .agent-work/state.json)" = SCOPE_MANIFEST_CHANGED ] || fail "사례8: lock≠원본인데 리뷰 루프가 진행됨 (exit $rc)"
[ "$(wc -l < "$MOCK_LOG" | tr -d ' ')" -eq 0 ] || fail "사례8: lock≠원본인데 모델이 호출됨"
cp "$TMP/scope.valid" .agent-work/feature-scope.lock.json
cp "$TMP/foreign.before8" src/foreign.txt
pass "사례8: manifest 넓히기 → SCOPE_MANIFEST_CHANGED, 원복 없음, 리뷰어 재호출 없음, lock≠원본이면 진행 불가"

# ===== 사례 9: new_file_roots 는 신규 생성만 허용 =====
mkdir -p src/owned && echo "existing" > src/owned/existing.txt
git add src/owned/existing.txt && git -c user.email=smoke@test -c user.name=smoke commit -qm "existing under root"
( source "$CFG"; snapshot_worktree_tree > .agent-work/worker-baseline.tree )   # 기준선에 existing.txt 포함
b="$(source "$CFG"; snapshot_worktree_tree)"
echo "modified" >> src/owned/existing.txt
a="$(source "$CFG"; snapshot_worktree_tree)"
v="$(viol "$b" "$a")"
[ "$v" = "src/owned/existing.txt" ] || fail "사례9: root 아래 기존 파일 수정이 위반으로 잡히지 않음 (violations=[$v])"
git checkout -q -- src/owned/existing.txt 2>/dev/null || { echo "existing" > src/owned/existing.txt; }
b="$(source "$CFG"; snapshot_worktree_tree)"
echo "brand new" > src/owned/new.txt
a="$(source "$CFG"; snapshot_worktree_tree)"
v="$(viol "$b" "$a")"
[ -z "$v" ] || fail "사례9: root 아래 신규 파일 생성이 위반으로 잡힘 (violations=[$v])"
# 승인 지문: 기준선에 있던 root 파일 변경은 지문에 영향 없음, 신규 파일 변경은 영향 있음
fp0="$(source "$CFG"; compute_feature_fingerprint)"
echo "ext" >> src/owned/existing.txt; fp1="$(source "$CFG"; compute_feature_fingerprint)"
[ "$fp0" = "$fp1" ] || fail "사례9: 기준선에 있던 root 파일 변경이 범위 지문을 바꿈"
echo "more" >> src/owned/new.txt; fp2="$(source "$CFG"; compute_feature_fingerprint)"
[ "$fp1" != "$fp2" ] || fail "사례9: root 아래 신규 파일 변경이 범위 지문에 반영되지 않음"
pass "사례9: new_file_roots 아래 기존 파일 수정 → 위반 / 신규 생성 → 허용, 지문은 신규 엔트리만 반영"

# ===== 사례 10: 피처가 만든 root 파일의 후속 라운드 수정은 허용 =====
# (사례 9 의 상태: 기준선에는 src/owned/existing.txt 만 있고 src/owned/new.txt 는 그 뒤에 생성됨)
b="$(source "$CFG"; snapshot_worktree_tree)"
echo "fixer edits the file the worker created" >> src/owned/new.txt
a="$(source "$CFG"; snapshot_worktree_tree)"
v="$(viol "$b" "$a")"
[ -z "$v" ] || fail "사례10: 피처가 만든 root 파일의 후속 수정이 위반으로 잡힘 (violations=[$v])"
b="$a"; echo "again" >> src/owned/existing.txt; a="$(source "$CFG"; snapshot_worktree_tree)"
v="$(viol "$b" "$a")"
[ "$v" = "src/owned/existing.txt" ] || fail "사례10: 대조군 — 기준선 파일 수정이 위반으로 잡히지 않음 (violations=[$v])"
pass "사례10: 이전 호출이 만든 root 파일의 후속 수정 허용 / 기준선 파일 수정은 여전히 위반"

# ===== 사례 11: APPROVE 후 원본 manifest 만 변경 → 승인 무효 =====
git checkout -q -- src/owned/existing.txt 2>/dev/null || true
cp "$TMP/scope.valid" .agent-work/feature-scope.json; cp "$TMP/scope.valid" .agent-work/feature-scope.lock.json
echo "worker change 3" >> src/feature.txt
: > "$MOCK_LOG"
MOCK_REVIEW=APPROVE bash "$LOOP" >"$TMP/case11.log" 2>&1 || { cat "$TMP/case11.log"; fail "사례11: APPROVE 실패"; }
approval_ok || fail "사례11: 원본==lock 인데 승인 지문이 통과하지 않음"
jq -c '.files += ["src/foreign.txt"]' .agent-work/feature-scope.json > "$TMP/scope.widened" && cp "$TMP/scope.widened" .agent-work/feature-scope.json
approval_ok && fail "사례11: 원본 manifest 만 바뀌었는데 승인 지문이 통과함"
( source "$CFG"; verify_approved_fingerprint 2>&1 >/dev/null | grep -q 'SCOPE_MANIFEST_CHANGED' ) || fail "사례11: 실패 사유가 SCOPE_MANIFEST_CHANGED 가 아님"
: > "$MOCK_LOG"; bash "$LOOP" >"$TMP/case11b.log" 2>&1; rc=$?
[ "$rc" -eq 2 ] && [ "$(jq -r .status .agent-work/state.json)" = SCOPE_MANIFEST_CHANGED ] || fail "사례11: 승인 재사용/리뷰 진행이 막히지 않음 (exit $rc)"
[ "$(wc -l < "$MOCK_LOG" | tr -d ' ')" -eq 0 ] || fail "사례11: 모델이 호출됨"
cp "$TMP/scope.valid" .agent-work/feature-scope.json
pass "사례11: APPROVE 후 원본만 변경 → 승인 지문 실패(SCOPE_MANIFEST_CHANGED), 재사용·진행 불가, 모델 호출 0"

# ===== 사례 12: 피처가 만든 root 파일의 삭제·symlink 화는 위반 (허용은 A/M 만) =====
# (상태: 기준선에 src/owned/new.txt 없음, 이전 호출이 생성)
[ -f src/owned/new.txt ] || fail "사례12: 전제 — src/owned/new.txt 가 없음"
cp src/owned/new.txt "$TMP/new.keep"
b="$(source "$CFG"; snapshot_worktree_tree)"
rm -f src/owned/new.txt
a="$(source "$CFG"; snapshot_worktree_tree)"
v="$(viol "$b" "$a")"
[ "$v" = "src/owned/new.txt" ] || fail "사례12: 피처가 만든 root 파일 삭제(D)가 위반으로 잡히지 않음 (violations=[$v])"
cp "$TMP/new.keep" src/owned/new.txt
b="$(source "$CFG"; snapshot_worktree_tree)"
rm -f src/owned/new.txt && ln -s existing.txt src/owned/new.txt
a="$(source "$CFG"; snapshot_worktree_tree)"
v="$(viol "$b" "$a")"
[ "$v" = "src/owned/new.txt" ] || fail "사례12: 피처가 만든 root 파일의 symlink 화(T)가 위반으로 잡히지 않음 (violations=[$v])"
rm -f src/owned/new.txt && cp "$TMP/new.keep" src/owned/new.txt
# 대조군: 같은 파일의 후속 수정(M)은 여전히 허용
b="$(source "$CFG"; snapshot_worktree_tree)"; echo "m" >> src/owned/new.txt; a="$(source "$CFG"; snapshot_worktree_tree)"
v="$(viol "$b" "$a")"
[ -z "$v" ] || fail "사례12: 대조군 — 피처가 만든 root 파일 수정(M)이 위반으로 잡힘 (violations=[$v])"
pass "사례12: 피처가 만든 root 파일 D/T → 위반, M → 허용"

# ===== 사례 13: 수정자가 worker-baseline.tree 를 빈 tree 로 바꾸고 root 아래 기존 파일 수정 =====
cp .agent-work/worker-baseline.tree "$TMP/baseline.keep"
cp src/owned/existing.txt "$TMP/existing.before13"
echo "worker change 4" >> src/feature.txt   # 사례 11 의 승인을 무효화해 새 리뷰(FIX)→수정자가 돌게 한다
index_before13="$(index_hash)"               # 사례 9 가 커밋을 만들었으므로 index 기준을 여기서 다시 잡는다
: > "$MOCK_LOG"
MOCK_REVIEW=FIX MOCK_FIX_TAMPER_BASELINE=1 bash "$LOOP" >"$TMP/case13.log" 2>&1; rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/case13.log"; fail "사례13: exit 2 기대, 실제 $rc"; }
st="$(jq -r .status .agent-work/state.json)"
[ "$st" = SCOPE_BASELINE_CHANGED ] || fail "사례13: 상태 SCOPE_BASELINE_CHANGED 기대, 실제 $st"
[ "$(grep -c '^fixer$' "$MOCK_LOG")" -eq 1 ] || fail "사례13: 수정자 호출 횟수가 1 이 아님"
[ "$(tail -1 src/owned/existing.txt)" = "tampered by fixer" ] || fail "사례13: 수정자의 기존 파일 변경이 원복됨(보존돼야 함)"
[ "$(cat .agent-work/worker-baseline.tree)" = 4b825dc642cb6eb9a060e54bf8d69288fbee4904 ] || fail "사례13: 기준선 파일이 자동 복구됨(복구 금지)"
[ "$(index_hash)" = "$index_before13" ] || fail "사례13: git index 가 변경됨"
[ "$(jq -r .expected .agent-work/worker-baseline.guard.json)" = "$(cat "$TMP/baseline.keep")" ] || fail "사례13: 가드 파일의 기대값이 원래 기준선이 아님"
# 복구 없이 재실행 → 변조된 값을 새 기준선으로 읽지 않고 모델 호출 0회로 다시 중단
: > "$MOCK_LOG"
MOCK_REVIEW=APPROVE bash "$LOOP" >"$TMP/case13b.log" 2>&1; rc=$?
[ "$rc" -eq 2 ] && [ "$(jq -r .status .agent-work/state.json)" = SCOPE_BASELINE_CHANGED ] || fail "사례13: 기준선 미복구 재실행이 막히지 않음 (exit $rc, status $(jq -r .status .agent-work/state.json))"
[ "$(wc -l < "$MOCK_LOG" | tr -d ' ')" -eq 0 ] || fail "사례13: 기준선 미복구 재실행에서 모델이 호출됨"
# 원래 값으로 복구한 뒤에만 재개
cp "$TMP/baseline.keep" .agent-work/worker-baseline.tree
cp "$TMP/existing.before13" src/owned/existing.txt
: > "$MOCK_LOG"
MOCK_REVIEW=APPROVE bash "$LOOP" >"$TMP/case13c.log" 2>&1 || { cat "$TMP/case13c.log"; fail "사례13: 기준선 복구 후 재개 실패"; }
[ "$(grep -c '^reviewer$' "$MOCK_LOG")" -eq 1 ] || fail "사례13: 복구 후 리뷰어가 재개되지 않음"
[ "$(jq -r .active .agent-work/worker-baseline.guard.json)" = false ] || fail "사례13: 복구 후 가드가 비활성화되지 않음"
pass "사례13: 수정자 기준선 조작 → SCOPE_BASELINE_CHANGED, 원복 없음, 미복구 재실행은 모델 0회로 재중단, 복구 후 재개"

# ===== 사례 14: 수정자가 기준선 + manifest 복합 변경 — 앞선 사유로 멈춰도 가드가 남는다 =====
cp .agent-work/worker-baseline.tree "$TMP/baseline.keep14"
cp src/owned/existing.txt "$TMP/existing.before14"
echo "worker change 5" >> src/feature.txt   # 사례 13 의 승인 무효화
: > "$MOCK_LOG"
MOCK_REVIEW=FIX MOCK_FIX_TAMPER_BOTH=1 bash "$LOOP" >"$TMP/case14.log" 2>&1; rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/case14.log"; fail "사례14: exit 2 기대, 실제 $rc"; }
[ "$(jq -r .status .agent-work/state.json)" = SCOPE_MANIFEST_CHANGED ] || fail "사례14: 첫 중단 사유가 SCOPE_MANIFEST_CHANGED 가 아님 ($(jq -r .status .agent-work/state.json))"
[ "$(jq -r .active .agent-work/worker-baseline.guard.json)" = true ] || fail "사례14: manifest 사유로 먼저 멈췄는데 기준선 가드가 기록되지 않음"
[ "$(jq -r .expected .agent-work/worker-baseline.guard.json)" = "$(cat "$TMP/baseline.keep14")" ] || fail "사례14: 가드 기대값이 원래 기준선이 아님"
# manifest 만 복구하고 재실행 → 변조된 기준선을 받아들이지 않는다
cp "$TMP/scope.valid" .agent-work/feature-scope.json; cp "$TMP/scope.valid" .agent-work/feature-scope.lock.json
: > "$MOCK_LOG"
MOCK_REVIEW=APPROVE bash "$LOOP" >"$TMP/case14b.log" 2>&1; rc=$?
[ "$rc" -eq 2 ] && [ "$(jq -r .status .agent-work/state.json)" = SCOPE_BASELINE_CHANGED ] || fail "사례14: manifest 만 복구한 재실행이 막히지 않음 (exit $rc, status $(jq -r .status .agent-work/state.json))"
[ "$(wc -l < "$MOCK_LOG" | tr -d ' ')" -eq 0 ] || fail "사례14: 기준선 미복구 재실행에서 모델이 호출됨"
[ "$(tail -1 src/owned/existing.txt)" = "tampered by fixer (both)" ] || fail "사례14: 수정자 변경이 원복됨(보존돼야 함)"
# 기준선까지 복구하면 재개
cp "$TMP/baseline.keep14" .agent-work/worker-baseline.tree
cp "$TMP/existing.before14" src/owned/existing.txt
: > "$MOCK_LOG"
MOCK_REVIEW=APPROVE bash "$LOOP" >"$TMP/case14c.log" 2>&1 || { cat "$TMP/case14c.log"; fail "사례14: 기준선 복구 후 재개 실패"; }
[ "$(grep -c '^reviewer$' "$MOCK_LOG")" -eq 1 ] || fail "사례14: 복구 후 리뷰어가 재개되지 않음"
pass "사례14: 기준선+manifest 복합 변경 → SCOPE_MANIFEST_CHANGED 로 멈춰도 가드 기록, manifest 만 복구 시 재중단(모델 0회), 전부 복구 후 재개"

echo "[SMOKE] 전부 통과 — 임시 저장소: $TMP (필요 없으면 직접 정리)"
