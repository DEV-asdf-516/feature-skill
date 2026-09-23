# implementation.md
## 변경 파일
1. `src/OrderService.java` — `public List<String> statuses(List<Long> ids)` 추가. 없는 id → NotFoundException. 기존 `get` 은 그대로.
2. `src/test/OrderServiceTest.java` — 아래 테스트 추가. 기존 테스트 구성(mock repo + `when(...).thenReturn(...)`)을 따른다.
## 테스트
- `statuses_returnsInInputOrder`: ids [1, 2] → [PAID, SHIPPED].
- `statuses_unknownId_throwsNotFound`: ids [1, 9], 9 없음 → NotFoundException.
## 완료 기준
위 두 테스트 통과. 위 두 파일 외 변경 없음.
