# request.md
## 원문
입고 목록을 재고에 반영하는 `Inventory.restock(List<Delivery>)` 를 추가한다. 같은 sku 가 여러 건이면 수량이 모두 더해진다.
## 범위
- `src/Inventory.java`, `src/test/InventoryTest.java`
## 제외
- `src/Stock.java` 변경 없음.
