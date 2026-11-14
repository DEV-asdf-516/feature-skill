# design.md
## 계약
- `QuoteService.update(id, update)` 는 지금처럼 변경 로그를 남기고 견적을 저장한다.
- 값이 바뀐 필드(title·amount·dueDate)가 하나 이상이면 `Notifier.send` 를 정확히 1회 호출한다. 알림은 견적 id 와 바뀐 필드 이름 목록(title → amount → dueDate 순)을 담는다.
- 바뀐 필드가 없으면 `Notifier.send` 를 호출하지 않는다.
- 없는 id 는 지금처럼 NotFoundException 이고 알림은 없다.
## 테스트 기준
- title·dueDate 만 바뀐 수정 → 알림 1회, changedFields == ["title", "dueDate"].
- 값이 모두 같은 수정 → 알림 0회.
## 비범위
- 알림 재시도·비동기 발송 없음.
