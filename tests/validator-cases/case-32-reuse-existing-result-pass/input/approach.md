# approach.md
## 결정 1: 알림 발송 위치 [REQUIRED]
`QuoteService.update`(`src/QuoteService.java:L7-L12`)가 `changeLog.logUpdated(before, update)` 호출 뒤 알림을 조립해 `notifier.send` 를 1회 호출한다. 비동기·재시도 없음.
## 결정 2: 바뀐 필드 판단 [REQUIRED] — REUSE `QuoteChangeLogService.logUpdated` 의 반환값
`update` 는 `logUpdated`(`src/QuoteChangeLogService.java:L9-L15`)가 반환한 `List<ChangeLogEntry>` 를 받아 `QuoteEditNotification.of(long quoteId, List<ChangeLogEntry> changes)` 에 그대로 넘긴다. 알림의 changedFields 는 그 목록의 `field()` 를 순서대로 담은 것이며, 필드 값을 다시 비교하지 않는다.
## 결정 3: 미발송 [REQUIRED]
반환된 변경 항목 목록이 비어 있으면 `notifier.send` 를 호출하지 않는다.
## 결정 4: 포맷·import 순서, changedFields 를 만드는 순회 형태 [DELEGATED]
formatter 와 import 정렬 도구가 정한다. 순회는 for/stream 어느 쪽이든 된다.
