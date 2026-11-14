# implementation.md
## 변경 파일
1. `src/TaskService.java` — `update` 가 변경 로그 저장 뒤 수정 알림을 보낸다(바뀐 필드가 없으면 보내지 않는다).
2. `src/TaskEditNotification.java` — `of(Task before, TaskUpdate update)` 정적 factory 추가.
3. `src/test/TaskServiceTest.java` — 아래 테스트 추가.

## 테스트
- `update_notifiesChangedFields`: title·dueDate 만 바뀐 수정 → `Notifier.send` 1회, changedFields == ["title", "dueDate"].
- `update_noChange_doesNotNotify`: 값이 모두 같은 수정 → `Notifier.send` 0회.
## 테스트 setup
`TaskRepository`·`ChangeLogRepository`·`Notifier` 를 테스트 안의 기록용 구현으로 대체해 `TaskService` 를 직접 생성한다. 테스트 내부 helper·지역 구조는 정하지 않는다.
## 완료 기준
위 테스트 통과. 변경 파일 목록 외 변경 없음.
