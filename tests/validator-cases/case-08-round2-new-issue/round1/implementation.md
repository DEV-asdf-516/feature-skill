# implementation.md
## 변경 파일
1. `src/ClientService.java` — `ClientSummary summary(long id)` 추가.
2. `src/ClientController.java` — `GET /clients/{id}/summary` 매핑 추가.
## 테스트
- 존재하는 id → 200, id·name 반환.
- 없는 id → 404.
## 완료 기준
위 두 테스트 통과.
