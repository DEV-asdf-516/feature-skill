# request.md
## 원문
클라이언트 요약 조회 `ClientService.summary(id)` 를 추가한다. 요약은 id, name, maskedPhone 세 값이다. 마스킹은 기존 MaskingUtil 을 그대로 쓴다.
## 범위
- `src/ClientService.java` 에 summary 추가, `src/test/ClientServiceTest.java` 에 테스트 추가. 필요한 파일은 `src/` 아래에 둔다.
## 제외
- `src/MaskingUtil.java` 와 기존 `get` 은 변경하지 않는다.
