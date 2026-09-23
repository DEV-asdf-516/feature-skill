# request.md
## 원문
클라이언트 요약 조회 `ClientService.summary(id)` 를 추가한다. 응답은 기존 `ClientSummary`(id, name, maskedPhone) 다. 마스킹은 기존 MaskingUtil 을 그대로 쓴다.
## 범위
- `src/ClientService.java` 에 summary 추가, `src/test/ClientServiceTest.java` 신설.
## 제외
- `src/ClientSummary.java`, `src/MaskingUtil.java`, `src/ClientRepository.java` 는 변경하지 않는다.
