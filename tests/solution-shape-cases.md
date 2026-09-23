# REQUIRED / DELEGATED 판정 사례 (material decision vs local implementation expression)

`approach.md` 의 결정 단위를 REQUIRED 로 올릴지 DELEGATED 로 둘지 판정하는 기준은 **기술 범주가 아니라 결정의 영향**이다. 이 문서는 오케스트레이터(문서 작성자)·검증자·워커·리뷰어가 같은 경계를 쓰는지 사람이 대조하는 사례집이다. 실제 모델 호출 회귀(`validator-regression.sh`·`reviewer-regression.sh`·`worker-regression.sh`)와 달리 유료 호출이 없다.

## 역할 모델

```
request/design → designer/orchestrator → implementation.md + approach.md (= material implementation contract)
              → worker (= 계약 안에서 저장소 관례에 맞는 가장 단순한 local 표현을 고르는 제한된 구현자)
              → reviewer (= material 계약·명시 convention·불필요한 standalone abstraction 을 잡는 병합 게이트)
```

합의는 워커의 모든 판단을 제거하기 위한 것이 아니다. 워커가 소유하면 안 되는 제품·아키텍처·solution-shape 판단만 선점한다. 동일한 제품 동작과 책임 경계, 재사용 관계, 안전성 및 의미 있는 비용 특성을 만족하는 local implementation expression 은 워커가 소유한다.

## 규칙

```
               ┌─ 외부 관찰 동작 / 영속 데이터 정합성 / 보안·권한·개인정보 경계 / 사용자 명시 방식·재사용 → 항상 REQUIRED
모든 결정 ─────┤
               ├─ 워커가 고르면 material 항목(아래)이 달라지는가?  ── 예 → REQUIRED (결정 + 근거, 가장 단순한 통상 해법)
               └─ 아니오(외부 동작·책임 배치·재사용 경로·상태 의미·안전성·의미 있는 비용이 같음) → DELEGATED 또는 아예 적지 않음
```

**material decision** = 사용자에게 관찰되는 동작·API 계약 / public·package-level 계약·프레임워크 진입점 계약 / 영속 데이터 모델·정합성 / transaction boundary / concurrency·locking / 보안·권한·개인정보 경계 / layer·module·domain 의 responsibility placement / 기존 공용 책임의 REUSE·EXTEND vs 새 병렬 책임 / sync·async·background 실행 의미 / retry·fallback·cache·error semantics / DB·network·외부 API 호출 topology·횟수 / 실제 요구 규모에서 의미 있게 다른 시간·공간 비용 / 되돌리기 어려운 새 production abstraction·type·state representation / 사용자·명시적 convention 이 직접 요구한 방식.

**local implementation expression** = local 변수 이름 / intermediate local vs inline / 같은 클래스 안의 private helper 추출 vs inline 과 그 signature / if vs switch / 단순 for vs stream / 동일 의미의 SDK·API overload / builder 표현 / 외부 상태·I/O·복잡도에 영향 없는 collection 생성 위치 / 작은 bounded in-memory collection 의 동등한 algorithm 표현 / 반환 직전 local 유무 / 포맷·import·line break / 같은 책임 안의 사소한 private control-flow. 명시적 project convention 이 이 중 하나를 실제 규칙으로 정했으면 convention 이 우선한다.

판별법 한 줄: **두 구현이 request/design/conventions 를 모두 만족하고 외부 동작·책임 배치·재사용 경로·상태 의미·안전성·의미 있는 비용 특성이 동일하다면, 서로 다른 production diff 가 나온다는 사실만으로 문서 공백이 아니다.** 최종 gate 질문: 이 선택을 워커에게 맡겼을 때 제품/아키텍처/책임 경계/상태 의미/I/O 비용/안전성 중 무엇이 달라지는가? 구체적으로 답하지 못하면 REQUIRED 가 아니다.

REQUIRED 로 올린 뒤의 선택 품질 규칙 둘:
1. 후보 중 **가장 단순한 통상 해법**을 고른다. 직접 범위의 precedent → 언어·플랫폼·표준 라이브러리의 표준 기능 → 직접적인 최소 구현 순. 새 추상화·새 의존성·별도 상태 구조는 앞선 방법보다 요구·기존 계약·필요한 비용 특성을 더 직접적이고 단순하게 만족한다는 구체적 이유가 있을 때만 고르고 이유를 적는다.
2. **금지는 기본적으로 쓰지 않는다.** 특정 대안이 요구 불변식이나 선택한 접근법을 깨뜨릴 때만 적고, 금지 이유와 지켜야 할 불변식(또는 허용 대안)을 함께 적는다.

단순성 의무: 문서가 새 production structure 를 직접 요구하려 할 때 "요구사항·책임 경계·상태 모델 때문에 필요한가, 워커 선택을 제거하려고 만든 구조인가" 를 먼저 묻고 후자면 만들지 않는다(`SendOutcome`/`Kind`/`ResultContext`/`resultOf` 류).

## 사례

1~7 은 material decision 이라 REQUIRED 인 결정, 8~15 는 local implementation expression 이라 문서가 정하지 않는(정해 두었더라도 리뷰어가 blocker 로 삼지 않는) 결정이다. 한쪽만 맞히는 판정은 실패다.

| # | 결정 | 기대 | 무엇이 달라지는가 | 함정 |
|---|---|---|---|---|
| 1 | 항목 n 개의 상세 조회. 일괄 조회 vs 루프 안 n 번 개별 조회 | REQUIRED | DB/API 호출 횟수 1 vs n | "둘 다 같은 결과" 는 DELEGATED 근거가 아니다. `validator-cases/case-21`(BLOCK)·`reviewer-cases/case-24`(DOC_GAP) |
| 2 | 외부 gateway 실패 시 재시도 여부·횟수 | REQUIRED | 외부 호출 횟수(건당 과금)·실패 semantics | design 이 "구현이 정한다" 고 했어도 material 이다. `validator-cases/case-22` |
| 3 | "A 는 B 를 사용해 items 를 처리한다". A 가 항목마다 판정하고 B 를 호출 vs B 가 목록 전체를 받아 판정·조립 | REQUIRED | 판정·조립 책임 위치와 B 의 public 계약 | `validator-cases/case-13`(BLOCK)·`case-14`(PASS — 책임 위치만 정하면 충분, pseudocode 불필요) |
| 4 | 입력 정규화에 같은 모듈의 `normalizePhone` 과 `PhoneFormatter.canonical` 이 공존 | REQUIRED | 재사용 경로가 갈리고 기존 호출자와의 일관성이 달라진다 | precedent 가 둘 경쟁하므로 작성자가 하나를 고르고 인용한다 |
| 5 | 같은 책임의 새 repository/service/helper 를 만들지 기존 것을 EXTEND 할지 | REQUIRED (REUSE/EXTEND/NEW + 탐색 근거) | 병렬 책임 생성 | `validator-cases/case-11`(BLOCK)·`case-12`(PASS)·`reviewer-cases/case-13` |
| 6 | DB lock vs Redis lock, transaction 안에서의 상태 변경 순서, sync vs async | REQUIRED | 상태 의미·동시성·실패 방식 | 결과가 같아 보여도 material |
| 7 | 화면 요소 조건부 강조. CSS 선택자 vs 새 상태 값 + JS 토글 | REQUIRED | 새 state representation 과 렌더 흐름 | 백엔드 예시가 아니어도 같은 규칙 |
| 8 | 조회 결과를 지역 변수에 두고 DTO 생성자에 넘길지, 직접 반환할지, 같은 클래스 private helper 로 뺄지 | local (문서가 정하지 않음) | 아무것도 — 책임·재사용·동작·비용 같음 | `reviewer-cases/case-21`(helper 추출 → APPROVE), `validator-cases/case-19` |
| 9 | 같은 역할의 값 이름이 `client`/`found`/`entity` 로 제각각 | local | 없음(convention 이 명명 규칙을 정한 경우만 예외) | `reviewer-cases/case-22`·`case-06`(APPROVE), `worker-cases/case-04`(DOC_GAP 을 내면 FAIL) |
| 10 | 필터·변환을 stream 체인으로 쓸지 for 루프로 쓸지 | local | 없음(주변 코드 관례를 따르는 것은 워커 몫) | 스킬이 특정 construct 를 선호하지 않는다 |
| 11 | 같은 동작의 SDK overload 중 하나 | local | 없음 | `reviewer-cases/case-26`·`validator-cases/case-20` |
| 12 | 목록 A 의 항목이 목록 B 에 있는지 확인. bounded in-memory 목록에서 선형 `contains` vs Set | local | 요구 규모에서 의미 있는 비용 차이 없음 | 목록이 unbounded/hot path 이거나 B 가 외부 조회면 사례 1 이다. `reviewer-cases/case-12`(APPROVE) |
| 13 | in-memory Map 에 건마다 add vs 사전 합산 뒤 add | local | 없음(I/O 없음) | `validator-cases/case-18`(PASS) |
| 14 | 정규식 한 번 vs 수동 스캔으로 연속 하이픈 축약 | local | bounded 문자열에서 결과·비용·구조물 동일 | `validator-cases/case-09`(PASS) |
| 15 | 들여쓰기·줄바꿈·import 정렬·compiler 가 강제하는 문법 | local (tool trivia) | 없음 | `reviewer-cases/case-23`(APPROVE) |

반례(워커 자유가 아닌 것): 문서가 요구하지 않은 standalone `SendOutcome` + `Kind` + `resultOf` 를 추가해 branch 결과를 한 번 더 타입으로 감싼 경우 — 제거해도 동작·책임·검증이 그대로이므로 리뷰어 `REDUNDANT_CODE` (`reviewer-cases/case-25`). 워커의 local 자유는 "가장 단순한 표현을 고를 권리" 이지 새 구조를 만들 권리가 아니다.

## 판정 후 자기 점검

approach.md 를 쓴 뒤 REQUIRED 항목마다 다음을 확인한다.

- 이 결정을 워커에게 맡기면 제품/아키텍처/책임 경계/상태 의미/I/O 비용/안전성 중 무엇이 달라지는지 한 줄로 적을 수 있는가. 못 적으면 REQUIRED 가 아니다.
- 근거가 줄 범위 인용(`path:L40-L68`) 또는 표준 기법 + 이유인가. reference 가 있으면 무엇을 고정하는지(책임 배치·재사용·material control-flow)와 달라지는 지점이 적혀 있는가.
- helper 여부·local 이름·intermediate·if/switch·for/stream·overload·pseudocode 를 diff 동일성 목적으로 적지 않았는가.
- 새 production 구조물을 요구했다면 요구·책임 경계·상태 모델 때문인가, 워커 선택을 제거하려는 것인가.
- 고른 접근법이 후보 중 가장 단순한 통상 해법인가.
- 금지 문구가 있다면 이유와 불변식(또는 허용 대안)이 붙어 있는가.

검증자는 반대 방향을 본다: material 접근법이 비어 있으면 `REQUIREMENT_MISSING`, 접근법은 정해졌지만 material 구현 계약 하나가 열려 있으면 `CODE_SPEC_GAP` 으로 REVISE_DOC 을 내되(일곱 입장 조건 + "무엇이 달라지는가" gate), 어느 쪽을 고를지는 처방하지 않는다. local expression 으로는 blocker 를 만들지 않는다. 워커는 material 선택을 문서·reference·convention·직접 범위 precedent 어디서도 찾지 못하면 스스로 고르지 않고 `DOC_GAP` 으로 돌려보내고, local 선택은 직접 정한다. 검증자와 워커가 둘 다 놓쳐 워커가 material 선택을 골라 버린 경우 리뷰어가 `UNDECIDED_APPROACH` + `DOC_GAP` 으로 문서 단계로 되돌린다. 문서가 정한 material 계약과 다르게 쓴 경우는 동작이 같아도 `CONTRACT_VIOLATION`, 불필요한 standalone abstraction 은 `REDUNDANT_CODE` 다.

새 responsibility boundary(같은 책임의 repository·service·helper, 기존 공용 converter·query path 와 경쟁하는 경로, 공유 abstraction, infrastructure component)를 도입하는 결정은 `REUSE / EXTEND / NEW` 를 명시하고, NEW 에는 같은 모듈·직접 의존 코드에서 확인한 symbol·가장 가까운 후보·REUSE/EXTEND 불가 이유를 적는다. 새 API 계약에 대응하는 DTO/command, 새 table 에 대응하는 entity, design 이 존재를 확정한 feature-local value carrier, 같은 클래스 안의 private helper 는 이 근거의 대상이 아니다(`validator-cases/case-19`).
