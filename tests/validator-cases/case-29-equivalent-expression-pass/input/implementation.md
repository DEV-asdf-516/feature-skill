# implementation.md
## 변경 파일
1. `src/OrderSummary.java` 신규 — `public record OrderSummary(long id, String status)`.
2. `src/OrderService.java` — `public List<OrderSummary> findRecent(int limit)` 추가.
3. `src/test/OrderRecentTest.java` 신규 — 아래 테스트.

## 테스트
- `findRecent_returnsIdAndStatusInOrder`: repository 가 (2, "PAID"), (1, "NEW") 를 돌려주면 결과도 그 순서로 id·status 가 같다.
- `findRecent_empty`: repository 가 빈 목록이면 빈 목록.
## 테스트 setup
`OrderRepository` 를 테스트 안의 고정 목록 구현으로 대체해 `OrderService` 를 직접 생성한다. 테스트 내부 helper·지역 구조는 정하지 않는다.
## 완료 기준
위 테스트 통과. 변경 파일 목록 외 변경 없음.
