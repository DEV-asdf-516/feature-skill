# approach.md
## 결정 1: 비고 저장 경로 [REQUIRED] — EXTEND `UserRepository`
기존 `UserRepository`(`src/UserRepository.java:L1-L4`)에 `updateNote(long id, String note)` 를 추가한다 — `updateName` 과 같은 단건 갱신이며 별도 repository 를 만들지 않는다. `UserService.updateNote` 의 순서: 길이 검사(500자 초과면 IllegalArgumentException) → 기존 `findOrThrow(id)`(`src/UserService.java:L12-L14`) REUSE 로 존재 확인 → `repo.updateNote(id, note)` 1회. null note 는 길이 검사를 건너뛰고 그대로 저장한다.
## 결정 2: 스키마 [REQUIRED]
`db/migration/V2__user_note.sql` 에서 `ALTER TABLE user ADD COLUMN note VARCHAR(500) NULL`. 기존 `db/migration/V1__user.sql` 은 고치지 않는다(request 의 기존 데이터 계약).
## 결정 3: 조회 응답 [REQUIRED] — EXTEND `UserView`·`UserMapper.toView`
`UserView` 에 `note` 를 세 번째 component 로 추가하고 `UserMapper.toView`(`src/UserMapper.java:L3-L3`)가 `user.note()` 를 넘긴다. 변환 책임은 지금처럼 `UserMapper` 에 둔다.
## 결정 4: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
