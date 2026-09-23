# request.md
## 원문
주문 상태 일괄 조회 `OrderService.statuses(List<Long> ids)` 를 추가한다. 주문 관리 화면이 한 페이지의 주문 id 목록(수백 건)을 넘기면 각 주문의 status 문자열을 입력 순서대로 돌려준다. 하나라도 없는 id 가 있으면 NotFoundException 이다.
## 범위
- `src/OrderService.java` 에 statuses 추가, `src/test/OrderServiceTest.java` 에 테스트 추가.
## 제외
- `src/OrderRepository.java` 는 변경하지 않는다(findById·findAllByIds 모두 이미 있다).
