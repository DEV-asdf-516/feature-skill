# approach.md
## 결정 1: 변환 [REQUIRED]
`StockReturnMessage.toChange()` 는 `new StockChange(sku, StockChange.Type.IN, quantity)` 를 반환한다(`src/StockChange.java:L1-L3`). reason 은 싣지 않는다.
## 결정 2: 필수값 검증 [REQUIRED]
기존 `StockImportMessage.toChange` 의 검증 블록(`src/StockImportMessage.java:L3-L12`)과 같은 형태로 쓴다 — sku·quantity 의 누락 여부를 모은 뒤 한 번에 `IllegalArgumentException("stock return message: required field missing")` 을 던진다.
## 결정 3: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
