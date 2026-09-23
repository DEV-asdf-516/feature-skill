# approach.md
## 결정 1: 재고 반영 [REQUIRED] — REUSE `Stock.add`
`restock` 은 기존 `src/Stock.java:L6-L6` 의 `stock.add(sku, qty)` 로만 재고를 바꾼다(`Stock` 은 범위 밖, 새 class/helper 없음, O(n)). deliveries 는 입력 순서대로 처리하며, 같은 sku 가 여러 건이면 반영 결과는 그 sku 의 qty 합계와 같다.
## 결정 2: 빈 입력 [REQUIRED]
빈 deliveries 는 위 처리에서 아무 호출도 없어 성립한다. 별도 분기 없음.
## 결정 3: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
