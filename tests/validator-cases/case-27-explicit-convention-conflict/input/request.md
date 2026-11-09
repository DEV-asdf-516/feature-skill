# request.md
## 원문
최근 주문 목록을 돌려주는 `OrderService.findRecent(limit)` 를 추가한다. 항목마다 주문 id 와 status 를 준다.
## 범위
- `src/OrderService.java`, 응답 타입이 필요하면 `src/` 아래 신설 가능, `src/test/OrderRecentTest.java`
## 제외
- `OrderRepository`·`OrderEntity` 변경 없음. 기존 `OrderService.get` 변경 없음.
