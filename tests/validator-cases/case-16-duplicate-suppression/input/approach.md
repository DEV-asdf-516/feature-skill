# approach.md
## 결정 1: 라인 금액 합산 [REQUIRED] — NEW `OrderTotalCalculator`
`src/OrderTotalCalculator.java` 에 `public final class OrderTotalCalculator`(private 생성자)를 신설하고 `public static long total(Order order)` 하나를 둔다: 지역 변수 `long sum = 0`, `order.lines()` 를 for-each 로 한 번 순회하며 `sum += line.priceCents() * line.qty()`, `sum` 반환. helper·stream·중간 컬렉션 없음. 요약 전용 계산기를 따로 두면 이후 할인 정책이 붙어도 다른 코드에 영향이 없다.
## 결정 2: 주문 조회 [REQUIRED] — REUSE `OrderService.get`
`summarize` 는 기존 `src/OrderService.java:L4-L6` 의 `get(orderId)` 를 호출해 결과를 지역 변수 `order` 에 둔다. 없는 주문의 NotFoundException 은 `get` 이 던진다 — summarize 에 분기 없음.
## 결정 3: 요약 DTO 와 매핑 [REQUIRED] — NEW `OrderSummary`
탐색(같은 모듈·직접 의존): 요약 응답 타입이 없다. `src/Order.java:L1-L1` 은 엔티티, `src/Line.java:L1-L1` 은 라인이며 가장 가까운 후보 `Order` 는 totalCents·lineCount 필드가 없어 REUSE/EXTEND 불가 → `src/OrderSummary.java` 에 `public record OrderSummary(long orderId, long totalCents, int lineCount) {}` 를 신설한다. 매핑은 `summarize` 안에서 생성자 직접 호출, converter/helper 없음:
```
Order order = get(orderId);
return new OrderSummary(order.id(), OrderTotalCalculator.total(order), order.lines().size());
```
## 결정 4: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
