# implementation.md
## 변경 파일
1. `src/ClientService.java` — `public Client rename(long id, String newName)` 추가. 없는 id 면 NotFoundException. 호출 순서: `findOrThrow(id)` → `Client.withName(newName)` → `repo.save(...)` → 반환. 기존 `get`·`changePhone`·`findOrThrow` 는 그대로.
2. `src/test/ClientServiceTest.java` — 아래 테스트 추가. 기존 테스트 구성(`InMemoryClientRepository` + `check(...)`, `main` 에서 호출)을 따른다.
## 테스트
- `rename_savesAndReturnsRenamed`: id 1 "Kim" → rename(1, "Lee") 의 name == "Lee", repo.saved 크기 1 이고 반환 인스턴스와 같다.
- `rename_unknownId_throwsNotFound`: 없는 id → NotFoundException, repo.saved 비어 있음.
## 완료 기준
위 두 테스트 통과(`bash run-tests.sh ClientServiceTest`). 위 두 파일 외 변경 없음.
