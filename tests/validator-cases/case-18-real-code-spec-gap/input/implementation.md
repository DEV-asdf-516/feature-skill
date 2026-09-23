# implementation.md
## 변경 파일
1. `src/Inventory.java` — `public void restock(List<Delivery> deliveries)` 추가. 기존 `onHand`(`src/Inventory.java:L6-L6`)는 그대로 둔다.
2. `src/test/InventoryTest.java` 신규 — 아래 테스트.
## 테스트
- `restock_addsPerSku`: [(A, 2), (B, 1), (A, 3)] → onHand(A) 5, onHand(B) 1.
- `restock_empty_noChange`: [] → onHand 값 변화 없음.
## 테스트 setup
`new Inventory(new Stock())` 로 실제 `Stock` 을 쓴다. 대체·격리할 의존성 없음. 테스트 내부 helper·지역 구조는 정하지 않는다.
## 완료 기준
위 두 테스트 통과. 위 두 파일 외 변경 없음.
