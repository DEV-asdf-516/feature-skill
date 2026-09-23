# implementation.md
## 변경 파일
1. `src/ClientService.java` — `public Client update(long id, ClientUpdate update)` 추가. 없는 id 면 NotFoundException. 바뀐 필드의 ChangeLog 를 남기고 갱신된 Client 를 저장·반환.
2. `src/test/ClientServiceTest.java` — 아래 테스트 추가.
## 테스트
- `update_logsChangedFieldsOnly`: name·email 만 바뀐 갱신 → 저장된 로그 2건(name, email 순, before/after 값 일치), 반환 Client 의 name == "Lee", repo.save 호출.
- `update_unknownId_throwsNotFound`: 없는 id → NotFoundException, 로그 0건.
## 완료 기준
위 두 테스트 통과. 위 두 파일 외 변경 없음.
