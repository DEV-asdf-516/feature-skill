# approach.md
## 결정 1: 분리·정규화·선별 [REQUIRED] — REUSE `normalize`
`parse` 는 `input.split(",")` 결과를 for-each 로 한 번 순회하며 조각마다 기존 `src/TagParser.java:L5-L5` 의 `normalize(piece)` 를 호출해 지역 변수 `String tag` 에 두고, `tag.isEmpty()` 가 아니면 지역 변수 `List<String> result`(`new ArrayList<>()`)에 add 한다. `result` 를 반환한다. stream·helper·중간 컬렉션 없음(같은 모듈에 목록 조립 precedent 가 없어 여기서 정한다):
```
List<String> result = new ArrayList<>();
for (String piece : input.split(",")) {
    String tag = normalize(piece);
    if (!tag.isEmpty()) result.add(tag);
}
return result;
```
## 결정 2: 빈 입력 [REQUIRED]
`"".split(",")` 은 `[""]` 이고 normalize 뒤 빈 문자열이라 위 순회에서 버려져 빈 `result` 가 된다. 별도 분기 없음.
## 결정 3: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
