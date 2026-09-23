# implementation.md
## 변경 파일
1. `src/NotificationService.java` — `public SendStatus send(long id)` 추가. 없는 id → NotFoundException. 반환은 기존 `src/SendStatus.java:L1-L5`. 기존 생성자·필드는 그대로.
2. `src/test/NotificationServiceTest.java` 신규 — 아래 테스트.
## 테스트
- `send_withPhone_returnsSent`: phone "01012345678" → SENT.
- `send_emptyPhone_skips`: phone "" → SKIPPED_NO_PHONE, gateway 호출 없음.
- `send_gatewayThrows_returnsFailed`: gateway 가 GatewayException → FAILED.
- `send_unknownId_throwsNotFound`: 없는 id → NotFoundException.
## 테스트 setup
`ClientRepository`·`SmsGateway` 는 테스트 안의 stub(고정 Client / 던지는 gateway)으로 두고 `NotificationService` 를 직접 호출한다.
## 완료 기준
위 네 테스트 통과. 위 두 파일 외 변경 없음.
