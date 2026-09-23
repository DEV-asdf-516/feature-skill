# implementation.md
## 변경 파일
1. `src/ClientUpdateRequest.java` — 신설. 요청 바인딩용 DTO(name, phone). 기본 생성자 + getter/setter(프레임워크 바인딩 요구).
2. `src/ClientService.java` — `public Client update(long id, ClientUpdateRequest request)` 추가. 없는 id 면 NotFoundException, 검증 실패면 IllegalArgumentException("name" | "phone"), 통과하면 갱신된 Client 저장·반환.
3. `src/Client.java` — 갱신 사본을 만드는 메서드 추가(불변 유지, 기존 필드·접근자 변경 없음).
4. `src/test/ClientServiceTest.java` — 아래 테스트 추가.
## 테스트
- `update_savesUpdatedClient`: 유효 요청 → 반환 Client 의 name == "Lee", phone == "01099998888", repo.save 호출.
- `update_rejectsBlankName`: 공백 이름 → IllegalArgumentException, save 미호출.
- `update_rejectsNonDigitPhone`: "010-9999-8888" → IllegalArgumentException, save 미호출.
- `update_unknownId_throwsNotFound`: 없는 id → NotFoundException.
## 완료 기준
위 네 테스트 통과. 위 네 파일과 request.md 가 허용한 신설 타입 외 변경 없음.
