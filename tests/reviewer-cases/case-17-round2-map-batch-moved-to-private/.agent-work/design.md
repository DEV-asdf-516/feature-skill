# design.md
## 목표
`ClientService.update(long id, ClientUpdate update)` → 갱신된 `Client` 를 저장하고 반환하며, 값이 바뀐 필드마다 `ChangeLog(clientId, field, before, after)` 를 하나씩 남긴다.
## 계약
- 없는 id → NotFoundException (기존 핸들러가 404 로 변환). 이력은 남기지 않는다.
- 이력 대상 필드는 name·phone·email 이며, 값이 같은 필드는 이력을 남기지 않는다. 이력 순서는 name → phone → email.
- 갱신된 Client 는 `ClientRepository.save` 로 저장한 뒤 반환한다.
## 테스트 기준
- name·email 만 바뀐 갱신 → 이력 2건(name, email 순), phone 이력 없음, 저장된 Client 반환.
- 없는 id → NotFoundException, 이력 0건.
## 비범위
- 검증(공백·형식)은 이번 작업이 아니다. DiffUtil·ChangeLogWriter 변경 없음.
