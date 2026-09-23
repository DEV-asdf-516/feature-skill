# implementation.md
## 변경 파일
1. `src/DartLookupService.java` 신규 — `public static String lookup(String name)`, package-private `static String resolve(DartHttp.DartResponse response)`, 중첩 `public static final class DartLookupException extends RuntimeException`(생성자 `DartLookupException(String status)`).
2. `src/test/DartLookupServiceTest.java` 신규 — 아래 테스트.
## 테스트
- status "000" + data 1건 → corp_code 반환.
- status "013" → DartLookupException.
## 테스트 setup
`DartHttp.search` 는 static 이라 대체하지 않는다. 테스트는 `new DartHttp.DartResponse(status, message, data)` 를 직접 만들어 `resolve` 를 호출하고 반환값·예외만 검증한다. `lookup` 의 HTTP 호출 자체는 테스트하지 않는다. 테스트 내부 helper·지역 구조는 정하지 않는다.
