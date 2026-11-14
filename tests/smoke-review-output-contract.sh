#!/usr/bin/env bash
# =============================================================
# 스모크: 구현 리뷰 출력 계약 — fix_ref 정의·검증 통일(P0-1)과 REVIEW_OUTPUT_INVALID 재실행 게이트(P0-2)
# 파일 경로: tests/smoke-review-output-contract.sh   (실제 LLM 호출 없음 — fake codex 리뷰어 / fake claude 수정자, 임시 저장소)
# 사용법: bash tests/smoke-review-output-contract.sh
#
# 불변식:
#   - fix_ref = 직전 수정으로 실제 바뀐 저장소 상대 소스 파일 경로:L시작-L끝. 패치 파일 경로·행 번호가 아니고, 수정 후 소스의 변경 hunk 와 겹쳐야 한다(git tree 기준).
#   - 출력 계약 위반은 ENV_ERROR(exit 1)가 아니라 REVIEW_OUTPUT_INVALID(exit 4): 구조화 진단, 원본·이벤트·invocation id 보존, 세션 미수용, 수정자 미호출.
#   - 같은 입력·같은 계약의 재실행은 리뷰어 0회로 같은 진단. resume marker 를 지우지 않는다. 검사기를 고치면 저장된 출력을 로컬 재검증한다.
#   - 새 모델 호출은 명시적 새 리뷰 시도(--new-attempt)로만 — 새 attempt, 새 세션.
# 사례:
#   R2.  Round 2 FIX_REGRESSION + 변경 소스 파일의 정확한 hunk(previous_issue_id 공백) → 유효한 리뷰로 수용
#   R2b. 삭제뿐인 수정 → 삭제 지점에 맞닿은 줄(anchor)을 가리킨 fix_ref 수용
#   R1.  Round 2 FIX_REGRESSION + 패치 파일 fix_ref → INVALID_FIX_REF, exit 4
#   R5.  같은 무효 출력으로 두 번 재실행 → 리뷰어 호출 0, 원본·지문·진단 보존, resume marker 유지
#   R3.  경로는 맞지만 hunk 밖 줄 / 경로 이탈 / 시작>끝 → 각각 따로 거부(여러 위반을 하나로 합치지 않음), verdict 수용 금지
#   R4.  UNRESOLVED_PREVIOUS: 직전 id 일치 수용 / 불일치 거부 / fix_ref 혼용 거부, FIX_REGRESSION 의 previous_issue_id 혼용 거부
#   R5b. Round 1(새 세션) 무효 출력도 재실행 리뷰어 0회
#   R6.  검사기 버그 수정 뒤 저장된 JSON 로컬 재검증 → 리뷰어 0회로 수용(세션 수용·marker 해제는 그때), 입력이 달라졌으면 0회로 멈추고 --new-attempt 로만 새 리뷰
#   R6b. 재검증 수용 도중 세션 확정 실패 → 무효 기록은 active 그대로(먼저 닫지 않는다), 재실행은 리뷰어 0회로 같은 재검증을 이어간다
#   R7.  코드(tree)는 그대로인데 계약 문서(approach.md) 내용이 바뀜 → 저장된 출력은 다른 계약의 리뷰 — 재사용하지 않고 0회로 멈춤(달라진 문서 표시)
#   R3b. hunk 없는 변경(파일 mode 만)을 가리킨 fix_ref 는 줄 번호가 무엇이든 거부
#   R8.  검사기 버전(REVIEW_CHECKER_VERSION)만 바뀜 → 저장된 APPROVE 를 그대로 믿지 않고 로컬 재검증(리뷰어 0회), 새 검사기로 무효면 승인 미재사용
#   R11. DOC_GAP 의 code_refs 가 일부라도 파일 경로로 확정되지 않으면(비정규·지어낸 경로·디렉터리) DOC_GAP_CODE_REF_PATH — gap 체크포인트를 만들지 않는다
#   R9.  스키마 전체 검사: 필수 필드 누락·빈 code_refs(minItems)·enum 밖 origin·정의되지 않은 필드 → SCHEMA_INVALID(위반마다 따로, issue id·필드 경로 포함)
#   R10. 코드는 그대로인데 계약 문서·사용자 결정이 바뀜 → 과거 APPROVE 재사용 금지(새 attempt 로 리뷰). 판정 이력 줄만 늘면 승인 유지
#   R10b. APPROVE 이후 conventions.md 만 생성·변경·삭제 → 기존 승인 무효 → 새 리뷰. 옛 체크포인트 포맷은 해석하지 않는다
# =============================================================
set -u
PROJECT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$PROJECT_SRC/.claude/skills/feature"
TMP="${TMPDIR:-/tmp}/feature-smoke-review-contract-$$"
mkdir -p "$TMP/bin" "$TMP/repo/.claude/hooks" "$TMP/side"
fail() { echo "[SMOKE FAIL] $*" >&2; exit 1; }
pass() { echo "[SMOKE PASS] $*"; }

mkdir -p "$TMP/repo/.claude/skills" && cp -R "$SKILL_SRC" "$TMP/repo/.claude/skills/feature" || fail "스킬 복사 실패"
cp "$PROJECT_SRC/.claude/hooks/core_rules.md" "$TMP/repo/.claude/hooks/" 2>/dev/null || echo "core rules" > "$TMP/repo/.claude/hooks/core_rules.md"
CFG="$TMP/repo/.claude/skills/feature/config.sh"
sed -i.bak "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$TMP/bin/claude\"|; s|^CODEX_BIN=.*|CODEX_BIN=\"$TMP/bin/codex\"|; s|^TEST_CMD=\"CHANGE_ME\"|TEST_CMD=\"true\"|; s|^LINT_CMD=\"CHANGE_ME\"|LINT_CMD=\"true\"|; s/^MAX_IMPL_ROUNDS=.*/MAX_IMPL_ROUNDS=1/" "$CFG" && rm -f "$CFG.bak"
# 역할별 CLI 고정(스모크 역할 CLI 고정 원칙): 리뷰어 = codex(세션 resume·marker 규약을 함께 본다), 수정자 = claude. 쓰지 않는 역할도 가짜 bin 으로만 간다.
sed -i.bak 's/^REVIEWER_CLI=.*/REVIEWER_CLI="codex"/; s/^VALIDATOR_CLI=.*/VALIDATOR_CLI="codex"/; s/^FIXER_CLI=.*/FIXER_CLI="claude"/; s/^DESIGNER_CLI=.*/DESIGNER_CLI="claude"/; s/^WORKER_CLI=.*/WORKER_CLI="claude"/' "$CFG" && rm -f "$CFG.bak"
cp "$CFG" "$TMP/side/config.good.sh"
cd "$TMP/repo" || exit 1
git init -q
printf '.agent-work/\n.claude/\n' > .gitignore
mkdir -p src && for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "line $i"; done > src/u01.txt
git add -A && git -c user.email=smoke@test -c user.name=smoke commit -qm baseline
mkdir -p .agent-work/reviews
for doc in request design implementation approach; do printf '# %s\n' "$doc" > ".agent-work/$doc.md"; done
: > .agent-work/decisions.md
printf '{"version":1,"files":["src/u01.txt"],"new_file_roots":[]}\n' > .agent-work/feature-scope.json
cp .agent-work/feature-scope.json .agent-work/feature-scope.lock.json
printf '{"status":"DONE","undecided":[],"delegated_choices":[],"tests":[],"context_updates":{"upsert":[],"remove":[]}}\n' > .agent-work/worker-result.json
( source "$CFG"; snapshot_worktree_tree ) > .agent-work/worker-baseline.tree
REVIEW_LOOP=".claude/skills/feature/scripts/impl-review-loop.sh"
V="$(grep -E '^REVIEWER_CONTRACT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
export MOCK_LOG="$TMP/calls.log" MOCK_STATE="$TMP/mock-state" FEATURE_LIVE_TEE=1
mkdir -p "$MOCK_STATE"

# --- fake codex(리뷰어): n 번째 호출에 $MOCK_STATE/review-<n>.json 을 -o 에 쓴다. thread.started / turn.completed 이벤트, resume 은 같은 thread id ---
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = exec ] || { echo "unexpected argv: $*" >&2; exit 9; }
shift
mode=new; sid=""
if [ "${1:-}" = resume ]; then
  shift
  if [ "${1:-}" = --help ]; then printf '      --json\n      --output-schema <FILE>\n  -o, --output-last-message <FILE>\n'; exit 0; fi
  mode=resume; sid="$1"; shift
fi
out=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; --output-schema|-m|--sandbox|-c) shift 2;; *) shift;; esac; done
n=$(( $(cat "$MOCK_STATE/codex.n" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$MOCK_STATE/codex.n"
echo "codex $mode ${sid:-none} n=$n" >> "$MOCK_LOG"
if [ "$mode" = resume ]; then tid="$sid"; else tid="tid-$n"; fi
printf '{"type":"thread.started","thread_id":"%s"}\n' "$tid"
printf '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10}}\n'
[ -f "$MOCK_STATE/review-$n.json" ] || { echo "no fixture for call $n" >&2; exit 1; }
cp "$MOCK_STATE/review-$n.json" "$out"
EOF
# --- fake claude(수정자): FAKE_EDIT_CMD 실행 ---
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude fixer" >> "$MOCK_LOG"
eval "${FAKE_EDIT_CMD:-true}"
printf '{"result":"ok","session_id":"fake","total_cost_usd":0,"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
EOF
chmod +x "$TMP/bin/codex" "$TMP/bin/claude"

ISSUE='{"id":"R-01","action":"FIX_CODE","category":"CONTRACT_VIOLATION","evidence_type":"DIRECT_MISMATCH","basis_refs":["approach.md:L1"],"code_refs":["src/u01.txt:L3-L3"],"reachable_scenario":"","impact":"","why_blocks_now":"x","required_outcome":"y","origin":"ROUND_1","previous_issue_id":"","fix_ref":"","user_question":"","options":[]}'
review_of() { # issue-json... → REQUEST_CHANGES 리뷰 (인자 없으면 APPROVE)
  if [ "$#" -eq 0 ]; then printf '{"schema_version":%s,"verdict":"APPROVE","issues":[]}\n' "$V"; return; fi
  printf '%s\n' "$@" | jq -sc --argjson v "$V" '{schema_version:$v, verdict:"REQUEST_CHANGES", issues:.}'
}
issue() { printf '%s' "$ISSUE" | jq -c "$1"; }   # jq 필터로 ISSUE 변형
# 수정자: 8번째 줄을 바꾼다(수정 후 소스의 변경 hunk = L8). 임시 파일은 저장소 밖에 둔다(범위 밖 변경 방지).
FIX_LINE8='awk "NR==8{print \"line 8 fixed\";next}{print}" src/u01.txt > "$MOCK_STATE/u01.new" && cp "$MOCK_STATE/u01.new" src/u01.txt; echo "- [fix round 1] R-01 ACCEPT" >> .agent-work/decisions.md'
FIX_DELETE8='awk "NR!=8" src/u01.txt > "$MOCK_STATE/u01.new" && cp "$MOCK_STATE/u01.new" src/u01.txt; echo "- [fix round 1] R-01 ACCEPT" >> .agent-work/decisions.md'
reset_case() { # 테스트 환경 정리(파이프라인 동작 아님)
  : > "$MOCK_LOG"; rm -f "$MOCK_STATE"/codex.n "$MOCK_STATE"/review-*.json
  rm -rf .agent-work/reviews/impl-attempt-* .agent-work/reviews/invalid-review.json .agent-work/review-impl.json .agent-work/approved.fingerprint .agent-work/state.json
  rm -f .agent-work/.session-* .agent-work/usage.jsonl; : > .agent-work/decisions.md
  cp "$TMP/side/config.good.sh" "$CFG"
  git checkout -q -- src/u01.txt
  awk 'NR==3{print "line 3 worker";next}{print}' src/u01.txt > "$MOCK_STATE/u01.new" && cp "$MOCK_STATE/u01.new" src/u01.txt   # 워커의 변경(리뷰 대상)
}
run_loop() { # [loop args…] → exit code, 로그 $TMP/loop.log   (FAKE_EDIT_CMD 는 호출자가 export)
  bash "$REVIEW_LOOP" "$@" > "$TMP/loop.log" 2>&1; echo $?
}
# Round 1 REQUEST_CHANGES(R-01) → 수정자 → Round 2 = 주어진 리뷰
run_round2() { # round2-review-json [fixer-cmd]
  reset_case
  review_of "$ISSUE" > "$MOCK_STATE/review-1.json"; printf '%s\n' "$1" > "$MOCK_STATE/review-2.json"
  FAKE_EDIT_CMD="${2:-$FIX_LINE8}" run_loop
}
codex_calls() { grep -c '^codex ' "$MOCK_LOG" || true; }
fixer_calls() { grep -c '^claude fixer' "$MOCK_LOG" || true; }
st() { jq -r "$1" .agent-work/state.json; }
inv() { jq -r "$1" .agent-work/reviews/invalid-review.json; }
MARKER=".agent-work/.session-reviewer-a01.resume-pending.json"
LEDGER=".agent-work/.session-reviewer-a01.codex.json"
# FIX_REGRESSION issue: id 와 fix_ref 만 바꾼다(중첩 따옴표·brace expansion 을 피하려고 jq --arg 로 조립)
reg() { printf '%s' "$ISSUE" | jq -c --arg id "$1" --arg ref "$2" '. + {id:$id, origin:"FIX_REGRESSION", previous_issue_id:"", code_refs:["src/u01.txt:L8-L8"], fix_ref:$ref}'; }

# ===== R2: 정확한 hunk 를 가리킨 FIX_REGRESSION → 유효한 리뷰 =====
rc="$(run_round2 "$(review_of "$(reg R-02 'src/u01.txt:L8-L8')")")"
[ "$rc" -eq 2 ] && [ "$(st .status)" = MAX_ROUNDS_EXCEEDED ] || { tail -20 "$TMP/loop.log"; fail "R2: 유효한 Round 2 리뷰가 수용되지 않음 (rc $rc, $(st .status))"; }
[ ! -f .agent-work/reviews/invalid-review.json ] || fail "R2: 유효한 출력인데 invalid-review.json 이 생김"
[ ! -f "$MARKER" ] && jq -e '.last_accepted_label=="impl-review-a01-round-02"' "$LEDGER" >/dev/null || fail "R2: 유효한 Round 2 의 세션이 수용되지 않음"
grep -qx 'src/u01.txt' .agent-work/reviews/impl-attempt-01/fix-files-round-02.txt || fail "R2: 수정으로 바뀐 소스 파일 목록(fix-files-round-02.txt)이 없음"
pass "R2: 변경 소스 파일의 정확한 hunk(previous_issue_id 공백) → 유효한 리뷰로 수용"

# ===== R2b: 삭제뿐인 수정 — 삭제 지점에 맞닿은 줄이 anchor =====
rc="$(run_round2 "$(review_of "$(reg R-02 'src/u01.txt:L7-L7')")" "$FIX_DELETE8")"
[ "$rc" -eq 2 ] && [ "$(st .status)" = MAX_ROUNDS_EXCEEDED ] || { tail -20 "$TMP/loop.log"; fail "R2b: 삭제 hunk 의 anchor(L7)가 거부됨 (rc $rc)"; }
rc="$(run_round2 "$(review_of "$(reg R-02 'src/u01.txt:L10-L11')")" "$FIX_DELETE8")"
[ "$rc" -eq 4 ] && [ "$(inv '.errors[0].rule_id')" = INVALID_FIX_REF ] || fail "R2b: 삭제 지점과 무관한 줄 범위가 수용됨 (rc $rc)"
pass "R2b: 삭제뿐인 수정은 수정 후 파일의 삭제 지점 anchor 만 인정"

# ===== R1: 패치 파일을 가리킨 fix_ref → INVALID_FIX_REF =====
rc="$(run_round2 "$(review_of "$(reg R-02 '.agent-work/reviews/impl-attempt-01/fix-diff-round-02.patch:L3-L5')")")"
[ "$rc" -eq 4 ] || { tail -20 "$TMP/loop.log"; fail "R1: 패치 파일 fix_ref 의 종료 코드가 4 가 아님 ($rc)"; }
[ "$(st .status)" = REVIEW_OUTPUT_INVALID ] || fail "R1: state.json 이 REVIEW_OUTPUT_INVALID 가 아님 ($(st .status))"
jq -e '.active==true and .status=="REVIEW_OUTPUT_INVALID" and .attempt==1 and .round==2 and (.errors|length)==1
       and .errors[0].rule_id=="INVALID_FIX_REF" and .errors[0].issue_id=="R-02" and .errors[0].field=="fix_ref"
       and (.errors[0].observed|test("fix-diff-round-02.patch")) and (.errors[0].expected|startswith("fix_ref = "))
       and (.result_sha256|length)==64 and (.input_fingerprint|length)==64 and (.invocation_id|length)>0
       and (.input.prev_tree|length)>=40 and (.input.cur_tree|length)>=40 and .input.reviewer_contract_version!=null and (.input.scope_hash|length)==64
       and (.input.prev_review|endswith("reviewer-round-01.json"))
       and ([.input.contract_docs_sha256 | to_entries[] | select(.value|length==64) | .key] | sort) == ["approach.md","decisions.md","design.md","implementation.md","request.md"]
       and (.checker_version|type)=="number"' .agent-work/reviews/invalid-review.json >/dev/null \
  || fail "R1: invalid-review.json 구조화 진단·입력 지문 불일치: $(cat .agent-work/reviews/invalid-review.json)"
[ "$(fixer_calls)" -eq 1 ] || fail "R1: 무효 출력 뒤 수정자가 다시 호출됨"
[ ! -f .agent-work/approved.fingerprint ] || fail "R1: 무효 출력이 승인으로 처리됨"
jq -e '.last_accepted_label=="impl-review-a01-round-01"' "$LEDGER" >/dev/null || fail "R1: 무효 Round 2 의 세션이 수용됨"
[ -f "$MARKER" ] || fail "R1: 미수용 resume marker 가 사라짐"
[ "$(jq -r .next_step .agent-work/review-impl.json)" = REVIEW_OUTPUT_INVALID ] || fail "R1: 체크포인트 next_step 이 REVIEW_OUTPUT_INVALID 가 아님"
pass "R1: 패치 파일 fix_ref → 구조화된 INVALID_FIX_REF, exit 4, 수정자·승인·세션 수용 없음"

# ===== R5: 같은 무효 출력 상태로 두 번 재실행 → 리뷰어 0회, 원본·지문·진단 보존, marker 유지 =====
R2JSON=".agent-work/reviews/impl-attempt-01/reviewer-round-02.json"
sha_before="$(shasum -a 256 "$R2JSON" | cut -d' ' -f1)"; rec_before="$(inv '[.result_sha256,.input_fingerprint,.invocation_id,.recorded_at,(.errors|tojson)]|join("|")')"
events_before="$(shasum -a 256 "$R2JSON.events.jsonl" | cut -d' ' -f1)"; marker_before="$(cat "$MARKER")"
for i in 1 2; do
  : > "$MOCK_LOG"
  rc="$(FAKE_EDIT_CMD="$FIX_LINE8" run_loop)"
  [ "$rc" -eq 4 ] && [ "$(codex_calls)" -eq 0 ] && [ "$(fixer_calls)" -eq 0 ] || { tail -20 "$TMP/loop.log"; fail "R5: 재실행 $i 회차 — rc $rc, 리뷰어 $(codex_calls)회, 수정자 $(fixer_calls)회 (모델 0회·exit 4 기대)"; }
  grep -q 'INVALID_FIX_REF' "$TMP/loop.log" || fail "R5: 재실행 $i 회차가 같은 진단을 돌려주지 않음"
  grep -q 'SESSION_RESUME_UNCERTAIN' "$TMP/loop.log" && fail "R5: 재실행이 codex resume 경로까지 감(모델 호출 전 게이트가 아님)"
done
[ "$(shasum -a 256 "$R2JSON" | cut -d' ' -f1)" = "$sha_before" ] && [ "$(shasum -a 256 "$R2JSON.events.jsonl" | cut -d' ' -f1)" = "$events_before" ] || fail "R5: 원본 결과 JSON 또는 이벤트 로그가 덮어써짐"
[ "$(inv '[.result_sha256,.input_fingerprint,.invocation_id,.recorded_at,(.errors|tojson)]|join("|")')" = "$rec_before" ] || fail "R5: 무효 기록(지문·진단·invocation id)이 바뀜"
[ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$marker_before" ] || fail "R5: resume marker 가 삭제·변경됨"
[ "$(ls -d .agent-work/reviews/impl-attempt-* | wc -l | tr -d ' ')" -eq 1 ] || fail "R5: 재실행이 새 attempt 를 만듦"
pass "R5: 무효 출력 재실행 2회 — 리뷰어 호출 0, 원본·이벤트·지문·진단 보존, resume marker 그대로"

# ===== R3: hunk 밖 줄 / 경로 이탈 / 시작>끝 — 위반마다 따로 기록 =====
rc="$(run_round2 "$(review_of \
  "$(reg R-02 'src/u01.txt:L1-L2')" \
  "$(reg R-03 '../outside.txt:L1-L1')" \
  "$(reg R-04 'src/u01.txt:L9-L8')" \
  "$(reg R-05 'src/u01.txt:8')" \
  "$(reg R-06 'src/u01.txt:L8-L9')")")"
[ "$rc" -eq 4 ] || { tail -20 "$TMP/loop.log"; fail "R3: 종료 코드가 4 가 아님 ($rc)"; }
[ "$(inv '[.errors[] | select(.rule_id=="INVALID_FIX_REF") | .issue_id] | sort | join(",")')" = "R-02,R-03,R-04,R-05" ] \
  || fail "R3: 위반 issue 집합 불일치(유효한 R-06 은 빠져야 하고 나머지는 각각 기록): $(inv '[.errors[] | "\(.issue_id):\(.rule_id)"] | join(",")')"
inv '.errors[] | select(.issue_id=="R-02") | .observed' | grep -q '겹치지 않음' || fail "R3: hunk 밖 범위의 사유가 기록되지 않음"
[ ! -f .agent-work/approved.fingerprint ] && [ "$(st .status)" = REVIEW_OUTPUT_INVALID ] || fail "R3: verdict 가 수용됨"
pass "R3: 변경 파일이어도 hunk 밖 줄 범위는 거부, 경로 이탈·범위 역전·형식 위반도 issue 별로 따로 진단"

# ===== R4: UNRESOLVED_PREVIOUS / previous_issue_id =====
rc="$(run_round2 "$(review_of "$(issue '. + {origin:"UNRESOLVED_PREVIOUS", previous_issue_id:"R-01", required_outcome:"y2"}')")")"
[ "$rc" -eq 2 ] && [ ! -f .agent-work/reviews/invalid-review.json ] || { tail -20 "$TMP/loop.log"; fail "R4: 직전 id 와 일치하는 UNRESOLVED_PREVIOUS 가 거부됨 (rc $rc)"; }
rc="$(run_round2 "$(review_of "$(issue '. + {id:"R-09", origin:"UNRESOLVED_PREVIOUS", previous_issue_id:"R-09"}')")")"
[ "$rc" -eq 4 ] && [ "$(inv '.errors[0] | "\(.rule_id):\(.issue_id):\(.field)"')" = "INVALID_PREVIOUS_ISSUE_ID:R-09:previous_issue_id" ] || fail "R4: 직전 리뷰에 없는 id 의 UNRESOLVED_PREVIOUS 가 통과됨 (rc $rc)"
rc="$(run_round2 "$(review_of "$(issue '. + {origin:"UNRESOLVED_PREVIOUS", previous_issue_id:"R-01", fix_ref:"src/u01.txt:L8-L8"}')")")"
[ "$rc" -eq 4 ] && [ "$(inv '.errors[0] | "\(.rule_id):\(.field)"')" = "INVALID_FIX_REF:fix_ref" ] || fail "R4: UNRESOLVED_PREVIOUS 의 fix_ref 혼용이 통과됨 (rc $rc)"
rc="$(run_round2 "$(review_of "$(reg R-02 'src/u01.txt:L8-L8' | jq -c '.previous_issue_id="R-01"')")")"
[ "$rc" -eq 4 ] && [ "$(inv '.errors[0].rule_id')" = INVALID_PREVIOUS_ISSUE_ID ] || fail "R4: FIX_REGRESSION 의 previous_issue_id 혼용이 통과됨 (rc $rc)"
pass "R4: UNRESOLVED_PREVIOUS 는 직전 id 일치만 수용, 불일치·fix_ref 혼용·previous_issue_id 혼용 거부"

# ===== R5b: Round 1(새 세션 — marker 없음) 무효 출력도 재실행 0회 =====
reset_case
review_of "$ISSUE" | jq -c '.verdict="APPROVE"' > "$MOCK_STATE/review-1.json"
rc="$(run_loop)"; [ "$rc" -eq 4 ] && [ "$(inv '.errors[0].rule_id')" = VERDICT_INCONSISTENT ] && [ "$(inv .round)" = 1 ] || { tail -20 "$TMP/loop.log"; fail "R5b: 모순 verdict 가 REVIEW_OUTPUT_INVALID 가 아님 (rc $rc)"; }
[ ! -f "$LEDGER" ] || fail "R5b: 무효 Round 1 의 세션 원장이 확정됨"
: > "$MOCK_LOG"; rc="$(run_loop)"
[ "$rc" -eq 4 ] && [ "$(codex_calls)" -eq 0 ] || fail "R5b: Round 1 무효 출력 재실행이 리뷰어를 다시 부름 (rc $rc, $(codex_calls)회)"
pass "R5b: 새 세션의 무효 출력도 재실행은 리뷰어 0회(같은 프롬프트로 새 비용을 지불하지 않는다)"

# ===== R6: 검사기 버그 수정 뒤 저장된 출력 로컬 재검증 =====
sabotage_checker() { # fix_ref 대조가 항상 실패하는 '버그 있는 검사기'
  perl -0pi -e 's/(review_fix_ref_violation\(\) \{[^\n]*\n)/$1  echo "simulated checker bug"; return 1\n/' "$CFG"
  grep -q 'simulated checker bug' "$CFG" || fail "R6: 검사기 변조 픽스처 실패"
}
reset_case; sabotage_checker
review_of "$ISSUE" > "$MOCK_STATE/review-1.json"; review_of "$(reg R-02 'src/u01.txt:L8-L8')" > "$MOCK_STATE/review-2.json"
rc="$(FAKE_EDIT_CMD="$FIX_LINE8" run_loop)"
[ "$rc" -eq 4 ] && inv '.errors[0].observed' | grep -q 'simulated checker bug' || { tail -20 "$TMP/loop.log"; fail "R6: 전제(버그 있는 검사기가 유효한 출력을 거부) 실패 (rc $rc)"; }
[ -f "$MARKER" ] || fail "R6: 전제 — 미수용 marker 없음"
cp "$TMP/side/config.good.sh" "$CFG"   # 검사기 버그 수정(리뷰어에게 주는 지시·계약 버전은 그대로)
: > "$MOCK_LOG"; rc="$(FAKE_EDIT_CMD="$FIX_LINE8" run_loop)"
[ "$(codex_calls)" -eq 0 ] || fail "R6: 로컬 재검증이 리뷰어를 다시 부름: $(cat "$MOCK_LOG")"
[ "$rc" -eq 2 ] && [ "$(st .status)" = MAX_ROUNDS_EXCEEDED ] || { tail -20 "$TMP/loop.log"; fail "R6: 재검증된 출력이 유효한 리뷰로 처리되지 않음 (rc $rc, $(st .status))"; }
jq -e '.active==false and .status=="REVALIDATED"' .agent-work/reviews/invalid-review.json >/dev/null || fail "R6: 무효 기록이 REVALIDATED 로 닫히지 않음"
[ ! -f "$MARKER" ] && jq -e '.last_accepted_label=="impl-review-a01-round-02"' "$LEDGER" >/dev/null || fail "R6: 재검증 수용 시 세션 수용·marker 해제가 되지 않음"
grep -q '리뷰어 호출 생략' "$TMP/loop.log" || fail "R6: 저장된 출력 재사용 로그가 없음"
pass "R6: 검사기 수정 뒤 같은 입력·같은 계약이면 저장된 출력을 리뷰어 0회로 재검증·수용"

# 입력이 달라졌으면 저장된 출력을 재사용하지 않는다 — 리뷰어 0회로 멈추고, 새 리뷰는 명시적 새 attempt 로만
reset_case; sabotage_checker
review_of "$ISSUE" > "$MOCK_STATE/review-1.json"; review_of "$(reg R-02 'src/u01.txt:L8-L8')" > "$MOCK_STATE/review-2.json"
rc="$(FAKE_EDIT_CMD="$FIX_LINE8" run_loop)"; [ "$rc" -eq 4 ] || fail "R6: 전제 실패 (rc $rc)"
cp "$TMP/side/config.good.sh" "$CFG"
echo "edit after the invalid review" >> src/u01.txt
: > "$MOCK_LOG"; rc="$(run_loop)"
[ "$rc" -eq 4 ] && [ "$(codex_calls)" -eq 0 ] && st .why | grep -q '입력' || { tail -20 "$TMP/loop.log"; fail "R6: 입력이 바뀌었는데 0회 중단이 아님 (rc $rc, 리뷰어 $(codex_calls)회, why: $(st .why))"; }
jq -e '.active==true' .agent-work/reviews/invalid-review.json >/dev/null || fail "R6: 입력 변경 뒤 무효 기록이 닫힘"
review_of > "$MOCK_STATE/review-3.json"
: > "$MOCK_LOG"; rc="$(run_loop --new-attempt)"
[ "$rc" -eq 0 ] || { tail -20 "$TMP/loop.log"; fail "R6: 명시적 새 리뷰 시도가 승인으로 끝나지 않음 (rc $rc)"; }
[ "$(grep -c '^codex new ' "$MOCK_LOG")" -eq 1 ] && [ "$(grep -c '^codex resume ' "$MOCK_LOG")" -eq 0 ] || fail "R6: 새 리뷰 시도가 새 세션 1회가 아님: $(cat "$MOCK_LOG")"
[ -f .agent-work/reviews/impl-attempt-02/reviewer-round-01.json ] && jq -e '.attempt==2 and .next_step=="APPROVE"' .agent-work/review-impl.json >/dev/null || fail "R6: 새 attempt 02 Round 1 로 리뷰되지 않음"
jq -e '.active==false and .status=="SUPERSEDED"' .agent-work/reviews/invalid-review.json >/dev/null || fail "R6: 무효 기록이 SUPERSEDED 로 닫히지 않음"
[ -f "$MARKER" ] && [ -f .agent-work/reviews/impl-attempt-01/reviewer-round-02.json ] || fail "R6: 새 시도가 이전 attempt 의 미수용 marker 또는 원본 결과를 지움"
[ -f .agent-work/.session-reviewer-a02.codex.json ] || fail "R6: 새 attempt 의 세션 원장이 없음"
# 대기 중인 무효 출력이 없을 때 --new-attempt 는 유료 리뷰를 강제하지 않는다
: > "$MOCK_LOG"; rc="$(run_loop --new-attempt)"
[ "$rc" -eq 0 ] && [ "$(codex_calls)" -eq 0 ] && grep -q '무시' "$TMP/loop.log" || fail "R6: 무효 기록 없는 --new-attempt 가 리뷰어를 부르거나 승인 재사용을 깸 (rc $rc, $(codex_calls)회)"
pass "R6: 입력이 달라졌으면 리뷰어 0회로 멈추고, --new-attempt 만 새 attempt·새 세션으로 리뷰(이전 marker·원본 보존)"

# ===== R6b: 재검증 수용 도중 세션 확정이 실패해도 무효 기록을 먼저 닫지 않는다 — 재실행은 리뷰어 0회 =====
reset_case; sabotage_checker
review_of "$ISSUE" > "$MOCK_STATE/review-1.json"; review_of "$(reg R-02 'src/u01.txt:L8-L8')" > "$MOCK_STATE/review-2.json"
rc="$(FAKE_EDIT_CMD="$FIX_LINE8" run_loop)"; [ "$rc" -eq 4 ] || fail "R6b: 전제 실패 (rc $rc)"
cp "$TMP/side/config.good.sh" "$CFG"   # 검사기 버그 수정
perl -0pi -e 's/(role_session_accept\(\) \{[^\n]*\n)/$1  if [ "\$1" = REVIEWER ]; then echo "simulated session accept failure" >&2; return 1; fi\n/' "$CFG"
grep -q 'simulated session accept failure' "$CFG" || fail "R6b: 세션 확정 실패 주입 픽스처 실패"
: > "$MOCK_LOG"; rc="$(FAKE_EDIT_CMD="$FIX_LINE8" run_loop)"
[ "$rc" -eq 1 ] && [ "$(codex_calls)" -eq 0 ] && grep -q '리뷰어 세션 확정 실패' "$TMP/loop.log" || { tail -20 "$TMP/loop.log"; fail "R6b: 전제(재검증 수용 중 세션 확정 실패로 중단) 실패 (rc $rc, 리뷰어 $(codex_calls)회)"; }
jq -e '.active==true and .status=="REVIEW_OUTPUT_INVALID"' .agent-work/reviews/invalid-review.json >/dev/null || fail "R6b: 세션 확정이 실패했는데 무효 기록이 이미 닫힘($(inv .status)) — 재실행이 새 리뷰 호출로 간다"
[ -f "$MARKER" ] || fail "R6b: 세션 확정 실패인데 marker 가 해제됨"
cp "$TMP/side/config.good.sh" "$CFG"   # 실패 원인 제거
: > "$MOCK_LOG"; rc="$(FAKE_EDIT_CMD="$FIX_LINE8" run_loop)"
[ "$(codex_calls)" -eq 0 ] || fail "R6b: 중간 실패 뒤 재실행이 리뷰어를 다시 부름: $(cat "$MOCK_LOG")"
[ "$rc" -eq 2 ] && [ "$(st .status)" = MAX_ROUNDS_EXCEEDED ] || { tail -20 "$TMP/loop.log"; fail "R6b: 재실행이 같은 저장 출력을 이어 처리하지 않음 (rc $rc, $(st .status))"; }
jq -e '.active==false and .status=="REVALIDATED"' .agent-work/reviews/invalid-review.json >/dev/null || fail "R6b: 처리 완료 뒤 무효 기록이 REVALIDATED 로 닫히지 않음"
[ ! -f "$MARKER" ] && jq -e '.last_accepted_label=="impl-review-a01-round-02"' "$LEDGER" >/dev/null || fail "R6b: 재실행에서 세션 수용·marker 해제가 되지 않음"
[ "$(ls -d .agent-work/reviews/impl-attempt-* | wc -l | tr -d ' ')" -eq 1 ] || fail "R6b: 재실행이 새 attempt 를 만듦"
pass "R6b: 재검증 수용 중 세션 확정 실패 → 무효 기록 active 유지, 재실행은 리뷰어 0회로 같은 출력을 이어 처리한 뒤에만 REVALIDATED"

# ===== R7: 코드는 그대로, 계약 문서 내용만 바뀜 → 저장된 출력은 다른 계약의 리뷰 =====
reset_case; sabotage_checker
review_of "$ISSUE" > "$MOCK_STATE/review-1.json"; review_of "$(reg R-02 'src/u01.txt:L8-L8')" > "$MOCK_STATE/review-2.json"
rc="$(FAKE_EDIT_CMD="$FIX_LINE8" run_loop)"; [ "$rc" -eq 4 ] || fail "R7: 전제 실패 (rc $rc)"
cp "$TMP/side/config.good.sh" "$CFG"
tree_r7="$( ( source "$CFG"; snapshot_worktree_tree ) )"
printf '\n## 결정 X (REQUIRED)\n리뷰 뒤에 바뀐 계약\n' >> .agent-work/approach.md
[ "$( ( source "$CFG"; snapshot_worktree_tree ) )" = "$tree_r7" ] || fail "R7: 전제 — 계약 문서 변경이 source tree 를 바꿈(사례가 '코드는 그대로'를 검증하지 못함)"
: > "$MOCK_LOG"; rc="$(run_loop)"
[ "$rc" -eq 4 ] && [ "$(codex_calls)" -eq 0 ] && [ "$(fixer_calls)" -eq 0 ] || { tail -20 "$TMP/loop.log"; fail "R7: 계약 문서가 바뀌었는데 저장된 출력이 재사용됨 (rc $rc, 리뷰어 $(codex_calls)회)"; }
st .why | grep -q '계약 문서 approach.md' || fail "R7: 달라진 계약 문서가 진단에 없음: $(st .why)"
st .why | grep -q 'cur_tree\|approval_fingerprint' && fail "R7: 코드가 그대로인데 tree·승인 지문이 달라진 것으로 보고됨: $(st .why)"
jq -e '.active==true' .agent-work/reviews/invalid-review.json >/dev/null || fail "R7: 계약 변경 뒤 무효 기록이 닫힘"
printf '# approach\n' > .agent-work/approach.md   # 계약을 리뷰 당시로 되돌리면 같은 입력이다 → 로컬 재검증
: > "$MOCK_LOG"; rc="$(run_loop)"
[ "$rc" -eq 2 ] && [ "$(codex_calls)" -eq 0 ] && [ "$(st .status)" = MAX_ROUNDS_EXCEEDED ] || { tail -20 "$TMP/loop.log"; fail "R7: 계약을 되돌렸는데 로컬 재검증으로 이어지지 않음 (rc $rc)"; }
pass "R7: 리뷰 입력 지문이 계약 문서 내용을 포함 — 코드가 같아도 계약이 바뀌면 저장된 출력을 재사용하지 않는다(리뷰어 0회, 달라진 문서 표시)"

# ===== R3b: hunk 없는 변경(파일 mode 만) — 어떤 줄 범위도 fix_ref 가 될 수 없다 =====
reset_case
t1="$( ( source "$CFG"; snapshot_worktree_tree ) )"; chmod +x src/u01.txt; t2="$( ( source "$CFG"; snapshot_worktree_tree ) )"; chmod -x src/u01.txt
git diff --no-renames --name-only "$t1" "$t2" > "$TMP/changed.txt"
grep -qx 'src/u01.txt' "$TMP/changed.txt" && [ -z "$(git diff -U0 "$t1" "$t2" | grep '^@@')" ] || fail "R3b: 전제(mode 만 바뀐 tree — 변경 파일이지만 hunk 없음) 실패"
for ref in 'src/u01.txt:L999999-L999999' 'src/u01.txt:L1-L1'; do
  why="$( ( source "$CFG"; review_fix_ref_violation "$ref" "$t1" "$t2" "$TMP/changed.txt" ) )" && fail "R3b: hunk 없는 변경의 fix_ref '$ref' 가 통과됨"
  printf '%s' "$why" | grep -q 'hunk 가 없음' || fail "R3b: 거부 사유가 hunk 없음이 아님: $why"
done
pass "R3b: 파일 mode 만 바뀐 변경은 임의의 줄 번호(L999999)도 L1 도 fix_ref 로 인정하지 않는다"

# ===== R8: 검사기 버전만 바뀜 → 저장된 APPROVE 도 그대로 믿지 않고 로컬 재검증 =====
K="$(grep -E '^REVIEW_CHECKER_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
bump_checker() { sed -i.bak "s/^REVIEW_CHECKER_VERSION=.*/REVIEW_CHECKER_VERSION=$1/" "$CFG" && mv "$CFG.bak" "$TMP/side/config.bak.$1"; }
LOOP_GOOD="$TMP/side/impl-review-loop.good.sh"; cp "$REVIEW_LOOP" "$LOOP_GOOD"
reset_case
review_of > "$MOCK_STATE/review-1.json"
rc="$(run_loop)"; [ "$rc" -eq 0 ] && jq -e --argjson k "$K" '.next_step=="APPROVE" and .checker_version==$k' .agent-work/review-impl.json >/dev/null || { tail -20 "$TMP/loop.log"; fail "R8: 전제(승인 + 체크포인트에 검사기 버전 기록) 실패 (rc $rc)"; }
( source "$CFG"; impl_approval_current ) || fail "R8: 전제 — 같은 검사기 버전에서 승인이 유효하지 않음"
bump_checker "$((K + 1))"
( source "$CFG"; impl_approval_current ) && fail "R8: 검사기 버전이 바뀌었는데 러너의 승인 판정이 옛 APPROVE 를 그대로 유효로 봄"
: > "$MOCK_LOG"; rc="$(run_loop)"
[ "$rc" -eq 0 ] && [ "$(codex_calls)" -eq 0 ] && grep -q '로컬 재검증' "$TMP/loop.log" || { tail -20 "$TMP/loop.log"; fail "R8: 검사기 버전 변경 뒤 승인이 로컬 재검증(리뷰어 0회)으로 재사용되지 않음 (rc $rc, $(codex_calls)회)"; }
jq -e --argjson k "$((K + 1))" '.next_step=="APPROVE" and .checker_version==$k and .attempt==1' .agent-work/review-impl.json >/dev/null && ( source "$CFG"; impl_approval_current ) || fail "R8: 재검증 뒤 체크포인트의 검사기 버전이 갱신되지 않음"
# 새 검사기가 저장된 승인 출력을 거부하면 승인을 재사용하지 않는다(새 attempt 로 리뷰)
bump_checker "$((K + 2))"
perl -0pi -e 's/(validate_review_output\(\) \{[^\n]*\n)/$1  printf "%s" \x27[{"issue_id":"","field":"(root)","observed":"simulated stricter checker","expected":"x","rule_id":"SIMULATED"}]\x27; return 0\n/' "$REVIEW_LOOP"
grep -q 'simulated stricter checker' "$REVIEW_LOOP" || fail "R8: 더 엄격한 검사기 픽스처 실패"
review_of > "$MOCK_STATE/review-2.json"
: > "$MOCK_LOG"; rc="$(run_loop)"
cp "$LOOP_GOOD" "$REVIEW_LOOP"
grep -q '승인을 재사용하지 않는다' "$TMP/loop.log" && [ "$(codex_calls)" -eq 1 ] && [ -f .agent-work/reviews/impl-attempt-02/reviewer-round-01.json ] || { tail -20 "$TMP/loop.log"; fail "R8: 새 검사기로 무효인 승인이 재사용됨 (rc $rc, 리뷰어 $(codex_calls)회)"; }
[ "$rc" -eq 4 ] || fail "R8: (픽스처의 검사기는 모든 출력을 거부한다) 새 리뷰가 REVIEW_OUTPUT_INVALID 가 아님 (rc $rc)"
pass "R8: 검사기 버전만 바뀌어도 저장된 APPROVE 는 로컬 재검증 뒤에만 재사용(리뷰어 0회), 새 검사기로 무효면 승인 미재사용"

# ===== R9: 스키마 전체 검사 — required·minItems·enum·additionalProperties =====
reset_case   # Round 1: code_refs 빈 배열 + user_question·options 필드 누락
review_of "$(issue '. + {code_refs:[]} | del(.user_question, .options)')" > "$MOCK_STATE/review-1.json"
rc="$(run_loop)"
[ "$rc" -eq 4 ] && [ "$(inv '[.errors[].rule_id] | unique | join(",")')" = SCHEMA_INVALID ] || { tail -20 "$TMP/loop.log"; fail "R9: 필드 누락·빈 code_refs 가 스키마 위반으로 거부되지 않음 (rc $rc): $(inv '.errors|tojson' 2>/dev/null)"; }
[ "$(inv '[.errors[] | select(.issue_id=="R-01") | .field] | sort | join(",")')" = "issues[0].code_refs,issues[0].options,issues[0].user_question" ] \
  || fail "R9: 위반 필드가 각각 기록되지 않음: $(inv '[.errors[] | "\(.issue_id):\(.field):\(.observed)"] | join(" | ")')"
[ "$(fixer_calls)" -eq 0 ] && [ ! -f .agent-work/approved.fingerprint ] || fail "R9: 스키마 위반 출력이 수용됨"
rc="$(run_round2 "$(review_of "$(reg R-02 'src/u01.txt:L8-L8' | jq -c '.origin="BOGUS_ORIGIN"')")")"   # Round 2: enum 밖 origin
[ "$rc" -eq 4 ] && [ "$(inv '.errors[0] | "\(.rule_id):\(.issue_id):\(.field)"')" = "SCHEMA_INVALID:R-02:issues[0].origin" ] && inv '.errors[0].observed' | grep -q BOGUS_ORIGIN \
  || { tail -20 "$TMP/loop.log"; fail "R9: enum 밖 origin 이 통과됨 (rc $rc): $(inv '.errors|tojson' 2>/dev/null)"; }
reset_case   # 스키마에 없는 필드 / 루트 필수 필드 누락
review_of "$(issue '. + {severity:"high"}')" > "$MOCK_STATE/review-1.json"
rc="$(run_loop)"; [ "$rc" -eq 4 ] && [ "$(inv '.errors[0] | "\(.rule_id):\(.field)"')" = "SCHEMA_INVALID:issues[0].severity" ] || fail "R9: 스키마에 없는 필드가 통과됨 (rc $rc)"
reset_case
printf '{"schema_version":%s,"verdict":"APPROVE"}\n' "$V" > "$MOCK_STATE/review-1.json"
rc="$(run_loop)"; [ "$rc" -eq 4 ] && [ "$(inv '.errors[0] | "\(.rule_id):\(.field)"')" = "SCHEMA_INVALID:issues" ] && [ ! -f .agent-work/approved.fingerprint ] || fail "R9: issues 없는 APPROVE 가 통과됨 (rc $rc)"
pass "R9: 스키마의 required·minItems·enum·additionalProperties 위반은 SCHEMA_INVALID 로 필드별 진단(수정자·승인 없음)"

# ===== R11: DOC_GAP 의 code_refs 는 전부 파일 경로여야 한다 — 일부만 비정규여도 gap 체크포인트를 만들지 않는다 =====
docgap() { issue '. + {action:"DOC_GAP", category:"UNDECIDED_APPROACH", user_question:"어느 방식인가", options:["a","b"]}' | jq -c --argjson refs "$1" '.code_refs=$refs'; }
r11_invalid() { # 사례 code_refs-json 기대-field(쉼표) 기대-observed-조각
  reset_case; rm -f .agent-work/doc-gap-resume.json
  review_of "$(docgap "$2")" > "$MOCK_STATE/review-1.json"
  rc="$(run_loop)"
  [ "$rc" -eq 4 ] && [ "$(inv '[.errors[].rule_id] | unique | join(",")')" = DOC_GAP_CODE_REF_PATH ] && [ "$(inv '[.errors[].field] | join(",")')" = "$3" ] && inv '.errors[0].observed' | grep -qF -- "$4" \
    || { tail -20 "$TMP/loop.log"; fail "R11($1): 비정규 code_refs 가 DOC_GAP_CODE_REF_PATH 로 거부되지 않음 (rc $rc): $(inv '.errors|tojson' 2>/dev/null)"; }
  [ ! -f .agent-work/doc-gap-resume.json ] && [ "$(fixer_calls)" -eq 0 ] && [ ! -f .agent-work/approved.fingerprint ] || fail "R11($1): 거부된 리뷰로 gap 체크포인트·수정자·승인이 생김"
}
r11_invalid 일부-절대경로 '["src/u01.txt:L3-L3","/abs/src/b/B.java:L3-L4"]' 'code_refs[1]' '/abs/src/b/B.java:L3-L4'
r11_invalid 일부-상위경로 '["../outside.txt:L1-L2","src/u01.txt:L3-L3"]' 'code_refs[0]' '../outside.txt:L1-L2'
r11_invalid 전부-비정규 '["src/*.txt:L1","src/"]' 'code_refs[0],code_refs[1]' 'src/*.txt:L1'
r11_invalid 설명-문구 '["src/u01.txt:L3-L3 (drop 경로)"]' 'code_refs[0]' '작업 트리에 없고'
r11_invalid 지어낸-경로 '["src/u01.txt:L3-L3","./src/ghost/Invented.java:L1-L2"]' 'code_refs[1]' './src/ghost/Invented.java:L1-L2'
r11_invalid 디렉터리 '["src"]' 'code_refs[0]' '디렉터리'
: > "$MOCK_LOG"; rc="$(run_loop)"; [ "$rc" -eq 4 ] && [ "$(codex_calls)" -eq 0 ] || fail "R11: 거부된 출력의 재실행이 리뷰어를 다시 부름 (rc $rc)"
# 정규화: 줄 범위(여러 구간)와 선행 "./" 만 뗀다 — 검사기와 gap 기록이 같은 정의(code_ref_path)를 쓴다. FIX_CODE 의 code_refs 는 이 검사 대상이 아니다
r11_errors() { ( set -- "$1"; source "$CFG"; SCHEMA_FILE="$PROJECT_ROOT/.claude/skills/feature/schemas/impl-review.schema.json"
  eval "$(sed -n '/^validate_review_output() {/,/^}/p' "$REVIEW_LOOP")"; validate_review_output "$1" 1 "" "" "" | jq -c '[.[].rule_id]' ); }
review_of "$(docgap '["./src/u01.txt:L3-L3,L8-L8","src/u01.txt"]')" > "$TMP/r11-ok.json"
[ "$(r11_errors "$TMP/r11-ok.json")" = '[]' ] || fail "R11: 정규화 가능한 code_refs(선행 ./·여러 줄 범위·줄 범위 없음)가 거부됨: $(r11_errors "$TMP/r11-ok.json")"
[ "$( ( source "$CFG"; jq -c "$JQ_PATH_DEFS"'[.issues[].code_refs[] | code_ref_path | select(plain_file_path)] | unique' "$TMP/r11-ok.json" ) )" = '["src/u01.txt"]' ] || fail "R11: gap 기록의 paths 정규화가 검사기와 다름"
review_of "$(issue '.code_refs=["/abs/x.java:L1","src/u01.txt:L3-L3"]')" > "$TMP/r11-fix.json"
[ "$(r11_errors "$TMP/r11-fix.json")" = '[]' ] || fail "R11: FIX_CODE issue 의 code_refs 까지 경로 검사 대상이 됨: $(r11_errors "$TMP/r11-fix.json")"
pass "R11: DOC_GAP code_refs 는 일부만 비정규·지어낸 경로여도 REVIEW_OUTPUT_INVALID(gap 체크포인트 없음, 재실행 리뷰어 0회), 선행 ./·줄 범위만 정규화"

# ===== R10: 계약 문서가 바뀌면 코드가 같아도 과거 APPROVE 를 재사용하지 않는다 =====
reset_case
review_of > "$MOCK_STATE/review-1.json"
rc="$(run_loop)"; [ "$rc" -eq 0 ] && jq -e '.next_step=="APPROVE" and ([.contract_docs_sha256 | keys[]] | sort) == ["approach.md","conventions.md","decisions.md#USER-QUESTION","design.md","implementation.md","request.md"]' .agent-work/review-impl.json >/dev/null \
  || { tail -20 "$TMP/loop.log"; fail "R10: 전제(승인 체크포인트에 계약 문서 지문 기록) 실패 (rc $rc): $(cat .agent-work/review-impl.json)"; }
( source "$CFG"; impl_approval_current ) || fail "R10: 전제 — 승인 직후 승인이 유효하지 않음"
# 판정 이력(사용자 결정이 아닌 줄)이 decisions.md 에 쌓여도 승인은 유지된다
echo '- [round 1] B-01 REJECT 사유 기록' >> .agent-work/decisions.md
: > "$MOCK_LOG"; rc="$(run_loop)"
[ "$rc" -eq 0 ] && [ "$(codex_calls)" -eq 0 ] && ( source "$CFG"; impl_approval_current ) || fail "R10: 판정 이력 줄 추가만으로 승인이 무효가 됨 (rc $rc, 리뷰어 $(codex_calls)회)"
# 계약 문서 본문 변경(코드는 그대로) → 러너 판정·루프 모두 과거 APPROVE 를 쓰지 않는다
tree_r10="$( ( source "$CFG"; snapshot_worktree_tree ) )"
printf '\n## 결정 Y (REQUIRED)\n승인 뒤에 바뀐 계약\n' >> .agent-work/approach.md
[ "$( ( source "$CFG"; snapshot_worktree_tree ) )" = "$tree_r10" ] && [ "$( ( source "$CFG"; compute_approval_fingerprint ) )" = "$(cat .agent-work/approved.fingerprint)" ] || fail "R10: 전제 — 문서 변경이 작업 트리 지문을 바꿈"
( source "$CFG"; impl_approval_current ) && fail "R10: 계약 문서가 바뀌었는데 러너의 승인 판정이 과거 APPROVE 를 유효로 봄"
review_of > "$MOCK_STATE/review-2.json"
: > "$MOCK_LOG"; rc="$(run_loop)"
[ "$rc" -eq 0 ] && [ "$(codex_calls)" -eq 1 ] && grep -q '다른 계약에 대한 승인' "$TMP/loop.log" && [ -f .agent-work/reviews/impl-attempt-02/reviewer-round-01.json ] \
  || { tail -20 "$TMP/loop.log"; fail "R10: 계약 변경 뒤 과거 APPROVE 가 재사용됨 (rc $rc, 리뷰어 $(codex_calls)회)"; }
( source "$CFG"; impl_approval_current ) || fail "R10: 새 계약으로 다시 리뷰한 승인이 유효하지 않음"
# 사용자 결정 추가도 계약 변경이다
echo '- [USER-QUESTION][scope=impl] 조회 방식 → Map 사전 인덱스' >> .agent-work/decisions.md
( source "$CFG"; impl_approval_current ) && fail "R10: 사용자 결정이 추가됐는데 과거 APPROVE 가 유효로 판정됨"
# 계약 문서 지문이 없는 옛 체크포인트는 같다고 증명할 수 없다
: > .agent-work/decisions.md; printf '# approach\n' > .agent-work/approach.md
reset_case; review_of > "$MOCK_STATE/review-1.json"; rc="$(run_loop)"; [ "$rc" -eq 0 ] || fail "R10: 전제 실패 (rc $rc)"
jq 'del(.contract_docs_sha256)' .agent-work/review-impl.json > "$TMP/ck.tmp" && cp "$TMP/ck.tmp" .agent-work/review-impl.json
( source "$CFG"; impl_approval_current ) && fail "R10: 계약 문서 지문 없는 옛 승인 체크포인트가 유효로 판정됨"
pass "R10: 승인 캐시는 계약 문서(본문 + 사용자 결정) 지문에 묶인다 — 코드가 같아도 계약이 바뀌면 새 attempt 로 리뷰, 판정 이력만 늘면 유지"

# ===== R10b: conventions.md 만 바뀌어도(생성·변경·삭제) 과거 APPROVE 를 재사용하지 않는다 =====
conv_case() { # 단계-이름 — 직전 승인이 무효로 판정되고, 루프가 새 attempt 로 리뷰어 1회를 불러 다시 승인하는지 확인
  ( source "$CFG"; compute_approval_fingerprint ) > "$TMP/fp.now"
  [ "$(cat "$TMP/fp.now")" = "$(cat .agent-work/approved.fingerprint)" ] || fail "R10b($1): 전제 — conventions 변경이 범위 작업 트리 지문을 바꿈(사례가 '코드는 그대로'를 검증하지 못함)"
  ( source "$CFG"; impl_approval_current ) && fail "R10b($1): conventions.md 가 달라졌는데 러너의 승인 판정이 과거 APPROVE 를 유효로 봄"
  n_before="$(cat "$MOCK_STATE/codex.n")"; review_of > "$MOCK_STATE/review-$((n_before + 1)).json"
  : > "$MOCK_LOG"; rc="$(run_loop)"
  [ "$rc" -eq 0 ] && [ "$(codex_calls)" -eq 1 ] && grep -q '다른 계약에 대한 승인' "$TMP/loop.log" || { tail -20 "$TMP/loop.log"; fail "R10b($1): conventions 변경 뒤 과거 APPROVE 가 재사용됨 (rc $rc, 리뷰어 $(codex_calls)회)"; }
  ( source "$CFG"; impl_approval_current ) || fail "R10b($1): 새 컨벤션으로 다시 리뷰한 승인이 유효하지 않음"
  : > "$MOCK_LOG"; rc="$(run_loop)"
  [ "$rc" -eq 0 ] && [ "$(codex_calls)" -eq 0 ] || fail "R10b($1): conventions 가 그대로인데 승인이 재사용되지 않음 (rc $rc, 리뷰어 $(codex_calls)회)"
}
reset_case
[ ! -e conventions.md ] || fail "R10b: 전제 — 픽스처 저장소에 conventions.md 가 이미 있음"
review_of > "$MOCK_STATE/review-1.json"
rc="$(run_loop)"; [ "$rc" -eq 0 ] && [ "$(jq -r '.contract_docs_sha256["conventions.md"]' .agent-work/review-impl.json)" = ABSENT ] || { tail -20 "$TMP/loop.log"; fail "R10b: 전제(컨벤션 없는 승인 — 지문에 ABSENT 기록) 실패 (rc $rc)"; }
printf '# conventions\n1. 표현 변환은 서비스 계층에서 한다\n' > conventions.md;                       conv_case 생성
[ "$(jq -r '.contract_docs_sha256["conventions.md"] | length' .agent-work/review-impl.json)" -eq 64 ] || fail "R10b: 컨벤션 내용 해시가 승인 체크포인트에 없음"
printf '# conventions\n1. 표현 변환은 응답 DTO 에서 한다\n' > conventions.md;                        conv_case 변경
mv conventions.md "$TMP/side/conventions.removed.md";                                                conv_case 삭제
[ "$(jq -r '.contract_docs_sha256["conventions.md"]' .agent-work/review-impl.json)" = ABSENT ] || fail "R10b: 컨벤션 삭제 뒤 승인 지문이 ABSENT 가 아님"
# 무효 출력의 로컬 재검증용 지문(파일 전체 decisions + conventions_sha256)과 승인용 지문은 분리돼 있다
[ "$( ( source "$CFG"; review_contract_docs_json ) | jq -c 'keys')" = '["approach.md","decisions.md","design.md","implementation.md","request.md"]' ] || fail "R10b: 무효 출력용 계약 문서 지문의 키가 승인용과 섞임"
# 옛 포맷의 승인 체크포인트(지문 의미가 다름)는 해석하지 않고 새 attempt 로 리뷰한다
CKV="$(grep -E '^REVIEW_CHECKPOINT_VERSION=' "$CFG" | cut -d= -f2 | cut -d' ' -f1)"
jq --argjson v "$((CKV - 1))" '.version=$v' .agent-work/review-impl.json > "$TMP/ck.tmp" && cp "$TMP/ck.tmp" .agent-work/review-impl.json
( source "$CFG"; impl_approval_current ) && fail "R10b: 옛 포맷의 승인 체크포인트가 유효로 판정됨"
n_before="$(cat "$MOCK_STATE/codex.n")"; review_of > "$MOCK_STATE/review-$((n_before + 1)).json"
: > "$MOCK_LOG"; rc="$(run_loop)"
[ "$rc" -eq 0 ] && [ "$(codex_calls)" -eq 1 ] && grep -q '포맷 버전 불일치' "$TMP/loop.log" || { tail -20 "$TMP/loop.log"; fail "R10b: 옛 포맷 체크포인트의 승인이 재사용됨 (rc $rc, 리뷰어 $(codex_calls)회)"; }
pass "R10b: conventions.md 의 생성·변경·삭제는 각각 기존 승인을 무효로 만들고 새 리뷰 1회를 부른다(그대로면 재사용), 옛 포맷 체크포인트는 재리뷰"

echo "[SMOKE OK] 리뷰 출력 계약 스모크 전체 통과"
rm -rf "$TMP"
