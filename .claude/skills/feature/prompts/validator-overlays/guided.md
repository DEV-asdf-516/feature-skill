판정 순서(guided). 위 계약을 바꾸지 않는다 — 아래 순서대로만 진행하고 단계를 건너뛰거나 섞지 않는다.
1. 문서 간 직접 모순을 먼저 찾는다(request.md ↔ design.md ↔ decisions.md, impl 이면 design.md ↔ implementation.md ↔ approach.md). 발견하면 DIRECT_MISMATCH 후보로 적어 둔다.
2. 직접 모순이 없으면 명시 계약의 누락만 확인한다 — 문서에 적힌 요구 하나가 대상 문서에서 빠졌는가. 새 요구를 발굴하지 않는다.
3. 실행 경로 추적은 1·2 에서 나온 후보의 BLOCK 여부가 그 경로에 달릴 때만 한다. 그 외의 코드 탐색은 하지 않는다.
4. 접근법이 갈리는(solution shape) 결정이 비어 있으면 REQUIREMENT_MISSING 후보, 접근법은 정해졌지만 **문서가 소유한 구현 포인트**의 코드 구조(판단 위치·호출 순서·branch 조건·collection/aggregation 위치·helper 여부·API 호출 형태·의미 있는 local/naming)를 문서·인용된 reference·직접 범위의 명백한 단일 precedent 어느 것도 하나로 정하지 않았으면 CODE_SPEC_GAP 후보다 — 단 공통 계약의 여섯 입장 조건을 모두 확정할 수 있을 때만이며, "두 워커가 다른 diff 를 만들 수 있다" 는 보조 판정이지 단독 근거가 아니다. 문서가 요구하지 않은 구현 포인트(문서에 없는 helper·매핑 구조·테스트 내부 코드)를 발굴해 후보로 삼지 않는다. 어느 쪽이든 갈리는 둘을 구체적으로 적을 수 없으면 후보가 아니고, 차이가 formatter·import 정렬·compiler 수준이면 후보가 아니다. 새 구조물을 도입하는 결정에 REUSE/EXTEND/NEW 탐색 근거 세 가지가 빠져 있으면 REUSE_DISCOVERY_GAP 후보다 — 근거가 있으면 그 판단을 재론하지 않는다. 같은 원인은 category 우선순위에 따라 후보 하나로만 둔다.
5. 후보마다 입장 조건을 하나씩 대조한다. 조건 하나라도 확정할 수 없으면 출력하지 않는다.
6. 남은 후보가 없으면 PASS 다. 빈 결과를 채우려 하지 않는다.
