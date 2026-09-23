# approach.md
## 결정 1: 응답 판정 [REQUIRED] — REUSE `DartHttp.DartResponse`
`resolve(response)` 는 `response.status()` 가 `"000"` 과 같으면 `response.data().get(0).corpCode()` 를 반환하고, 아니면 `throw new DartLookupException(response.status())` 다. 기존 `src/DartHttp.java:L2-L3` 의 `DartResponse`/`Item` 역직렬화 타입을 그대로 쓴다. `lookup(name)` 은 ① 결정 2 의 인코딩 ② `DartHttp.search(encoded)` ③ `resolve(response)` 순서로 호출하고 `resolve` 의 반환값을 지역 변수 없이 그대로 반환한다 — 그 외 helper·분기 없음. `resolve` 를 분리하는 이유는 테스트 setup(`DartHttp.search` 가 static)뿐이다. 같은 모듈에 서비스 precedent 는 없다(`src/DartHttp.java:L1-L5` 뿐) — 여기서 정한다.
## 결정 2: 이름 인코딩 [REQUIRED]
`DartHttp.search` 는 이름을 URL 에 그대로 이어 붙이므로(`src/DartHttp.java:L4-L4`, 범위 밖이라 수정하지 않음) 서비스에서 `String encoded = URLEncoder.encode(name, StandardCharsets.UTF_8)` 로 인코딩한 값을 넘긴다. 표준 라이브러리 한 번 호출이며 별도 구조물 없음.
## 결정 3: 예외 타입 [REQUIRED] — NEW `DartLookupException`
탐색(같은 모듈·직접 의존): `src/DartHttp.java:L1-L5` 에 예외 타입이 없고 가장 가까운 후보도 없다 → REUSE/EXTEND 불가. `DartLookupService` 안에 중첩 `public static final class DartLookupException extends RuntimeException` 으로 선언하고 생성자 `DartLookupException(String status)` 는 `super(status)` 만 호출한다. 필드·추가 메서드 없음.
## 결정 4: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
