#!/usr/bin/env bash
# =============================================================
# worker-regression.sh 하네스 회귀 (LLM 호출 없음, 가짜 CLI) — production run_worker 의 DOC_GAP 체크포인트 전제를 하네스가 재현하는가.
#   저장소 사본에 가짜 워커(codex 규약: -o 경로에 worker-result JSON, stdout 에 turn.completed usage 이벤트)와 실패하는 claude 스텁을 고정한 뒤
#   실제 tests/worker-regression.sh 를 그대로 돌린다(승인 파일은 사본 안에서 소모 — 원본 저장소의 승인 게이트는 건드리지 않는다).
#   A. 가짜 DOC_GAP 워커 → case-07 [OK]: run_worker exit 2 · doc-gap-resume.json(WAITING_USER) · 그 밑바탕이 production 이 인정하는 impl consensus PASS
#      (consensus_pass_current impl / impl_docs_accepted / doc_gap_base_consensus_valid — 검증 로직을 복제하지 않고 같은 config.sh 헬퍼로 확인) · 워커 호출 정확히 1회
#   B. 가짜 DONE 워커 → run_worker exit 0 / status DONE (case-07 은 UNDECIDED 기대라 하네스가 그 불일치를 정확히 보고)
#   C. provenance 가드 불변: PASS 리뷰를 BLOCK 으로 바꾸면 같은 헬퍼가 즉시 false — 하네스가 가드를 우회하지 않았다
#   D. usage summary: usage_summary(schema v3) 재사용 — codex 행 reported=null 이어도 estimated/combined 가 0 이 아니고 cost_unknown=0
# =============================================================
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
COPY="$TMP/repo"; mkdir -p "$COPY" "$TMP/bin" "$TMP/state"
fail() { echo "[FAIL] $1" >&2; echo "   작업 디렉터리: $TMP" >&2; exit 1; }
pass() { echo "[OK] $1"; }
for bin in jq uuidgen envsubst git python3 javac java; do command -v "$bin" >/dev/null 2>&1 || fail "'$bin' 미설치"; done

# 저장소 사본 (.git·_workspace·pycache 제외) — 하네스·config·픽스처·프롬프트 전부 현재 작업 트리 그대로
python3 - "$SOURCE_ROOT" "$COPY" <<'PY'
import shutil, sys, os
src, dst = sys.argv[1], sys.argv[2]
def ignore(d, names):
    skip = {n for n in names if n in ('.git', '_workspace', '__pycache__')}
    if os.path.abspath(d) == os.path.abspath(src): skip |= {n for n in names if n == '.agent-work'}   # 픽스처의 .agent-work 는 유지
    return skip
shutil.copytree(src, dst, ignore=ignore, symlinks=True, dirs_exist_ok=True)
PY
git -C "$COPY" init -q

# --- 가짜 워커(codex 규약). FAKE_WORKER_MODE=DONE|DOCGAP. usage 이벤트는 smoke-codex-usage 사례 A 와 같은 값(가격표 모델 gpt-6-luna 로 추정 비용이 계산된다) ---
cat > "$TMP/bin/fake-codex-worker" <<'EOF'
#!/usr/bin/env bash
out=""; while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
[ -n "$out" ] || { echo "no -o" >&2; exit 9; }
echo "worker $FAKE_WORKER_MODE" >> "$FAKE_WORKER_LOG"
printf '{"type":"turn.completed","usage":{"input_tokens":10000,"cached_input_tokens":6000,"cache_write_input_tokens":1000,"output_tokens":500,"reasoning_output_tokens":300}}\n'
case "$FAKE_WORKER_MODE" in
  DONE) printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}\n' > "$out";;
  DOCGAP) printf '{"status":"UNDECIDED","undecided":[{"kind":"DOC_GAP","location":"src/ClientService.java summary","decision_needed":"요약 반환 구조(NEW DTO / record / 기존 타입)가 approach.md 에 없음","options":["NEW ClientSummary record","기존 타입 재사용"]}],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}\n' > "$out";;
  *) echo "unknown mode" >&2; exit 9;;
esac
EOF
# 미사용 CLI 스텁: 어느 역할이든 claude 로 새면 즉시 실패
printf '#!/usr/bin/env bash\necho "claude must not be called" >&2; exit 97\n' > "$TMP/bin/stub-claude"
chmod +x "$TMP/bin/fake-codex-worker" "$TMP/bin/stub-claude"
export FAKE_WORKER_LOG="$TMP/state/worker.log"

CFG="$COPY/.claude/skills/feature/config.sh"
sed -i.bak "s|^WORKER_MODEL=.*|WORKER_MODEL=\"gpt-6-luna\"|; s|^WORKER_CLI=.*|WORKER_CLI=\"codex\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/fake-codex-worker\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/stub-claude\"|" "$CFG"
grep -q "fake-codex-worker" "$CFG" || fail "사본 config.sh 에 가짜 워커 CLI 를 고정하지 못함"

run_harness() { # mode case → stdout 을 $TMP/state/<mode>.out 에, rc 반환
  local mode="$1" case="$2" rc=0
  : > "$FAKE_WORKER_LOG"
  touch "$COPY/.claude/ALLOW_REAL_LLM_REGRESSION"
  set +e
  (cd "$COPY" && FAKE_WORKER_MODE="$mode" WORKER_REGRESSION_DIR="$TMP/wr-$mode" bash tests/worker-regression.sh "$case") > "$TMP/state/$mode.out" 2>&1
  rc=$?
  set -e
  [ ! -f "$COPY/.claude/ALLOW_REAL_LLM_REGRESSION" ] || fail "$mode: 승인 파일이 소모되지 않음"
  return $rc
}
in_cfg() { ( cd "$1" && source .claude/skills/feature/config.sh && "${@:2}" ); }   # 사례 temp 저장소의 production 헬퍼 실행

# ===== A: DOC_GAP → exit 2 + 유효한 provenance 위의 체크포인트 =====
run_harness DOCGAP case-07-doc-gap-no-new-decision || fail "A: 하네스 exit $? — $TMP/state/DOCGAP.out"
grep -q '^  \[OK\]' "$TMP/state/DOCGAP.out" || fail "A: case-07 이 [OK] 가 아님 — $TMP/state/DOCGAP.out"
[ "$(grep -c '^worker DOCGAP$' "$FAKE_WORKER_LOG")" = 1 ] || fail "A: 워커 호출이 정확히 1회가 아님: $(cat "$FAKE_WORKER_LOG")"
T="$(ls -d "$TMP"/wr-DOCGAP/run.*/case-07-doc-gap-no-new-decision)"
grep -q 'NEED_USER (UNDECIDED)' "$T/run.log" || fail "A: run_worker 가 NEED_USER(UNDECIDED)=exit 2 로 끝나지 않음 — $T/run.log"
[ "$(jq -r .next_step "$T/.agent-work/doc-gap-resume.json")" = WAITING_USER ] || fail "A: doc-gap-resume.json 이 WAITING_USER 가 아님"
[ "$(jq -r '.gaps[0].tag' "$T/.agent-work/doc-gap-resume.json")" = "worker-gap=01-summary#1" ] || fail "A: gap tag 불일치: $(jq -c .gaps "$T/.agent-work/doc-gap-resume.json")"
ck="$T/.agent-work/consensus-impl.json"
[ "$(jq -r .next_step "$ck")" = PASS ] && [ "$(jq -r .target "$ck")" = impl ] || fail "A: consensus-impl.json 이 impl PASS 체크포인트가 아님"
[ "$(jq -r .version "$ck")" = "$(grep -E '^CONSENSUS_CHECKPOINT_VERSION=' "$CFG" | cut -d= -f2)" ] || fail "A: 체크포인트 포맷 버전 불일치"
[ "$(jq -r .contract_version "$ck")" = "$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2)" ] || fail "A: 체크포인트 계약 버전 불일치"
review="$(jq -r .review "$ck")"
[ "$review" = ".agent-work/reviews/validator-impl-round-01.json" ] && [ "$(jq -r .verdict "$T/$review")" = PASS ] || fail "A: 체크포인트가 실제 PASS 리뷰를 가리키지 않음: $review"
[ "$(jq -r .base_consensus_review "$T/.agent-work/doc-gap-resume.json")" = "$review" ] || fail "A: doc-gap 체크포인트의 base_consensus_review 가 consensus-impl.json 과 다름"
[ "$(jq -r .base_pass_fingerprint "$T/.agent-work/doc-gap-resume.json")" = "$(jq -r .input_fingerprint "$ck")" ] || fail "A: base_pass_fingerprint 불일치"
[ "$(jq -r .input_fingerprint "$ck")" = "$(in_cfg "$T" consensus_pass_fingerprint impl)" ] || fail "A: PASS 지문이 현재 impl 입력 지문과 다름"
in_cfg "$T" consensus_pass_current impl || fail "A: production consensus_pass_current impl 이 false"
in_cfg "$T" impl_docs_accepted || fail "A: production impl_docs_accepted 가 false"
in_cfg "$T" doc_gap_base_consensus_valid || fail "A: production doc_gap_base_consensus_valid 가 false"
grep -q 'consensus-loop impl 시작' "$T/consensus-setup.log" && ! grep -q 'claude must not be called' "$T/consensus-setup.log" || fail "A: 합의 전제가 production consensus-loop 로 만들어지지 않았거나 claude 로 샘"
pass "A. 가짜 DOC_GAP 워커 → case-07 [OK]: run_worker exit 2, doc-gap-resume.json(WAITING_USER), 밑바탕 consensus-impl.json 이 production 헬퍼가 인정하는 impl PASS(포맷·계약 버전·PASS 리뷰·현재 입력 지문), 워커 호출 1회"

# ===== B: DONE → exit 0 =====
run_harness DONE case-07-doc-gap-no-new-decision && fail "B: DONE 결과인데 UNDECIDED 기대 사례가 통과함"
grep -q 'actual exit=0 status=DONE' "$TMP/state/DONE.out" || fail "B: run_worker 가 exit 0 / DONE 으로 끝나지 않음 — $TMP/state/DONE.out"
[ "$(grep -c '^worker DONE$' "$FAKE_WORKER_LOG")" = 1 ] || fail "B: 워커 호출이 정확히 1회가 아님"
TD="$(ls -d "$TMP"/wr-DONE/run.*/case-07-doc-gap-no-new-decision)"
[ ! -f "$TD/.agent-work/doc-gap-resume.json" ] || fail "B: DONE 인데 doc-gap 체크포인트가 생김"
pass "B. 가짜 DONE 워커 → run_worker exit 0 / status DONE (하네스는 기대 불일치를 정확히 보고)"

# ===== C: provenance 가드 불변 — PASS 리뷰를 위조하면 같은 헬퍼가 false =====
cp "$T/$review" "$T/$review.keep"
jq '.verdict="BLOCK"' "$T/$review.keep" > "$T/$review"
in_cfg "$T" consensus_pass_current impl && fail "C: 리뷰가 BLOCK 인데 consensus_pass_current impl 이 true"
in_cfg "$T" impl_docs_accepted && fail "C: 리뷰가 BLOCK 인데 impl_docs_accepted 가 true"
in_cfg "$T" doc_gap_base_consensus_valid && fail "C: 리뷰가 BLOCK 인데 doc_gap_base_consensus_valid 가 true"
cp "$T/$review.keep" "$T/$review"
printf '\n## 추가\n' >> "$T/.agent-work/implementation.md"
in_cfg "$T" consensus_pass_current impl && fail "C: implementation.md 가 바뀌었는데 impl PASS 지문이 유효함"
pass "C. provenance 가드 불변: 위조 리뷰·바뀐 impl 입력에서 consensus_pass_current / impl_docs_accepted / doc_gap_base_consensus_valid 전부 false"

# ===== D: usage summary (usage_summary 재사용, provider 중립 라벨) =====
summary="$(grep '^  합계:' "$TMP/state/DOCGAP.out")"
[ -n "$summary" ] || fail "D: usage 합계 줄이 없음 — $TMP/state/DOCGAP.out"
for k in invocations=1 tokens_total=10500 input_effective=10000 output=500 reasoning_output=300 reported_cost_usd=0 cost_unknown_invocations=0; do
  printf '%s' "$summary" | grep -q " $k " || printf '%s' "$summary" | grep -q " $k\$" || fail "D: 합계에 '$k' 없음: $summary"
done
est="$(printf '%s' "$summary" | sed -n 's/.* estimated_cost_usd=\([0-9.e-]*\).*/\1/p')"
comb="$(printf '%s' "$summary" | sed -n 's/.* combined_cost_usd_estimate=\([0-9.e-]*\).*/\1/p')"
[ "$(awk -v e="$est" 'BEGIN{printf "%.7f", e}')" = "0.0007100" ] && [ "$comb" = "$est" ] || fail "D: codex 추정 비용 불일치(기대 0.00071): estimated=$est combined=$comb — $summary"
grep -q 'reported_cost_usd=n/a estimated_cost_usd=0.00071' "$TMP/state/DOCGAP.out" || fail "D: 행 단위 출력에 reported(n/a)/estimated 가 없음 — $TMP/state/DOCGAP.out"
! grep -q 'cost_usd(보고된 행만)\|input_effective(claude)\|tokens_total(codex)' "$TMP/state/DOCGAP.out" || fail "D: 옛 provider 라벨이 남아 있음"
pass "D. usage summary: usage_summary(schema v3) 재사용 — codex 행 reported=null 이어도 estimated/combined 비용·tokens_total·cost_unknown=0 이 provider 중립 라벨로 출력"

echo; echo "smoke-worker-regression 전부 통과 ($TMP)"
