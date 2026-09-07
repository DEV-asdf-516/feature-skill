# request.md
## 원문
클라이언트 상세 조회 API `GET /clients/{id}/summary` 를 추가한다. 응답은 id, name, maskedPhone 세 필드다.
## 범위
- `src/ClientController.java` 신규 작성으로 엔드포인트 추가, `src/ClientService.java` 에 summary 조회 추가.
## 제외
- 캐시 계층(`src/ClientCache.java`)은 이번 범위가 아니다.

## 기존 데이터·HTTP 계약
전화번호는 null이 아닌 11자리 숫자 문자열이다. 기존 HTTP 계층은 NotFoundException을 404로 변환하며, 신규 컨트롤러도 이 매핑을 사용한다.
