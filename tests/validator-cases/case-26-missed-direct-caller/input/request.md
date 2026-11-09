# request.md
## 원문
주문 목록 화면에서 보관된 주문을 숨긴다. `OrderService.findAll` 은 보관되지 않은 주문만 돌려준다. 요약 화면(`OrderService.findAllSummary`)은 지금처럼 보관된 주문을 포함해 전부 보여준다.
## 범위
- `src/OrderQuery.java`, `src/OrderService.java`, `src/test/OrderListTest.java`
## 제외
- `order` 테이블 스키마 변경 없음.
