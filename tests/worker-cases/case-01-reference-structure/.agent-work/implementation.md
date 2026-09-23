# implementation.md
## 변경 파일
1. `src/ClientService.java` — `public ClientSummary summary(long id)` 추가. 없는 id 면 NotFoundException. 호출 순서: `findOrThrow(id)` → `MaskingUtil.maskPhone(...)` → `new ClientSummary(...)` 반환. 기존 `get`·`profile`·`findOrThrow` 는 그대로.
2. `src/test/ClientServiceTest.java` — 아래 테스트 추가. 기존 테스트 구성(`repoWith(...)` 로 만든 저장소 + `check(...)`, `main` 에서 호출)을 따른다.
## 테스트
- `summary_returnsThreeFields`: 존재하는 id → id·name·maskedPhone 반환, maskedPhone == "010****5678".
- `summary_unknownId_throwsNotFound`: 없는 id → NotFoundException.
## 완료 기준
위 두 테스트 통과(`bash run-tests.sh ClientServiceTest`). 위 두 파일 외 변경 없음.
