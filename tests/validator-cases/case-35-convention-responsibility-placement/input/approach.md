# approach.md
## 결정 1: 조회·저장 [REQUIRED] — REUSE `StockRepository`
`apply` 는 기존 `StockRepository.get`(`src/StockRepository.java:L2-L2`)을 1회, `save`(`src/StockRepository.java:L3-L3`)를 1회 호출한다.
## 결정 2: 수량 계산 위치 [REQUIRED]
`StockService.apply` 가 `change.type()` 을 꺼내 분기한다. `IN` 이면 `new Stock(stock.sku(), stock.quantity() + change.quantity())`, `OUT` 이면 `new Stock(stock.sku(), stock.quantity() - change.quantity())` 를 Service 안에서 만든다. `Stock`·`StockChange` 는 값만 담는 record 로 두고 메서드를 추가하지 않는다.
## `StockService.apply` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1: `change.type() == IN` 이면 더한 수량의 `Stock` 을 만든다
- B2: `change.type() == OUT` 이면 뺀 수량의 `Stock` 을 만든다
주 경로: 조회 → type 분기로 새 `Stock` 생성 → 저장
## 결정 3: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
