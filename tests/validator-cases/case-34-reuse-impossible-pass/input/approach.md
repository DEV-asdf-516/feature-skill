# approach.md
## 결정 1: 알림 발송 위치 [REQUIRED]
`QuoteService.update`(`src/QuoteService.java:L7-L12`)가 `changeLog.logUpdated(before, update)` 호출 뒤 알림을 조립해 `notifier.send` 를 1회 호출한다. 비동기·재시도 없음.
## 결정 2: 바뀐 필드 판단 [REQUIRED]
`QuoteEditNotification.of(Quote before, QuoteUpdate update)` 가 title·amount·dueDate 를 before 와 update 로 각각 비교해 값이 다른 필드 이름 목록을 직접 계산한다. `update` 는 지금처럼 `logUpdated` 의 반환값을 받지 않는다. 탐색: 기존 `logUpdated`(`src/QuoteChangeLogService.java:L9-L15`)는 저장 건수(`int`)만 반환해 필드 이름을 얻을 수 없고, `QuoteChangeLogService` 는 request.md 의 변경 제외 대상이다.
## 결정 3: 미발송 [REQUIRED]
계산한 목록이 비어 있으면 `notifier.send` 를 호출하지 않는다.
## 결정 4: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
