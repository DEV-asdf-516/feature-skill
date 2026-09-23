판정 순서(guided). 위 계약을 바꾸지 않는다 — 아래 순서대로만 진행하고 단계를 건너뛰거나 섞지 않는다.
1. 문서 간 직접 모순을 먼저 찾는다(request.md ↔ design.md ↔ decisions.md, impl 이면 design.md ↔ implementation.md ↔ approach.md). 발견하면 DIRECT_MISMATCH 후보로 적어 둔다.
2. 직접 모순이 없으면 명시 계약의 누락만 확인한다 — 문서에 적힌 요구 하나가 대상 문서에서 빠졌는가. 새 요구를 발굴하지 않는다.
3. 실행 경로 추적은 1·2 에서 나온 후보의 BLOCK 여부가 그 경로에 달릴 때만 한다. 그 외의 코드 탐색은 하지 않는다.
4. material 접근법이 비어 있거나 DELEGATED 로 남아 있으면 REQUIREMENT_MISSING 후보, 접근법은 정해졌지만 **문서가 소유한 구현 포인트**의 material 구현 계약 하나(책임 위치·public/package 계약·호출 횟수·상태 변경 순서·transaction/lock/retry/cache 의미·새 production 구조물)를 문서·인용된 reference·convention·직접 범위의 명백한 단일 precedent 어느 것도 하나로 정하지 않았으면 CODE_SPEC_GAP 후보다 — 단 공통 계약의 일곱 입장 조건을 모두 확정할 수 있고, "이 선택을 워커에게 맡기면 제품/아키텍처/책임 경계/상태 의미/I/O 비용/안전성 중 무엇이 달라지는가" 에 구체적으로 답할 수 있을 때만이다. helper 유무·local 이름·intermediate 유무·if/switch·for/stream·동등 overload·bounded local collection 표현·diff 구조 차이는 후보가 아니고, "두 워커가 다른 diff 를 만들 수 있다" 는 근거가 아니다. 문서가 요구하지 않은 구현 포인트(문서에 없는 helper·매핑 구조·테스트 내부 코드)를 발굴해 후보로 삼지 않는다. 새 responsibility boundary 를 도입하는 결정에 REUSE/EXTEND/NEW 탐색 근거 세 가지가 빠져 있으면 REUSE_DISCOVERY_GAP 후보다 — 근거가 있으면 그 판단을 재론하지 않고, feature-local DTO/entity/value carrier 나 단순 private helper 에는 근거를 요구하지 않는다. 같은 원인은 category 우선순위에 따라 후보 하나로만 둔다.
5. 후보마다 입장 조건을 하나씩 대조한다. 조건 하나라도 확정할 수 없으면 출력하지 않는다.
6. 남은 후보가 없으면 PASS 다. 빈 결과를 채우려 하지 않는다.
