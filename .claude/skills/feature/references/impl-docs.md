# 구현 문서 작성 (`IMPL_DOCS_MISSING` / `SCOPE_MISSING`)

> feature 스킬 참조 문서(`SKILL.md` 에서 분리한 원문). 읽는 시점: `NEED_DOCS(IMPL_DOCS_MISSING)`·`NEED_DOCS(SCOPE_MISSING)` 반환 직후, 그리고 implementation.md·approach.md·feature-scope.json·implementation-units.json 을 쓰거나 고치기 직전. 본문의 "Phase 0 3번/4번" 은 `references/phase0-design.md` 다.

### 구현 문서 작성 (`IMPL_DOCS_MISSING` 반환 시)

합의된 `design.md` 기반으로 네 파일을 쓴다. 설계 합의를 재해석·번복하지 않는다. `IMPL_DOCS_MISSING` 반환 출력 끝의 `[PROJECT CONVENTIONS]` 블록(worktree 사본)과 대조해 적용 규칙을 REQUIRED 로 반영한다(Phase 0 3번과 같은 절차). material decision 마다 Phase 0 4번의 세 가지(요구 출처 · 컨벤션 대조 · 실제 코드 경로)를 확인한 뒤에 적는다 — design 에 없는 제품 동작을 구현 문서에서 새로 추가하지 않는다.

1. `.agent-work/implementation.md` — **무엇을** 구현하는가(도메인 지식)를 **material implementation contract** 수준으로 확정한다. 계획서가 아니지만 코드 blueprint 도 아니다 — 워커가 제품·아키텍처·책임 경계·재사용 관계·비용 특성을 새로 선택하지 않을 만큼만 구체화한다.
   구현 대상마다 필요한 것만 확정한다: 변경·생성 대상 / material public·package symbol 과 signature / 입력·출력 계약 / 책임 경계(누가 판단·조립하는가) / 외부 상태 변경 / 중요한 호출 관계 / 중요한 상태 변경 순서 / 테스트할 observable behavior / 테스트 계약.
   자동으로 쓰지 않는 것: private helper 이름·개수, local 변수 이름, local collection 배치, for/stream, 동일 overload 중 하나, 의미 차이 없는 intermediate result type, production pseudocode(material control-flow 가 복잡해 오해를 막을 때만).
   형식 예:
   ```
   File: <path>
   Function: A.process(input) -> Result
   변경: 기존 X 조회 유지 · Y.build(...) 호출 추가 · 반환된 Z 를 P.publish(...) 에 전달 · 기존 inline 변환 로직 제거
   호출 순서: 1. X 획득 → 2. Y 호출 → 3. 실패 결과면 즉시 반환 → 4. 성공 결과를 P 에 전달 → 5. 결과 반환
   ```
3. `.agent-work/feature-scope.json` — 이번 피처가 변경·생성하는 **정확한 경로 목록**. `implementation.md` 의 파일 목록을 기계가 읽는 형태로 옮긴 것이며 자연어 목록을 러너가 해석하지 않는다. `files` 의 경로는 생성·수정·삭제가 모두 허용된다. 정확한 파일명을 미리 정할 수 없는 생성 경로(마이그레이션 등)만 `new_file_roots` 에 디렉터리 접두로 최소한만 두며, **그 아래는 워커 진입
   기준선(`worker-baseline.tree`)에 없던 경로의 생성·수정(A/M)만 허용**된다 — 이 피처가 만든 파일은 이후 라운드의 수정자·worker-fix 가 다시 고칠 수 있지만 삭제·유형 변경(D/T)은 위반이고, 기준선에 있던 파일의 수정·삭제도 `SCOPE_VIOLATION` 이다(소유 분류는 호출별 A/M 이 아니라 기준선 존재 여부).
   기준선 tree 는 호출 전에 읽어 사후 판정에 넘기며 호출 중 파일이 바뀌면 `SCOPE_BASELINE_CHANGED` 로 중단한다. 경로는 canonical 이어야 한다(선행 `./`·후행 `/`·`..` 금지). 러너는 워커 진입 시 이 파일을 `feature-scope.lock.json` 으로 확정하고, 이후 모든 검사·diff·지문은 lock 을 쓴다
   — 워커·수정자가 manifest 를 고쳐 범위를 넓히면 `SCOPE_MANIFEST_CHANGED` 로 중단한다. 범위를 바꾸려면 원본을 고치고 lock 을 지운 뒤 재실행한다(impl PASS 지문에 manifest 가 포함돼 재합의를 거친다).
   ```json
   {"version": 1, "files": ["src/main/java/com/example/order/OrderService.java", "src/test/java/com/example/order/OrderServiceTest.java"], "new_file_roots": ["src/main/resources/db/migration/"]}
   ```
   러너는 이 범위로 (1) 워커·수정자 호출 전후 write-set 을 대조해 범위 밖 변경이 있으면 원복 없이 `SCOPE_VIOLATION` 으로 중단하고, (2) 리뷰 diff 를 범위 경로로 한정하며, (3) 승인 지문을 범위 파일로 계산한다(다른 세션이 범위 밖 파일을 바꿔도 승인·verify 가 무효화되지 않음). 사용자 결정(DOC_GAP 해결)으로 파일 목록이 바뀌어야 하면 원본을 고치고 lock 을 지운 뒤 재실행한다(impl 재합의).
2. `.agent-work/approach.md` — **어떻게** 구현하는가. 단위는 함수가 아니라 **구현 결정**이며, 결정마다 `REQUIRED` 또는 `DELEGATED`를 표시한다.
   - **완성도 기준 = material contract 의 충분성.** 합의는 워커의 모든 판단을 제거하기 위한 것이 아니라, 워커가 소유하면 안 되는 제품·아키텍처·solution-shape 판단만 선점하기 위한 것이다. 판정 문장: 두 구현이 request/design/conventions 를 모두 만족하고 외부 동작·책임 배치·재사용 경로·상태 의미·안전성·의미 있는 비용 특성이 동일하다면, 서로 다른 production diff 가 나온다는 사실만으로 문서 공백이 아니다.
     **material decision**(사전 합의 대상) = 사용자에게 관찰되는 동작·API 계약 / public·package-level 계약·프레임워크 진입점 계약 / 영속 데이터 모델·정합성 / transaction boundary / concurrency·locking / 보안·권한·개인정보 경계 / layer·module·domain 의 responsibility placement / 기존 공용 책임의 REUSE·EXTEND vs 새 병렬 책임 / sync·async·background
     실행 의미 / retry·fallback·cache·error semantics / DB·network·외부 API 호출 topology·횟수 / 실제 요구 규모에서 의미 있게 다른 시간·공간 비용 / 되돌리기 어려운 새 production abstraction·type·state representation / 사용자·명시적 convention 이 직접 요구한 방식.
     **local implementation expression**(워커 소유) = local 변수 이름 / intermediate local vs inline / 같은 클래스 안의 private helper 추출 vs inline 과 그 signature / if vs switch / 단순 for vs stream / 동일 의미의 SDK·API overload / builder 표현 / 외부 상태·I/O·복잡도에 영향 없는 collection 생성 위치 / 작은 bounded in-memory
     collection 의 동등한 algorithm 표현 / 반환 직전 local 유무 / 포맷·import·line break / 같은 책임 안의 사소한 private control-flow(명시적 project convention 이 정한 것은 convention 우선). 역할 경계: 오케스트레이터가 material decision 을 결정하고, 워커는 그 안에서 저장소 관례에 맞는 가장 단순한 local 표현을 고르며, 리뷰어는 material 계약·convention·새 standalone
     abstraction 을 잡는다.
   - **REQUIRED — material decision 또는 사용자·convention 이 명시적으로 고정한 구현 계약만.** 예: "기존 NotificationRepository 를 EXTEND 한다 — 별도 repository 를 만들지 않는다", "외부 API 조회는 batch 1회다", "Redis lock 을 사용한다", "transaction 안에서 상태 A → B 순으로 변경한다", "실패는 retry 하지 않고 FAILED 로 기록한다".
     항상 REQUIRED: 외부 관찰 동작·영속 데이터 정합성·보안/권한/개인정보 경계가 갈리는 선택, 사용자가 명시한 방식·기존 코드 재사용. 동등한 local expression 을 diff 동일성 목적으로 REQUIRED 로 선결정하지 않는다 — 그런 문장은 리뷰어가 material 계약으로 취급하지 않는다.
     pseudocode 는 material control-flow 가 복잡해 오해를 막는 데 실제 필요할 때만 쓰고, 많을수록 완성도가 높은 것으로 취급하지 않는다:
     ```
     ## 결정 3: `A.process` 결과 조립 [REQUIRED]
     result = 새 collection
     primary = componentA.process(input)
     if primary 존재: result.add(primary)
     for each item in additions: result.add(componentB.added(context, item))
     for each item in removals: result.add(componentB.removed(context, item))
     return result
     ```
     여기까지 내려가는 것이 허용된다. 근거는 줄 범위 인용(`path:L40-L68`) 또는 표준 기법 + 선택 이유다.
   - **DELEGATED — material contract 를 지키는 범위의 local implementation expression.** private helper 추출 여부, local 이름, local intermediate 유무, if/switch, for/stream, 동등 overload, 작은 local collection 표현.
     "아무렇게나" 가 아니다 — 워커는 명시적 project convention → 이미 선택된 material contract → 직접 범위의 명백한 기존 표현 → 언어·플랫폼 관용 표현 → 가장 단순한 직접 구현 순으로 정하며, 새 abstraction 을 만들어 자유도를 소비하는 것은 DELEGATED 의 기본 권한이 아니다.
     DELEGATED 결정에는 기법을 적지 않으며, 워커는 결과 JSON 의 `delegated_choices` 에 material contract 에 가까워 리뷰어가 확인할 가치가 있는 선택만 보고한다. 리뷰어는 그 목록을 참고만 하고 코드 위치로 판정한다.
   - **단순성 의무.** 문서가 새 production structure(type·record·enum·context·result·helper layer·interface)를 직접 요구하려 할 때는 먼저 묻는다 — 이 구조가 요구사항·책임 경계·상태 모델 때문에 필요한가, 아니면 워커 선택을 제거하기 위해 만든 구조인가? 후자라면 만들지 않는다. `SendOutcome`/`Kind`/`ResultContext`/`private resultOf(...)` 같은 것을 branch 결과를 사전에 타입으로 고정하려고 발명하지 않는다 — 직접 값·기존 타입·local 변수로 충분하면 더 직접적인 쪽을 택한다.
   - **REQUIRED 의 선택 품질.** material 접근법을 REQUIRED 로 확정할 때는 요구와 기존 계약을 만족하는 후보 중 **가장 단순한 통상 해법**을 고른다. 우선순위: 직접 범위의 명백한 precedent → 언어·플랫폼·표준 라이브러리의 표준 기능 → 직접적인 최소 구현. 새 추상화·새 의존성·별도 상태 구조는 앞선 방법보다 요구·기존 계약·필요한 비용 특성을 더 직접적이고 단순하게 만족한다는 구체적 이유가 있을 때만 고르고 그 이유를 적는다.
   - **재사용 탐색(REUSE / EXTEND / NEW).** **새 responsibility boundary** 를 만드는 결정 — 같은 책임의 repository/service/helper 신설, 기존 공용 converter·query path 와 경쟁하는 새 경로, 공유 abstraction/interface, infrastructure component, 새 cross-domain/shared responsibility
     — 는 같은 모듈·직접 의존 코드에서 같은 책임의 기존 구현을 먼저 찾고 `REUSE`(기존 symbol 호출) / `EXTEND`(기존 symbol 에 메서드·분기 추가) / `NEW` 중 하나를 명시한다. `NEW` 에는 ① 확인한 기존 symbol/path ② 가장 가까운 기존 후보 ③ REUSE/EXTEND 가 요구를 만족하지 못하는 이유가 있어야 하며, 없는 NEW 는 검증자가 `REUSE_DISCOVERY_GAP` 으로 막는다(어느 구현이 나은지는 정하지 않는다).
     요구에서 거의 자명하게 파생되는 feature-local 구조 — 새 DB table 에 대응하는 entity/row model, 새 API 계약에 대응하는 DTO/command, design 이 존재를 확정한 feature-local value carrier, 기존 책임과 경쟁하지 않는 단순 feature-local model
     — 와 같은 클래스 안의 단순 private helper 는 이 근거의 대상이 아니다. 워커는 REUSE/EXTEND 로 정해진 symbol 옆에 병렬 구현을 만들지 못하고(리뷰어 `CONTRACT_VIOLATION`), 명시적 NEW 가 없는 새 standalone 구조물은 `DOC_GAP` 으로 돌려보낸다.
   - **금지 문구.** 금지는 기본적으로 쓰지 않는다. 특정 대안이 요구 불변식이나 선택한 접근법을 깨뜨릴 때만 적고, 그때는 금지 이유와 지켜야 할 불변식 또는 허용 대안을 함께 적는다. 수단 이름만 단독으로 금지하지 않는다(잘못된 형태: "정규식 한 줄 치환 금지". 바람직한 형태: "토큰별 반복 치환은 순회를 n 번 하므로 쓰지 않는다 — 한 번의 왼쪽→오른쪽 스캔을 유지한다").
   - **탐색 범위와 근거.** 기본 범위는 변경 파일 · 같은 모듈 · 직접 의존 코드 · 동일 책임의 인접 symbol · 기존 reference 가 가리키는 코드이며, 무제한 repo-wide 탐색이 아니다. 그 범위에서 기존 utility, 책임 배치, 재사용 경로, 상태 처리 invariant, 같은 유형의 호출부, 그리고 변경 대상 symbol 의 직접 호출부·피호출부(Phase 0 4번 C)를 확인해 두 문서에 반영한다. 저장소는 **오케스트레이터가 material contract 를 작성하기 위한 근거**다.
   - **reference code.** 따라야 할 precedent 는 반드시 백틱 **줄 범위**로 인용한다(`src/foo/Bar.kt:L40-L68`). 러너가 그 범위만 워커 프롬프트에 `[REFERENCE CODE]`로 직접 붙인다(참조당 100줄·8개 캡). 심볼명이나 범위 없는 경로는 붙지 않으며 검증자가 blocking 으로 돌려보낸다.
     reference 가 고정하는 것은 책임 배치·재사용 symbol·material control-flow·상태 처리 invariant·project-specific API idiom 중 의미 있는 부분이다. incidental expression(local 이름·helper 개수·줄 구조·같은 의미의 overload·private extraction 여부)은 자동으로 contract 가 되지 않는다
     — 정확히 복제해야 하는 이유가 user decision·project convention·material contract 에 있으면 approach 가 그 이유를 명시한다.
   - **제어 흐름 절(선택)** — 외부 동작이나 상태 변경 결과가 갈리는 함수에 "허용된 결정점을 열거하고 그 외 동작 분기를 금지"하는 계약을 쓴다. 모든 함수에 쓰지 않는다. 절이 있는 함수는 REQUIRED 계약이고, 절이 없는 함수라도 호출 순서·branch 조건·aggregation 위치는 위 REQUIRED 규칙대로 결정에 적혀 있어야 한다(워커는 문서에 없는 외부 동작·상태 결과를 새로 정하지 못하고, 리뷰어는 그런 추가를 `UNDECLARED_BEHAVIOR` issue 로 잡는다).
     계약 대상은 구문상의 조건문이 아니라 **동작을 달리하는 결정점**이다(루프 종료·관용적 빈값 확인·API 예외 변환·값 계산 boolean·exhaustive match 는 열거하지 않는다). 소스에 분기 ID 주석을 요구하지 않고, 리뷰어는 정상 대응하는 분기를 출력하지 않는다 — 계약 밖 결정점·중복 분기·누락된 분기만 issue 다.
     워커는 열거된 결정점만 구현하고 추가가 필요하면 UNDECIDED 로 돌려보낸다. 주 경로는 호출 순서 사양이다 — 문서가 `A → B → C` 로 정했으면 `A → C → B` 는 동작이 같아도 위반이다. 형식:
     ```
     ## `OrderService.process` 제어 흐름 [REQUIRED]
     요구되는 분기:
     - B1 / REQ-03: 주문이 없으면 NOT_FOUND 반환
     - B2 / REQ-04: 이미 처리된 주문이면 현재 결과 반환
     주 경로: 주문 조회 → 처리 실행 → 결과 저장 → 반환
     금지: 위 목록에 없는 null 방어 분기 · 호환성 fallback · 재시도 · 타입별 if 분기 · boolean flag 흐름 제어
     참조 구현: `src/order/ExistingOrderService.java:L40-L68`
     ```
   - 제어 흐름 절은 request.md·design.md에 **이미 명시된** 동작을 옮기는 것이다. 모든 분기를 선제 예측하지 않는다 — 구현 중 실제 공백은 워커가 `DOC_GAP`으로 돌려보내고 사용자가 결정한 뒤 오케스트레이터가 approach.md 에 동기화한다(검증자 재합의 없음). 검증자는 명시된 요구 동작이 빠졌는지만 본다.
   - **완성도는 상세함의 양이 아니다.** 필요 없는 정보를 쓰지 않는다. 최적화 목표는 문서 길이의 최소화도 최대화도 아니라 **material contract 의 충분성**이며, 사소한 helper/local/collection 선택 때문에 DOC_GAP → 사용자 질문이 생기지 않는 것이다. 판정 예시는 `tests/solution-shape-cases.md`.
4. `.agent-work/implementation-units.json` — 위 두 문서가 확정된 **뒤에** 그 구현 범위를 워커가 소화할 수 있는 **기능 단위(implementation unit)** 로 자른 실행 계획(`schemas/implementation-units.schema.json`). impl 합의의 입력이라 impl PASS 지문에 포함되며, 바꾸면 impl 재합의를 거친다. unit 은 새 설계 판단이 아니다 — design/implementation/approach 가 계속 source of truth 이고 unit 은 "이번 워커 호출이 그중 어느 계약을 구현하는가"만 정한다.
   ```json
   {"version": 1, "units": [
     {"id": "01-intake-assignment", "title": "접수 및 담당자 지정", "goal": "요청 접수와 최초 담당자 지정 흐름을 구현한다.",
      "requirements": ["REQ-01", "REQ-02"],
      "scope": {"files": ["src/main/.../TicketService.java"], "new_file_roots": ["src/test/.../ticket/"]},
      "references": ["implementation.md#접수-및-담당자-지정", "approach.md#접수-및-담당자-지정"],
      "targeted_test": "./gradlew test --tests '*TicketAssignment*'"}
   ]}
   ```
   - **분할 규칙.** unit 은 하나의 완결된 사용자/도메인 동작 또는 강하게 결합된 동작 묶음이다(접수+담당자 지정 / 환불 요청+상태 조회 / 환불 승인·반려·취소 …). Repository → Service → Controller 같은 레이어·파일·클래스 종류 기준 분할은 금지. 한 unit 이 끝나면 그 동작의 targeted test 가 가능해야 하고, 뒤 unit 은 앞 unit 이 만든 실제 코드를 쓸 수 있으며, 같은 파일을 여러 unit 이 순차 수정해도 된다.
     Jira subtask 와 1:1 로 강제하지 않는다. 한 워커가 여러 독립 기능을 동시에 구현해야 하면 너무 큰 것이고, 메서드·파일 하나 수준이면 너무 작다. **독립 화면·독립 기능이 여럿 한 unit 에 몰리면 응집도 기준으로 나눈다** — 서로 다른 화면(또는 서로 다른 진입점·사용자 동작)이 한 unit 에 들어 있고 각각 따로 targeted test 가 가능하면 그것은 unit 둘 이상이다(71파일·8화면이 한 unit 이었던 사례가 워커 턴 하나로 소화되지 않았다).
     파일 수의 고정 임계치나 추가 검증 Agent 는 두지 않으며, 반대로 한 동작을 여러 unit 으로 잘게 쪼개 CLI 호출 수만 늘리지도 않는다. 모든 unit 의 합집합은 implementation.md 의 구현 범위를 빠짐없이 덮고 unit 간 중복 구현이 없어야 한다. 순서는 선행 동작이 먼저 오도록 정한다(배열 순서 = 실행 순서).
     3~8개가 흔한 크기지만 한도는 아니다.
   - **스키마·러너 검사.** `version` 1, `units` ≥1, unit 마다 `id`(순번 prefix + kebab, manifest 전체에서 유일, 순번이 배열 순서대로 증가)·`title`·`goal`·`requirements`(≥1)·`scope`·`references`(≥1)·`targeted_test`(빈 문자열 금지) 필수, 그 외 필드 금지
     — `depends_on`·`priority`·parallel 류는 존재하지 않는다(병렬화·DAG 를 만들지 않는다). `scope` 는 `feature-scope.json` 과 같은 `files`/`new_file_roots` 의미(canonical 경로, 둘 중 하나 이상)이며 **전체 범위의 부분집합**이어야 한다
     — 러너가 워커 진입 시 lock 대비 검사하고 벗어나면 `IMPL_DOCS_MISSING` 으로 돌려보낸다. 검증자는 ① 전체 범위를 빠짐없이 덮는가 ② 기능 단위인가 ③ 과대·과소 unit 이 없는가 ④ 순서가 선행 관계에 맞는가 ⑤ scope 가 전체 범위 안인가 ⑥ targeted_test 가 그 unit 을 검증하는가 ⑦ 문서에 없는 새 설계 결정이 없는가 만 보고, 더 좋은 분할을 제안하지 않는다.
   - **references 는 계약 의존의 유일한 근거다.** 형식은 `implementation.md#<heading>` / `approach.md#<heading>` / `design.md#<heading>`(heading 텍스트·그 slug·heading 끝의 `{#id}`, 또는 `결정-1` 처럼 slug 의 단어 경계 접두
     — 문서 안에서 **유일**해야 한다) 또는 `#` 없는 문서 이름(문서 전체). 러너는 그 절의 **본문**을 unit 별 계약 스냅샷으로 남겨, 절 본문·그 unit 의 `[worker-gap=<unit>#N]` 결정·unit JSON 이 바뀐 unit 만 stale 로 만든다(heading 이 그대로여도 본문이 바뀌면 변경이다).
     가리키는 heading 이 없거나 둘 이상이면 러너가 워커·검증자를 부르기 전에 멈춘다. unit 이 의존하는 설계 절이 있으면 `design.md#<절>` 도 references 에 적는다 — 적지 않은 unit 은 design.md 전체가 전역 입력으로 취급돼 design.md 가 바뀔 때마다 사용자의 영향 확정(`UNIT_CONTRACT_IMPACT_REQUIRED`)이 필요해진다.
     `requirements` 의 자유 문장은 영향 판정에 쓰이지 않는다.
   - **references 의 정밀도.** unit 은 material decision 을 새로 정하는 곳이 아니다. 각 unit 의 `references` 는 그 unit 이 구현해야 하는 implementation.md/approach.md 의 **정확한 영역**(절 anchor)을 가리켜, unit 워커가 긴 문서 전체에서 자기 구현법을 추론하지 않게 한다. unit 을 더 잘게 쪼개는 것으로 문서 부족을 해결하지 않는다 — 문서 공백은 문서에서 메운다.
