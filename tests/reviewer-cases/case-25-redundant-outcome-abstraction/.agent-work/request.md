# request.md
## 원문
클라이언트에게 안내 SMS 를 보내는 `NotificationService.send(id)` 를 추가한다. 전화번호가 비어 있는 클라이언트는 발송하지 않고 건너뛴 결과를 돌려준다. 결과는 기존 `SendStatus` 로 돌려준다.
## 범위
- `src/NotificationService.java` 에 send 추가, `src/test/NotificationServiceTest.java` 에 테스트 추가.
## 제외
- `src/SendStatus.java`, `src/SmsGateway.java`, `src/ClientRepository.java` 는 변경하지 않는다.
