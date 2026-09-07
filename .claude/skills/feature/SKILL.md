---
name: feature
description: 복잡한 피처를 다중 에이전트 합의 파이프라인으로 처리한다. 오케스트레이터가 사용자 요구를 설계 문서(design.md)로 쓰고 이어서 워커용 구현 문서(implementation.md=무엇, approach.md=어떻게)를 쓰며, 러너(feature-run.sh)가 검증자 합의 → 워커 구현 → 리뷰 수렴 → 최종 테스트를 기계적으로 연결하고, 사용자 판단이 필요한 지점에서만 오케스트레이터로 돌아온다. 사용자가 "feature" 또는 "피처"를 명시하며 기능 구현을 요청할 때 사용한다. 사소한 수정·단일 파일 변경에는 사용하지 않는다.
---

# feature

피처 하나를 "설계 합의 → 구현 문서 합의 → 구현 → 리뷰 수렴 → 최종 테스트"로 끝까지 처리한다. 오케스트레이터(이 세션)가 하는 일은 **문서 작성과 사용자 질문뿐**이고, 나머지 결정론적 제어는 전부 `scripts/feature-run.sh`(교통정리기)가 맡는다. 러너는 agent 가 아니다 — 판단이 필요한 상태가 나오면 추가 추론 없이 즉시 이 세션으로 반환한다.

사용자가 세션 요약을 요청하면 `<skill_dir>/specs/feature_<번호>/session/SESSION-<YYYY-MM-DD>-<피처>.md`에 작성한다(결정·미해결 쟁점·다음 단계 위주).

## 사전 조건

1. `config.sh`의 역할별 `*_MODEL`·`*_EFFORT`·`TEST_CMD`·`LINT_CMD`가 실제 환경과 일치. 빈 값이나 `CHANGE_ME`가 남으면 가드가 실행 거부.
2. `claude`, `codex`, `jq`, `uuidgen`, `envsubst` 설치·로그인.
3. 저장소 루트에서 실행. `.agent-work/`는 `.gitignore`에 등록돼 있다.

## Phase 0 — 초기화 + 문서 작성 (오케스트레이터)

1. 새 피처면 러너를 `--new`로 한 번 실행한다. 이전 산출물을 `.agent-work/archive/<이름>/`으로 `mv`(rm 금지)하고 `decisions.md`를 비운 뒤, `design.md`가 없으므로 `NEED_DOCS(DESIGN_MISSING)`(exit 3)로 즉시 돌아온다 — 정상이다. 같은 피처의 계속이면 `--new`를 쓰지 않는다(세션 이어가기가 캐시 절감의 핵심).

```bash
bash <skill_dir>/scripts/feature-run.sh --new --archive-as <이전-피처명>
```

2. 사용자 요구를 `.agent-work/request.md`에 기록(원문 + 해석한 범위 + 명시적 제외). 스펙 폴더(`<skill_dir>/specs/feature_<번호>/`)에 문서·이미지가 있으면 전부 읽어 반영. **모호하면 추측 대신 사용자에게 질문**하고 `decisions.md`에 `- [USER-QUESTION] <질문> → <답>` 형식으로 기록.
3. `.agent-work/design.md` 초안: 목표, API/데이터 계약, 에러·동시성 처리, 테스트 기준, 비범위. 갈리는 설계 판단은 옵션을 제시해 사용자 결정을 받는다.

## Phase 1 — 러너 실행

```bash
bash <skill_dir>/scripts/feature-run.sh [--branch feature/<이름>]
```

러너가 `preflight → design → impl → worker → review → verify → done`을 연결한다. verify 는 `TEST_CMD` → `LINT_CMD` 이며 실패하면 워커 수정 → 재리뷰로 돌아간다. 복잡도·중복·dead code 분석은 프로젝트가 `LINT_CMD`에 구성한다 — 스킬은 언어 독립이라 자체 코드 검사를 갖지 않고, 커버리지 % 게이트도 두지 않는다(숫자 채우기 테스트 유발). 실시간 로그 창(`feature-live`)은 러너가 연다. 진행은 `.agent-work/live.log`와 `run-state.json`으로 관찰한다. **종료 코드로만 다음 행동을 정한다:**

| exit | status | reason | 오케스트레이터 행동 |
|---|---|---|---|
| 0 | `DONE` | — | Phase 2 보고 |
| 3 | `NEED_DOCS` | `DESIGN_MISSING` | Phase 0의 2·3 수행 후 재실행 |
| 3 | `NEED_DOCS` | `IMPL_DOCS_MISSING` | 설계 합의 완료. 아래 "구현 문서 작성" 후 재실행 |
| 2 | `NEED_USER` | `ASK_USER` | 검증자가 문서 재작성으로 풀 수 없다고 판정(허용 범위 밖 공용 컴포넌트 수정 필요, 또는 제품 정책 선택). `state.json.review`의 해당 이슈 `user_question`과 `options`를 **그대로** 사용자에게 전달. 답 기록 → 문서 반영 → 재실행 |
| 2 | `NEED_USER` | `DEADLOCK` / `MAX_ROUNDS` | 마지막 리뷰 JSON(`state.json.review`)의 쟁점만 사용자에게 보고하고 멈춘다. 답을 `decisions.md`에 `[USER-QUESTION]`으로 기록, 해당 문서에 반영 후 재실행 |
| 3 | `NEED_DOCS` | `APPROACH_GAP` | 워커 `undecided`가 전부 `DOC_GAP`이거나 리뷰어가 `DOC_GAP` issue(`state.json.review`의 `required_outcome`)를 냄 — 제품 동작은 정해져 있는데 `approach.md`에 그 분기·방식만 누락. **사용자에게 묻지 않고** 오케스트레이터가 `approach.md`를 보강한 뒤 재실행(검증자 재합의 → worker 재개) |
| 2 | `NEED_USER` | `UNDECIDED` | `undecided`에 `USER_DECISION`(어느 문서에도 없는 제품 정책 선택)이 하나라도 있음. 그 항목만 **합의 루프 없이 그대로 사용자에게 질문**, 함께 온 `DOC_GAP`은 오케스트레이터가 보강. 답 기록 → `approach.md` 반영 → 재실행 |
| 2 | `NEED_USER` | `TEST_RETRIES_EXHAUSTED` / `APPROVAL_STALE_REPEATED` | 로그(`reviews/verify-*.log`)와 상황을 정리해 사용자 보고 후 멈춘다 |
| 3 | `NEED_DOCS` | `SCOPE_MISSING` | `feature-scope.json` 이 없다. 아래 "구현 문서 작성" 3번대로 작성 후 재실행 |
| 2 | `NEED_USER` | `FOREIGN_WORKTREE_CHANGE` | 리뷰어가 `OUT_OF_SCOPE_CHANGE` 를 냄. **자동 원복하지 않는다** — 같은 working tree 의 다른 세션 변경일 수 있다. `state.json.review` 의 해당 이슈 파일 목록을 사용자에게 보여 주고, 사용자가 "워커 과잉 변경이라 되돌린다 / 다른 작업이라 보존하고 범위를 넓힌다" 를 결정한다. 파이프라인은 어느 쪽도 스스로 하지 않는다 |
| 2 | `NEED_USER` | `SCOPE_VIOLATION` | 워커·수정자 호출 전후 write-set 이 `feature-scope.json` 범위를 벗어남(`state.json.files`). 위와 같이 사용자 결정. 자동 원복 금지 |
| 2 | `NEED_USER` | `SCOPE_MANIFEST_CHANGED` | `feature-scope.json` 이 워커 진입 시 확정한 `feature-scope.lock.json` 과 다르거나, 워커·수정자 호출 중 둘 중 하나가 바뀜(범위를 넓혀 검사를 우회하는 경로). 자동 복구 없음. 의도한 범위 변경이면 사용자가 lock 을 지우고 재실행(impl 재합의 → 새 lock), 아니면 원본을 lock 과 같게 되돌린다 |
| 2 | `NEED_USER` | `SCOPE_BASELINE_CHANGED` | 워커·수정자 호출 중 `worker-baseline.tree` 가 바뀜. 이 파일은 `new_file_roots` 아래 소유권 판정의 기준이라 바꾸면 기존 파일 보호가 풀린다(빈 tree 로 바꾸는 우회). 러너·루프는 호출 전에 읽은 값으로 판정하고 파일 변경은 자동 복구 없이 중단하며, 기대값을 `worker-baseline.guard.json` 에 남긴다(index·manifest 검사보다 먼저 기록하므로 다른 사유로 먼저 종료해도 가드는 남는다). 복구 전 재실행은 stage 와 무관하게 러너 진입 시 전역 검사에서 모델·테스트 호출 0회로 같은 사유로 다시 멈춘다(변조된 값을 새 기준선으로 읽는 우회, verify 의 worker-fix 중단 뒤 verify 재진입으로 DONE 이 되는 우회 차단). 사용자가 원래 값(`expected`)으로 되돌리고 워커·수정자 변경을 확인한 뒤 재실행 |
| 1 | `ENV_ERROR` | — | 원인 확인 후 재실행. 진행 금지 |

재실행은 항상 같은 명령이다(`--worktree` 를 썼다면 그 인자도 같이). 러너가 `run-state.json`의 stage 힌트와 실제 산출물(합의 체크포인트 `consensus-design.json`/`consensus-impl.json`의 PASS + 현재 입력 지문 + 참조 리뷰 JSON 내용, `worker-result.json`, `approved.fingerprint`)을 교차 확인해 재개 지점을 스스로 고른다 — 오케스트레이터가 단계를 지정하지 않는다. impl 이상으로 가려면 design PASS 가, worker 이상으로 가려면 impl PASS 가 현재 입력(request/design/implementation/approach + `decisions.md`의 `[USER-QUESTION]` 줄)에 대해 유효해야 하며, 문서를 고치고 재실행하면 해당 합의부터 다시 돈다. 문서 합의 루프는 stage 보다 잘게 `consensus-design.json` / `consensus-impl.json` 에 round 와 다음 단계(`VALIDATOR_PENDING` / `DESIGNER_PENDING` / `PASS`)를 기록한다 — 검증자가 끝난 뒤 디자이너 호출이 실패(모델 ID 오류 등)하면 재실행은 같은 리뷰 JSON 으로 디자이너만 다시 부르고, 디자이너가 문서를 일부 고친 뒤 죽었으면(입력 지문 불일치) 같은 수정을 반복하지 않고 다음 검증 라운드로 간다. PASS 도 입력 지문과 함께 캐시되어 입력이 그대로이고 참조 리뷰가 실제 현재 계약의 PASS 이면 검증자를 다시 부르지 않는다. 지문은 세 종류다: editable(대상 문서 + `decisions.md` 전체 — 스냅샷·diff·변경 파일 목록과 같은 집합, 디자이너 부분 실행 감지), upstream(design 은 `request.md`, impl 은 `request.md`+`design.md`, + `[USER-QUESTION]` — 바뀌면 저장된 리뷰가 무효라 Round 1 부터), PASS(입력 문서 전체 + `[USER-QUESTION]` — 이후 판정 기록이 쌓여도 PASS 가 무효화되지 않음). 체크포인트 포맷은 `config.sh`의 `CONSENSUS_CHECKPOINT_VERSION`/`REVIEW_CHECKPOINT_VERSION`으로 따로 버전을 매기며, 지문 의미가 바뀌면 올린다 — 다른 버전의 체크포인트는 지문을 비교하지 않고 처음(Round 1 / 새 attempt)으로 돌아간다. `ASK_USER`/`DEADLOCK`/`MAX_ROUNDS` 로 멈추면 체크포인트는 Round 1 로 초기화된다(사용자 수정 후 처음부터 재검증). 구현 리뷰 루프도 같은 구조로 `review-impl.json` 에 attempt·round·다음 단계(`REVIEWER_PENDING` / `FIXER_PENDING` / `APPROVE`)와 작업 트리 지문을 기록한다 — 리뷰어가 `REQUEST_CHANGES` 를 낸 뒤 수정자 호출이 실패하면 재실행은 같은 attempt 에서 기존 리뷰 JSON 으로 수정자만 다시 부르고, 수정자가 코드나 `decisions.md`를 일부 고친 뒤 죽었으면(작업 트리 + `decisions.md` 지문 불일치) 다음 리뷰 라운드로 간다. 수정자가 완료된 뒤(`REVIEWER_PENDING`) 외부 변경이 들어왔으면 종결 검토에 섞이지 않도록 새 attempt 의 Round 1 로 간다. `APPROVE` 는 작업 트리만의 지문이 그대로이고 참조 리뷰가 실제 현재 계약의 APPROVE 이면 재사용하고, 바뀌었으면 새 attempt 를 시작한다. 러너도 verify 로 바로 들어가기 전에 같은 조건(`impl_approval_current`: 체크포인트 APPROVE + 계약·포맷 버전 + 트리 지문 + `approved.fingerprint` 일치 + 실제 APPROVE 리뷰)을 확인하고, 아니면 review 부터 다시 간다. `DEADLOCK`/`MAX_ROUNDS`/`DOC_GAP` 종료 시 체크포인트는 초기화되어 다음 재진입은 새 attempt 의 Round 1 이다.

### 구현 문서 작성 (`IMPL_DOCS_MISSING` 반환 시)

합의된 `design.md` 기반으로 세 파일을 쓴다. 설계 합의를 재해석·번복하지 않는다.

1. `.agent-work/implementation.md` — **무엇을** 구현하는가(도메인 지식). 변경·생성 파일 목록과 순서, 클래스/함수 수준 계획(시그니처·입출력 계약), 작성할 테스트 목록, 완료 판정 기준.
3. `.agent-work/feature-scope.json` — 이번 피처가 변경·생성하는 **정확한 경로 목록**. `implementation.md` 의 파일 목록을 기계가 읽는 형태로 옮긴 것이며 자연어 목록을 러너가 해석하지 않는다. `files` 의 경로는 생성·수정·삭제가 모두 허용된다. 정확한 파일명을 미리 정할 수 없는 생성 경로(마이그레이션 등)만 `new_file_roots` 에 디렉터리 접두로 최소한만 두며, **그 아래는 워커 진입 기준선(`worker-baseline.tree`)에 없던 경로의 생성·수정(A/M)만 허용**된다 — 이 피처가 만든 파일은 이후 라운드의 수정자·worker-fix 가 다시 고칠 수 있지만 삭제·유형 변경(D/T)은 위반이고, 기준선에 있던 파일의 수정·삭제도 `SCOPE_VIOLATION` 이다(소유 분류는 호출별 A/M 이 아니라 기준선 존재 여부). 기준선 tree 는 호출 전에 읽어 사후 판정에 넘기며 호출 중 파일이 바뀌면 `SCOPE_BASELINE_CHANGED` 로 중단한다. 경로는 canonical 이어야 한다(선행 `./`·후행 `/`·`..` 금지). 러너는 워커 진입 시 이 파일을 `feature-scope.lock.json` 으로 확정하고, 이후 모든 검사·diff·지문은 lock 을 쓴다 — 워커·수정자가 manifest 를 고쳐 범위를 넓히면 `SCOPE_MANIFEST_CHANGED` 로 중단한다. 범위를 바꾸려면 원본을 고치고 lock 을 지운 뒤 재실행한다(impl PASS 지문에 manifest 가 포함돼 재합의를 거친다).
   ```json
   {"version": 1, "files": ["src/main/java/com/example/quote/QuoteService.java", "src/test/java/com/example/quote/QuoteServiceTest.java"], "new_file_roots": ["src/main/resources/db/migration/"]}
   ```
   러너는 이 범위로 (1) 워커·수정자 호출 전후 write-set 을 대조해 범위 밖 변경이 있으면 원복 없이 `SCOPE_VIOLATION` 으로 중단하고, (2) 리뷰 diff 를 범위 경로로 한정하며, (3) 승인 지문을 범위 파일로 계산한다(다른 세션이 범위 밖 파일을 바꿔도 승인·verify 가 무효화되지 않음). 워커 재개(`APPROACH_GAP` 등)로 파일 목록이 바뀌면 함께 갱신한다.
2. `.agent-work/approach.md` — **어떻게** 구현하는가(CS 지식). 단위는 함수가 아니라 **구현 결정**이며, 결정마다 `REQUIRED` 또는 `DELEGATED`를 표시한다.
   - **DELEGATED가 기본값이다.** 다음 중 하나에 해당하는 선택만 **REQUIRED**: ① 선택에 따라 외부에서 관찰되는 동작이 달라진다 ② 영속 데이터의 정합성이 달라진다 ③ 보안·권한·개인정보 경계가 달라진다 ④ 사용자가 특정 구현 방식이나 기존 코드 재사용을 명시적으로 요구했다. REQUIRED에는 기법·구조·금지 방식을 적고 근거를 붙인다: 저장소에 같은 종류의 문제를 푸는 기존 코드가 있으면 그 줄 범위를 직접 열어 확인한 뒤 인용 → 없으면 표준 기법 + 선택 이유.
   - **DELEGATED(위임)** — 그 밖의 로컬 구현 방식 전부(trim 호출 위치, 헬퍼 배치, 일반적 파싱·변환·검증, 일상적 트랜잭션·예외 처리·DTO·mapper). 기법을 적지 않는다. 워커가 "기존 패턴 우선 → 표준 라이브러리 우선 → 새 추상화 금지" 제약 안에서 정하고 결과 JSON의 `delegated_choices`에 보고하며, 리뷰어는 그 목록으로 제약 위반만 검사한다. 예: `공백 입력이 오류인가 무시인가` = REQUIRED(외부 동작), `trim을 어디서 호출하나` = DELEGATED.
   - **제어 흐름 절(선택)** — 외부 동작이나 상태 변경 결과가 갈리는 함수에 "허용된 결정점을 열거하고 그 외 동작 분기를 금지"하는 계약을 쓴다. 모든 함수에 쓰지 않는다. 절이 있는 함수는 REQUIRED 계약이고, 없는 함수의 로컬 제어 흐름은 DELEGATED 다(단 워커는 문서에 없는 외부 동작·상태 결과를 새로 정하지 못하고, 리뷰어는 그런 추가를 `UNDECLARED_BEHAVIOR` issue 로 잡는다). 계약 대상은 구문상의 조건문이 아니라 **동작을 달리하는 결정점**이다(루프 종료·관용적 빈값 확인·API 예외 변환·값 계산 boolean·exhaustive match 는 열거하지 않는다). 소스에 분기 ID 주석을 요구하지 않고, 리뷰어는 정상 대응하는 분기를 출력하지 않는다 — 계약 밖 결정점·중복 분기·누락된 분기만 issue 다. 워커는 열거된 결정점만 구현하고 추가가 필요하면 UNDECIDED 로 돌려보낸다. 형식:
     ```
     ## `OrderService.process` 제어 흐름 [REQUIRED]
     요구되는 분기:
     - B1 / REQ-03: 주문이 없으면 NOT_FOUND 반환
     - B2 / REQ-04: 이미 처리된 주문이면 현재 결과 반환
     주 경로: 주문 조회 → 처리 실행 → 결과 저장 → 반환
     금지: 위 목록에 없는 null 방어 분기 · 호환성 fallback · 재시도 · 타입별 if 분기 · boolean flag 흐름 제어
     참조 구현: `src/order/ExistingOrderService.java:L40-L68`
     ```
   - 참조할 기존 코드는 반드시 백틱 **줄 범위**로 인용한다(`src/foo/Bar.kt:L40-L68`). 러너가 그 범위만 워커 프롬프트에 `[REFERENCE CODE]`로 직접 붙인다(참조당 100줄·8개 캡). 심볼명이나 범위 없는 경로는 언어 종속 탐색이 필요해 붙지 않으며 검증자가 blocking 으로 돌려보낸다.
   - 제어 흐름 절은 request.md·design.md에 **이미 명시된** 동작을 옮기는 것이다. 모든 분기를 선제 예측하지 않는다 — 구현 중 실제 공백은 워커가 `DOC_GAP`으로 돌려보내고 오케스트레이터가 보강한다. 검증자는 명시된 요구 동작이 빠졌는지만 본다.

## Phase 2 — 보고 (오케스트레이터)

`DONE`이면 변경 요약·라운드 수(`run-state.json.history`, `usage.jsonl`)·`decisions.md` 주요 결정·`delegated_choices`를 한 번에 보고한다. 커밋 절차는 강제 규칙 참조.

## 강제 규칙 (어길 수 없음)

- **검증자는 게이트지 설계자가 아니다.** REVISE_DOC은 여섯 가지 입장 조건(요구·결정·계약 위반 / 근거: 문서 대조 DIRECT_MISMATCH 또는 실행 경로 REACHABLE_FAILURE / 명시 계약과 다른 결과·권한·비밀·영속 데이터·구현 불가 영향 / 이번 변경이 만들거나 활성화 / 지금 결정 없이는 진행 불가 / 정확한 근거 위치)을 모두 만족할 때만, ASK_USER는 별도 네 조건(어디에도 미결정 / 동작·데이터·보안·범위가 갈림 / 기존 계약·패턴이 확정 못 함 / 없이는 시작 불가)을 만족할 때만 등록된다. 스키마와 러너가 근거 필드, 사용하지 않는 필드의 공백, id 유일성, Round 2 `origin`의 형식과 참조 대상 존재(직전 이슈 id, docs diff에서 실제 바뀐 파일)를 강제하며 어긋나면 검증자 응답 오류로 중단한다. 수정과 신규 blocker 사이의 의미적 인과관계까지 러너가 보장하지는 않는다 — 그것은 `tests/validator-cases.md` 감도 회귀 세트의 몫이다. 순수 정책 미결정은 `POLICY_UNDECIDED` + `UNDECIDED_CHOICE`로 표현해 충돌 계약이나 실패 경로를 지어내지 않게 한다. 검증자 프롬프트는 두 층이다 — 공통 계약(`prompts/validator-review-design.md`/`-impl.md`: 관할·탐색 범위·입장 조건·출력 형식, 모델과 무관)과 판정 전략 오버레이(`prompts/validator-overlays/<프로필>.md`, `[VALIDATOR PROFILE: …]` 블록으로 task prompt 끝에 붙음). 프로필은 `config.sh`의 `VALIDATOR_PROFILE`(compact / guided / conservative / none)이며 비워 두면 `validator_profile` 헬퍼가 `VALIDATOR_MODEL`로 기본값을 고른다(sol→compact, astra→guided, 그 외→conservative). 오버레이는 계약을 바꾸지 못하고 "그 계약을 어떤 순서·깊이로 판정할지"만 담는다 — 모델별로 계약 파일을 복제하지 않는다. 프로필 이름이 있는데 파일이 없으면 검증자를 부르지 않고 실패한다. 검증자 프롬프트(공통 계약·오버레이 모두)·스키마·러너 검사 중 하나라도 바뀌면 `config.sh`의 `VALIDATOR_CONTRACT_VERSION`을 올린다. 러너가 그 값과 다른 이전 PASS를 자동 무효화하므로 `--new` 없이 재실행하면 된다. 검증자는 최소 불변식만 요구하고 해결 방법을 처방하지 않는다. 디자이너는 5단계 판정을 거쳐 REJECT하고, ACCEPT해도 검증자의 처방을 복사하지 않는다. Round 1은 전부, Round 2부터는 직전 이슈 종결 검토와 직접 회귀만. 파이프라인 운영(git 기준선·지문·테스트 순서)은 러너 책임이며 문서 blocking 사유가 아니다.
- **리뷰어는 병합 게이트지 개선자가 아니다.** issue 는 여섯 가지 입장 조건(이번 diff 가 만든 문제 / 여덟 category 중 하나: CONTRACT_VIOLATION·UNDECLARED_BEHAVIOR·REACHABLE_BUG·SECURITY_OR_DATA_RISK·REDUNDANT_CONTROL_FLOW·REDUNDANT_CODE·TEST_CONTRACT_GAP·OUT_OF_SCOPE_CHANGE / 증거: DIRECT_MISMATCH·REACHABLE_FAILURE·SEMANTIC_REDUNDANCY / verify 전에 반드시 수정 / 기존 결함·장래 개선이 아님 / 정확한 위치)을 모두 만족할 때만 등록된다. 명명·포맷·선호 리팩터링·정상 대응 분기·`delegated_choices` 보고 누락·합의된 동작의 추가 black-box 테스트는 issue 가 아니다. `required_outcome` 은 결과만 적고 기법을 처방하지 않는다. action 은 `FIX_CODE`(수정자) / `DOC_GAP`(오케스트레이터가 approach.md 보강, exit 3) 둘뿐이다 — 제품 정책 선택이라 사용자에게 가야 하는지는 재합의 때 문서 검증자가 판정하므로 리뷰어는 사용자 질문을 만들지 않는다. 리뷰 diff 는 러너가 워커 진입 직전에 기록한 `worker-baseline.tree` 대비다(피처 이전 미커밋 변경은 이번 작업이 아니다). `OUT_OF_SCOPE_CHANGE` 는 수정자에게 가지 않는다 — 러너가 수정자 호출 전에 `FOREIGN_WORKTREE_CHANGE` 로 사용자에게 돌려보내며, 어떤 역할도 범위 밖 파일을 원복하지 않는다(`pre_bash_guard` 가 `git restore`/`checkout --`/`reset --hard` 를 차단). 워커·수정자의 git index 조작(add/reset/stash/restore --staged)은 금지이며, 러너·루프가 호출 전후 index 지문을 비교해 바뀌었으면 자동 복구 없이 중단한다. 루프가 증거·action 별 필드, id 유일성, Round 2 `origin`(UNRESOLVED_PREVIOUS / FIX_REGRESSION / NEWLY_EXPOSED_BY_FIX)과 참조 대상(직전 이슈 id, 수정 diff 에 실제로 바뀐 파일)을 강제하고 어긋나면 응답 오류로 중단한다. Round 1 은 전부, Round 2 부터는 직전 이슈 종결 검토와 수정이 만든 직접 회귀만. 같은 이슈가 내용 변화 없이 반복되면 `DEADLOCK`. 수정자는 `FIX_CODE` 의 required_outcome 만 구현하고 잘못된 이슈는 `decisions.md` 에 `[fix round N] <id> REJECT` 로 남긴다. 리뷰어 프롬프트·스키마·루프 검사 중 하나라도 바뀌면 `config.sh`의 `REVIEWER_CONTRACT_VERSION`을 올리고 `tests/reviewer-cases.md` 감도 회귀를 돌린다 — 유료 실행이므로 사용자 승인 후 `touch .claude/ALLOW_REAL_LLM_REGRESSION`(1회용)이 있어야 스크립트가 돈다. 오케스트레이터가 지시 없이 만들지 않는다.
- **막히면 AI끼리 풀지 말고 사용자에게 묻는다.** 러너가 자동으로 도는 루프는 성공 조건이 기계적인 두 가지뿐 — (리뷰 이슈 → 수정자 → 재리뷰), (테스트 실패 → 워커 1회 수정 → 재리뷰 → 재테스트). 교착·라운드 초과·`UNDECIDED`·재시도 소진은 전부 즉시 사용자 반환이며, 러너·오케스트레이터 어느 쪽도 "다른 에이전트에게 다시 물어보는" 자동 복구를 추가하지 않는다.
- **테스트는 동작 계약 검증용이다** — 작성 순서는 강제하지 않는다. 워커는 `implementation.md`가 명시한 동작 계약을 검증하는 테스트만 쓰고, 테스트 편의만을 위한 운영 API·분기·추상화·가시성 변경과 커버리지 수치 목적의 테스트는 금지. 리뷰어는 명시 요구 테스트의 누락, 내부 호출·private 상태만 검증하는 테스트, 테스트 편의용 운영 코드 변경을 `TEST_CONTRACT_GAP` 으로 올린다. 이미 합의된 외부 동작을 검증하는 추가 black-box 테스트는 문서에 이름이 없어도 issue 가 아니다.
- **구현 방식(어떻게)의 REQUIRED 결정은 워커가 정하지 않는다** — `approach.md`에서 오케스트레이터가 결정하고 검증자가 합의한다. 워커·수정자가 REQUIRED와 다른 기법을 쓰면 리뷰어가 `CONTRACT_VIOLATION` 으로 잡는다. DELEGATED는 워커 선택을 존중한다 — 기존 유틸·표준 라이브러리의 수동 재구현과 새 추상화 도입만 코드 위치를 근거로 issue 이며, `delegated_choices` 보고 누락 자체는 issue 가 아니다.
- 모호한 요구·갈리는 설계 판단은 추측 금지 — 사용자 질문 후 문서 반영, `decisions.md`에 `- [USER-QUESTION] <질문> → <답>` 기록.
- 판정은 스키마 검증된 JSON만 신뢰한다: 검증자(`PASS/BLOCK`), 리뷰어(`APPROVE/REQUEST_CHANGES`), 워커(`DONE/UNDECIDED`, `schemas/worker-result.schema.json`). 모순 응답은 스크립트가 즉시 거부. "대충 통과 간주" 금지.
- 하위 실행은 반드시 `--model`/`-m` 명시(`config.sh` 한 곳에서 관리). `core_rules.md`는 워커에게만, 선택 `conventions.md`는 전 역할에 주입. 워커에는 추가로 `config.sh`의 `WORKER_SKILLS`(기본 `ponytail`; 탐색 순서 `.claude/skills/<이름>/SKILL.md` → `.agents/skills/<이름>/SKILL.md` → 스킬 안의 `worker-skills/<이름>/SKILL.md` vendored 사본. `install.sh` 가 `worker-skills/` 를 함께 복사하므로 설치 대상에서도 항상 있다)의 본문을 `[WORKER SKILL]` 블록으로 붙인다. ponytail(최소 해법 사다리, 강도 `PONYTAIL_LEVEL`)은 **DELEGATED 결정과 로컬 구현 방식에만** 적용되며 문서가 정한 동작·REQUIRED 결정·테스트 목록을 YAGNI 로 빼지 못한다 — 과하다고 보면 구현을 줄이지 말고 `delegated_choices`/`undecided`로 보고한다. 목록에 있는데 어디에도 없으면 워커를 실행하지 않고 실패한다. 프로젝트 codex hooks(`.codex/hooks.json` + `worker_guard.sh`)는 매 툴 호출에 별도 적용.
- **워커(codex)와 리뷰어·수정자는 파일 삭제 절대 금지** — 훅이 강제한다(claude 쪽 `pre_bash_guard`, codex 쪽 `worker_guard`). 러너의 `--new` 아카이브도 `mv`만 쓴다. 삭제가 필요하면 `decisions.md`에 대상·사유를 남기고 사용자 에스컬레이션.
- 워커·리뷰어·수정자는 커밋·푸시 금지. 커밋은 사용자가 요청했을 때만 — `DONE` 이후 오케스트레이터가 `verify_approved_fingerprint`(config.sh)로 승인 지문을 재확인하고 `touch .claude/ALLOW_COMMIT`(1회용 플래그) 후 `fixer` 세션에 별도 호출로 위임.
- 마지막 APPROVE 이후 코드가 조금이라도 바뀌면 재리뷰 없이 종료 금지 — 러너의 verify 단계가 지문으로 강제한다.
- 모든 하위 실행은 stdin을 닫고 돌린다(스크립트 시작부 `exec </dev/null`). 러너를 다른 명령·heredoc과 한 줄로 묶지 않는다.
- **진행 확인은 "프로세스 생존"이 아니라 "실제 진척"으로 판정** — `live.log` 최근 갱신과 CPU 시간 증가를 본다. 둘 다 멈춰 있으면 입력 대기·행(hang)이다: 해당 PID만 TERM으로 정리하고(`pkill` 광역 금지) 원인 확인 후 같은 명령으로 재실행하면 러너가 재개 지점을 찾는다. 중단된 라운드 산출물은 archive로 옮긴다.

## 공유 working tree 와 변경 소유권

`worker-baseline.tree` 는 시점 기준선이지 변경 소유권 증거가 아니다. git 은 같은 working tree 에서 생긴 변경이 워커의 것인지 다른 채팅 세션의 것인지 기록하지 않는다. 그래서:

- 같은 working tree 에서 피처 실행 중 다른 writer 의 변경이 존재할 수 있으므로, **범위 밖 변경은 자동 원복하지 않는다.** 현재 내용을 보존하고 `FOREIGN_WORKTREE_CHANGE`(리뷰어 판정) 또는 `SCOPE_VIOLATION`(write-set 대조) 으로 중단한다. 되돌릴지 보존할지는 사용자가 정한다.
- 이번 피처의 변경은 시점이 아니라 **범위**(`feature-scope.json` → 워커 진입 시 `feature-scope.lock.json` 으로 확정)로 정의한다. 리뷰 diff 와 승인 지문은 범위 경로만 본다(`new_file_roots` 아래는 기준선에 없던 신규 파일만). manifest 는 검사 기준이면서 에이전트가 쓸 수 있는 `.agent-work` 안에 있으므로, 호출 전후 원본·lock 해시를 대조해 바뀌었으면 `SCOPE_MANIFEST_CHANGED` 로 중단한다. 같은 이유로 `worker-baseline.tree` 도 호출 전에 읽은 값으로만 소유권을 판정하고, 호출 중 바뀌었으면 `SCOPE_BASELINE_CHANGED` 로 중단한다. 범위 안 파일을 다른 세션이 동시에 고치는 경우는 구분할 수 없다 — 그 파일의 변경은 이번 작업으로 리뷰된다.
- **엄격한 격리가 필요한 실행은 피처별 전용 git worktree 에서 수행한다.** `feature-run.sh --worktree <디렉터리> --branch <이름>` 이 없으면 만들고 그 안에서 모든 단계를 돈다(산출물 `.agent-work` 도 그 안). 피처 worktree 밖의 파일은 워커·수정자·리뷰·승인 대상이 아니며, 다른 세션은 원래 디렉터리에서 계속 작업한다. 완료 후 main 반영은 자동이 아니라 사용자의 병합 단계다. 커밋 정책(사용자 지시 시에만)은 그대로다. `.codex/`(worker_guard 훅)가 커밋돼 있지 않으면 worktree 에 복사한다.

권장 구성: 피처별 전용 worktree + `feature-scope.json` 필수 + write-set 검사 + 범위 밖 변경 자동 원복 금지 + main 자동 반영 금지. 공유 worktree 를 써야 한다면 앞의 원복 금지·범위 한정이 최소 안전장치다.

이 정책의 회귀는 저장소 루트의 `tests/smoke-foreign-change.sh` 다(실제 LLM 호출 없음, mock claude, 임시 저장소). 다섯 사례: ① 기준선 기록 후 워커 역할이 범위 안 파일을, 다른 세션 역할이 범위 밖 파일을 고친 상태에서 리뷰어가 `OUT_OF_SCOPE_CHANGE` 를 내면 exit 2 / `FOREIGN_WORKTREE_CHANGE` / 수정자 호출 0회 / 두 파일과 index 불변 / 리뷰어 diff 가 실제로 캡처됐고 범위 안 파일은 있고 범위 밖 파일은 없음 ② 수정자의 범위 밖 쓰기 → `SCOPE_VIOLATION`, 원복 없음 ③ 승인 지문 양방향 — 범위 밖 외부 변경은 승인 유지·재사용, 범위 안 내용·실행 권한·범위 정의 변경은 승인 무효 ④ 범위 밖 파일을 범위 안 경로로 rename 하면 출발지가 위반으로 잡힘(`--no-renames`) ⑤ manifest 가 있는데 잘못되면 전체 트리 지문으로 조용히 돌아가지 않고 실패 ⑥ manifest canonical 규칙과 roots-only 유효 ⑦ ponytail 주입 ⑧ 수정자가 manifest 를 넓혀도 `SCOPE_MANIFEST_CHANGED`, 원복·재호출 없음, lock≠원본이면 진행 불가 ⑨ `new_file_roots` 아래 기준선 파일 수정은 위반·신규 생성은 허용, 지문은 신규 엔트리만 ⑩ 이전 호출이 만든 root 파일의 후속 수정은 허용 ⑪ APPROVE 뒤 lock 은 그대로 두고 원본 manifest 만 바뀌면 승인 지문 실패(원본·lock 일치 검사가 `compute_approval_fingerprint` 안에 있다) ⑫ 피처가 만든 root 파일의 삭제·symlink 화(D/T)는 위반 ⑬ 수정자가 `worker-baseline.tree` 를 빈 tree 로 바꾸고 root 아래 기존 파일을 고치면 `SCOPE_BASELINE_CHANGED`, 파일·기준선 모두 자동 복구 없음, 복구 없이 재실행하면 모델 호출 0회로 다시 중단, 복구 후에만 재개 ⑭ 기준선과 manifest 를 함께 바꾸면 `SCOPE_MANIFEST_CHANGED` 로 먼저 멈추더라도 가드가 남아, manifest 만 고친 재실행은 `SCOPE_BASELINE_CHANGED` 로 모델 0회 재중단. `tests/install-smoke.sh` 8절은 필수 워커 스킬이 없으면 `run_worker` 가 실제로 중단하고 codex 를 부르지 않음, worker 단계 진입 시 원본≠lock 이면 `NEED_USER`/`SCOPE_MANIFEST_CHANGED` 가 실제로 기록되고 codex 를 부르지 않음, 11d 절은 verify 단계의 worker-fix 가 기준선과 범위 밖 파일을 바꿔 멈춘 뒤 테스트가 통과하도록 바뀐 재실행이 테스트·codex·리뷰어 호출 0회로 다시 멈추고 기준선 복구 후에만 DONE 에 이르는지 본다. 그리고 워커가 `worker-baseline.tree` 를 빈 tree 로 바꾸고 root 아래 기존 파일을 고치면 `SCOPE_BASELINE_CHANGED` 로 review 에 들어가지 않고 원복도 하지 않으며, 복구 없이 재실행하면 codex 호출 0회로 다시 멈추고 복구 후에만 워커가 재개됨을 본다. 리뷰 루프·수정자 프롬프트·범위 함수(`config.sh`)를 바꾸면 돌린다. 범위 지문은 `snapshot_worktree_tree` 의 tree 엔트리(모드·유형·blob·경로)와 manifest 자체를 해시하므로 내용뿐 아니라 실행 권한·symlink 목적지·생성/삭제까지 잡는다.

## 토큰 절약 구조 (스크립트에 내장)

- 오케스트레이터는 러너 호출 1회당 턴 1회만 소비한다. 러너 내부의 라운드 진행·재진입은 상위 세션 API 호출을 발생시키지 않는다.
- Claude 하위 실행은 역할별 세션 유지: `designer-doc`, `reviewer`, `fixer`. 첫 호출이 `--session-id`, 이후 `--resume`. `reviewer`와 `fixer`는 절대 같은 세션으로 합치지 않는다.
- 사용량은 `$WORK_DIR/usage.jsonl`에 라운드별 누적. codex는 출력의 "tokens used" 참고.
