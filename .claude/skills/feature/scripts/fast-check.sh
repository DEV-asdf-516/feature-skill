#!/usr/bin/env bash
# =============================================================
# 프로젝트 빠른 검사 연결 (선택 기능) — LLM 구현 리뷰 전에 적용 프로젝트가 제공한 결정론적 검사를 돌린다
# 파일 경로: .claude/skills/feature/scripts/fast-check.sh   (source 전용 — impl-review-loop.sh 가 config.sh 뒤에 읽는다)
#
# 이 파일은 명령 연결·결과 구분·증거 보존만 한다. 어떤 도구로 무엇을 검사할지는 프로젝트가 정한다 — 언어·프레임워크·규칙 파일 형식을 여기 넣지 않는다.
# 헬퍼를 config.sh 가 아니라 scripts/ 에 둔 이유: config.sh 는 사용자 편집 파일이라 설치가 덮어쓰지 않는다. 여기 있으면 옛 config.sh 를 그대로 둔 설치도
# 병합 없이 이 기능을 받고(FAST_CHECK_CMD 가 없으니 미설정 = 생략), 런타임 계약 표식(FEATURE_RUNTIME_CONTRACT_VERSION)을 올릴 필요가 없다.
#
# 설정 (config.sh 사용자 설정 영역, 둘 다 선택):
#   FAST_CHECK_CMD          검사 명령. 비어 있거나 없으면 미설정 — 검사를 실행하지 않고 "생략"으로만 로그에 남긴다(실행·통과로 집계하지 않는다).
#   FAST_CHECK_TIMEOUT_SEC  제한 시간(초, 양의 정수). 기본 120.
#
# 명령 계약:
#   실행 위치  피처 worktree 루트(git rev-parse --show-toplevel), `bash -c "$FAST_CHECK_CMD"`, stdin 은 /dev/null.
#   환경 변수  FAST_CHECK_ROOT          worktree 루트 절대 경로
#              FAST_CHECK_CHANGED_FILES 이번 피처가 바꾼 파일 목록 파일의 절대 경로(한 줄에 저장소 상대 경로 하나, 삭제된 파일 제외,
#                                       feature-scope 범위 안, 기준 = 워커 진입 기준선). 쓰지 않아도 된다 — 변경 파일만 검사하고 싶은 도구용.
#                                       경로는 인용·이스케이프 없는 실제 문자열이다(한글·공백·따옴표 포함 그대로).
#   프로세스   명령은 자기 프로세스 그룹에서 돈다. 제한 시간을 넘기면 그룹 전체에 TERM → KILL 을 보내고 정리가 끝난 뒤에 사후 비교를 한다.
#   종료 코드  0      정상 완료(위반 없음)
#              1      규칙 위반 — stdout/stderr 에 수정에 필요한 진단(규칙·파일·위치·내용)을 낸다. 출력이 비어 있으면 실행 오류로 본다.
#              그 외  실행 오류(도구 누락 126/127, 내부 오류, 시그널 등). 제한 시간 초과도 실행 오류다.
#   기존 도구의 종료 코드가 이와 다르면(예: 위반을 2 로 알림) 프로젝트 쪽 얇은 어댑터 스크립트가 0/1/그 외로 옮긴다.
#   읽기 전용  작업 트리(gitignore 적용, $WORK_DIR 제외)와 git index 를 바꾸지 않는다. 자동 수정·포매팅·파일 삭제·git add 금지.
#              실행 전후 tree 스냅샷과 index 지문을 비교해 달라졌으면 종료 코드와 무관하게 실행 오류다(변경은 원복하지 않고 그대로 둔다).
#
# 산출물 ($WORK_DIR/fast-check/ — 실행마다 새 번호, 덮어쓰지 않는다):
#   check-NNNN.log                명령의 stdout+stderr 원본
#   check-NNNN.changed-files.txt  FAST_CHECK_CHANGED_FILES 로 넘긴 목록 (같은 목록의 NUL 구분 원본은 check-NNNN.changed-files.txt.z)
#   check-NNNN.timeout            제한 시간 초과로 종료시켰을 때만 생긴다
#   last.json / history.jsonl     실행 기록 {version, seq, label, status, kind, cmd, cmd_sha256, cwd, timeout_sec, exit_code, timed_out,
#                                 duration_sec, log, changed_files, tree_before, tree_after, index_before, index_after, index_modified, modified_paths[],
#                                 out_of_scope_paths[], started_at, finished_at}
#   이 기록은 증거일 뿐 성공 캐시가 아니다 — 어떤 게이트도 과거 PASS 기록으로 검사를 건너뛰지 않는다(경계마다 다시 실행한다).
#   readonly-restored.json        직전 읽기 전용 위반(seq)의 복구를 확인했다는 표식(아래 '읽기 전용 위반 뒤의 재실행')
#
# 읽기 전용 위반 뒤의 재실행 (세 검사 공통 — check_readonly_violation_pending):
#   마지막 기록이 index 를 바꾼 실행이면, 현재 index 지문이 그 실행 전 지문(index_before)으로 돌아오기 전에는 명령을 다시 실행하지 않고 같은 오류로 멈춘다.
#   (실행 전후만 비교하면, 바뀐 index 를 그대로 둔 재실행은 '이번 실행은 아무것도 안 바꿨다'로 통과한다.)
#   Unit 정적 검사는 작업 트리 변경도 같은 방식으로 막는다: 그 실행이 바꾼 경로들이 실행 전 내용으로 돌아와야 한다 — 다른 파일이 더 바뀌어 tree 가 달라진 것은 복구가 아니다.
#   자동 원복은 없다. 복구를 확인하면 표식(readonly-restored.json)을 남겨, 그 뒤의 정상적인 코드 변경을 같은 위반으로 다시 세지 않는다.
#
# 같은 실행 엔진(project_check_run)을 쓰는 다른 두 선택 검사 — 엔진(프로세스 그룹·타임아웃·읽기 전용 비교·결과 구분·기록)은 하나뿐이고 프로필만 다르다:
#   Unit 정적 검사   UNIT_CHECK_CMD / UNIT_CHECK_TIMEOUT_SEC(기본 120)   — unit_check_run. 러너(run_unit)가 unit 의 targeted test 앞에서 실행한다.
#                    환경 변수 UNIT_CHECK_ROOT · UNIT_CHECK_CHANGED_FILES(이 unit 이 바꾼 파일: units/<id>/before.tree → 현재, unit scope 안, 삭제 제외) · UNIT_CHECK_UNIT_ID.
#                    산출물 $WORK_DIR/units/<id>/unit-check/ (check-NNNN.log, last.json, history.jsonl — 기록에 unit_id 가 붙는다).
#   위험도별 검증    RISK_VERIFY_CMD / RISK_VERIFY_TIMEOUT_SEC(기본 600) — risk_verify_run. 러너가 리뷰 승인 뒤 TEST_CMD 앞(verify 진입마다)에서 실행한다.
#                    환경 변수 RISK_VERIFY_ROOT · RISK_VERIFY_CHANGED_FILES(전체 Fast Check 와 같은 목록) · RISK_VERIFY_RESULT(명령이 결과 JSON 을 쓸 파일 경로).
#                    결과 JSON: {"risk_level":"LOW|MEDIUM|HIGH|CRITICAL|UNKNOWN", "checks":[{"name":"<비어 있지 않은 문자열>","status":"PASS|FAIL|SKIPPED"}]?,
#                               "reasons":["<문자열>"]?, "needs_human":bool?} — risk_level 만 필수. checks·reasons 는 있으면 항목 형식까지 검사한다.
#                    exit 0 인데 결과 파일이 없거나 형식이 틀리면 실행 오류(RESULT_INVALID)다 — 위험도를 LOW 로 가정하지 않는다.
#                    exit 0 인데 checks 에 FAIL 이 있으면 실행 오류(RESULT_INCONSISTENT)다 — 종료 코드와 개별 검증 결과가 모순이면 통과도 코드 위반도 아니고
#                    검증 명령의 결과 계약 오류다(실패한 검증이 있으면 명령은 exit 1 + 진단을 내야 한다). risk_level=UNKNOWN 또는 needs_human=true 는
#                    통과가 아니라 사용자 판단(NEEDS_USER)이다. 산출물 $WORK_DIR/risk-verify/ (기록에 risk_level·needs_human·checks·result 가 붙는다).
#   종료 코드 계약(0 정상 / 1 위반 + 진단 / 그 외 오류)·읽기 전용·타임아웃·기록 형식은 세 검사가 같다. 미설정이면 셋 다 "생략" 로그만 남긴다.
# =============================================================

FAST_CHECK_DIR="$WORK_DIR/fast-check"
FAST_CHECK_RECORD="$FAST_CHECK_DIR/last.json"
FAST_CHECK_HISTORY="$FAST_CHECK_DIR/history.jsonl"
FAST_CHECK_RECORD_VERSION=1
FAST_CHECK_STATUS=""; FAST_CHECK_KIND=""; FAST_CHECK_LOG=""; FAST_CHECK_DETAIL=""; FAST_CHECK_EXIT_CODE=""

fast_check_cmd() { printf '%s' "${FAST_CHECK_CMD:-}"; }
_check_cmd_set() { [ -n "${1//[[:space:]]/}" ]; }   # 공백뿐인 값도 미설정이다
fast_check_configured() { _check_cmd_set "$(fast_check_cmd)"; }
unit_check_configured() { _check_cmd_set "${UNIT_CHECK_CMD:-}"; }
risk_verify_configured() { _check_cmd_set "${RISK_VERIFY_CMD:-}"; }

# ---------- 공용 실행 엔진의 프로필 (호출 한 번에만 유효 — 래퍼가 채운다) ----------
#   PC_NAME 로그 태그 · PC_VAR 설정/환경 변수 접두(<PC_VAR>_CMD, _TIMEOUT_SEC, _ROOT, _CHANGED_FILES) · PC_CMD 명령 · PC_TIMEOUT 제한 시간 · PC_DIR 산출물 디렉터리
#   PC_BASE 변경 파일 목록의 기준 tree(빈 값 = 워커 진입 기준선, 없으면 HEAD) · PC_SCOPE 목록을 좁힐 scope manifest(빈 값 = feature-scope)
#   PC_ENV 추가 환경 변수(NAME=value 배열) · PC_RESULT_ENV=1 이면 <PC_VAR>_RESULT(결과 JSON 경로)를 넘긴다 · PC_EXTRA 기록에 합칠 JSON 객체
#   PC_POST 기본 판정 뒤·기록 전에 부르는 함수 이름(선택) — CHECK_STATUS/CHECK_KIND/CHECK_DETAIL/PC_EXTRA 를 고칠 수 있다(인자: 결과 JSON 경로, 실행 후 tree 는 CHECK_TREE).
#   PC_RESTORE_GUARD 직전 읽기 전용 위반의 복구 확인 범위: index(기본 — index 지문만) | all(index + 그 실행이 바꾼 작업 트리 경로)
# 결과: CHECK_STATUS(PASS|SKIPPED|VIOLATION|ERROR|NEEDS_USER) / CHECK_KIND / CHECK_LOG / CHECK_DETAIL / CHECK_EXIT_CODE / CHECK_RECORD
CHECK_STATUS=""; CHECK_KIND=""; CHECK_LOG=""; CHECK_DETAIL=""; CHECK_EXIT_CODE=""; CHECK_RECORD=""; CHECK_TREE=""
CHECK_RO_KIND=""; CHECK_RO_DETAIL=""

# check_readonly_violation_pending <check-dir> <index|all> — 그 검사의 마지막 기록이 읽기 전용 위반이고 아직 복구되지 않았는가(모델·검사 명령 호출 없음).
#   반환: 0 미복구(CHECK_RO_KIND · CHECK_RO_DETAIL 에 사유) · 1 위반 기록 없음 또는 복구 확인 · 2 판정 자체의 실패(지문·스냅샷·표식 기록 불가)
#   index: 현재 index 지문 == 기록의 index_before 여야 한다(index_before 가 없는 옛 기록은 판정할 근거가 없어 건너뛴다).
#   all  : 추가로, 그 실행이 바꾼 경로(tree_before → tree_after)가 전부 현재 tree 에서 tree_before 와 같은 내용이어야 한다.
#          '현재 tree 가 실행 직후 tree 와 다르다'는 복구가 아니다 — 다른 파일을 더 고쳐도 검사가 만든 변경은 그대로 남는다.
#   복구를 확인하면 표식(readonly-restored.json, 그 기록의 seq)을 남긴다. 표식이 있으면 다시 판정하지 않는다 — 복구 뒤 워커가 같은 파일을 정상적으로 고친 것을
#   같은 위반으로 되풀이해 막지 않기 위해서다. 원복은 하지 않는다.
check_readonly_violation_pending() {
  local dir="$1" mode="$2" rec="$1/last.json" mark="$1/readonly-restored.json" seq idx_before cur_idx before after cur p left checked=0
  local specs=()
  CHECK_RO_KIND=""; CHECK_RO_DETAIL=""
  [ -f "$rec" ] || return 1
  jq -e '.status=="ERROR" and (.index_modified==true or ((.modified_paths // []) | length) > 0)' "$rec" >/dev/null 2>&1 || return 1
  seq="$(jq -r '.seq' "$rec")"
  if [ -f "$mark" ] && jq -e --arg s "$seq" '(.seq|tostring)==$s' "$mark" >/dev/null 2>&1; then return 1; fi
  idx_before="$(jq -r 'if .index_modified==true then (.index_before // "") else "" end' "$rec")"
  if [ -n "$idx_before" ]; then
    checked=1
    cur_idx="$(compute_index_fingerprint)" || return 2
    if [ "$cur_idx" != "$idx_before" ]; then
      CHECK_RO_KIND=INDEX_MODIFIED
      CHECK_RO_DETAIL="직전 실행(#$seq)이 git index 를 바꿨고 index 가 그 실행 전 상태로 돌아오지 않았다(실행 전 지문 ${idx_before:0:12}…, 현재 ${cur_idx:0:12}…) — 명령을 다시 실행하지 않았다. 검사가 stage 한 내용을 직접 되돌린 뒤(자동 복구 없음) 재실행. 기록: $rec"
      return 0
    fi
  fi
  if [ "$mode" = all ] && jq -e '((.modified_paths // []) | length) > 0' "$rec" >/dev/null 2>&1; then
    checked=1
    before="$(jq -r '.tree_before' "$rec")"; after="$(jq -r '.tree_after' "$rec")"
    cur="$(snapshot_worktree_tree)" || return 2
    while IFS= read -r -d '' p; do specs+=(":(literal)$p"); done < <(git diff -z --no-renames --name-only "$before" "$after" -- 2>/dev/null)
    if [ "${#specs[@]}" -eq 0 ]; then
      CHECK_RO_KIND=WORKTREE_MODIFIED
      CHECK_RO_DETAIL="직전 실행(#$seq)이 작업 트리를 바꿨는데 그 실행 전후 tree($before → $after)를 읽을 수 없어 복구 여부를 확인할 수 없다 — 복구된 것으로 간주하지 않는다. 기록: $rec"
      return 0
    fi
    left="$(git -c core.quotePath=false diff --no-renames --name-only "$before" "$cur" -- "${specs[@]}" | paste -sd, -)"
    if [ -n "$left" ]; then
      CHECK_RO_KIND=WORKTREE_MODIFIED
      CHECK_RO_DETAIL="직전 실행(#$seq)이 작업 트리를 바꿨고 그 변경이 해소되지 않았다 — 실행 전 내용과 다른 경로: $left (실행 전 tree $before, 현재 $cur). 다른 파일이 더 바뀐 것은 복구가 아니다 — 명령을 다시 실행하지 않았다. 그 경로들을 실행 전 내용으로 직접 되돌린 뒤(자동 원복 없음) 재실행. 기록: $rec"
      return 0
    fi
  fi
  [ "$checked" = 1 ] || return 1
  jq -n --arg seq "$seq" --arg kind "$(jq -r '.kind' "$rec")" --arg now "$(date '+%FT%T%z')" '{seq:($seq|tonumber? // $seq), kind:$kind, restored_at:$now}' > "$mark.tmp" \
    && mv "$mark.tmp" "$mark" || return 2
  return 1
}

# fast_check_run <label> — 전체 Fast Check(리뷰 루프가 리뷰어 호출 직전마다 부른다). 프로필만 채우고 공용 엔진을 부른다.
#   반환: 0 PASS · 10 SKIPPED(미설정) · 20 VIOLATION(규칙 위반) · 30 ERROR(실행 오류) · 1 이 헬퍼 자체의 실패(스냅샷·기록 불가)
#   결과는 FAST_CHECK_STATUS / FAST_CHECK_KIND / FAST_CHECK_LOG / FAST_CHECK_EXIT_CODE / FAST_CHECK_DETAIL 에도 남긴다.
#   ERROR 의 kind: INVALID_CONFIG · TIMEOUT · COMMAND_NOT_RUNNABLE · NO_DIAGNOSTICS · UNEXPECTED_EXIT · WORKTREE_MODIFIED · INDEX_MODIFIED
#   (INDEX_MODIFIED 는 직전 실행이 바꾼 index 가 복구되지 않은 재실행에서도 난다 — 그때는 명령을 실행하지 않는다)
fast_check_run() {
  local rc=0
  PC_NAME=fast-check; PC_VAR=FAST_CHECK; PC_CMD="$(fast_check_cmd)"; PC_TIMEOUT="${FAST_CHECK_TIMEOUT_SEC:-120}"; PC_DIR="$FAST_CHECK_DIR"
  PC_BASE=""; PC_SCOPE=""; PC_ENV=(); PC_RESULT_ENV=0; PC_EXTRA='{}'; PC_POST=""; PC_RESTORE_GUARD=index
  project_check_run "$1" || rc=$?
  FAST_CHECK_STATUS="$CHECK_STATUS"; FAST_CHECK_KIND="$CHECK_KIND"; FAST_CHECK_LOG="$CHECK_LOG"; FAST_CHECK_DETAIL="$CHECK_DETAIL"; FAST_CHECK_EXIT_CODE="$CHECK_EXIT_CODE"
  return "$rc"
}

# unit_check_run <unit-id> <unit-dir> <label> — Unit 정적 검사. 반환 코드는 fast_check_run 과 같다(결과는 CHECK_*).
#   변경 파일 목록은 이 unit 의 시작 tree(before.tree) → 현재, unit scope 안으로 좁힌다 — 다른 unit 이 바꾼 파일을 unit 마다 되풀이해 넘기지 않는다.
#   (목록만으로 안전성을 판단할 수 없는 검사기는 목록을 무시하고 더 넓게 검사해도 된다 — 목록은 입력이지 강제 범위가 아니다.)
unit_check_run() {
  local id="$1" unit_dir="$2"
  PC_NAME=unit-check; PC_VAR=UNIT_CHECK; PC_CMD="${UNIT_CHECK_CMD:-}"; PC_TIMEOUT="${UNIT_CHECK_TIMEOUT_SEC:-120}"; PC_DIR="$unit_dir/unit-check"
  PC_BASE=""; PC_SCOPE=""; PC_ENV=("UNIT_CHECK_UNIT_ID=$id"); PC_RESULT_ENV=0; PC_POST=_unit_check_post; PC_RESTORE_GUARD=all
  PC_UNIT_ID="$id"
  if _check_cmd_set "${UNIT_CHECK_CMD:-}"; then   # 선언한 정책 경로가 틀렸으면 명령을 돌리기 전에 멈춘다(돌린 뒤에는 그 결과에 지문을 붙일 수 없다)
    local pol_tree
    pol_tree="$(snapshot_worktree_tree)" || { echo "[FAIL] [unit-check] 실행 전 tree 스냅샷 실패" >&2; return 1; }
    unit_check_policy_extra_paths "$pol_tree" >/dev/null || return 1
  fi
  PC_EXTRA="$(jq -nc --arg id "$id" '{unit_id:$id}')"
  if [ -f "$unit_dir/before.tree" ] && git cat-file -e "$(cat "$unit_dir/before.tree")^{tree}" 2>/dev/null; then PC_BASE="$(cat "$unit_dir/before.tree")"; fi
  [ ! -f "$unit_dir/scope.json" ] || PC_SCOPE="$unit_dir/scope.json"
  project_check_run "$3"
}
# ---------- 완료 unit 의 검사 증거: 명령 + 검사 대상 코드 + 정책 입력에 결속 ----------
# 과거 PASS 는 '그때의 코드를 그때의 규칙으로 검사했다'는 증거일 뿐이다. 그 PASS 를 지금도 쓸 수 있는지는 기록에 남긴 두 지문으로 판정한다(둘 다 tree 내용의 해시, 모델 호출 없음):
#   subject_fingerprint  이 unit 의 scope(files + new_file_roots) 안 경로들의 내용 — 검사 대상 코드. 뒤 unit·수정자·worker-fix·사용자가 이 범위를 고치면 달라진다.
#   policy_fingerprint   정책 입력의 내용. 명령 문자열이 같아도 이것이 바뀌면 다른 검사다. 세 부분의 합이다:
#                        ① 어떤 unit 의 scope 에도 속하지 않는 경로 전부(검사 스크립트·규칙·설정 파일이 보통 여기 있다)
#                        ② UNIT_CHECK_CMD 의 토큰 중 작업 트리의 파일인 것(검사 스크립트 자체 — 어느 unit 의 scope 안에 있어도 포함)
#                        ③ config.sh 의 UNIT_CHECK_POLICY_PATHS 로 선언한 경로(파일·디렉터리 — 어느 unit 의 scope 안에 있어도 포함)
#                        ②③ 이 없으면 다른 unit 이 소유한(그 unit 의 scope 안) 규칙 파일이 바뀌어도 ① 은 그대로다 — scope 제외 규칙이 그 파일을 지문에서 빼기 때문이다.
# 전체 tree 를 통째로 비교하지 않는다: 다른 unit 의 scope 에만 속한 경로의 변경(독립 unit 의 정상 작업)은 이 unit 의 증거를 무효화하지 않는다.
# 한계: 하네스는 검사기가 실제로 무엇을 읽는지 알 수 없다. 다음은 지문에 없다 — ⓐ 작업 트리 밖의 입력(gitignore 된 설정·전역 도구 버전)
#       ⓑ 어느 unit 의 scope 안에 있으면서 명령 문자열에도 UNIT_CHECK_POLICY_PATHS 에도 나오지 않는 규칙·설정 파일 ⓒ 검사기가 다른 unit 의 코드까지 읽는 교차 파일 규칙.
#       ⓑ 는 프로젝트가 UNIT_CHECK_POLICY_PATHS 에 선언해 닫는다(선언은 재검증을 늘릴 뿐 줄이지 않는다). ⓐⓒ 는 캐시 없는 전체 Fast Check·리뷰·verify 가 맡는다.
#       판정이 애매하면 재사용이 아니라 재검증이다(지문 없는·이전 형식의 기록 포함).
UNIT_CHECK_EVIDENCE_VERSION=2   # 2: policy_fingerprint 에 명령 토큰 파일·UNIT_CHECK_POLICY_PATHS 추가(1 의 기록은 재검증한다)
UNIT_CHECK_EVIDENCE_WHY=""
# unit_check_policy_extra_paths <tree> → 한 줄에 경로 하나: unit scope 와 무관하게 정책 입력으로 세는 경로(위 ②③). 공백으로 나눈다(glob 해석 없음).
#   ② 는 그 tree 의 파일(blob)인 토큰만 — 디렉터리 인자(검사 대상)는 정책이 아니다. ③ 은 선언이므로 tree 에 없으면 실패한다(오타·gitignore 된 경로를
#   조용히 빈 지문으로 받으면 선언이 아무것도 막지 못한다).
unit_check_policy_extra_paths() {
  local tree="$1" tok p
  ( set -f
    for tok in ${UNIT_CHECK_CMD:-}; do
      p="${tok#./}"
      case "$p" in ''|/*|-*) continue;; esac
      [ "$(git cat-file -t "$tree:$p" 2>/dev/null)" != blob ] || printf '%s\n' "$p"
    done
    for tok in ${UNIT_CHECK_POLICY_PATHS:-}; do
      p="${tok#./}"; while [ "${p%/}" != "$p" ]; do p="${p%/}"; done
      if [ -z "$p" ] || [ "${p#/}" != "$p" ] || ! git cat-file -e "$tree:$p" 2>/dev/null; then
        echo "[FAIL] [unit-check] UNIT_CHECK_POLICY_PATHS 의 경로 '$tok' 가 작업 트리 스냅샷에 없다(오타이거나 gitignore 된 경로, 또는 저장소 상대 경로가 아님) — 정책 입력으로 지문에 넣을 수 없다. config.sh 를 고친 뒤 재실행" >&2
        exit 1
      fi
      printf '%s\n' "$p"
    done ) | sort -u
  [ "${PIPESTATUS[0]}" -eq 0 ]
}
# ---------- 워커 호출 전 사전 검사: 선언한 정책 경로 ----------
# 위 실행 시점 규칙(검사를 돌리는 순간 선언한 경로가 tree 에 없으면 실패)은 그대로다. 다만 그 판정은 첫 unit 의 워커 턴이 끝난 뒤에야 나온다 —
# 오타 하나를 워커 호출이 끝난 뒤에 알게 된다. 러너는 unit 루프에 들어가기 전에 아래 두 헬퍼로 '다음 검사 시점에도 없을 것이 확정된 경로'만 미리 가린다(검사 명령·모델 호출 0회).
#   지금 tree 에 있다                                     → 통과
#   없지만 첫 unit 이 아직 실행 전이고 그 unit 의 scope 안  → 통과(그 unit 의 워커가 만들 수 있다 — 만들지 않으면 실행 시점 규칙이 종전대로 잡는다)
#   그 외(어느 unit 도 만들 수 없음 · 뒤 unit 만 만들 수 있음 · 첫 unit 이 이미 완료)  → 오류: 다음 검사가 반드시 실패한다
# unit_check_policy_missing_paths <tree> → 선언했지만 그 tree 에 없는 경로(정규화, 한 줄 하나). 형식이 틀린 선언(빈 값·절대 경로)은 적힌 그대로 낸다.
unit_check_policy_missing_paths() {
  local tree="$1" tok p
  ( set -f
    for tok in ${UNIT_CHECK_POLICY_PATHS:-}; do
      p="${tok#./}"; while [ "${p%/}" != "$p" ]; do p="${p%/}"; done
      if [ -z "$p" ] || [ "${p#/}" != "$p" ]; then printf '%s\n' "$tok"; continue; fi
      git cat-file -e "$tree:$p" 2>/dev/null || printf '%s\n' "$p"
    done ) | sort -u
}
# unit_scope_can_create <unit-id> <path> — 그 unit 의 scope 가 path(파일 또는 디렉터리)를 만들 수 있는가: files 의 항목이거나 그 상위 디렉터리, new_file_roots 의 안·자신·상위.
unit_scope_can_create() {
  jq -e --arg id "$1" --arg p "$2" '
    [.units[] | select(.id==$id) | .scope
     | ((.files // []) | any(. == $p or startswith($p + "/")))
       or ([(.new_file_roots // [])[] | sub("/+$"; "")] | any(. == $p or (. as $r | $p | startswith($r + "/")) or startswith($p + "/")))] | any' \
    "$(units_manifest_file)" >/dev/null 2>&1
}
unit_check_evidence_fingerprints() { # unit-id tree → "<subject> <policy>"
  local id="$1" tree="$2" manifest empty ps s p extra_list
  local subject=() policy=(.) extra=()
  manifest="$(units_manifest_file)"; [ -f "$manifest" ] || return 1
  empty="$(git hash-object -t tree /dev/null)" || return 1
  while IFS= read -r ps; do [ -z "$ps" ] || subject+=(":(literal)$ps"); done \
    < <(jq -r --arg id "$id" '.units[] | select(.id==$id) | .scope | .files[]?, ((.new_file_roots // [])[] | sub("/+$"; "") + "/")' "$manifest")
  while IFS= read -r ps; do [ -z "$ps" ] || policy+=(":(exclude,literal)$ps"); done \
    < <(jq -r '.units[].scope | .files[]?, ((.new_file_roots // [])[] | sub("/+$"; "") + "/")' "$manifest" | sort -u)
  [ "${#subject[@]}" -gt 0 ] || return 1
  extra_list="$(unit_check_policy_extra_paths "$tree")" || return 1
  while IFS= read -r ps; do [ -z "$ps" ] || extra+=(":(literal)$ps"); done <<< "$extra_list"
  # 빈 tree 대비 raw diff = 그 pathspec 범위의 (mode, blob, path) 목록. ls-tree 는 exclude pathspec 을 받지 않는다.
  s="$(git diff --raw -z --no-renames --no-abbrev "$empty" "$tree" -- "${subject[@]}" | sha256_stdin)" || return 1
  # 정책 = ① scope 밖 전부 + ②③ 추가 경로(scope 제외 pathspec 이 이기므로 따로 뽑아 이어 붙인다 — 겹쳐서 두 번 들어가도 결정적이다)
  p="$( { git diff --raw -z --no-renames --no-abbrev "$empty" "$tree" -- "${policy[@]}"
          [ "${#extra[@]}" -eq 0 ] || git diff --raw -z --no-renames --no-abbrev "$empty" "$tree" -- "${extra[@]}"; } | sha256_stdin)" || return 1
  printf '%s %s' "$s" "$p"
}
_unit_check_post() { # 기록에 지문을 붙인다(실행 후 tree 기준 — PASS 면 실행 전 tree 와 같다)
  local fps
  fps="$(unit_check_evidence_fingerprints "$PC_UNIT_ID" "$CHECK_TREE")" || return 1
  PC_EXTRA="$(jq -c --argjson v "$UNIT_CHECK_EVIDENCE_VERSION" --arg s "${fps%% *}" --arg p "${fps##* }" \
    '. + {evidence_version:$v, subject_fingerprint:$s, policy_fingerprint:$p}' <<< "$PC_EXTRA")"
}
# unit_check_evidence_current <unit-id> [tree] — 그 unit 의 마지막 검사 기록이 PASS 이고, 같은 명령·지금의 검사 대상 코드·지금의 정책 입력에 대한 것인가.
# 미설정이면 요구할 증거가 없다(SKIPPED — PASS 가 아니다). 아니면 1 을 돌려주고 사유를 UNIT_CHECK_EVIDENCE_WHY 에 남긴다 — 호출자는 워커를 부르지 않고 검사만 다시 돌린다.
unit_check_evidence_current() {
  UNIT_CHECK_EVIDENCE_WHY=""
  unit_check_configured || return 0
  local rec="$WORK_DIR/units/$1/unit-check/last.json" tree="${2:-}" fps
  [ -f "$rec" ] || { UNIT_CHECK_EVIDENCE_WHY="검사 기록 없음(완료 뒤 검사를 새로 설정)"; return 1; }
  jq -e '.status=="PASS"' "$rec" >/dev/null 2>&1 || { UNIT_CHECK_EVIDENCE_WHY="마지막 검사 기록이 PASS 가 아님($(jq -r '.status // "?"' "$rec" 2>/dev/null))"; return 1; }
  jq -e --arg sha "$(printf '%s' "${UNIT_CHECK_CMD:-}" | sha256_stdin)" '.cmd_sha256==$sha' "$rec" >/dev/null 2>&1 || { UNIT_CHECK_EVIDENCE_WHY="검사 명령이 바뀜"; return 1; }
  jq -e --argjson v "$UNIT_CHECK_EVIDENCE_VERSION" '.evidence_version==$v and (.subject_fingerprint|type)=="string" and (.policy_fingerprint|type)=="string"' "$rec" >/dev/null 2>&1 \
    || { UNIT_CHECK_EVIDENCE_WHY="기록에 검사 대상·정책 지문이 없음(이전 형식의 기록)"; return 1; }
  [ -n "$tree" ] || tree="$(snapshot_worktree_tree)" || { UNIT_CHECK_EVIDENCE_WHY="작업 트리 스냅샷 실패"; return 1; }
  fps="$(unit_check_evidence_fingerprints "$1" "$tree")" || { UNIT_CHECK_EVIDENCE_WHY="현재 지문 계산 실패"; return 1; }
  [ "$(jq -r '.subject_fingerprint' "$rec")" = "${fps%% *}" ] || { UNIT_CHECK_EVIDENCE_WHY="검사 뒤 이 unit 의 scope 안 코드가 바뀜"; return 1; }
  [ "$(jq -r '.policy_fingerprint' "$rec")" = "${fps##* }" ] || { UNIT_CHECK_EVIDENCE_WHY="검사 뒤 정책 입력(어느 unit 의 scope 에도 없는 파일·명령이 가리키는 검사 스크립트·UNIT_CHECK_POLICY_PATHS — 검사 스크립트·규칙·설정)이 바뀜"; return 1; }
}

# risk_verify_run <label> — 리뷰 승인 뒤 위험도별 추가 검증. 반환: 0 PASS · 10 SKIPPED · 20 VIOLATION · 30 ERROR · 40 NEEDS_USER(위험도 UNKNOWN / needs_human) · 1 헬퍼 실패
RISK_VERIFY_DIR="$WORK_DIR/risk-verify"
risk_verify_run() {
  PC_NAME=risk-verify; PC_VAR=RISK_VERIFY; PC_CMD="${RISK_VERIFY_CMD:-}"; PC_TIMEOUT="${RISK_VERIFY_TIMEOUT_SEC:-600}"; PC_DIR="$RISK_VERIFY_DIR"
  PC_BASE=""; PC_SCOPE=""; PC_ENV=(); PC_RESULT_ENV=1; PC_EXTRA='{}'; PC_POST=_risk_verify_post; PC_RESTORE_GUARD=index
  project_check_run "$1"
}
# 위험도 결과 해석(엔진의 기본 판정 뒤, 기록 전). 결과 파일이 없거나 형식이 틀리면 위험도는 UNKNOWN 이다 — LOW 로 가정하지 않는다.
_risk_verify_post() { # result-json-path
  local result="$1" level=UNKNOWN valid=false needs=false checks='[]' reasons='[]'
  if [ -s "$result" ] && jq -e 'type=="object" and (.risk_level|type=="string") and (.risk_level|IN("LOW","MEDIUM","HIGH","CRITICAL","UNKNOWN"))
       and ((.checks // [])|type=="array") and ((.reasons // [])|type=="array") and ((.needs_human // false)|type=="boolean")
       and ((.checks // []) | all(type=="object" and (.name|type=="string") and (.name|length>0) and (.status|type=="string") and (.status|IN("PASS","FAIL","SKIPPED"))))
       and ((.reasons // []) | all(type=="string"))' "$result" >/dev/null 2>&1; then
    valid=true; level="$(jq -r '.risk_level' "$result")"; needs="$(jq -r '.needs_human // false' "$result")"
    checks="$(jq -c '.checks // []' "$result")"; reasons="$(jq -c '.reasons // []' "$result")"
  fi
  PC_EXTRA="$(jq -nc --arg level "$level" --argjson valid "$valid" --argjson needs "$needs" --argjson checks "$checks" --argjson reasons "$reasons" --arg result "$result" \
    '{risk_level:$level, result_valid:$valid, needs_human:$needs, checks:$checks, reasons:$reasons, result:$result}')"
  [ "$CHECK_STATUS" = PASS ] || return 0   # 위반·실행 오류는 그대로 — 위험도는 진단 정보로만 붙는다
  if [ "$valid" != true ]; then
    CHECK_STATUS=ERROR; CHECK_KIND=RESULT_INVALID
    CHECK_DETAIL="exit 0 인데 결과 JSON(RISK_VERIFY_RESULT=$result)이 없거나 계약({\"risk_level\":\"LOW|MEDIUM|HIGH|CRITICAL|UNKNOWN\", \"checks\":[{\"name\":\"…\",\"status\":\"PASS|FAIL|SKIPPED\"}]?, \"reasons\":[\"…\"]?, \"needs_human\":bool?})에 맞지 않는다 — 위험도를 LOW 로 가정하지 않는다"
  elif jq -e 'any(.[]; .status=="FAIL")' <<< "$checks" >/dev/null 2>&1; then
    # 개별 검증이 실패했다고 적어 놓고 exit 0 — 종료 코드와 결과가 모순이다. 통과로 받지 않고, 코드 위반(워커 수정)으로도 보내지 않는다: 검증 명령의 결과 계약 오류다.
    CHECK_STATUS=ERROR; CHECK_KIND=RESULT_INCONSISTENT
    CHECK_DETAIL="exit 0(정상)인데 결과 JSON 의 checks 에 실패한 검증이 있다($(jq -r '[.[] | select(.status=="FAIL") | .name] | join(", ")' <<< "$checks")) — 종료 코드와 개별 검증 결과가 모순이라 통과로 받지 않는다. 실패한 검증이 있으면 명령은 exit 1 + 진단을 내야 한다"
  elif [ "$level" = UNKNOWN ]; then
    CHECK_STATUS=NEEDS_USER; CHECK_KIND=RISK_UNKNOWN
    CHECK_DETAIL="프로젝트 검증 명령이 이 변경의 위험도를 판정하지 못했다(risk_level=UNKNOWN) — LOW 로 간주하지 않고 모델에게 추측시키지도 않는다"
  elif [ "$needs" = true ]; then
    CHECK_STATUS=NEEDS_USER; CHECK_KIND=HUMAN_REVIEW_REQUIRED
    CHECK_DETAIL="프로젝트 검증 명령이 사람의 확인을 요구했다(risk_level=$level, needs_human=true)"
  fi
}

# project_check_run <label> — 공용 실행 엔진. 위 프로필(PC_*)을 읽는다. 반환: 0 PASS · 10 SKIPPED · 20 VIOLATION · 30 ERROR · 40 NEEDS_USER · 1 엔진 자체의 실패
project_check_run() {
  local label="$1" cmd="$PC_CMD" timeout="$PC_TIMEOUT" name="$PC_NAME" check_dir="$PC_DIR" record history
  record="$check_dir/last.json"; history="$check_dir/history.jsonl"
  CHECK_STATUS=""; CHECK_KIND=""; CHECK_LOG=""; CHECK_DETAIL=""; CHECK_EXIT_CODE=""; CHECK_RECORD="$record"
  if ! _check_cmd_set "$cmd"; then
    CHECK_STATUS=SKIPPED
    echo "[$(date '+%F %T')] [$name] 생략($label): ${PC_VAR}_CMD 미설정 — 검사를 실행하지 않았다(실행·통과로 집계하지 않음)"
    return 10
  fi

  # 직전 실행의 읽기 전용 위반이 복구되지 않았으면 명령을 실행하지 않는다(새 기록도 쓰지 않는다 — 마지막 기록은 그 위반 그대로다)
  local ro_rc=0
  check_readonly_violation_pending "$check_dir" "${PC_RESTORE_GUARD:-index}" || ro_rc=$?
  case "$ro_rc" in
    0) CHECK_STATUS=ERROR; CHECK_KIND="$CHECK_RO_KIND"; CHECK_DETAIL="$CHECK_RO_DETAIL"
       CHECK_LOG="$(jq -r '.log // ""' "$record")"; CHECK_EXIT_CODE="$(jq -r '.exit_code // ""' "$record")"
       echo "[$(date '+%F %T')] [$name] 실행하지 않음($label) — 직전 읽기 전용 위반 미복구($CHECK_KIND): $CHECK_DETAIL"
       return 30;;
    1) ;;
    *) echo "[FAIL] [$name] 직전 읽기 전용 위반의 복구 여부를 판정하지 못함" >&2; return 1;;
  esac

  local root abs_dir seq tag log list timeout_marker result_file
  root="$(git rev-parse --show-toplevel)" || { echo "[FAIL] [$name] worktree 루트를 확인할 수 없음" >&2; return 1; }
  mkdir -p "$check_dir" || { echo "[FAIL] [$name] 산출물 디렉터리 생성 실패: $check_dir" >&2; return 1; }
  abs_dir="$(cd "$check_dir" && pwd)" || return 1
  seq=1; [ ! -f "$history" ] || seq=$(( $(wc -l < "$history") + 1 ))
  tag="$(printf '%04d' "$seq")"
  # 기록(history)을 남기지 못하고 죽은 실행의 로그·결과 파일을 덮어쓰지 않는다 — 비어 있는 번호까지 올린다
  while [ -e "$check_dir/check-$tag.log" ] || [ -e "$check_dir/check-$tag.result.json" ]; do seq=$((seq + 1)); tag="$(printf '%04d' "$seq")"; done
  log="$check_dir/check-$tag.log"; list="$abs_dir/check-$tag.changed-files.txt"; timeout_marker="$abs_dir/check-$tag.timeout"; result_file="$abs_dir/check-$tag.result.json"
  CHECK_LOG="$log"

  local before_tree after_tree index_before index_after baseline="" base rc=0 timed_out=0 started finished t0 duration
  local status="" kind="" modified="" out_of_scope="" index_modified=false
  before_tree="$(snapshot_worktree_tree)" || { echo "[FAIL] [$name] 실행 전 tree 스냅샷 실패" >&2; return 1; }
  index_before="$(compute_index_fingerprint)" || { echo "[FAIL] [$name] 실행 전 git index 지문 계산 실패" >&2; return 1; }
  baseline="$(read_worker_baseline_tree)" || return 1
  base="${PC_BASE:-${baseline:-HEAD}}"
  # 변경 파일 목록: 기준(전체 검사 = 워커 진입 기준선, unit 검사 = 그 unit 의 시작 tree) → 현재 스냅샷, 삭제 제외.
  # 범위 manifest(전체 = feature-scope, unit 검사 = 그 unit 의 scope.json)가 유효하면 그 범위만(리뷰 diff 와 같은 방식 — glob 해석 없이 literal).
  local pathspecs=() ps
  if [ -n "$PC_SCOPE" ]; then
    while IFS= read -r ps; do pathspecs+=(":(literal)$ps"); done < <(SCOPE_MANIFEST_OVERRIDE="$PC_SCOPE" feature_scope_pathspecs)
  elif feature_scope_present && feature_scope_valid 2>/dev/null; then
    while IFS= read -r ps; do pathspecs+=(":(literal)$ps"); done < <(feature_scope_pathspecs)
  fi
  # 경로는 git 의 인용 표기가 아니라 실제 문자열 그대로 넘긴다: -z 출력(NUL 구분, 인용 없음)을 줄 단위로 바꾼다. 인용 표기("src/\352\267\234….java")를 그대로 주면
  # 확장자로 고르는 어댑터가 한글·특수문자 경로를 목록에서 빠뜨리고도 통과(exit 0)한다. (경로 안의 개행 문자는 표현할 수 없다 — 줄 단위 목록의 한계.)
  if [ "${#pathspecs[@]}" -gt 0 ]; then
    git diff -z --no-renames --name-only --diff-filter=d "$base" "$before_tree" -- "${pathspecs[@]}" > "$list.z"
  else
    git diff -z --no-renames --name-only --diff-filter=d "$base" "$before_tree" -- > "$list.z"
  fi || { echo "[FAIL] [$name] 변경 파일 목록 생성 실패" >&2; return 1; }
  tr '\0' '\n' < "$list.z" > "$list" || { echo "[FAIL] [$name] 변경 파일 목록 변환 실패" >&2; return 1; }

  started="$(date '+%FT%T%z')"; t0=$SECONDS
  case "$timeout" in
    ''|*[!0-9]*|0) status=ERROR; kind=INVALID_CONFIG; : > "$log"
       CHECK_DETAIL="${PC_VAR}_TIMEOUT_SEC 가 양의 정수가 아님('$timeout') — 명령을 실행하지 않았다";;
  esac
  if [ -z "$status" ]; then
    echo "[$(date '+%F %T')] [$name] #$tag 실행($label): $cmd  (cwd: $root, 제한 ${timeout}s, 변경 파일 $(wc -l < "$list" | tr -d ' ')개)"
    local cmd_pid dog_pid nap monitor_was_on=0 tries=0
    # 명령에 넘길 환경 변수: <접두>_ROOT · <접두>_CHANGED_FILES (+ 결과 JSON 경로 · 프로필의 추가 변수). bash 3.2 의 빈 배열 + set -u 를 피해 조립한다.
    local check_env=("${PC_VAR}_ROOT=$root" "${PC_VAR}_CHANGED_FILES=$list") extra_env
    [ "$PC_RESULT_ENV" != 1 ] || check_env+=("${PC_VAR}_RESULT=$result_file")
    for extra_env in ${PC_ENV[@]+"${PC_ENV[@]}"}; do check_env+=("$extra_env"); done
    # 명령을 자기 프로세스 그룹(pgid = cmd_pid)에서 띄운다 — 타임아웃 때 명령이 띄운 자식·손자까지 그룹 단위로 정리하기 위해서다.
    # (bash 의 job control 을 이 한 줄 동안만 켠다. setsid 로 그룹을 벗어난 프로세스는 잡지 못한다.)
    case "$-" in *m*) monitor_was_on=1;; esac
    set -m
    ( cd "$root" && exec env "${check_env[@]}" bash -c "$cmd" ) > "$log" 2>&1 < /dev/null &
    cmd_pid=$!
    [ "$monitor_was_on" = 1 ] || set +m
    # 감시자: 제한 시간이 지나면 표식 파일을 남기고 그룹 전체에 TERM, 2초 뒤 KILL. 표준 입출력을 끊어 러너의 tee 파이프를 붙잡지 않는다.
    ( set +e
      trap 'kill "$nap" 2>/dev/null; exit 0' TERM
      sleep "$timeout" & nap=$!; wait "$nap" || exit 0
      : > "$timeout_marker"
      kill -TERM -- "-$cmd_pid" 2>/dev/null; kill -TERM "$cmd_pid" 2>/dev/null
      sleep 2 & nap=$!; wait "$nap" || exit 0
      kill -KILL -- "-$cmd_pid" 2>/dev/null; kill -KILL "$cmd_pid" 2>/dev/null
    ) > /dev/null 2>&1 < /dev/null &
    dog_pid=$!
    wait "$cmd_pid" 2>/dev/null; rc=$?
    kill -TERM "$dog_pid" 2>/dev/null; wait "$dog_pid" 2>/dev/null
    if [ -f "$timeout_marker" ]; then
      timed_out=1
      # 명령 본체가 TERM 으로 끝나면 위에서 감시자를 멈췄으므로 감시자의 KILL 단계는 실행되지 않는다. TERM 을 무시한 자식이 남아 있을 수 있으니
      # 여기서 그룹 전체를 KILL 하고 사라질 때까지(최대 5초) 기다린다 — 아래 사후 스냅샷은 정리가 끝난 뒤의 작업 트리여야 한다.
      kill -KILL -- "-$cmd_pid" 2>/dev/null
      while kill -0 -- "-$cmd_pid" 2>/dev/null && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries + 1)); done
      ! kill -0 -- "-$cmd_pid" 2>/dev/null || echo "[WARN] [$name] 타임아웃 뒤에도 검사 프로세스 그룹($cmd_pid)이 남아 있다 — 직접 확인하라" >&2
    fi
  fi
  duration=$((SECONDS - t0)); finished="$(date '+%FT%T%z')"
  CHECK_EXIT_CODE="$rc"

  # 읽기 전용 계약 확인 — 종료 코드보다 먼저 본다(위반이든 통과든, 검사가 코드를 바꿨으면 그 결과는 지금의 코드에 대한 것이 아니다)
  after_tree="$(snapshot_worktree_tree)" || { echo "[FAIL] [$name] 실행 후 tree 스냅샷 실패" >&2; return 1; }
  index_after="$(compute_index_fingerprint)" || { echo "[FAIL] [$name] 실행 후 git index 지문 계산 실패" >&2; return 1; }
  if [ "$after_tree" != "$before_tree" ]; then
    modified="$(git -c core.quotePath=false diff --no-renames --name-status "$before_tree" "$after_tree" -- | tr '\t' ' ')"
    if feature_scope_present && feature_scope_valid 2>/dev/null; then
      out_of_scope="$(feature_scope_violations "$before_tree" "$after_tree" "$baseline")"
    fi
  fi
  [ "$index_after" = "$index_before" ] || index_modified=true

  if [ -z "$status" ]; then
    if [ "$index_modified" = true ]; then
      status=ERROR; kind=INDEX_MODIFIED
      CHECK_DETAIL="검사 명령이 git index 를 바꿨다(git add/reset/stash 등) — 읽기 전용 계약 위반. 자동 복구하지 않았다"
    elif [ -n "$modified" ]; then
      status=ERROR; kind=WORKTREE_MODIFIED
      CHECK_DETAIL="검사 명령이 작업 트리를 바꿨다(자동 수정·포매팅·파일 생성/삭제) — 읽기 전용 계약 위반. 변경은 원복하지 않고 그대로 뒀다: $(printf '%s' "$modified" | paste -sd, -)${out_of_scope:+ / 그중 feature-scope 밖: $(printf '%s' "$out_of_scope" | paste -sd, -)}"
    elif [ "$timed_out" = 1 ]; then
      status=ERROR; kind=TIMEOUT
      CHECK_DETAIL="제한 시간 ${timeout}s 초과로 종료시켰다(exit $rc)"
    elif [ "$rc" -eq 0 ]; then
      status=PASS
    elif [ "$rc" -eq 1 ] && [ -s "$log" ]; then
      status=VIOLATION
    elif [ "$rc" -eq 1 ]; then
      status=ERROR; kind=NO_DIAGNOSTICS
      CHECK_DETAIL="exit 1(규칙 위반)인데 출력이 비어 있다 — 무엇을 고쳐야 하는지 해석할 수 없다"
    elif [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
      status=ERROR; kind=COMMAND_NOT_RUNNABLE
      CHECK_DETAIL="명령을 실행할 수 없다(exit $rc — 도구 누락·경로 오류·실행 권한 없음)"
    else
      status=ERROR; kind=UNEXPECTED_EXIT
      CHECK_DETAIL="계약에 없는 종료 코드 exit $rc (0=정상, 1=규칙 위반만 해석한다)"
    fi
  fi
  CHECK_STATUS="$status"; CHECK_KIND="$kind"; CHECK_TREE="$after_tree"
  # 프로필의 사후 해석(위험도 결과 등) — 기본 판정을 PASS 에서 ERROR/NEEDS_USER 로 낮출 수만 있다(위반·오류를 통과로 올리는 경로는 없다)
  if [ -n "$PC_POST" ]; then
    "$PC_POST" "$result_file" || { echo "[FAIL] [$name] 결과 해석 실패" >&2; return 1; }
    status="$CHECK_STATUS"; kind="$CHECK_KIND"
  fi

  jq -nc --argjson v "$FAST_CHECK_RECORD_VERSION" --argjson seq "$seq" --arg label "$label" --arg status "$status" --arg kind "$kind" \
    --arg cmd "$cmd" --arg cmd_sha "$(printf '%s' "$cmd" | sha256_stdin)" --arg cwd "$root" --arg timeout "$timeout" --argjson rc "$rc" \
    --argjson timed_out "$timed_out" --argjson duration "$duration" --arg log "$log" --arg list "$list" \
    --arg before "$before_tree" --arg after "$after_tree" --arg idx_before "$index_before" --arg idx_after "$index_after" --argjson index_modified "$index_modified" \
    --arg modified "$modified" --arg oos "$out_of_scope" --arg detail "$CHECK_DETAIL" --arg started "$started" --arg finished "$finished" --argjson extra "$PC_EXTRA" \
    '{version:$v, seq:$seq, label:$label, status:$status, kind:(if $kind=="" then null else $kind end), cmd:$cmd, cmd_sha256:$cmd_sha, cwd:$cwd,
      timeout_sec:($timeout|tonumber? // $timeout), exit_code:$rc, timed_out:($timed_out==1), duration_sec:$duration, log:$log, changed_files:$list,
      tree_before:$before, tree_after:$after, index_before:$idx_before, index_after:$idx_after, index_modified:$index_modified,
      modified_paths:($modified | split("\n") | map(select(length>0))), out_of_scope_paths:($oos | split("\n") | map(select(length>0))),
      detail:(if $detail=="" then null else $detail end), started_at:$started, finished_at:$finished} + $extra' > "$record.tmp" \
    && mv "$record.tmp" "$record" && cat "$record" >> "$history" \
    || { echo "[FAIL] [$name] 실행 기록 저장 실패: $record" >&2; return 1; }

  case "$status" in
    PASS)
      echo "[$(date '+%F %T')] [$name] #$tag 통과 — exit 0, ${duration}s, 로그 $log"
      return 0;;
    VIOLATION)
      echo "[$(date '+%F %T')] [$name] #$tag 규칙 위반 — exit 1, ${duration}s, 진단 원본 $log (아래는 마지막 40줄)"
      tail -40 "$log" | sed 's/^/  | /'
      return 20;;
    NEEDS_USER)
      echo "[$(date '+%F %T')] [$name] #$tag 사용자 판단 필요($kind) — $CHECK_DETAIL. ${duration}s, 로그 $log"
      return 40;;
    *)
      echo "[$(date '+%F %T')] [$name] #$tag 실행 오류($kind) — $CHECK_DETAIL. ${duration}s, 로그 $log (아래는 마지막 20줄)"
      tail -20 "$log" | sed 's/^/  | /'
      return 30;;
  esac
}
