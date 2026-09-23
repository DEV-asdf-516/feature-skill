# request.md
## 원문
클라이언트 수정 서비스 `ClientService.update(id, 요청)` 를 추가한다. 요청은 name·phone 두 값이며 이름 공백과 전화번호 형식(숫자 10~11자리)을 검증한 뒤 갱신해 저장한다. 요청 DTO 는 이번에 신설한다.
## 범위
- `src/ClientUpdateRequest.java` 신설(요청 바인딩용 DTO), `src/ClientService.java` 에 update 추가, `src/Client.java` 에 갱신 사본 생성 추가, `src/test/ClientServiceTest.java` 에 테스트 추가. 갱신 값 전달에 필요한 타입이 더 있으면 `src/` 에 신설 가능.
## 제외
- 컨트롤러·저장소 변경 없음.
