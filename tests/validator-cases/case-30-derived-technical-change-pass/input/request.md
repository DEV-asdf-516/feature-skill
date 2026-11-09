# request.md
## 원문
사용자에 비고를 남길 수 있게 한다. `UserService.updateNote(id, note)` 로 비고를 저장하고, 사용자 상세 조회(`UserService.get`)에 비고를 함께 보여준다.
## 범위
- `src/User.java`, `src/UserRepository.java`, `src/UserService.java`, `src/UserMapper.java`, `src/UserView.java`, `db/migration/` 아래 신규 migration, `src/test/UserNoteTest.java`
## 제외
- 주문 비고(`src/OrderNoteService.java`)는 이번 범위가 아니다.

## 기존 데이터 계약
`user` 테이블은 `db/migration/V1__user.sql` 로 만들어졌다. 스키마 변경은 새 migration 파일로만 한다.
