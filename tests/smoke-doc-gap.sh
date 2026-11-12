#!/usr/bin/env bash
# =============================================================
# 스모크: 구현 후 DOC_GAP 상태머신 — 실제 LLM 호출 없음 (공용 mock CLI: 역할은 스키마로 판별), 임시 저장소
# 파일 경로: tests/smoke-doc-gap.sh
# 사용법: bash tests/smoke-doc-gap.sh
#
# 불변식: 최초 impl consensus 뒤 워커·리뷰어가 발견한 DOC_GAP 은 impl 재합의(검증자·디자이너)로 돌아가지 않는다.
#   post-implementation DOC_GAP → 사용자 1회 판단(decisions.md + approach.md) → 워커 → 리뷰어.  그 사이 designer=0, validator=0, impl consensus=0.
# 사례:
#   A. 리뷰어 DOC_GAP only → NEED_USER/REVIEW_DOC_GAP(NEED_DOCS/APPROACH_GAP 아님), validator/designer/fixer 0, 워커 재호출 0, doc-gap-resume.json WAITING_USER,
#      리뷰 JSON·코드·index 보존. 답 없이 재실행 → 모델 0회로 같은 사유
#   B. 답(decisions.md [review-issue=…]) + approach.md 반영 후 재실행 → impl consensus 0·validator 0·designer 0, review-gap 워커 정확히 1회 → 리뷰어 → DONE,
#      stale impl PASS 지문 때문에 impl 로 되돌아가지 않음, 체크포인트 RESOLVED. 빈 답·approach 미동기화는 수리되지 않음
#   C. mixed(DOC_GAP + FIX_CODE) → 1차 fixer 0·NEED_USER, 답 후 review-gap 워커가 DOC_GAP 결정 + 같은 리뷰의 FIX_CODE 를 함께 입력받음, 선행 fixer 0, 이후 리뷰어 1회
#   D. 프로세스 재시작: WAITING_USER / WORKER_PENDING / REVIEW_PENDING 각각에서 재실행해도 impl consensus 로 빠지지 않고 완료된 유료 역할을 재호출하지 않는다
#   E. 사용자 답을 기다리는 동안 source 변경 → DOC_GAP_SOURCE_CHANGED, 기존 리뷰 미적용, 자동 restore 없음, 모델 0회
#   F. unit 워커 DOC_GAP(미완료 unit 02) → NEED_USER/UNDECIDED, unit 01 완료 유지, 답 후 validator/designer 없이 unit 02 부터 워커 → targeted test → 리뷰 → DONE
#   H. impl_docs_accepted 우회 불가: approach 단독 변경 → 재합의 / 위조 체크포인트 무효 / frozen 문서 변경·답 삭제 → DOC_GAP_SCOPE_EXCEEDED(모델 0회)
#   G. review-gap 워커가 새 DOC_GAP 을 내면 임의 결정 없이 다시 NEED_USER(무한 자동 루프 없음), 같은 리뷰 경로 보존
#   I. (feature 061) 코드 변경 없이 끝난 Gap A 의 review-gap 워커 직후 다른 리뷰가 Gap B(같은 issue id R-01)를 냄 → Gap B 의 tag 는 @2 로 유일화되어
#      Gap A 의 답이 Gap B 의 답으로 읽히지 않고, Gap A 의 해결 기록(원본 리뷰·이슈 ID·사용자 결정)은 prior_gaps 로 보존되며, 답 후 Gap B 의 review-gap 워커가 **반드시 1회** 돈다
#      (tree·결과 파일이 Gap A 의 것과 전부 같아도 건너뛰지 않는다)
#   J. review-gap 워커 결과 재사용은 같은 실행 식별자 + DONE 기록 + tree + 결과 파일 내용이 모두 맞을 때만(코드 변경 없는 실행 포함). 결과 파일·리뷰 내용이 달라졌거나
#      시작만 기록된 채 결과 파일이 다른 내용으로 남아 있으면(유효한 JSON 이 아니어도) WORKER_OUTCOME_UNCERTAIN(모델 0회, 자동 재호출 없음)
#   K. REVIEW_PENDING 재개도 같은 증명을 요구한다: 완료 기록 뒤 결과 파일·리뷰 내용이 바뀌었거나 worker_run 이 없으면 WORKER_OUTCOME_UNCERTAIN,
#      리뷰 시작 전 tree 가 after tree 와 다르면 DOC_GAP_SOURCE_CHANGED(모델 0회). 리뷰 루프가 이미 진행됐으면(수정자) tree 는 리뷰 체크포인트가 판정한다
#   M. 리뷰 해시가 없는 옛 체크포인트를 다음 gap 으로 넘길 때 현재 리뷰 내용으로 해시를 사후 생성하지 않는다(검증 근거 없는 기록으로 남는다)
#   L. tag 중복 검사는 pipefail 아래 큰 문서에서도 이미 쓰인 tag 를 놓치지 않는다
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-docgap-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"echo full-test >> $TMP/calls.log\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"echo full-lint >> $TMP/calls.log\"|" "$CFG" && rm -f "$CFG.bak"
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && for u in 01 02; do echo "base $u" > "src/u$u.txt"; done
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
printf '\n## 01\nunit 01 contract\n\n## 02\nunit 02 contract\n\n## 03\nunit 03 contract\n' >> .agent-work/implementation.md   # unit references(implementation.md#NN)가 가리키는 절 — 러너가 그 절 본문으로 unit 별 계약 변경을 판정한다
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/u01.txt","src/u02.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
cat > .agent-work/implementation-units.json <<EOF
{"version":1,"units":[
 {"id":"01-intake","title":"접수","goal":"unit 01","requirements":["REQ-01"],"scope":{"files":["src/u01.txt"],"new_file_roots":[]},"references":["implementation.md#01"],"targeted_test":"echo test-01 >> $TMP/calls.log"},
 {"id":"02-drop","title":"Drop","goal":"unit 02","requirements":["REQ-02"],"scope":{"files":["src/u02.txt"],"new_file_roots":[]},"references":["implementation.md#02"],"targeted_test":"echo test-02 >> $TMP/calls.log"}
]}
EOF
RUN=".claude/skills/feature/scripts/feature-run.sh"
CONTRACT="$(grep -E '^VALIDATOR_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
REVIEW_CONTRACT="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" FEATURE_LIVE_TEE=1 MOCK_VALIDATOR_CONTRACT="$CONTRACT" MOCK_REVIEW_CONTRACT="$REVIEW_CONTRACT"
mkdir -p "$MOCK_STATE"

# --- 공용 mock CLI (역할은 스키마로 판별). 리뷰어는 $MOCK_STATE/review-next 의 모드(DOCGAP|MIXED|APPROVE|CRASH)를 1회 소비하고 APPROVE 로 되돌린다 ---
cat > "$TMP/bin/mock-cli" <<'EOF'
#!/usr/bin/env bash
cli="$(basename "$0")"
out=""; schema=""; prompt=""; editing=0
while [ "$#" -gt 0 ]; do case "$1" in
  exec|-p|--json) shift;;
  -o) out="$2"; shift 2;;
  --output-schema) schema="$(cat "$2")"; shift 2;;
  --json-schema) schema="$2"; shift 2;;
  --sandbox) [ "$2" = workspace-write ] && editing=1; shift 2;;
  --permission-mode) editing=1; shift 2;;
  -m|-c|--model|--effort|--output-format|--tools|--allowedTools|--disallowedTools|--append-system-prompt|--session-id|--resume) shift 2;;
  *) prompt="$1"; shift;;
esac; done
usage='"session_id":"fake","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
# 실제 codex exec --json 은 첫 이벤트로 thread.started 를 낸다 — 세션 원장(config.sh codex 어댑터)이 이 계약을 읽는다
[ "$cli" = codex ] && printf '{"type":"thread.started","thread_id":"mock-thread-%s"}\n' "$$"
emit() { if [ "$cli" = codex ]; then if [ -n "$out" ]; then printf '%s\n' "$1" > "$out"; else printf '%s\n' "$1"; fi; else printf '{"structured_output":%s,%s}\n' "$1" "$usage"; fi; }
role=""
case "$schema" in
  *'"blocking_issues"'*) role=validator;;
  *'"issues"'*) role=reviewer;;
  *'"context_updates"'*) role=worker;;
  "") [ "$editing" = 1 ] && role=editor;;
esac
[ -n "$role" ] || { echo "UNKNOWN-ROLE" >> "$MOCK_LOG"; exit 1; }
issue_base='"category":"UNDECIDED_APPROACH","evidence_type":"DIRECT_MISMATCH","basis_refs":["approach.md:L1-L1"],"code_refs":["src/u01.txt:L1-L1"],"reachable_scenario":"","impact":"Map 이면 사전 인덱스 1개, 선형이면 항목마다 탐색","why_blocks_now":"w","required_outcome":"문서가 Map 과 선형 탐색 중 하나를 정한다","origin":"ROUND_1","previous_issue_id":"","fix_ref":""'
docgap_issue="{\"id\":\"R-01\",\"action\":\"DOC_GAP\",$issue_base,\"user_question\":\"Map 사전 인덱스와 항목별 선형 탐색 중 무엇인가\",\"options\":[\"Map 사전 인덱스\",\"항목별 선형 탐색\"]}"
fix_issue='{"id":"R-02","action":"FIX_CODE","category":"CONTRACT_VIOLATION","evidence_type":"DIRECT_MISMATCH","basis_refs":["approach.md:L1-L1"],"code_refs":["src/u02.txt:L1-L1"],"reachable_scenario":"","impact":"","why_blocks_now":"w","required_outcome":"u02 가 문서대로","origin":"ROUND_1","previous_issue_id":"","fix_ref":"","user_question":"","options":[]}'
case "$role" in
  validator) echo "validator" >> "$MOCK_LOG"; emit "{\"schema_version\":$MOCK_VALIDATOR_CONTRACT,\"verdict\":\"PASS\",\"blocking_issues\":[]}"; exit 0;;
  editor) echo "editor" >> "$MOCK_LOG"; if [ "$cli" = codex ]; then echo ok; else printf '{"result":"ok",%s}\n' "$usage"; fi; exit 0;;
  reviewer)
    mode="$(cat "$MOCK_STATE/review-next" 2>/dev/null || echo APPROVE)"; printf 'APPROVE' > "$MOCK_STATE/review-next"
    echo "reviewer $mode" >> "$MOCK_LOG"
    case "$mode" in
      DOCGAP) emit "{\"schema_version\":$MOCK_REVIEW_CONTRACT,\"verdict\":\"REQUEST_CHANGES\",\"issues\":[$docgap_issue]}";;
      MIXED)  emit "{\"schema_version\":$MOCK_REVIEW_CONTRACT,\"verdict\":\"REQUEST_CHANGES\",\"issues\":[$docgap_issue,$fix_issue]}";;
      CRASH)  exit 1;;
      *)      emit "{\"schema_version\":$MOCK_REVIEW_CONTRACT,\"verdict\":\"APPROVE\",\"issues\":[]}";;
    esac; exit 0;;
esac
# ---- 워커: unit 호출(프롬프트의 unit JSON) / review-gap 호출([REVIEW GAP CONTEXT] 블록) ----
if printf '%s' "$prompt" | grep -q '^\[REVIEW GAP CONTEXT\]$'; then
  echo "review-gap-worker" >> "$MOCK_LOG"
  printf '%s' "$prompt" > "$MOCK_STATE/review-gap-prompt.txt"
  if [ -f "$MOCK_STATE/crash-review-gap" ]; then rm -f "$MOCK_STATE/crash-review-gap"; exit 7; fi
  [ -f "$MOCK_STATE/gap-nochange" ] || { echo "review-gap fix" >> src/u01.txt; echo "review-gap fix" >> src/u02.txt; }   # gap-nochange: 코드 변경 없이 DONE 으로 끝나는 정상 실행
  if [ -f "$MOCK_STATE/gap-again" ]; then
    rm -f "$MOCK_STATE/gap-again"
    emit '{"status":"UNDECIDED","undecided":[{"kind":"DOC_GAP","location":"src/u02.txt","decision_needed":"정렬 기준","options":["이름","날짜"]}],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}'; exit 0
  fi
  emit '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[{"name":"gap","result":"PASS"}],"context_updates":{"upsert":[],"remove":[]}}'; exit 0
fi
unit="$(printf '%s' "$prompt" | grep -oE '"id": *"[0-9]+-[a-z0-9-]+"' | head -1 | sed -E 's/.*"([0-9]+-[a-z0-9-]+)"/\1/')"
n="${unit%%-*}"
echo "worker ${unit:-none}" >> "$MOCK_LOG"
echo "worker $unit" >> "src/u$n.txt"
if [ -f "$MOCK_STATE/undecided-$n" ]; then
  rm -f "$MOCK_STATE/undecided-$n"
  emit "$(printf '{"status":"UNDECIDED","undecided":[{"kind":"DOC_GAP","location":"src/u%s.txt","decision_needed":"drop 시 상태 전이 위치","options":["서비스","도메인 객체"]}],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}' "$n")"; exit 0
fi
emit "$(printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[{"name":"u%s","result":"PASS"}],"context_updates":{"upsert":[],"remove":[]}}' "$n")"
exit 0
EOF
chmod +x "$TMP/bin/mock-cli"; cp "$TMP/bin/mock-cli" "$TMP/bin/claude"; cp "$TMP/bin/mock-cli" "$TMP/bin/codex"

fake_pass() { bash .claude/skills/feature/scripts/consensus-loop.sh "$1" > "$TMP/consensus-$1.log" 2>&1 || { cat "$TMP/consensus-$1.log"; fail "픽스처: $1 합의 PASS 체크포인트 생성 실패"; }; }
fake_pass design; fake_pass impl
run_runner() { : > "$MOCK_LOG"; bash "$RUN" > "$TMP/run.log" 2>&1; echo $?; }
reason() { jq -r '.reason' .agent-work/run-state.json; }
status() { jq -r '.status' .agent-work/run-state.json; }
calls() { grep -c "^$1" "$MOCK_LOG" 2>/dev/null || true; }
gap() { jq -r "$1" .agent-work/doc-gap-resume.json; }
index_hash() { git ls-files --stage -v -z | shasum -a 256 | cut -c1-64; }
no_reconsensus() { # 검증자·디자이너·impl consensus 가 끼지 않았다
  [ "$(calls validator)" -eq 0 ] || fail "$1: 검증자가 호출됨 ($(paste -sd'|' "$MOCK_LOG"))"
  [ "$(calls editor)" -eq 0 ] || fail "$1: 디자이너/수정자(편집 역할)가 호출됨 ($(paste -sd'|' "$MOCK_LOG"))"
  grep -q 'consensus-loop impl\|impl 부터\|NEED_DOCS\|APPROACH_GAP' "$TMP/run.log" && fail "$1: impl 재합의 경로로 빠짐: $(grep 'impl 부터\|NEED_DOCS\|APPROACH_GAP' "$TMP/run.log")"
  return 0
}
reset_tree() { # 테스트 환경 정리(파이프라인 동작 아님)
  git checkout -q -- src
  rm -rf .agent-work/units .agent-work/implementation-context.json .agent-work/implementation-units.lock.json .agent-work/feature-scope.lock.json .agent-work/worker-baseline.tree \
    .agent-work/worker-result.json .agent-work/review-gap-result.json .agent-work/review-gap-*.tree .agent-work/review-impl.json .agent-work/approved.fingerprint \
    .agent-work/reviews/impl-attempt-* .agent-work/.session-* .agent-work/worker-session.json .agent-work/worker-session.migrate* .agent-work/worker-handoff.json \
    .agent-work/doc-gap-resume.json .agent-work/worker-outcome.guard.json "$MOCK_STATE"/*
  : > .agent-work/decisions.md; printf '# approach\n' > .agent-work/approach.md
  fake_pass impl   # decisions/approach 를 되돌렸으므로 impl PASS 지문 재동기화 (픽스처)
  printf '{"stage":"worker","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
}
answer_review_gap() { # 사용자 역할: decisions.md 답 + approach.md 최소 동기화 (오케스트레이터가 하는 일 — 디자이너 호출 없음)
  printf -- '- [USER-QUESTION][scope=impl][review-issue=R-01] Map 사전 인덱스와 항목별 선형 탐색 중 무엇인가 → Map 사전 인덱스\n' >> .agent-work/decisions.md
  printf '\n## 결정 R-01 (REQUIRED)\nMap 사전 인덱스를 쓴다.\n' >> .agent-work/approach.md
}

# ===== 사례 A: 리뷰어 DOC_GAP only =====
reset_tree; printf 'DOCGAP' > "$MOCK_STATE/review-next"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = REVIEW_DOC_GAP ] || { tail -20 "$TMP/run.log"; fail "A: exit 2/REVIEW_DOC_GAP 기대, 실제 $rc/$(reason)"; }
[ "$(status)" = NEED_USER ] || fail "A: status 가 NEED_USER 가 아님"
[ "$(paste -sd'|' "$MOCK_LOG")" = "worker 01-intake|test-01|worker 02-drop|test-02|reviewer DOCGAP" ] || fail "A: 호출 순서 불일치: $(paste -sd'|' "$MOCK_LOG")"
no_reconsensus A
jq -e '.version==1 and .origin=="review" and .next_step=="WAITING_USER" and .gaps[0].key=="R-01" and .gaps[0].tag=="review-issue=R-01" and (.gaps[0].options|length)==2 and .resolved_impl_fingerprint=="" and .base_consensus_review!=""' .agent-work/doc-gap-resume.json >/dev/null \
  || fail "A: doc-gap-resume.json 불일치: $(cat .agent-work/doc-gap-resume.json)"
REVIEW_A="$(gap .review)"; [ -f "$REVIEW_A" ] && jq -e '.issues[0].action=="DOC_GAP"' "$REVIEW_A" >/dev/null || fail "A: 리뷰 JSON 이 보존되지 않음 ($REVIEW_A)"
[ "$(gap .source_tree)" = "$(bash -c "source $CFG; snapshot_worktree_tree")" ] || fail "A: source_tree 가 현재 작업 트리와 다름"
grep -q 'R-01' .agent-work/run-state.json && grep -q 'Map 사전 인덱스' .agent-work/run-state.json && grep -q 'approach.md:L1-L1' .agent-work/run-state.json || fail "A: detail 에 issue id·질문·options·refs 가 없음"
[ "$(tail -1 src/u01.txt)" = "worker 01-intake" ] && [ "$(tail -1 src/u02.txt)" = "worker 02-drop" ] || fail "A: 코드가 보존되지 않음"
INDEX_A="$(index_hash)"
[ -f .agent-work/units/01-intake/done.json ] && [ -f .agent-work/units/02-drop/done.json ] || fail "A: unit 완료 체크포인트가 사라짐"
# 답 없이 재실행 → 모델 0회, 같은 사유 (WAITING_USER 유지)
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = REVIEW_DOC_GAP ] || { tail -20 "$TMP/run.log"; fail "A(재실행): exit 2/REVIEW_DOC_GAP 기대, 실제 $rc/$(reason)"; }
[ ! -s "$MOCK_LOG" ] || fail "A(재실행): 답 없는데 모델/테스트가 호출됨: $(paste -sd'|' "$MOCK_LOG")"
[ "$(gap .next_step)" = WAITING_USER ] || fail "A(재실행): 체크포인트가 WAITING_USER 가 아님"
# 빈 답은 답이 아니다 / approach 미동기화는 수리되지 않는다
printf -- '- [USER-QUESTION][scope=impl][review-issue=R-01] 질문 → \n' >> .agent-work/decisions.md
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = REVIEW_DOC_GAP ] && [ ! -s "$MOCK_LOG" ] && grep -q '답 없는 gap: review-issue=R-01' .agent-work/run-state.json || fail "A(빈 답): 빈 답이 resolved 로 처리됨 ($rc/$(reason))"
printf -- '- [USER-QUESTION][scope=impl][review-issue=R-01] Map 사전 인덱스와 항목별 선형 탐색 중 무엇인가 → Map 사전 인덱스\n' >> .agent-work/decisions.md
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = REVIEW_DOC_GAP ] && [ ! -s "$MOCK_LOG" ] && grep -q 'approach.md 가 DOC_GAP 발생 시점과 같다' .agent-work/run-state.json || fail "A(approach 미동기화): 동기화 없이 진행됨 ($rc/$(reason))"
[ "$(gap .next_step)" = WAITING_USER ] || fail "A: 미동기화인데 WAITING_USER 를 벗어남"
pass "A: 리뷰어 DOC_GAP → NEED_USER/REVIEW_DOC_GAP, 검증자·디자이너·수정자 0, 체크포인트 WAITING_USER, 리뷰·코드·index 보존, 답 없음/빈 답/미동기화는 모델 0회로 대기"

# ===== 사례 B: 답 + approach 반영 후 재실행 → impl consensus 0, review-gap 워커 1회 → 리뷰어 → DONE =====
printf '\n## 결정 R-01 (REQUIRED)\nMap 사전 인덱스를 쓴다.\n' >> .agent-work/approach.md
( source "$CFG"; consensus_pass_current impl ) && fail "B: 전제 — 문서가 바뀌었는데 impl PASS 지문이 유효함(사례가 stale 경로를 검증하지 못함)"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "B: exit 0/DONE 기대, 실제 $rc/$(status)"; }
[ "$(paste -sd'|' "$MOCK_LOG")" = "review-gap-worker|reviewer APPROVE|full-test|full-lint" ] || fail "B: 호출 순서 불일치(워커 1회 → 리뷰어 1회 기대): $(paste -sd'|' "$MOCK_LOG")"
no_reconsensus B
[ "$(gap .next_step)" = RESOLVED ] && [ -n "$(gap .resolved_impl_fingerprint)" ] || fail "B: 체크포인트가 RESOLVED 가 아님: $(cat .agent-work/doc-gap-resume.json)"
[ "$(jq -r .next_step .agent-work/consensus-impl.json)" = PASS ] && ( source "$CFG"; consensus_pass_current impl ) && fail "B: impl consensus 체크포인트가 위조됨(PASS 지문이 새 문서로 덮임)"
grep -q 'review-issue=R-01' "$MOCK_STATE/review-gap-prompt.txt" && grep -q 'Map 사전 인덱스' "$MOCK_STATE/review-gap-prompt.txt" && grep -q "$REVIEW_A" "$MOCK_STATE/review-gap-prompt.txt" || fail "B: review-gap 워커 프롬프트에 사용자 결정·리뷰 경로가 없음"
[ "$(tail -1 src/u01.txt)" = "review-gap fix" ] || fail "B: review-gap 워커 변경이 없음"
[ -f .agent-work/review-gap-result.json ] && jq -e '.status=="DONE"' .agent-work/worker-result.json >/dev/null || fail "B: review-gap 결과가 unit 합산 worker-result.json 을 덮어씀"
[ "$(index_hash)" = "$INDEX_A" ] || fail "B: git index 가 바뀜"
[ "$(jq -r 'select(.role=="WORKER") | .label' .agent-work/usage.jsonl 2>/dev/null | grep -c review-gap)" -ge 0 ] || true
# DONE 뒤 재실행: 이미 DONE (모델 0회)
rc="$(run_runner)"; [ "$rc" -eq 0 ] && [ ! -s "$MOCK_LOG" ] || fail "B(재실행): DONE 뒤 모델이 호출됨"
pass "B: 사용자 답 → review-gap 워커 1회 → 리뷰어 → DONE, impl consensus/validator/designer 0, PASS 지문 위조 없음(사용자 해결 provenance 로 재개)"

# ===== 사례 C: mixed DOC_GAP + FIX_CODE =====
reset_tree; printf 'MIXED' > "$MOCK_STATE/review-next"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = REVIEW_DOC_GAP ] || { tail -20 "$TMP/run.log"; fail "C: exit 2/REVIEW_DOC_GAP 기대, 실제 $rc/$(reason)"; }
[ "$(calls editor)" -eq 0 ] || fail "C: DOC_GAP 이 있는데 수정자가 먼저 호출됨"
grep -q 'FIX_CODE R-02' .agent-work/run-state.json || fail "C: detail 에 같은 리뷰의 FIX_CODE 가 안내되지 않음"
REVIEW_C="$(gap .review)"; jq -e '[.issues[].action]==["DOC_GAP","FIX_CODE"]' "$REVIEW_C" >/dev/null || fail "C: mixed 리뷰가 보존되지 않음"
answer_review_gap
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "C: 답 후 exit 0/DONE 기대, 실제 $rc/$(status)"; }
[ "$(paste -sd'|' "$MOCK_LOG")" = "review-gap-worker|reviewer APPROVE|full-test|full-lint" ] || fail "C: 답 후 호출 순서 불일치(선행 fixer 없음, 워커 → 리뷰어 1회): $(paste -sd'|' "$MOCK_LOG")"
no_reconsensus C
grep -q "$REVIEW_C" "$MOCK_STATE/review-gap-prompt.txt" && grep -q 'review-issue=R-01' "$MOCK_STATE/review-gap-prompt.txt" || fail "C: review-gap 워커가 리뷰(FIX_CODE 포함)·결정을 입력받지 않음"
[ "$(tail -1 src/u02.txt)" = "review-gap fix" ] || fail "C: FIX_CODE 대상(u02) 변경이 없음"
pass "C: mixed → 1차 수정자 0·NEED_USER, 답 후 review-gap 워커가 DOC_GAP 결정 + FIX_CODE 를 함께 처리 → 리뷰어 1회 → DONE"

# ===== 사례 D: 프로세스 재시작 — WORKER_PENDING / REVIEW_PENDING =====
# D-1 WORKER_PENDING: 답 수리 뒤 review-gap 워커가 변경 없이 실패(exit 7) → 기존 실행 실패(ENV_ERROR), 체크포인트 WORKER_PENDING 유지 → 재실행은 impl consensus 없이 워커부터
reset_tree; printf 'DOCGAP' > "$MOCK_STATE/review-next"
rc="$(run_runner)"; [ "$rc" -eq 2 ] || fail "D: 전제 실패"
answer_review_gap; touch "$MOCK_STATE/crash-review-gap"
rc="$(run_runner)"
[ "$rc" -eq 1 ] && [ "$(status)" = ENV_ERROR ] || { tail -20 "$TMP/run.log"; fail "D-1: 워커 실패가 exit 1/ENV_ERROR 가 아님 ($rc/$(status))"; }
[ "$(gap .next_step)" = WORKER_PENDING ] && [ -n "$(gap .resolved_impl_fingerprint)" ] || fail "D-1: 체크포인트가 WORKER_PENDING 이 아님: $(cat .agent-work/doc-gap-resume.json)"
[ "$(calls reviewer)" -eq 0 ] || fail "D-1: 워커 실패인데 리뷰어가 호출됨"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "D-1: 재실행 exit 0/DONE 기대, 실제 $rc/$(status)"; }
[ "$(paste -sd'|' "$MOCK_LOG")" = "review-gap-worker|reviewer APPROVE|full-test|full-lint" ] || fail "D-1: 재실행이 워커부터 재개되지 않음: $(paste -sd'|' "$MOCK_LOG")"
no_reconsensus D-1
# D-2 REVIEW_PENDING: 워커 완료 뒤 리뷰어 crash → 체크포인트 REVIEW_PENDING → 재실행은 워커 재호출 없이 리뷰어부터
reset_tree; printf 'DOCGAP' > "$MOCK_STATE/review-next"
rc="$(run_runner)"; [ "$rc" -eq 2 ] || fail "D-2: 전제 실패"
answer_review_gap; printf 'CRASH' > "$MOCK_STATE/review-next"
rc="$(run_runner)"
[ "$rc" -eq 1 ] || { tail -20 "$TMP/run.log"; fail "D-2: 리뷰어 crash 가 exit 1 이 아님 ($rc)"; }
[ "$(calls review-gap-worker)" -eq 1 ] || fail "D-2: review-gap 워커 1회가 아님"
[ "$(gap .next_step)" = REVIEW_PENDING ] || fail "D-2: 체크포인트가 REVIEW_PENDING 이 아님: $(cat .agent-work/doc-gap-resume.json)"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "D-2: 재실행 exit 0/DONE 기대, 실제 $rc/$(status)"; }
[ "$(paste -sd'|' "$MOCK_LOG")" = "reviewer APPROVE|full-test|full-lint" ] || fail "D-2: 재실행이 리뷰어부터 재개되지 않음(워커 재호출 금지): $(paste -sd'|' "$MOCK_LOG")"
no_reconsensus D-2
[ "$(gap .next_step)" = RESOLVED ] || fail "D-2: 승인 뒤 RESOLVED 가 아님"
# D-3 RESOLVED 직후 힌트가 doc-gap 인 채 죽음 → worker 부터(완료 unit 건너뜀) → 리뷰 승인 재사용 → DONE, 모델 0회
printf '{"stage":"doc-gap","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -20 "$TMP/run.log"; fail "D-3: exit 0/DONE 기대, 실제 $rc/$(status)"; }
grep -q '^worker \|^review-gap-worker\|^reviewer' "$MOCK_LOG" && fail "D-3: RESOLVED 뒤 재실행에서 워커/리뷰어가 재호출됨: $(paste -sd'|' "$MOCK_LOG")"
no_reconsensus D-3
pass "D: WORKER_PENDING/REVIEW_PENDING/RESOLVED 어느 지점에서 죽어도 impl consensus 없이 체크포인트 단계부터 재개, 완료된 유료 역할 재호출 없음"

# ===== 사례 E: 답을 기다리는 동안 source 변경 → DOC_GAP_SOURCE_CHANGED, 기존 리뷰 미적용, 자동 restore 없음 =====
reset_tree; printf 'DOCGAP' > "$MOCK_STATE/review-next"
rc="$(run_runner)"; [ "$rc" -eq 2 ] || fail "E: 전제 실패"
answer_review_gap
echo "external edit while waiting" >> src/u01.txt
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = DOC_GAP_SOURCE_CHANGED ] || { tail -20 "$TMP/run.log"; fail "E: exit 2/DOC_GAP_SOURCE_CHANGED 기대, 실제 $rc/$(reason)"; }
[ ! -s "$MOCK_LOG" ] || fail "E: source 변경 감지인데 모델이 호출됨: $(paste -sd'|' "$MOCK_LOG")"
[ "$(tail -1 src/u01.txt)" = "external edit while waiting" ] || fail "E: 외부 변경이 자동 원복됨"
[ "$(gap .next_step)" = WAITING_USER ] || fail "E: 체크포인트가 수리됨(WAITING_USER 유지돼야 함)"
# 문서(.agent-work)만 바뀐 것은 source 변경이 아니다 — 위 사례 B/C 가 이미 통과. 사용자가 tree 를 되돌리면 재개된다
git checkout -q -- src/u01.txt; echo "worker 01-intake" >> src/u01.txt
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -20 "$TMP/run.log"; fail "E: tree 복구 후 재개 실패 ($rc/$(status))"; }
no_reconsensus E
pass "E: 대기 중 source 변경 → DOC_GAP_SOURCE_CHANGED(모델 0회, 원복 없음), 복구 후 재개"

# ===== 사례 F: unit 워커 DOC_GAP =====
reset_tree; touch "$MOCK_STATE/undecided-02"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] || { tail -20 "$TMP/run.log"; fail "F: exit 2/UNDECIDED 기대, 실제 $rc/$(reason)"; }
[ "$(paste -sd'|' "$MOCK_LOG")" = "worker 01-intake|test-01|worker 02-drop" ] || fail "F: 호출 순서 불일치: $(paste -sd'|' "$MOCK_LOG")"
[ -f .agent-work/units/01-intake/done.json ] && [ ! -f .agent-work/units/02-drop/done.json ] || fail "F: unit 01 완료/02 미완료 상태가 아님"
jq -e '.origin=="worker" and .unit_id=="02-drop" and .next_step=="WAITING_USER" and .gaps[0].key=="02-drop#1" and .gaps[0].tag=="worker-gap=02-drop#1" and .gaps[0].question=="drop 시 상태 전이 위치"' .agent-work/doc-gap-resume.json >/dev/null \
  || fail "F: 워커 체크포인트 불일치: $(cat .agent-work/doc-gap-resume.json)"
grep -q 'worker-gap=02-drop#1' .agent-work/run-state.json || fail "F: detail 에 답 태그가 없음"
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] && [ ! -s "$MOCK_LOG" ] || fail "F(재실행): 답 없는데 모델이 호출됨"
printf -- '- [USER-QUESTION][scope=impl][worker-gap=02-drop#1] drop 시 상태 전이 위치 → 도메인 객체\n' >> .agent-work/decisions.md
printf '\n## 결정 02-drop (REQUIRED)\n상태 전이는 도메인 객체가 한다.\n' >> .agent-work/approach.md
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "F: 답 후 exit 0/DONE 기대, 실제 $rc/$(status)"; }
[ "$(paste -sd'|' "$MOCK_LOG")" = "worker 02-drop|test-02|reviewer APPROVE|full-test|full-lint" ] || fail "F: 답 후 unit 02 부터 재개되지 않음(01 재호출·검증자 금지): $(paste -sd'|' "$MOCK_LOG")"
no_reconsensus F
[ -f .agent-work/units/02-drop/done.json ] && [ "$(gap .next_step)" = RESOLVED ] || fail "F: unit 02 완료·RESOLVED 가 아님"
pass "F: unit 워커 DOC_GAP → NEED_USER/UNDECIDED, unit 01 유지, 답 후 validator/designer 없이 unit 02 → targeted test → 리뷰 → DONE"

# ===== 사례 G: review-gap 워커가 새 DOC_GAP → 다시 NEED_USER(자동 루프 없음), 리뷰 경로 보존, 답 후 같은 워커 재개 =====
reset_tree; printf 'DOCGAP' > "$MOCK_STATE/review-next"
rc="$(run_runner)"; [ "$rc" -eq 2 ] || fail "G: 전제 실패"
answer_review_gap; touch "$MOCK_STATE/gap-again"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = UNDECIDED ] || { tail -20 "$TMP/run.log"; fail "G: exit 2/UNDECIDED 기대, 실제 $rc/$(reason)"; }
[ "$(calls review-gap-worker)" -eq 1 ] && [ "$(calls reviewer)" -eq 0 ] || fail "G: 워커 1회·리뷰어 0회가 아님: $(paste -sd'|' "$MOCK_LOG")"
jq -e --arg r "$REVIEW_A" '.origin=="worker" and .unit_id=="" and .next_step=="WAITING_USER" and .gaps[0].tag=="worker-gap=review-gap#1" and (.review|endswith("reviewer-round-01.json"))' .agent-work/doc-gap-resume.json >/dev/null \
  || fail "G: 새 gap 체크포인트 불일치: $(cat .agent-work/doc-gap-resume.json)"
printf -- '- [USER-QUESTION][scope=impl][worker-gap=review-gap#1] 정렬 기준 → 날짜\n' >> .agent-work/decisions.md
printf '\n## 결정 정렬 (REQUIRED)\n날짜순.\n' >> .agent-work/approach.md
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "G: 답 후 exit 0/DONE 기대, 실제 $rc/$(status)"; }
[ "$(paste -sd'|' "$MOCK_LOG")" = "review-gap-worker|reviewer APPROVE|full-test|full-lint" ] || fail "G: 답 후 같은 review-gap 워커 → 리뷰어가 아님: $(paste -sd'|' "$MOCK_LOG")"
grep -q 'worker-gap=review-gap#1' "$MOCK_STATE/review-gap-prompt.txt" || fail "G: 재개된 워커 프롬프트에 두 번째 결정이 없음"
grep -q '같은 리뷰에서 앞서 결정된 항목' "$MOCK_STATE/review-gap-prompt.txt" && grep -q '\[review-issue=R-01\].*→ Map 사전 인덱스$' "$MOCK_STATE/review-gap-prompt.txt" || fail "G: 재개된 워커 프롬프트에 같은 리뷰의 앞선 결정(R-01)이 없음"
jq -e '(.prior_gaps|length)==1 and .prior_gaps[0].tag=="review-issue=R-01" and .prior_gaps[0].review==.review' .agent-work/doc-gap-resume.json >/dev/null || fail "G: 워커 미결정 체크포인트가 앞선 리뷰 gap 의 해결 기록을 보존하지 않음"
no_reconsensus G
pass "G: review-gap 워커의 새 DOC_GAP → 다시 NEED_USER(자동 루프 없음), 답 후 같은 워커 → 리뷰어 → DONE"

# ===== 사례 H: impl_docs_accepted 는 좁은 우회문이어야 한다 — provenance 다섯 조건 중 하나라도 깨지면 impl 재합의(검증자 1회) 또는 중단(모델 0회) =====
# H-1 pending 없이 approach.md 만 바뀜 → 정상적으로 impl 재합의(체크포인트 RESOLVED 가 있어도 지문이 다르면 무효)
reset_tree; printf 'DOCGAP' > "$MOCK_STATE/review-next"
rc="$(run_runner)"; [ "$rc" -eq 2 ] || fail "H: 전제 실패"; answer_review_gap
rc="$(run_runner)"; [ "$rc" -eq 0 ] && [ "$(gap .next_step)" = RESOLVED ] || fail "H: 전제(RESOLVED) 실패"
printf '\n## 또 다른 변경\n' >> .agent-work/approach.md
printf '{"stage":"review","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
rc="$(run_runner)"
[ "$(calls validator)" -eq 1 ] && grep -q 'impl 부터' "$TMP/run.log" || fail "H-1: RESOLVED 뒤 approach.md 추가 변경이 impl 재합의를 거치지 않음: $(paste -sd'|' "$MOCK_LOG")"
( source "$CFG"; doc_gap_resolved_current ) && fail "H-1: 지문이 다른데 doc_gap_resolved_current 가 true"
# H-2 위조: 체크포인트에 현재 지문을 손으로 써 넣어도(밑바탕 PASS 지문·review 불일치) 우회 불가
reset_tree
printf '\n## 무단 변경\n' >> .agent-work/approach.md
jq -n --arg fp "$(bash -c "source $CFG; consensus_pass_fingerprint impl")" --arg r "$(jq -r .review .agent-work/consensus-impl.json)" \
  '{version:1,origin:"review",next_step:"RESOLVED",review:"x",attempt:1,round:1,unit_id:"",result:"",gaps:[],source_tree:"",docs_fingerprint:"",approach_hash:"",
    base_consensus_review:$r,base_consensus_round:1,base_pass_fingerprint:"forged",gap_impl_fingerprint:"",frozen_docs_hash:"",decisions_lines:0,decisions_prefix_hash:"",resolved_impl_fingerprint:$fp}' > .agent-work/doc-gap-resume.json
( source "$CFG"; doc_gap_resolved_current ) && fail "H-2: 위조 체크포인트(밑바탕 PASS 지문 불일치)가 유효로 판정됨"
printf '{"stage":"review","test_retries":0,"stale_count":0,"history":[]}\n' > .agent-work/run-state.json
rc="$(run_runner)"; [ "$(calls validator)" -eq 1 ] && grep -q 'impl 부터' "$TMP/run.log" || fail "H-2: 위조 체크포인트로 impl 재합의를 우회함: $(paste -sd'|' "$MOCK_LOG")"
# H-3 대기 중 implementation.md 변경 + 답 → 해결 범위 밖(DOC_GAP_SCOPE_EXCEEDED), 모델 0회, 수리되지 않음. 되돌리면 재개
reset_tree; printf 'DOCGAP' > "$MOCK_STATE/review-next"
rc="$(run_runner)"; [ "$rc" -eq 2 ] || fail "H-3: 전제 실패"; answer_review_gap
printf '\n새 요구\n' >> .agent-work/implementation.md
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = DOC_GAP_SCOPE_EXCEEDED ] && [ ! -s "$MOCK_LOG" ] && [ "$(gap .next_step)" = WAITING_USER ] || { tail -5 "$TMP/run.log"; fail "H-3: implementation.md 변경이 사용자 해결 경로로 수리됨 ($rc/$(reason))"; }
printf '# implementation\n\n## 01\nunit 01 contract\n\n## 02\nunit 02 contract\n\n## 03\nunit 03 contract\n' > .agent-work/implementation.md   # 픽스처 원문 그대로 되돌린다
rc="$(run_runner)"; [ "$rc" -eq 0 ] && [ "$(calls validator)" -eq 0 ] || fail "H-3: 되돌린 뒤 재개 실패 ($rc)"
# H-4 수리 뒤(WORKER_PENDING) 답 줄 삭제 → provenance 깨짐, 모델 0회
reset_tree; printf 'DOCGAP' > "$MOCK_STATE/review-next"
rc="$(run_runner)"; [ "$rc" -eq 2 ] || fail "H-4: 전제 실패"; answer_review_gap; touch "$MOCK_STATE/crash-review-gap"
rc="$(run_runner)"; [ "$(gap .next_step)" = WORKER_PENDING ] || fail "H-4: 전제(WORKER_PENDING) 실패"
grep -v 'review-issue=R-01' .agent-work/decisions.md > "$TMP/d.tmp"; mv "$TMP/d.tmp" .agent-work/decisions.md
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = DOC_GAP_SCOPE_EXCEEDED ] && [ ! -s "$MOCK_LOG" ] || { tail -5 "$TMP/run.log"; fail "H-4: 답 줄 삭제 뒤에도 워커가 진행됨 ($rc/$(reason))"; }
( source "$CFG"; impl_docs_accepted ) && fail "H-4: 답이 없는데 impl_docs_accepted 가 true"
pass "H: impl_docs_accepted 는 활성 체크포인트 + 실제 consensus PASS + 답 존재 + 해결 범위 안 변경 + 고정 지문 일치일 때만 true — approach 단독 변경·위조·범위 밖 문서 변경·답 삭제는 전부 재합의/중단"

# ===== 사례 I: 코드 변경 없는 Gap A 직후 Gap B — Gap B 의 review-gap 워커를 건너뛰지 않는다 (feature 061 재현) =====
tree_now() { bash -c "source $CFG; snapshot_worktree_tree"; }
sha_of() { shasum -a 256 "$1" | cut -c1-64; }
reset_tree; printf 'DOCGAP' > "$MOCK_STATE/review-next"
rc="$(run_runner)"; [ "$rc" -eq 2 ] && [ "$(reason)" = REVIEW_DOC_GAP ] || fail "I: 전제(Gap A) 실패"
REVIEW_I1="$(gap .review)"; TREE_I="$(tree_now)"
answer_review_gap; touch "$MOCK_STATE/gap-nochange"; printf 'DOCGAP' > "$MOCK_STATE/review-next"   # Gap A 워커는 코드 변경 없이 DONE, 이어진 리뷰가 Gap B 를 낸다
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = REVIEW_DOC_GAP ] || { tail -20 "$TMP/run.log"; fail "I: Gap B 가 exit 2/REVIEW_DOC_GAP 이 아님 ($rc/$(reason))"; }
[ "$(paste -sd'|' "$MOCK_LOG")" = "review-gap-worker|reviewer DOCGAP" ] || fail "I: Gap A 워커 → 리뷰어(Gap B) 순서가 아님: $(paste -sd'|' "$MOCK_LOG")"
[ "$(tree_now)" = "$TREE_I" ] || fail "I: 전제 — Gap A 워커가 코드를 바꿈(코드 변경 없는 사례가 아님)"
REVIEW_I2="$(gap .review)"; [ "$REVIEW_I2" != "$REVIEW_I1" ] && [ -f "$REVIEW_I2" ] || fail "I: Gap B 가 다른 리뷰 파일이 아님 ($REVIEW_I1 / $REVIEW_I2)"
jq -e --arg r1 "$REVIEW_I1" --arg s1 "$(sha_of "$REVIEW_I1")" --arg s2 "$(sha_of "$REVIEW_I2")" --arg t "$TREE_I" '
  .next_step=="WAITING_USER" and .origin=="review" and .source_tree==$t and (has("worker_run")|not) and .review_sha256==$s2
  and .gaps[0].key=="R-01" and .gaps[0].tag=="review-issue=R-01@2"
  and (.prior_gaps|length)==1 and .prior_gaps[0].key=="R-01" and .prior_gaps[0].tag=="review-issue=R-01" and .prior_gaps[0].origin=="review"
  and .prior_gaps[0].review==$r1 and .prior_gaps[0].review_sha256==$s1 and (.prior_gaps[0].answer|test("\\[review-issue=R-01\\].*→ Map 사전 인덱스$"))
  and (.prior_gaps[0].resolved_impl_fingerprint|length)==64 and .prior_gaps[0].location=="src/u01.txt:L1-L1"' .agent-work/doc-gap-resume.json >/dev/null \
  || fail "I: Gap B 체크포인트(유일 tag·prior_gaps 의 원본 리뷰/이슈 ID/사용자 결정) 불일치: $(cat .agent-work/doc-gap-resume.json)"
grep -q 'tag: review-issue=R-01@2' .agent-work/run-state.json || fail "I: detail 에 Gap B 의 답 tag 가 없음"
( source "$CFG"; [ "$(doc_gap_prior_valid_tags)" = '["review-issue=R-01"]' ] ) || fail "I: 앞선 해결(Gap A)의 연결이 유효로 확인되지 않음"
# 답 없이 재실행: Gap A 의 답 줄([review-issue=R-01])이 Gap B 의 답으로 읽히면 안 된다 — 모델 0회로 대기
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = REVIEW_DOC_GAP ] && [ ! -s "$MOCK_LOG" ] && grep -q '답 없는 gap: review-issue=R-01@2' .agent-work/run-state.json \
  || { tail -5 "$TMP/run.log"; fail "I: 다른 리뷰의 같은 issue id 답이 Gap B 의 답으로 인정됨 ($rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"; }
printf -- '- [USER-QUESTION][scope=impl][review-issue=R-01@2] Map 사전 인덱스와 항목별 선형 탐색 중 무엇인가(두 번째 위치) → 항목별 선형 탐색\n' >> .agent-work/decisions.md
printf '\n## 결정 R-01@2 (REQUIRED)\n두 번째 위치는 항목별 선형 탐색.\n' >> .agent-work/approach.md
# Gap A 워커가 남긴 산출물은 Gap B 의 source tree 와 전부 같다(before == after == 현재) — tree 비교만으로는 Gap B 워커를 건너뛰게 되는 상태다
[ "$(cat .agent-work/review-gap-before.tree)" = "$TREE_I" ] && [ "$(cat .agent-work/review-gap-after.tree)" = "$TREE_I" ] && jq -e '.status=="DONE"' .agent-work/review-gap-result.json >/dev/null \
  || fail "I: 전제 — Gap A 워커 산출물(before/after tree·DONE 결과)이 재사용 오판 조건을 만들지 않음"
mv "$MOCK_STATE/gap-nochange" "$MOCK_STATE/gap-nochange.used"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "I: Gap B 답 후 exit 0/DONE 기대, 실제 $rc/$(status)/$(reason)"; }
[ "$(paste -sd'|' "$MOCK_LOG")" = "review-gap-worker|reviewer APPROVE|full-test|full-lint" ] || fail "I: Gap B 의 review-gap 워커가 정확히 1회 돌지 않음(Gap A 결과 재사용 금지): $(paste -sd'|' "$MOCK_LOG")"
grep -q 'review-issue=R-01@2' "$MOCK_STATE/review-gap-prompt.txt" && grep -q '항목별 선형 탐색$' "$MOCK_STATE/review-gap-prompt.txt" && grep -q "$REVIEW_I2" "$MOCK_STATE/review-gap-prompt.txt" \
  || fail "I: Gap B 워커 프롬프트에 Gap B 의 리뷰·결정이 없음"
no_reconsensus I
jq -e '.next_step=="RESOLVED" and .worker_run.state=="DONE" and (.worker_run.identity|length)==64 and (.worker_run.result_sha256|length)==64 and (.prior_gaps|length)==1' .agent-work/doc-gap-resume.json >/dev/null \
  || fail "I: 완료 뒤 체크포인트(worker_run·prior_gaps) 불일치: $(cat .agent-work/doc-gap-resume.json)"
pass "I: 코드 변경 없는 Gap A 직후 Gap B — tag 유일화(@2)로 Gap A 의 답을 재사용하지 않고, prior_gaps 가 Gap A 의 원본 리뷰·이슈 ID·결정을 보존하며, Gap B 워커가 정확히 1회 돈다"

# ===== 사례 J: review-gap 워커 결과 재사용 조건 =====
# 픽스처: 코드 변경 없는 워커가 DONE 으로 끝나 완료 기록(worker_run DONE)까지 남긴 뒤, 단계 전환(REVIEW_PENDING) 직전에 프로세스가 죽은 상태
reset_tree; printf 'DOCGAP' > "$MOCK_STATE/review-next"
rc="$(run_runner)"; [ "$rc" -eq 2 ] || fail "J: 전제 실패"
answer_review_gap; touch "$MOCK_STATE/gap-nochange"; printf 'CRASH' > "$MOCK_STATE/review-next"
rc="$(run_runner)"; [ "$rc" -eq 1 ] && [ "$(gap .next_step)" = REVIEW_PENDING ] && [ "$(gap .worker_run.state)" = DONE ] && [ "$(gap .worker_run.before_tree)" = "$(gap .worker_run.after_tree)" ] \
  || { tail -20 "$TMP/run.log"; fail "J: 전제(코드 변경 없는 워커 DONE 기록 + REVIEW_PENDING) 실패: $(cat .agent-work/doc-gap-resume.json)"; }
jq '.next_step="WORKER_PENDING" | .source_tree=.worker_run.before_tree' .agent-work/doc-gap-resume.json > "$TMP/j.ck" && cp "$TMP/j.ck" .agent-work/doc-gap-resume.json
cp .agent-work/review-gap-result.json "$TMP/j.result"; REVIEW_J="$(gap .review)"; cp "$REVIEW_J" "$TMP/j.review"
# J-1 결과 파일이 완료 기록 당시와 다름(해시 불일치) → 재사용도 재호출도 하지 않는다
printf '\n' >> .agent-work/review-gap-result.json
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] && [ ! -s "$MOCK_LOG" ] && [ "$(gap .next_step)" = WORKER_PENDING ] \
  || { tail -5 "$TMP/run.log"; fail "J-1: 결과 파일이 달라졌는데 WORKER_OUTCOME_UNCERTAIN(모델 0회)이 아님 ($rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"; }
cp "$TMP/j.result" .agent-work/review-gap-result.json
# J-2 리뷰 내용이 달라짐(경로는 같음) → 식별자 불일치 → 재사용도 재호출도 하지 않는다
printf '\n' >> "$REVIEW_J"
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] && [ ! -s "$MOCK_LOG" ] && grep -q '식별자' .agent-work/run-state.json \
  || { tail -5 "$TMP/run.log"; fail "J-2: 리뷰 내용이 달라졌는데(경로 동일) 결과를 재사용하거나 워커를 다시 부름 ($rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"; }
cp "$TMP/j.review" "$REVIEW_J"
# J-3 source tree 가 기록된 after tree 와 다름 → DOC_GAP_SOURCE_CHANGED(자동 원복 없음), 되돌리면 J-4 로
cp src/u01.txt "$TMP/j.u01"; echo "external edit" >> src/u01.txt
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = DOC_GAP_SOURCE_CHANGED ] && [ ! -s "$MOCK_LOG" ] && [ "$(tail -1 src/u01.txt)" = "external edit" ] \
  || { tail -5 "$TMP/run.log"; fail "J-3: tree 가 달라졌는데 DOC_GAP_SOURCE_CHANGED(모델 0회·원복 없음)가 아님 ($rc/$(reason))"; }
cp "$TMP/j.u01" src/u01.txt
# J-4 같은 식별자 + DONE 기록 + tree 일치 + 결과 파일 그대로 → 워커 재호출 없이 리뷰로(코드 변경 없는 실행도 재사용된다)
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] || { tail -30 "$TMP/run.log"; fail "J-4: 재사용 조건이 모두 맞는데 DONE 이 아님 ($rc/$(status)/$(reason))"; }
[ "$(paste -sd'|' "$MOCK_LOG")" = "reviewer APPROVE|full-test|full-lint" ] && grep -q 'review-gap 워커 결과 재사용' "$TMP/run.log" || fail "J-4: 워커가 재호출됐거나 재사용 로그가 없음: $(paste -sd'|' "$MOCK_LOG")"
no_reconsensus J-4
# J-5 시작만 기록됨(STARTED) + tree 그대로 + 이번 호출의 유효한 DONE 결과가 남음(게이트·세션 수용 완료 여부 불명) → 자동 재호출하지 않는다
reset_tree; printf 'DOCGAP' > "$MOCK_STATE/review-next"
rc="$(run_runner)"; [ "$rc" -eq 2 ] || fail "J-5: 전제 실패"
answer_review_gap; touch "$MOCK_STATE/crash-review-gap"
rc="$(run_runner)"; [ "$rc" -eq 1 ] && [ "$(gap .next_step)" = WORKER_PENDING ] && [ "$(gap .worker_run.state)" = STARTED ] || fail "J-5: 전제(STARTED 기록) 실패: $(cat .agent-work/doc-gap-resume.json)"
cp "$TMP/j.result" .agent-work/review-gap-result.json
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] && [ ! -s "$MOCK_LOG" ] \
  || { tail -5 "$TMP/run.log"; fail "J-5: 완료 기록 없는 결과를 재사용하거나 워커를 자동 재호출함 ($rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"; }
# 결과 파일이 유효한 JSON 이 아니어도 시작 기록 당시와 다른 내용이 남아 있으면 CLI 가 돌았다는 뜻이다 → 자동 재호출하지 않는다
printf '{"status":"DONE","undecided":[' > .agent-work/review-gap-result.json
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] && [ ! -s "$MOCK_LOG" ] && [ "$(gap .worker_run.state)" = STARTED ] \
  || { tail -5 "$TMP/run.log"; fail "J-5: 깨진 결과가 남은 STARTED 에서 워커를 자동 재호출함 ($rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"; }
# 결과가 없으면(호출이 결과 없이 실패 — 사례 D-1 과 같은 상태) 기존 정책대로 워커부터 다시 돈다
mv .agent-work/review-gap-result.json "$TMP/j.result.spent"
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(paste -sd'|' "$MOCK_LOG")" = "review-gap-worker|reviewer APPROVE|full-test|full-lint" ] || { tail -20 "$TMP/run.log"; fail "J-5: 결과 없는 STARTED 에서 워커부터 재개되지 않음 ($rc): $(paste -sd'|' "$MOCK_LOG")"; }
pass "J: 재사용은 같은 식별자·DONE 기록·tree·결과 파일 내용이 모두 맞을 때만(코드 변경 없는 실행 포함) — 결과/리뷰 내용 변경·완료 기록 없는 결과는 WORKER_OUTCOME_UNCERTAIN, tree 변경은 DOC_GAP_SOURCE_CHANGED"

# ===== 사례 K: REVIEW_PENDING 재개 — 체크포인트를 되돌리지 않은 정상 경로에서 완료 증명을 다시 확인한다 =====
reset_tree; printf 'DOCGAP' > "$MOCK_STATE/review-next"
rc="$(run_runner)"; [ "$rc" -eq 2 ] || fail "K: 전제 실패"
answer_review_gap; printf 'CRASH' > "$MOCK_STATE/review-next"
rc="$(run_runner)"; [ "$rc" -eq 1 ] && [ "$(gap .next_step)" = REVIEW_PENDING ] && [ "$(gap .worker_run.state)" = DONE ] && [ "$(gap .worker_run.before_tree)" != "$(gap .worker_run.after_tree)" ] \
  || { tail -20 "$TMP/run.log"; fail "K: 전제(워커 DONE 기록 + 리뷰어 crash → REVIEW_PENDING) 실패: $(cat .agent-work/doc-gap-resume.json)"; }
cp .agent-work/doc-gap-resume.json "$TMP/k.ck"; cp .agent-work/review-gap-result.json "$TMP/k.result"; REVIEW_K="$(gap .review)"; cp "$REVIEW_K" "$TMP/k.review"
k_uncertain() { # label grep-pattern
  rc="$(run_runner)"
  [ "$rc" -eq 2 ] && [ "$(reason)" = WORKER_OUTCOME_UNCERTAIN ] && [ ! -s "$MOCK_LOG" ] && [ "$(gap .next_step)" = REVIEW_PENDING ] && grep -q "$2" .agent-work/run-state.json \
    || { tail -5 "$TMP/run.log"; fail "$1: REVIEW_PENDING 에서 WORKER_OUTCOME_UNCERTAIN(모델 0회)이 아님 ($rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"; }
}
# K-1 완료 기록 뒤 결과 파일이 바뀜 → 리뷰로 들어가지 않는다
printf '\n' >> .agent-work/review-gap-result.json; k_uncertain K-1 '완료 기록 당시와 다르'; cp "$TMP/k.result" .agent-work/review-gap-result.json
# K-2 리뷰 내용이 바뀜(식별자 불일치)
printf '\n' >> "$REVIEW_K"; k_uncertain K-2 '식별자'; cp "$TMP/k.review" "$REVIEW_K"
# K-3 실행 기록이 없는 REVIEW_PENDING(이 검증 이전의 체크포인트·손으로 고친 체크포인트) → 완료를 증명할 수 없다
jq 'del(.worker_run)' "$TMP/k.ck" > .agent-work/doc-gap-resume.json; k_uncertain K-3 'worker_run'
# K-4 완료가 아닌 실행 기록(STARTED)인 REVIEW_PENDING
jq '.worker_run.state="STARTED"' "$TMP/k.ck" > .agent-work/doc-gap-resume.json; k_uncertain K-4 'DONE'
# K-4b 체크포인트 source tree 가 완료 기록의 after tree 와 다름(체크포인트와 실행 기록이 같은 실행을 가리키지 않는다)
jq '.source_tree=.worker_run.before_tree' "$TMP/k.ck" > .agent-work/doc-gap-resume.json; k_uncertain K-4b 'after tree'
cp "$TMP/k.ck" .agent-work/doc-gap-resume.json
# K-5 리뷰가 시작되기 전에 tree 가 after tree 와 달라짐 → DOC_GAP_SOURCE_CHANGED(자동 원복 없음)
cp src/u01.txt "$TMP/k.u01"; echo "external edit" >> src/u01.txt
rc="$(run_runner)"
[ "$rc" -eq 2 ] && [ "$(reason)" = DOC_GAP_SOURCE_CHANGED ] && [ ! -s "$MOCK_LOG" ] && [ "$(tail -1 src/u01.txt)" = "external edit" ] \
  || { tail -5 "$TMP/run.log"; fail "K-5: 리뷰 전 tree 변경인데 DOC_GAP_SOURCE_CHANGED(모델 0회·원복 없음)가 아님 ($rc/$(reason)): $(paste -sd'|' "$MOCK_LOG")"; }
# K-6 리뷰 루프가 이미 진행됐으면(수정자 대기 체크포인트 / 러너가 남긴 진행 표시) tree 차이는 리뷰 체크포인트의 몫이다 — 이 판정은 tree 로 막지 않는다
k_verdict() { ( source "$CFG"; doc_gap_review_entry_verdict "$(doc_gap_worker_identity)" "$(snapshot_worktree_tree)" >/dev/null; echo $? ); }
[ "$(k_verdict)" -eq 11 ] || fail "K-6: 전제 — 리뷰 진행 전 tree 변경이 11 이 아님"
cp .agent-work/review-impl.json "$TMP/k.review-impl" 2>/dev/null || true
printf '{"next_step":"FIXER_PENDING"}\n' > .agent-work/review-impl.json
[ "$(k_verdict)" -eq 0 ] || fail "K-6: 리뷰 루프가 진행 중(FIXER_PENDING)인데 tree 차이로 막음"
printf '{"next_step":"NONE"}\n' > .agent-work/review-impl.json
[ "$(k_verdict)" -eq 11 ] || fail "K-6: 리뷰 체크포인트가 초기화 상태인데 tree 차이를 통과시킴"
( source "$CFG"; doc_gap_mark_review_progressed ) && [ "$(k_verdict)" -eq 0 ] || fail "K-6: 러너의 진행 표시(review_progressed) 뒤에도 tree 차이로 막음"
printf '\n' >> .agent-work/review-gap-result.json
[ "$(k_verdict)" -eq 12 ] || fail "K-6: 리뷰가 진행됐어도 결과 파일 변경은 불확실(12)이어야 함"
cp "$TMP/k.result" .agent-work/review-gap-result.json; cp "$TMP/k.ck" .agent-work/doc-gap-resume.json; cp "$TMP/k.u01" src/u01.txt
if [ -f "$TMP/k.review-impl" ]; then cp "$TMP/k.review-impl" .agent-work/review-impl.json; else printf '{"next_step":"NONE"}\n' > .agent-work/review-impl.json; fi
# K-7 모든 조건이 맞으면 워커 재호출 없이 리뷰어부터
rc="$(run_runner)"
[ "$rc" -eq 0 ] && [ "$(status)" = DONE ] && [ "$(paste -sd'|' "$MOCK_LOG")" = "reviewer APPROVE|full-test|full-lint" ] && [ "$(gap .next_step)" = RESOLVED ] \
  || { tail -30 "$TMP/run.log"; fail "K-7: 조건이 모두 맞는 REVIEW_PENDING 재개가 리뷰어 → DONE 이 아님 ($rc/$(status)/$(reason)): $(paste -sd'|' "$MOCK_LOG")"; }
no_reconsensus K-7
pass "K: REVIEW_PENDING 재개도 완료 기록·식별자·결과 파일 해시를 확인한다 — 결과/리뷰 변경·실행 기록 없음은 WORKER_OUTCOME_UNCERTAIN, 리뷰 전 tree 변경은 DOC_GAP_SOURCE_CHANGED, 리뷰가 진행된 뒤의 tree 는 리뷰 체크포인트가 판정"

# ===== 사례 M: 리뷰 해시 없는 옛 활성 체크포인트를 다음 gap 으로 넘길 때 해시를 사후 생성하지 않는다 =====
# 픽스처: K-7 뒤의 해결된 체크포인트(RESOLVED, 유효)에서 review_sha256 만 없앤다 = 이 필드가 생기기 전에 기록된 체크포인트
cp .agent-work/doc-gap-resume.json "$TMP/m.ck"
( source "$CFG"; doc_gap_resolved_current ) || fail "M: 전제 — K-7 뒤 체크포인트가 유효한 해결 상태가 아님"
[ -f "$(gap .review)" ] || fail "M: 전제 — 원본 리뷰 파일이 없음(사후 해시가 만들어질 조건이 아님)"
( source "$CFG"; _doc_gap_carry_prior | jq -e '.[-1].review_sha256|length==64' >/dev/null ) || fail "M: 전제 — 해시가 있는 체크포인트의 carry 가 해시를 넘기지 않음"
for strip in 'del(.review_sha256)' '.review_sha256=""'; do
  jq "$strip" "$TMP/m.ck" > .agent-work/doc-gap-resume.json
  ( source "$CFG"; _doc_gap_carry_prior | jq -e '.[-1].review_sha256=="" and .[-1].origin=="review" and (.[-1].answer|length)>0' >/dev/null ) \
    || fail "M: 해시 없는 체크포인트($strip)를 넘기면서 현재 리뷰 내용으로 해시를 만들어 넣음: $( ( source "$CFG"; _doc_gap_carry_prior ) )"
  # 넘어간 기록은 검증 근거가 없으므로 다음 체크포인트에서 유효한 앞선 해결로 인정되지 않는다
  ( source "$CFG"; jq --argjson p "$(_doc_gap_carry_prior)" '.prior_gaps=$p' "$DOC_GAP_RESUME" > "$DOC_GAP_RESUME.m" && cp "$DOC_GAP_RESUME.m" "$DOC_GAP_RESUME"; [ "$(doc_gap_prior_valid_tags)" = '[]' ] ) \
    || fail "M: 해시 없이 넘어간 앞선 해결 기록($strip)이 유효로 인정됨"
done
cp "$TMP/m.ck" .agent-work/doc-gap-resume.json
pass "M: 리뷰 해시 없는 옛 체크포인트는 다음 gap 으로 넘어가도 해시가 사후 생성되지 않고, 검증 근거 없는 기록으로 남아 인정되지 않는다"

# ===== 사례 L: tag 중복 검사 — pipefail + 큰 문서 =====
cp .agent-work/decisions.md "$TMP/l.decisions"
{ printf -- '- [USER-QUESTION][scope=impl][review-issue=R-77] 질문 → 답\n'; i=0; while [ "$i" -lt 6000 ]; do printf -- '- [round %s] 합의 이력 줄 — 파이프 버퍼를 넘기기 위한 채움 문장이다 0123456789 0123456789 0123456789\n' "$i"; i=$((i + 1)); done; } > .agent-work/decisions.md
[ "$(wc -c < .agent-work/decisions.md)" -gt 300000 ] || fail "L: 전제 — 문서가 파이프 버퍼보다 크지 않음"
( set -o pipefail; source "$CFG"; _doc_gap_tag_taken 'review-issue=R-77' '[]' ) || fail "L: pipefail 아래 큰 decisions.md 의 첫 줄에 있는 tag 를 '쓰이지 않음'으로 판정"
( set -o pipefail; source "$CFG"; _doc_gap_tag_taken 'review-issue=R-78' '[]' ) && fail "L: 쓰이지 않은 tag 를 '쓰임'으로 판정"
( set -o pipefail; source "$CFG"; [ "$(_doc_gap_unique_tags '[{"tag":"review-issue=R-77"}]' '[]' | jq -r '.[0].tag')" = 'review-issue=R-77@2' ] ) || fail "L: 이미 쓰인 tag 가 @2 로 유일화되지 않음"
cp "$TMP/l.decisions" .agent-work/decisions.md
pass "L: tag 중복 검사는 pipefail 아래 큰 문서에서도 이미 쓰인 tag 를 찾는다(SIGPIPE 오판 없음)"

rm -rf "$TMP"
echo "smoke-doc-gap: 전부 통과"
