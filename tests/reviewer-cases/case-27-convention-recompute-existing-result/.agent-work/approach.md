# approach.md
## 결정 1: 알림 발송 위치 [REQUIRED]
`QuoteService.update`(`src/QuoteService.java:L7-L12`)가 `changeLog.logUpdated(before, update)` 호출 뒤 `notifier.send` 를 1회 호출한다. 비동기·재시도 없음.
## 결정 2: 알림 내용 [REQUIRED]
알림은 견적 id 와 바뀐 필드 이름 목록(title → amount → dueDate 순)을 담은 `QuoteEditNotification` 이며 `QuoteEditNotification.of` 로 만든다.
## 결정 3: 미발송 [REQUIRED]
바뀐 필드가 없으면 `notifier.send` 를 호출하지 않는다.
## 결정 4: 변수명·지역 변수·순회 형태·private helper 유무 [DELEGATED]
## `QuoteService.update` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 4: 없는 id → NotFoundException (기존 그대로)
- B2 / design 계약 3: 바뀐 필드 없음 → 알림 미발송 (결정 3)
주 경로: 견적 조회 → 변경 로그 저장 → 알림 발송 → 갱신 사본 저장 → 반환
금지: 위 목록에 없는 null·빈값 방어 분기 · fallback · 재시도
