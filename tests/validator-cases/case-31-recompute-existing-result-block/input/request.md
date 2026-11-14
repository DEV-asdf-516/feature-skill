# request.md
## 원문
견적을 수정하면 수정 알림을 보낸다. 알림에는 견적 id 와 값이 바뀐 필드 이름 목록을 담는다. 바뀐 필드가 없으면 알림을 보내지 않는다.
## 범위
- `src/QuoteService.java` 의 `update`, `src/QuoteEditNotification.java`, `src/test/QuoteServiceTest.java`
## 제외
- `QuoteChangeLogService`·`ChangeLogEntry`·`ChangeLogRepository`·`Notifier` 변경 없음. 알림 문구·채널은 이번 작업이 아니다.
