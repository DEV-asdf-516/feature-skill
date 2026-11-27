#!/usr/bin/env bash
# =============================================================
# .claude/skills/feature/scripts/lib/contract/consensus.sh
# 문서 합의 체크포인트 공용 정의(합의 문서·사용자 결정·conventions·PASS/upstream 지문·PASS 판정).
# scripts/lib/bootstrap.sh 가 정해진 순서로 source 한다 — 직접 실행하지 않는다.
# (분리 전 config.sh 기준 1625–1768)
# =============================================================

# ---------- 문서 합의 체크포인트 공용 정의 (consensus-loop.sh 와 feature-run.sh 가 같은 것을 써야 한다) ----------
# 합의 대상 문서 + decisions.md. 스냅샷·문서 diff·변경 파일 계산·재개 지문이 모두 이 목록 하나를 쓴다.
# (지문에 들어가는 파일과 diff 에 잡히는 파일이 다르면, 변경 감지로 넘어간 다음 라운드에서 검증자가
#  실제로 바뀐 파일을 revision_ref 로 가리켜도 러너가 "변경 목록에 없음"으로 응답을 거부하게 된다)
consensus_docs_for() { # design | impl
  case "$1" in
    design) printf '%s\n' "$WORK_DIR/design.md" "$WORK_DIR/decisions.md";;
    impl) printf '%s\n' "$WORK_DIR/implementation.md" "$WORK_DIR/approach.md" "$WORK_DIR/implementation-units.json" "$WORK_DIR/decisions.md";;
  esac
}
# (impl 은 구현 단위 manifest 도 디자이너가 고치는 합의 대상이다 — 러너는 impl 단계 진입 전에 존재를 요구하고, 루프 단독 실행·회귀 픽스처에서는 없어도 된다)
# 지문 세 종류 — 재개 지점은 "누가 무엇을 바꿨는가"에 따라 달라지므로 하나로 합치지 않는다.
#   editable : 디자이너가 고치는 것(consensus_docs_for = 대상 문서 + decisions.md). DESIGNER_PENDING 에서 달라졌으면 디자이너 부분 실행.
#   upstream : 디자이너 입력이지만 이 루프가 고치지 않는 것(design: request.md / impl: request.md + design.md, + target 범위의 [USER-QUESTION]
#              + worktree conventions.md). 달라졌으면 저장된 리뷰 자체가 무효 → Round 1 부터.
#   pass     : 합의된 입력 전체(upstream + 대상 문서 + target 범위의 [USER-QUESTION] + worktree conventions.md). PASS 가 현재 입력에 대한 것인지.
# conventions.md 는 검증자 프롬프트에 본문이 그대로 들어가는 판정 입력이다 — 내용이 바뀌면 옛 규칙으로 받은 design·impl PASS 는 현재 입력에 대한 PASS 가 아니다.
# [USER-QUESTION] 의 의존성 범위(scope) — downstream 은 upstream 결정을 상속하지만 upstream 은 downstream 결정을 보지 않는다:
#   design ← [USER-QUESTION][scope=design]
#   impl   ← [USER-QUESTION][scope=design] + [USER-QUESTION][scope=impl]
# scope 는 질문이 '발생한 단계'가 아니라 그 결정이 **처음 영향을 주는 단계**다:
#   scope=design : 요구·외부 동작·설계(design.md)에 영향을 주는 결정 — impl 합의·워커·리뷰 도중에 나왔어도 design 이다.
#   scope=impl   : 합의된 설계는 그대로이고 구현 수단(implementation.md·approach.md·unit 분할·범위)에만 영향을 주는 결정.
# 그래서 impl 합의 중 사용자가 검증자 요구를 기각한 결정(scope=impl)은 이미 PASS 한 design 을 무효화하지 않고, 늦게 나온 제품 요구(scope=design)는
# design PASS·impl upstream 지문을 깨서 정상 재합의를 거친다. scope=impl 전부를 design 검증자에게 넘기지 않는다(단계 격리).
# 이미 기록된 줄의 scope 를 문구로 추정해 재분류하지 않는다 — 새 규칙은 앞으로 기록하는 결정에 적용된다.
# scope 없는 옛 형식 `- [USER-QUESTION] ...` 은 어느 단계의 결정인지 코드가 추론할 수 없으므로 여기서 추정하지 않는다 —
# 러너·합의 루프가 LLM 호출 전에 DECISION_SCOPE_REQUIRED 로 멈추고 사용자가 태그를 명시한다(consensus_unscoped_user_decisions).
_fingerprint_files() { # file... → NUL 구분 내용 스트림
  for file in "$@"; do
    [ -f "$file" ] || continue
    printf '%s\0' "$file"; cat "$file"; printf '\0'
  done
}
# decisions.md 에서 scope 없는 옛 형식의 사용자 결정 줄 → stdout (없으면 빈 출력). LLM 호출 전 preflight 가 쓴다.
consensus_unscoped_user_decisions() {
  [ -f "$WORK_DIR/decisions.md" ] || return 0
  grep -nE '^[[:space:]]*- \[USER-QUESTION\]' "$WORK_DIR/decisions.md" | grep -vE '^[0-9]+:[[:space:]]*- \[USER-QUESTION\]\[scope=(design|impl)\]' || true
}
# target 이 보는 확정 사용자 결정 줄(한 줄 하나, 없으면 빈 출력). **지문과 검증자 프롬프트 입력이 이 함수 하나를 쓴다** — 검증자가 보지 못한 결정이
# PASS 지문에 들어가거나, 지문에 없는 결정을 검증자가 보는 일이 없게 한다(consensus-loop 의 reviews/user-decisions-<target>.md 도 이 출력이다).
consensus_user_decision_lines() { # design | impl
  local pattern
  case "$1" in
    design) pattern='^[[:space:]]*- \[USER-QUESTION\]\[scope=design\]';;
    impl) pattern='^[[:space:]]*- \[USER-QUESTION\]\[scope=(design|impl)\]';;
    *) echo "[FAIL] consensus_user_decision_lines: 대상은 design 또는 impl 이어야 함: '$1'" >&2; return 1;;
  esac
  if [ -f "$WORK_DIR/decisions.md" ]; then grep -E "$pattern" "$WORK_DIR/decisions.md" || true; fi
}
# 같은 줄 집합 → NUL 구분 스트림 (지문 입력). [round N] ACCEPT/REJECT 같은 합의 이력은 넣지 않는다.
consensus_user_decisions_for() { # design | impl
  printf 'decisions:USER-QUESTION:%s\0' "$1"
  consensus_user_decision_lines "$1" || return 1
  printf '\0'
}
# 지문(합의 PASS·unit 전역 계약·승인 계약 문서·워커 세션 계약)에 넣는 conventions 내용 → stdout. 반환 1 = 없음.
# 자기 무효화 예외: conventions.md 가 이 피처의 범위(feature-scope 의 files — lock 이 있으면 lock)에 **정확히** 들어 있으면 이 피처의 산출물이다.
#   워커가 고친 규칙으로 합의·unit 계약·승인·세션 지문이 바뀌면 피처가 자기 입력을 무효로 만들어 끝까지 갈 수 없다(feature 061).
#   그래서 워커 기준선(worker-baseline.tree — 처음 워커 진입 때 한 번 기록)이 있으면 작업 트리 파일 대신 기준선 tree 의 내용을 쓴다.
#   기준선 기록 직전까지는 작업 트리 파일로 판정하므로(합의 PASS 가 현재 파일에 유효해야 워커에 진입한다) 고정되는 내용은 합의가 본 내용과 같다.
# 예외는 범위 안일 때만이다 — 범위 밖이면(new_file_roots 아래도 해당 없음: 기존 파일 수정은 위반) 기준선이 있어도 작업 트리 파일 그대로라
#   conventions 변경은 종전처럼 합의·unit 계약·승인·세션을 무효로 만든다. 기준선이 유효한 tree 가 아니면 '없음'으로 떨어져 지문이 달라진다(fail closed).
# 역할 프롬프트에 싣는 본문은 이 함수가 아니라 작업 트리 파일이다(load_project_conventions / load_worker_rules) — 뒤 unit 워커·리뷰어·수정자는 바뀐 규칙을 본다.
conventions_contract_content() {
  local rel="${CONVENTIONS_FILE#"$PROJECT_ROOT"/}" tree
  if [ -n "${CONVENTIONS_FILE:-}" ] && [ "$rel" != "$CONVENTIONS_FILE" ] && [ -f "$WORK_DIR/worker-baseline.tree" ] \
     && SCOPE_MANIFEST_OVERRIDE="" path_in_exact_feature_files "$rel" \
     && ! git -C "$PROJECT_ROOT" check-ignore -q -- "$rel" 2>/dev/null; then   # gitignore 된 파일은 기준선 tree 에 담기지 않는다 — '기준선에 없음'과 구별할 수 없으므로 예외를 적용하지 않는다
    tree="$(cat "$WORK_DIR/worker-baseline.tree")"
    git -C "$PROJECT_ROOT" cat-file -e "$tree:$rel" 2>/dev/null || return 1
    git -C "$PROJECT_ROOT" cat-file blob "$tree:$rel"
    return
  fi
  [ -f "${CONVENTIONS_FILE:-}" ] || return 1
  cat "$CONVENTIONS_FILE"
}
# 작업 트리의 conventions.md 가 계약 지문에 고정된 내용과 다른가 — 범위 안 conventions 를 이 피처가 바꾼 경우에만 참이다(범위 밖이면 두 내용이 같은 파일이다).
# 같은 세션을 잇는 워커 재개 턴이 최초 턴의 옛 [PROJECT CONVENTIONS] 블록 대신 현재 파일을 받게 하는 데 쓴다.
conventions_drifted_from_contract() {
  local a=ABSENT b=ABSENT
  if conventions_contract_content >/dev/null; then a="$(conventions_contract_content | sha256_stdin)" || return 1; fi
  if [ -f "${CONVENTIONS_FILE:-}" ]; then b="$(sha256_stdin < "$CONVENTIONS_FILE")" || return 1; fi
  [ "$a" != "$b" ]
}
# 프로젝트 conventions → NUL 구분 스트림 (지문 입력). 경로가 아니라 고정 라벨을 쓴다(내용만 지문에 들어간다).
# 없으면 고정 부재 표지만 낸다 — conventions 없는 프로젝트의 지문은 실행마다 같고, 파일이 생기거나(빈 파일 포함) 사라지면 달라진다.
consensus_conventions_stream() {
  if conventions_contract_content >/dev/null; then
    printf 'conventions:present\0'; conventions_contract_content; printf '\0'
  else printf 'conventions:absent\0'; fi
}
consensus_editable_fingerprint() { # design | impl
  { consensus_docs_for "$1" | while IFS= read -r file; do _fingerprint_files "$file"; done; } | sha256_stdin
}
consensus_upstream_fingerprint() { # design | impl
  {
    case "$1" in
      design) _fingerprint_files "$WORK_DIR/request.md";;
      impl) _fingerprint_files "$WORK_DIR/request.md" "$WORK_DIR/design.md";;
    esac
    consensus_user_decisions_for "$1"
    consensus_conventions_stream
  } | sha256_stdin
}
# PASS 지문: 합의된 '입력'이 여전히 같은지 확인하는 용도. request/design(/implementation/approach) 전체, worktree conventions.md 내용,
# decisions.md 중 이 target 범위의 사용자 정책 결정([USER-QUESTION][scope=…]) 줄만 — 이후 수정자·디자이너의 판정 기록이
# 쌓이거나 downstream 단계의 사용자 결정이 추가돼도 이전 PASS 가 불필요하게 무효화되지 않게 한다.
# decisions.md 전체를 넣지 않는다(합의 이력이 PASS 를 깨면 안 됨). 반대로 사용자 결정을 아예 빼지도 않는다 — 문서 변경 없이
# 검증자 요구를 기각한 결정이 합의 입력에서 빠지면 옛 PASS 가 그대로 재사용되는 다른 stale-cache 문제가 생긴다.
consensus_pass_fingerprint() { # design | impl
  {
    case "$1" in
      design) _fingerprint_files "$WORK_DIR/request.md" "$WORK_DIR/design.md";;
      impl) _fingerprint_files "$WORK_DIR/request.md" "$WORK_DIR/design.md" "$WORK_DIR/implementation.md" "$WORK_DIR/approach.md" "$WORK_DIR/feature-scope.json" "$WORK_DIR/implementation-units.json";;
    esac
    consensus_user_decisions_for "$1"
    consensus_conventions_stream
  } | sha256_stdin
}
# (impl PASS 지문에 feature-scope.json · implementation-units.json 원본을 넣는다 — 사용자가 범위나 구현 단위를 바꾸면 워커 재진입 전에 impl 재합의를 거치게 한다)
# 리뷰 JSON 내용 검증 — 체크포인트가 가리키는 파일이 존재한다는 것만으로 PASS/APPROVE 를 복원하지 않는다.
valid_spec_pass_review() { # review.json
  [ -f "$1" ] && jq -e --argjson v "$VALIDATOR_CONTRACT_VERSION" \
    '.schema_version==$v and .verdict=="PASS" and (.blocking_issues|length)==0' "$1" >/dev/null 2>&1
}
valid_impl_approve_review() { # review.json
  [ -f "$1" ] && jq -e --argjson v "$REVIEWER_CONTRACT_VERSION" \
    '.schema_version==$v and .verdict=="APPROVE" and (.issues|length)==0' "$1" >/dev/null 2>&1
}
# 현재 입력에 대해 유효한 합의 PASS 가 있는가: 체크포인트가 PASS 이고, 계약 버전·PASS 지문이 현재와 같고,
# 가리키는 리뷰 파일이 해당 round 의 실제 PASS 리뷰여야 한다. 러너의 stage 결정과 루프의 PASS 재사용이 함께 쓴다.
consensus_pass_current() { # design | impl
  local target="$1" checkpoint="$WORK_DIR/consensus-$1.json" review round
  [ -f "$checkpoint" ] || return 1
  jq -e --arg t "$target" --argjson v "$VALIDATOR_CONTRACT_VERSION" --argjson cv "$CONSENSUS_CHECKPOINT_VERSION" \
    '.version==$cv and .target==$t and .contract_version==$v and .next_step=="PASS"' "$checkpoint" >/dev/null 2>&1 || return 1
  [ "$(jq -r '.input_fingerprint // ""' "$checkpoint")" = "$(consensus_pass_fingerprint "$target")" ] || return 1
  review="$(jq -r '.review // ""' "$checkpoint")"
  round="$(jq -r '.round // 0' "$checkpoint")"
  [ "$review" = "$WORK_DIR/reviews/validator-$target-round-$(printf '%02d' "$round").json" ] || return 1
  valid_spec_pass_review "$review"
}
