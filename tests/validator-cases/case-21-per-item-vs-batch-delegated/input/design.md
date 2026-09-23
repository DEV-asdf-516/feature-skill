# design.md
## 목표
`OrderService.statuses(List<Long> ids)` → 각 id 의 status 를 입력 순서대로 담은 `List<String>`.
## 계약
- ids 는 null 이 아니다(호출자 계약). 빈 목록이면 빈 결과.
- 없는 id 가 하나라도 있으면 NotFoundException(기존 타입).
- 호출 규모: 한 페이지 최대 500 건. repository 는 DB 를 친다.
## 테스트 기준
- ids [1, 2] 에 status [PAID, SHIPPED] → [PAID, SHIPPED].
- ids [1, 9] 에 9 없음 → NotFoundException.
## 비범위
- 정렬·중복 제거·캐시 없음.
