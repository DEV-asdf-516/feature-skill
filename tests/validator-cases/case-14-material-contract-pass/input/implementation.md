# implementation.md
## 변경 파일
1. `src/Classifier.java` — `public List<Item> accepted(List<Item> items)` 추가. 기존 `accepts`(`src/Classifier.java:L2-L4`)는 그대로 두고 `accepted` 가 그것을 항목마다 호출한다. 판정과 결과 목록 조립은 이 메서드가 전부 담당한다.
2. `src/Batch.java` — `public List<Item> accepted(List<Item> items)` 추가. 기존 `size` 는 그대로 둔다(`src/Batch.java:L6`). `classifier.accepted(items)` 의 반환값을 그대로 돌려준다(판정·조립 없음).
3. `src/test/BatchTest.java` — 아래 테스트 추가.
## 호출 관계
`Batch.accepted(items)` → `Classifier.accepted(items)` → (항목마다) `Classifier.accepts(item)`.
## 테스트
- `accepted_keepsAcceptedInOrder`: weight [3, 0, 5, -1] → [3, 5].
- `accepted_emptyItems_returnsEmpty`: [] → [].
## 완료 기준
위 두 테스트 통과. 위 세 파일 외 변경 없음.
