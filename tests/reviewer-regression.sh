#!/usr/bin/env bash
# =============================================================
# 리뷰어 판정 감도 회귀 — 고정 픽스처로 실제 리뷰어(claude, config.sh 의 REVIEWER_MODEL/EFFORT)를 돌린다.
# 사용법:
#   bash tests/reviewer-regression.sh                 # 전 사례
#   bash tests/reviewer-regression.sh case-03-...     # 사례 하나만
#   bash tests/reviewer-regression.sh compare <reviewer-round-json> <expected.json>   # 결과 파일만 대조
# 비용: 사례당 실제 리뷰어 호출 1회(Round 2 사례도 1회 — Round 1 리뷰와 수정자는 고정 픽스처로 대체).
# 대조 기준: verdict 일치 + issues 개수 일치 + expected.issues 각각을 만족하는 이슈 존재.
#   expected 이슈 필드는 정확 일치(action, category …) 또는 `<field>_any_of` 배열로 허용 집합을 준다.
# 픽스처: base/(HEAD 커밋) → changed/(워커 결과 작업 트리). Round 2 사례는 changed/ 가 Round 1 시점이고
#   가짜 claude 가 Round 1 리뷰(prev-review.json)와 수정자(fixed/ 적용 + decisions-round1.md)를 대신한 뒤
#   Round 2 만 실제 리뷰어가 돈다.
# =============================================================
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES_DIR="$SOURCE_ROOT/tests/reviewer-cases"
SRC_CONFIG="$SOURCE_ROOT/.claude/skills/feature/config.sh"

compare() { # result.json expected.json → 0 일치 / 1 불일치 (차이는 stdout)
  jq -e --slurpfile exp "$2" '
    def matches($want):
      . as $issue
      | [ $want | to_entries[]
          | if (.key | endswith("_any_of")) then ($issue[(.key | sub("_any_of$"; ""))] as $v | (.value | index([$v])) != null)
            else ($issue[.key] == .value) end
        ] | all;
    $exp[0] as $e
    | (.verdict == $e.verdict) as $v_ok
    | ((.issues | length) == ($e.issues | length)) as $n_ok
    | ([ $e.issues[] as $want | any(.issues[]; matches($want)) ] | all) as $m_ok
    | if ($v_ok and $n_ok and $m_ok) then true
      else error("verdict=\(.verdict)(기대 \($e.verdict)) issues=\(.issues|length)(기대 \($e.issues|length)) 매칭=\($m_ok) 실제: \([.issues[] | {id,action,category,evidence_type,origin,code_refs}])")
      end' "$1" >/dev/null
}
diff_msg() { printf '%s' "${1#*error (at*): }"; }

if [ "${1:-}" = compare ]; then
  if out="$(compare "$2" "$3" 2>&1)"; then echo "[OK] 일치"; else echo "[DIFF] $(diff_msg "$out")"; exit 1; fi
  exit 0
fi

# ---------- 유료 실행 승인 게이트 ----------
# 이 스크립트는 실제 LLM CLI 를 부르고 비용이 든다. 사용자가 명시적으로 승인한 실행만 허용한다:
# 사용자 지시 후 `touch .claude/ALLOW_REAL_LLM_REGRESSION` (1회용 — 실행 시 소모). 오케스트레이터가 지시 없이 만들면 안 된다.
APPROVAL_FILE="$SOURCE_ROOT/.claude/ALLOW_REAL_LLM_REGRESSION"
if [ ! -f "$APPROVAL_FILE" ]; then
  echo "[BLOCK] 이 회귀는 실제 claude/codex 호출과 비용이 발생합니다. 사용자 승인 후 1회용 허용 파일을 만든 뒤 다시 실행: touch $APPROVAL_FILE" >&2
  exit 3
fi
mkdir -p "$SOURCE_ROOT/.agent-work"
mv "$APPROVAL_FILE" "$SOURCE_ROOT/.agent-work/ALLOW_REAL_LLM_REGRESSION.used.$(date +%s)"   # 한 번 쓴 승인은 재사용하지 않는다

# 대입문만 검사 — config.sh 의 가드 코드 자체에 CHANGE_ME 문자열이 있으므로 전체 grep 은 항상 걸린다
if grep -Eq '^[[:space:]]*(REVIEWER_MODEL|REVIEWER_EFFORT|CLAUDE_BIN)=.*CHANGE_ME' "$SRC_CONFIG"; then
  echo "[FAIL] config.sh 의 리뷰어 설정(REVIEWER_MODEL 등) CHANGE_ME 를 먼저 채우세요." >&2; exit 1
fi
# config.sh 를 source 하지 않는다 — TEST_CMD 등이 CHANGE_ME 면 가드가 exit 1 하고 set -e 가 조용히 스크립트를 죽인다. 대입문만 읽는다.
CONFIGURED_CLAUDE_BIN="$(sed -n 's/^CLAUDE_BIN="\{0,1\}\([^"#]*\)"\{0,1\}[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$SRC_CONFIG" | tail -1 | sed 's/[[:space:]]*$//')"
[ -n "$CONFIGURED_CLAUDE_BIN" ] || { echo "[FAIL] config.sh 의 CLAUDE_BIN 대입문을 읽지 못함" >&2; exit 1; }
for bin in "$CONFIGURED_CLAUDE_BIN" jq uuidgen envsubst git; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[FAIL] '$bin' 미설치" >&2; exit 1; }
done
REAL_CLAUDE="$(command -v "$CONFIGURED_CLAUDE_BIN")"

# 같은 REVIEWER_REGRESSION_DIR 를 반복 지정해도 이전 실행 산출물이 섞이지 않게 실행마다 하위 디렉터리를 만든다
if [ -n "${REVIEWER_REGRESSION_DIR:-}" ]; then
  mkdir -p "$REVIEWER_REGRESSION_DIR"; SCRATCH="$(mktemp -d "$REVIEWER_REGRESSION_DIR/run.XXXXXX")"
else
  SCRATCH="$(mktemp -d)"
fi
echo "작업 디렉터리: $SCRATCH (결과 JSON·로그 보존)"
pass=0; fail=0; selected=0; failed_cases=()
mark_fail() { echo "  [FAIL] $1"; fail=$((fail + 1)); failed_cases+=("$name"); }

# 실제 claude 래퍼: Claude Code 세션 안에서 돌릴 때 중첩 실행 차단 변수를 지운다(밖에서는 무해).
# 호출 카운터와 픽스처는 저장소 밖(target 의 형제 디렉터리)에 둔다 — 저장소 안에 두면 리뷰 중 작업 트리 지문이 바뀐다.
write_fakes() { # target case_dir round
  local target="$1" case_dir="$2" round="$3" side="$1.side"
  mkdir -p "$side"
  cat > "$side/real-claude" <<EOF
#!/usr/bin/env bash
exec env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION "$REAL_CLAUDE" "\$@"
EOF
  cat > "$side/fake-claude" <<EOF
#!/usr/bin/env bash
# 1번째 호출(리뷰어 Round 1): 고정 prev-review.json 을 structured_output 으로 출력.
# 2번째 호출(수정자): fixed/ 를 적용하고 decisions 를 기록. 이후: 실제 리뷰어.
set -euo pipefail
count_file="$side/.claude-calls"; n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 )); printf '%s' "\$n" > "\$count_file"
if [ "\$n" -eq 1 ]; then
  jq -n -c --slurpfile r "$case_dir/prev-review.json" '{structured_output: \$r[0], session_id:"fake", total_cost_usd:0, usage:{input_tokens:0,output_tokens:0,cache_read_input_tokens:0,cache_creation_input_tokens:0}}'
  exit 0
fi
if [ "\$n" -eq 2 ]; then
  cp -R "$case_dir/fixed/." "$target/"
  cat "$case_dir/decisions-round1.md" >> "$target/.agent-work/decisions.md"
  printf '{"session_id":"fake","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\\n'
  exit 0
fi
# 가짜가 받은 --session-id 는 실제 세션을 만들지 않았으므로, 실제 리뷰어의 --resume <id> 를 --session-id <id> 로 바꿔 새로 연다
args=(); while [ "\$#" -gt 0 ]; do case "\$1" in --resume) args+=(--session-id "\$2"); shift 2;; *) args+=("\$1"); shift;; esac; done
exec "$side/real-claude" "\${args[@]}"
EOF
  chmod +x "$side/real-claude" "$side/fake-claude"
  if [ "$round" = 2 ]; then printf '%s' "$side/fake-claude"; else printf '%s' "$side/real-claude"; fi
}

for case_dir in "$CASES_DIR"/case-*/; do
  case_dir="${case_dir%/}"; name="$(basename "$case_dir")"
  [ -z "${1:-}" ] || [ "$1" = "$name" ] || continue
  selected=$((selected + 1))
  round="$(jq -r '.round // 1' "$case_dir/expected.json")"
  expected_verdict="$(jq -r '.verdict' "$case_dir/expected.json")"
  target="$SCRATCH/$name"; mkdir -p "$target"; git -C "$target" init -q
  bash "$SOURCE_ROOT/install.sh" "$target" >/dev/null
  cfg="$target/.claude/skills/feature/config.sh"
  cp "$SRC_CONFIG" "$cfg"   # 실제 모델 설정 그대로
  claude_bin="$(write_fakes "$target" "$case_dir" "$round")"
  if [ "$round" = 2 ]; then max_rounds=1; else max_rounds=0; fi   # Round 1 사례는 리뷰 1회, 수정자 없음
  sed -i.bak "s/^TEST_CMD=.*/TEST_CMD=\"true\"/; s/^LINT_CMD=.*/LINT_CMD=\"true\"/; s/^MAX_IMPL_ROUNDS=.*/MAX_IMPL_ROUNDS=$max_rounds/; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$claude_bin\"|" "$cfg"
  rm -f "$cfg.bak"
  cp -R "$case_dir/base/." "$target/"
  (cd "$target" && git add -A && git -c user.email=t@t -c user.name=t commit -qm fixture)
  mkdir -p "$target/.agent-work"
  cp "$case_dir/.agent-work/"* "$target/.agent-work/"
  git -C "$target" rev-parse 'HEAD^{tree}' > "$target/.agent-work/worker-baseline.tree"   # 워커 진입 기준선 = base/ 커밋
  : > "$target/.agent-work/decisions.md"
  cp -R "$case_dir/changed/." "$target/"

  echo "=== $name (round $round) ==="
  set +e
  (cd "$target" && FEATURE_LIVE_TEE=1 bash .claude/skills/feature/scripts/impl-review-loop.sh) > "$target.run.log" 2>&1
  rc=$?
  set -e
  # APPROVE 는 exit 0, REQUEST_CHANGES 는 라운드 소진/ASK_USER(exit 2) 또는 DOC_GAP(exit 3). 그 외는 러너/리뷰어 오류다.
  case "$expected_verdict:$rc" in
    APPROVE:0|REQUEST_CHANGES:2|REQUEST_CHANGES:3) ;;
    *) mark_fail "비정상 종료: 기대 verdict=$expected_verdict, exit=$rc — $target.run.log"; tail -10 "$target.run.log" | sed 's/^/    /'; continue;;
  esac
  result="$target/.agent-work/reviews/impl-attempt-01/reviewer-round-$(printf '%02d' "$round").json"
  [ -f "$result" ] || { mark_fail "리뷰어 결과 없음: $result"; continue; }
  if out="$(compare "$result" "$case_dir/expected.json" 2>&1)"; then
    echo "  [OK]"; pass=$((pass + 1))
  else
    mark_fail "$(diff_msg "$out")"
    [ "$round" = 2 ] && echo "    Round 2 인과 확인용 수정 diff: $target/.agent-work/reviews/impl-attempt-01/fix-diff-round-02.patch"
  fi
  # 자연어 본문은 자동 대조하지 않는다 — required_outcome 이 처방(기법)이 아니라 결과인지는 사람이 본다.
  jq -r '.issues[]? | "    [\(.id)] required_outcome: \(.required_outcome)"' "$result"
done
if [ "$selected" -eq 0 ]; then
  echo "[FAIL] 일치하는 회귀 사례가 없음: ${1:-$CASES_DIR/case-*}" >&2; exit 1
fi
echo; echo "통과 $pass / 실패 $fail"
[ "$fail" -eq 0 ] || { printf '  - %s\n' "${failed_cases[@]}"; exit 1; }
