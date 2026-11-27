#!/usr/bin/env bash
# =============================================================
# .claude/skills/feature/scripts/lib/runtime.sh
# 계약·포맷 버전 상수, 런타임 계약 표식, JQ_PATH_DEFS, 프롬프트·규칙 로더, tree 스냅샷, sha256·index/worktree 지문, JSON Schema 검사.
# scripts/lib/bootstrap.sh 가 정해진 순서로 source 한다 — 직접 실행하지 않는다.
# (분리 전 config.sh 기준 70–131, 238–383, 888–927, 1769–1794)
# =============================================================

# --- 검증자 계약 버전 ---
# 검증자 프롬프트(공통 계약 prompts/validator-review-*.md 와 오버레이 prompts/validator-overlays/*.md 모두)·spec-review 스키마·러너의 연계 검사 중 하나라도 바뀌면 올린다.
# 러너는 이 값과 다른 이전 PASS 파일을 무효로 보고 검증 라운드를 다시 돈다(--new 불필요).
# 13: implementation.md+approach.md 를 코드 사양서로 판정 — CODE_SPEC_GAP(문서가 두 가지 이상의 non-trivial 코드 구조를 허용) 추가, DELEGATED 는 formatter/import/compiler 세부와 저장소 단일 표현뿐.
# 15: 검증 대상을 production diff 동일성 → material decision 으로 되돌림. CODE_SPEC_GAP 은 material 구현 계약 하나가 열린 경우만(일곱 입장 조건 + "무엇이 달라지는가" gate), helper/local naming/intermediate/if·switch/for·stream/동등 overload/bounded local collection 은 워커 소유 local expression. REUSE_DISCOVERY_GAP 은 새 responsibility boundary 에만(feature-local DTO/entity/private helper 제외). "두 워커 다른 diff" 기준 폐기.
# 16: 판정 격리 — 검증자는 호출마다 fresh 세션, 종결 검토 입력은 직전 blocker 의 구조화된 주장·증거(prev-blockers-*.json — why_blocks_now 제외)와 decisions.md 를 뺀 문서 diff 뿐. [round N] ACCEPT/REJECT 이력은 판정 입력이 아니며 "REJECT 된 이슈 재제기 금지" 는 폐기(검증자가 독립 재판정, 불일치는 DEADLOCK 으로 사용자에게).
# 17: 검증자 입력에서 decisions.md 원본을 뺐다 — 러너가 추린 확정 사용자 결정 파일(reviews/user-decisions-<target>.md, [USER-QUESTION][scope=…] 줄만)을 준다. v16 실모델에서 검증자가 decisions.md 의 REJECT 사유를 읽고 추론에 쓴 것이 관측됨.
# 18: validator-review-impl.md 1행에 ${PROJECT_CONVENTIONS} 추가 — design 검증자만 conventions.md 본문을 받고 impl 검증자는 받지 못하던 누락 수정(consensus-loop 는 두 검증자 모두에 인자 "" 를 넘기고 프롬프트 본문 렌더링에만 의존한다). 루프 start-up 에서 플레이스홀더 부재를 fail-closed 로 검사.
# 19: 문서 주장의 독립 교차 검증 — ① 명시적 conventions 규칙과 직접 충돌하는 문서 결정은 동작이 같아도 DIRECT_MISMATCH ② request·확정 사용자 결정·기존 필수 계약에 근거 없는 신규 제품 동작 ③ 문서가 변경 대상으로 지정한 함수·쿼리·서비스의 직접 호출부·피호출부 확인(누락으로 명시 계약 위반·구현 불가일 때만) ④ NEW 탐색 근거가 직접 범위 코드와 사실로 어긋나면 REUSE_DISCOVERY_GAP. category·스키마 필드는 그대로(schema_version 만 19). 탐색 범위는 여전히 변경 대상 + 직접 의존.
# 20: 사용자 결정의 scope 는 '발생 단계'가 아니라 '처음 영향을 주는 단계'다 — 요구·외부 동작·설계에 영향을 주는 결정은 어느 단계에서 나왔어도 scope=design(design·impl 검증자 모두 본다),
#     구현 수단만 정한 결정은 scope=impl(impl 검증자만). request.md 의 `## 요구 변경/추가` 절(시간순 append)과 scope=design 결정이 함께 있을 때만, 그 항목이 명시한 범위에서
#     뒤 요구가 옛 요구를 대체한다(범위 밖은 원 요구 유지, 문서 소유자의 주장만으로는 대체되지 않는다). 두 검증자 프롬프트가 같은 출처 우선순위를 쓴다.
#     검증자에게 주는 결정 파일과 PASS/upstream 지문은 같은 함수(consensus_user_decision_lines)의 출력이다. 지문 계산 의미·체크포인트 포맷은 그대로라 CONSENSUS_CHECKPOINT_VERSION 은 올리지 않는다.
# 21: 교차 검증 ⑤ 기존 계산·판단 결과의 재사용 — approach.md 가 REQUIRED 로 새로 수행하게 한 판단과 같은 의미의 결과를 변경 대상의 직접 호출부·피호출부가 이미 반환·전달하고,
#     그 반복이 적용되는 명시 convention(Memoization 류)·명시된 재사용/비용 계약·직접 건드리는 기존 코드의 책임 계약과 직접 충돌할 때만 기존 category
#     (REQUIREMENT_CONTRADICTION / DIRECT_MISMATCH, code_refs = 기존 생산·전달 경로)로 막는다. 새 category·스키마 필드·라운드 없음(schema_version 만 21).
#     디자이너 수용 기준(designer-revise-impl/-design)에 적용 가능한 명시 convention·직접 변경하는 기존 코드 계약을 포함 — 요구 문서에 반복되지 않았다는 이유만으로 REJECT 하지 않는다.
# 22: 교차 검증 ① 을 결정 단위 대조로 명시 — REQUIRED 결정·제어 흐름 절·계약을 하나씩 적용 규칙과 맞춰 보고, 대조 대상에 책임 배치·이름과 종류·상태/흐름 제어 방식·
#     '같은 형태로 따르라' 고 인용한 참조 구현의 줄 범위(범위 안 코드가 명시 규칙을 어기면 그 인용 결정이 충돌)를 포함한다. 설계 원칙 형태의 명시 규칙도 대상.
#     컨벤션을 어긴 REQUIRED 결정 여러 건이 PASS 된 실제 실행에 대한 대응. 새 category·스키마 필드·라운드 없음(schema_version 만 22). 회귀 사례 35~37.
VALIDATOR_CONTRACT_VERSION=22

# --- 리뷰어 계약 버전 ---
# 리뷰어 프롬프트·수정자 프롬프트·impl-review 스키마·impl-review-loop 의 연계 검사 중 하나라도 바뀌면 올린다.
# 루프는 리뷰 JSON 의 schema_version 이 이 값과 다르면 응답 오류로 중단한다.
# 10: 프로젝트 컨벤션(conventions.md) 명시 규칙 위반을 CONTRACT_VIOLATION 으로 검사 — 리뷰어·수정자 프롬프트에 CONVENTIONS_FILE 경로 전달.
# 11: code-spec 수준 REQUIRED(호출 순서·helper 분해·naming·local 구조·reference pattern) 이탈을 동작이 같아도 CONTRACT_VIOLATION 으로 검사. 제외는 formatter/import/compiler 세부뿐.
# 14: DOC_GAP issue 에 user_question(비어 있지 않음)·options(≥2) 필수, FIX_CODE 는 둘 다 빈 값 — 리뷰어 DOC_GAP 은 impl 재합의가 아니라 사용자 결정으로 간다(doc-gap-resume.json).
# 15: CONTRACT_VIOLATION/UNDECIDED_APPROACH 를 material 계약(책임 배치·재사용·호출 횟수·상태 순서·transaction/lock/retry/cache·public 계약·명시 convention)으로 한정. helper/local naming/intermediate/if·switch/for·stream/동등 overload/bounded local collection/반환 직전 alias 는 문서가 적어 두었어도 issue 아님. REDUNDANT_CODE 에 문서가 요구하지 않은 standalone abstraction(outcome/context/kind 등) 추가. 수정자는 material contract 만 복구.
# 16: fix_ref 정의를 프롬프트·스키마·루프 검사에서 하나로 통일(REVIEW_FIX_REF_RULE) — 수정 후 소스 파일 경로:L시작-L끝, 패치 파일(fix-diff-round-N.patch) 경로·행 번호 금지,
#     실제 변경 파일 + 새 버전 hunk 교차를 git tree 로 검사. origin 별 필드(ROUND_1 / UNRESOLVED_PREVIOUS / FIX_REGRESSION·NEWLY_EXPOSED_BY_FIX)를 명시.
#     출력 계약 위반은 ENV_ERROR 가 아니라 REVIEW_OUTPUT_INVALID(reviews/invalid-review.json, 구조화 진단, 재실행 모델 0회)다.
# 리뷰어에게 주는 지시(프롬프트·스키마)가 그대로이고 루프 검사기의 버그만 고친 경우에는 올리지 않는다 — 그래야 저장된 REVIEW_OUTPUT_INVALID 출력을
# 고친 검사기로 로컬 재검증(모델 0회)할 수 있다. 지시가 바뀌면 올리고, 그때 저장된 출력은 옛 계약의 것이므로 명시적 새 리뷰 시도가 필요하다.
# 검사기만 고친 경우에는 대신 아래 REVIEW_CHECKER_VERSION 을 올린다 — 올리지 않으면 옛 검사기가 통과시킨 APPROVE 가 재검증 없이 재사용된다.
# 17: 컨벤션 검사 기준에 '기존 계산·판단 결과의 재사용'(Memoization 류)을 추가 — 판정은 실제 데이터 흐름(생산자 → 반환값 → 소비자)이며 문서가 재계산을 지시했어도 통과시키지 않는다.
#     규칙과 구현 문서가 충돌할 때의 DOC_GAP 은 디자이너 재합의가 아니라 사용자 에스컬레이션이라고 설명을 바로잡음. 일반적인 중복 local 연산은 대상이 아니다. 스키마·검사기는 그대로.
REVIEWER_CONTRACT_VERSION=17
# 루프 검사기(impl-review-loop.sh validate_review_output + 아래 review_fix_ref_* )의 버전 — 리뷰어 계약 버전과 목적이 다르다.
#   REVIEWER_CONTRACT_VERSION : 리뷰어에게 주는 지시(프롬프트·스키마). 바뀌면 저장된 출력은 옛 계약의 것 → 새 리뷰.
#   REVIEW_CHECKER_VERSION    : 같은 지시에 대한 러너의 결정론적 검사. 검사기만 고쳤으면 이것만 올린다 → 저장된 출력(무효 기록 **과 승인 캐시 모두**)을
#                               새 검사기로 로컬 재검증한다(모델 0회). 리뷰 입력 지문에는 넣지 않는다(넣으면 무효 출력의 로컬 재검증이 불가능해진다).
#   REVIEW_CHECKPOINT_VERSION : review-impl.json 필드·지문의 의미(아래).
# 승인 체크포인트는 자신을 통과시킨 검사기 버전(checker_version)을 든다 — 현재 값과 다르면 그 APPROVE 를 그대로 믿지 않고 리뷰 루프가 저장된 출력을 재검증한 뒤에만 재사용한다.
# 2: hunk 없는 변경(binary·파일 mode 만)을 가리킨 fix_ref 를 거부(전에는 임의의 줄 번호가 통과).
# 3: 스키마(schemas/impl-review.schema.json)의 required·enum·minItems·minLength·additionalProperties 를 실제로 검사(json_schema_violations).
#    전에는 일부 필드의 타입만 봐서 필드 누락·enum 밖 origin·빈 code_refs 가 통과했다.
# 4: DOC_GAP issue 의 code_refs 를 전부 검사(DOC_GAP_CODE_REF_PATH) — 줄 범위를 떼고 선행 "./" 만 정규화한 결과가 저장소 상대 파일 경로(plain_file_path)이고
#    실제 파일(또는 이 피처가 만들 수 있는 경로)이어야 한다. 전에는 gap 기록(doc_gap_record_review)이 비정규 ref 만 조용히 버려, 일부만 비정규인 리뷰는
#    남은 경로만으로 unit 에 연결되고(paths 가 있으므로 legacy 해석으로도 돌아가지 않는다) 빠진 파일의 unit 은 gap 해결로 인정받지 못했다.
REVIEW_CHECKER_VERSION=4

# --- 체크포인트 포맷 버전 ---
# consensus-<target>.json / review-impl.json 의 필드·지문 '의미'가 바뀌면 올린다(계약 버전과 별개).
# 로더는 버전이 다르면 저장된 지문을 해석하지 않고 안전하게 처음(Round 1 / 새 attempt)으로 돌아간다 —
# 다른 의미의 지문을 비교해 "부분 실행"으로 오판하고 단계를 건너뛰는 것을 막는다.
# consensus 4: upstream·PASS 지문에 worktree conventions.md 내용 포함(없으면 고정 부재 표지) — conventions 가 바뀌면 이전 design·impl PASS 를 재사용하지 않는다.
CONSENSUS_CHECKPOINT_VERSION=4
# review 3: next_step 에 REVIEW_OUTPUT_INVALID 추가(리뷰어 출력 계약 위반 — reviews/invalid-review.json 이 진단·입력 지문을 든다).
# review 4: APPROVE 체크포인트가 contract_docs_sha256(승인 당시 계약 문서 + 사용자 결정 줄 + conventions.md 내용 지문)을 들고, 승인 재사용이 그 값을 현재와 대조한다.
#           옛 포맷(3 이하)의 체크포인트는 그 지문이 없거나 의미가 달라 해석하지 않는다 — 새 attempt 로 Round 1 부터 리뷰한다.
REVIEW_CHECKPOINT_VERSION=4

# --- 런타임 계약 표식 (사용자 설정이 아니다 — 고치지 않는다) ---
# 이 값은 scripts/ 안 런타임 본문(scripts/lib/)의 세대다. feature-run.sh 의 REQUIRED_RUNTIME_CONTRACT_VERSION 이 같은 scripts/ 의 이 값과 대조해 서로 다른 버전의 scripts/ 가 섞인 설치를 멈춘다.
# config.sh 는 사용자 설정 전용이라 이 값을 갖지 않는다(로더가 거부한다). 헬퍼 '이름'이 같다는 사실은 본문이 호환된다는 증거가 아니다.
# 아래 헬퍼의 동작·출력 형식·체크포인트 필드 가운데 scripts/·schemas/·prompts/ 가 의존하는 것을 바꾸면 이 값을 올린다.
# 1: DOC_GAP 구조화 경로(undecided[].paths·gap paths)·legacy 위치 해석·WAITING_USER 수리 사전 검사(doc_gap_repair_preflight).
# 2: 모델 기준 backend 라우팅(role_backend — claude_native / claude_cli / codex_cli)과 native Agent 인계(scripts/native-agent-bridge.sh, exit 42/43).
# 3: Codex 모델의 backend 분기(role_backend — codex_app_server 추가, CODEX_BACKEND)와 Codex App Server 런타임(scripts/codex-app-server.sh · .mjs) 위임,
#    세션 원장의 backend 표식(.session-<key>.codex.json 의 backend — 없으면 legacy_exec)·SESSION_BACKEND_MISMATCH.
FEATURE_RUNTIME_CONTRACT_VERSION=3

# --- 저장소 상대 경로 공용 규칙 (jq 정의) ---
# feature-scope / implementation-units 의 scope 경로, 워커 undecided[].paths, DOC_GAP 체크포인트의 paths 가 전부 이 정의를 쓴다(두 번째 경로 검사기를 만들지 않는다).
#   canonical_path    : 저장소 상대, 선행 "/"·"./" 금지, 빈·"."·".." 세그먼트 금지(따라서 후행 "/" = 디렉터리 표기도 거부)
#   plain_file_path   : canonical_path 이면서 glob 문자(* ?)가 없다 — 파일 하나를 가리키는 경로
#   strip_line_ranges : 끝의 ":L10-L20" / ":L10-L20,L30-L40" 줄 범위만 뗀다. 문자열 **끝**에 그 형식이 있을 때만이다 — 경로 안의 ":" 를 첫 위치에서 자르지 않는다
#   code_ref_path     : 리뷰 issue 의 code_ref("파일:L시작-L끝") → 경로. 줄 범위를 떼고 선행 "./" 만 뗀다(뜻이 하나뿐인 정규화). 그 밖의 비정규 형태(절대경로·".."·glob·
#                       디렉터리 표기)는 고치지 않는다 — 결과가 plain_file_path 가 아니면 리뷰 출력 검사(DOC_GAP_CODE_REF_PATH)가 체크포인트 생성 전에 거부한다
JQ_PATH_DEFS='
  def canonical_path: type=="string" and length>0 and (startswith("/")|not) and (startswith("./")|not)
    and (split("/") | all(.[]; . != "" and . != "." and . != ".."));
  def plain_file_path: canonical_path and (test("[*?]")|not);
  def strip_line_ranges: sub(":L?[0-9]+(-L?[0-9]+)?(,L?[0-9]+(-L?[0-9]+)?)*$"; "");
  def code_ref_path: strip_line_ranges | sub("^(\\./)+"; "");
'

# 페르소나 템플릿(prompts/*.md) 렌더링. 지정한 변수만 치환해 본문의 다른 $ 문자를 보존한다.
# 사용: VAR1=... VAR2=... render_prompt <템플릿 파일> '${VAR1} ${VAR2}'
render_prompt() {
  envsubst "$2" < "$1"
}

# 검증자 판정 전략 프로필. VALIDATOR_PROFILE 이 비어 있으면 VALIDATOR_MODEL 로 기본값을 고른다.
# 프로필은 모델 ID 가 아니라 전략 이름(compact/guided/conservative)이라, 모델이 바뀌어도 여기 매핑 한 줄만 고친다.
# 매핑은 정확한 모델 ID 만 본다 — 여기 없는 모델은 conservative 다. 위 VALIDATOR_MODEL 기본값은 반드시 이 매핑에 있어야 하고(없으면 의도치 않게 conservative),
# 그 매핑 값은 명시 VALIDATOR_PROFILE 과 같아야 한다(tests/install-smoke.sh 가 둘의 일치를 검사한다).
# 공통 계약(관할·탐색 범위·BLOCK/ASK_USER 입장 조건·스키마)은 validator-review-*.md 한 곳에만 있고 오버레이는 "그 계약을 어떤 순서로 판정할지"만 담는다.
validator_profile() {
  if [ -n "${VALIDATOR_PROFILE:-}" ]; then printf '%s' "$VALIDATOR_PROFILE"; return 0; fi
  case "${VALIDATOR_MODEL:-}" in
    gpt-6-sol)   printf 'compact' ;;
    gpt-5.6-sol)   printf 'compact' ;;
    gpt-6-astra)   printf 'guided' ;;
    gpt-6.2-astra) printf 'guided' ;;
    *)             printf 'conservative' ;;
  esac
}

# 오버레이 본문을 [VALIDATOR PROFILE: <이름>] 블록으로 출력한다. 검증자 task prompt 뒤에 붙인다(system prompt 가 아니다 — 정체성이 아니라 실행 힌트).
# 프로필 none 이면 아무것도 출력하지 않는다. 이름이 있는데 파일이 없으면 조용히 생략하지 않고 실패한다(오타로 전략이 빠진 채 유료 호출을 막는다).
load_validator_overlay() {
  local profile file
  profile="$(validator_profile)"
  [ "$profile" = none ] && return 0
  file="$FEATURE_SKILL_DIR/prompts/validator-overlays/$profile.md"
  [ -f "$file" ] || { echo "[FAIL] 검증자 프로필 '$profile' 의 오버레이 없음: $file — config.sh VALIDATOR_PROFILE 또는 validator_profile 매핑 확인" >&2; return 1; }
  printf '\n\n[VALIDATOR PROFILE: %s]\n' "$profile"
  cat "$file"
}

# 프로젝트 conventions는 모든 역할에 전달하되 없으면 아무것도 출력하지 않는다.
load_project_conventions() {
  [ -f "$CONVENTIONS_FILE" ] || return 0
  printf '[PROJECT CONVENTIONS]\n'
  cat "$CONVENTIONS_FILE"
}

# core_rules.md는 워커에게만 전달한다. 선택 conventions가 있으면 뒤에 덧붙인다.
# contract: 워커 세션 계약 지문용 — conventions 는 conventions_contract_content(피처 범위 안 산출물이면 워커 기준선 내용)를 쓴다.
#           프롬프트에 싣는 본문(인자 없음)은 항상 작업 트리의 현재 파일이다.
load_worker_rules() { # [contract]
  printf '[CORE RULES]\n'
  cat "$CORE_RULES_FILE"
  if [ "${1:-}" = contract ]; then
    if conventions_contract_content >/dev/null; then
      printf '\n\n[PROJECT CONVENTIONS]\n'
      conventions_contract_content
    fi
  elif [ -f "$CONVENTIONS_FILE" ]; then
    printf '\n\n[PROJECT CONVENTIONS]\n'
    cat "$CONVENTIONS_FILE"
  fi
  load_worker_skills
}

# WORKER_SKILLS 의 SKILL.md 본문(frontmatter 제외)을 워커 프롬프트에 붙인다.
worker_skill_file() { # name → 경로 (없으면 빈 출력)
  local d
  for d in "$PROJECT_ROOT/.claude/skills/$1" "$PROJECT_ROOT/.agents/skills/$1"; do
    [ -f "$d/SKILL.md" ] && { printf '%s' "$d/SKILL.md"; return 0; }
  done
  return 1
}
strip_frontmatter() { awk 'NR==1 && $0=="---" {infm=1; next} infm && $0=="---" {infm=0; next} !infm' "$1"; }
load_worker_skills() {
  local name file
  [ "${#WORKER_SKILLS[@]}" -gt 0 ] || return 0
  for name in "${WORKER_SKILLS[@]}"; do
    file="$(worker_skill_file "$name")" || { echo "[FAIL] 필수 워커 스킬 '$name' 없음 — .claude/skills/, .agents/skills/ 어디에도 SKILL.md 가 없다. npx skills add 로 설치하거나 config.sh WORKER_SKILLS 에서 제거" >&2; return 1; }
    printf '\n\n[WORKER SKILL: %s]\n' "$name"
    strip_frontmatter "$file"
  done
}

# approach.md 가 백틱으로 인용한 참조 구현 `path:L40-L68` 의 해당 줄 범위만 워커 프롬프트에 붙인다.
# "가서 읽어라"는 codex 비대화형 실행에서 자주 무시되므로 러너가 결정론적으로 눈앞에 둔다.
# 심볼 탐색은 언어 종속이라 하지 않는다 — 줄 범위가 없는 인용은 붙이지 않는다(검증자가 범위를 요구한다).
# 참조당 REF_MAX_LINES 줄, 총 REF_MAX_REFS 개까지.
REF_MAX_REFS="${REF_MAX_REFS:-8}"
REF_MAX_LINES="${REF_MAX_LINES:-100}"
load_reference_code() {
  local approach="$WORK_DIR/approach.md" count=0 ref path from to
  [ -f "$approach" ] || return 0
  grep -oE '`[A-Za-z0-9_./-]+:L[0-9]+-L[0-9]+`' "$approach" | tr -d '`' | sort -u \
    | while IFS= read -r ref; do
        path="${ref%%:L*}"; from="${ref##*:L}"; from="${from%%-L*}"; to="${ref##*-L}"
        [ -f "$path" ] || continue
        [ "$count" -ge "$REF_MAX_REFS" ] && { printf '\n[REFERENCE CODE 생략: 참조 %d개 초과]\n' "$REF_MAX_REFS"; break; }
        [ "$count" -eq 0 ] && printf '[REFERENCE CODE — approach.md 가 인용한 기존 코드. REQUIRED 동작·구조·재사용 계약 확인용]\n'
        count=$((count + 1))
        if [ $((to - from + 1)) -gt "$REF_MAX_LINES" ]; then to=$((from + REF_MAX_LINES - 1)); fi
        printf '\n--- %s:L%d-L%d ---\n' "$path" "$from" "$to"
        sed -n "${from},${to}p" "$path"
      done
  return 0
}

# 작업 트리(WORK_DIR 제외, gitignore 적용)를 git tree 객체로 기록해 SHA 를 출력한다.
# 커밋·실제 index 를 건드리지 않고(임시 index) untracked 신규 파일까지 담는다.
# 용도: 워커 진입 직전 기준선(worker-baseline.tree — 이번 작업이 만든 변경만 리뷰·원복 대상으로 삼는다),
#       리뷰 라운드별 스냅샷(수정자가 실제로 바꾼 diff).
snapshot_worktree_tree() {
  # 임시 index 는 프로세스별 이름 — 같은 트리에서 두 실행(예: 두 피처의 worktree 부트스트랩)이 동시에 스냅샷해도 서로 덮어쓰지 않는다
  local idx; idx="$(cd "$WORK_DIR" && pwd)/.snapshot-index.${BASHPID:-$$}"   # $$ 는 subshell 에서 부모와 같다 — BASHPID 로 구분
  rm -f "$idx"
  if git rev-parse --verify -q HEAD >/dev/null; then
    GIT_INDEX_FILE="$idx" git read-tree HEAD || return 1
  else
    GIT_INDEX_FILE="$idx" git read-tree --empty || return 1   # 커밋이 없는 저장소: 빈 tree 에서 시작
  fi
  # pathspec 으로 WORK_DIR 를 빼면 gitignore 된 경우 git 이 "ignored path" 힌트와 함께 실패한다 — 전부 담은 뒤 index 에서만 뺀다
  GIT_INDEX_FILE="$idx" git add -A >/dev/null || return 1
  GIT_INDEX_FILE="$idx" git rm -r -q --cached --ignore-unmatch -- "$WORK_DIR" >/dev/null || return 1
  GIT_INDEX_FILE="$idx" git write-tree || return 1
  rm -f "$idx"
}

# SHA-256 해시 (Linux sha256sum / macOS shasum 겸용)
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# git index 지문. 워커·수정자 호출 전후로 비교해 staged/unstaged 상태가 바뀌었으면 자동 복구 없이 중단한다
# (사용자의 staged 상태를 파이프라인이 해석하지 않는다). 정규식 훅이 놓치는 index 명령까지 결과 기준으로 잡는다.
compute_index_fingerprint() {
  # -v: assume-unchanged(소문자 태그)·skip-worktree(S) 같은 index 플래그까지 지문에 포함 — 변경 파일을 status 에서 숨기는 우회를 막는다
  git ls-files --stage -v -z | sha256_stdin
}

# 작업 트리 지문: tracked diff + status(-uall) + untracked 파일 '내용'까지 해시.
# git diff HEAD 만으로는 untracked 파일이, status 만으로는 untracked 내용 변경이
# 빠지므로 셋을 함께 묶어야 "승인 이후 어떤 변경도 없었다"를 보장할 수 있다.
# $WORK_DIR 는 제외 — 파이프라인 산출물(state.json, 리뷰, 지문 파일 자신)은
# 코드 변경이 아니며, gitignore 되지 않은 환경에서 지문이 자기참조되는 것을 막는다.
compute_worktree_fingerprint() {
  {
    git diff --binary HEAD -- . ":(exclude)$WORK_DIR"
    git status --porcelain=v1 -uall -- . ":(exclude)$WORK_DIR"
    git ls-files --others --exclude-standard -z -- . ":(exclude)$WORK_DIR" \
      | while IFS= read -r -d '' untracked_file; do
          if [ -L "$untracked_file" ]; then
            # 심볼릭 링크는 대상 내용이 아니라 '가리키는 경로'를 해시한다
            # (깨진 링크 실패 방지 + 같은 내용의 다른 대상으로 바꿔치기 감지)
            printf 'symlink %s ' "$untracked_file"
            readlink "$untracked_file" | sha256_stdin
          else
            printf '%s ' "$untracked_file"
            sha256_stdin < "$untracked_file"
          fi
        done
  } | sha256_stdin
}

# ---------- JSON Schema 검사 (모델 출력의 구조 검증 — 조건부 필드 규칙과 분리) ----------
# schema-file 로 json-file 을 검사해 위반 배열 [{path, observed, expected}] 을 낸다(통과면 []). 반환 1 = 실행 실패(JSON 파싱 불가 등).
# 지원 keyword: type(object|array|string|integer|number|boolean) · properties · required · additionalProperties:false · enum · minItems · minLength · items.
# 이 저장소의 스키마가 쓰는 keyword 전부다 — 스키마에 다른 keyword(oneOf·pattern 등)를 추가하면 여기에도 추가한다(조용히 무시되는 검사를 만들지 않는다).
json_schema_violations() { # schema-file json-file
  jq -c --slurpfile schema "$1" '
    def typeok($t): if $t=="object" then type=="object" elif $t=="array" then type=="array" elif $t=="string" then type=="string"
      elif $t=="integer" then (type=="number" and . == floor) elif $t=="number" then type=="number" elif $t=="boolean" then type=="boolean" else true end;
    def v($s; $p): . as $d
      | if ($s.type != null) and ($d | typeok($s.type) | not) then [{path:$p, observed:("type " + ($d|type)), expected:("type " + $s.type)}]
        else
          (if ($s.enum != null) and (any($s.enum[]; . == $d) | not) then [{path:$p, observed:($d|tojson), expected:("enum " + ($s.enum|tojson))}] else [] end)
          + (if ($d|type)=="string" and ($s.minLength != null) and ($d|length) < $s.minLength then [{path:$p, observed:("length " + ($d|length|tostring)), expected:("minLength " + ($s.minLength|tostring))}] else [] end)
          + (if ($d|type)=="array" then
               (if ($s.minItems != null) and ($d|length) < $s.minItems then [{path:$p, observed:("items " + ($d|length|tostring)), expected:("minItems " + ($s.minItems|tostring))}] else [] end)
               + (if $s.items != null then ([range(0; $d|length) as $i | ($d[$i] | v($s.items; $p + "[" + ($i|tostring) + "]"))] | add // []) else [] end)
             else [] end)
          + (if ($d|type)=="object" then
               [($s.required // [])[] | select(. as $k | $d | has($k) | not) | {path:($p + "." + .), observed:"missing", expected:"required field"}]
               + (if $s.additionalProperties == false then [$d | keys[] | select(. as $k | ($s.properties // {}) | has($k) | not) | {path:($p + "." + .), observed:"unexpected field", expected:"additionalProperties false"}] else [] end)
               + ([($s.properties // {}) | to_entries[] | . as $e | select($d | has($e.key)) | ($d[$e.key] | v($e.value; $p + "." + $e.key))] | add // [])
             else [] end)
        end;
    v($schema[0]; "$")' "$2"
}
