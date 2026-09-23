# implementation.md
## 변경 파일
1. `src/TagFormatter.java` — 신설. `public final class TagFormatter`, private 생성자, `public static String joinUpper(java.util.List<String> tags)` 하나만 가진다: 태그를 순서대로 대문자화해 `,` 로 잇는다(빈 목록 → 빈 문자열).
2. `src/ClientService.java` — `public String tagLine(long id)` 추가. 없는 id 면 NotFoundException. 호출 순서: `findOrThrow(id)` → `TagFormatter.joinUpper(client.tags())` 반환. 순회·연결 로직은 `TagFormatter` 에만 있다. 기존 `get`·`findOrThrow` 는 그대로.
3. `src/test/ClientServiceTest.java` — 아래 테스트 추가. 기존 테스트 구성(`repoWith(...)` + `check(...)`, `main` 에서 호출)을 따른다.
## 테스트
- `tagLine_joinsUpperCaseTags`: ["vip","new"] → `"VIP,NEW"`.
- `tagLine_noTags_returnsEmpty`: [] → `""`.
- `tagLine_unknownId_throwsNotFound`: 없는 id → NotFoundException.
## 완료 기준
위 세 테스트 통과(`bash run-tests.sh ClientServiceTest`). 위 세 파일 외 변경 없음.
