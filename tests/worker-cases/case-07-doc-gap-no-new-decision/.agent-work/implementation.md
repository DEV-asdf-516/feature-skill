# implementation.md
## 변경 파일
1. `src/ClientService.java` — `summary(long id)` 추가. 없는 id 면 NotFoundException. 호출 순서: `findOrThrow(id)` → `MaskingUtil.maskPhone(...)` → 요약 반환. 반환 타입과 요약의 표현은 approach.md 가 정한다. 기존 `get`·`findOrThrow` 는 그대로.
2. `src/test/ClientServiceTest.java` — 아래 테스트 추가. 기존 테스트 구성(`repoWith(...)` + `check(...)`, `main` 에서 호출)을 따른다.
## 테스트
- `summary_returnsThreeValues`: 존재하는 id → id 1, name "Kim", maskedPhone "010****5678".
- `summary_unknownId_throwsNotFound`: 없는 id → NotFoundException.
## 완료 기준
위 두 테스트 통과(`bash run-tests.sh ClientServiceTest`).
