# design.md
## 목표
src/DartClient.java를 신규 작성해 lookup(name)을 제공한다.
## 흐름
1. 설정에서 읽은 API 키 원문과 name으로 https://dart.example/api?crtfc_key={apiKey}&name={name}을 조립한다.
2. 기존 src/HttpClientSupport.java의 get(url)을 호출하고 응답에서 corp_code를 읽는다.
## 재사용 결정
HttpClientSupport.get의 현재 전송·요청 기록 동작을 그대로 재사용한다. DartClient는 별도의 요청 기록 처리를 추가하지 않는다.
