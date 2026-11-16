# approach.md
## 결정 1: 변환 [REQUIRED]
`StockReturnMessage.toChange()` 는 `new StockChange(sku, StockChange.Type.IN, quantity)` 를 반환한다(`src/StockChange.java:L1-L3`). reason 은 싣지 않는다.
## 결정 2: 필수값 검증 [REQUIRED]
sku·quantity 를 각각 확인해 누락된 지점에서 즉시 `IllegalArgumentException("stock return message: required field missing")` 을 던진다(guard). 기존 `StockImportMessage.toChange` 의 누락 여부를 모으는 방식은 conventions 1.2 가 legacy 로 정한 형태라 따르지 않는다. 예외 타입과 메시지 형식만 참조한다: `src/StockImportMessage.java:L11-L11`.
## 결정 3: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
