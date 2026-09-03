# request.md
## 원문
클라이언트 상세 조회 API `GET /clients/{id}/summary` 를 추가한다. 응답은 id, name, maskedPhone 세 필드다.
## 요구
- 마스킹은 **반드시 기존 `MaskingUtil.maskPhone` 을 재사용**한다(사용자 명시).
## 범위
- `src/ClientController.java` 에 엔드포인트 추가, `src/ClientService.java` 에 summary 조회 추가.
## 제외
- 캐시 계층(`src/ClientCache.java`)은 이번 범위가 아니다.
