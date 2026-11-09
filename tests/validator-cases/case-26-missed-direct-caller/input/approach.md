# approach.md
## 결정 1: 보관 주문 제외 위치 [REQUIRED] — EXTEND `OrderQuery.selectOrders`
제외는 조회 SQL 에서 한다. `selectOrders()`(`src/OrderQuery.java:L7-L9`)의 SQL 을 `SELECT id, stage, archived FROM order WHERE archived = false ORDER BY id` 로 바꾼다 — DB 호출은 지금처럼 1회이고 메모리 필터·별도 쿼리 메서드를 만들지 않는다.
## 결정 2: 요약 [REQUIRED]
요약 쿼리는 변경이 불필요하다. `findAllSummary` 은 이번 변경 대상이 아니다.
## 결정 3: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
