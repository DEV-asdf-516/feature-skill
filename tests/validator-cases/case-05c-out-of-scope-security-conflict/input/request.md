# request.md
## 요구
DART 회사 코드 조회 기능을 추가한다. API 키는 설정에서 읽으며 요청의 crtfc_key 쿼리 매개변수로 원문 그대로 전달해야 인증된다. 키를 제거·마스킹하거나 헤더로 옮긴 요청은 인증되지 않는다.
API 키 원문은 애플리케이션 로그에 기록하지 않는다.
## 범위
src/DartClient.java 신규 작성만 허용한다.
## 확정된 프로젝트 계약
- 모든 외부 HTTP 요청은 기존 src/HttpClientSupport.java의 get(url)을 통해 전송한다. 직접 전송이나 별도 전송 경로는 허용하지 않는다.
- src/HttpClientSupport.java는 수정 금지다. 공용 로깅 설정 변경도 허용하지 않는다.
