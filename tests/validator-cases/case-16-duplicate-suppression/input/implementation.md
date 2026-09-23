# implementation.md
## 변경 파일
1. `src/OrderSummary.java` 신규 — `public record OrderSummary(long orderId, long totalCents, int lineCount)`.
2. `src/OrderTotalCalculator.java` 신규 — `public static long total(Order order)`.
3. `src/OrderService.java` — `public OrderSummary summarize(long orderId)` 추가. 기존 `get`(`src/OrderService.java:L4-L6`)은 그대로 둔다.
4. `src/test/OrderSummaryTest.java` 신규 — 아래 테스트.
## 테스트
- `summarize_totalsAndCounts`: lines [(100, 2), (50, 1)] → totalCents 250, lineCount 2.
- `summarize_unknownOrder_throws`: 없는 id → NotFoundException.
## 테스트 setup
`OrderRepository` 는 테스트 안에서 고정 `Order` / `Optional.empty()` 를 돌려주는 stub 으로 두고 `OrderService` 를 직접 호출한다. 테스트 내부 helper·지역 구조는 정하지 않는다.
## 완료 기준
위 두 테스트 통과. 위 네 파일 외 변경 없음.
