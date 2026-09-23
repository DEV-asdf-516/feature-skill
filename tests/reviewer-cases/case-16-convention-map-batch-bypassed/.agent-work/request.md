# request.md
## 원문
클라이언트 수정 API 의 서비스 계층 `ClientService.update(id, ClientUpdate)` 를 추가한다. 이름·전화번호·이메일을 갱신하고, 실제로 값이 바뀐 필드마다 변경 이력(ChangeLog)을 남긴다. 변경 감지와 이력 기록은 기존 DiffUtil·ChangeLogWriter 를 그대로 쓴다.
## 범위
- `src/ClientService.java` 에 update 추가, `src/test/ClientServiceTest.java` 에 테스트 추가.
## 제외
- `src/DiffUtil.java`, `src/ChangeLogWriter.java`, `src/Client.java`, `src/ClientUpdate.java` 는 변경하지 않는다. 컨트롤러는 다음 작업이다.
