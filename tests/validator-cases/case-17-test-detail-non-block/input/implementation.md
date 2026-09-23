# implementation.md
## 변경 파일
1. `src/TagParser.java` — `public static List<String> parse(String input)` 추가. 기존 `normalize`(`src/TagParser.java:L5-L5`)는 그대로 두고 `parse` 가 조각마다 호출한다.
2. `src/test/TagParserTest.java` — 기존 파일(`src/test/TagParserTest.java:L1-L9`)에 아래 테스트를 추가한다. 기존 테스트는 그대로.
## 테스트
- `parse_normalizesAndDropsEmpty`: "Java, ,kotlin ,  " → ["java", "kotlin"].
- `parse_emptyInput_returnsEmpty`: "" → [].
- `parse_keepsDuplicates`: "a,a" → ["a", "a"].
## 테스트 setup
입력 문자열과 기대 목록만으로 검증한다. 대체·격리할 의존성 없음. 테스트 내부의 helper·지역 변수·반복 구조·assertion 묶음 방식은 정하지 않는다 — 기존 `TagParserTest` 의 형태를 따르면 된다.
## 완료 기준
위 세 테스트 통과. 위 두 파일 외 변경 없음.
