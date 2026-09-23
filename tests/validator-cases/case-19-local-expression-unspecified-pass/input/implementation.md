# implementation.md
## 변경 파일
1. `src/ClientSummary.java` 신규 — `public record ClientSummary(long id, String name, String maskedPhone)`.
2. `src/ClientService.java` — `public ClientSummary summary(long id)` 추가. 없는 id → NotFoundException. 기존 `get`·`findOrThrow` 는 그대로.
3. `src/test/ClientServiceTest.java` 신규 — 아래 테스트.
## 테스트
- `summary_returnsThreeFields`: id 1, Kim, 01012345678 → (1, "Kim", "010****5678").
- `summary_unknownId_throwsNotFound`: 없는 id → NotFoundException.
## 테스트 setup
`ClientRepository` 는 테스트 안에서 고정 `Client` / `Optional.empty()` 를 돌려주는 stub 으로 두고 `ClientService` 를 직접 호출한다.
## 완료 기준
위 두 테스트 통과. 위 세 파일 외 변경 없음.
