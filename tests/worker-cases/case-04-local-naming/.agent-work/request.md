# request.md
## 원문
클라이언트 이름 변경 `ClientService.rename(id, newName)` 을 추가한다. 기존 전화번호 변경(`changePhone`)과 같은 방식으로 작성한다.
## 범위
- `src/ClientService.java` 에 rename 추가, `src/test/ClientServiceTest.java` 에 테스트 추가.
## 제외
- `Client`·`ClientRepository`·기존 `changePhone` 은 변경하지 않는다.
