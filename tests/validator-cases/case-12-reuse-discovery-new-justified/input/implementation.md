# implementation.md
## 변경 파일
1. `src/ClientPhoneRepository.java` 신규 — `java.util.Optional<Client> findByPhone(String phone)`.
2. `src/ClientService.java` — `ClientSummary summaryByPhone(String phone)` 추가. 없으면 NotFoundException.
3. `src/ClientController.java` 신규 — `GET /clients/by-phone/{phone}/summary` 매핑 추가.
## 테스트
- 존재하는 전화번호 → 200, 세 필드 반환.
- 없는 전화번호 → 404.
## 완료 기준
위 두 테스트 통과.
