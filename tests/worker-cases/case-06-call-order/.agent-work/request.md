# request.md
## 원문
프로필 발행 `ClientService.publishProfile(id)` 를 추가한다. 프로필을 만들어 기존 `ProfilePublisher` 로 발행하고 그 프로필을 반환한다.
## 범위
- `src/ClientService.java` 에 publishProfile 추가, `src/test/ClientServiceTest.java` 에 테스트 추가.
## 제외
- `ProfilePublisher`·`ClientProfile`·기존 `profile` 은 변경하지 않는다.
