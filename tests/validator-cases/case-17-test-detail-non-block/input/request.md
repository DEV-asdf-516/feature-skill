# request.md
## 원문
쉼표로 구분된 태그 문자열을 태그 목록으로 바꾸는 `TagParser.parse(String)` 을 추가한다. 각 태그는 기존 normalize 를 거치고, 빈 태그는 버린다. 순서는 입력 순서다.
## 범위
- `src/TagParser.java`, `src/test/TagParserTest.java`
