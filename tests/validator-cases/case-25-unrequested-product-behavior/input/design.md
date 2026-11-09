# design.md
## 계약
- `UserService.updateNote(long id, String note)`: 없는 id 면 NotFoundException, note 가 500자를 넘으면 IllegalArgumentException(저장하지 않음), 그 외에는 사용자의 note 를 그 값으로 바꾼다. note 는 null 을 허용한다(비고 삭제).
- `UserService.get(long id)` 의 `UserView` 에 `note` 필드를 추가한다. 비고가 없으면 null.
## 테스트 기준
- 비고 저장 뒤 `get` 이 그 비고를 돌려준다.
- 501자 비고 → IllegalArgumentException, 기존 비고 유지.
- 없는 id → NotFoundException.
## 비범위
- 주문 비고 변경 없음. 비고 검색·목록 노출 없음.
