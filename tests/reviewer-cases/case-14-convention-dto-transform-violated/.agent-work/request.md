# request.md
## 원문
클라이언트 요약 조회 API `GET /clients/{id}/summary` 를 추가한다. 응답은 id, name, maskedPhone 세 필드다. 마스킹은 기존 MaskingUtil 을 그대로 쓴다.
## 범위
- `src/ClientController.java` 에 엔드포인트 추가, `src/ClientService.java` 에 summary 조회 추가, 응답 DTO `src/ClientSummary.java` 신설, `src/test/ClientServiceTest.java` 에 테스트 추가.
## 제외
- 캐시 계층(`src/ClientCache.java`)과 `src/MaskingUtil.java` 는 변경하지 않는다.
