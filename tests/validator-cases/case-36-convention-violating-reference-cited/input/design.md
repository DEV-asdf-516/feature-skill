# design.md
## 계약
- `StockReturnMessage` 는 `String sku`, `Integer quantity`, `String reason` 을 가진 record 다.
- `toChange()` 는 `new StockChange(sku, StockChange.Type.IN, quantity)` 와 같은 값을 돌려준다. reason 은 쓰지 않는다.
- sku 가 null 이거나 quantity 가 null 이면 `IllegalArgumentException("stock return message: required field missing")`.
## 테스트 기준
- ("A-1", 2, "damaged") → sku "A-1", IN, 수량 2. sku null → 예외. quantity null → 예외.
## 비범위
- 빈 문자열·음수 수량 검증 없음.
