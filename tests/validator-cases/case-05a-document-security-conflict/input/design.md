# design.md
## 목표
DartClient.lookup(name)이 https://dart.example/api?crtfc_key={apiKey}&name={name}을 호출해 corp_code를 반환한다.
## 로깅
조회할 때마다 apiKey 원문을 포함한 완성된 요청 URL 전체를 INFO 로그에 기록한다.
