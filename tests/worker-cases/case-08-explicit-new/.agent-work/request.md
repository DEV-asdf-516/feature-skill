# request.md
## 원문
클라이언트 태그 한 줄 `ClientService.tagLine(id)` 를 추가한다. 태그를 대문자로 바꿔 `,` 로 이어 붙인 문자열이다.
## 범위
- `src/ClientService.java` 에 tagLine 추가, 태그 포매터 `src/TagFormatter.java` 신설, `src/test/ClientServiceTest.java` 에 테스트 추가.
## 제외
- 기존 `get`·`Client` 는 변경하지 않는다.
