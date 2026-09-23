# implementation.md
## 변경 파일
1. `src/ClientService.java` — `public Client update(long id, ClientUpdate update)` 추가. 없는 id 면 NotFoundException. 바뀐 필드의 ChangeLog 를 남기고 갱신된 Client 를 저장·반환. 호출 순서: `findOrThrow` → `DiffUtil.diff` → `ChangeLogWriter.writeAll` → `Client.apply` → `repo.save` → 반환. 기존 `get`·`findOrThrow` 는 그대로.
2. `src/test/ClientServiceTest.java` — 아래 테스트 추가. 기존 테스트 구성(`InMemoryClientRepository` + `ChangeLogWriter(logs::add)` + `check(...)`, `main` 에서 호출)을 따른다.
## 테스트
- `update_logsChangedFieldsOnly`: (1, "Kim", "01012345678", "kim@x.io") 에 ("Lee", "01012345678", "lee@x.io") 갱신 → logs 2건(field 순서 name, email; before/after 값 일치), 반환 name == "Lee", repo.saved 크기 1.
- `update_unknownId_throwsNotFound`: 없는 id → NotFoundException, logs 0건.
## 완료 기준
위 두 테스트 통과(`bash run-tests.sh ClientServiceTest`). 위 두 파일 외 변경 없음.
