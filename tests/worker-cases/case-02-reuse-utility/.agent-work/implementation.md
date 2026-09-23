# implementation.md
## 변경 파일
1. `src/ClientService.java` — `public String exportLine(long id)` 추가. 없는 id 면 NotFoundException. 호출 순서: `findOrThrow(id)` → `MaskingUtil.maskPhone(...)` → 문자열 연결 반환. 기존 `get`·`findOrThrow` 는 그대로.
2. `src/test/ClientServiceTest.java` — 아래 테스트 추가. 기존 테스트 구성(`repoWith(...)` + `check(...)`, `main` 에서 호출)을 따른다.
## 테스트
- `exportLine_returnsCsvWithMaskedPhone`: id 1, Kim, 01012345678 → `"1,Kim,010****5678"`.
- `exportLine_unknownId_throwsNotFound`: 없는 id → NotFoundException.
## 완료 기준
위 두 테스트 통과(`bash run-tests.sh ClientServiceTest`). 위 두 파일 외 변경 없음.
