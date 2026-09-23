# REQUIRED / DELEGATED 판정 사례 (solution shape + code-spec)

`approach.md` 의 결정 단위를 REQUIRED 로 올릴지 DELEGATED 로 둘지 판정하는 기준은 **기술 범주가 아니라 결정의 영향**이다. 이 문서는 오케스트레이터(문서 작성자)·검증자·워커·리뷰어가 같은 경계를 쓰는지 사람이 대조하는 사례집이다. 실제 모델 호출 회귀(`validator-regression.sh`·`reviewer-regression.sh`)와 달리 유료 호출이 없다 — approach.md 를 쓰거나 검토할 때 아래 표에 대보는 용도다.

## 역할 모델

```
request/design → designer/orchestrator → implementation.md + approach.md (= 구현할 코드의 실행 가능한 사양)
              → worker (= 사양서를 실제 repository 문법으로 옮기는 타이피스트)
              → reviewer (= 코드가 사양과 repository 규칙을 그대로 구현했는지 검증)
```

워커는 architecture, solution shape, 주요 데이터/제어 흐름, 기존 기능 재사용 방식, 새 구조물 필요 여부, 함수 분해, 처리 순서, branch 구조, iteration 방식, 의미 있는 intermediate value, 변수 역할과 이름, 기존 API 의 어떤 호출 형태를 쓸지, private helper 구성, 호출부/피호출부 책임 분배를 새로 결정하는 주체가 아니다. 이 선택은 원칙적으로 문서 단계에서 끝난다.

## 규칙

```
               ┌─ 외부 관찰 동작 / 영속 데이터 정합성 / 보안·권한·개인정보 경계 / 사용자 명시 방식·재사용 → 항상 REQUIRED
모든 결정 ─────┤
               ├─ 워커가 고르면 solution shape 가 달라지는가?  ── 예 → REQUIRED (기법 + 근거)
               ├─ 두 워커가 문서를 지키면서 서로 다른 non-trivial diff 를 만들 수 있는가? ── 예 → REQUIRED (code-spec: 위치·순서·구조·이름을 하나로, 필요하면 pseudocode)
               └─ 차이가 formatter / import 정렬 / compiler / 저장소 단일 표현 수준뿐 → DELEGATED (기법을 적지 않는다)
```

solution shape = 해결 전략과 주요 데이터/제어 흐름, 비용 특성(시간·공간·I/O·동기화), 기존 기능 재사용 vs 새 구현, 새 구조물(헬퍼·클래스·모듈·의존성) 필요 여부, 실패 방식.

non-trivial diff = 다른 control flow, 다른 processing order, 다른 helper 분해, 다른 aggregation 위치, 다른 reusable symbol, 다른 API 사용 pattern, 의미 있는 local 변수 구조, 다른 naming pattern, 다른 collection construction pattern.

판별법 한 줄: **같은 문서를 받은 유능한 두 워커가 서로 구조적으로 다른 코드를 쓸 수 있다면, 그 차이가 formatter/compiler 가 정하는 수준이 아닌 이상 문서는 아직 불완전하다.**

표현 선택의 결정 순서: ① 프로젝트 convention → ② 인용한 reference code → ③ 직접 범위(같은 모듈·직접 의존 코드)의 동일 책임 precedent → ④ 오케스트레이터 판단. ①~③ 이 하나로 정하면 그 위치를 줄 범위로 인용하는 한 줄로 고정한다 — 워커가 찾게 두지 않는다. precedent 가 여럿이면 ④ 로 하나를 고른다. 저장소 전체에서 유일함을 증명하려 하지 않는다 — 세 역할(작성자·검증자·리뷰어)이 같은 직접 범위를 본다.

REQUIRED 로 올린 뒤의 선택 품질 규칙 둘:
1. 후보 중 **가장 단순한 통상 해법**을 고른다. 직접 범위의 precedent → 언어·플랫폼·표준 라이브러리의 표준 기능 → 직접적인 최소 구현 순. 새 추상화·새 의존성·별도 상태 구조(상태 머신, 임시 버퍼, 사전 인덱스)는 앞선 방법보다 요구·기존 계약·필요한 비용 특성을 더 직접적이고 단순하게 만족한다는 구체적 이유가 있을 때만 고르고 이유를 적는다. 소유권만 회수하고 이 규칙이 없으면 "수동 상태 머신으로 구현 [REQUIRED]" 가 나오고 워커는 이전보다 더 충실하게 장황한 코드를 만든다.
2. **금지는 기본적으로 쓰지 않는다.** 특정 대안이 요구 불변식이나 선택한 접근법을 깨뜨릴 때만 적고, 금지 이유와 지켜야 할 불변식(또는 허용 대안)을 함께 적는다. 수단 이름만 단독으로 금지하지 않는다.

과잉 명세 > 과소 명세: 필요 없는 정보는 쓰지 않되, 워커가 구현 선택을 해야 하는 것보다는 상세한 문서가 낫다. 최적화 목표는 문서 길이가 아니라 구현 결과의 예측 가능성과 저장소 일관성이다.

## 사례 14개

1~5 는 solution shape 가 갈려 REQUIRED 인 결정, 6~10 은 접근법은 같지만 code-spec 이 갈려 REQUIRED 인 결정(이전 계약에서는 DELEGATED 였다), 11~14 는 DELEGATED 로 남길 수 있는 결정이다. 세 묶음 중 한쪽만 맞히는 판정은 실패다.

| # | 결정 | 기대 | 갈리는 둘과 영향 (REQUIRED 라면 한 줄로 적혀야 함) | 함정 |
|---|---|---|---|---|
| 1 | 연속 중복 토큰을 한 번에 축약. 정규식 `{2,}` 그룹 한 번 vs 문자 단위 수동 스캔 + 상태 변수 | REQUIRED (shape) | 해결 전략이 다르고, 수동 스캔은 상태 머신·임시 버퍼가 필요해 코드량이 몇 배가 된다 | 결과 문자열이 같으니 "외부 동작 불변 → DELEGATED" 로 빠지는 것이 사고의 형태다 |
| 2 | 목록 A 의 각 항목이 목록 B 에 있는지 확인. 항목마다 B 선형 탐색 vs B 를 Set 으로 만들어 조회 | REQUIRED (shape) | 비용 특성이 O(n·m) 과 O(n+m) 으로 다르고, 사전 인덱스는 중간 자료구조를 하나 더 만든다 | "자료구조 선택이니까"가 아니라 순회 횟수·비용이 갈리기 때문이다 |
| 3 | 화면 요소 조건부 강조. CSS 선택자 vs 상태 값 추가 + JS 클래스 토글 | REQUIRED (shape) | 새 상태(구조물)와 렌더 흐름이 달라지고, 한쪽은 코드가 거의 없다 | 백엔드 예시가 아니어도 같은 규칙이 먹는다 |
| 4 | 항목 n 개의 상세 조회. 일괄 조회 vs 루프 안 n 번 개별 조회 | REQUIRED (shape) | I/O 횟수가 1 vs n | "둘 다 같은 결과" 는 DELEGATED 근거가 아니다 |
| 5 | 입력 정규화에 같은 모듈의 `normalizePhone` 과 `PhoneFormatter.canonical` 이 공존 | REQUIRED (shape) | 재사용 vs 새 구현이 갈리고 어느 유틸을 쓰느냐로 기존 호출자와의 일관성이 달라진다. 하나를 골라 줄 범위를 인용한다 | precedent 가 둘 이상 경쟁하므로 ③ 이 정하지 못한다 — ④ 가 정한다 |
| 6 | "A 는 B 를 사용해 items 를 처리한다". A 가 항목마다 판정하고 B 를 호출 vs B 가 목록 전체를 받아 판정·조립을 완료 | REQUIRED (code-spec) | 판단 위치·collection 조립 위치·호출 관계가 다른 두 diff 가 모두 문서를 지킨다 | 접근법("한 번 순회, B 재사용")이 정해졌다고 끝이 아니다. `validator-cases/case-13`(BLOCK)·`case-14`(PASS) |
| 7 | 이미 "정규식 한 번" 이 정해진 뒤 `Pattern` 을 static 상수로 둘지 메서드 지역 변수로 둘지 | REQUIRED (code-spec) | 클래스 구조와 diff 가 다르다. 직접 범위 precedent 가 있으면 인용, 없으면 작성자가 정한다 | 이전 계약에서는 DELEGATED 였다. `validator-cases/case-10` 은 이제 결정 3 으로 이것을 정한다 |
| 8 | 조회 결과를 지역 변수 `client` 에 두고 다음 줄에서 DTO 생성자에 넘길지, 호출 결과를 직접 반환할지, private helper 로 뺄지 | REQUIRED (code-spec) | helper 분해·local 구조가 다르다. 참조 precedent 가 있으면 "그 구조 복제" 한 줄로 고정한다 | `reviewer-cases/case-21`(helper 추출 → REQUEST_CHANGES) |
| 9 | 같은 역할의 값 이름이 `changes` / `changeContexts` / `logs` / `result` 로 제각각일 수 있음 | REQUIRED (code-spec) | 사람이 diff 를 읽을 때 의미·일관성이 달라진다. 직접 precedent 가 있으면 그 이름, 없으면 작성자가 하나를 정한다 | loop index 나 compiler 급 이름까지 강제하지는 않는다. `reviewer-cases/case-22`(문서가 `client` 로 정함 → `found` 는 REQUEST_CHANGES), `case-06`(문서가 정하지 않음 → APPROVE) |
| 10 | 필터·변환을 stream 체인으로 쓸지 for 루프로 쓸지. 주변 코드는 for 루프 | REQUIRED (code-spec, precedent 인용) | 제어 구문 형태가 다른 diff. 저장소가 정한다 — 주변 코드가 반복문이면 반복문 | 스킬이 특정 construct 를 선호하지 않는다. precedent 가 하나면 인용 한 줄, 여럿이면 작성자가 고른다 |
| 11 | 들여쓰기·줄바꿈·인자 개행·빈 줄 | DELEGATED | formatter 가 정한다 | `reviewer-cases/case-23`(APPROVE) |
| 12 | import 정렬 순서 | DELEGATED | import 정렬 도구가 정한다 | 같은 사례 |
| 13 | 언어가 강제하는 문법적 세부(exhaustive match, 필수 예외 변환, 타입 명시) | DELEGATED | compiler 가 정한다 | 결정점이 아니다 — 리뷰어의 "issue 가 아닌 것" 과 같은 항목 |
| 14 | 결과 컨테이너 생성 표현. 저장소 전체가 `new ArrayList<>()` 하나만 쓰고 접근법("한 번 순회하며 append")은 정해짐 | DELEGATED | 저장소에 하나의 명백한 표현만 있어 판단이 필요 없다 | 표현이 둘 이상 공존하면 DELEGATED 가 아니라 문서가 정한다(사례 7·10) |

## 판정 후 자기 점검

approach.md 를 쓴 뒤 REQUIRED 항목마다 다음을 확인한다.

- 갈리는 둘(접근법 또는 코드 구조)과 영향 하나가 **한 줄로** 적혀 있는가.
- 근거가 줄 범위 인용(`path:L40-L68`) 또는 표준 기법 + 이유인가. reference 가 있으면 "복제하되 달라지는 지점" 이 적혀 있는가.
- 호출 symbol·호출 형태·호출 순서·판단 위치·collection/aggregation 위치·helper 여부·의미 있는 local 의 역할과 이름이 하나로 정해져 있는가. 워커가 오해할 부분은 pseudocode 로 적었는가.
- DELEGATED 로 남긴 것이 formatter·import 정렬·compiler·저장소 단일 표현뿐인가. "쓰기 번거로워서" 남긴 DELEGATED 는 없는가.
- 고른 접근법이 후보 중 가장 단순한 통상 해법인가. 별도 상태 구조·새 추상화를 골랐다면 더 단순한 방법으로 요구를 표현할 수 없는 이유가 적혀 있는가.
- 금지 문구가 있다면 이유와 불변식(또는 허용 대안)이 붙어 있는가.

검증자는 반대 방향을 본다: 접근법이 갈리는 결정이 비어 있으면 `REQUIREMENT_MISSING`, 접근법은 정해졌지만 두 워커가 서로 다른 non-trivial diff 를 만들 수 있으면 `CODE_SPEC_GAP` 으로 REVISE_DOC 을 내되, 어느 쪽을 고를지는 처방하지 않고 "이 implementation point 가 아직 두 가지 이상의 코드 구조를 허용한다" 와 그 둘만 돌려보낸다. 워커는 그런 선택을 문서·reference·직접 범위 precedent 어디서도 찾지 못하면 스스로 고르지 않고 `DOC_GAP` 으로 돌려보낸다. 검증자와 워커가 둘 다 놓쳐 워커가 골라 버린 경우 리뷰어가 `UNDECIDED_APPROACH` + `DOC_GAP` 으로 문서 단계로 되돌린다 — 리뷰어도 어느 쪽이 나은지는 적지 않는다. 문서가 정한 것과 다르게 쓴 경우는 동작이 같아도 `CONTRACT_VIOLATION` 이다.

실제 검증자가 이 경계를 잡는지는 `validator-cases/case-09-approach-undecided-scan`(BLOCK)·`case-10-expression-only-delegated`(PASS)·`case-13-code-spec-control-flow-gap`(BLOCK)·`case-14-code-spec-blueprint`(PASS)·`case-15-code-spec-scope-pass`(문서가 소유하지 않은 포인트 발굴 금지, PASS)·`case-16-duplicate-suppression`(REUSE_DISCOVERY_GAP 정확히 1건)·`case-17-test-detail-non-block`(테스트 내부는 code-spec 아님, PASS)·`case-18-real-code-spec-gap`(CODE_SPEC_GAP 정확히 1건) 가, 리뷰어가 마지막 방어선으로 잡는지는 `reviewer-cases/case-12-undecided-approach`(UNDECIDED_APPROACH / DOC_GAP)·`case-21-reference-pattern-deviation`·`case-22-naming-local-precedent-deviation`(CONTRACT_VIOLATION)·`case-23-formatter-trivia-only`(APPROVE) 가 고정한다.

재사용 vs 새 구현이 solution shape 의 일부이므로 새 구조물(repository·service·helper·converter·query/변환 경로)을 도입하는 결정은 `REUSE / EXTEND / NEW` 를 명시하고, NEW 에는 같은 모듈·직접 의존 코드에서 확인한 symbol·가장 가까운 후보·REUSE/EXTEND 불가 이유를 적는다. REUSE/EXTEND 는 symbol 이름만 쓰지 말고 어떤 호출 형태로 어떻게 사용하는지까지 적는다. 근거 없는 NEW 는 검증자 `REUSE_DISCOVERY_GAP`(`validator-cases/case-11`, BLOCK), 근거 있는 NEW 는 통과(`case-12`, PASS), REUSE 로 정해진 symbol 옆의 병렬 구현은 리뷰어 `CONTRACT_VIOLATION`(`reviewer-cases/case-13`) 이 고정한다.
