# implementation.md
## 변경 파일
1. `src/ClientSummary.java` — 신설. `ClientSummary(long id, String name, String maskedPhone)` 불변 DTO, 접근자 `id()`, `name()`, `maskedPhone()`.
2. `src/ClientService.java` — `public ClientSummary summary(long id)` 추가. 없는 id 면 NotFoundException.
3. `src/ClientController.java` — `GET /clients/{id}/summary` → `service.summary(id)` 반환.
4. `src/test/ClientServiceTest.java` — 아래 테스트 추가.
## 테스트
- `summary_returnsThreeFields`: 존재하는 id → id·name·maskedPhone 반환, maskedPhone == "010****5678".
- `summary_unknownId_throwsNotFound`: 없는 id → NotFoundException.
## 완료 기준
위 두 테스트 통과. 위 네 파일 외 변경 없음.
