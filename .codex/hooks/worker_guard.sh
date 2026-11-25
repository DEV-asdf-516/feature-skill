#!/bin/bash
# codex PreToolUse 훅 (프로젝트 레벨)
# codex 편집 역할(워커·수정자·디자이너)의 커밋·푸시·index 조작·파일 삭제를 막는다(claude 쪽의 대응물은 pre_bash_guard.sh — 판정 규칙은 이 파일과 따로다).
# exit 2 = 도구 호출 차단, stderr 가 codex 에게 거부 사유로 전달된다. exit 0 = 허용.
# 검증자·리뷰어는 read-only 샌드박스라 이 훅에 걸릴 일이 없다.
#
# 판정 원칙:
#   - 검사하지 못한 호출은 허용하지 않는다. jq 없음·빈 입력·JSON 아님·tool_input 없음은 모두 차단이다(exit 0 으로 흘리지 않는다).
#   - git 하위 명령은 전역 옵션(-C <경로>, -c <k=v>, --git-dir …)을 건너뛴 뒤의 것으로 본다.
#   - 삭제는 명령 단위로 본다: 한 호출 안의 삭제 명령마다 '모든' 대상이 허용 경로(.agent-work/ · /tmp/ · /private/tmp/)여야 한다.
#     허용 경로를 지우는 명령이 하나 있다고 해서 같은 호출의 다른 삭제가 통과하지 않는다.
#   - 삭제 대상은 글자 그대로 읽을 수 있는 경로여야 한다: 영문·숫자와 `_ . / @ % + = : , -` 만으로 된 토큰만 대상으로 인정한다.
#     변수($X) · 명령 치환 · 글로브(* ? [ ]) · 중괄호 확장 · 역슬래시 · ~ · 공백이 든 대상은 허용 경로로 시작해도 차단이다
#     (`.agent-work/$X` 는 셸이 풀기 전에는 어디를 가리키는지 알 수 없다).
#   - 허용 경로 안의 심볼릭 링크를 거쳐 가는 대상은 차단이다(검사 시점에 있는 링크만 본다 — 아래 한계).
#   - 프로젝트 안에서의 이동(이름 바꾸기)은 허용한다: `mv` 의 목적지(마지막 인자, `-t` 형태면 그 값)와 apply_patch 의 `*** Move to:` 목적지가
#     글자 그대로 읽을 수 있는 프로젝트 안 경로(`..` 없는 상대 경로, 또는 작업 루트 아래의 절대 경로)면 통과다.
#     단 삭제 허용 경로(.agent-work/ · /tmp/)는 '프로젝트 안'으로 치지 않는다 — 거기로 옮긴 뒤 지우면 두 단계 삭제가 된다.
#     통과하는 mv 도 원본·옵션은 글자 그대로 읽을 수 있어야 한다(글로브 * ? [ ] 는 허용, 변수·명령 치환·중괄호는 차단 — `mv $(rm -rf src) dst`).
#     프로젝트 밖으로(또는 삭제 허용 경로·읽을 수 없는 목적지로) 옮기는 것은 원래 경로의 삭제다 — 그때는 원본 전부에 삭제와 같은 허용 경로 규칙을 적용한다.
#     `git mv` 는 index 를 바꾸므로 index 조작으로 막는다. `.codex/` 를 원본·목적지로 하는 `mv` 는 막는다.
#   - apply_patch 의 `*** Delete File:` 도 삭제다(같은 허용 경로 규칙).
#   - 삭제·이동 명령 이름(rm · unlink · rmdir · shred · mv)은 명령 자리인지 따지지 않고 어느 자리에 있든 그 명령으로 본다. 감싸는 명령(timeout · sudo -u … · xargs -n 1 · eval …)을
#     목록으로 가려내는 방식은 목록에 없는 것을 놓친다. 그 대가로 삭제 명령 이름을 인자로 넘기는 읽기 명령(예: grep 의 검색어)도 막힌다 — 막는 쪽으로 틀린다.
#   - `.codex/`(이 가드와 훅 정의)를 대상으로 한 apply_patch(Add · Update · Delete · Move to)는 차단이다. 이것은 인계철선이다 — 아래 한계.
#     셸 명령의 `.codex/` 언급은 막지 않는다: 이 훅은 읽기 전용 역할의 호출에도 걸리고, 그 역할이 이 파일들을 읽는 것은 정당하다.
#
# 한계: 문자열 검사다. 다른 인터프리터로 지우는 경우(python -c, node -e …), 변수·alias 로 명령 이름을 감춘 경우, 리다이렉션으로 내용을 비우는 경우는 잡지 못한다.
#   같은 호출 안에서 심볼릭 링크를 만들고 곧바로 그 링크를 거쳐 지우는 경우도 잡지 못한다(검사 시점에는 링크가 없다).
#   `mv` 의 목적지가 프로젝트 안인지는 적힌 글자로만 본다: 같은 호출에서 `cd` 로 디렉터리를 옮긴 뒤의 상대 경로, 프로젝트 밖을 가리키는 심볼릭 링크 목적지,
#   목적지에 이미 있던 파일을 덮어쓰는 이동은 가려내지 못한다.
#   셸 명령으로 `.codex/` 아래를 고쳐 쓰는 것(리다이렉션 · sed -i · cp …)은 이 스크립트가 막지 않는다 — 가드 파일 자체의 보호는
#   codex 의 workspace-write sandbox(.codex · .git 쓰기 거부)와 러너의 호출 전후 대조가 맡는다.
#   그 밖의 경로는 러너의 사후 게이트(HEAD·index 지문·범위 대조)가 받는다 — 이 훅은 1차 차단이지 유일한 방어가 아니다.
#
# 프로젝트별 보호(생성 코드·마이그레이션 편집 금지 등)가 필요하면 같은 패턴(검사 → block)으로 맨 아래 `exit 0` 앞에 추가한다.
# 주의: hooks.json 의 command 경로가 상대 경로이므로 codex 를 저장소 루트에서 실행해야 한다.

# 가드 계약 세대. Codex App Server backend 의 필수 훅 게이트가 이 줄을 대조한다 — 세대가 낮은(우회 가능한) 가드로는 편집 역할을 실행하지 않는다.
# 게이트는 이 줄에 더해 이 파일의 sha256 을 검토된 지문 목록(배포본의 지문 + 사용자가 등록한 지문)과 대조한다 — 줄만 붙인 가드는 통과하지 못한다.
# 게이트는 이 스크립트를 실행하지 않는다(판정 회귀는 tests/smoke-worker-guard.sh 가 본다).
# 이 파일을 프로젝트에 맞게 고쳐 쓰면 지문이 달라진다: 본문을 직접 검토한 뒤 그 지문을 CODEX_APP_GUARD_REVIEWED_SHA256 에 등록해야 편집 역할이 실행된다
# (references/codex-app-server.md). 고쳐 쓰더라도 위 판정 원칙을 지키는 한 이 줄은 그대로 둔다. 원칙을 지키지 않는 가드에 이 줄만 붙이지 않는다.
WORKER_GUARD_CONTRACT=3

block() { echo "차단: $1" >&2; exit 2; }

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || block "jq 를 찾을 수 없어 도구 호출을 검사할 수 없습니다. 검사하지 못한 호출은 허용하지 않습니다."
[ -n "$INPUT" ] || block "훅 입력이 비어 있어 도구 호출을 검사할 수 없습니다."

# tool_input 의 모든 문자열 값을 공백으로 이어 붙인다 — command 가 문자열이든 argv 배열이든 같은 모양이 된다.
TEXT=$(printf '%s' "$INPUT" | jq -er 'if type == "object" and (.tool_input != null) then ([.tool_input | .. | strings] | join(" ")) else error("no tool_input") end' 2>/dev/null) \
  || block "훅 입력을 해석하지 못했습니다(JSON 이 아니거나 tool_input 이 없음). 검사하지 못한 호출은 허용하지 않습니다."
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // "" | tostring' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "" | tostring' 2>/dev/null)

[ -n "$TEXT" ] || exit 0   # 문자열 인자가 하나도 없는 호출 — 검사할 명령이 없다

strip_quotes() { local p="$1"; p="${p#\"}"; p="${p%\"}"; p="${p#\'}"; p="${p%\'}"; printf '%s' "$p"; }
allowed_path() { # 경로 → 0 이면 삭제 허용 경로(글자 그대로 읽을 수 있고 허용 접두사로 시작한다)
  local p; p="$(strip_quotes "$1")"
  case "$p" in ''|*[!A-Za-z0-9_./@%+=:,-]*) return 1 ;; esac
  case "$p" in *..*) return 1 ;; esac
  [ -z "$CWD" ] || case "$p" in "$CWD"/.agent-work/?*) return 0 ;; esac
  while [ "${p#./}" != "$p" ]; do p="${p#./}"; done
  case "$p" in .agent-work/?*|/tmp/?*|/private/tmp/?*) return 0 ;; esac
  return 1
}
through_symlink() { # 허용 경로 → 0 이면 심볼릭 링크를 거쳐 허용 경로 밖을 가리킬 수 있다(검사 시점의 파일시스템 기준)
  local p base rest cur comp n=0 total=0 trail=0 IFS
  p="$(strip_quotes "$1")"
  case "$p" in
    /private/tmp/*) base=/private/tmp; rest="${p#/private/tmp/}" ;;
    /tmp/*) base=/tmp; rest="${p#/tmp/}" ;;   # /tmp 자체는 시스템 링크일 수 있다(macOS) — 그 아래만 본다
    *)
      if [ -n "$CWD" ] && [ "${p#"$CWD"/.agent-work/}" != "$p" ]; then rest="${p#"$CWD"/.agent-work/}"
      else while [ "${p#./}" != "$p" ]; do p="${p#./}"; done; rest="${p#.agent-work/}"; fi
      base="${CWD:-.}/.agent-work"
      [ ! -L "$base" ] || return 0 ;;
  esac
  case "$rest" in */) trail=1 ;; esac
  IFS=/
  for comp in $rest; do [ -z "$comp" ] || total=$((total + 1)); done
  cur="$base"
  for comp in $rest; do
    [ -n "$comp" ] || continue
    n=$((n + 1)); cur="$cur/$comp"
    if [ -L "$cur" ]; then
      # 마지막 요소가 링크이고 끝에 / 가 없으면 지워지는 것은 링크 자신이다
      { [ "$n" -eq "$total" ] && [ "$trail" -eq 0 ]; } || return 0
    fi
  done
  return 1
}
protected_path() { # 경로 → 0 이면 가드·훅 정의가 있는 .codex/ 아래다
  local p; p="$(strip_quotes "$1")"
  case "$p" in .codex|.codex/*|*/.codex|*/.codex/*) return 0 ;; esac
  return 1
}
in_project_path() { # 경로 → 0 이면 이동의 목적지로 삼아도 되는 프로젝트 안 경로: 글자 그대로 읽을 수 있고(`..` 없는 상대 경로, 또는 작업 루트 아래의 절대 경로)
  # 삭제 허용 경로(.agent-work · /tmp)가 아니다 — 거기로 옮긴 파일은 다음 호출에서 지울 수 있으므로 그 이동은 삭제로 본다.
  local p; p="$(strip_quotes "$1")"
  case "$p" in ''|*[!A-Za-z0-9_./@%+=:,-]*) return 1 ;; esac
  case "$p" in *..*) return 1 ;; esac
  case "$p" in
    /*) [ -n "$CWD" ] || return 1
        case "$p" in "$CWD"/?*) p="${p#"$CWD"/}" ;; *) return 1 ;; esac ;;
  esac
  while [ "${p#./}" != "$p" ]; do p="${p#./}"; done
  case "$p" in .agent-work|.agent-work/*|/*) return 1 ;; esac
  return 0
}
header_path() { # patch 헤더 줄, 표식 → 표식 뒤의 경로(앞뒤 공백 제거)
  local t="${1#*"$2"}"
  t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
  printf '%s' "$t"
}
check_delete_target() { # 경로, 표시할 이름
  allowed_path "$1" || block "워커는 프로젝트 파일을 삭제할 수 없습니다($2: $1). 삭제·이동이 필요하면 대상과 사유를 결과 보고에 남기세요(.agent-work·/tmp 하위의 글자 그대로 적은 경로만 허용)."
  ! through_symlink "$1" || block "삭제 대상이 심볼릭 링크를 거쳐 갑니다($2: $1). 허용 경로 밖을 가리킬 수 있어 허용하지 않습니다."
}

# ---------- apply_patch 헤더: 삭제 · 이동 · 가드 파일 ----------
# 도구 이름과 무관하게 본다(셸로 부른 apply_patch 포함).
PATCH_SRC=""
while IFS= read -r line; do
  case "$line" in
    *'*** Delete File:'*)
      target="$(header_path "$line" '*** Delete File:')"
      ! protected_path "$target" || block "워커는 .codex/ 아래(가드·훅 정의)를 바꿀 수 없습니다(apply_patch 의 Delete File: $target)."
      check_delete_target "$target" "apply_patch 의 Delete File" ;;
    *'*** Update File:'*)
      PATCH_SRC="$(header_path "$line" '*** Update File:')"
      ! protected_path "$PATCH_SRC" || block "워커는 .codex/ 아래(가드·훅 정의)를 바꿀 수 없습니다(apply_patch 의 Update File: $PATCH_SRC)." ;;
    *'*** Add File:'*)
      target="$(header_path "$line" '*** Add File:')"; PATCH_SRC=""
      ! protected_path "$target" || block "워커는 .codex/ 아래(가드·훅 정의)를 바꿀 수 없습니다(apply_patch 의 Add File: $target)." ;;
    *'*** Move to:'*)
      target="$(header_path "$line" '*** Move to:')"
      ! protected_path "$target" || block "워커는 .codex/ 아래(가드·훅 정의)를 바꿀 수 없습니다(apply_patch 의 Move to: $target)."
      # 원본을 알 수 없는 Move to(직전 Update File 없음)는 허용하지 않는다.
      [ -n "$PATCH_SRC" ] || block "apply_patch 의 Move to 에 원본(직전 Update File)이 없습니다($target). 원본을 확인할 수 없는 이동은 허용하지 않습니다."
      # 프로젝트 안으로의 이동(이름 바꾸기)은 통과다. 프로젝트 밖·삭제 허용 경로로 옮기는 것은 원래 경로의 삭제다.
      in_project_path "$target" || check_delete_target "$PATCH_SRC" "apply_patch 의 Move to(프로젝트 밖) — 원본"
      PATCH_SRC="" ;;
  esac
done <<EOF_TEXT
$TEXT
EOF_TEXT

# ---------- 검사할 명령 텍스트 ----------
# 네이티브 apply_patch 도구의 본문(추가·삭제·문맥 줄)은 셸이 실행하지 않는 파일 내용이다 — 명령 검사에서 뺀다(위에서 Delete File 은 이미 봤다).
# 셸 도구로 들어온 patch 는 본문을 빼지 않는다: 그 줄들이 셸에 넘어가지 않는다고 여기서 확인할 수 없다.
case "$(printf '%s' "$TOOL_NAME" | tr '[:upper:]' '[:lower:]')" in
  apply_patch|applypatch) SCAN="" ;;
  *) SCAN="$TEXT" ;;
esac
[ -n "$SCAN" ] || exit 0
# 줄 끝 역슬래시(줄 이어 쓰기)는 한 줄로 붙인다
SCAN=$(printf '%s\n' "$SCAN" | awk '{ if (sub(/\\$/, " ")) printf "%s", $0; else print }')

# git + 전역 옵션(-C <경로> · -c <k=v> · --git-dir <경로> 처럼 값을 따로 받는 것, 그 밖의 -옵션) + 하위 명령
ARG="(\"[^\"]*\"|'[^']*'|[^[:space:]]+)"
GIT="(^|[^[:alnum:]_.-])git([[:space:]]+(-[Cc][[:space:]]+$ARG|--(git-dir|work-tree|namespace|super-prefix|config-env|exec-path)[[:space:]]+$ARG|-[^[:space:]]*))*[[:space:]]+"
END="([^[:alnum:]_-]|\$)"

# 워커 커밋/푸시 금지 (스킬 강제 규칙: 커밋은 사용자 지시 시 수정자)
if printf '%s\n' "$SCAN" | grep -qE "$GIT(commit|push|commit-tree|update-ref)$END"; then
  block "워커는 커밋/푸시할 수 없습니다. 커밋은 사용자 지시 시 수정자가 수행합니다."
fi

# 워커 index 조작 금지 — staged/unstaged 상태는 사용자의 것. 리뷰·원복은 작업 트리(worker-baseline.tree) 기준으로만 이뤄진다.
if printf '%s\n' "$SCAN" | grep -qE "$GIT(add|reset|stash|update-index|read-tree|mv)$END|${GIT}restore[[:space:]]([^;&|]*[[:space:]])?(--staged|-[a-zA-Z]*S[a-zA-Z]*)$END"; then
  block "워커는 git index 를 조작할 수 없습니다(git add/reset/stash/mv/restore --staged). 파일 내용만 수정하세요 — 이름을 바꾸려면 git 없이 mv 를 쓰세요."
fi

# 워커 파일 삭제 금지 — git 을 통한 삭제는 대상과 무관하게 막는다
if printf '%s\n' "$SCAN" | grep -qE "$GIT(rm|clean)$END"; then
  block "워커는 프로젝트 파일을 삭제할 수 없습니다(git rm/clean). 삭제가 필요하면 대상과 사유를 결과 보고에 남기세요."
fi

# 워커 파일 삭제 금지 (.agent-work·임시 경로 제외) — 명령 단위로, 모든 대상이 글자 그대로 적힌 허용 경로일 때만 통과.
# mv 는 목적지가 프로젝트 안(삭제 허용 경로 제외)이고 원본·옵션이 글자 그대로 읽히면 통과하고, 그 밖의 목적지면 원본에 삭제와 같은 규칙을 적용한다.
# 출력: "B <사유>"(차단, 첫 줄에서 끝) 또는 "T <허용된 대상>"(심볼릭 링크 검사로 넘긴다)
# 명령 구분은 ; | & 줄바꿈뿐이다. 괄호·중괄호·백틱·$( 는 대상 토큰에 남겨 두고 대상 검사에서 걸러 낸다
# (먼저 쪼개면 `.agent-work/a{,/../../src}` 나 `.agent-work/x$(…)` 의 앞부분만 남아 허용 경로로 읽힌다).
VERDICT=$(printf '%s\n' "$SCAN" | awk -v cwd="$CWD" '
  function allowed(p,   q) {
    q = p
    if (q !~ /^[A-Za-z0-9_.\/@%+=:,-]+$/) return 0
    if (index(q, "..") > 0) return 0
    if (cwd != "" && index(q, cwd "/.agent-work/") == 1 && length(q) > length(cwd "/.agent-work/")) return 1
    while (substr(q, 1, 2) == "./") q = substr(q, 3)
    if (q ~ /^\.agent-work\/./ || q ~ /^\/tmp\/./ || q ~ /^\/private\/tmp\/./) return 1
    return 0
  }
  function inproject(p,   q) {   # 이동의 목적지로 삼아도 되는 프로젝트 안 경로: 글자 그대로 읽히고(.. 없는 상대 경로, 또는 작업 루트 아래의 절대 경로) 삭제 허용 경로가 아니다
    q = p
    if (q !~ /^[A-Za-z0-9_.\/@%+=:,-]+$/) return 0
    if (index(q, "..") > 0) return 0
    if (substr(q, 1, 1) == "/") {
      if (cwd == "" || index(q, cwd "/") != 1 || length(q) <= length(cwd "/")) return 0
      q = substr(q, length(cwd) + 2)
    }
    while (substr(q, 1, 2) == "./") q = substr(q, 3)
    if (q ~ /^\.agent-work(\/|$)/ || substr(q, 1, 1) == "/") return 0   # 거기로 옮긴 뒤 지우면 두 단계 삭제다
    return 1
  }
  function guarded(p) { return p ~ /(^|\/)\.codex(\/|$)/ }   # 가드·훅 정의가 있는 .codex/
  function cmdname(t,   parts, np, j, b) {   # 토큰 안에서 명령 이름을 찾는다: (rm · $(rm · x=$(rm · `rm · /bin/rm
    np = split(t, parts, /\$\(|[(){}`=]/)
    for (j = 1; j <= np; j++) {
      b = parts[j]; sub(/^.*\//, "", b)
      if (b ~ /^(rm|unlink|rmdir|shred|mv)$/) return b
    }
    return ""
  }
  {
    line = $0
    gsub(/&&|\|\||[;|&]/, "\n", line)
    n = split(line, segs, "\n")
    for (s = 1; s <= n; s++) {
      m = split(segs[s], tok, /[[:space:]]+/)
      for (i = 1; i <= m; i++) {
        t = tok[i]; gsub(/["\047]/, "", t)
        if (t == "") continue
        if (t == "-delete") { print "B find -delete"; exit }
        b = cmdname(t)
        if (b == "") continue
        na = 0; dest = ""; hasdest = 0; badopt = ""
        for (k = i + 1; k <= m; k++) {
          a = tok[k]; gsub(/["\047]/, "", a)
          if (a == "") continue
          if (a ~ /^[0-9]*[<>]/) { if (a ~ /^[0-9]*[<>]+&?$/) k++; continue }
          if (a ~ /^-/) {
            if (b == "mv") {   # 목적지를 옵션으로 주는 형태: -t DIR · --target-directory DIR · --target-directory=DIR
              if (a !~ /^[A-Za-z0-9_.\/@%+=:,-]+$/ && badopt == "") badopt = a   # 옵션 자리에 숨긴 치환: mv -$(…) a b
              if (a ~ /^--target-directory=/) { dest = substr(a, 20); hasdest = 1 }
              else if (a == "--target-directory" || a ~ /^-[a-zA-Z]*t$/) { k++; dest = (k <= m ? tok[k] : ""); gsub(/["\047]/, "", dest); hasdest = 1 }
            }
            continue
          }
          args[++na] = a
        }
        last = na
        if (b == "mv") {
          # 마지막 인자가 목적지다(-t 형태면 그 값). 목적지가 프로젝트 안이면 이동은 통과, 아니면 원본이 곧 사라지는 경로다.
          if (!hasdest) { dest = (na >= 1 ? args[na] : ""); last = na - 1 }
          if (last < 1) { print "B mv (대상을 확인할 수 없음)"; exit }
          if (guarded(dest)) { print "B mv " dest " (.codex 아래는 옮길 수 없음)"; exit }
          for (k = 1; k <= last; k++) if (guarded(args[k])) { print "B mv " args[k] " (.codex 아래는 옮길 수 없음)"; exit }
          if (inproject(dest)) {
            # 통과하는 이동이라도 원본·옵션 자리에 다른 명령을 숨길 수 없다: mv $(rm -rf src) dst · mv `…` dst. 글로브는 실행이 아니므로 허용한다.
            if (badopt != "") { print "B mv " badopt " (옵션을 글자 그대로 읽을 수 없음)"; exit }
            for (k = 1; k <= last; k++) if (args[k] !~ /^[A-Za-z0-9_.\/@%+=:,*?\[\]-]+$/) { print "B mv " args[k] " (원본을 글자 그대로 읽을 수 없음)"; exit }
            break
          }
        }
        if (last < 1) { print "B " b " (대상을 확인할 수 없음)"; exit }
        for (k = 1; k <= last; k++) {
          if (!allowed(args[k])) { print "B " b " " args[k]; exit }
          print "T " args[k]
        }
        break
      }
    }
  }')
while IFS= read -r vline; do
  case "$vline" in
    'B '*) block "워커는 프로젝트 파일을 삭제하거나 프로젝트 밖으로 옮길 수 없습니다(${vline#B }). 한 호출 안의 삭제 명령은 모든 대상이 .agent-work·/tmp 하위의 글자 그대로 적은 경로여야 합니다(변수·글로브·명령 치환 불가). mv 는 목적지가 글자 그대로 적은 프로젝트 안 경로(.agent-work·/tmp 제외)이고 원본에 변수·명령 치환이 없을 때 통과합니다. 삭제가 필요하면 대상과 사유를 결과 보고에 남기세요." ;;
    'T '*) ! through_symlink "${vline#T }" || block "삭제 대상이 심볼릭 링크를 거쳐 갑니다(${vline#T }). 허용 경로 밖을 가리킬 수 있어 허용하지 않습니다." ;;
  esac
done <<EOF_VERDICT
$VERDICT
EOF_VERDICT

exit 0
