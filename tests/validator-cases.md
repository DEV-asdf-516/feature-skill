# 검증자 판정 감도 회귀

고정된 `input/*.md`와 `src/`를 임시 저장소의 `.agent-work/`와 `src/`로 복사해 실제 validator를 실행한다. fixture 원본은 Git으로 관리하고 `.agent-work/`는 실행 산출물로만 쓴다. 모델 응답에 기대값이나 판정 힌트를 주지 않는다.

```bash
python3 tests/validator-fixture-smoke.py              # 유료 호출 없는 fixture/비교 검사
# 사용자 지시 후에만 1회용 승인 파일 생성:
touch .claude/ALLOW_REAL_LLM_REGRESSION
bash tests/validator-regression.sh                   # 25개, 최대 실제 검증자 25회
bash tests/validator-regression.sh case-08b-round2-new-issue # 08a 먼저 + 08b, 최대 2회
bash tests/validator-regression.sh compare review.json expected.json [full|gate]
```

실제 호출은 config.sh의 VALIDATOR_MODEL/EFFORT/PROFILE을 사용한다. TEST_CMD와 LINT_CMD는 임시 사본에서 true로 바꾸며 원본 설정을 수정하지 않는다. case-08b의 디자이너는 고정 수정 적용용 가짜 실행기이고, 디자이너 모델 행동은 이 회귀로 검증하지 않는다.

## 사례

| 사례 | 검사하는 경계 | 기대 |
|---|---|---|
| 01 unrelated-existing-defect | 새 조회는 repo를 직접 사용하며 기존 캐시 결함 경로를 활성화하지 않음 | impl PASS |
| 02 required-util-missing | 사용자 명시 MaskingUtil 재사용 대신 직접 구현 — blocker 정확히 1개 | impl BLOCK / REVISE_DOC / DIRECT_MISMATCH |
| 03 runner-ops-missing | 정상 optional subtitle 응답 변경. 문서의 미커밋 메모·미정 baseline/archive는 운영 문제 | impl PASS |
| 04 unrequested-message-check | status 판정만 합의. message 검사 요구를 새로 만들지 않음. 이름 인코딩은 REQUIRED 로 확정 | impl PASS |
| 05a document-security-conflict | 키 비기록 요구와 키 포함 URL 로깅 설계가 문서만으로 충돌 | design BLOCK / REVISE_DOC / SECURITY / DIRECT_MISMATCH |
| 05b reachable-security-failure | 직접 의존 코드가 키 포함 URL을 기록. 해당 공용 코드 수정 허용 | design BLOCK / REVISE_DOC / SECURITY / REACHABLE_FAILURE |
| 05c out-of-scope-security-conflict | 05b와 같은 design·code. 인증 키 원문 전달·유일한 호출 경로·공용 코드/로그 설정 수정 금지로 범위 내 대안 없음 | design BLOCK / ASK_USER / SECURITY 또는 REQUIREMENT_CONTRADICTION / REACHABLE_FAILURE 또는 DIRECT_MISMATCH (확정 계약 충돌이라 두 라벨 모두 타당, v9 회귀에서 후자 관측) |
| 06 normalize-empty-persist | 숫자 정규화 뒤 무조건 저장이 8자리/미저장+400 계약 위반 | impl BLOCK / REVISE_DOC, category/evidence는 expected의 허용 집합 |
| 07 policy-undecided | idempotency 재요청 정책이 미정이고 선례 없음 | design BLOCK / ASK_USER / POLICY_UNDECIDED / UNDECIDED_CHOICE |
| 08a round1-blockers | A=필수 마스킹 유틸 미사용, B=없는 id에 404 대신 200. 두 독립 요구 위반 — 정확히 2건 | impl Round 1 BLOCK / REVISE_DOC 2건 / DIRECT_MISMATCH |
| 08b round2-new-issue | 직전 리뷰에는 A만 있음. A만 수정되고 이전부터 보인 별개 B는 그대로 | impl Round 2 PASS |
| 09 local-algorithm-delegated-pass | 연속 하이픈 축약의 방식(정규식 한 번 vs 수동 스캔)이 DELEGATED 로 남음. bounded 문자열에서 결과·I/O·책임·상태·비용이 같은 local expression | impl PASS (v15 이전 BLOCK/REQUIREMENT_MISSING — 이제 내면 회귀) |
| 10 expression-only-delegated | 접근법은 REQUIRED 로 정해졌고 Pattern 보관 위치·반환 표현만 DELEGATED | impl PASS |
| 11 reuse-discovery-gap | 같은 모듈에 `ClientRepository.findById`·`findOrThrow` 가 있는데 approach 가 탐색 근거 없이 같은 조회 책임의 `NEW ClientSummaryRepository` 를 REQUIRED 로 정함(새 responsibility boundary). DTO·컨트롤러는 완결 — 정확히 1건 | impl BLOCK / REVISE_DOC / REUSE_DISCOVERY_GAP / DIRECT_MISMATCH — findOrThrow 재사용을 처방하거나 같은 원인에 REQUIREMENT_MISSING 을 추가하면 실패 |
| 12 reuse-discovery-new-justified | 전화번호 조회가 어디에도 없고 공용 `ClientRepository` 는 request 제외 조항으로 EXTEND 불가. NEW 에 확인한 symbol·가장 가까운 후보·REUSE/EXTEND 불가 이유가 적힘 | impl PASS (근거 있는 NEW 를 재론하면 회귀) |
| 13 code-spec-control-flow-gap | 접근법(한 번 순회·`Classifier` REUSE)은 정해졌지만 "A 는 B 를 사용해 items 를 처리한다" 만 있고 implementation 이 `Classifier` 변경을 열어 두어, Batch 가 판정·조립하는 구조와 Classifier 가 목록 메서드를 갖고 판정·조립하는 구조가 모두 가능하다 — **책임 배치와 Classifier 의 public 계약**이 갈리는 material gap | impl BLOCK / REVISE_DOC / **CODE_SPEC_GAP** / DIRECT_MISMATCH — 어느 구조를 고를지 처방하거나 helper/local 을 근거로 들면 manual-check 실패 |
| 14 material-contract-pass | 같은 요구. approach 가 책임 위치(Classifier 가 판정·조립, Batch 는 위임)와 EXTEND 만 정하고 helper·local 이름·for/stream·pseudocode 는 적지 않음 | impl PASS (local 미명세·pseudocode 부재를 CODE_SPEC_GAP 으로 막으면 회귀) |
| 15 code-spec-scope-pass | 구현 대상 `Ledger.balance` 의 material 계약(REUSE entries 1회, 새 구조물 없음)은 완결. 같은 파일의 무관한 기존 세부(`audit`, `entries` 내부)를 발굴하지 않고 합산 표현을 요구하지 않음 | impl PASS |
| 16 duplicate-suppression | `NEW OrderTotalCalculator` 에 탐색 근거가 없고 같은 모듈에 `PriceCalculator.total` 이 있음(같은 책임의 병렬 helper). DTO·조회·테스트 setup 은 완결 | impl BLOCK / REVISE_DOC / REUSE_DISCOVERY_GAP **정확히 1건** — 같은 원인에 REQUIREMENT_MISSING/CODE_SPEC_GAP 을 얹으면 실패 |
| 17 test-detail-non-block | production material 계약(REUSE normalize, 빈 태그 제거, 순서)과 테스트 입력/기대값은 명확. 테스트 내부 helper/local/반복 구조·production local 표현은 문서가 정하지 않음 | impl PASS (테스트 내부 코드나 local 표현을 이유로 CODE_SPEC_GAP 이면 회귀) |
| 18 local-aggregation-pass | `Inventory.restock` 은 `Stock.add` REUSE·순서까지 정해졌고 건마다 `add` vs sku 별 사전 합산 뒤 `add`(in-memory Map)가 열려 있음 — I/O·책임·상태·비용이 같은 local aggregation | impl PASS (v15 이전 CODE_SPEC_GAP — 이제 내면 회귀) |
| 19 local-expression-unspecified-pass | `summary` 안의 helper 유무·local 이름·intermediate·record 생성 표현을 문서가 정하지 않음 + NEW `ClientSummary` 는 새 API 계약에 대응하는 feature-local DTO 라 탐색 근거 없음 | impl PASS (CODE_SPEC_GAP 또는 REUSE_DISCOVERY_GAP 이면 회귀) |
| 20 equivalent-overload-unspecified-pass | `MaskingUtil.maskPhone` 에 1-인자·2-인자 overload 가 있고 결정 2 는 어느 것인지 적지 않음 | impl PASS |
| 21 per-item-vs-batch-delegated | `OrderService.statuses(ids)`(한 페이지 최대 500 건, repository 는 DB) 의 조회 방식이 DELEGATED. repository 에 `findById`·`findAllByIds` 모두 있음 — DB 호출 1 vs n 의 I/O topology | impl BLOCK / REVISE_DOC / REQUIREMENT_MISSING 또는 CODE_SPEC_GAP / DIRECT_MISMATCH |
| 22 retry-semantics-delegated | `NotificationService.send` 의 gateway 실패 처리(재시도 여부·횟수, 건당 과금)가 DELEGATED | impl BLOCK / REVISE_DOC / REQUIREMENT_MISSING 또는 CODE_SPEC_GAP / DIRECT_MISMATCH |

SECURITY는 표를 위한 축약이며 실제 JSON은 `CHANGE_INTRODUCES_SECURITY_RISK`다.

05c는 공통 프롬프트의 **확정 계약 충돌 예외**를 검사한다. 새 category는 없다. 일반 ASK_USER 네 조건은 유지하고, 피처 관련 blocker·정확한 근거·안전한 범위 내 대안 부재가 입증된 계약 충돌에 한해서만 1·3조건의 예외로 사용자 결정을 다시 요구한다. 확정 범위를 임의로 넓히거나 설계자에게 사용자 결정을 고치라고 보내지 않는다.

## 08의 두 실행을 분리하는 이유

08a와 08b의 초기 input/src는 동일하다. 먼저 실제 validator로 08a의 A+B 검출을 검사하고, 자동 비교에 실패하면 08b의 유료 호출은 생략한다. 두 이슈가 실제 A/B인지는 manual-check로 응답 본문을 확인한다. 같은 결함을 둘로 중복 보고했다면 count/label이 맞아도 의미 검사 통과가 아니다.

08b에서는 08a의 실제 리뷰를 이어 붙이지 않는다. 고정 `prev-review.json`에는 A만 넣는다. 가짜 디자이너는 `revised-input/`을 적용해 A만 고친다. B는 변경 전부터 있었지만 직전 리뷰에는 없었으므로, Round 2에서 처음 등록하면 suppression 실패다.

**직전 리뷰에 A+B가 모두 있었다면 미해결 B를 `UNRESOLVED_PREVIOUS`로 내는 것이 올바르다.** 그 상황에서 PASS를 요구하면 기존 Round 2 계약을 깨뜨린다. 따라서 별도의 Round 1 대조와 A만 포함한 종결 검사로 나눈다. 이전 미해결 이슈 유지나 수정으로 새로 생긴 회귀를 검사하는 사례는 이번 suppression 사례와 별개다.

## 채점

- **Gate:** 유효한 runner 종료 + PASS/BLOCK + action별 이슈 수.
- **Classification:** Gate에 더해 category/evidence/origin 등 expected의 모든 issue 필드. 전체 사례 수를 분모로 사용하므로 gate 실패도 classification 실패다.
- **실행·출력 오류:** runner가 JSON 필드 연계를 거부했거나 CLI/실행이 실패한 사례. 두 점수에서 통과로 세지 않고 별도로 표시한다.
- **선행 실패로 생략:** 08a 실패로 08b를 호출하지 않은 경우. 통과로 세지 않는다.

예를 들어 보안 문제를 올바르게 BLOCK/REVISE_DOC했으나 evidence만 틀리면 Gate는 통과, Classification은 실패다. blocker를 PASS하면 둘 다 실패다. 단순 최종 exit 1만으로 CLI 오류와 판정 실패를 구분하지 않는다. `run.log`의 사례 종료와 비교 결과를 함께 본다.

비교는 이슈 순서나 id에 의존하지 않으며, 실제 이슈 하나를 여러 기대 이슈에 재사용하지 않는 일대일 매칭이다. `_any_of`는 의미상 허용되는 category/evidence 차이를 열어 두는 데 사용한다. 질문 문장·선택지 표현·구체 해결 기법은 고정하지 않는다.

## 수동 확인과 한계

- 06: 최소 불변식만 요구하고 구현 기법을 처방하지 않는가.
- 08a: 두 응답이 실제로 마스킹 재사용 위반 A와 404/200 위반 B인가.
- 11: minimum_contract_needed 가 탐색 근거(확인한 symbol·가장 가까운 후보·REUSE/EXTEND 불가 이유) 보강만 요구하고 어느 구현이 나은지 정하지 않는가.
- 13: impact 에 material 차이(판정·조립 책임 위치, Classifier 의 public 계약)가 적히고, minimum_contract_needed 가 "판단·조립 책임 위치가 하나로 정해져야 한다" 만 말하며 어느 구조를 고를지 처방하지 않는가. 14 가 BLOCK 이면 local 미명세를 material gap 으로 본 것이므로 프롬프트의 CODE_SPEC_GAP 절을 본다.
- 15: blocking_issues 가 비어 있는가. `audit`·`entries` 내부·테스트 내부·합산 표현(for/stream/helper)을 언급한 issue 가 있으면 관할 위반 또는 local expression 회귀다.
- 16: issue 가 정확히 하나이고 REUSE_DISCOVERY_GAP 인가. minimum_contract_needed 가 탐색 근거 보강만 요구하고 `PriceCalculator` 재사용을 처방하거나 DTO/매핑 결정을 끼워 넣지 않는가.
- 17: 테스트 내부(helper·local·assertion 방식·프레임워크)를 이유로 한 issue 가 없는가.
- 09·18·19·20: blocking_issues 가 비어 있는가. 정규식 vs 스캔 / 건별 add vs 사전 합산 / helper·local 이름·intermediate / overload 를 이유로 한 issue 는 전부 local expression 회귀다.
- 21·22: impact 가 I/O 횟수(DB 호출 1 vs n / 외부 SMS 호출 횟수·실패 semantics)를 적는가. minimum_contract_needed 가 어느 쪽을 고를지·횟수를 처방하지 않는가.
- 08b가 BLOCK이면 docs diff와 revision_ref의 실제 인과를 확인한다.
- 문서/코드 인용 범위의 존재는 로컬 fixture 검사로 확인한다. 단편 Java 코드는 모델 입력이며 완성된 애플리케이션 빌드 테스트가 아니다.
- guided는 새 05b 실행 전에 탐색 전략을 바꾸지 않는다. 결과가 실패하면 공통 계약의 직접 의존 확인 범위와 충돌하는지 검토한다.
- 같은 점수라도 gate 누락과 taxonomy 불일치는 다르다. 모델·effort·profile과 반복 수를 함께 기록한다.

## v15 migration (2026-09-23) — 검증 대상을 production diff 동일성에서 material decision 으로

"두 워커가 다른 non-trivial diff 를 만들 수 있는가" 를 판정 기준(보조 기준 포함)에서 제거했다. CODE_SPEC_GAP 은 material 구현 계약 하나가 열린 경우만이며 일곱 입장 조건 + "이 선택을 워커에게 맡기면 제품/아키텍처/책임 경계/상태 의미/I/O 비용/안전성 중 무엇이 달라지는가" gate 를 통과해야 한다. helper 분해·local naming·collection/aggregation 위치·API usage pattern·intermediate result·diff 구조 자체는 근거가 아니다. REUSE_DISCOVERY_GAP 은 새 responsibility boundary 에만 적용하고 feature-local DTO/entity/value carrier·단순 private helper 에는 근거를 요구하지 않는다. 이에 따라 case-09(정규식 vs 스캔)·case-18(in-memory 합산 위치)을 PASS 로, case-14·15·17 의 approach 에서 pseudocode·local 이름·helper 금지를 제거했고(여전히 PASS), case-13 은 책임 배치 + Classifier public 계약이라는 material 근거로 BLOCK 을 유지한다. 새 사례 19·20(PASS: helper/naming/intermediate/DTO 근거/overload 미명세)·21·22(BLOCK: N+1 vs batch, retry 여부)를 추가했다. **v15 실모델 회귀는 아직 실행하지 않았다.**

## v14 migration 분류 (2026-09-23 실모델 9/17 실패 대응, 이력)

VALIDATOR_CONTRACT_VERSION 13 실모델 회귀에서 8개 사례가 깨졌다. 각 추가 issue 를 **FIXTURE_NEEDS_CODE_SPEC_MIGRATION**(옛 fixture 가 새 code-spec 계약을 실제로 위반 → fixture 의 비관심 영역을 완결) 과 **VALIDATOR_OVERREACH**(검증자가 문서가 요구하지 않은 구현 의무를 발명하거나 같은 원인을 두 category 로 냄 → 프롬프트 수정) 으로 나눴다. 검증자를 느슨하게 만들지 않았고 code-spec 철학은 그대로다.

| 사례 | 추가 issue | 문서 근거 | 분류 | 조치 |
|---|---|---|---|---|
| 01 | `R1-DTO-MAPPING-UNDECIDED` (REQUIREMENT_MISSING) | approach.md L6 `결정 3: DTO 매핑 [DELEGATED]`, implementation.md L3 이 반환 타입 `ClientSummary` 를 적었지만 저장소에 없음 → 워커가 만들어야 하는 symbol 의 위치·구조·매핑 위치가 미정 | FIXTURE | 결정 3 을 REQUIRED NEW `ClientSummary` record + 서비스 내 생성자 직접 호출 pseudocode 로 완결, `src/Client.java` 추가 |
| 01 | `R1-CONTROLLER-CODE-SPEC` (CODE_SPEC_GAP) | implementation.md L4 가 `ClientController` 신규를 소유하지만 approach.md 에 결정이 없음(직접 반환 vs ResponseEntity wrapper, precedent 없음) | FIXTURE | 결정 4 컨트롤러: 생성자 주입 필드 하나, `service.summary(id)` 반환값 직접 반환, wrapper/try-catch 없음 |
| 02 | `ROUND1-DTO-CODESPEC` (CODE_SPEC_GAP) | 01 과 동일한 결정 3 DELEGATED | FIXTURE | 01 과 같은 migration. masking blocker 1건만 남음 |
| 04 | `R1-API-SHAPE` (REQUIREMENT_MISSING) | implementation.md L3 `String lookup(String name)` 에 가시성·static 없음. 직접 범위 `src/DartHttp.java:L4` 가 `public static` precedent 인데 무시함 | BOTH | 프롬프트: 문서가 적은 signature 에 없는 modifier 는 precedent/convention 세부이지 blocker 아님. fixture: `public static String lookup` 명시 |
| 04 | `R1-EXCEPTION-SPEC` (CODE_SPEC_GAP) | design.md L6 이 `DartLookupException` 을 던지라고 하는데 저장소에 없고 implementation.md 변경 파일에도 없음 → 워커가 만들어야 하는 symbol 의 선언 위치·상위 타입·생성자 미정 | FIXTURE | 결정 3 NEW `DartLookupException`(중첩 static, RuntimeException, `(String status)`) + 변경 파일에 등재. 문서가 호출하라고 적은 symbol 이 없어 워커가 만들어야 하는 경우는 "발명" 이 아니라 문서가 소유한 포인트다 |
| 04 | `R1-LOOKUP-BLUEPRINT` (CODE_SPEC_GAP) | approach.md L2-L5 가 인코딩→search→status 판정→반환/throw 의 선형 흐름과 "별도 구조물 없음" 을 적었는데 "helper 로 분해할 수도 있다" 는 문서에 없는 대안을 가정 | BOTH | 프롬프트: 선형 흐름이 적혀 있으면 helper 여부는 "없음" 으로 결정된 것. fixture: 테스트 setup 때문에 `resolve` 분리를 명시적으로 결정 |
| 04 | `R1-TEST-SPEC` (CODE_SPEC_GAP) | implementation.md L4-L6 에 테스트 동작만 있고 테스트 파일·`DartHttp.search`(static) 격리 경계가 없음(setup 경계 = 정당). 그러나 "따를 테스트 pattern·실행 명령" 까지 요구 = 과잉 | BOTH | 프롬프트: 테스트 문서는 동작·입력 의미·assertion·setup 경계만. fixture: 테스트 파일 + `resolve` 직접 호출 setup 추가 |
| 08a | `R1-DTO-CODE-SPEC` (CODE_SPEC_GAP) | 01 과 동일 | FIXTURE | 01 과 같은 migration + 결정 1 의 빈 경로 blueprint. A·B 2건만 남음. 08b input/revised-input 동기화(결정 2 만 다름) |
| 08a | 결정 4 HTTP 매핑·경로 변수 바인딩 symbol (CODE_SPEC_GAP, 2차 실행) | conventions.md 없음(harness 는 fixture src·docs 만 복사), approach 결정 4 가 "precedent 없음" 을 선언하면서 매핑 annotation·바인딩을 정하지 않음, src 에 컨트롤러·HTTP annotation 부재 → 여섯 조건 성립 | FIXTURE | 결정 4 에 `@RestController`·`@GetMapping`·`@PathVariable("id")` 와 판단 위치(컨트롤러=라우팅·바인딩, 존재 판단=서비스) 추가. 08a/08b input 및 revised-input 동일 문안 |
| 08a | 결정 4 REUSE/EXTEND/NEW 판단·탐색 근거 (REUSE_DISCOVERY_GAP, 3차 실행) | 결정 4 는 src 에 없는 `ClientController` 를 신설(implementation.md 항목 3·request.md 범위)하므로 새 구조 도입이 맞음. NEW 표시와 근거 세 가지(확인한 symbol, 가장 가까운 후보, REUSE/EXTEND 불가 이유)가 결정 3 과 달리 없었음 | FIXTURE | 결정 4 를 NEW `ClientController` 로 표시하고 탐색 근거 추가. 08a/08b input 및 revised-input 동일 문안, 정책 무변경 |
| 01·02·11·12 | 결정 4 (08a 와 동일 latent defect, 실행 전 선제 migration) | 넷 다 `src/ClientController.java` 신규(request·implementation 지정), src 에 컨트롤러 없음, 결정 4 에 NEW 표시·탐색 근거 부재. 페어 fixture 없음 | FIXTURE | 08a 와 같은 문안으로 NEW `ClientController` + 탐색 근거(11·12 는 `ClientRepository` 포함). expected·원래 목적 무변경 |
| 11 | `R1-APPROACH-002` (REQUIREMENT_MISSING) | 01 과 동일한 결정 3 DELEGATED. REUSE gap 과는 다른 결정이라 category 중복은 아님 | FIXTURE | 01 과 같은 migration. REUSE_DISCOVERY_GAP 1건만 남음 |
| 12 | `R1-001` (REQUIREMENT_MISSING) | 01 과 동일한 결정 3 DELEGATED. 단 minimum_contract_needed 에 "REUSE/EXTEND/NEW 판단" 을 끼워 넣어 category 를 섞음 | BOTH | fixture: DTO migration. 프롬프트: category 우선순위 — minimum_contract_needed 는 그 category 의 요구만 |
| 12 | `R1-002` (CODE_SPEC_GAP) | 01 컨트롤러와 동일 | FIXTURE | 결정 4 컨트롤러(by-phone) |
| 14 | `R1-CODE-SPEC-TEST-001` (CODE_SPEC_GAP) | production blueprint(approach.md L2-L13)는 완결. implementation.md L5·L9-L10 이 테스트 파일·이름·입력/기대값을 정했는데 "JUnit vs main/assert, assertion helper" 등 테스트 내부 작성 방식을 요구 | OVERREACH | 프롬프트: 테스트 코드의 경계 절 신설 — 테스트 내부 local/helper/control-flow/naming·assertion API·프레임워크는 code-spec 아님, 테스트만을 이유로 CODE_SPEC_GAP 금지. fixture 무변경 |

프롬프트 변경(v14) 요약: ① 관할에 "문서가 소유한 구현 포인트" 정의와 발명 금지 ② CODE_SPEC_GAP 여섯 입장 조건(확정 구현 대상 / solution 소유 / trivia 아님 / production diff 구조·명명·API 를 유의미하게 바꿈 / convention·reference·precedent 가 정하지 않음 / 워커가 임의 선택해야 함) ③ "두 워커 다른 diff" 는 ④ 의 보조 판정 ④ 선형 흐름 = helper 없음, signature 의 modifier 는 세부 ⑤ 테스트 코드의 경계 ⑥ category 우선순위·중복 금지(REQUIREMENT_MISSING → 접근법 누락 → REUSE_DISCOVERY_GAP → CODE_SPEC_GAP, 하위가 성립하면 상위 추가 금지). guided 오버레이 4단계 동기화. case-13(BLOCK)·case-14(PASS) 의 기대는 그대로다.

v14 실모델 회귀는 실행되지 않은 채 v15 로 넘어갔다. 사용자 승인 뒤 `touch .claude/ALLOW_REAL_LLM_REGRESSION && bash tests/validator-regression.sh` 로 25개를 돌린다.
