# implementation.md
## 변경 파일
1. `src/TagMerger.java` — `public List<String> missing(List<String> existing, List<String> incoming)` 추가. 기존 `normalize` 는 그대로 둔다.
2. `src/test/TagMergerTest.java` — 아래 테스트 추가.
## 테스트
- `missing_returnsIncomingNotInExisting`: existing=[a,b], incoming=[b,c,a,d] → [c,d].
- `missing_emptyIncoming_returnsEmpty`: incoming=[] → [].
## 완료 기준
위 두 테스트 통과. 위 두 파일 외 변경 없음.
