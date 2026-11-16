# Phase 0 — 초기화 + 설계 문서 작성

> feature 스킬 참조 문서(`SKILL.md` 에서 분리한 원문). 읽는 시점: 피처 최초 진입, `NEED_DOCS(DESIGN_MISSING)` 반환 직후, 그리고 request.md·design.md 를 쓰거나 고치기 직전. 아래 "구현 문서 작성" 은 `references/impl-docs.md` 다.

## 사전 조건

1. `config.sh`의 역할별 `*_MODEL`·`*_EFFORT`·`TEST_CMD`·`LINT_CMD`가 실제 환경과 일치. 빈 값이나 `CHANGE_ME`가 남으면 가드가 실행 거부. 이 interactive 오케스트레이터 세션(초안 design/implementation/approach 작성)의 모델은 `config.sh` 로 제어되지 않는다 — `DESIGN_REVISION_MODEL` 은 검증자가 BLOCK 한 합의 문서를 고치는 하위 실행(child DESIGNER)에만 쓰인다.
2. `claude`, `codex`, `jq`, `uuidgen`, `envsubst` 설치·로그인.
3. 저장소 루트에서 실행. `.agent-work/`는 `.gitignore`에 등록돼 있다.

## Phase 0 — 초기화 + 문서 작성 (오케스트레이터)

1. **피처 식별자를 정하고 러너를 `--feature <id>` 로 한 번 실행해 전용 worktree 를 먼저 확정한다.** id 는 영숫자·`._-`(예: `018`, `order-cancel`). 러너가 branch `feature/<id>` 와 worktree `<저장소 옆>/<repo>-feature-<id>` 를 id 로 결정론적으로 정하고, 없으면 원본 working tree 의 현재 상태(미커밋 tracked 변경·untracked 파일 포함, gitignore
   파일·`.agent-work` 제외)를 bootstrap 커밋 없이 snapshot tree 로 옮겨 만든다. 원본의 branch/HEAD/index/working tree 는 읽기만 한다. 이후 `request.md`·`design.md`·`implementation.md`·`approach.md`·`feature-scope.json`·`.agent-work`(리뷰·세션·로그)·워커·리뷰어·수정자는 전부 **그 worktree 안에서만** 다룬다.
   첫 실행은 `design.md`가 없으므로 `NEED_DOCS(DESIGN_MISSING)`(exit 3)로 즉시 돌아온다 — 정상이며, 로그의 `피처 worktree: <경로>` 줄과 `DESIGN_MISSING` 안내가 절대 경로를 알려 준다. 같은 피처의 계속이면 같은 `--feature <id>` 로 다시 실행하면 기존 worktree 와 그 안의 `.agent-work` 를 그대로 이어서 쓴다(중복 생성 없음, 세션 이어가기가 캐시 절감의 핵심).
   같은 worktree 에서 피처를 처음부터 다시 시작할 때만 `--new`를 붙인다(이전 산출물은 `.agent-work/archive/<이름>/`으로 `mv`, rm 금지). 부트스트랩이 거부되는 경우(원본에서 러너가 실행 중, dirty submodule, snapshot 도중 원본 변경)는 exit 1 이며 사유를 사용자에게 보고하고 원인이 해소된 뒤 재실행한다
   — 다른 방법으로 우회하지 않는다.

```bash
bash <skill_dir>/scripts/feature-run.sh --feature <id>          # 처음이든 재실행이든 항상 이 형태
bash <skill_dir>/scripts/feature-run.sh --feature <id> --new    # 같은 worktree 에서 피처를 처음부터 다시
bash <skill_dir>/scripts/feature-run.sh --feature <id> --new-review-attempt   # REVIEW_OUTPUT_INVALID 로 멈춘 리뷰만 새 attempt 로 다시(사용자 승인 뒤, 유료 리뷰 1회 이상) — 그 외 상태에서는 효과 없음
```

2. 사용자 요구를 `<worktree>/.agent-work/request.md`에 기록(원문 + 해석한 범위 + 명시적 제외). 스펙 폴더(`<skill_dir>/specs/feature_<번호>/`)에 문서·이미지가 있으면 전부 읽어 반영. **모호하면 추측 대신 사용자에게 질문**하고 `decisions.md`에 `- [USER-QUESTION][scope=design] <질문> → <답>` 형식으로 기록(Phase 0 의 요구·설계 질문은 항상 `scope=design`).
   **요구가 나중에 바뀌거나 추가되면**(impl 합의·워커·리뷰 도중 포함) request.md 의 원문을 고치지 않고 끝에 `## 요구 변경/추가` 절을 두어 시간 순서로 **append** 한다 — 항목마다 날짜·무엇을 추가/변경하는가·**어느 옛 규칙을 어느 범위에서 대체하는가(명시적 예외·제외 대상 포함)** 를 적는다(예:
   "2026-11-10 — 환불 승인·취소 승인 요청 Slack 에도 사유 표시. 원 요구 '접근 권한 요청만 사유 표시'를 이 두 유형에 한해 대체. 리마인드 알림은 제외(원 요구 유지)"). 그 변경을 지시한 사용자 결정은 `[USER-QUESTION][scope=design]` 로 기록하고 design.md(필요하면 implementation.md/approach.md)를 갱신한다
   — design 검증자는 이 두 근거(request.md 의 변경 기록 + scope=design 결정)가 함께 있을 때만 뒤 요구를 그 범위의 기준으로 읽는다.
3. `<worktree>/.agent-work/design.md` 초안: 목표, API/데이터 계약, 에러·동시성 처리, 테스트 기준, 비범위. 갈리는 설계 판단은 옵션을 제시해 사용자 결정을 받는다. 아래에서 `.agent-work/…` 는 항상 피처 worktree 안의 경로다. **문서 작성 직전 conventions 재대조.**
   러너는 `NEED_DOCS`(`DESIGN_MISSING` / `IMPL_DOCS_MISSING`) 로 돌아올 때 출력 끝에 **그 worktree 의** `conventions.md` 본문을 `[PROJECT CONVENTIONS]` 블록으로 덧붙인다(worktree 에 없으면 생략). 세션 첫 프롬프트에 주입된 원본 conventions 가 아니라 snapshot 된 worktree 사본이 기준이다. **그 블록은 사본일 뿐이다 — 문서를 쓰기 직전에 worktree 의 `conventions.md` 파일을 Read 도구로 처음부터 끝까지 직접 읽는다**(경로: `[SKILL REFERENCE]` 줄의 `[CONVENTIONS]` 뒤). 러너를 백그라운드 로그로 돌리거나 출력을 `head`/`grep` 으로 줄여 읽으면 블록은 보이지 않으며, 그 상태로 쓴 문서는 대조 없이 쓴 문서다.
   문서를 쓰기 전에 그 블록과 대조해 적용 규칙을 골라 문서에 명시 반영한다(명시적 convention 이 직접 요구한 방식은 material decision 이다 — 워커 재량으로 남기지 않는다). 적용 규칙이 없으면 문서 전제·비범위 절에 `적용 conventions: 없음 — <사유>` 한 줄을 남긴다(`decisions.md` 는 합의 지문 대상이므로 거기엔 쓰지 않는다).
   적용 conventions 의 절 번호만 나열하고 실제 대조를 생략하지 않는다 — 나열은 준수의 증거가 아니며, 검증자는 문서 결정이 명시 규칙과 직접 충돌하면 동작이 같아도 `DIRECT_MISMATCH` 로 막는다(검증자 계약 v19, design·impl 검증자 모두 conventions 본문을 받는다).
4. **material decision 확인 세 가지 — `design.md`·`implementation.md`·`approach.md` 공통.** 문서에 material decision(아래 "구현 문서 작성" 2번의 정의)을 적기 전에 그 결정에 한해 세 가지를 확인한다. 목적은 문서를 상세하게 만드는 것이 아니라 **잘못된 material 계약이 워커까지 내려가지 않게 하는 것**이다.
   모든 문장에 출처 표를 붙이거나 조사 보고서를 쓰지 않는다 — 확인 결과는 필요한 계약과 최소 근거(줄 범위 인용 한두 개)만 문서에 남기고, 사소한 helper·지역 변수·동일 의미의 표현 차이는 지금처럼 워커에게 위임하며(`REQUIRED`/`DELEGATED` 구분 불변), 저장소 전체를 무차별 탐색하지 않는다.
   - **A. 요구 출처.** 신규 동작·정책·계약은 사용자 요구 원문(`request.md`), 확정된 사용자 결정(`decisions.md` 의 `[USER-QUESTION]`), 기존 필수 계약(명시적 convention, 이번 변경이 직접 건드리는 기존 코드의 계약) 중 하나에서 도출돼야 한다. "다른 기능이 같은 처리를 한다" 는 새 요구의 근거가 아니다(예:
     필드 하나를 추가하는 요구에, 요청이 없는데 다른 엔티티가 그렇다는 이유로 변경 이력 기록까지 넣는 것). **구현에 필수적인 기술 변경**(새 필드를 위한 컬럼·migration·DTO·매핑, 요구된 동작이 거쳐야 하는 기존 경로의 수정)과 **새 제품 동작**(사용자에게 관찰되는 기능, 새 영속 기록·이력, 새 알림·권한 규칙)을 구별한다
     — 전자는 그대로 쓰고, 후자는 근거가 없으면 임의로 확정하지 않고 문서에서 뺀다. 그 동작 없이는 요구를 구현할 수 없거나 사용자 선택에 따라 결과가 실제로 갈릴 때만 질문한다(있으면 좋을 것 같다는 이유로 묻지 않는다).
   - **A-2. 사용자가 지목한 선례는 관련 경로를 끝까지 확인한다.** 요구(request.md·스펙 문서·사용자 결정)가 "기존 X 구조를 참고하라" 처럼 기존 구현을 지목했으면, 설계를 시작하기 전에 그 선례에서 이번 변경과 관련된 구현 경로(진입점에서 저장까지 실제로 거치는 층)를 열어 선례가 같은 문제를 어떻게 푸는지 먼저 확인한다 — 진입점 한 층만 보고 나머지를 요구사항에서 새로 설계하지 않는다.
     참고는 복제가 아니다: 사용자가 명시적으로 재사용·동일 구조를 요구한 부분과 conventions 가 정한 것만 고정이고, 그 밖의 차이는 요구사항과 기존 코드로 판단할 수 있으면 직접 정한다(선례와 달라진 material 결정에는 이유를 한 줄 남긴다). 그렇게 판단할 수 없는 중요한 설계 결정만 사용자에게 묻는다. 문서의 절(동시성·제어 흐름 등)을 채우는 것이 목적이 아니다 — 선례가 더 단순하게 푸는 문제에 그 절을 채우려고 새 분기·잠금·타입을 만들지 않는다.
   - **B. 컨벤션 대조.** 위 3번의 worktree `conventions.md` 블록을 기준으로, 이 material decision 에 적용되는 명시 규칙을 실제로 대조한다. 기존 코드의 관례와 명시적 convention 이 충돌하면 **convention 이 우선**이다(기존 코드를 precedent 로 인용해 convention 과 다른 구조를 REQUIRED 로 정하지 않는다). 참조 구현으로 인용하려는 줄 범위도 대조 대상이다 — 그 코드에 규칙 위반이 있으면 워커가 그대로 복제하므로, 위반 부분을 뺀 범위만 인용하거나 규칙을 따르는 형태를 문서에 직접 적는다. material decision 이거나 convention 이 명시로 고정한 구현 계약(구조·책임 배치·타입 경계 등)에 해당하는 규칙만 문서에 반영하고, 스타일 수준의 규칙은 워커가 conventions 를 직접 받으므로 옮겨 적지 않는다.
   - **C. 실제 코드 경로.** 변경 대상으로 적는 기존 함수·쿼리·서비스는 그 **직접 호출부와 직접 피호출부**(한 단계)를 열어 본 뒤에 적는다. 기존 repository/service/helper/query 경로와 책임 배치를 확인하고, 변경이 그 호출 경로 전체에 반영되는지 확인한다 — "X 는 변경 불필요" 같은 문장은 X 의 호출 관계를 확인한 뒤에만 쓴다(예:
     공용 쿼리를 고치면서 그 쿼리를 함께 부르는 다른 조회 메서드를 놓친 채 "그 조회는 변경 불필요" 라고 적는 것). 그때 호출 관계만이 아니라 **결과 생산자 → 반환값 → 소비자**를 함께 본다: 직접 호출부·피호출부가 이미 계산·판단해 반환하거나 넘겨주는 값(변경 항목 목록, 판정·분류 결과, 조회 결과 등)이 있고 그 값으로 필요한 결과를 만들 수 있으면, 같은 판단·계산을 다시 하도록 적지 않고 그 값을 받아 쓰는 경로를 `REQUIRED` 로 적는다(예:
     변경 로그 서비스가 변경 항목 목록을 이미 반환하는데 알림 조립 쪽에서 같은 필드 비교를 다시 하도록 적는 것 — conventions 에 "이미 계산한 결과를 다시 계산하지 않는다" 류 규칙이 있으면 그 위반이다). 이 확인은 지금 적으려는 material decision 의 직접 경로에 한한다 — 전역 코드 감사나 증거 표를 만들지 않으며, 기존 반환값으로 필요한 결과를 만들 수 없으면(의미·시점·범위가 다름) 새 계산을 그대로 적는다.
     직접 범위(변경 파일·같은 모듈·직접 의존)의 재사용 후보를 확인해 기존 책임의 중복 구현을 막는다(아래 "재사용 탐색"). 검증자는 문서의 이런 서술을 사실로 받아들이지 않고 같은 범위를 독립적으로 열어 대조한다.
