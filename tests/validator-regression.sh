#!/usr/bin/env bash
# =============================================================
# 검증자 판정 감도 회귀 — 고정 픽스처로 실제 검증자(codex, config.sh 의 VALIDATOR_MODEL/EFFORT)를 돌린다.
# 사용법:
#   bash tests/validator-regression.sh                 # 전 사례
#   bash tests/validator-regression.sh case-02-...     # 사례 하나만
#   bash tests/validator-regression.sh compare <validator-round-json> <expected.json>   # 결과 파일만 대조
# 비용: 사례당 실제 검증자 호출 1회. 08b 선택 시 대조군 08a도 먼저 실행하므로 2회.
# 대조 기준: verdict 일치 + blocking_issues 개수 일치 + expected.issues 각각을 만족하는 이슈 존재.
#   expected 이슈 필드는 정확 일치(action, origin …) 또는 `<field>_any_of` 배열로 허용 집합을 준다.
# case-08b: 한 consensus-loop 프로세스 안에서 Round 1(가짜 codex 가 prev-review.json 을 그대로 출력)
#   → 가짜 디자이너(revised-input/ 문서 적용 + decisions 기록) → Round 2(실제 검증자) 로 진행한다.
# =============================================================
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES_DIR="$SOURCE_ROOT/tests/validator-cases"
SRC_CONFIG="$SOURCE_ROOT/.claude/skills/feature/config.sh"

compare() { # result.json expected.json [full|gate] → 0 일치 / 1 불일치
  jq -e --slurpfile exp "$2" --arg mode "${3:-full}" '
    def matches($want):
      . as $issue
      | [ $want | to_entries[]
          | select($mode != "gate" or .key == "action" or .key == "action_any_of")
          | if (.key | endswith("_any_of")) then ($issue[(.key | sub("_any_of$"; ""))] as $v | (.value | index([$v])) != null)
            else ($issue[.key] == .value) end
        ] | all;
    # ponytail: 이슈가 적은 fixture의 완전 매칭. 이슈 수가 커지면 이분 매칭으로 교체.
    def matches_all($wants):
      if ($wants | length) == 0 then length == 0
      else . as $remaining | any(range(length);
        . as $i | ($remaining[$i] | matches($wants[0])) and
        ($remaining | del(.[$i]) | matches_all($wants[1:])))
      end;
    $exp[0] as $e
    | (.verdict == $e.verdict) as $v_ok
    | ((.blocking_issues | length) == ($e.issues | length)) as $n_ok
    | (.blocking_issues | matches_all($e.issues)) as $m_ok
    | if ($v_ok and $n_ok and $m_ok) then true
      else error("verdict=\(.verdict)(기대 \($e.verdict)) issues=\(.blocking_issues|length)(기대 \($e.issues|length)) 매칭=\($m_ok) 실제: \([.blocking_issues[] | {id,action,category,evidence_type,origin}])")
      end' "$1" >/dev/null
}
diff_msg() { printf '%s' "${1#*error (at*): }"; }

if [ "${1:-}" = compare ]; then
  if out="$(compare "$2" "$3" "${4:-full}" 2>&1)"; then echo "[OK] 일치"; else echo "[DIFF] $(diff_msg "$out")"; exit 1; fi
  exit 0
fi

# 사례 이름 인자는 승인 파일을 소모하기 전에 검사한다 (오타·셸 주석 잔재 '#' 로 승인이 낭비되지 않게)
if [ -n "${1:-}" ] && [ ! -f "$CASES_DIR/$1/expected.json" ]; then
  echo "[FAIL] 일치하는 회귀 사례가 없음: $1 (승인 파일은 소모하지 않음). 사용 가능: $(ls "$CASES_DIR" | tr '\n' ' ')" >&2; exit 1
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
if grep -Eq '^[[:space:]]*(VALIDATOR_MODEL|VALIDATOR_EFFORT|CODEX_BIN)=.*CHANGE_ME' "$SRC_CONFIG"; then
  echo "[FAIL] config.sh 의 검증자 설정(VALIDATOR_MODEL 등) CHANGE_ME 를 먼저 채우세요." >&2; exit 1
fi
# 설정된 codex 실행기를 일반 사례와 case-08 Round 2 가 동일하게 쓴다 (PATH 의 'codex' 를 가정하지 않는다)
# config.sh 를 source 하지 않는다 — TEST_CMD 등이 CHANGE_ME 면 가드가 exit 1 하고 set -e 가 조용히 스크립트를 죽인다. 대입문만 읽는다.
CONFIGURED_CODEX_BIN="$(sed -n 's/^CODEX_BIN="\{0,1\}\([^"#]*\)"\{0,1\}[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$SRC_CONFIG" | tail -1 | sed 's/[[:space:]]*$//')"
[ -n "$CONFIGURED_CODEX_BIN" ] || { echo "[FAIL] config.sh 의 CODEX_BIN 대입문을 읽지 못함" >&2; exit 1; }
for bin in "$CONFIGURED_CODEX_BIN" jq uuidgen envsubst git; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[FAIL] '$bin' 미설치" >&2; exit 1; }
done

# 같은 VALIDATOR_REGRESSION_DIR 를 반복 지정해도 이전 실행의 reviews·.codex-calls 가 섞이지 않게 실행마다 하위 디렉터리를 만든다
if [ -n "${VALIDATOR_REGRESSION_DIR:-}" ]; then
  mkdir -p "$VALIDATOR_REGRESSION_DIR"; SCRATCH="$(mktemp -d "$VALIDATOR_REGRESSION_DIR/run.XXXXXX")"
else
  SCRATCH="$(mktemp -d)"
fi
echo "작업 디렉터리: $SCRATCH (결과 JSON·로그 보존)"
pass=0; fail=0; gate_pass=0; invalid=0; skipped=0; selected=0; failed_cases=()
mark_fail() { echo "  [FAIL] $1"; fail=$((fail + 1)); failed_cases+=("$name"); }
requested_dependency=""
if [ -n "${1:-}" ] && [ -f "$CASES_DIR/$1/expected.json" ]; then
  requested_dependency="$(jq -r '.requires_case // empty' "$CASES_DIR/$1/expected.json")"
fi

# case-08b 용 가짜 실행기: Round 1 검증자 호출만 고정 리뷰로 대체하고, 디자이너는 revised-input/ 를 적용한다
write_fakes() { # target case_dir codex_bin
  local target="$1" case_dir="$2" real_codex; real_codex="$(command -v "$3")"
  cat > "$target/fake-codex" <<EOF
#!/usr/bin/env bash
# 첫 호출(Round 1): 고정 prev-review.json 을 -o 경로에 그대로 출력. 이후 호출: 실제 codex.
set -euo pipefail
count_file="$target/.codex-calls"; n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 )); printf '%s' "\$n" > "\$count_file"
if [ "\$n" -eq 1 ]; then
  out=""; while [ "\$#" -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2;; *) shift;; esac; done
  cp "$case_dir/prev-review.json" "\$out"; exit 0
fi
exec "$real_codex" "\$@"
EOF
  cat > "$target/fake-claude" <<EOF
#!/usr/bin/env bash
# 디자이너 대체: 검증자 Round 1 이슈를 ACCEPT 한 것으로 기록하고 revised-input/ 문서를 적용한다
set -euo pipefail
cp "$case_dir/revised-input/"*.md "$target/.agent-work/"
cat "$case_dir/decisions-round1.md" >> "$target/.agent-work/decisions.md"
printf '{"session_id":"fake","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
EOF
  chmod +x "$target/fake-codex" "$target/fake-claude"
}

for case_dir in "$CASES_DIR"/case-*/; do
  case_dir="${case_dir%/}"; name="$(basename "$case_dir")"
  [ -z "${1:-}" ] || [ "$1" = "$name" ] || [ "$requested_dependency" = "$name" ] || continue
  selected=$((selected + 1))
  prerequisite="$(jq -r '.requires_case // empty' "$case_dir/expected.json")"
  if [ -n "$prerequisite" ] && [ ! -f "$SCRATCH/$prerequisite/passed" ]; then
    skipped=$((skipped + 1)); mark_fail "선행 대조군 $prerequisite 미통과 — $name 호출 생략"; continue
  fi
  stage="$(jq -r '.stage' "$case_dir/expected.json")"
  round="$(jq -r '.round // 1' "$case_dir/expected.json")"
  expected_verdict="$(jq -r '.verdict' "$case_dir/expected.json")"
  target="$SCRATCH/$name"; mkdir -p "$target"; git -C "$target" init -q
  bash "$SOURCE_ROOT/install.sh" "$target" >/dev/null
  cfg="$target/.claude/skills/feature/config.sh"
  cp "$SRC_CONFIG" "$cfg"   # 실제 모델 설정 그대로
  sed -i.bak 's/^TEST_CMD=.*/TEST_CMD="true"/; s/^LINT_CMD=.*/LINT_CMD="true"/' "$cfg"
  mkdir -p "$target/.agent-work"
  cp "$case_dir/input/"*.md "$target/.agent-work/"
  if [ "$round" = 2 ]; then
    write_fakes "$target" "$case_dir" "$CONFIGURED_CODEX_BIN"
    sed -i.bak "s/^MAX_SPEC_ROUNDS=.*/MAX_SPEC_ROUNDS=1/; s|^CODEX_BIN=.*|CODEX_BIN=\"$target/fake-codex\"|; s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$target/fake-claude\"|" "$cfg"
  else
    sed -i.bak 's/^MAX_SPEC_ROUNDS=.*/MAX_SPEC_ROUNDS=0/' "$cfg"   # 검증자 Round 1 만
  fi
  rm -f "$cfg.bak"
  [ -d "$case_dir/src" ] && cp -R "$case_dir/src" "$target/src"
  touch "$target/.agent-work/decisions.md"
  (cd "$target" && git add -A && git -c user.email=t@t -c user.name=t commit -qm fixture)

  echo "=== $name ($stage, round $round) ==="
  set +e
  (cd "$target" && bash .claude/skills/feature/scripts/consensus-loop.sh "$stage") > "$target/run.log" 2>&1
  rc=$?
  set -e
  result="$target/.agent-work/reviews/validator-$stage-round-$(printf '%02d' "$round").json"
  # 기대값과 다른 유효 판정은 gate 실패다. 출력 거부/실행 오류와 구분한다.
  actual_verdict="$(jq -r '.verdict' "$result" 2>/dev/null || true)"
  case "$actual_verdict:$rc" in
    PASS:0|BLOCK:2) ;;
    *) invalid=$((invalid + 1)); mark_fail "실행·출력 오류: verdict=$actual_verdict, exit=$rc — $target/run.log"; tail -10 "$target/run.log" | sed 's/^/    /'; continue;;
  esac
  if compare "$result" "$case_dir/expected.json" gate >/dev/null 2>&1; then
    gate_pass=$((gate_pass + 1)); echo "  [GATE OK]"
  else
    echo "  [GATE FAIL] 기대 verdict=$expected_verdict, 실제 verdict=$actual_verdict (action·개수 포함)"
  fi
  if out="$(compare "$result" "$case_dir/expected.json" 2>&1)"; then
    echo "  [OK]"; pass=$((pass + 1)); touch "$target/passed"
  else
    mark_fail "$(diff_msg "$out")"
    [ "$round" = 2 ] && echo "    Round 2 인과 확인용 diff: $target/.agent-work/reviews/docs-diff-$stage-round-02.diff"
  fi
  # 자연어 본문은 자동 대조하지 않는다 — 처방 금지(불변식만 서술)는 사람이 본다. 정규식 게이트로 만들지 않는다.
  if [ -f "$case_dir/manual-check.txt" ]; then
    echo "  [MANUAL] $(cat "$case_dir/manual-check.txt")"
    jq -r '.blocking_issues[] | select(.action == "REVISE_DOC") | "    minimum_contract_needed: \(.minimum_contract_needed)"' "$result"
  fi
done
if [ "$selected" -eq 0 ]; then
  echo "[FAIL] 일치하는 회귀 사례가 없음: ${1:-$CASES_DIR/case-*}" >&2; exit 1
fi
echo; echo "Gate: $gate_pass/$selected / Classification: $pass/$selected / 실행·출력 오류: $invalid / 선행 실패로 생략: $skipped"
echo "통과 $pass / 실패 $fail"
[ "$fail" -eq 0 ] || { printf '  - %s\n' "${failed_cases[@]}"; exit 1; }
