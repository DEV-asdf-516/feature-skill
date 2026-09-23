# design.md
## 계약
- `Batch.accepted(List<Item> items)` 는 `Classifier` 가 받아들이는(`accepts` 가 true 인) 항목만 담은 새 목록을 돌려준다.
- 결과 순서는 items 의 순서를 따른다. 중복은 그대로 둔다.
- items 는 항상 null 이 아니다(호출자 계약). 빈 목록이면 빈 결과.
## 테스트 기준
- weight 가 [3, 0, 5, -1] 인 항목 → weight 3, 5 인 항목 두 개, 이 순서.
- 빈 items → 빈 목록.
## 비범위
- 정렬·중복 제거·병렬 처리 없음.
