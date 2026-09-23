# implementation.md
## 변경 파일
1. `src/ClientPhoneRepository.java` 신규 — `java.util.Optional<Client> findByPhone(String phone)`.
2. `src/ClientSummary.java` 신규 — `public record ClientSummary(long id, String name, String maskedPhone)`.
3. `src/ClientService.java` — `public ClientSummary summaryByPhone(String phone)` 추가. 없으면 NotFoundException.
4. `src/ClientController.java` 신규 — `GET /clients/by-phone/{phone}/summary` 매핑 `summaryByPhone(String phone)` 추가, `ClientService.summaryByPhone` 반환값을 그대로 반환.
5. `src/test/ClientSummaryTest.java` 신규 — 아래 테스트.
## 테스트
- 존재하는 전화번호 → 200, 세 필드 반환.
- 없는 전화번호 → 404.
## 테스트 setup
`src/test/ClientSummaryTest.java` 신규. `ClientPhoneRepository` 는 테스트 안에서 고정 `Client` 를 돌려주는 stub(존재 전화번호) / `Optional.empty()`(없는 전화번호) 로 두고, `ClientController` 를 직접 생성해 `summaryByPhone(phone)` 를 호출한다. HTTP 상태는 기존 계층의 NotFoundException→404 매핑에 맡기므로 테스트는 반환된 `ClientSummary` 필드값과 예외 발생만 본다. 테스트 내부 helper·지역 구조는 정하지 않는다.
## 완료 기준
위 두 테스트 통과.
