# implementation.md
## 변경 파일
1. `src/NotificationService.java` — `public SendStatus send(long id)` 추가. 없는 id → NotFoundException. 반환은 기존 `src/SendStatus.java:L1-L4` 의 `SendStatus`. 기존 생성자·필드는 그대로.
2. `src/test/NotificationServiceTest.java` — 아래 테스트 추가. 기존 테스트 구성(mock repo·mock gateway + `when(...)`/`verify(...)`)을 따른다.
## 테스트
- `send_withPhone_sendsOnceAndReturnsSent`: phone "01012345678" → SENT, `gateway.send("01012345678", "안내 메시지")` 1회.
- `send_emptyPhone_skips`: phone "" → SKIPPED_NO_PHONE, gateway 호출 없음.
- `send_unknownId_throwsNotFound`: 없는 id → NotFoundException.
## 완료 기준
위 세 테스트 통과. 위 두 파일 외 변경 없음.
