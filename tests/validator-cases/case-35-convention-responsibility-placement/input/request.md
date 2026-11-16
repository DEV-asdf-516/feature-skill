# request.md
## 원문
재고 변동을 반영하는 `StockService.apply(StockChange change)` 를 추가한다. 입고(IN)는 현재 수량에 더하고 출고(OUT)는 뺀 수량으로 저장한다.
## 범위
- `src/StockService.java`, `src/Stock.java`, `src/StockChange.java`, `src/test/StockApplyTest.java`
## 제외
- `StockRepository` 변경 없음. 음수 재고 검증 없음.
