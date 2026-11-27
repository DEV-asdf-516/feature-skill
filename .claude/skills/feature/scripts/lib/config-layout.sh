#!/usr/bin/env bash
# =============================================================
# .claude/skills/feature/scripts/lib/config-layout.sh
# config.sh 소유권 판정 — config.sh 가 사용자 설정 전용인가(런타임 본문이 섞인 분리 이전 설정인가)를 줄 텍스트로만 본다(config.sh 를 실행하지 않는다).
# scripts/lib/bootstrap.sh 가 config.sh 를 source 하기 전에, install.sh 가 소스 저장소에서(대상 런타임 없이) 같은 함수를 쓴다.
# 정의만 있고 실행문이 없다 — 직접 실행하지 않는다. (분리 전 config.sh 에는 없던 새 판정이다)
# 런타임 소유 줄은 두 가지다:
#   (a) 런타임 함수 이름의 정의 줄(`이름()` / `function 이름`, 앞 공백 허용). 이름 집합은 이 파일이 있는 scripts/lib/ 의 모듈이 정의하는 함수 전부다 —
#       목록을 따로 두지 않는다(옮겨 간 헬퍼 이름 그대로다). 분리 이전의 모든 config.sh 는 그 헬퍼들(render_prompt 등)을 정의하므로 이 조항만으로 잡힌다.
#       런타임 이름이 아닌 함수 모양의 줄(사용자 함수, 여러 줄 설정 문자열 안의 `run_checks() {` 같은 줄)은 판정하지 않는다.
#       모듈에서 이름을 모을 때는 bash 정의 모양만 센다: `이름()`, 또는 `function 이름` 뒤에 빈 괄호·공백·`{` — 매개변수가 든 `function 이름(a, b)` 는
#       모듈 안 awk 프로그램의 함수(이 파일의 fname 등)라 bash 함수가 아니다. 그것까지 모으면 같은 이름의 사용자 함수(`fname() { :; }`)를 거부했다.
#   (b) 런타임 소유 이름 8개의 대입(export 형태 포함): 계약·포맷 버전 상수 6개와 PROJECT_ROOT·FEATURE_SKILL_DIR(로더가 config.sh 보다 먼저 정한다).
# 한계: 줄 단위 판정이지 Bash 파서가 아니다. 여러 줄 문자열 안이라도 줄 첫머리에 런타임 이름의 정의·대입이 오면(예: `PROJECT_ROOT=… ./run-tests` 로
#   시작하는 줄) 위반으로 본다 — 실패 쪽으로 닫히고 그 줄 번호를 보여 준다. 그런 명령은 줄 첫머리가 그 이름이 되지 않게 쓰거나(예: `env PROJECT_ROOT=…`) 스크립트 파일로 옮긴다.
# config 경로는 awk 에 넘기지 않는다 — config 는 stdin 으로 읽는다. awk 는 `-v` 값의 백슬래시를 이스케이프로 풀고(판마다 다름) `이름=…` 모양의 operand 를
#   파일이 아니라 변수 대입으로 본다. 경로를 넘기면 그런 경로의 config 가 판정 없이 통과했다. 모듈 경로는 절대 경로(`/` 로 시작)라 대입으로 읽히지 않는다.
#   config 단계(표식 operand `incfg=1` 뒤)에 들어가지 못했으면 판정할 수 없다(2) — 통과(0)로 끝나지 않는다.
# =============================================================

feature_config_runtime_lines() { # config-file → stdout: 위반 줄(줄번호:내용). 반환 0 설정 전용 / 1 위반 / 2 읽기·판정 실패
  [ -f "$1" ] && [ -r "$1" ] || return 2
  local lib f out rc=0
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 2
  for f in "$lib"/*.sh "$lib"/*/*.sh; do [ -f "$f" ] && [ -r "$f" ] || return 2; done
  # 앞의 파일들(모듈)에서 함수 이름을 모으고, 표식 뒤 stdin(config.sh)의 줄을 판정한다. 모듈에서 이름을 하나도 못 모으면 판정할 수 없다(2).
  # 위반은 awk 종료 코드 3 이다 — 1·2 는 셸(리다이렉트 실패)·awk 자신의 오류와 겹치므로 판정 실패(2)로 본다.
  out="$(awk -v vars="FEATURE_RUNTIME_CONTRACT_VERSION VALIDATOR_CONTRACT_VERSION REVIEWER_CONTRACT_VERSION REVIEW_CHECKER_VERSION CONSENSUS_CHECKPOINT_VERSION REVIEW_CHECKPOINT_VERSION PROJECT_ROOT FEATURE_SKILL_DIR" '
    function fname(s,   n) {
      if (match(s, /^[[:space:]]*function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) { n = substr(s, RSTART, RLENGTH); sub(/^[[:space:]]*function[[:space:]]+/, "", n); return n }
      if (match(s, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/)) { n = substr(s, RSTART, RLENGTH); sub(/^[[:space:]]*/, "", n); sub(/[[:space:]]*\(\)$/, "", n); return n }
      return ""
    }
    function bashfname(s,   n) {
      # 모듈 쪽 이름 수집 — bash 정의 모양만. 끝에 공백을 붙여 "function 이름" 이 줄 끝에서 끝나는 경우도 같은 식으로 본다.
      if (match(s " ", /^[[:space:]]*function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*([[:space:]]*\(\))?([[:space:]]|\{)/)) {
        n = substr(s " ", RSTART, RLENGTH); sub(/^[[:space:]]*function[[:space:]]+/, "", n); sub(/[^A-Za-z0-9_].*$/, "", n); return n
      }
      if (match(s, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/)) { n = substr(s, RSTART, RLENGTH); sub(/^[[:space:]]*/, "", n); sub(/[[:space:]]*\(\)$/, "", n); return n }
      return ""
    }
    BEGIN { nv = split(vars, v, " "); for (i = 1; i <= nv; i++) owned_var[v[i]] = 1 }
    !incfg { n = bashfname($0); if (n != "") { owned_fn[n] = 1; nf++ } next }
    {
      if (nf == 0) exit 2
      n = fname($0)
      if (n != "" && (n in owned_fn)) { print FNR ":" $0; bad = 1; next }
      if (match($0, /^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
        a = substr($0, RSTART, RLENGTH); sub(/^[[:space:]]*(export[[:space:]]+)?/, "", a); sub(/=$/, "", a)
        if (a in owned_var) { print FNR ":" $0; bad = 1 }
      }
    }
    END { if (nf == 0 || !incfg) exit 2; exit bad ? 3 : 0 }' "$lib"/*.sh "$lib"/*/*.sh incfg=1 - < "$1")" || rc=$?
  case "$rc" in 0) return 0 ;; 3) printf '%s\n' "$out"; return 1 ;; *) return 2 ;; esac
}
