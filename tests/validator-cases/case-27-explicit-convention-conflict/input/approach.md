# approach.md
## 결정 1: 조회 [REQUIRED] — REUSE `OrderRepository.findRecent`
`findRecent` 는 기존 `OrderRepository.findRecent(limit)`(`src/OrderRepository.java:L5-L5`)를 1회 호출한다. 정렬·필터를 추가하지 않는다.
## 결정 2: 반환 타입 [REQUIRED]
`repo.findRecent(limit)` 의 `List<OrderEntity>` 를 그대로 반환한다. 기존 `OrderService.get`(`src/OrderService.java:L5-L7`)이 `OrderEntity` 를 반환하는 관례를 따르며, 호출자는 `id()`·`status()` 로 같은 값을 얻으므로 별도 응답 타입을 만들지 않는다.
## 결정 3: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
