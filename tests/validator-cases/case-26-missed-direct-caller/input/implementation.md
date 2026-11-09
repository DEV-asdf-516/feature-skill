# implementation.md
## 변경 파일
1. `src/OrderQuery.java` — `selectOrders()`(`src/OrderQuery.java:L7-L9`)의 SQL 에 `WHERE archived = false` 를 추가한다. signature 는 그대로다.
2. `src/test/OrderListTest.java` 신규 — 아래 테스트.
`src/OrderService.java` 는 변경하지 않는다 — `findAll` 은 `selectOrders()` 결과를 그대로 돌려주므로 쿼리 변경만으로 충족되고, 요약은 별도 조회라 이번 쿼리 변경의 영향이 없다.
## 테스트
- `findAll_excludesArchived`: 보관 1건·미보관 2건 → `findAll()` 은 미보관 2건, id 오름차순.
## 테스트 setup
`Db` 를 테스트 안에서 SQL 문자열의 `WHERE archived = false` 유무에 따라 고정 목록을 돌려주는 구현으로 대체해 `OrderService` 를 직접 생성한다. 테스트 내부 helper·지역 구조는 정하지 않는다.
## 완료 기준
위 테스트 통과. 위 두 파일 외 변경 없음.
