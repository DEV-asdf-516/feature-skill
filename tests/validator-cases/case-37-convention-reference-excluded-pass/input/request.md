# request.md
## 원문
반품 입고 메시지 `StockReturnMessage(sku, quantity, reason)` 를 신설하고 `toChange()` 로 입고(IN) `StockChange` 로 바꾼다. sku 또는 quantity 가 없으면 `IllegalArgumentException` 을 던진다.
## 범위
- `src/StockReturnMessage.java`(신규), `src/test/StockReturnMessageTest.java`(신규)
## 제외
- `StockImportMessage`·`StockChange` 변경 없음. reason 은 `StockChange` 에 싣지 않는다.
