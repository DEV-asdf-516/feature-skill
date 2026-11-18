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
#                                 duration_sec, log, changed_files, tree_before, tree_after, index_modified, modified_paths[], out_of_scope_paths[],
#                                 started_at, finished_at}
#   이 기록은 증거일 뿐 성공 캐시가 아니다 — 어떤 게이트도 과거 PASS 기록으로 검사를 건너뛰지 않는다(경계마다 다시 실행한다).
# =============================================================

FAST_CHECK_DIR="$WORK_DIR/fast-check"
FAST_CHECK_RECORD="$FAST_CHECK_DIR/last.json"
FAST_CHECK_HISTORY="$FAST_CHECK_DIR/history.jsonl"
FAST_CHECK_RECORD_VERSION=1
FAST_CHECK_STATUS=""; FAST_CHECK_KIND=""; FAST_CHECK_LOG=""; FAST_CHECK_DETAIL=""; FAST_CHECK_EXIT_CODE=""

fast_check_cmd() { printf '%s' "${FAST_CHECK_CMD:-}"; }
fast_check_configured() { # 공백뿐인 값도 미설정이다
  local cmd; cmd="$(fast_check_cmd)"
  [ -n "${cmd//[[:space:]]/}" ]
}

# fast_check_run <label>
#   반환: 0 PASS · 10 SKIPPED(미설정) · 20 VIOLATION(규칙 위반) · 30 ERROR(실행 오류) · 1 이 헬퍼 자체의 실패(스냅샷·기록 불가)
#   결과는 FAST_CHECK_STATUS / FAST_CHECK_KIND / FAST_CHECK_LOG / FAST_CHECK_EXIT_CODE / FAST_CHECK_DETAIL 에도 남긴다.
#   ERROR 의 kind: INVALID_CONFIG · TIMEOUT · COMMAND_NOT_RUNNABLE · NO_DIAGNOSTICS · UNEXPECTED_EXIT · WORKTREE_MODIFIED · INDEX_MODIFIED
fast_check_run() {
  local label="$1" cmd timeout="${FAST_CHECK_TIMEOUT_SEC:-120}"
  FAST_CHECK_STATUS=""; FAST_CHECK_KIND=""; FAST_CHECK_LOG=""; FAST_CHECK_DETAIL=""; FAST_CHECK_EXIT_CODE=""
  if ! fast_check_configured; then
    FAST_CHECK_STATUS=SKIPPED
    echo "[$(date '+%F %T')] [fast-check] 생략($label): FAST_CHECK_CMD 미설정 — 검사를 실행하지 않았다(실행·통과로 집계하지 않음)"
    return 10
  fi
  cmd="$(fast_check_cmd)"

  local root abs_dir seq tag log list timeout_marker
  root="$(git rev-parse --show-toplevel)" || { echo "[FAIL] [fast-check] worktree 루트를 확인할 수 없음" >&2; return 1; }
  mkdir -p "$FAST_CHECK_DIR" || { echo "[FAIL] [fast-check] 산출물 디렉터리 생성 실패: $FAST_CHECK_DIR" >&2; return 1; }
  abs_dir="$(cd "$FAST_CHECK_DIR" && pwd)" || return 1
  seq=1; [ ! -f "$FAST_CHECK_HISTORY" ] || seq=$(( $(wc -l < "$FAST_CHECK_HISTORY") + 1 ))
  tag="$(printf '%04d' "$seq")"
  # 기록(history)을 남기지 못하고 죽은 실행의 로그를 덮어쓰지 않는다 — 비어 있는 번호까지 올린다
  while [ -e "$FAST_CHECK_DIR/check-$tag.log" ]; do seq=$((seq + 1)); tag="$(printf '%04d' "$seq")"; done
  log="$FAST_CHECK_DIR/check-$tag.log"; list="$abs_dir/check-$tag.changed-files.txt"; timeout_marker="$abs_dir/check-$tag.timeout"
  FAST_CHECK_LOG="$log"

  local before_tree after_tree index_before index_after baseline="" base rc=0 timed_out=0 started finished t0 duration
  local status="" kind="" modified="" out_of_scope="" index_modified=false
  before_tree="$(snapshot_worktree_tree)" || { echo "[FAIL] [fast-check] 실행 전 tree 스냅샷 실패" >&2; return 1; }
  index_before="$(compute_index_fingerprint)" || { echo "[FAIL] [fast-check] 실행 전 git index 지문 계산 실패" >&2; return 1; }
  baseline="$(read_worker_baseline_tree)" || return 1
  base="${baseline:-HEAD}"
  # 변경 파일 목록: 기준선 → 현재 스냅샷, 삭제 제외. 범위 manifest 가 유효하면 그 범위만(리뷰 diff 와 같은 범위 — glob 해석 없이 literal).
  local pathspecs=() ps
  if feature_scope_present && feature_scope_valid 2>/dev/null; then
    while IFS= read -r ps; do pathspecs+=(":(literal)$ps"); done < <(feature_scope_pathspecs)
  fi
  # 경로는 git 의 인용 표기가 아니라 실제 문자열 그대로 넘긴다: -z 출력(NUL 구분, 인용 없음)을 줄 단위로 바꾼다. 인용 표기("src/\352\267\234….java")를 그대로 주면
  # 확장자로 고르는 어댑터가 한글·특수문자 경로를 목록에서 빠뜨리고도 통과(exit 0)한다. (경로 안의 개행 문자는 표현할 수 없다 — 줄 단위 목록의 한계.)
  if [ "${#pathspecs[@]}" -gt 0 ]; then
    git diff -z --no-renames --name-only --diff-filter=d "$base" "$before_tree" -- "${pathspecs[@]}" > "$list.z"
  else
    git diff -z --no-renames --name-only --diff-filter=d "$base" "$before_tree" -- > "$list.z"
  fi || { echo "[FAIL] [fast-check] 변경 파일 목록 생성 실패" >&2; return 1; }
  tr '\0' '\n' < "$list.z" > "$list" || { echo "[FAIL] [fast-check] 변경 파일 목록 변환 실패" >&2; return 1; }

  started="$(date '+%FT%T%z')"; t0=$SECONDS
  case "$timeout" in
    ''|*[!0-9]*|0) status=ERROR; kind=INVALID_CONFIG; : > "$log"
       FAST_CHECK_DETAIL="FAST_CHECK_TIMEOUT_SEC 가 양의 정수가 아님('$timeout') — 명령을 실행하지 않았다";;
  esac
  if [ -z "$status" ]; then
    echo "[$(date '+%F %T')] [fast-check] #$tag 실행($label): $cmd  (cwd: $root, 제한 ${timeout}s, 변경 파일 $(wc -l < "$list" | tr -d ' ')개)"
    local cmd_pid dog_pid nap monitor_was_on=0 tries=0
    # 명령을 자기 프로세스 그룹(pgid = cmd_pid)에서 띄운다 — 타임아웃 때 명령이 띄운 자식·손자까지 그룹 단위로 정리하기 위해서다.
    # (bash 의 job control 을 이 한 줄 동안만 켠다. setsid 로 그룹을 벗어난 프로세스는 잡지 못한다.)
    case "$-" in *m*) monitor_was_on=1;; esac
    set -m
    ( cd "$root" && FAST_CHECK_ROOT="$root" FAST_CHECK_CHANGED_FILES="$list" exec bash -c "$cmd" ) > "$log" 2>&1 < /dev/null &
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
      ! kill -0 -- "-$cmd_pid" 2>/dev/null || echo "[WARN] [fast-check] 타임아웃 뒤에도 검사 프로세스 그룹($cmd_pid)이 남아 있다 — 직접 확인하라" >&2
    fi
  fi
  duration=$((SECONDS - t0)); finished="$(date '+%FT%T%z')"
  FAST_CHECK_EXIT_CODE="$rc"

  # 읽기 전용 계약 확인 — 종료 코드보다 먼저 본다(위반이든 통과든, 검사가 코드를 바꿨으면 그 결과는 지금의 코드에 대한 것이 아니다)
  after_tree="$(snapshot_worktree_tree)" || { echo "[FAIL] [fast-check] 실행 후 tree 스냅샷 실패" >&2; return 1; }
  index_after="$(compute_index_fingerprint)" || { echo "[FAIL] [fast-check] 실행 후 git index 지문 계산 실패" >&2; return 1; }
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
      FAST_CHECK_DETAIL="검사 명령이 git index 를 바꿨다(git add/reset/stash 등) — 읽기 전용 계약 위반. 자동 복구하지 않았다"
    elif [ -n "$modified" ]; then
      status=ERROR; kind=WORKTREE_MODIFIED
      FAST_CHECK_DETAIL="검사 명령이 작업 트리를 바꿨다(자동 수정·포매팅·파일 생성/삭제) — 읽기 전용 계약 위반. 변경은 원복하지 않고 그대로 뒀다: $(printf '%s' "$modified" | paste -sd, -)${out_of_scope:+ / 그중 feature-scope 밖: $(printf '%s' "$out_of_scope" | paste -sd, -)}"
    elif [ "$timed_out" = 1 ]; then
      status=ERROR; kind=TIMEOUT
      FAST_CHECK_DETAIL="제한 시간 ${timeout}s 초과로 종료시켰다(exit $rc)"
    elif [ "$rc" -eq 0 ]; then
      status=PASS
    elif [ "$rc" -eq 1 ] && [ -s "$log" ]; then
      status=VIOLATION
    elif [ "$rc" -eq 1 ]; then
      status=ERROR; kind=NO_DIAGNOSTICS
      FAST_CHECK_DETAIL="exit 1(규칙 위반)인데 출력이 비어 있다 — 무엇을 고쳐야 하는지 해석할 수 없다"
    elif [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
      status=ERROR; kind=COMMAND_NOT_RUNNABLE
      FAST_CHECK_DETAIL="명령을 실행할 수 없다(exit $rc — 도구 누락·경로 오류·실행 권한 없음)"
    else
      status=ERROR; kind=UNEXPECTED_EXIT
      FAST_CHECK_DETAIL="계약에 없는 종료 코드 exit $rc (0=정상, 1=규칙 위반만 해석한다)"
    fi
  fi
  FAST_CHECK_STATUS="$status"; FAST_CHECK_KIND="$kind"

  jq -nc --argjson v "$FAST_CHECK_RECORD_VERSION" --argjson seq "$seq" --arg label "$label" --arg status "$status" --arg kind "$kind" \
    --arg cmd "$cmd" --arg cmd_sha "$(printf '%s' "$cmd" | sha256_stdin)" --arg cwd "$root" --arg timeout "$timeout" --argjson rc "$rc" \
    --argjson timed_out "$timed_out" --argjson duration "$duration" --arg log "$log" --arg list "$list" \
    --arg before "$before_tree" --arg after "$after_tree" --argjson index_modified "$index_modified" \
    --arg modified "$modified" --arg oos "$out_of_scope" --arg detail "$FAST_CHECK_DETAIL" --arg started "$started" --arg finished "$finished" \
    '{version:$v, seq:$seq, label:$label, status:$status, kind:(if $kind=="" then null else $kind end), cmd:$cmd, cmd_sha256:$cmd_sha, cwd:$cwd,
      timeout_sec:($timeout|tonumber? // $timeout), exit_code:$rc, timed_out:($timed_out==1), duration_sec:$duration, log:$log, changed_files:$list,
      tree_before:$before, tree_after:$after, index_modified:$index_modified,
      modified_paths:($modified | split("\n") | map(select(length>0))), out_of_scope_paths:($oos | split("\n") | map(select(length>0))),
      detail:(if $detail=="" then null else $detail end), started_at:$started, finished_at:$finished}' > "$FAST_CHECK_RECORD.tmp" \
    && mv "$FAST_CHECK_RECORD.tmp" "$FAST_CHECK_RECORD" && cat "$FAST_CHECK_RECORD" >> "$FAST_CHECK_HISTORY" \
    || { echo "[FAIL] [fast-check] 실행 기록 저장 실패: $FAST_CHECK_RECORD" >&2; return 1; }

  case "$status" in
    PASS)
      echo "[$(date '+%F %T')] [fast-check] #$tag 통과 — exit 0, ${duration}s, 로그 $log"
      return 0;;
    VIOLATION)
      echo "[$(date '+%F %T')] [fast-check] #$tag 규칙 위반 — exit 1, ${duration}s, 진단 원본 $log (아래는 마지막 40줄)"
      tail -40 "$log" | sed 's/^/  | /'
      return 20;;
    *)
      echo "[$(date '+%F %T')] [fast-check] #$tag 실행 오류($kind) — $FAST_CHECK_DETAIL. ${duration}s, 로그 $log (아래는 마지막 20줄)"
      tail -20 "$log" | sed 's/^/  | /'
      return 30;;
  esac
}
