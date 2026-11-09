# implementation.md
## 변경 파일
1. `src/PhoneFormatter.java` 신규 — `public static String digitsOnly(String phone)`: 숫자가 아닌 문자를 모두 제거한 문자열.
2. `src/ClientService.java` — `register` 가 `PhoneFormatter.digitsOnly(phone)` 의 결과를 `repo.insert` 에 넘긴다.
3. `src/test/ClientRegisterTest.java` 신규 — 아래 테스트.
## 테스트
- `register_storesDigitsOnly`: `register("a", "010-1234-5678")` → `insert` 에 `"01012345678"` 이 전달된다.
## 테스트 setup
`ClientRepository` 를 테스트 안에서 `insert` 인자를 기록하는 구현으로 대체해 `ClientService` 를 직접 생성한다. 테스트 내부 helper·지역 구조는 정하지 않는다.
## 완료 기준
위 테스트 통과. 변경 파일 목록 외 변경 없음.
