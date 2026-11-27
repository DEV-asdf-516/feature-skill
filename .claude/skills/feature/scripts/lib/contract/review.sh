#!/usr/bin/env bash
# =============================================================
# .claude/skills/feature/scripts/lib/contract/review.sh
# 범위·승인·수정자 재개 지문, 리뷰 계약 문서 지문, fix_ref 계약, impl_approval_current, verify_approved_fingerprint.
# scripts/lib/bootstrap.sh 가 정해진 순서로 source 한다 — 직접 실행하지 않는다.
# (분리 전 config.sh 기준 1571–1624, 1795–1907, 2584–2598)
# =============================================================

# 범위 지문: 현재 작업 트리의 git tree 객체에서 범위 경로의 엔트리(모드·유형·blob·경로)를 해시한다.
# 내용뿐 아니라 실행 권한·symlink 목적지·생성/삭제까지 잡히고, snapshot_worktree_tree 와 같은 기준(untracked 포함, WORK_DIR 제외)이다.
# manifest(lock) 자체도 포함한다 — 범위 정의가 바뀌면 이전 승인은 다른 범위에 대한 것이다.
# roots 아래는 신규 파일만 피처 변경이므로, 워커 진입 기준선(worker-baseline.tree)에 이미 있던 엔트리는 제외한다(기준선이 없으면 전부 포함).
compute_feature_fingerprint() {
  local tree path root baseline=""
  tree="$(snapshot_worktree_tree)" || return 1
  [ -f "$WORK_DIR/worker-baseline.tree" ] && baseline="$(cat "$WORK_DIR/worker-baseline.tree")"
  {
    printf 'feature-scope\0'; cat "$(feature_scope_file)"; printf '\0'
    while IFS= read -r path; do
      git ls-tree -r -z "$tree" -- ":(literal)$path"
    done < <(jq -r '.files[]' "$(feature_scope_file)")
    while IFS= read -r root; do
      root="${root%/}"
      if [ -n "$baseline" ]; then
        # 기준선에 있던 경로는 제외 (경로 기준 차집합)
        git ls-tree -r "$tree" -- ":(literal)$root/" \
          | awk -v base="$(git ls-tree -r --name-only "$baseline" -- ":(literal)$root/" | tr '\n' '\001')" \
              'BEGIN{n=split(base,a,"\001"); for(i=1;i<=n;i++) if(a[i]!="") seen[a[i]]=1} {p=$0; sub(/^[^\t]*\t/,"",p); if(!(p in seen)) print}'
      else
        git ls-tree -r "$tree" -- ":(literal)$root/"
      fi
    done < <(jq -r '(.new_file_roots // [])[]' "$(feature_scope_file)")
  } | sha256_stdin
}
# 승인·리뷰 입력 지문. manifest 가 없으면(구버전 산출물) 작업 트리 전체 지문으로 호환한다.
# manifest 가 '있는데' 잘못된 경우는 조용히 전체 지문으로 돌아가지 않는다 — 범위 격리가 소리 없이 풀리기 때문에 실패시킨다.
# lock 이 있으면 원본과 같아야 한다 — 이 불변식을 여기 두어 러너 verify·리뷰 루프·승인 재사용·커밋 직전 검사가 전부 같은 조건을 본다
# (lock 만 해시하면 승인 뒤 원본만 바뀌어도 통과해 버린다).
compute_approval_fingerprint() {
  if [ -f "$FEATURE_SCOPE_LOCK" ]; then
    [ -f "$FEATURE_SCOPE_FILE" ] || { echo "[FAIL] feature-scope.json 은 없고 lock 만 존재함" >&2; return 1; }
    cmp -s "$FEATURE_SCOPE_FILE" "$FEATURE_SCOPE_LOCK" || { echo "[SCOPE_MANIFEST_CHANGED] feature-scope.json 과 feature-scope.lock.json 이 다름 — 승인·지문 계산 불가" >&2; return 1; }
    feature_scope_valid_file "$FEATURE_SCOPE_LOCK" || { echo "[FAIL] 유효하지 않은 feature-scope.lock.json" >&2; return 1; }
  fi
  if feature_scope_present; then
    feature_scope_valid_file "$FEATURE_SCOPE_FILE" || { echo "[FAIL] 유효하지 않은 feature-scope.json — version $FEATURE_SCOPE_VERSION, files/new_file_roots 중 하나 이상, canonical 상대 경로" >&2; return 1; }
    compute_feature_fingerprint
  else
    compute_worktree_fingerprint
  fi
}

# 수정자(FIXER_PENDING) 재개용 지문: 승인 지문 + decisions.md. 수정자는 코드를 고치지 않고 decisions.md 에
# REJECT 만 기록하고 죽을 수 있으므로, 작업 트리 지문만으로는 부분 실행을 감지하지 못한다.
# APPROVE 캐시는 계속 compute_approval_fingerprint 만 쓴다 — 이후 문서 기록이 승인을 무효화하면 안 된다.
compute_fixer_resume_fingerprint() {
  {
    compute_approval_fingerprint
    if [ -f "$WORK_DIR/decisions.md" ]; then sha256_stdin < "$WORK_DIR/decisions.md"; else printf 'MISSING\n'; fi
  } | sha256_stdin
}

# ---------- 리뷰가 기준으로 읽는 계약 문서의 내용 지문 (리뷰 루프의 입력 지문과 승인 캐시가 같이 쓴다) ----------
# prompts/reviewer.md 의 기준 문서: request · design · implementation · approach · decisions. 파일별 SHA256(없으면 ABSENT)의 객체를 낸다.
#   (인자 없음)  decisions.md 전체 — 그 리뷰 호출의 정확한 입력(Round 2 는 수정자의 [fix round N] 줄까지 읽는다). 무효 출력의 로컬 재검증용.
#   approval     decisions.md 는 사용자 결정([USER-QUESTION]) 줄만 — 승인 뒤에 쌓이는 판정 기록(ACCEPT/REJECT 이력)이 승인을 깨지 않게 하되,
#                계약(문서 본문·사용자 결정)이 바뀌면 그 APPROVE 는 다른 계약에 대한 승인이다.
#                worktree conventions.md 의 내용 해시(없으면 ABSENT)도 넣는다 — 리뷰어는 [PROJECT CONVENTIONS] 본문과 그 파일을 기준으로 컨벤션 위반을 판정하므로,
#                컨벤션이 바뀌거나 새로 생기거나 없어지면 과거 APPROVE 는 다른 기준에 대한 승인이다(무효 출력용 지문은 conventions_sha256 을 따로 든다 — 두 지문은 분리 유지).
REVIEW_CONTRACT_DOCS="request.md design.md implementation.md approach.md decisions.md"
review_contract_docs_json() { # [approval]
  local mode="${1:-}" docs='{}' d h key
  for d in $REVIEW_CONTRACT_DOCS; do
    h=ABSENT; key="$d"
    if [ "$d" = decisions.md ] && [ "$mode" = approval ]; then
      key="decisions.md#USER-QUESTION"
      if [ -f "$WORK_DIR/$d" ]; then h="$({ grep -E '^[[:space:]]*- \[USER-QUESTION\]' "$WORK_DIR/$d" || true; } | sha256_stdin)" || return 1; fi
    elif [ -f "$WORK_DIR/$d" ]; then
      h="$(sha256_stdin < "$WORK_DIR/$d")" || return 1
    fi
    docs="$(jq -Sc --arg d "$key" --arg h "$h" '. + {($d):$h}' <<< "$docs")" || return 1
  done
  if [ "$mode" = approval ]; then
    h=ABSENT
    if conventions_contract_content >/dev/null; then h="$(conventions_contract_content | sha256_stdin)" || return 1; fi
    docs="$(jq -Sc --arg h "$h" '. + {"conventions.md":$h}' <<< "$docs")" || return 1
  fi
  printf '%s' "$docs"
}
# 승인 체크포인트가 든 계약 문서 지문 == 현재 계약 문서 지문인가. 필드가 없는 옛 체크포인트는 같다고 증명할 수 없으므로 false 다.
review_approval_docs_current() { # checkpoint-file
  local cur; cur="$(review_contract_docs_json approval)" || return 1
  [ "$(jq -Sc '.contract_docs_sha256 // null' "$1" 2>/dev/null)" = "$cur" ]
}

# ---------- 구현 리뷰 fix_ref 계약 (프롬프트·스키마 설명·루프 검사가 같은 문장을 쓴다) ----------
# 이 문장은 prompts/reviewer.md 와 schemas/impl-review.schema.json 의 fix_ref 설명에 글자 그대로 들어 있고(install-smoke 가 대조),
# impl-review-loop.sh 가 Round 2+ 지시문과 진단의 expected 에 그대로 쓴다. 문장을 바꾸면 세 곳을 함께 바꾸고 REVIEWER_CONTRACT_VERSION 을 올린다.
REVIEW_FIX_REF_RULE='fix_ref = 수정자의 직전 라운드 수정으로 실제 변경된 저장소 상대 소스 파일 경로:L시작-L끝 — fix-diff-round-N.patch 같은 패치 파일 경로가 아니고, 줄 번호는 패치 파일의 행 번호가 아니라 수정 후 소스 파일의 행 번호이며, 그 범위는 수정이 바꾼 hunk 와 겹쳐야 한다(변경이 삭제뿐이면 수정 후 파일에서 삭제 지점에 맞닿은 줄을 가리킨다)'
# fix_ref 파싱: "<path>\t<start>\t<end>" 출력. 반환 1 = 형식(^(.+):L([1-9][0-9]*)-L([1-9][0-9]*)$) 위반, 2 = start > end, 3 = 경로가 canonical 상대 경로가 아님
# (feature-scope 와 같은 규칙: 절대 경로·선행 ./ ·후행 / ·빈/"."/".." 세그먼트 금지).
review_fix_ref_parse() { # fix_ref
  local path s e
  [[ "$1" =~ ^(.+):L([1-9][0-9]*)-L([1-9][0-9]*)$ ]] || return 1
  path="${BASH_REMATCH[1]}"; s="${BASH_REMATCH[2]}"; e="${BASH_REMATCH[3]}"
  [ "$s" -le "$e" ] || return 2
  case "$path" in /*|./*|*/) return 3;; esac
  case "/$path/" in *//*|*/./*|*/../*) return 3;; esac
  printf '%s\t%s\t%s' "$path" "$s" "$e"
}
# 두 tree 사이에서 path 의 **새 버전** hunk 범위를 "start end" 줄로 낸다(git tree 양쪽 버전 기준 — .patch 텍스트의 줄 번호가 아니다).
#   추가·수정 hunk(+c,d  d≥1): [c, c+d-1].  삭제뿐인 hunk(+c,0): 삭제 지점에 맞닿은 새 파일의 줄 [max(c,1), c+1] 이 anchor 다.
#   textual hunk 가 없는 변경(binary·mode 만)은 아무것도 내지 않는다 — 호출자(review_fix_ref_violation)가 "hunk 없음" 을 위반으로 다룬다.
review_fix_hunk_ranges() { # prev-tree cur-tree path
  git diff --no-renames -U0 "$1" "$2" -- ":(literal)$3" \
    | sed -nE 's/^@@ -[0-9]+(,[0-9]+)? \+([0-9]+)(,([0-9]+))? @@.*/\2 \4/p' \
    | while read -r c d; do
        d="${d:-1}"
        if [ "$d" -eq 0 ]; then printf '%s %s\n' "$(( c > 0 ? c : 1 ))" "$(( c + 1 ))"; else printf '%s %s\n' "$c" "$(( c + d - 1 ))"; fi
      done
}
# fix_ref 하나를 실제 수정(prev-tree → cur-tree, changed-files-list = 범위 안에서 바뀐 경로 목록 파일)과 대조한다.
# 위반이면 "<observed 설명>" 한 줄을 내고 1, 통과면 출력 없이 0. 증거를 보지 않는 자동 교정은 하지 않는다(fail-closed).
review_fix_ref_violation() { # fix_ref prev-tree cur-tree changed-files-list
  local parsed path s e rc=0 hs he hunks hit=0
  parsed="$(review_fix_ref_parse "$1")" || rc=$?
  case "$rc" in
    1) echo "형식이 '<저장소 상대 경로>:L<시작>-L<끝>' 이 아님"; return 1;;
    2) echo "줄 범위의 시작이 끝보다 큼"; return 1;;
    3) echo "경로가 canonical 저장소 상대 경로가 아님(절대 경로·'./'·'..'·빈 세그먼트 금지)"; return 1;;
  esac
  IFS=$'\t' read -r path s e <<< "$parsed"
  if ! grep -qxF -- "$path" "$4"; then
    case "$path" in
      *.patch|*.diff|"$WORK_DIR"/*) echo "경로가 패치·파이프라인 산출물 파일임 — 직전 수정으로 바뀐 소스 파일이 아님";;
      *) echo "경로가 직전 수정(prev tree → 현재 tree)으로 바뀐 파일 목록에 없음";;
    esac
    return 1
  fi
  hunks="$(review_fix_hunk_ranges "$2" "$3" "$path")"
  if [ -z "$hunks" ]; then
    # binary·파일 mode 만 바뀐 변경: 줄 단위 hunk 가 없다. "범위는 수정이 바꾼 hunk 와 겹쳐야 한다" 를 만족하는 줄 범위가 존재하지 않으므로
    # 변경 파일 일치만으로 임의의 줄 번호(L999999 등)를 통과시키지 않는다(fail-closed).
    echo "'$path' 의 직전 수정에는 줄 단위 hunk 가 없음(binary 또는 파일 mode 만 변경) — 겹칠 hunk 가 없어 어떤 줄 범위도 이 파일의 fix_ref 가 될 수 없다"
    return 1
  fi
  while read -r hs he; do
    if [ "$s" -le "$he" ] && [ "$e" -ge "$hs" ]; then hit=1; break; fi
  done <<< "$hunks"
  [ "$hit" -eq 1 ] && return 0
  echo "줄 범위 L$s-L$e 가 수정 후 '$path' 의 변경 hunk($(printf '%s' "$hunks" | awk '{printf "%sL%s-L%s", (NR>1?", ":""), $1, $2}'))와 겹치지 않음"
  return 1
}

# 현재 작업 트리에 대해 유효한 구현 승인이 있는가: review-impl.json 이 APPROVE 이고 포맷·계약 버전이 맞고,
# 작업 트리 지문이 같고, 리뷰 경로가 attempt/round 와 일치하며 실제 APPROVE 리뷰이고, approved.fingerprint 도 같은 값이어야 한다.
# 러너가 verify stage 로 바로 들어가기 전에 쓴다 — approved.fingerprint 파일 존재만으로 리뷰 루프의 검사를 우회하지 않게.
# 그 APPROVE 를 통과시킨 검사기 버전(checker_version)도 현재와 같아야 한다 — 다르면(검사기만 고친 경우 포함) 여기서는 무효로 보고 review stage 로 보낸다.
# 리뷰 루프가 저장된 승인 출력을 현재 검사기로 로컬 재검증(모델 0회)해 통과하면 체크포인트의 checker_version 을 갱신하고, 무효면 새 attempt 로 리뷰한다.
# 승인 당시 리뷰어가 읽은 계약 문서(contract_docs_sha256 — request/design/implementation/approach 본문 + decisions.md 의 사용자 결정 줄 + conventions.md 내용)도 현재와 같아야 한다 —
# 코드(작업 트리 지문)가 그대로여도 계약이 바뀌었으면(재합의 포함) 그 APPROVE 는 다른 계약에 대한 승인이다. 다르면 무효 → 리뷰 루프가 새 attempt 로 리뷰한다.
impl_approval_current() {
  local checkpoint="$WORK_DIR/review-impl.json" fp review attempt round
  [ -f "$checkpoint" ] && [ -f "$WORK_DIR/approved.fingerprint" ] || return 1
  jq -e --argjson v "$REVIEWER_CONTRACT_VERSION" --argjson cv "$REVIEW_CHECKPOINT_VERSION" --argjson kv "$REVIEW_CHECKER_VERSION" \
    '.version==$cv and .contract_version==$v and .checker_version==$kv and .next_step=="APPROVE"' "$checkpoint" >/dev/null 2>&1 || return 1
  fp="$(jq -r '.worktree_fingerprint // ""' "$checkpoint")"
  [ -n "$fp" ] && [ "$fp" = "$(cat "$WORK_DIR/approved.fingerprint")" ] && [ "$fp" = "$(compute_approval_fingerprint)" ] || return 1
  review_approval_docs_current "$checkpoint" || return 1
  review="$(jq -r '.review // ""' "$checkpoint")"
  attempt="$(jq -r '.attempt // 0' "$checkpoint")"; round="$(jq -r '.round // 0' "$checkpoint")"
  [ "$review" = "$WORK_DIR/reviews/impl-attempt-$(printf '%02d' "$attempt")/reviewer-round-$(printf '%02d' "$round").json" ] || return 1
  valid_impl_approve_review "$review"
}

# 마지막 APPROVE 시점 지문과 현재 작업 트리를 비교. 다르면 승인 무효(APPROVAL_STALE).
# Phase 4 진입 직전과 커밋 위임 직전, 두 지점에서 반드시 호출한다.
verify_approved_fingerprint() {
  local fingerprint_file="$WORK_DIR/approved.fingerprint"
  [ -f "$fingerprint_file" ] || { echo "[FAIL] 승인 지문 없음: $fingerprint_file — Phase 3 승인이 선행돼야 함." >&2; return 1; }
  local approved_hash current_hash
  approved_hash="$(cat "$fingerprint_file")"
  current_hash="$(compute_approval_fingerprint)"
  if [ "$approved_hash" != "$current_hash" ]; then
    echo "[APPROVAL_STALE] 마지막 APPROVE 이후 코드가 변경됨. Phase 3 재리뷰 없이는 진행 금지." >&2
    return 1
  fi
  echo "승인 지문 일치 — 마지막 APPROVE 이후 변경 없음."
}
