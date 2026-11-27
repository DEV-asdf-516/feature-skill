#!/usr/bin/env bash
# =============================================================
# .claude/skills/feature/scripts/lib/contract/scope.sh
# feature-scope manifest·기준선 가드·CLI 종료 코드≠의미적 완료·워커 결과/경로/범위 가드.
# scripts/lib/bootstrap.sh 가 정해진 순서로 source 한다 — 직접 실행하지 않는다.
# (분리 전 config.sh 기준 928–1153)
# =============================================================

# ---------- 피처 범위 manifest (feature-scope.json) ----------
# 오케스트레이터가 implementation.md 와 함께 쓴다: {"version":1,"files":[...],"new_file_roots":[...]}.
#   files          : 이번 피처가 변경·생성하는 정확한 경로(저장소 루트 기준)
#   new_file_roots : 정확한 파일명을 미리 정할 수 없는 생성 경로의 디렉터리 접두(마이그레이션 등). 최소한으로.
# 용도 — 같은 working tree 를 다른 세션과 공유할 때 "이번 피처의 변경"을 시점이 아니라 범위로 정의한다.
#   worker-baseline.tree 는 시점 기준선이지 변경 소유권의 증거가 아니다.
#   (1) 워커·수정자 호출 전후 write-set 이 범위를 벗어나면 자동 원복 없이 보존하고 중단
#   (2) 리뷰 diff 를 범위 경로로 한정 — 다른 세션의 변경이 "이번 작업"으로 리뷰어에게 가지 않는다
#   (3) 승인 지문을 범위 파일로 계산 — 다른 세션이 범위 밖 파일을 바꿔도 승인이 무효화되지 않는다
FEATURE_SCOPE_FILE="$WORK_DIR/feature-scope.json"          # 오케스트레이터가 쓰는 원본
FEATURE_SCOPE_LOCK="$WORK_DIR/feature-scope.lock.json"     # 워커 진입 전에 확정한 불변 사본 — 검사·diff·지문은 전부 이것을 쓴다
FEATURE_SCOPE_VERSION=1
# manifest 는 '검사 기준'이면서 워커·수정자가 쓸 수 있는 .agent-work 안에 있다(작업 트리 스냅샷은 WORK_DIR 를 제외하므로
# manifest 변경은 write-set diff 에 보이지 않는다). 그래서 원본을 직접 쓰지 않고 lock 사본을 기준으로 삼고, 호출 전후
# 원본·lock 해시를 대조해 달라졌으면 SCOPE_MANIFEST_CHANGED 로 자동 복구 없이 중단한다.
feature_scope_present() { [ -f "$FEATURE_SCOPE_FILE" ]; }
# SCOPE_MANIFEST_OVERRIDE: 같은 files/new_file_roots 의미의 다른 manifest(구현 단위의 scope.json)로 아래 검사·pathspec 함수를 한 번 더 돌릴 때
# 호출 한 번에만 지정한다(`SCOPE_MANIFEST_OVERRIDE=<path> feature_scope_violations …`). 두 번째 범위 엔진을 만들지 않기 위한 매개변수다.
feature_scope_file() {
  if [ -n "${SCOPE_MANIFEST_OVERRIDE:-}" ]; then printf '%s' "$SCOPE_MANIFEST_OVERRIDE"; return 0; fi
  if [ -f "$FEATURE_SCOPE_LOCK" ]; then printf '%s' "$FEATURE_SCOPE_LOCK"; else printf '%s' "$FEATURE_SCOPE_FILE"; fi
}
# 원본 + lock 의 내용 해시 (없는 쪽은 MISSING). 워커·수정자 호출 전후로 비교한다.
feature_scope_hash() {
  {
    for f in "$FEATURE_SCOPE_FILE" "$FEATURE_SCOPE_LOCK"; do
      printf '%s\0' "$f"; if [ -f "$f" ]; then cat "$f"; else printf 'MISSING'; fi; printf '\0'
    done
  } | sha256_stdin
}
# lock 확정: 없으면 원본을 복사. 있는데 원본과 다르면 2 (사용자가 범위를 바꿨거나 누군가 원본을 건드림 — 호출자가 중단).
# 반환: 0 확정/일치, 1 생성 실패, 2 원본≠lock. 호출부는 set -e 아래에서 `if lock_feature_scope; then :; else rc=$?; ...` 형태로 받는다
# (`f; rc=$?` 는 errexit 가 f 의 실패에서 바로 종료해 rc 줄에 도달하지 못한다).
lock_feature_scope() {
  if [ ! -f "$FEATURE_SCOPE_LOCK" ]; then
    cp "$FEATURE_SCOPE_FILE" "$FEATURE_SCOPE_LOCK" || return 1
    return 0
  fi
  cmp -s "$FEATURE_SCOPE_FILE" "$FEATURE_SCOPE_LOCK" && return 0
  return 2
}
# 경로는 canonical 이어야 한다 — git 이 돌려주는 변경 경로(선행 ./ 없음, 후행 / 없음)와 문자열로 비교하기 때문.
#   files          : 저장소 상대, 선행 "./" 금지, 후행 "/" 금지, 빈·"."·".." 세그먼트 금지. 이 경로는 생성·수정·삭제 전부 허용.
#   new_file_roots : 같은 규칙이되 후행 "/" 는 하나 허용(비교 전에 제거). 이 아래는 **기준선 tree 에 없던 파일의 생성·후속 수정(A/M)만** 허용 —
#                    기존 파일의 수정·삭제·타입 변경은 범위 위반이다(정확한 파일명을 미리 알 수 없는 '생성' 경로라는 정의 그대로).
#   files 와 new_file_roots 중 하나 이상에 항목이 있어야 한다 (마이그레이션만 만드는 피처는 roots 만으로 표현)
feature_scope_valid_file() { # manifest-path
  [ -f "$1" ] && jq -e --argjson v "$FEATURE_SCOPE_VERSION" "$JQ_PATH_DEFS"'
    def canonical: canonical_path;
    .version==$v and (.files|type=="array") and ((.new_file_roots // [])|type=="array")
    and ((.files|length) + ((.new_file_roots // [])|length)) > 0
    and all(.files[]; canonical)
    and all((.new_file_roots // [])[]; type=="string" and (sub("/$"; "") | canonical))' \
    "$1" >/dev/null 2>&1
}
feature_scope_valid() { feature_scope_valid_file "$(feature_scope_file)"; }
feature_scope_pathspecs() { # git pathspec 목록 (files + roots), 한 줄 하나
  jq -r '.files[], ((.new_file_roots // [])[] | sub("/+$"; "") + "/")' "$(feature_scope_file)"
}
path_in_exact_feature_files() { # path → 0 이면 files 에 정확히 있음
  jq -e --arg p "$1" '(.files|index($p))!=null' "$(feature_scope_file)" >/dev/null 2>&1
}
path_in_new_file_roots() { # path → 0 이면 어떤 root 아래
  jq -e --arg p "$1" 'any((.new_file_roots // [])[]; . as $r | ($p|startswith(($r|sub("/+$"; "")) + "/")))' "$(feature_scope_file)" >/dev/null 2>&1
}
path_in_feature_scope() { path_in_exact_feature_files "$1" || path_in_new_file_roots "$1"; }
# 두 tree 사이 변경 중 범위 밖인 것을 출력 (없으면 빈 출력, 반환 0). 호출자가 비어 있지 않으면 중단한다.
#   files 경로: A/M/D/T 전부 허용. 그 밖(범위 밖): 전부 위반.
#   roots 아래: 소유 분류는 이번 호출의 A/M 이 아니라 **워커 진입 기준선 tree 에 있었는가**로 정한다.
#     기준선에 있던 파일 → M/D/T 전부 위반 (이 피처 것이 아니다)
#     기준선에 없던 파일(이 피처가 만든 것) → A/M 허용, D/T 위반 (파일 삭제 금지 계약을 결과 기준으로도 지킨다)
#     그래야 첫 워커 호출이 만든 파일을 다음 라운드의 수정자·worker-fix 가 다시 고칠 수 있다(호출 직전 tree 대비 M 이지만 피처가 만든 파일).
#   기준선 tree 는 **호출자가 호출 전에 읽어 인자로 넘긴다** — 이 함수는 worker-baseline.tree 파일을 다시 읽지 않는다.
#   그 파일은 에이전트가 쓸 수 있는 .agent-work 안에 있어서, 호출 후에 읽으면 워커가 빈 tree 로 바꿔 기존 파일 보호를 무력화할 수 있다.
#   호출자는 호출 전후 파일 내용이 같은지도 검사한다(SCOPE_BASELINE_CHANGED). 기준선 인자가 비어 있으면(구버전 산출물·단독 실행)
#   호출 전후 status A 만 허용하는 보수적 규칙으로 돌아간다.
path_owned_by_baseline() { # baseline-tree path → 0 이면 워커 진입 전부터 존재
  [ -n "$1" ] || return 1
  git ls-tree "$1" -- ":(literal)$2" 2>/dev/null | grep -q .
}
# worker-baseline.tree 를 읽어 검증된 tree 해시를 출력. 파일이 없으면 빈 출력(반환 0), 있는데 유효한 tree 가 아니면 반환 1.
read_worker_baseline_tree() {
  local t
  [ -f "$WORK_DIR/worker-baseline.tree" ] || return 0
  t="$(cat "$WORK_DIR/worker-baseline.tree")"
  git cat-file -e "$t^{tree}" 2>/dev/null || { echo "[FAIL] worker-baseline.tree 가 유효한 tree 를 가리키지 않음: $t" >&2; return 1; }
  printf '%s' "$t"
}
# 기준선 변조 가드: SCOPE_BASELINE_CHANGED 로 중단한 뒤 사용자가 worker-baseline.tree 를 원래 값으로 되돌리기 전에는
# 다음 실행이 변조된 값을 새 기준선으로 읽어 들이면 안 된다(그러면 첫 실행이 잡은 우회가 재실행에서 성립한다).
# 자동 원복은 하지 않고, 중단 당시의 기대값을 이 파일에 남겨 복구 전 재실행을 모델 호출 0회로 다시 막는다.
BASELINE_GUARD="$WORK_DIR/worker-baseline.guard.json"
record_baseline_guard() { # expected observed actor
  jq -n --arg expected "$1" --arg observed "$2" --arg actor "$3" \
    '{active:true, expected:$expected, observed:$observed, actor:$actor}' > "$BASELINE_GUARD.tmp" && mv "$BASELINE_GUARD.tmp" "$BASELINE_GUARD"
}
# 활성 가드가 있으면 현재 worker-baseline.tree 가 기대값과 같아야 통과(가드를 비활성화). 다르면 1 — 호출자가 모델 호출 없이 중단.
require_baseline_guard_resolved() {
  local expected current=""
  [ -f "$BASELINE_GUARD" ] || return 0
  jq -e '.active == true' "$BASELINE_GUARD" >/dev/null 2>&1 || return 0
  expected="$(jq -r '.expected' "$BASELINE_GUARD")"
  [ -f "$WORK_DIR/worker-baseline.tree" ] && current="$(cat "$WORK_DIR/worker-baseline.tree")"
  if [ "$current" != "$expected" ]; then
    echo "[STOP] worker-baseline.tree 가 아직 변조 전 값으로 복구되지 않음 — 기대: ${expected:-없음} / 현재: ${current:-없음}. 자동 복구하지 않음." >&2
    return 1
  fi
  jq '.active = false' "$BASELINE_GUARD" > "$BASELINE_GUARD.tmp" && mv "$BASELINE_GUARD.tmp" "$BASELINE_GUARD"
}
# =============================================================
# CLI 종료 코드 ≠ 의미적 완료
#   편집 역할이 작업 트리·문서를 이미 바꾼 뒤 비정상 종료코드를 돌려줄 수 있다(codex 가 task_complete 뒤 프로세스 exit 1 을 내는 간헐 사례).
#   raw exit code 는 usage.jsonl 에 관측값 그대로 남기고(위조 없음), 호출자가 raw rc + 이번 invocation 의 기계 판독 결과 +
#   호출 전후 변경 + 기존 index/manifest/baseline/write-set 게이트 + 다음 독립 검증 게이트(검증자·리뷰어·targeted test)로 재실행 여부를 정한다.
#   불변식: 편집 역할이 한번 변경을 만들고 종료했으면, 성공 여부가 불명확하다는 이유만으로 같은 편집 호출을 자동 반복하지 않는다.
#   복구된 경우는 숨기지 않는다 — [WARN] CLI_EXIT_STATUS_MISMATCH 로그 + append-only cli-anomalies.jsonl.
# =============================================================
CLI_ANOMALY_LOG="$WORK_DIR/cli-anomalies.jsonl"
record_cli_anomaly() { # role cli label raw_exit_code recovery(STRUCTURED_RESULT|FORWARD_TO_VALIDATOR|FORWARD_TO_REVIEWER) evidence
  jq -nc --arg role "$1" --arg cli "$2" --arg label "$3" --argjson rc "$4" --arg recovery "$5" --arg evidence "$6" --arg now "$(date '+%FT%T%z')" \
    '{timestamp:$now, kind:"CLI_EXIT_STATUS_MISMATCH", role:$role, cli:$cli, label:$label, raw_exit_code:$rc, recovery:$recovery, evidence:$evidence}' \
    >> "$CLI_ANOMALY_LOG"
}
cli_anomaly_count() { if [ -f "$CLI_ANOMALY_LOG" ]; then grep -c . "$CLI_ANOMALY_LOG" || true; else echo 0; fi; }
# 워커 결과 JSON 이 러너가 실제로 쓰는 계약을 만족하는가 — 파일 존재만으로 성공 취급하지 않는다.
#   JSON parse / status ∈ {DONE,UNDECIDED} / undecided·delegated_choices·tests 배열 / context_updates.upsert·remove 배열(unit 의 rolling context 가 읽는다) /
#   undecided 항목의 kind·location·decision_needed / DONE+undecided>0 · UNDECIDED+undecided==0 모순.
#   undecided 항목의 paths: 비어 있지 않은 배열, 항목마다 저장소 상대 파일 경로(plain_file_path — 절대경로·".."·선행 "./"·빈 값·glob·디렉터리 표기 거부), 중복 없음.
#     location 은 사람에게 보여 주는 자유 문자열이고 unit 연결 판정에는 paths 만 쓴다. 파일 실재·신규 파일 허용 범위는 worker_undecided_path_violations 가 따로 본다
#     (이 함수는 저장된 결과의 재검증에도 쓰이므로 작업 트리 상태에 의존하지 않는다).
worker_result_valid() { # result.json
  [ -s "$1" ] || return 1
  jq -e "$JQ_PATH_DEFS"'
    type=="object"
    and (.status=="DONE" or .status=="UNDECIDED")
    and (.undecided|type)=="array" and (.delegated_choices|type)=="array" and (.tests|type)=="array"
    and (.context_updates|type)=="object" and (.context_updates.upsert|type)=="array" and (.context_updates.remove|type)=="array"
    and all(.undecided[]; (.kind=="DOC_GAP" or .kind=="USER_DECISION") and (.location|type)=="string" and (.decision_needed|type)=="string"
          and (.paths|type)=="array" and (.paths|length)>0 and all(.paths[]; plain_file_path) and ((.paths|unique|length) == (.paths|length)))
    and ((.status=="DONE" and (.undecided|length)==0) or (.status=="UNDECIDED" and (.undecided|length)>0))
  ' "$1" >/dev/null 2>&1
}
# 이번 호출이 낸 undecided[].paths 가 실제 파일을 가리키는가 — "<undecided 번호>:<path>:<사유>" 줄로 위반을 낸다(빈 출력 = 통과). 현행 worktree/scope 규칙과 같다:
#   · 작업 트리에 있는 파일이면 통과(범위 밖의 기존 파일도 미결정의 위치일 수 있다 — unit 연결은 scope 대조가 따로 정한다)
#   · 없는 경로는 이 피처가 만들 수 있는 곳(feature-scope 의 files 에 정확히 있거나 new_file_roots 아래)일 때만 통과
#   · 디렉터리이거나, 없으면서 범위 밖이면 위반 — 모델이 지어낸 경로로 gap 을 unit 에 연결하지 않는다
# 리뷰 DOC_GAP 의 code_refs 도 같은 규칙으로 본다(repo_file_path_violation — impl-review-loop.sh validate_review_output).
repo_file_path_violation() { # path → 위반이면 사유를 출력하고 1, 아니면 0
  if [ -d "$PROJECT_ROOT/$1" ]; then printf '디렉터리'; return 1
  elif [ -e "$PROJECT_ROOT/$1" ] || [ -L "$PROJECT_ROOT/$1" ]; then return 0
  elif path_in_feature_scope "$1"; then return 0
  else printf '작업 트리에 없고 feature-scope(files/new_file_roots) 밖'; return 1; fi
}
worker_undecided_path_violations() { # result.json
  local i p why
  while IFS=$'\t' read -r i p; do
    [ -n "$p" ] || continue
    why="$(repo_file_path_violation "$p")" || printf '%s:%s:%s\n' "$i" "$p" "$why"
  done < <(jq -r '.undecided | to_entries[] | (.key + 1) as $n | .value.paths[] | [($n|tostring), .] | @tsv' "$1")
}
# 디자이너 범위 가드: 디자이너(편집 역할)가 합의 단계에서 문서 밖 source 작업 트리를 바꾸면 rc 와 무관하게 DESIGNER_SCOPE_VIOLATION 으로 중단한다.
# 검증자는 설계 문서를 검증하는 역할이지 디자이너가 바꾼 구현 코드를 승인하는 역할이 아니므로 VALIDATOR_PENDING 으로 넘기지 않는다.
# 호출 전 tree(expected)를 남겨, 사용자가 작업 트리를 되돌리기 전에는 재실행이 모델 호출 0회로 같은 사유로 다시 멈춘다(자동 원복·자동 재호출 없음).
DESIGNER_SCOPE_GUARD="$WORK_DIR/designer-scope.guard.json"
record_designer_scope_guard() { # expected(before-tree) observed(after-tree) target round raw_exit_code
  jq -n --arg expected "$1" --arg observed "$2" --arg target "$3" --argjson round "$4" --argjson rc "$5" --arg now "$(date '+%FT%T%z')" \
    '{active:true, expected:$expected, observed:$observed, target:$target, round:$round, raw_exit_code:$rc, recorded_at:$now}' \
    > "$DESIGNER_SCOPE_GUARD.tmp" && mv "$DESIGNER_SCOPE_GUARD.tmp" "$DESIGNER_SCOPE_GUARD"
}
require_designer_scope_guard_resolved() {
  local expected current
  [ -f "$DESIGNER_SCOPE_GUARD" ] || return 0
  jq -e '.active == true' "$DESIGNER_SCOPE_GUARD" >/dev/null 2>&1 || return 0
  expected="$(jq -r '.expected' "$DESIGNER_SCOPE_GUARD")"
  current="$(snapshot_worktree_tree)" || return 1
  if [ "$current" != "$expected" ]; then
    echo "[STOP] 직전 디자이너 호출($(jq -r '.target' "$DESIGNER_SCOPE_GUARD") round $(jq -r '.round' "$DESIGNER_SCOPE_GUARD"))이 문서 밖 source 파일을 바꿨고 작업 트리가 호출 전 tree 로 복구되지 않음 — 기대: $expected / 현재: $current. 자동 복구하지 않음." >&2
    return 1
  fi
  jq '.active = false' "$DESIGNER_SCOPE_GUARD" > "$DESIGNER_SCOPE_GUARD.tmp" && mv "$DESIGNER_SCOPE_GUARD.tmp" "$DESIGNER_SCOPE_GUARD"
}
# 워커 결과 불확실 가드: 워커가 작업 트리를 바꿨는데 결과 JSON 이 없거나 깨졌고 rc ≠ 0 이면 WORKER_OUTCOME_UNCERTAIN 으로 중단한다.
# 호출 전 tree(expected)를 남겨, 사용자가 작업 트리를 그 tree 로 명시적으로 되돌리기 전에는 재실행이 모델 호출 0회로 같은 사유로 다시 멈춘다.
# 자동 restore/reset/checkout/stash 없음. worker-baseline.guard.json 과 같은 fail-closed 패턴이며 워커 전용의 최소 구현이다.
WORKER_OUTCOME_GUARD="$WORK_DIR/worker-outcome.guard.json"
record_worker_outcome_guard() { # expected(before-tree) observed(after-tree) role label raw_exit_code result_path [invocation_id] [raw_log] [reason]
  # [Modified: GOAL-6] invocation_id·raw 로그 경로·오류 이유를 함께 남긴다(CLI rc 가 0 이어도 결과 검증 실패 + 트리 변경이면 같은 가드를 쓴다)
  jq -n --arg expected "$1" --arg observed "$2" --arg role "$3" --arg label "$4" --argjson rc "$5" --arg result "$6" \
    --arg inv "${7:-}" --arg raw "${8:-}" --arg reason "${9:-}" --arg now "$(date '+%FT%T%z')" \
    '{active:true, expected:$expected, observed:$observed, role:$role, label:$label, raw_exit_code:$rc, result:$result,
      invocation_id:(if $inv=="" then null else $inv end), raw_log:(if $raw=="" then null else $raw end), reason:(if $reason=="" then null else $reason end), recorded_at:$now}' \
    > "$WORKER_OUTCOME_GUARD.tmp" && mv "$WORKER_OUTCOME_GUARD.tmp" "$WORKER_OUTCOME_GUARD"
}
# 활성 가드가 있으면 현재 작업 트리가 expected(호출 전 tree)와 같아야 통과(가드 비활성화). 다르면 1 — 호출자가 모델 호출 없이 중단.
require_worker_outcome_guard_resolved() {
  local expected current
  [ -f "$WORKER_OUTCOME_GUARD" ] || return 0
  jq -e '.active == true' "$WORKER_OUTCOME_GUARD" >/dev/null 2>&1 || return 0
  expected="$(jq -r '.expected' "$WORKER_OUTCOME_GUARD")"
  current="$(snapshot_worktree_tree)" || return 1
  if [ "$current" != "$expected" ]; then
    echo "[STOP] 직전 워커 호출($(jq -r '.label' "$WORKER_OUTCOME_GUARD"), exit $(jq -r '.raw_exit_code' "$WORKER_OUTCOME_GUARD"))의 완료 여부가 불확실한데 작업 트리가 호출 전 tree 로 복구되지 않음 — 기대: $expected / 현재: $current. 자동 복구하지 않음." >&2
    return 1
  fi
  jq '.active = false' "$WORKER_OUTCOME_GUARD" > "$WORKER_OUTCOME_GUARD.tmp" && mv "$WORKER_OUTCOME_GUARD.tmp" "$WORKER_OUTCOME_GUARD"
}
feature_scope_violations() { # before-tree after-tree [ownership-baseline-tree]
  # --no-renames: rename 을 삭제+추가로 분해한다. 아니면 범위 밖 파일을 범위 안 경로로 옮겼을 때 목적지만 보여
  # 출발지(범위 밖 파일의 삭제)가 검사를 통과한다. 리뷰용 diff 는 rename 형태를 유지해도 되지만 위반 검사는 고정.
  local before="$1" after="$2" baseline="${3:-}" status changed
  git diff --no-renames --name-status -z "$before" "$after" -- | while IFS= read -r -d '' status && IFS= read -r -d '' changed; do
    [ -z "$changed" ] && continue
    path_in_exact_feature_files "$changed" && continue
    if path_in_new_file_roots "$changed"; then
      if [ -n "$baseline" ]; then
        if ! path_owned_by_baseline "$baseline" "$changed"; then
          case "$status" in A|M) continue;; esac
        fi
      elif [ "$status" = A ]; then
        continue
      fi
    fi
    printf '%s\n' "$changed"
  done
}
