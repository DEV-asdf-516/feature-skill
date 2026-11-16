# design.md
## 계약
- `StockService.apply(StockChange change)` 는 `StockRepository.get(change.sku())` 로 현재 재고를 1회 읽고, 변동을 반영한 `Stock` 을 `StockRepository.save` 로 1회 저장한다. 반환값은 없다.
- IN 이면 저장 수량 = 현재 수량 + 변동 수량, OUT 이면 현재 수량 − 변동 수량. sku 는 그대로다.
## 테스트 기준
- 수량 10 에 IN 3 → 13 저장. 수량 10 에 OUT 4 → 6 저장.
## 비범위
- 음수 재고 검증·동시성 제어·재고 없는 sku 처리 없음.
