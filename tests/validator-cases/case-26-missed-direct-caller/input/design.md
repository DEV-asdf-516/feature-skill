# design.md
## 계약
- `OrderService.findAll()` 은 `archived = false` 인 주문만 id 오름차순으로 돌려준다.
- `OrderService.findAllSummary()` 의 결과는 바뀌지 않는다 — 보관된 주문을 포함한 전체를 stage 별로 묶는다.
## 테스트 기준
- 보관 1건·미보관 2건 → `findAll` 은 미보관 2건.
## 비범위
- 스키마·정렬 기준 변경 없음.
