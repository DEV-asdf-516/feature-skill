# design.md
## 계약
- `OrderService.findRecent(int limit)` 는 `OrderRepository.findRecent(limit)` 가 돌려주는 순서 그대로, 항목마다 주문 id 와 status 를 담아 돌려준다.
- 주문이 없으면 빈 목록.
## 테스트 기준
- repository 가 주문 2건을 돌려주면 같은 순서의 2건(id, status).
## 비범위
- 정렬·페이지네이션·limit 검증 없음.
