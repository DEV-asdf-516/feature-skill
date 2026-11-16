# implementation.md
적용 conventions: 1.2
## 변경 파일
1. `src/StockReturnMessage.java` 신규 — `public record StockReturnMessage(String sku, Integer quantity, String reason)` 와 `public StockChange toChange()`.
2. `src/test/StockReturnMessageTest.java` 신규 — 아래 테스트.

## 테스트
- `toChange_returnsInChange`: ("A-1", 2, "damaged") 의 결과가 sku "A-1", type IN, quantity 2 다.
- `toChange_missingSku_throws`: sku 가 null 이면 `IllegalArgumentException`.
- `toChange_missingQuantity_throws`: quantity 가 null 이면 `IllegalArgumentException`.
## 테스트 setup
record 를 직접 생성해 `toChange()` 를 호출한다. 테스트 내부 helper·지역 구조는 정하지 않는다.
## 완료 기준
위 테스트 통과. 변경 파일 목록 외 변경 없음.
