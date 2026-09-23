# request.md
## 원문
클라이언트 요약 조회 `ClientService.summary(id)` 를 추가한다. 응답은 기존 `ClientSummary`(id, name, maskedPhone) 다. 마스킹은 기존 MaskingUtil 을 그대로 쓴다. 기존 프로필 조회(`profile`)와 같은 방식으로 작성한다.
## 범위
- `src/ClientService.java` 에 summary 조회 추가, `src/test/ClientServiceTest.java` 에 테스트 추가.
## 제외
- `src/ClientSummary.java`, `src/MaskingUtil.java`, 기존 `get`·`profile` 조회는 변경하지 않는다.
