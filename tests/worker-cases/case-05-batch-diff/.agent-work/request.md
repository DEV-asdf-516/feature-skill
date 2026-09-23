# request.md
## 원문
클라이언트 갱신 `ClientService.update(id, update)` 를 추가한다. 바뀐 필드만 변경 이력(ChangeLog)으로 남기고 갱신된 Client 를 저장·반환한다. 변경 감지와 이력 기록은 기존 `DiffUtil`·`ChangeLogWriter` 를 그대로 쓴다.
## 범위
- `src/ClientService.java` 에 update 추가, `src/test/ClientServiceTest.java` 에 테스트 추가.
## 제외
- `DiffUtil`·`ChangeLogWriter`·`Client`·`ClientUpdate` 는 변경하지 않는다.
