# implementation.md
적용 conventions: 1.1, 1.2
## 변경 파일
1. `src/StockService.java` — `public void apply(StockChange change)` 추가.
2. `src/test/StockApplyTest.java` 신규 — 아래 테스트.

## 테스트
- `apply_in_addsQuantity`: 수량 10 인 재고에 IN 3 을 적용하면 수량 13 인 같은 sku 가 저장된다.
- `apply_out_subtractsQuantity`: 수량 10 인 재고에 OUT 4 를 적용하면 수량 6 인 같은 sku 가 저장된다.
## 테스트 setup
`StockRepository` 를 테스트 안의 메모리 구현으로 대체해 `StockService` 를 직접 생성한다. 테스트 내부 helper·지역 구조는 정하지 않는다.
## 완료 기준
위 테스트 통과. 변경 파일 목록 외 변경 없음.
