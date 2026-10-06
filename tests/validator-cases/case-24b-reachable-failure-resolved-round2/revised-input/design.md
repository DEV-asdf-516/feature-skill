# design.md
## 목표
src/DartClient.java를 신규 작성해 lookup(name)을 제공한다.
## 흐름
1. 설정에서 읽은 API 키 원문과 name으로 https://dart.example/api?crtfc_key={apiKey}&name={name}을 조립한다.
2. 기존 src/HttpClientSupport.java의 get(url)을 호출하고 응답에서 corp_code를 읽는다.
## 재사용 결정
HttpClientSupport.get의 전송 동작은 그대로 재사용한다. 요청 기록은 이번 변경에서 수정한다: src/HttpClientSupport.java의 get은 URL에서 쿼리 문자열을 제외한 scheme·host·path만 기록하며, crtfc_key를 포함한 쿼리 매개변수는 어떤 로그에도 남기지 않는다. 전송되는 URL은 바꾸지 않는다. DartClient는 별도의 요청 기록 처리를 추가하지 않는다.
