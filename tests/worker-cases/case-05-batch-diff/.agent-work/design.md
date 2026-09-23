# design.md
## 목표
`ClientService.update(long id, ClientUpdate update)` → 바뀐 필드의 ChangeLog 를 남기고 갱신 사본을 저장·반환.
## 계약
- 없는 id → NotFoundException, 이력 없음.
- 이력은 바뀐 필드만, `Client.fields()` 의 순서(name, phone, email)로 남는다. 각 이력의 before/after 는 이전·새 값이다.
- 반환 Client 가 저장된 인스턴스다(한 번 저장).
## 테스트 기준
- name·email 만 바뀐 갱신 → 이력 2건(name, email 순), 반환 name == "Lee", 저장 1회.
- 없는 id → NotFoundException, 이력 0건.
