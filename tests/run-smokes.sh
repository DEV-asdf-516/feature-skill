#!/usr/bin/env bash
# =============================================================
# 무과금 스모크 병렬 실행기 (모델 호출 0회 — 유료 회귀 *-regression.sh 는 실행하지 않는다)
# 사용: bash tests/run-smokes.sh [-j N] [이름 패턴...]
#   bash tests/run-smokes.sh                 전부(tests/smoke-*.sh + install-smoke.sh + validator-fixture-smoke.py)
#   bash tests/run-smokes.sh -j 4 native     이름에 'native' 가 들어간 것만, 동시에 4개
# 각 스모크는 자기 임시 저장소를 쓰므로 서로 독립이다. 직렬로 약 20분 걸리는 것을 동시에 돌린다.
# NTFY_TOPIC 은 미설정 사례를 깨므로 지우고 실행한다. 로그는 스모크별 파일로 남기고, 실패한 것은 끝 20줄을 보여 준다.
# 종료 코드: 전부 통과 0, 하나라도 실패 1.
# =============================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
JOBS="$( (sysctl -n hw.ncpu || nproc) 2>/dev/null | head -1)"; JOBS="${JOBS:-4}"; [ "$JOBS" -le 8 ] || JOBS=8
if [ "${1:-}" = "-j" ]; then JOBS="${2:?-j 뒤에 동시 실행 수가 필요하다}"; shift 2; fi
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/feature-smokes-XXXXXX")"

list() {
  local t p keep
  for t in tests/smoke-*.sh tests/install-smoke.sh tests/validator-fixture-smoke.py; do
    [ -f "$t" ] || continue
    if [ "$#" -eq 0 ]; then echo "$t"; continue; fi
    keep=0; for p in "$@"; do case "$t" in *"$p"*) keep=1;; esac; done
    [ "$keep" = 0 ] || echo "$t"
  done
}
run_one() { # test-path logs-dir
  local t="$1" log="$2/$(basename "$1").log" s rc=0
  s="$(date +%s)"
  case "$t" in
    *.py) env -u NTFY_TOPIC python3 "$t" > "$log" 2>&1 || rc=$?;;
    *) env -u NTFY_TOPIC bash "$t" > "$log" 2>&1 || rc=$?;;
  esac
  printf '%s %s %ss\n' "$([ "$rc" = 0 ] && echo PASS || echo FAIL)" "$t" "$(( $(date +%s) - s ))" | tee -a "$2/summary.txt"
}
export -f run_one

tests="$(list "$@")"
[ -n "$tests" ] || { echo "실행할 스모크가 없다(패턴: $*)" >&2; exit 1; }
start="$(date +%s)"
echo "스모크 $(printf '%s\n' "$tests" | wc -l | tr -d ' ')개, 동시 ${JOBS}개 — 로그: ${LOGS}"
printf '%s\n' "$tests" | xargs -P "$JOBS" -I{} bash -c 'run_one "$1" "$2"' _ {} "$LOGS"

fails="$(grep -c '^FAIL ' "$LOGS/summary.txt" || true)"
echo "----"
echo "통과 $(grep -c '^PASS ' "$LOGS/summary.txt" || true) / 실패 $fails / $(( $(date +%s) - start ))s"
if [ "$fails" != 0 ]; then
  grep '^FAIL ' "$LOGS/summary.txt" | while read -r _ t _; do
    echo "===== $t (끝 20줄) ====="; tail -20 "$LOGS/$(basename "$t").log"
  done
  exit 1
fi
