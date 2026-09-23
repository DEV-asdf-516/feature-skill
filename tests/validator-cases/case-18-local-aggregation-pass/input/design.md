# design.md
## 계약
- `Inventory.restock(List<Delivery> deliveries)` 뒤 각 sku 의 `onHand` 는 이전 값 + 그 sku 의 qty 합이다.
- deliveries 는 null 이 아니다(호출자 계약). 빈 목록이면 변화 없음.
- 반환값 없음(void).
## 테스트 기준
- [(A, 2), (B, 1), (A, 3)] → onHand(A) 5, onHand(B) 1.
- [] → 변화 없음.
## 비범위
- 정렬·검증·음수 처리 없음.
