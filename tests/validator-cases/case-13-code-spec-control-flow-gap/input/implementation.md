# implementation.md
## 변경 파일
1. `src/Batch.java` — `public List<Item> accepted(List<Item> items)` 추가. 기존 `size` 는 그대로 둔다(`src/Batch.java:L6`). 반환은 새 목록이며 items 를 수정하지 않는다.
2. `src/Classifier.java` — 필요하면 변경(`src/Classifier.java:L1-L5`). 기존 `accepts` 의 계약은 그대로다.
3. `src/test/BatchTest.java` — 아래 테스트 추가.
## 테스트
- `accepted_keepsAcceptedInOrder`: weight [3, 0, 5, -1] → [3, 5].
- `accepted_emptyItems_returnsEmpty`: [] → [].
## 완료 기준
위 두 테스트 통과. 위 세 파일 외 변경 없음.
