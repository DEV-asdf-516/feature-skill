#!/usr/bin/env bash
# =============================================================
# .claude/skills/feature/scripts/lib/state/doc-gap.sh
# 구현 후 DOC_GAP 재개 체크포인트.
# scripts/lib/bootstrap.sh 가 정해진 순서로 source 한다 — 직접 실행하지 않는다.
# (분리 전 config.sh 기준 2052–2583)
# =============================================================

# =============================================================
# 구현 후 DOC_GAP 재개 체크포인트 — $WORK_DIR/doc-gap-resume.json
#   impl consensus 는 최초 워커 진입 전의 사전 게이트다. 그 뒤 워커(unit)·리뷰어·review-gap 워커가 발견한 DOC_GAP/USER_DECISION 은
#   impl 재합의로 돌아가지 않고 사용자에게 직접 간다: NEED_USER → 사용자가 decisions.md + approach.md 에 결정 기록 → 검증자·디자이너 없이 워커 → 리뷰.
#   사용자 결정이 그 gap 의 최종 결정이며 validator PASS 와는 다른 provenance 다 — consensus-impl.json 을 위조하거나 PASS 지문을 덮어쓰지 않는다.
#   대신 이 파일이 "이미 PASS 한 impl 문서(base_consensus_review) + 사용자가 답한 gap + 동기화된 approach" 의 지문(resolved_impl_fingerprint)을 들고,
#   러너는 consensus_pass_current impl 이 stale 이어도 그 지문이 현재 입력과 같으면 impl 단계로 되돌리지 않는다(impl_docs_accepted).
#   next_step: WAITING_USER(사용자 답 전 — 모델 호출 0회) → WORKER_PENDING(답·동기화·source tree 확인 + 리뷰 gap 이면 완료 unit 사전 검사 통과) → REVIEW_PENDING(review-gap 워커 완료) → RESOLVED.
#   gaps[].paths 는 그 gap 의 구조화된 파일 경로(워커 undecided 의 paths / 리뷰 issue 의 code_refs), gaps[].location 은 표시용 원문이다. unit 연결 판정은 paths 만 쓴다(doc_gap_links).
#     paths 는 덧붙인 필드라 포맷 버전은 그대로다 — paths 가 없는 옛 기록은 doc_gap_links 의 제한된 legacy 해석으로 읽는다.
#   gaps[].tag 는 decisions.md 의 답 줄이 달아야 하는 태그다: `- [USER-QUESTION][scope=impl][<tag>] <질문> → <답>`
#     리뷰어 issue  → review-issue=<issue id>          워커 undecided → worker-gap=<unit id | review-gap>#<n>
#     기록 시점에 그 tag 가 이미 쓰였으면 "@2", "@3" … 이 붙는다(_doc_gap_unique_tags) — 다른 리뷰의 같은 issue id·다시 1 부터인 워커 번호가 앞 gap 과 섞이지 않는다.
#   prior_gaps[] 는 이 체크포인트 이전에 해결된 gap 의 기록이다(원본 origin/review/review_sha256/attempt/round/unit_id, key·tag·질문·위치, 사용자 답 줄, 그 해결의 입력 지문).
#     해결 사슬이 유효한 동안(doc_gap_resolved_current) 새 gap 기록이 앞 기록을 이어 붙인다. 필드는 덧붙이기만 했으므로 포맷 버전은 그대로다(없는 필드는 빈 값으로 읽는다).
#   review_sha256 은 기록 시점 리뷰 JSON 의 내용 해시, worker_run 은 review-gap 워커 실행 기록이다(아래 doc_gap_worker_identity).
#   기존 [USER-QUESTION][scope=impl] 의미는 그대로다(impl 지문에 들어가고 design PASS 를 깨지 않는다). 태그가 붙은 줄만 pending gap 의 답으로 인정한다.
# =============================================================
DOC_GAP_RESUME="$WORK_DIR/doc-gap-resume.json"
DOC_GAP_RESUME_VERSION=1
_doc_gap_docs_hash() { _fingerprint_files "$WORK_DIR/implementation.md" "$WORK_DIR/approach.md" "$WORK_DIR/decisions.md" | sha256_stdin; }
_doc_gap_approach_hash() { if [ -f "$WORK_DIR/approach.md" ]; then sha256_stdin < "$WORK_DIR/approach.md"; else printf 'MISSING'; fi; }
# 해결 과정에서 바뀌어도 되는 것은 approach.md 와 decisions.md 의 **추가** 뿐이다. 그 밖의 impl 입력(implementation.md·implementation-units.json·feature-scope.json)은
# gap 기록 시점 그대로여야 한다 — 바뀌었으면 gap 해결이 아니라 새 구현 제안이므로 사용자 해결 경로로 우회할 수 없다(impl 재합의).
_doc_gap_frozen_hash() { _fingerprint_files "$WORK_DIR/implementation.md" "$WORK_DIR/implementation-units.json" "$WORK_DIR/feature-scope.json" | sha256_stdin; }
_doc_gap_decisions_lines() { if [ -f "$WORK_DIR/decisions.md" ]; then wc -l < "$WORK_DIR/decisions.md" | tr -d ' '; else echo 0; fi; }
_doc_gap_decisions_prefix_hash() { # n → decisions.md 앞 n 줄의 해시
  # n=0(gap 기록 시점에 decisions.md 가 비어 있음)은 빈 prefix 다 — BSD head 는 -n 0 을 오류로 거부하므로 따로 다룬다(해시는 빈 입력의 것으로 같다)
  if [ ! -f "$WORK_DIR/decisions.md" ]; then printf 'MISSING'; elif [ "$1" -eq 0 ]; then printf '' | sha256_stdin; else head -n "$1" "$WORK_DIR/decisions.md" | sha256_stdin; fi
}
# 해결 범위 검사: frozen 문서 불변 + decisions.md 는 기록 시점 내용을 prefix 로 유지(append-only). 0 = OK, 1 = 범위 밖 변경.
doc_gap_resolution_scope_ok() {
  [ "$(_doc_gap_frozen_hash)" = "$(doc_gap_field '.frozen_docs_hash')" ] || return 1
  local n; n="$(doc_gap_field '.decisions_lines')"
  [ "$(_doc_gap_decisions_lines)" -ge "$n" ] && [ "$(_doc_gap_decisions_prefix_hash "$n")" = "$(doc_gap_field '.decisions_prefix_hash')" ]
}
# tag 유일화: 리뷰어 issue id(R-01 …)는 리뷰마다, 워커 미결정 번호(#1 …)는 호출마다 다시 1 부터라 서로 다른 gap 이 같은 tag 를 가질 수 있다.
#   그러면 앞 gap 의 답 줄이 새 gap 의 답으로 읽히고(사용자에게 묻지 않고 진행), 앞 gap 의 approach 절 표시가 새 gap 의 해결로 인정된다.
#   기록 시점에 그 tag 가 이미 쓰였으면(decisions.md·approach.md 에 "[tag]" 가 있거나 앞선 해결 기록·같은 묶음의 앞 항목이 같은 tag) "@2", "@3" … 을 붙인다.
#   key(리뷰어 issue id / <unit|review-gap>#<n>)는 그대로다 — 사용자가 적을 tag 는 항상 체크포인트·중단 사유에 표기된 값이다.
_doc_gap_tag_taken() { # tag taken-json
  jq -e --arg t "$1" 'index($t) != null' <<< "$2" >/dev/null 2>&1 && return 0
  # 파이프를 쓰지 않는다: 러너는 pipefail 이라 `cat … | grep -q` 는 grep 이 첫 일치에서 끝날 때 cat 이 SIGPIPE(141)로 죽어 '쓰이지 않음'으로 뒤집힌다(큰 문서에서 tag 중복).
  local f
  for f in "$WORK_DIR/decisions.md" "$WORK_DIR/approach.md"; do
    [ -f "$f" ] || continue
    if grep -qF -- "[$1]" "$f"; then return 0; fi
  done
  return 1
}
_doc_gap_unique_tags() { # gaps-json prior-json → gaps-json
  local gaps="$1" taken n i=0 tag cand k
  taken="$(jq -c '[.[].tag]' <<< "$2")" || return 1
  n="$(jq 'length' <<< "$gaps")" || return 1
  while [ "$i" -lt "$n" ]; do
    tag="$(jq -r --argjson i "$i" '.[$i].tag' <<< "$gaps")" || return 1
    cand="$tag"; k=1
    while _doc_gap_tag_taken "$cand" "$taken"; do k=$((k + 1)); cand="$tag@$k"; done
    gaps="$(jq -c --argjson i "$i" --arg t "$cand" '.[$i].tag=$t' <<< "$gaps")" || return 1
    taken="$(jq -c --arg t "$cand" '. + [$t]' <<< "$taken")" || return 1
    i=$((i + 1))
  done
  printf '%s' "$gaps"
}
# 지금 체크포인트(해결된 상태로 유효함을 호출자가 확인)의 gap 을 해결 기록으로 바꿔 기존 prior_gaps 뒤에 붙인다 → JSON 배열.
#   항목마다 원본(origin·review 경로·review 내용 해시·attempt·round·unit_id·워커 결과 경로), 이슈 ID(key·tag), 질문·선택지·근거·코드 위치(location 원문 + 구조화된 paths),
#   사용자 결정(그 시점 decisions.md 의 답 줄 원문), 그 해결을 고정한 impl 입력 지문을 함께 든다 — 여러 번의 미결정이 이어져도 앞 기록을 덮지 않는다.
_doc_gap_carry_prior() {
  local answers='{}' tag rsha
  while IFS= read -r tag; do
    answers="$(jq -c --arg t "$tag" --arg a "$(doc_gap_answer_line "$tag")" '. + {($t):$a}' <<< "$answers")" || return 1
  done < <(doc_gap_field '.gaps[].tag')
  # review_sha256 은 gap 기록 시점에 고정된 값만 넘긴다. 해시가 없던 옛 체크포인트의 리뷰를 지금 내용으로 해시하지 않는다 —
  # 사후에 만든 해시는 리뷰 발생 시점의 내용을 증명하지 못하므로, 그 기록은 검증 근거 없는 상태로 남아 doc_gap_prior_valid_tags 가 인정하지 않는다.
  rsha="$(doc_gap_field '.review_sha256 // ""')"
  jq -c --argjson ans "$answers" --arg rsha "$rsha" '
    . as $c | [(.prior_gaps // [])[], (.gaps[] | ({key, tag, question, options, refs, location, impact,
      origin:$c.origin, review:$c.review, review_sha256:$rsha, attempt:$c.attempt, round:$c.round, unit_id:$c.unit_id, result:$c.result,
      answer:($ans[.tag] // ""), resolved_impl_fingerprint:$c.resolved_impl_fingerprint, resolved_at:$c.updated_at}
      + (if (.paths|type)=="array" then {paths} else {} end)))]' "$DOC_GAP_RESUME"   # paths 는 기록에 있을 때만 넘긴다 — 없던 기록에 사후로 만들어 넣지 않는다
}
# 앞선 해결(prior_gaps) 가운데 지금도 연결이 확인되는 것의 tag → JSON 배열. 하나라도 어긋난 항목은 조용히 빠진다(그 해결로는 계약 변경을 덮지 않는다 — fail closed).
#   · unit 워커 gap(unit_id 있음)이 아니다(그 unit 은 다시 돌았다 — 해결 예외의 근거가 아니라 이력이다)
#   · 사용자 결정: 기록된 답 줄 원문(answer)이 있고, 그 tag 의 답 줄이 지금도 decisions.md 에 그 원문 그대로 있다
#   · 원본 리뷰(리뷰 DOC_GAP): 기록된 내용 해시(review_sha256)가 있고, 기록된 경로의 리뷰 JSON 이 그 내용 그대로이며 그 리뷰에 그 이슈 ID 의 DOC_GAP 이 있다
#   검증 근거(answer·review_sha256)가 없는 기록은 인정하지 않는다 — 확인할 수 없는 이력이 계약 변경을 정당화하지 않는다. origin 이 review/worker 가 아닌 기록도 같다.
doc_gap_prior_valid_tags() {
  local out='[]' row tag cur answer review rsha
  [ -f "$DOC_GAP_RESUME" ] || { printf '[]'; return 0; }
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    [ -z "$(jq -r '.unit_id // ""' <<< "$row")" ] || continue
    tag="$(jq -r '.tag // ""' <<< "$row")"; [ -n "$tag" ] || continue
    cur="$(doc_gap_answer_line "$tag")"; [ -n "$cur" ] || continue
    answer="$(jq -r '.answer // ""' <<< "$row")"; [ -n "$answer" ] && [ "$answer" = "$cur" ] || continue
    review="$(jq -r '.review // ""' <<< "$row")"; rsha="$(jq -r '.review_sha256 // ""' <<< "$row")"
    case "$(jq -r '.origin // ""' <<< "$row")" in
      review)
        [ -n "$rsha" ] && [ -f "$review" ] && [ "$(sha256_stdin < "$review")" = "$rsha" ] || continue
        jq -e --arg k "$(jq -r '.key // ""' <<< "$row")" 'any(.issues[]?; .id==$k and .action=="DOC_GAP")' "$review" >/dev/null 2>&1 || continue;;
      worker) ;;   # verify 의 worker-fix·review-gap 워커 미결정: 원본은 리뷰가 아니다 — 사용자 결정 원문 일치가 근거다
      *) continue;;
    esac
    out="$(jq -c --arg t "$tag" '. + [$t]' <<< "$out")" || return 1
  done < <(jq -c '(.prior_gaps // [])[]' "$DOC_GAP_RESUME" 2>/dev/null)
  printf '%s' "$out"
}
_doc_gap_write() { # gaps-json origin review attempt round unit_id result source_tree
  # 전제: 지금 impl 문서가 승인된 상태(최초 validator PASS 유효 또는 직전 gap 의 사용자 해결 지문 유효)여야 gap 을 기록할 수 있다 —
  # 승인되지 않은 문서 위의 gap 은 존재할 수 없고, 이 전제가 provenance 체인(PASS → 해결 → 해결 …)의 귀납 조건이다.
  impl_docs_accepted || { echo "[FAIL] doc-gap 기록 거부 — impl 문서가 승인된 상태가 아님(consensus-impl.json PASS 도 사용자 해결 지문도 현재 입력에 유효하지 않음)" >&2; return 1; }
  # 밑바탕 종류: 검증자 PASS(consensus-impl.json) 또는 합의 단계 사용자 수리(user-escalation-resume-impl.json, USER_RESOLVED). 둘은 다른 provenance 라 섞지 않는다 —
  # impl 이 사용자 수리로 워커에 들어왔으면 consensus-impl.json 은 PASS 가 아니므로(위조하지 않는다) 수리 체크포인트의 리뷰·수리 지문을 밑바탕으로 든다.
  local base_review="" base_round=0 base_fp="" base_kind=PASS
  if [ "$(user_escalation_step impl)" = USER_RESOLVED ] && ! jq -e '.next_step=="PASS"' "$WORK_DIR/consensus-impl.json" >/dev/null 2>&1; then
    base_kind=USER_RESOLVED
    base_review="$(user_escalation_field impl '.review')"; base_round="$(user_escalation_field impl '.round')"
    base_fp="$(user_escalation_field impl '.resolved_input_fingerprint')"
  elif [ -f "$WORK_DIR/consensus-impl.json" ]; then
    base_review="$(jq -r '.review // ""' "$WORK_DIR/consensus-impl.json")"; base_round="$(jq -r '.round // 0' "$WORK_DIR/consensus-impl.json")"
    base_fp="$(jq -r '.input_fingerprint // ""' "$WORK_DIR/consensus-impl.json")"
  fi
  # 지금 체크포인트가 해결된 상태로 유효하면(해결 사슬이 이어진다) 그 gap 들을 prior_gaps 로 넘긴다 — 새 gap 이 앞 해결 기록을 덮어쓰지 않는다.
  # 유효하지 않은 체크포인트(SUPERSEDED·지문 불일치)의 gap 은 넘기지 않는다: 그 위의 문서는 정상 재합의로 다시 확정됐다.
  local prior='[]' gaps review_sha=""
  if doc_gap_resolved_current; then prior="$(_doc_gap_carry_prior)" || return 1; fi
  gaps="$(_doc_gap_unique_tags "$1" "$prior")" || return 1
  if [ -n "$3" ] && [ -f "$3" ]; then review_sha="$(sha256_stdin < "$3")" || return 1; fi
  local n; n="$(_doc_gap_decisions_lines)"
  jq -n --argjson v "$DOC_GAP_RESUME_VERSION" --argjson gaps "$gaps" --argjson prior "$prior" --arg review_sha "$review_sha" --arg origin "$2" --arg review "$3" --arg attempt "${4:-0}" --arg round "${5:-0}" \
    --arg unit "$6" --arg result "$7" --arg tree "$8" --arg docs "$(_doc_gap_docs_hash)" --arg approach "$(_doc_gap_approach_hash)" \
    --arg base "$base_review" --arg base_round "$base_round" --arg base_fp "$base_fp" --arg base_kind "$base_kind" --arg gap_fp "$(consensus_pass_fingerprint impl)" \
    --arg frozen "$(_doc_gap_frozen_hash)" --arg dl "$n" --arg dh "$(_doc_gap_decisions_prefix_hash "$n")" --arg now "$(date '+%FT%T%z')" \
    '{version:$v, origin:$origin, next_step:"WAITING_USER", review:$review, review_sha256:$review_sha, attempt:($attempt|tonumber), round:($round|tonumber), unit_id:$unit, result:$result,
      gaps:$gaps, prior_gaps:$prior, source_tree:$tree, docs_fingerprint:$docs, approach_hash:$approach,
      base_kind:$base_kind, base_consensus_review:$base, base_consensus_round:($base_round|tonumber), base_pass_fingerprint:$base_fp, gap_impl_fingerprint:$gap_fp,
      frozen_docs_hash:$frozen, decisions_lines:($dl|tonumber), decisions_prefix_hash:$dh,
      resolved_impl_fingerprint:"", recorded_at:$now, updated_at:$now}' > "$DOC_GAP_RESUME.tmp" && mv "$DOC_GAP_RESUME.tmp" "$DOC_GAP_RESUME"
}
# 리뷰어 DOC_GAP issue → 체크포인트(WAITING_USER). 리뷰 루프가 수정자 호출 전에 부른다(같은 리뷰의 FIX_CODE 는 review-gap 워커가 함께 처리).
doc_gap_record_review() { # review attempt round source_tree
  local gaps
  # paths: code_refs 를 code_ref_path 로 바꾼 저장소 상대 파일 경로(공용 규칙 — 워커 undecided 의 paths 와 같은 검사).
  # 리뷰 루프는 validate_review_output(DOC_GAP_CODE_REF_PATH)을 통과한 리뷰만 넘기므로 여기서 빠지는 ref 는 없다 — 아래 select 는 그 검사를 거치지 않은 호출에 대한 방어일 뿐이고,
  # 하나도 정규 경로가 아니면 paths 를 넣지 않는다(빈 배열로 '연결 없음'을 확정하지 않는다).
  gaps="$(jq -c "$JQ_PATH_DEFS"'[.issues[] | select(.action=="DOC_GAP") | {key:.id, tag:("review-issue=" + .id), question:.user_question, options:.options,
    refs:(.basis_refs + .code_refs), impact:.impact, location:(.code_refs|join(", ")),
    paths:([.code_refs[] | code_ref_path | select(plain_file_path)] | unique)} | if (.paths|length) == 0 then del(.paths) else . end]' "$1")"
  _doc_gap_write "$gaps" review "$1" "$2" "$3" "" "" "$4"
}
# 워커 undecided(DOC_GAP·USER_DECISION 모두 — 구현 시점의 solution-shape 선택은 둘 다 사용자 판단) → 체크포인트(WAITING_USER).
# unit 호출이면 unit_id, review-gap 워커면 review 경로를 남겨 재개 시 같은 워커를 다시 부른다. key 는 <unit|review-gap>#<n>(스키마에 id 없음).
# 호출자(run_worker)가 worker_result_valid + worker_undecided_path_violations 로 paths 계약을 확인한 결과만 넘긴다.
doc_gap_record_worker() { # result unit_id review source_tree
  local gaps prefix="${2:-review-gap}"
  gaps="$(jq -c --arg p "$prefix" '[.undecided | to_entries[] | ($p + "#" + ((.key + 1)|tostring)) as $k
    | {key:$k, tag:("worker-gap=" + $k), question:.value.decision_needed, options:.value.options, refs:[.value.location], impact:.value.kind,
       location:.value.location, paths:.value.paths}]' "$1")"   # location = 워커가 적은 원문(표시용), paths = 구조화된 경로(연결 판정용)
  _doc_gap_write "$gaps" worker "$3" 0 0 "$2" "$1" "$4"
}
# ---------- gap ↔ 파일 경로 (unit 연결 판정의 유일한 입력) ----------
# 후보 gap(① 현재 체크포인트의 gap — 리뷰 DOC_GAP 이거나 unit_id 가 없는 워커 미결정일 때만 ② 지금도 연결이 확인되는 prior_gaps)마다 경로를 해석한다 → JSON 배열
#   [{tag, key, prior, structured, location, paths:[저장소 상대 경로], unresolved:[{token, candidates:[…]}]}]
# · paths 가 있는 기록(신규): 그 배열만 쓴다. location/refs 는 읽지 않는다(legacy 파서를 실행하지 않는다).
# · paths 가 없는 옛 기록: **코드 위치만** 결정론적으로 해석한다(이 수정 이전에 기록된 체크포인트·prior_gaps 를 무효화하지 않기 위한 제한된 호환 경로).
#     리뷰 gap 은 원본 리뷰가 기록 당시 내용(review_sha256)으로 확인되면 그 issue 의 code_refs 배열을 쓰고(_doc_gap_legacy_code_refs), 확인되지 않으면 location 을 해석한다.
#     refs 는 읽지 않는다 — 리뷰 gap 의 refs 는 basis_refs + code_refs 라서 계약 **근거** 파일(basis)이 gap 의 코드 위치로 섞이면 무관한 unit 까지 연결된다.
#     끝의 " (설명)" 을 떼고 → " / " 와 ", " 로 파일을 나누고 → 각 조각 끝의 줄 범위(":L1-L2", ":L1-L2,L5-L9")만 뗀다. 경로 안의 ":" 를 첫 위치에서 자르지 않는다.
#     "/" 가 있는 조각은 그 경로 그대로다. basename 뿐인 조각은 **잠긴 feature-scope·units manifest 가 명시한 파일 경로 전체**(+ 저장소 루트의 같은 이름 파일)에서
#     정확히 하나와 맞을 때만 그 경로로 본다 — unit 마다 따로 맞춰 서로 다른 파일에 중복 연결하지 않고, 저장소를 검색해 추측하지도 않는다.
#     코드 위치의 조각이 0개·2개 이상과 맞으면 unresolved 로 남긴다(호출자가 DOC_GAP_LOCATION_UNRESOLVED 로 구분).
_doc_gap_path_universe() { # 잠긴 scope·manifest 가 명시한 파일 경로 전체(JSON 배열, 중복 제거)
  local fs um a='[]' b='[]'
  fs="$(feature_scope_file)"; um="$(units_manifest_file)"
  if [ -f "$fs" ]; then a="$(jq -c '[.files[]? | select(type=="string")]' "$fs" 2>/dev/null)" || a='[]'; fi
  if [ -f "$um" ]; then b="$(jq -c '[.units[]?.scope.files[]? | select(type=="string")]' "$um" 2>/dev/null)" || b='[]'; fi
  jq -nc --argjson a "${a:-[]}" --argjson b "${b:-[]}" '$a + $b | unique'
}
_doc_gap_root_files() { # 저장소 루트의 파일 이름(JSON 배열) — "/" 없는 조각이 루트 파일 자체일 수 있다
  local f
  { for f in "$PROJECT_ROOT"/* "$PROJECT_ROOT"/.[!.]*; do if [ -f "$f" ]; then printf '%s\n' "${f##*/}"; fi; done; } | jq -Rsc 'split("\n") | map(select(length > 0))'
}
# paths 없는 옛 리뷰 gap(현재 gap·prior_gaps) 가운데 원본 리뷰 JSON 이 기록 당시 내용 그대로인 것의 code_refs → {"<tag>":[code_refs…]}.
# 해시가 없거나 리뷰 파일이 달라졌거나 그 id 의 DOC_GAP 이 없으면 항목을 내지 않는다(호출자는 location 해석으로 돌아간다 — 지금 내용으로 사후 추정하지 않는다).
_doc_gap_legacy_code_refs() {
  local out='{}' row review rsha refs
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    review="$(jq -r '.review // ""' <<< "$row")"; rsha="$(jq -r '.sha // ""' <<< "$row")"
    [ -n "$rsha" ] && [ -f "$review" ] && [ "$(sha256_stdin < "$review")" = "$rsha" ] || continue
    refs="$(jq -c --arg k "$(jq -r '.key' <<< "$row")" '[.issues[]? | select(.id==$k and .action=="DOC_GAP") | .code_refs[]? | select(type=="string")]' "$review" 2>/dev/null)" || continue
    [ -n "$refs" ] && [ "$refs" != "[]" ] || continue
    out="$(jq -c --arg t "$(jq -r '.tag' <<< "$row")" --argjson r "$refs" '. + {($t):$r}' <<< "$out")" || return 1
  done < <(jq -c '. as $c
    | ((if .origin == "review" then [.gaps[] | {tag, key, review:($c.review // ""), sha:($c.review_sha256 // ""), paths}] else [] end)
       + [(.prior_gaps // [])[] | select(.origin == "review") | {tag, key, review:(.review // ""), sha:(.review_sha256 // ""), paths}])[]
    | select(((.paths | type) == "array" and (.paths | length) > 0) | not) | select((.tag | type) == "string" and (.key | type) == "string")' "$DOC_GAP_RESUME" 2>/dev/null)
  printf '%s' "$out"
}
doc_gap_links() {
  local prior universe roots code_refs
  code_refs="$(_doc_gap_legacy_code_refs)" || return 1
  prior="$(doc_gap_prior_valid_tags)" || return 1
  universe="$(_doc_gap_path_universe)" || return 1
  roots="$(_doc_gap_root_files)" || return 1
  jq -c --argjson pv "$prior" --argjson U "$universe" --argjson RF "$roots" --argjson CR "$code_refs" "$JQ_PATH_DEFS"'
    def legacy_tokens: sub("\\s+\\([^()]*\\)\\s*$"; "")
      | [ splits("\\s+/\\s+") | splits(",\\s+") | gsub("^\\s+|\\s+$"; "")
          | select(length > 0 and (test("^L?[0-9]+(-L?[0-9]+)?$") | not)) | strip_line_ranges | select(length > 0) ];
    def resolve: . as $t
      | if ($t | canonical_path | not) then {token:$t, candidates:[]}
        elif ($t | contains("/")) or (($U | index($t)) != null) then {path:$t}
        else ([($U[] | select((split("/") | last) == $t)), ($RF[] | select(. == $t))] | unique) as $c
          | if ($c | length) == 1 then {path:$c[0]} else {token:$t, candidates:$c} end
        end;
    def link($prior):
      if (.paths | type) == "array" and (.paths | length) > 0 then
        {tag, key:(.key // ""), prior:$prior, structured:true, location:(.location // ""), paths:([.paths[] | select(plain_file_path)] | unique), unresolved:[]}
      else ((.location // "") | if type == "string" then . else "" end) as $raw
        | ($CR[.tag // ""] // []) as $cr
        | (if ($cr | length) > 0 then [$cr[] | code_ref_path | select(length > 0) | resolve]   # 검증된 원본 리뷰의 code_refs(배열 그대로 — 문자열을 다시 쪼개지 않는다)
           else [$raw | select(length > 0) | legacy_tokens[] | resolve] end) as $hard
        | {tag, key:(.key // ""), prior:$prior, structured:false, location:$raw,
           paths:([$hard[] | .path // empty] | unique),
           unresolved:(if ($raw | length) > 0 and ($hard | length) == 0 then [{token:$raw, candidates:[]}] else [$hard[] | select(has("path") | not)] end)}
      end;
    [ ((if .origin == "review" or (.unit_id // "") == "" then .gaps else [] end)[] | link(false)),
      ((.prior_gaps // [])[] | select(.tag as $t | $pv | index($t) != null) | link(true)) ]' "$DOC_GAP_RESUME"
}
doc_gap_field() { jq -r "$1" "$DOC_GAP_RESUME"; }
doc_gap_next_step() { [ -f "$DOC_GAP_RESUME" ] && jq -r --argjson v "$DOC_GAP_RESUME_VERSION" 'if .version==$v then .next_step else "" end' "$DOC_GAP_RESUME" || printf ''; }
doc_gap_pending() { case "$(doc_gap_next_step)" in WAITING_USER|WORKER_PENDING|REVIEW_PENDING) return 0;; *) return 1;; esac; }
doc_gap_set_step() { # next_step [source_tree]
  jq --arg s "$1" --arg t "${2:-}" --arg now "$(date '+%FT%T%z')" '.next_step=$s | (if $t != "" then .source_tree=$t else . end) | .updated_at=$now' \
    "$DOC_GAP_RESUME" > "$DOC_GAP_RESUME.tmp" && mv "$DOC_GAP_RESUME.tmp" "$DOC_GAP_RESUME"
}
# 상위 계약이 정상 재합의로 다시 확정되면(새 impl PASS / 새 사용자 수리) 그 전 문서 위에서 기록된 pending gap 은 더 이상 재개 대상이 아니다.
# 지우지 않고 SUPERSEDED 로 남긴다(근거 보존) — doc_gap_pending·doc_gap_resolved_current 모두 false 가 되고, 그 unit 은 변경 계약(CHANGED CONTRACT)으로 다시 돈다.
doc_gap_supersede() { # why
  jq --arg why "$1" --arg now "$(date '+%FT%T%z')" '.superseded_from=.next_step | .next_step="SUPERSEDED" | .superseded_reason=$why | .updated_at=$now' \
    "$DOC_GAP_RESUME" > "$DOC_GAP_RESUME.tmp" && mv "$DOC_GAP_RESUME.tmp" "$DOC_GAP_RESUME"
}
_doc_gap_tag_regex() { printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g'; }
# tag 의 답 줄(scope=impl + tag + 비어 있지 않은 답). 빈 답은 답이 아니다.
doc_gap_answer_line() { # tag
  grep -E "^[[:space:]]*- \[USER-QUESTION\]\[scope=impl\]\[$(_doc_gap_tag_regex "$1")\] .*→[[:space:]]*[^[:space:]]" "$WORK_DIR/decisions.md" 2>/dev/null | tail -1
}
doc_gap_unanswered() { # → 답 없는 gap 의 tag, 한 줄 하나
  local tag
  while IFS= read -r tag; do [ -n "$(doc_gap_answer_line "$tag")" ] || printf '%s\n' "$tag"; done < <(doc_gap_field '.gaps[].tag')
}
doc_gap_approach_synced() { [ "$(_doc_gap_approach_hash)" != "$(doc_gap_field '.approach_hash')" ]; }
doc_gap_source_unchanged() { [ "$(snapshot_worktree_tree)" = "$(doc_gap_field '.source_tree')" ]; }
# 체크포인트의 밑바탕이 실제 impl consensus PASS 인가: base_consensus_review 가 지금 consensus-impl.json(포맷·계약 버전·target·PASS)이 가리키는
# 그 round 의 리뷰이고, 그 PASS 의 입력 지문(base_pass_fingerprint)이 체크포인트에 그대로이며, 리뷰 파일이 현재 계약의 실제 PASS 다.
# 밑바탕이 합의 단계 사용자 수리(base_kind=USER_RESOLVED)면 PASS 대신 그 수리 체크포인트가 온전하고(계약 버전·리뷰 내용 해시·답 수), 기록된 리뷰·수리 지문이 그대로여야 한다.
# base_kind 가 없는 옛 체크포인트는 PASS 밑바탕으로 본다.
doc_gap_base_consensus_valid() {
  local ck="$WORK_DIR/consensus-impl.json"
  if [ "$(doc_gap_field '.base_kind // "PASS"')" = USER_RESOLVED ]; then
    user_escalation_intact impl || return 1
    [ "$(user_escalation_field impl '.review')" = "$(doc_gap_field '.base_consensus_review')" ] || return 1
    [ -n "$(doc_gap_field '.base_pass_fingerprint')" ] && [ "$(user_escalation_field impl '.resolved_input_fingerprint')" = "$(doc_gap_field '.base_pass_fingerprint')" ]
    return
  fi
  [ -f "$ck" ] || return 1
  jq -e --argjson v "$VALIDATOR_CONTRACT_VERSION" --argjson cv "$CONSENSUS_CHECKPOINT_VERSION" \
    '.version==$cv and .target=="impl" and .contract_version==$v and .next_step=="PASS"' "$ck" >/dev/null 2>&1 || return 1
  [ "$(jq -r '.review // ""' "$ck")" = "$(doc_gap_field '.base_consensus_review')" ] || return 1
  [ -n "$(doc_gap_field '.base_pass_fingerprint')" ] && [ "$(jq -r '.input_fingerprint // ""' "$ck")" = "$(doc_gap_field '.base_pass_fingerprint')" ] || return 1
  [ "$(doc_gap_field '.base_consensus_review')" = "$WORK_DIR/reviews/validator-impl-round-$(printf '%02d' "$(doc_gap_field '.base_consensus_round')").json" ] || return 1
  valid_spec_pass_review "$(doc_gap_field '.base_consensus_review')"
}
# 사용자 답 수리: 답·approach 동기화·source tree 는 호출자가 확인했다. 수리는 세 단계다 — ① 사전 조건(doc_gap_accept_precheck) ② 리뷰 gap 이면 stale unit 사전 검사
# (doc_gap_repair_preflight — 체크포인트를 바꾸지 않는다) ③ 확정(doc_gap_accept). 지문을 먼저 고정하고 unit 을 검사하면, 검사 실패 뒤 사용자가 안내대로 문서를 고쳐도
# 이미 고정된 지문과 달라 재시도할 수 없다(feature 073). 그래서 ①·② 가 전부 통과한 뒤에만 ③ 이 한 번의 tmp+mv 로 지문과 단계를 함께 쓴다.
# precheck: 해결 범위(frozen 문서 불변·decisions append-only)·답 존재·밑바탕 PASS. 반환: 0 통과, 2 해결 범위 밖 변경, 1 밑바탕 무효. 상태를 바꾸지 않는다.
doc_gap_accept_precheck() {
  doc_gap_base_consensus_valid || return 1
  doc_gap_resolution_scope_ok || return 2
  [ -z "$(doc_gap_unanswered)" ] || return 2
}
# 확정: 지금의 impl 입력 지문(문서 + [scope=impl] 결정)을 사용자 해결 provenance 로 고정하고 WORKER_PENDING 으로. 인자를 주면(사전 검사가 본 지문) 지금의 지문과 같을 때만 쓴다.
# 반환: 0 수리, 2 해결 범위 밖 변경, 3 사전 검사 뒤 입력이 바뀜(체크포인트 불변), 1 밑바탕 무효/기록 실패.
doc_gap_accept() { # [사전 검사가 본 지문]
  local fp
  doc_gap_accept_precheck || return $?
  fp="$(consensus_pass_fingerprint impl)" || return 1
  [ -z "${1:-}" ] || [ "$1" = "$fp" ] || return 3
  jq --arg fp "$fp" --arg now "$(date '+%FT%T%z')" '.resolved_impl_fingerprint=$fp | .next_step="WORKER_PENDING" | .updated_at=$now' \
    "$DOC_GAP_RESUME" > "$DOC_GAP_RESUME.tmp" && mv "$DOC_GAP_RESUME.tmp" "$DOC_GAP_RESUME"
}
# ---------- 완료 unit 진단 (gap 해결이 낳은 계약 변경이 gap 으로 설명되는가) ----------
# 지금의 $DOC_GAP_RESUME 기준으로 유효하지 않은 완료 unit 과 위치를 확정하지 못한 후보 gap 을 모은다(모델 호출 없음, 상태 변경 없음) → JSON
#   {stale:[{unit, status, global_changed, linked_tags, changed:[{block, approach, tagged, mentions}]} | {unit, status, why}], unresolved:[{tag, key, prior, location, unresolved:[…]}]}
doc_gap_units_diagnosis() {
  local id stale='[]' d st links
  for id in $(unit_ids); do
    if unit_done_valid "$id"; then continue; fi
    st="$(unit_contract_status "$id")"
    if d="$(unit_contract_drift_json "$id" 2>/dev/null)"; then
      d="$(jq -c --arg st "$st" '. + {status:$st}' <<< "$d")" || return 1
    else
      UC_WHY=""; unit_contract_current "$id" >/dev/null 2>&1 || true   # 사유(UC_WHY)는 서브셸 밖에서 다시 받아야 남는다
      d="$(jq -nc --arg id "$id" --arg st "$st" --arg why "${UC_WHY:-기준 계약 스냅샷 또는 완료 체크포인트를 읽을 수 없음}" '{unit:$id, status:$st, why:$why}')" || return 1
    fi
    stale="$(jq -c --argjson d "$d" '. + [$d]' <<< "$stale")" || return 1
  done
  links="$(doc_gap_links)" || return 1
  jq -nc --argjson stale "$stale" --argjson links "$links" '{stale:$stale, unresolved:[$links[] | select((.unresolved | length) > 0) | {tag, key, prior, location, unresolved}]}'
}
# 진단 JSON → 중단 사유(DOC_GAP_PREFLIGHT_KIND)와 보고문(DOC_GAP_PREFLIGHT_DETAIL). 0 = 통과, 2 = 중단.
#   둘째 인자 "repair"(WAITING_USER 의 최초 수리 — doc_gap_repair_preflight): **현재 gap** 의 위치가 미확정이면 유효하지 않은 unit 이 하나도 없어도 중단한다.
#     위치를 모르는 gap 의 해결을 승인하면 그 gap 이 어느 unit 의 것인지 정하지 못한 채 지문이 고정된다 — stale unit 유무와 독립인 조건이다.
#     앞서 해결된 gap(prior_gaps)의 미확정 위치는 이 조건에 넣지 않는다: 이미 승인된 이력이고, 그 해결로 덮이지 않는 unit 은 stale 로 드러난다(정상 재개 호환).
#     인자가 없으면(이미 지문이 고정된 WORKER_PENDING 재검사) 종전대로 유효하지 않은 unit 이 있을 때만 중단한다 — 승인된 체크포인트를 사후에 무효화하지 않는다.
#   DOC_GAP_SCOPE_EXCEEDED       확인 가능한 범위 위반이 하나라도 있다: 전역 입력 변경, approach.md 가 아닌 계약 블록 변경, 어느 gap 의 해결인지 표시 없는 approach 절 변경,
#                                위치가 확정된 gap 인데 그 unit scope 와 연결되지 않는 gap 의 tag 만 적힌 절, 기준 스냅샷·완료 체크포인트 무효
#   DOC_GAP_LOCATION_UNRESOLVED  남은 문제가 전부 'gap 위치를 확정할 수 없음'이다(절에 적힌 tag 의 gap, 또는 repair 에서 현재 gap) — 범위 위반으로 단정하지 않는다(옛 체크포인트의 자유 문자열 위치)
DOC_GAP_PREFLIGHT_KIND=""; DOC_GAP_PREFLIGHT_DETAIL=""; DOC_GAP_PREFLIGHT_FP=""
doc_gap_diagnosis_classify() { # diagnosis-json [repair]
  local out cur=0
  DOC_GAP_PREFLIGHT_KIND=""; DOC_GAP_PREFLIGHT_DETAIL=""
  out="$(jq -c '
    ([.unresolved[].tag]) as $ut
    | def name: sub("^=== reference: "; "") | sub("^=== "; "") | sub(" ===$"; "");
      def classify: # 변경 블록 하나 → {kind: ok|scope|location, text}
        if (.approach | not) then {kind:"scope", text:("\(.block | name) — approach.md 절이 아닌 계약 변경(gap 해결 범위 밖)")}
        elif .tagged then {kind:"ok", text:("\(.block | name) — 연결된 gap tag 있음")}
        elif ([.mentions[] | select(. as $m | $ut | index($m) != null)] | length) > 0 then
          {kind:"location", text:("\(.block | name) — tag [\([.mentions[] | select(. as $m | $ut | index($m) != null)] | join("] ["))] 가 적혀 있지만 그 gap 의 위치를 확정할 수 없음")}
        elif (.mentions | length) > 0 then
          {kind:"scope", text:("\(.block | name) — tag [\(.mentions | join("] ["))] 가 적혀 있지만 그 gap 의 경로가 이 unit scope 밖")}
        else {kind:"scope", text:("\(.block | name) — 어느 gap 의 해결인지 표시(tag) 없는 변경")} end;
      [.stale[] | if has("changed") then
          ([.changed[] | classify]) as $c
          | {unit, items:$c, extra:([ (if .global_changed then "전역 입력(request·conventions·design·unit 에 묶이지 않은 결정) 변경" else empty end),
                                      (if (.changed | length) == 0 and (.global_changed | not) then "계약은 기준과 같지만 완료 체크포인트(done.json)가 유효하지 않음" else empty end) ]),
             linked:.linked_tags}
          | . + {text:("[\(.unit)] " + (((.items | map(.text)) + .extra) | join(" / ")) + " (이 unit 과 연결된 gap tag: " + (if (.linked | length) > 0 then (.linked | map("[" + . + "]") | join(" ")) else "없음" end) + ")")}
        else {unit, items:[], extra:["\(.status): \(.why)"], text:("[\(.unit)] \(.status) — \(.why)")} end] as $units
    | {n:($units | length),
       scope:([$units[] | select((.extra | length) > 0 or any(.items[]; .kind == "scope"))] | length),
       location:([$units[] | select(any(.items[]; .kind == "location"))] | length),
       units:([$units[].unit] | join(" ")),
       text:([$units[].text] | join(" ; ")),
       current_unresolved:([.unresolved[] | select(.prior | not)] | length),
       unresolved:([.unresolved[] | "[\(.tag)] 원문 \"\(.location)\" — " + ([.unresolved[] | "\"\(.token)\" 후보 \(if (.candidates | length) == 0 then "없음" else (.candidates | join(", ")) end)"] | join(" / "))] | join(" ; "))}' <<< "$1")" || return 1
  [ "${2:-}" != repair ] || cur="$(jq -r '.current_unresolved' <<< "$out")"
  if [ "$(jq -r '.n' <<< "$out")" -eq 0 ]; then
    [ "$cur" -gt 0 ] || return 0
    DOC_GAP_PREFLIGHT_KIND=DOC_GAP_LOCATION_UNRESOLVED
    DOC_GAP_PREFLIGHT_DETAIL="유효하지 않은 완료 unit 은 없다. 위치를 확정할 수 없는 gap(경로 추정·저장소 검색 없음) — $(jq -r '.unresolved' <<< "$out")"
    return 2
  fi
  if [ "$(jq -r '.scope' <<< "$out")" -eq 0 ] && { [ "$(jq -r '.location' <<< "$out")" -gt 0 ] || [ "$cur" -gt 0 ]; }; then DOC_GAP_PREFLIGHT_KIND=DOC_GAP_LOCATION_UNRESOLVED; else DOC_GAP_PREFLIGHT_KIND=DOC_GAP_SCOPE_EXCEEDED; fi
  DOC_GAP_PREFLIGHT_DETAIL="유효하지 않은 완료 unit: $(jq -r '.units' <<< "$out"). unit 별 내역 — $(jq -r '.text' <<< "$out")"
  [ -z "$(jq -r '.unresolved' <<< "$out")" ] || DOC_GAP_PREFLIGHT_DETAIL="$DOC_GAP_PREFLIGHT_DETAIL. 위치를 확정할 수 없는 gap(경로 추정·저장소 검색 없음) — $(jq -r '.unresolved' <<< "$out")"
  return 2
}
# WAITING_USER 의 최초 수리 전용 사전 검사. "지금 문서로 수리하면" 완료 unit 이 전부 유효한가를 **후보 상태**로 본다:
#   체크포인트 사본에 지금의 지문·WORKER_PENDING 을 넣은 후보 파일을 만들고, 이 함수의 서브셸 안에서만 DOC_GAP_RESUME 을 그 파일로 바꿔 기존 판정 함수
#   (unit_done_valid → unit_contract_drift_covered → doc_gap_resolved_current)를 그대로 돌린다. 실제 doc-gap-resume.json 은 읽기만 한다 — 실패하든 도중에 죽든 WAITING_USER 그대로다.
#   후보 파일은 승인 근거가 아니다: 어떤 판정도 이 경로를 체크포인트로 읽지 않고(doc_gap_next_step 은 $DOC_GAP_RESUME 만 본다), 호출마다 새로 만들고 끝나면 지운다.
#   남아 있는 잔재가 다음 실행의 검사를 건너뛰게 하지 못한다.
# 반환: 0 통과(DOC_GAP_PREFLIGHT_FP = 검사한 지문 — doc_gap_accept 에 그대로 넘긴다) / 2 중단(KIND·DETAIL) / 1 실행 실패.
DOC_GAP_CANDIDATE="$WORK_DIR/.doc-gap-resume.candidate.json"
doc_gap_repair_preflight() {
  local fp diag rc=0
  DOC_GAP_PREFLIGHT_KIND=""; DOC_GAP_PREFLIGHT_DETAIL=""; DOC_GAP_PREFLIGHT_FP=""
  [ "$(doc_gap_next_step)" = WAITING_USER ] || return 1
  fp="$(consensus_pass_fingerprint impl)" || return 1
  jq --arg fp "$fp" '.resolved_impl_fingerprint=$fp | .next_step="WORKER_PENDING"' "$DOC_GAP_RESUME" > "$DOC_GAP_CANDIDATE" || { rm -f "$DOC_GAP_CANDIDATE"; return 1; }
  diag="$( DOC_GAP_RESUME="$DOC_GAP_CANDIDATE"; doc_gap_resolved_current || exit 9; doc_gap_units_diagnosis )" || rc=$?
  rm -f "$DOC_GAP_CANDIDATE"
  [ "$rc" -eq 0 ] || return 1
  doc_gap_diagnosis_classify "$diag" repair || return $?
  DOC_GAP_PREFLIGHT_FP="$fp"
}
# 사용자 해결 provenance 가 현재 입력에 유효한가 — 다섯 가지를 모두 만족할 때만 true(어느 하나라도 깨지면 일반 impl 재합의로 돌아간다):
#   ① 활성 체크포인트(포맷 버전, 수리된 단계 WORKER_PENDING/REVIEW_PENDING/RESOLVED, 수리 지문 존재)
#   ② 밑바탕이 실제 impl consensus PASS(doc_gap_base_consensus_valid)
#   ③ 모든 pending gap 에 사용자 답이 지금도 존재
#   ④ 해결 범위 안의 변경뿐(frozen 문서 불변, decisions append-only)
#   ⑤ 수리 시점에 고정한 impl 입력 지문 == 현재 impl 입력 지문(그 뒤 approach/decisions 를 또 고쳤으면 무효)
# approach.md 가 바뀌었다는 사실만으로는 어느 조건도 만족하지 않는다 — 수리 지문은 doc_gap_accept 만 쓴다(사전 검사의 후보 파일은 그 호출 안에서만 읽힌다).
doc_gap_resolved_current() {
  [ -f "$DOC_GAP_RESUME" ] || return 1
  jq -e --argjson v "$DOC_GAP_RESUME_VERSION" '.version==$v and (.next_step=="WORKER_PENDING" or .next_step=="REVIEW_PENDING" or .next_step=="RESOLVED") and .resolved_impl_fingerprint!=""' \
    "$DOC_GAP_RESUME" >/dev/null 2>&1 || return 1
  doc_gap_base_consensus_valid || return 1
  [ -z "$(doc_gap_unanswered)" ] || return 1
  doc_gap_resolution_scope_ok || return 1
  [ "$(doc_gap_field '.resolved_impl_fingerprint')" = "$(consensus_pass_fingerprint impl)" ]
}
# 워커 이상으로 가도 되는 impl 문서 상태: 최초 validator PASS 가 현재 입력에 유효하거나, impl 합의 에스컬레이션의 사용자 수리(USER_RESOLVED)가 현재 입력에 유효하거나,
# 그 둘 중 하나 위에 사용자가 구현 후 gap 을 해결한 지문이 현재 입력과 같다.
impl_docs_accepted() { consensus_stage_accepted impl || doc_gap_resolved_current; }
# 사용자 보고문: gap 마다 id·질문·선택지·근거/코드 위치·영향 + 답을 적을 decisions.md 형식.
doc_gap_report() {
  jq -r '.gaps[] | "  [\(.key)] \(.question)\n      선택지: \(.options | join(" | "))\n      근거·코드: \(.refs | join(", "))\n      영향: \(.impact)\n      답 형식: - [USER-QUESTION][scope=impl][\(.tag)] \(.question) → <선택한 option>"' "$DOC_GAP_RESUME"
}
# review-gap 워커 프롬프트 블록: pending gap + 사용자가 decisions.md 에 적은 답 줄.
doc_gap_prompt_block() {
  local tag
  jq -r '.gaps[] | "- gap \(.key) (\(.location)): \(.question)\n  options: \(.options | join(" | "))"' "$DOC_GAP_RESUME"
  printf '\n사용자 결정(decisions.md):\n'
  while IFS= read -r tag; do printf '%s\n' "$(doc_gap_answer_line "$tag")"; done < <(doc_gap_field '.gaps[].tag')
  # 같은 리뷰에서 앞서 해결된 미결정(review-gap 워커가 새 미결정을 내 다시 도는 경우): 이번 체크포인트의 gap 은 워커 미결정뿐이므로 리뷰 DOC_GAP 의 결정을 함께 싣는다
  jq -r --arg r "$(doc_gap_field '.review // ""')" '
    [(.prior_gaps // [])[] | select($r != "" and (.review // "") == $r and (.answer // "") != "")]
    | if length > 0 then "\n같은 리뷰에서 앞서 결정된 항목(그대로 유효 — decisions.md):", (.[] | "- gap \(.key) (\(.location)): \(.question)\n  \(.answer)") else empty end' "$DOC_GAP_RESUME"
}
# ---------- review-gap 워커 실행 식별자·실행 기록 (doc-gap-resume.json 의 worker_run) ----------
# review-gap 워커 결과를 다시 쓰려면 "그 결과가 바로 이 gap 의 것"임이 증명돼야 한다. tree 비교만으로는 부족하다 — 앞 gap 의 워커가 코드를 바꾸지 않고
# DONE 으로 끝났으면 before/after tree 가 다음 gap 의 source tree 와 모두 같아, 다음 gap 의 워커를 부르지 않고 리뷰로 넘어간다(feature 061).
# 식별자 = 리뷰 경로 + 리뷰 **내용** + origin·attempt·round + 미결정 ID(key·tag·질문·선택지·위치) + 앞선 해결 기록 + 사용자 결정(답 줄 원문)
#          + 관련 계약(수리 시점에 고정한 impl 입력 지문 — implementation/approach/범위/units/scope=impl 결정/conventions)의 해시.
#   시각·tree 는 넣지 않는다(재실행해도 같은 값). 새 gap 이 기록되면 체크포인트가 새로 쓰여 worker_run 이 없으므로 앞 gap 의 결과는 구조적으로 재사용될 수 없다.
# worker_run = {identity, state:STARTED|DONE, before_tree, result, prior_result_sha256, after_tree, result_sha256} — 체크포인트와 같은 tmp+mv 로 쓴다.
#   STARTED: 호출 직전(그 시점에 남아 있던 결과 파일의 해시 = prior_result_sha256 — 앞 gap 의 결과와 이번 호출의 결과를 구별한다)
#   DONE   : run_worker 가 모든 게이트·세션 수용을 지나 유효한 DONE 으로 돌아온 뒤(결과 파일 해시·after tree 를 식별자와 함께 고정)
doc_gap_worker_identity() {
  local review tag
  review="$(doc_gap_field '.review // ""')"
  {
    printf 'review-gap-worker-v1\0%s\0' "$review"
    if [ -n "$review" ] && [ -f "$review" ]; then sha256_stdin < "$review"; else printf 'ABSENT'; fi; printf '\0'
    jq -Sc '{origin, attempt, round, unit_id, gaps:[.gaps[] | {key, tag, question, options, location}],
             prior:[(.prior_gaps // [])[] | {tag, review:(.review // ""), answer:(.answer // "")}], resolved_impl_fingerprint}' "$DOC_GAP_RESUME" || return 1
    printf '\0'
    while IFS= read -r tag; do printf '%s\0%s\0' "$tag" "$(doc_gap_answer_line "$tag")"; done < <(doc_gap_field '.gaps[].tag')
  } | sha256_stdin
}
doc_gap_worker_run_start() { # identity before_tree result_path
  local prior_sha=""
  if [ -f "$3" ]; then prior_sha="$(sha256_stdin < "$3")" || return 1; fi
  jq --arg id "$1" --arg b "$2" --arg r "$3" --arg p "$prior_sha" --arg now "$(date '+%FT%T%z')" \
    '.worker_run={identity:$id, state:"STARTED", before_tree:$b, result:$r, prior_result_sha256:$p, started_at:$now} | .updated_at=$now' \
    "$DOC_GAP_RESUME" > "$DOC_GAP_RESUME.tmp" && mv "$DOC_GAP_RESUME.tmp" "$DOC_GAP_RESUME"
}
doc_gap_worker_run_done() { # after_tree
  local result sha
  result="$(doc_gap_field '.worker_run.result // ""')"
  worker_result_valid "$result" && jq -e '.status=="DONE"' "$result" >/dev/null 2>&1 || return 1
  sha="$(sha256_stdin < "$result")" || return 1
  jq --arg a "$1" --arg s "$sha" --arg now "$(date '+%FT%T%z')" \
    '.worker_run += {state:"DONE", after_tree:$a, result_sha256:$s, finished_at:$now} | .updated_at=$now' \
    "$DOC_GAP_RESUME" > "$DOC_GAP_RESUME.tmp" && mv "$DOC_GAP_RESUME.tmp" "$DOC_GAP_RESUME"
}
# WORKER_PENDING 에서 review-gap 워커를 부를지 판정한다(모델 호출 없음). stdout 은 사유/기대 tree, 반환값이 판정이다:
#   0  호출   — 이 gap 의 실행 기록이 없고 현재 tree == 체크포인트 source tree, 또는 시작만 기록됐고(STARTED) tree 가 호출 전 그대로이며
#               결과 파일이 없거나(run_worker 가 호출 직전에 지운다) 비었거나 시작 기록 당시 내용 그대로다(= CLI 가 결과를 쓰지 않았다)
#               (기존 정책: 결과 없이 tree 도 그대로면 재실행해도 같은 편집이 중복될 위험이 없다)
#   10 재사용 — 같은 식별자 + DONE 기록 + 호출 전 tree == 체크포인트 source tree + 현재 tree == 기록된 after tree + 결과 파일이 기록 당시 내용 그대로인 유효한 DONE.
#               코드 변경이 없던 실행(before == after)도 같은 조건으로 재사용된다
#   11 source tree 불일치 — stdout 은 기대 tree. 조용히 진행하지 않는다(DOC_GAP_SOURCE_CHANGED)
#   12 불확실 — 식별자가 다르거나, 시작만 기록됐는데 결과 파일이 시작 기록 당시와 다른 내용으로 남아 있거나(유효한 JSON 인지와 무관 — CLI 가 실제로 돌아 무언가를 썼다,
#               게이트·세션 수용 완료 여부 불명), 결과 파일이 완료 기록과 다르다. 자동 재호출하지 않는다
doc_gap_worker_run_verdict() { # identity cur_tree
  local identity="$1" cur_tree="$2" state before after result cur_sha=""
  if ! jq -e '.worker_run | type=="object"' "$DOC_GAP_RESUME" >/dev/null 2>&1; then
    [ "$cur_tree" = "$(doc_gap_field '.source_tree')" ] && return 0
    doc_gap_field '.source_tree'; return 11
  fi
  state="$(doc_gap_field '.worker_run.state // ""')"; before="$(doc_gap_field '.worker_run.before_tree // ""')"
  after="$(doc_gap_field '.worker_run.after_tree // ""')"; result="$(doc_gap_field '.worker_run.result // ""')"
  if [ "$(doc_gap_field '.worker_run.identity // ""')" != "$identity" ]; then
    printf '기록된 review-gap 워커 실행(%s)의 식별자가 지금의 리뷰 내용·미결정·사용자 결정·계약과 다르다' "$state"; return 12
  fi
  if [ -n "$result" ] && [ -f "$result" ]; then cur_sha="$(sha256_stdin < "$result")" || { printf '결과 파일 해시 계산 실패'; return 12; }; fi
  case "$state" in
    DONE)
      [ "$before" = "$(doc_gap_field '.source_tree')" ] || { printf '기록된 호출 전 tree(%s)가 체크포인트 source tree 와 다르다' "$before"; return 12; }
      [ "$cur_tree" = "$after" ] || { printf '%s' "$after"; return 11; }
      worker_result_valid "$result" && jq -e '.status=="DONE"' "$result" >/dev/null 2>&1 && [ "$cur_sha" = "$(doc_gap_field '.worker_run.result_sha256 // ""')" ] \
        || { printf '결과 파일(%s)이 완료 기록 당시와 다르거나 유효한 DONE 이 아니다' "$result"; return 12; }
      return 10;;
    STARTED)
      [ "$cur_tree" = "$before" ] || { printf '%s' "$before"; return 11; }
      # 결과 파일이 시작 기록 당시와 다른 내용으로 남아 있으면 CLI 가 실제로 돌았다 — 그 내용이 유효한 결과인지와 무관하게 자동 재호출하지 않는다
      # (깨진 결과를 남긴 호출도 세션에는 턴이 들어갔을 수 있다 — 같은 프롬프트의 중복 전송 금지). 빈 파일은 결과가 아니다(run_worker 의 WORKER_RESULT_MISSING 과 같은 기준).
      if [ -n "$cur_sha" ] && [ -s "$result" ] && [ "$cur_sha" != "$(doc_gap_field '.worker_run.prior_result_sha256 // ""')" ]; then
        if worker_result_valid "$result"; then
          printf '호출은 시작됐고 이번 호출의 유효한 결과(%s, status %s)가 남아 있지만 완료 기록(게이트·세션 수용 통과)이 없다' "$result" "$(jq -r '.status' "$result")"
        else
          printf '호출은 시작됐고 결과 파일(%s)이 시작 기록 당시와 다른 내용으로 남아 있지만 유효한 결과가 아니고 완료 기록도 없다 — CLI 가 실제로 수행됐을 수 있다(원본 로그·세션 기록으로 호출이 수행되지 않았음을 확인했다면 그 결과 파일을 치우고 재실행하면 워커부터 다시 돈다)' "$result"
        fi
        return 12
      fi
      return 0;;
    *) printf '알 수 없는 worker_run.state: %s' "$state"; return 12;;
  esac
}
# REVIEW_PENDING 에서 리뷰로 들어가도 되는지 판정한다(모델 호출 없음) — WORKER_PENDING 의 재사용 판정(10)과 같은 증명을 단계가 넘어간 뒤에도 요구한다.
#   REVIEW_PENDING 은 "review-gap 워커가 끝났다"는 주장일 뿐이다: 완료 기록 뒤에 결과 파일·리뷰·결정이 바뀌었거나 체크포인트에 실행 기록이 없으면 그 주장을 믿지 않는다.
#   0  진입 — worker_run 이 DONE 이고 체크포인트 source tree == 기록된 after tree 이고 식별자가 지금과 같고 결과 파일이 완료 기록 당시 내용의 유효한 DONE 이며, (리뷰가 아직 진행되지 않았으면) 현재 tree == 기록된 after tree
#   11 source tree 불일치(stdout = 기대 tree)   12 불확실(stdout = 사유)
# tree 는 리뷰 루프가 이 워커 뒤로 아직 아무것도 진행하지 않았을 때만 본다: 리뷰어가 REQUEST_CHANGES 를 내면 수정자가 tree 를 바꾸는 것이 정상이고,
#   그 뒤의 tree 귀속은 리뷰 루프의 체크포인트(review-impl.json 의 작업 트리 지문)가 판정한다. '진행됨' = review-impl.json 이 초기화 상태(NONE)가 아니거나,
#   러너가 리뷰 루프의 사용자 반환(DEADLOCK/MAX_ROUNDS/REVIEW_OUTPUT_INVALID — 체크포인트가 초기화될 수 있다)을 worker_run.review_progressed 로 남겼다.
doc_gap_review_progressed() {
  jq -e '.worker_run.review_progressed == true' "$DOC_GAP_RESUME" >/dev/null 2>&1 && return 0
  [ -f "$WORK_DIR/review-impl.json" ] && jq -e '(.next_step // "NONE") != "NONE"' "$WORK_DIR/review-impl.json" >/dev/null 2>&1
}
doc_gap_mark_review_progressed() {
  jq -e '.worker_run | type=="object"' "$DOC_GAP_RESUME" >/dev/null 2>&1 || return 0
  jq --arg now "$(date '+%FT%T%z')" '.worker_run.review_progressed=true | .updated_at=$now' "$DOC_GAP_RESUME" > "$DOC_GAP_RESUME.tmp" && mv "$DOC_GAP_RESUME.tmp" "$DOC_GAP_RESUME"
}
doc_gap_review_entry_verdict() { # identity cur_tree
  local identity="$1" cur_tree="$2" state after result cur_sha=""
  if ! jq -e '.worker_run | type=="object"' "$DOC_GAP_RESUME" >/dev/null 2>&1; then
    printf 'REVIEW_PENDING 체크포인트에 review-gap 워커 실행 기록(worker_run)이 없다 — 워커 완료를 증명할 수 없다'; return 12
  fi
  state="$(doc_gap_field '.worker_run.state // ""')"; after="$(doc_gap_field '.worker_run.after_tree // ""')"; result="$(doc_gap_field '.worker_run.result // ""')"
  [ "$state" = DONE ] || { printf 'REVIEW_PENDING 인데 review-gap 워커 실행 기록이 완료(DONE)가 아니다(%s)' "${state:-없음}"; return 12; }
  # WORKER_PENDING 의 '호출 전 tree == source tree' 에 대응하는 검사: REVIEW_PENDING 으로 넘어갈 때 source_tree 는 워커의 after tree 로 갱신된다
  # (doc_gap_set_step REVIEW_PENDING <after>). 둘이 다르면 체크포인트와 실행 기록이 같은 실행을 가리키지 않는다.
  [ -n "$after" ] && [ "$after" = "$(doc_gap_field '.source_tree')" ] \
    || { printf '완료 기록의 after tree(%s)가 REVIEW_PENDING 체크포인트의 source tree 와 다르다' "${after:-없음}"; return 12; }
  if [ "$(doc_gap_field '.worker_run.identity // ""')" != "$identity" ]; then
    printf '완료 기록된 review-gap 워커 실행의 식별자가 지금의 리뷰 내용·미결정·사용자 결정·계약과 다르다'; return 12
  fi
  if [ -n "$result" ] && [ -f "$result" ]; then cur_sha="$(sha256_stdin < "$result")" || { printf '결과 파일 해시 계산 실패'; return 12; }; fi
  worker_result_valid "$result" && jq -e '.status=="DONE"' "$result" >/dev/null 2>&1 && [ "$cur_sha" = "$(doc_gap_field '.worker_run.result_sha256 // ""')" ] \
    || { printf '결과 파일(%s)이 완료 기록 당시와 다르거나 유효한 DONE 이 아니다' "$result"; return 12; }
  if ! doc_gap_review_progressed; then
    [ "$cur_tree" = "$after" ] || { printf '%s' "$after"; return 11; }
  fi
  return 0
}
