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
| 2 | `NEED_USER` | `DEADLOCK` / `MAX_ROUNDS` | 마지막 리뷰 JSON의 쟁점만 사용자에게 보고하고 멈춘다. 답을 `decisions.md`에 `[USER-QUESTION]`으로 기록, 해당 문서에 반영 후 재실행 |
| 3 | `NEED_DOCS` | `APPROACH_GAP` | 워커 `undecided`가 전부 `DOC_GAP`(제품 동작은 정해져 있는데 `approach.md`에 그 분기·방식만 누락). **사용자에게 묻지 않고** 오케스트레이터가 `approach.md`를 보강한 뒤 재실행(검증자 재합의 → worker 재개) |
| 2 | `NEED_USER` | `UNDECIDED` | `undecided`에 `USER_DECISION`(어느 문서에도 없는 제품 정책 선택)이 하나라도 있음. 그 항목만 **합의 루프 없이 그대로 사용자에게 질문**, 함께 온 `DOC_GAP`은 오케스트레이터가 보강. 답 기록 → `approach.md` 반영 → 재실행 |
| 2 | `NEED_USER` | `TEST_RETRIES_EXHAUSTED` / `APPROVAL_STALE_REPEATED` | 로그(`reviews/verify-*.log`)와 상황을 정리해 사용자 보고 후 멈춘다 |
| 1 | `ENV_ERROR` | — | 원인 확인 후 재실행. 진행 금지 |

재실행은 항상 같은 명령이다. 러너가 `run-state.json`의 stage 힌트와 실제 산출물(합의 PASS 파일, `worker-result.json`, `approved.fingerprint`)을 교차 확인해 재개 지점을 스스로 고른다 — 오케스트레이터가 단계를 지정하지 않는다.

### 구현 문서 작성 (`IMPL_DOCS_MISSING` 반환 시)

합의된 `design.md` 기반으로 두 파일을 쓴다. 설계 합의를 재해석·번복하지 않는다.

1. `.agent-work/implementation.md` — **무엇을** 구현하는가(도메인 지식). 변경·생성 파일 목록과 순서, 클래스/함수 수준 계획(시그니처·입출력 계약), 작성할 테스트 목록, 완료 판정 기준.
2. `.agent-work/approach.md` — **어떻게** 구현하는가(CS 지식). 단위는 함수가 아니라 **구현 결정**이며, 결정마다 `REQUIRED` 또는 `DELEGATED`를 표시한다.
   - **DELEGATED가 기본값이다.** 다음 중 하나에 해당하는 선택만 **REQUIRED**: ① 선택에 따라 외부에서 관찰되는 동작이 달라진다 ② 영속 데이터의 정합성이 달라진다 ③ 보안·권한·개인정보 경계가 달라진다 ④ 사용자가 특정 구현 방식이나 기존 코드 재사용을 명시적으로 요구했다. REQUIRED에는 기법·구조·금지 방식을 적고 근거를 붙인다: 저장소에 같은 종류의 문제를 푸는 기존 코드가 있으면 그 줄 범위를 직접 열어 확인한 뒤 인용 → 없으면 표준 기법 + 선택 이유.
   - **DELEGATED(위임)** — 그 밖의 로컬 구현 방식 전부(trim 호출 위치, 헬퍼 배치, 일반적 파싱·변환·검증, 일상적 트랜잭션·예외 처리·DTO·mapper). 기법을 적지 않는다. 워커가 "기존 패턴 우선 → 표준 라이브러리 우선 → 새 추상화 금지" 제약 안에서 정하고 결과 JSON의 `delegated_choices`에 보고하며, 리뷰어는 그 목록으로 제약 위반만 검사한다. 예: `공백 입력이 오류인가 무시인가` = REQUIRED(외부 동작), `trim을 어디서 호출하나` = DELEGATED.
   - **제어 흐름 절(선택)** — 외부 동작이나 상태 변경 결과가 갈리는 함수에 "허용된 결정점을 열거하고 그 외 동작 분기를 금지"하는 계약을 쓴다. 모든 함수에 쓰지 않는다. 절이 있는 함수는 REQUIRED 계약이고, 없는 함수의 로컬 제어 흐름은 DELEGATED 다(단 워커는 문서에 없는 외부 동작·상태 결과를 새로 정하지 못하고, 리뷰어는 그런 추가를 UNDECLARED_BRANCH 로 잡는다). 계약 대상은 구문상의 조건문이 아니라 **동작을 달리하는 결정점**이다(루프 종료·관용적 빈값 확인·API 예외 변환·값 계산 boolean·exhaustive match 는 열거하지 않는다). 소스에 분기 ID 주석을 요구하지 않는다 — 대응은 리뷰어가 결과 JSON `decision_points` 로 제시한다. 워커는 열거된 결정점만 구현하고 추가가 필요하면 UNDECIDED 로 돌려보낸다. 형식:
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

- **검증자는 게이트지 설계자가 아니다.** REVISE_DOC은 여섯 가지 입장 조건(요구·결정·계약 위반 / 근거: 문서 대조 DIRECT_MISMATCH 또는 실행 경로 REACHABLE_FAILURE / 명시 계약과 다른 결과·권한·비밀·영속 데이터·구현 불가 영향 / 이번 변경이 만들거나 활성화 / 지금 결정 없이는 진행 불가 / 정확한 근거 위치)을 모두 만족할 때만, ASK_USER는 별도 네 조건(어디에도 미결정 / 동작·데이터·보안·범위가 갈림 / 기존 계약·패턴이 확정 못 함 / 없이는 시작 불가)을 만족할 때만 등록된다. 스키마와 러너가 근거 필드, 사용하지 않는 필드의 공백, id 유일성, Round 2 `origin`의 형식과 참조 대상 존재(직전 이슈 id, docs diff에서 실제 바뀐 파일)를 강제하며 어긋나면 검증자 응답 오류로 중단한다. 수정과 신규 blocker 사이의 의미적 인과관계까지 러너가 보장하지는 않는다 — 그것은 `tests/validator-cases.md` 감도 회귀 세트의 몫이다. 순수 정책 미결정은 `POLICY_UNDECIDED` + `UNDECIDED_CHOICE`로 표현해 충돌 계약이나 실패 경로를 지어내지 않게 한다. 검증자 프롬프트·스키마·러너 검사 중 하나라도 바뀌면 `config.sh`의 `VALIDATOR_CONTRACT_VERSION`을 올린다. 러너가 그 값과 다른 이전 PASS를 자동 무효화하므로 `--new` 없이 재실행하면 된다. 검증자는 최소 불변식만 요구하고 해결 방법을 처방하지 않는다. 디자이너는 5단계 판정을 거쳐 REJECT하고, ACCEPT해도 검증자의 처방을 복사하지 않는다. Round 1은 전부, Round 2부터는 직전 이슈 종결 검토와 직접 회귀만. 파이프라인 운영(git 기준선·지문·테스트 순서)은 러너 책임이며 문서 blocking 사유가 아니다.
- **막히면 AI끼리 풀지 말고 사용자에게 묻는다.** 러너가 자동으로 도는 루프는 성공 조건이 기계적인 두 가지뿐 — (리뷰 이슈 → 수정자 → 재리뷰), (테스트 실패 → 워커 1회 수정 → 재리뷰 → 재테스트). 교착·라운드 초과·`UNDECIDED`·재시도 소진은 전부 즉시 사용자 반환이며, 러너·오케스트레이터 어느 쪽도 "다른 에이전트에게 다시 물어보는" 자동 복구를 추가하지 않는다.
- **테스트는 동작 계약 검증용이다** — 작성 순서는 강제하지 않는다. 워커는 `implementation.md`가 명시한 동작 계약을 검증하는 테스트만 쓰고, 테스트 편의만을 위한 운영 API·분기·추상화·가시성 변경과 커버리지 수치 목적의 테스트는 금지. 문서에 없는 테스트는 리뷰어가 issue 로 올린다.
- **구현 방식(어떻게)의 REQUIRED 결정은 워커가 정하지 않는다** — `approach.md`에서 오케스트레이터가 결정하고 검증자가 합의한다. 워커·수정자가 REQUIRED와 다른 기법을 쓰면 리뷰어가 문서 위반으로 잡는다. DELEGATED는 워커 선택을 존중하되 세 제약 위반만 issue.
- 모호한 요구·갈리는 설계 판단은 추측 금지 — 사용자 질문 후 문서 반영, `decisions.md`에 `- [USER-QUESTION] <질문> → <답>` 기록.
- 판정은 스키마 검증된 JSON만 신뢰한다: 검증자(`PASS/BLOCK`), 리뷰어(`APPROVE/REQUEST_CHANGES`), 워커(`DONE/UNDECIDED`, `schemas/worker-result.schema.json`). 모순 응답은 스크립트가 즉시 거부. "대충 통과 간주" 금지.
- 하위 실행은 반드시 `--model`/`-m` 명시(`config.sh` 한 곳에서 관리). `core_rules.md`는 워커에게만, 선택 `conventions.md`는 전 역할에 주입. 프로젝트 codex hooks(`.codex/hooks.json` + `worker_guard.sh`)는 매 툴 호출에 별도 적용.
- **워커(codex)와 리뷰어·수정자는 파일 삭제 절대 금지** — 훅이 강제한다(claude 쪽 `pre_bash_guard`, codex 쪽 `worker_guard`). 러너의 `--new` 아카이브도 `mv`만 쓴다. 삭제가 필요하면 `decisions.md`에 대상·사유를 남기고 사용자 에스컬레이션.
- 워커·리뷰어·수정자는 커밋·푸시 금지. 커밋은 사용자가 요청했을 때만 — `DONE` 이후 오케스트레이터가 `verify_approved_fingerprint`(config.sh)로 승인 지문을 재확인하고 `touch .claude/ALLOW_COMMIT`(1회용 플래그) 후 `fixer` 세션에 별도 호출로 위임.
- 마지막 APPROVE 이후 코드가 조금이라도 바뀌면 재리뷰 없이 종료 금지 — 러너의 verify 단계가 지문으로 강제한다.
- 모든 하위 실행은 stdin을 닫고 돌린다(스크립트 시작부 `exec </dev/null`). 러너를 다른 명령·heredoc과 한 줄로 묶지 않는다.
- **진행 확인은 "프로세스 생존"이 아니라 "실제 진척"으로 판정** — `live.log` 최근 갱신과 CPU 시간 증가를 본다. 둘 다 멈춰 있으면 입력 대기·행(hang)이다: 해당 PID만 TERM으로 정리하고(`pkill` 광역 금지) 원인 확인 후 같은 명령으로 재실행하면 러너가 재개 지점을 찾는다. 중단된 라운드 산출물은 archive로 옮긴다.

## 토큰 절약 구조 (스크립트에 내장)

- 오케스트레이터는 러너 호출 1회당 턴 1회만 소비한다. 러너 내부의 라운드 진행·재진입은 상위 세션 API 호출을 발생시키지 않는다.
- Claude 하위 실행은 역할별 세션 유지: `designer-doc`, `reviewer`, `fixer`. 첫 호출이 `--session-id`, 이후 `--resume`. `reviewer`와 `fixer`는 절대 같은 세션으로 합치지 않는다.
- 사용량은 `$WORK_DIR/usage.jsonl`에 라운드별 누적. codex는 출력의 "tokens used" 참고.
