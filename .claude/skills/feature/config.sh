#!/usr/bin/env bash
# =============================================================
# feature 파이프라인 설정
# 파일 경로: .claude/skills/feature/config.sh
# 사용자 설정 전용 — 런타임(헬퍼·계약/포맷 버전 상수·경로 초기화·설정 가드)은 scripts/lib/ 에 있고, scripts/lib/bootstrap.sh 가 이 파일을 읽는다.
# 런타임 함수(scripts/lib/ 모듈이 정의하는 이름 — render_prompt 등)의 정의와 런타임 상수(*_CONTRACT_VERSION·REVIEW_CHECKER_VERSION·*_CHECKPOINT_VERSION·PROJECT_ROOT·FEATURE_SKILL_DIR)를
# 여기 두지 않는다(로더가 거부한다 — scripts/lib/config-layout.sh). 설치·업데이트는 이 파일을 덮어쓰지 않는다. 이 파일은 0 으로 끝나야 한다(마지막 명령이 실패하면 로드가 멈춘다).
# 사용 전 반드시 모델 ID를 실제 환경에 맞게 채워 넣으세요.
#  - Claude 계열: claude 대화 세션에서 /model 로 확인
#  - Codex 계열: codex --help 또는 codex -m 후보 목록으로 확인
# =============================================================

# --- 역할별 모델 + reasoning effort ---
# 모델별 지원 effort가 다르므로 역할마다 함께 설정한다. 실제 허용 여부는 각 CLI가 검증한다.
# 어느 CLI 로 돌릴지는 모델 ID 로 정한다(claude* → claude, gpt-*/o*/codex* → codex). 아래 "역할 → CLI 라우팅" 참고.
# DESIGN_REVISION_MODEL: 검증자가 BLOCK 한 합의 문서(design/implementation/approach)를 수정하는 하위 실행(consensus-loop 의 DESIGNER 역할) 전용.
#   초안 작성은 interactive 오케스트레이터 세션이 직접 하며 그 모델은 이 설정으로 제어되지 않는다.
DESIGN_REVISION_MODEL="claude-fable-5-2"
DESIGNER_EFFORT="medium"
VALIDATOR_MODEL="gpt-6-astra"     # 명세 검증자
VALIDATOR_EFFORT="medium" # 게이트 모드(구현을 막을 최소 사유만 판정)지만 문서 주장을 직접 호출 경로·conventions 와 교차 확인하므로 low 로 내리지 않는다. 전체 보안·아키텍처 감사는 별도 수동 audit 에서만 high
VALIDATOR_PROFILE="guided"      # 판정 전략 오버레이(prompts/validator-overlays/<이름>.md). 명시 값이 모델별 기본값(validator_profile 헬퍼)보다 우선한다. 빈 값 = 모델별 기본값. compact | guided | conservative | none
WORKER_MODEL="claude-opus-5-5"       # 구현 담당
WORKER_EFFORT="medium"
REVIEWER_MODEL="gpt-5.6-sol"  # 구현 리뷰 담당
REVIEWER_EFFORT="high"
FIXER_MODEL="claude-sonnet-5-5"     # 리뷰 이슈 수정 담당
FIXER_EFFORT="high"

# --- CLI 실행 형식 ---
# Claude Code 비대화형 실행. 필요 시 --permission-mode 조정.
CLAUDE_BIN="claude"
CODEX_BIN="codex"

# --- 역할 → CLI 라우팅 ---
# 역할(디자이너/검증자/워커/리뷰어/수정자)은 고정이지만 어느 CLI 로 돌릴지는 모델 ID 로 정한다:
#   claude*                  → claude CLI (CLAUDE_BIN)
#   gpt-* | o[0-9]* | codex* → codex CLI (CODEX_BIN)
# 이름으로 정할 수 없는 모델은 아래에 claude|codex 를 직접 적는다(빈 값 = 모델 이름으로 자동 판정).
DESIGNER_CLI=""
VALIDATOR_CLI=""
WORKER_CLI=""
REVIEWER_CLI=""
FIXER_CLI=""

# --- Claude 모델의 실행 backend ---
# 모델 ID 가 claude* 인 역할을 무엇으로 실행할지. 역할이 아니라 모델이 정한다 — 다섯 역할 모두 같은 규칙이다.
#   native     : 현재 대화형 메인 Claude Code 세션의 네이티브 Agent(.claude/agents/feature-<역할>.md). Shell 은 요청을 발행하고 exit 42(NATIVE_AGENT_REQUIRED)로
#                돌아가며, 메인이 dispatch 한 뒤 같은 명령을 재실행하면 훅이 캡처한 원문 결과를 Shell 이 검증·수용한다(scripts/native-agent-bridge.sh).
#                `claude -p` 는 부르지 않는다. 실행 불가 시 CLI 로 자동 대체하지도 않는다.
#   legacy_cli : 종전의 `claude -p` 비대화형 실행(CLAUDE_BIN). 이미 `claude -p` 로 진행 중인 피처를 마칠 때와 CLI 어댑터 회귀에만 명시적으로 고른다.
# 기본값은 native 다. 이 줄이 없는 예전 config.sh 는 legacy_cli 로 동작한다(install 은 기존 config.sh 를 덮어쓰지 않는다).
# gpt-*/o*/codex* 모델은 이 값과 무관하게 codex CLI 다. native 에서는 모델 이름과 어긋나는 <ROLE>_CLI 재정의를 허용하지 않는다(명시적 오류).
# 진행 중인 피처의 세션(.session-*)은 backend 를 바꿔도 자동으로 옮겨 가지 않는다 — SESSION_CLI_MISMATCH / WORKER_SESSION_MISMATCH 로 멈춘다.
CLAUDE_BACKEND="native"

# --- Codex 모델의 실행 backend ---
# 모델 ID 가 gpt-*/o*/codex* 인 역할을 무엇으로 실행할지. 역할이 아니라 모델이 정한다 — 다섯 역할 모두 같은 규칙이다.
#   app_server  : 하네스가 로컬 `codex app-server`(stdio JSON-RPC)를 자식 프로세스로 직접 띄워 thread/turn 을 관리한다(scripts/codex-app-server.sh · .mjs).
#                 로컬 codex 바이너리(CODEX_BIN)와 기존 codex 인증·설정을 그대로 쓰고, 추가로 Node.js 18+ 가 필요하다(외부 패키지·daemon·네트워크 listener 없음).
#                 `codex exec` / `codex exec resume` 은 부르지 않는다. 실패해도 codex exec 로 자동 대체하지 않는다.
#   legacy_exec : 종전의 `codex exec` / `codex exec resume`. 이미 codex exec 로 진행 중인 피처를 마칠 때와 CLI 어댑터 회귀에만 명시적으로 고른다.
# 기본값은 app_server 다. 이 줄이 없는 예전 config.sh 는 legacy_exec 로 동작한다(install 은 기존 config.sh 를 덮어쓰지 않는다 — 전환은 이 줄을 직접 옮겨 적는 것이다).
# 진행 중인 피처의 세션(.session-*)은 backend 를 바꿔도 자동으로 옮겨 가지 않는다 — SESSION_BACKEND_MISMATCH / WORKER_SESSION_MISMATCH 로 멈춘다.
CODEX_BACKEND="app_server"
CODEX_APP_SERVER_NODE_BIN="${CODEX_APP_SERVER_NODE_BIN:-node}"               # Node.js 18+ 실행 파일
CODEX_APP_SERVER_RPC_TIMEOUT_SEC="${CODEX_APP_SERVER_RPC_TIMEOUT_SEC:-120}"   # initialize · thread/start · thread/resume · turn/start '응답' 대기 한도(초). turn/start 응답이 이 안에 없으면 불명(UNKNOWN)으로 멈춘다
CODEX_APP_SERVER_TURN_TIMEOUT_SEC="${CODEX_APP_SERVER_TURN_TIMEOUT_SEC:-0}"   # turn 완료 대기 한도(초). 0 = 한도 없음(codex exec 와 같다). 넘으면 재전송 없이 불명(UNKNOWN)으로 멈춘다
# 프로젝트에 맞게 고쳐 쓴 .codex/hooks/worker_guard.sh 를 직접 검토한 뒤 등록하는 지문(sha256, 공백으로 여러 개). 비워 두면 배포본 가드만 통과한다.
# 편집 역할의 필수 훅 게이트는 가드를 실행하지 않고 지문만 대조한다(references/codex-app-server.md). 이 줄이 없는 예전 config.sh 는 빈 값으로 동작한다.
CODEX_APP_GUARD_REVIEWED_SHA256="${CODEX_APP_GUARD_REVIEWED_SHA256:-}"


# --- 수렴/안전 한도 ---
MAX_SPEC_ROUNDS=1        # 명세 합의 최대 라운드
MAX_IMPL_ROUNDS=1        # 구현 리뷰-수정 라운드 (리뷰는 +1회 — 마지막 수정도 종결 검토). 1 = Reviewer 2 + Fixer 1, 첫 수정으로 안 풀리면 사용자에게
MAX_TEST_RETRIES=1       # 최종 테스트 실패 시 워커 재수정 허용 횟수
# Feature Worker 세션 교체 임계치(claude 라우팅 전용). 논리적 워커는 하나지만, unit 완료(targeted test PASS) 직후에
# 마지막 워커 invocation 의 '마지막 턴 실제 컨텍스트'(usage.jsonl 의 context_last_turn; 없으면 input_per_turn 근사)가 이 값 이상이면
# (input_effective 는 invocation 안 모든 model turn 의 누적 입력이라 컨텍스트 창 크기가 아니다 — 2026-10-27 매 unit 교체 사고)
# worker-handoff.json(스키마·계약 지문·git tree 검증)을 거쳐 다음 unit 부터 fresh CLI 세션으로 교체한다(scripts/worker-invoke.sh). claude·codex 모두.
# 교체 시점은 unit 경계뿐이고, 판단은 그 unit 에서 이 실행이 부른 마지막 워커 호출(units/<id>/last-usage-label)의 행만 쓴다.
# telemetry 가 없으면 임의 추정 없이 세션을 유지하며, 0 이면 교체하지 않는다. 기본 1,000,000 = 컨텍스트 창이 실제로 100만 토큰 수준일 때만.
WORKER_SESSION_ROTATE_INPUT_TOKENS="${WORKER_SESSION_ROTATE_INPUT_TOKENS:-1000000}"
# 창 크기(usage.jsonl 의 context_window)까지 관측되면 고정 임계치 대신 이 비율로 판단한다: context_last_turn / context_window ≥ 비율 → 다음 unit 부터 교체.
# 창 크기를 모르면 위 고정 임계치, 실측 자체가 없으면 input_per_turn 근사 + 고정 임계치(근사 사용은 로그에 남는다). 비활성은 위 값 0.
WORKER_SESSION_ROTATE_CONTEXT_RATIO="${WORKER_SESSION_ROTATE_CONTEXT_RATIO:-0.8}"

# --- 산출물 디렉터리 (저장소 루트 기준 상대 경로) ---
WORK_DIR=".agent-work"

# --- 프로젝트 명령 (저장소 루트에서 실행 기준, 프로젝트에 맞게 교체) ---
# 예: Gradle "./gradlew test" / pytest "venv/bin/pytest tests -q" / npm "npm test"
TEST_CMD="CHANGE_ME"
LINT_CMD="CHANGE_ME"
# 복잡도·중복·dead code 같은 정적 분석은 LINT_CMD 안에 프로젝트 도구로 구성한다(eslint/sonar, radon, detekt, clippy, knip, jscpd…).
# 스킬은 언어 독립이므로 자체 코드 검사를 갖지 않는다. 커버리지 % 임계치도 두지 않는다 — 숫자 채우기용 테스트를 유발한다.

# --- 프로젝트 빠른 검사 (선택) ---
# LLM 구현 리뷰어를 부르기 직전마다(첫 리뷰 전·수정자 뒤·재개·승인 재사용 전) 피처 worktree 루트에서 실행하는 결정론적 컨벤션 검사 명령.
# 명백한 위반에 리뷰 호출을 쓰지 않기 위한 것이고 TEST_CMD/LINT_CMD(리뷰 승인 뒤 전체 검증)를 대신하지 않는다 — 수 초~수십 초 안에 끝나는 검사만 둔다.
# 비어 있으면(또는 이 줄이 없는 기존 config.sh 면) 미설정 = 검사를 실행하지 않고 "생략" 으로만 로그에 남긴다.
# 계약: exit 0 = 정상, exit 1 = 규칙 위반(진단을 stdout/stderr 로 — 규칙·파일·위치·내용), 그 외·타임아웃 = 실행 오류. 읽기 전용(자동 수정·포매팅·git add 금지 — 실행 전후를 비교한다).
#       FAST_CHECK_CHANGED_FILES(이번 피처가 바꾼 파일 목록 파일 경로)·FAST_CHECK_ROOT 환경 변수를 준다. 기존 도구의 종료 코드가 다르면 프로젝트의 얇은 어댑터 스크립트로 맞춘다.
# 예: FAST_CHECK_CMD="scripts/convention-check.sh"   (상세: README '프로젝트 빠른 검사', references/pipeline-contracts.md)
# 진행 중인 피처가 있을 때 켜거나 끄지 않는다(워커 세션 계약에 포함된다 — WORKER_SESSION_MISMATCH).
FAST_CHECK_CMD=""
FAST_CHECK_TIMEOUT_SEC=120   # 제한 시간(초, 양의 정수). 넘으면 실행 오류(FAST_CHECK_ERROR/TIMEOUT)

# --- Unit 정적 검사 (선택) ---
# 구현 단위(unit)마다 워커 턴 뒤, 그 unit 의 targeted test 앞에서 실행하는 결정론적 검사 명령. 빠르고 국소적인 규칙만 둔다(변경 파일의 formatter 검사·lint·국소 규칙) —
# 전역 규칙·느린 검사는 위 FAST_CHECK_CMD(모든 unit 뒤 1회)에 두고, 같은 비싼 검사를 두 곳에 걸지 않는다. FAST_CHECK_CMD 를 unit 마다 자동으로 되풀이하지 않는다.
# 비어 있으면(또는 이 줄이 없는 기존 config.sh 면) 미설정 = 검사를 실행하지 않고 "생략" 으로만 로그에 남긴다(통과로 세지 않는다).
# 계약은 FAST_CHECK_CMD 와 같다: exit 0 = 정상, exit 1 = 규칙 위반(진단 출력 필수), 그 외·타임아웃 = 실행 오류, 읽기 전용(자동 수정·포매팅·git add 금지).
#       환경 변수 UNIT_CHECK_CHANGED_FILES(이 unit 이 바꾼 파일 목록 파일 — unit 시작 tree 대비, unit scope 안, 삭제 제외)·UNIT_CHECK_ROOT·UNIT_CHECK_UNIT_ID.
# 위반은 targeted test 실패와 같은 unit 수정 턴 1회로 함께 고친다(한도 MAX_TEST_RETRIES 공유). 실행 오류는 워커를 부르지 않고 사용자에게 돌아간다.
# 진행 중인 피처에서 명령을 켜거나 바꾸면: 이미 완료된 unit 은 워커 재호출 없이 새 명령으로 검사만 다시 돌고(위반이면 사용자에게), 남은 unit 은 새 명령을 따른다.
# 예: UNIT_CHECK_CMD="scripts/unit-check.sh"   (상세: README '검증 게이트', references/pipeline-contracts.md)
UNIT_CHECK_CMD=""
UNIT_CHECK_TIMEOUT_SEC=120   # 제한 시간(초, 양의 정수). 넘으면 실행 오류(UNIT_CHECK_ERROR/TIMEOUT)
# (선택) 검사가 읽는 규칙·설정 파일 중 **어느 unit 의 scope 안에 있는 것**을 공백으로 구분해 적는다(저장소 상대 경로 — 파일 또는 디렉터리, glob 없음).
# 완료 unit 의 검사 PASS 는 '그때의 규칙'에 묶여 재사용된다. 어느 unit 의 scope 에도 없는 파일과 위 명령이 가리키는 스크립트 파일은 자동으로 규칙 입력에 들어가지만,
# 이번 피처의 unit 이 직접 고치는 규칙 파일(예: 다른 unit 의 scope 에 든 lint 설정)은 하네스가 알 수 없다 — 여기 적어야 그 파일이 바뀔 때 완료 unit 을 다시 검사한다.
# 적은 경로가 작업 트리에 없으면(오타·gitignore) 워커를 부르기 전에 ENV_ERROR 로 멈춘다(첫 unit 이 만들 파일 — 그 unit 의 scope 안 — 만 그 unit 의 검사 때까지 유예).
# 비어 있으면(또는 줄이 없으면) 자동 포함분만 쓴다.
# 예: UNIT_CHECK_POLICY_PATHS="config/lint-rules.yml tools/checks"
UNIT_CHECK_POLICY_PATHS=""

# --- 검사 안내 문서 (선택) ---
# 워커가 코드를 쓰기 전에 '어떤 결정론적 검사가 언제 도는지'를 알도록, 러너는 워커 호출 직전에 위 설정(UNIT_CHECK_CMD · FAST_CHECK_CMD · UNIT_CHECK_POLICY_PATHS)만으로
# 작은 검사 계획(.agent-work/units/<id>/check-plan.json)을 만들어 경로와 요약을 프롬프트에 싣는다(검사 명령·모델 호출 0회 — 실제 검사는 종전 위치에서 그대로 다시 돈다).
# 검사 명령 문자열만으로는 규칙을 알 수 없다. 프로젝트가 검사 규칙을 사람이 읽을 문서로 정리해 두었으면 그 파일 하나의 **worktree 상대 경로**를 여기 적는다 —
# 본문을 프롬프트에 붙이지 않고 경로만 전달하며, 워커가 필요한 부분만 읽는다. 이 문서는 검사 판정을 대신하지 않는다.
# 적은 경로가 worktree 의 일반 파일이 아니면(오타·절대 경로·'..'·디렉터리·심볼릭 링크) 워커를 부르기 전에 ENV_ERROR 로 멈춘다.
# 비어 있으면(또는 이 줄이 없는 기존 config.sh 면) 미설정이다. 검사 두 개와 이 문서가 모두 미설정이면 검사 계획 자체를 만들지 않는다.
# 예: CHECK_GUIDE_FILE="docs/check-guide.md"
CHECK_GUIDE_FILE=""

# --- 위험도별 추가 검증 (선택) ---
# 리뷰 승인 뒤, 전체 TEST_CMD 앞에서 실행하는 프로젝트 명령 하나. 명령이 변경 내용(RISK_VERIFY_CHANGED_FILES)을 보고 위험도를 판정하고 그 위험도에 필요한
# 추가 검증(계약·보안·통합 테스트 등)을 직접 수행한다 — 위험도 규칙과 테스트 명령은 프로젝트가 소유하고 스킬에는 없다. 새 LLM 호출·리뷰어는 없다.
# 비어 있으면(또는 이 줄이 없는 기존 config.sh 면) 미설정 = 종전 그대로 리뷰 승인 → TEST_CMD.
# 계약: exit 0 = 통과(이때 $RISK_VERIFY_RESULT 파일에 {"risk_level":"LOW|MEDIUM|HIGH|CRITICAL|UNKNOWN","checks":[{"name":"…","status":"PASS"}],"reasons":["…"],"needs_human":false} 를 쓴다 —
#       risk_level 만 필수. 결과가 없거나 형식이 틀리면 실행 오류다: 위험도를 LOW 로 가정하지 않는다), exit 1 = 위반(진단 출력 필수 → 기존 worker-fix → 재리뷰 → 재검증,
#       한도 MAX_TEST_RETRIES 를 최종 테스트 수정과 공유), 그 외·타임아웃 = 실행 오류. risk_level=UNKNOWN 또는 needs_human=true 는 통과가 아니라 사용자 판단으로 돌아간다.
#       읽기 전용(소스·git index 변경 금지 — 산출물은 작업 트리 밖 임시 디렉터리에). TEST_CMD/FAST_CHECK_CMD 가 이미 돌리는 검사를 여기서 되풀이하지 않는다.
# 예: RISK_VERIFY_CMD="scripts/risk-verify.sh"   (상세: README '검증 게이트', references/pipeline-contracts.md)
RISK_VERIFY_CMD=""
RISK_VERIFY_TIMEOUT_SEC=600  # 제한 시간(초, 양의 정수). 넘으면 실행 오류(RISK_VERIFY_ERROR/TIMEOUT)

# --- ntfy 완료 푸시 알림 (선택) ---
# DONE(리뷰 승인 + 테스트·린트 통과, FINALIZED 아님) 기록 직후 1회 발송한다(scripts/notify-done.sh 의 notify_feature_done).
# OS 독립 — curl HTTP 호출 하나뿐이고 uname/OS 분기가 없다. 미설정이면 로그만 남기고 생략하며,
# 발송 실패도 DONE 결과(exit 0)를 바꾸지 않는다. 환경변수가 항상 우선이고 토픽·토큰을 저장소에 하드코딩하지 않는다.
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"   # self-host 서버면 교체
NTFY_TOPIC="${NTFY_TOPIC:-}"              # 구독 토픽. 비어 있으면 발송 생략
NTFY_TOKEN="${NTFY_TOKEN:-}"              # 보호 토픽 인증(선택). argv 가 아니라 curl --config(stdin)으로 전달돼 ps·로그에 남지 않는다
NTFY_TIMEOUT="${NTFY_TIMEOUT:-5}"         # HTTP 전체 타임아웃(초)
NTFY_CURL_BIN="${NTFY_CURL_BIN:-curl}"    # 테스트가 HTTP 클라이언트를 모킹할 때 교체

# --- 역할별 규칙 파일 ---
# 기본은 이 스킬이 설치된 프로젝트. 피처 전용 worktree 에서 돌 때는 러너가 FEATURE_PROJECT_ROOT 로 그 worktree 를 넘긴다 —
# 규칙 파일·conventions·프로젝트 로컬 워커 스킬을 원본이 아니라 snapshot 된 worktree 에서 읽어 실행 격리를 지킨다(하위 루프도 상속).
# PROJECT_ROOT·FEATURE_SKILL_DIR 은 로더가 이 파일보다 먼저 정한다(아래 경로 설정이 $PROJECT_ROOT 를 쓴다).
CORE_RULES_FILE="$PROJECT_ROOT/.claude/hooks/core_rules.md" # 워커 전용 필수 규칙
CONVENTIONS_FILE="$PROJECT_ROOT/conventions.md" # 선택 파일: 없으면 조용히 생략

# --- 워커에 주입하는 외부 스킬 ---
# 이름 목록(기본 없음). 탐색 순서: $PROJECT_ROOT/.claude/skills/<이름>/SKILL.md → .agents/skills/<이름>/SKILL.md (npx skills add 로 설치한 것).
# frontmatter 를 뗀 본문을 [WORKER SKILL: <이름>] 블록으로 core rules 뒤에 붙인다. 워커가 codex 면 Claude 스킬 로더가 없다.
# 목록에 있는데 어디에도 없으면 필수 동작 누락이므로 조용히 진행하지 않고 실패한다.
WORKER_SKILLS=()
