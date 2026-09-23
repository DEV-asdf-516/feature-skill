# implementation.md
## 변경 파일
1. `src/ClientService.java` — `public ClientProfile publishProfile(long id)` 추가. 없는 id 면 NotFoundException. 호출 순서: `findOrThrow(id)` → `new ClientProfile(...)` → `publisher.publish(...)` → 반환. 기존 `get`·`profile`·`findOrThrow` 는 그대로.
2. `src/test/ClientServiceTest.java` — 아래 테스트 추가. 기존 테스트 구성(`repoWith` + `RecordingPublisher` + `check`, `main` 에서 호출)을 따른다.
## 테스트
- `publishProfile_publishesOnceAndReturnsSame`: 존재하는 id → 반환 profile 의 id == 1, name == "Kim", publisher.published 크기 1 이고 그 원소가 반환 인스턴스와 같다.
- `publishProfile_unknownId_throwsNotFound`: 없는 id → NotFoundException, published 비어 있음.
## 완료 기준
위 두 테스트 통과(`bash run-tests.sh ClientServiceTest`). 위 두 파일 외 변경 없음.
