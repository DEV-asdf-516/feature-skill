# implementation.md
## 변경 파일
1. `db/migration/V2__user_note.sql` 신규 — `user` 테이블에 `note VARCHAR(500) NULL` 컬럼 추가.
2. `src/User.java` — 생성자·접근자에 `String note` 추가(`User(long id, String name, String note)`, `note()`).
3. `src/UserRepository.java` — `void updateNote(long id, String note)` 추가.
4. `src/UserService.java` — `public void updateNote(long id, String note)` 추가. 생성자에 `ChangeHistoryRepository history` 를 추가로 주입받고, 저장 뒤 `history.save("USER_NOTE", id, before, note)` 로 변경 이력을 남긴다.
5. `src/UserView.java` — `public record UserView(long id, String name, String note)`.
6. `src/UserMapper.java` — `toView` 가 `user.note()` 를 세 번째 인자로 넘긴다. `toView` 의 호출부는 `UserService.get`(`src/UserService.java:L5-L5`) 하나다.
7. `src/test/UserNoteTest.java` 신규 — 아래 테스트.

## 테스트
- `updateNote_thenGet_returnsNote`: 비고 저장 뒤 `get(id).note()` 가 그 값.
- `updateNote_tooLong_throwsAndKeeps`: 501자 → IllegalArgumentException, `get(id).note()` 는 이전 값.
- `updateNote_unknownId_throws`: 없는 id → NotFoundException.
- `updateNote_recordsHistory`: 비고 저장 뒤 `ChangeHistoryRepository.save("USER_NOTE", id, 이전 비고, 새 비고)` 가 1회 호출된다.
## 테스트 setup
`UserRepository` 를 테스트 안의 in-notery 구현으로 대체해 `UserService` 를 직접 생성한다. 테스트 내부 helper·지역 구조는 정하지 않는다.
## 완료 기준
위 테스트 통과. 변경 파일 목록 외 변경 없음.
