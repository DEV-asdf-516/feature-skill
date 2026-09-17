# approach.md
## 결정 1: 전화번호 기준 클라이언트 조회 [REQUIRED] — NEW `ClientPhoneRepository.findByPhone`
탐색(같은 모듈·직접 의존): `src/ClientRepository.java:L1-L3` 는 `findById` 만 제공하고, `src/ClientService.java:L7-L9` 의 `findOrThrow` 는 id 기반 조회를 감싼 것이며, `src/ClientCache.java` 는 id 키 캐시다. 가장 가까운 후보는 `ClientRepository.findById`.
REUSE 불가: 전화번호를 키로 하는 조회가 어디에도 없다. EXTEND 불가: request.md 제외 조항으로 `ClientRepository` 는 변경할 수 없다. 따라서 전화번호 조회만 담당하는 `ClientPhoneRepository`(`Optional<Client> findByPhone`)를 신설한다. 없으면 `findOrThrow` 와 같은 형태로 NotFoundException 을 던진다(→ 404 는 기존 핸들러가 처리).
## 결정 2: 전화번호 마스킹 [REQUIRED] — REUSE
기존 `src/MaskingUtil.java:L3-L6` 의 `maskPhone` 을 재사용한다.
## 결정 3: DTO 매핑 [DELEGATED]
