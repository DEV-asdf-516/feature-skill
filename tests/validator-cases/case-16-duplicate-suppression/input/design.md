# design.md
## 계약
- `OrderService.summarize(long orderId)` → `{orderId, totalCents, lineCount}`.
- totalCents 는 각 line 의 priceCents × qty 의 합. lineCount 는 lines 크기.
- 없는 주문 → NotFoundException(→ 404).
## 테스트 기준
- lines [(100, 2), (50, 1)] → totalCents 250, lineCount 2.
- 없는 주문 → NotFoundException.
