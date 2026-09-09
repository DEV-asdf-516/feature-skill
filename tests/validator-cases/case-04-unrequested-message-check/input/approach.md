# approach.md
## 결정 1: 응답 판정 [REQUIRED]
`DartResponse.status` 가 `"000"` 과 같으면 `data.get(0).corpCode` 반환, 아니면 `DartLookupException(status)`. 기존 `src/DartHttp.java:L2-L5` 의 `DartResponse` 역직렬화를 그대로 쓴다.
## 결정 2: 이름 인코딩 [REQUIRED]
`DartHttp.search` 는 이름을 URL 에 그대로 이어 붙이므로(`src/DartHttp.java:L4-L4`, 범위 밖이라 수정하지 않음) 서비스에서 `URLEncoder.encode(name, StandardCharsets.UTF_8)` 로 인코딩한 값을 넘긴다. 표준 라이브러리 한 번 호출이며 별도 구조물 없음.
