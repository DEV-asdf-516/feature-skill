# implementation.md
## 변경 파일
1. `src/ClientService.java` — `public String tagLine(long id)` 추가. 없는 id 면 NotFoundException. 조회 → 태그 순회(대문자화·`,` 연결) → 반환. 순회와 연결 로직은 `tagLine` 본문 안에 있다(approach.md 결정 2). 기존 `get`·`findOrThrow` 는 그대로.
2. `src/test/ClientServiceTest.java` — 아래 테스트 추가. 기존 테스트 구성(`repoWith(...)` + `check(...)`, `main` 에서 호출)을 따른다.
## 테스트
- `tagLine_joinsUpperCaseTags`: ["vip","new"] → `"VIP,NEW"`.
- `tagLine_noTags_returnsEmpty`: [] → `""`.
- `tagLine_unknownId_throwsNotFound`: 없는 id → NotFoundException.
## 완료 기준
위 세 테스트 통과(`bash run-tests.sh ClientServiceTest`). 위 두 파일 외 변경 없음.
