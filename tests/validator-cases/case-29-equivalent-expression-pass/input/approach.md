# approach.md
## 결정 1: 조회 [REQUIRED] — REUSE `OrderRepository.findRecent`
`findRecent` 는 기존 `OrderRepository.findRecent(limit)`(`src/OrderRepository.java:L5-L5`)를 1회 호출한다. 정렬·필터를 추가하지 않는다.
## 결정 2: 반환 타입 [REQUIRED] — NEW `OrderSummary`
새 조회 계약(id, status)에 직접 대응하는 응답 record `OrderSummary(long id, String status)` 를 `src/OrderSummary.java` 에 둔다. 엔티티→`OrderSummary` 변환은 `OrderService` 안에서 하고 repository 가 돌려준 순서를 유지한다. 별도 converter class 는 만들지 않는다.
## 결정 3: 변환 표현 [DELEGATED]
변환을 private helper 로 뺄지 inline 할지, 지역 변수 유무, for/stream 은 워커가 정한다.
## 결정 4: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
