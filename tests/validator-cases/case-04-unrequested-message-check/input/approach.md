# approach.md
## 결정 1: 응답 판정 [REQUIRED]
`DartResponse.status` 가 `"000"` 과 같으면 `data.get(0).corpCode` 반환, 아니면 `DartLookupException(status)`. 기존 `src/DartHttp.java:L2-L5` 의 `DartResponse` 역직렬화를 그대로 쓴다.
## 결정 2: 이름 인코딩 [DELEGATED]
