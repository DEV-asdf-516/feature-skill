#!/usr/bin/env bash
# =============================================================
# .claude/skills/feature/scripts/lib/state/escalation.sh
# 합의 단계 사용자 에스컬레이션 수리 체크포인트 + consensus_stage_accepted.
# scripts/lib/bootstrap.sh 가 정해진 순서로 source 한다 — 직접 실행하지 않는다.
# (분리 전 config.sh 기준 1908–2051)
# =============================================================

# =============================================================
# 합의 단계 사용자 에스컬레이션 수리 체크포인트 — $WORK_DIR/user-escalation-resume-<target>.json  (target = design | impl)
#   합의 루프가 ASK_USER / DEADLOCK / MAX_ROUNDS_EXCEEDED 로 멈추면 그 단계의 미해결 blocker 는 사용자에게 간다. 사용자의 명시적 결정이 그 blocker 의
#   최종 결정이며, 모든 blocker 가 결정되면 같은 단계의 검증자·디자이너를 다시 부르지 않고 다음 단계(design → impl, impl → worker)로 간다.
#   USER_RESOLVED 는 검증자 PASS 가 아니다 — consensus-<target>.json 을 PASS 로 만들지 않고 리뷰 JSON 의 BLOCK 도 그대로 둔다. 대신 이 파일이
#   "실제 마지막 리뷰(경로 + 내용 해시 + blocker 사본) + 발생 시점 입력 지문 + 사용자가 답한 줄 + 수리 시점 입력 지문" 을 별도 provenance 로 든다.
#   next_step: WAITING_USER(답 전 — 모델 호출 0회) → USER_RESOLVED(모든 blocker 에 답, 수리 지문 고정) / SUPERSEDED(전제가 깨져 정상 재합의로 넘어감 — 근거 보존용)
#   답 줄(blocker 마다 하나, 발생 뒤에 **추가된** 줄만 인정):  `- [USER-QUESTION][scope=<target>][escalation=<blocker id>] <질문·쟁점> → <답>`
#     scope 는 발생 단계와 같아야 하고 답은 비어 있으면 안 된다. ASK_USER 의 선택이든 REVISE_DOC 요구의 수용/기각이든 같은 형식이다.
#     [escalation=…] 은 구현 후 gap 의 [review-issue=…] / [worker-gap=…] 과 다른 태그이고 서로의 답으로 인정되지 않는다.
#   우회가 성립하는 범위(그 밖은 전부 종전 규칙 — 정상 재합의):
#     - 대기 중 바뀌어도 되는 것: 그 단계 문서(design: design.md / impl: implementation.md·approach.md)와 decisions.md 의 **추가**.
#     - 대기 중 바뀌면 안 되는 것(frozen): request.md, conventions.md, (impl) design.md·feature-scope.json·implementation-units.json·scope=design 결정,
#       decisions.md 의 기존 줄, 검증 계약·체크포인트 버전, 리뷰 JSON 내용. 하나라도 달라지면 에스컬레이션은 SUPERSEDED 가 되고 Round 1 부터 재합의한다.
#     - 수리 뒤: 수리 시점의 PASS 지문(consensus_pass_fingerprint) 과 현재가 같을 때만 재사용한다. 문서·결정·범위·conventions 를 또 바꾸면 무효다.
# =============================================================
USER_ESCALATION_VERSION=1
user_escalation_file() { printf '%s/user-escalation-resume-%s.json' "$WORK_DIR" "$1"; }
user_escalation_field() { jq -r "$2" "$(user_escalation_file "$1")"; } # target jq-filter
user_escalation_step() { # target → next_step (파일 없음·포맷 버전/target 불일치면 빈 값)
  local f; f="$(user_escalation_file "$1")"
  [ -f "$f" ] && jq -r --argjson v "$USER_ESCALATION_VERSION" --arg t "$1" 'if .version==$v and .target==$t then .next_step else "" end' "$f" 2>/dev/null || printf ''
}
_user_escalation_frozen_hash() { # target → 대기 중 바뀌면 안 되는 입력의 해시
  {
    case "$1" in
      design) _fingerprint_files "$WORK_DIR/request.md";;
      impl) _fingerprint_files "$WORK_DIR/request.md" "$WORK_DIR/design.md" "$WORK_DIR/feature-scope.json" "$WORK_DIR/implementation-units.json"
            consensus_user_decisions_for design;;
    esac
    consensus_conventions_stream
  } | sha256_stdin
}
# 그 단계 문서만의 해시(decisions.md 제외) — ASK_USER 결정이 문서에 반영됐는지(발생 시점과 달라졌는지) 확인하는 용도.
_user_escalation_stage_docs_hash() { # target
  case "$1" in
    design) _fingerprint_files "$WORK_DIR/design.md";;
    impl) _fingerprint_files "$WORK_DIR/implementation.md" "$WORK_DIR/approach.md";;
  esac | sha256_stdin
}
# 에스컬레이션 기록(WAITING_USER). 합의 루프가 consensus-<target>.json 을 초기화하기 **전에** 부른다 — DEADLOCK/MAX_ROUNDS 의 마지막 실제 리뷰가 사라지지 않게.
user_escalation_record() { # target reason review round
  local f n; f="$(user_escalation_file "$1")"; n="$(_doc_gap_decisions_lines)"
  [ -f "$3" ] && jq -e '(.blocking_issues|length)>0' "$3" >/dev/null 2>&1 || return 1
  jq -n --argjson v "$USER_ESCALATION_VERSION" --arg target "$1" --arg reason "$2" --arg review "$3" --arg round "$4" --slurpfile r "$3" \
    --arg sha "$(sha256_stdin < "$3")" --argjson cv "$VALIDATOR_CONTRACT_VERSION" --argjson ckv "$CONSENSUS_CHECKPOINT_VERSION" \
    --arg editable "$(consensus_editable_fingerprint "$1")" --arg upstream "$(consensus_upstream_fingerprint "$1")" --arg input "$(consensus_pass_fingerprint "$1")" \
    --arg frozen "$(_user_escalation_frozen_hash "$1")" --arg stage "$(_user_escalation_stage_docs_hash "$1")" --arg dl "$n" --arg dh "$(_doc_gap_decisions_prefix_hash "$n")" --arg now "$(date '+%FT%T%z')" \
    '{version:$v, target:$target, reason:$reason, next_step:"WAITING_USER", review:$review, review_sha256:$sha, round:($round|tonumber),
      contract_version:$cv, checkpoint_version:$ckv,
      issues:[$r[0].blocking_issues[] | {id, tag:("escalation=" + .id), action, category, evidence_type,
        question:(if .user_question != "" then .user_question else .minimum_contract_needed end), options, basis_refs, conflict_refs, code_refs,
        reachable_scenario, impact, minimum_contract_needed, user_question}],
      escalated:{editable_fingerprint:$editable, upstream_fingerprint:$upstream, input_fingerprint:$input},
      frozen_inputs_hash:$frozen, stage_docs_hash:$stage, decisions_lines:($dl|tonumber), decisions_prefix_hash:$dh,
      answers:[], resolved_input_fingerprint:"", resolved_editable_fingerprint:"", recorded_at:$now, updated_at:$now}' > "$f.tmp" && mv "$f.tmp" "$f"
}
# 근거 자체가 온전한가(WAITING_USER·USER_RESOLVED 공통): 계약·체크포인트 버전이 현재와 같고, blocker 가 있고, 가리키는 리뷰 JSON 내용이 기록 당시 그대로다.
_user_escalation_evidence_violation() { # target → 깨진 전제 한 줄(없으면 빈 출력)
  local f review; f="$(user_escalation_file "$1")"
  jq -e --argjson cv "$VALIDATOR_CONTRACT_VERSION" '.contract_version==$cv' "$f" >/dev/null 2>&1 || { echo "검증 계약 버전이 발생 당시와 다름(현재 $VALIDATOR_CONTRACT_VERSION)"; return 0; }
  jq -e --argjson ckv "$CONSENSUS_CHECKPOINT_VERSION" '.checkpoint_version==$ckv' "$f" >/dev/null 2>&1 || { echo "합의 체크포인트 포맷 버전이 발생 당시와 다름(현재 $CONSENSUS_CHECKPOINT_VERSION)"; return 0; }
  jq -e '(.issues|length)>0 and (.reason=="ASK_USER" or .reason=="DEADLOCK" or .reason=="MAX_ROUNDS_EXCEEDED")' "$f" >/dev/null 2>&1 || { echo "blocker 목록 또는 발생 사유가 유효하지 않음"; return 0; }
  review="$(user_escalation_field "$1" '.review')"
  { [ -f "$review" ] && [ "$(sha256_stdin < "$review")" = "$(user_escalation_field "$1" '.review_sha256')" ]; } || { echo "원본 리뷰 JSON($review)이 없거나 내용이 발생 당시와 다름"; return 0; }
}
# 대기 중 전제: 근거 온전 + frozen 입력 불변 + decisions.md 는 발생 시점 내용을 prefix 로 유지(append-only).
user_escalation_premise_violation() { # target → 깨진 전제 한 줄(없으면 빈 출력)
  local v n; v="$(_user_escalation_evidence_violation "$1")"
  [ -z "$v" ] || { echo "$v"; return 0; }
  [ "$(_user_escalation_frozen_hash "$1")" = "$(user_escalation_field "$1" '.frozen_inputs_hash')" ] \
    || { case "$1" in design) echo "request.md 또는 conventions.md 가 발생 시점과 다름";; *) echo "request.md·design.md·feature-scope.json·implementation-units.json·conventions.md·scope=design 결정 중 하나가 발생 시점과 다름";; esac; return 0; }
  n="$(user_escalation_field "$1" '.decisions_lines')"
  { [ "$(_doc_gap_decisions_lines)" -ge "$n" ] && [ "$(_doc_gap_decisions_prefix_hash "$n")" = "$(user_escalation_field "$1" '.decisions_prefix_hash')" ]; } \
    || { echo "decisions.md 의 기존 줄이 삭제·수정됨(추가만 허용)"; return 0; }
}
# blocker id 의 답 줄: 발생 뒤에 추가된 줄 중 scope=<target> + [escalation=<id>] + 그 blocker 의 질문·쟁점 문구 + 실제 답. 아래는 답이 아니다:
#   빈 답 / 다른 scope / 다른 id / 질문 문구가 그 blocker 의 것과 다름(공백 차이는 무시 — 보고문의 "답 형식" 줄을 그대로 복사하면 맞는다) /
#   답이 꺾쇠 플레이스홀더 그대로(`→ <답>`, `→ <선택한 option>` 처럼 `<…>` 하나뿐인 답 — 안내 형식을 채우지 않은 것이지 사용자 결정이 아니다).
user_escalation_answer_line() { # target id
  local n id_re q line ans found=""; n="$(user_escalation_field "$1" '.decisions_lines')"
  id_re="$(printf '%s' "$2" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"
  [ -f "$WORK_DIR/decisions.md" ] || return 0
  q="$(jq -r --arg id "$2" '.issues[] | select(.id==$id) | .question' "$(user_escalation_file "$1")" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
  [ -n "$q" ] || return 0
  while IFS= read -r line; do
    ans="$(printf '%s' "${line##*→}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ "$ans" =~ ^\<[^\<\>]*\>$ ]] && continue
    [[ "$(printf '%s' "${line%→*}" | tr -s '[:space:]' ' ')" == *"$q"* ]] || continue
    found="$line"
  done < <(tail -n +"$((n + 1))" "$WORK_DIR/decisions.md" | { grep -E "^[[:space:]]*- \[USER-QUESTION\]\[scope=$1\]\[escalation=$id_re\] .*→[[:space:]]*[^[:space:]]" || true; })
  printf '%s' "$found"
}
user_escalation_unanswered() { # target → 답 없는 blocker id, 한 줄 하나
  local id
  while IFS= read -r id; do [ -n "$(user_escalation_answer_line "$1" "$id")" ] || printf '%s\n' "$id"; done < <(user_escalation_field "$1" '.issues[].id')
}
# ASK_USER 는 정책 선택이므로 그 선택이 단계 문서(design: design.md / impl: implementation.md·approach.md)에 반영돼야 한다 — 발생 시점과 문서가 같으면 수리하지 않는다.
# (사용자가 A 를 골랐는데 문서에는 B 가 남은 채 다음 단계로 가는 것을 막는 최소 검사다. 변경 '여부'만 본다 — 내용 일치까지 증명하지는 않으며 검증자를 다시 부르지도 않는다.)
# DEADLOCK/MAX_ROUNDS 는 검증자 요구의 기각이 문서 변경 없이 성립하므로 요구하지 않는다. stage_docs_hash 가 없는 옛 체크포인트도 요구하지 않는다.
user_escalation_docs_synced() { # target
  [ "$(user_escalation_field "$1" '.reason')" = ASK_USER ] || return 0
  local h; h="$(user_escalation_field "$1" '.stage_docs_hash // ""')"
  [ -z "$h" ] || [ "$(_user_escalation_stage_docs_hash "$1")" != "$h" ]
}
# 사용자 답 수리: 전제(위)와 모든 blocker 의 답을 다시 확인한 뒤, 답 줄과 지금의 입력 지문을 고정하고 USER_RESOLVED 로. 반환: 0 수리, 2 답 없는 blocker 있음, 1 전제 무효/기록 실패.
# 수리 지문은 여기서만 쓴다 — 문서가 바뀌었다는 사실이나 [USER-QUESTION] 줄이 하나 늘었다는 사실만으로는 수리되지 않는다.
user_escalation_accept() { # target
  local f id answers='[]'; f="$(user_escalation_file "$1")"
  [ "$(user_escalation_step "$1")" = WAITING_USER ] || return 1
  [ -z "$(user_escalation_premise_violation "$1")" ] || return 1
  [ -z "$(user_escalation_unanswered "$1")" ] || return 2
  user_escalation_docs_synced "$1" || return 2
  while IFS= read -r id; do
    answers="$(jq -c --arg id "$id" --arg line "$(user_escalation_answer_line "$1" "$id")" '. + [{id:$id, line:$line}]' <<< "$answers")" || return 1
  done < <(user_escalation_field "$1" '.issues[].id')
  jq --argjson answers "$answers" --arg fp "$(consensus_pass_fingerprint "$1")" --arg editable "$(consensus_editable_fingerprint "$1")" --arg now "$(date '+%FT%T%z')" \
    '.next_step="USER_RESOLVED" | .answers=$answers | .resolved_input_fingerprint=$fp | .resolved_editable_fingerprint=$editable | .resolved_at=$now | .updated_at=$now' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
# 수리된 근거가 변조 없이 남아 있는가(현재 입력과 같은지는 보지 않는다 — 구현 후 DOC_GAP 체인의 밑바탕 검사용. doc_gap_base_consensus_valid 의 PASS 검사와 같은 수준).
user_escalation_intact() { # target
  [ "$(user_escalation_step "$1")" = USER_RESOLVED ] || return 1
  [ -z "$(_user_escalation_evidence_violation "$1")" ] || return 1
  jq -e '.resolved_input_fingerprint != "" and (.answers|length)==(.issues|length)' "$(user_escalation_file "$1")" >/dev/null 2>&1
}
# 현재 입력에 대해 유효한 사용자 수리가 있는가: USER_RESOLVED + 근거 온전 + 수리 시점에 고정한 입력 지문 == 현재 PASS 지문(문서·target 범위 사용자 결정·범위·conventions 전부).
user_escalation_resolved_current() { # design | impl
  user_escalation_intact "$1" || return 1
  [ "$(user_escalation_field "$1" '.resolved_input_fingerprint')" = "$(consensus_pass_fingerprint "$1")" ]
}
# 전제가 깨진 에스컬레이션은 지우지 않고 SUPERSEDED 로 남긴다(근거 보존). 그 뒤는 정상 재합의다.
user_escalation_supersede() { # target why
  local f; f="$(user_escalation_file "$1")"
  jq --arg why "$2" --arg now "$(date '+%FT%T%z')" '.superseded_from=.next_step | .next_step="SUPERSEDED" | .superseded_reason=$why | .updated_at=$now' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
# 사용자 보고문: blocker 마다 id·쟁점·선택지·근거 + 답을 적을 decisions.md 형식.
user_escalation_report() { # target
  jq -r --arg t "$1" '.issues[] | "  [\(.id)] (\(.action)) \(.question)" + (if (.options|length)>0 then "\n      선택지: \(.options | join(" | "))" else "" end)
    + "\n      근거: \((.basis_refs + .conflict_refs + .code_refs) | join(", "))\n      답 형식(질문 문구는 그대로 두고 <답> 자리를 실제 결정으로 바꾼다): - [USER-QUESTION][scope=\($t)][\(.tag)] \(.question | gsub("\\s+"; " ")) → <답>"' "$(user_escalation_file "$1")"
}
# 다음 단계로 가도 되는 합의 단계 상태: 검증자 PASS 가 현재 입력에 유효하거나, 사용자가 에스컬레이션의 모든 blocker 를 결정한 수리 지문이 현재 입력과 같다.
consensus_stage_accepted() { consensus_pass_current "$1" || user_escalation_resolved_current "$1"; } # design | impl
