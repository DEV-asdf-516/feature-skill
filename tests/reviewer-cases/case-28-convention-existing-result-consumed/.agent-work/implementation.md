# implementation.md
## 변경 파일
1. `src/QuoteService.java` — `update` 가 변경 로그 저장 뒤 수정 알림을 보낸다(바뀐 필드가 없으면 보내지 않는다).
2. `src/QuoteEditNotification.java` — 알림을 만드는 정적 factory `of` 추가.
3. `src/test/QuoteServiceTest.java` — 아래 테스트 추가.
## 테스트
- `update_notifiesChangedFields`: title·dueDate 만 바뀐 수정 → `Notifier.send` 1회, changedFields == ["title", "dueDate"].
- `update_noChange_doesNotNotify`: 값이 모두 같은 수정 → `Notifier.send` 0회.
## 완료 기준
위 두 테스트 통과. 위 세 파일 외 변경 없음.
