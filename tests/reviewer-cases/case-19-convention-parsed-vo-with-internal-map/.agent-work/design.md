# design.md
## 목표
`ClientService.update(long id, ClientUpdateRequest request)` → 검증을 통과한 name·phone 으로 갱신된 `Client` 를 저장하고 반환한다.
## 계약
- 없는 id → NotFoundException (기존 핸들러가 404 로 변환).
- name 이 null 또는 공백 → IllegalArgumentException("name"), phone 이 null 이거나 숫자 10~11자리가 아니면 → IllegalArgumentException("phone"). 검증 실패 시 저장하지 않는다.
- 갱신된 Client 는 `ClientRepository.save` 로 저장한 뒤 반환한다.
## 테스트 기준
- 유효 요청 → name·phone 이 바뀐 Client 저장·반환.
- 공백 이름 / 형식이 틀린 전화번호 → IllegalArgumentException, 저장 없음.
- 없는 id → NotFoundException.
## 비범위
- 컨트롤러 바인딩·에러 응답 형식은 다음 작업.
