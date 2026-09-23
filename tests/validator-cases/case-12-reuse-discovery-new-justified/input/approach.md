# approach.md
## 결정 1: 전화번호 기준 클라이언트 조회 [REQUIRED] — NEW `ClientPhoneRepository.findByPhone`
탐색(같은 모듈·직접 의존): `src/ClientRepository.java:L1-L3` 는 `findById` 만 제공하고, `src/ClientService.java:L7-L9` 의 `findOrThrow` 는 id 기반 조회를 감싼 것이며, `src/ClientCache.java` 는 id 키 캐시다. 가장 가까운 후보는 `ClientRepository.findById`.
REUSE 불가: 전화번호를 키로 하는 조회가 어디에도 없다. EXTEND 불가: request.md 제외 조항으로 `ClientRepository` 는 변경할 수 없다. 따라서 전화번호 조회만 담당하는 `ClientPhoneRepository`(`Optional<Client> findByPhone`)를 신설한다. `ClientService` 는 `private final ClientPhoneRepository phoneRepo` 를 생성자 주입으로 받고 `summaryByPhone` 안에서 `phoneRepo.findByPhone(phone).orElseThrow(() -> new NotFoundException("client " + phone))` 의 결과를 `client` 에 둔다(`findOrThrow` 와 같은 형태, 별도 helper 없음 → 404 는 기존 핸들러가 처리).
## 결정 2: 전화번호 마스킹 [REQUIRED] — REUSE `MaskingUtil.maskPhone`
기존 `src/MaskingUtil.java:L3-L6` 의 `MaskingUtil.maskPhone(client.phone())` 을 그대로 호출한다.
## 결정 3: DTO 매핑 [REQUIRED] — NEW `ClientSummary`
탐색(같은 모듈·직접 의존): 요약 응답 타입이 없다. `src/ClientService.java:L1-L10` 과 `src/Client.java:L1-L1` 은 엔티티 `Client(id, name, phone)` 만 다룬다. 가장 가까운 후보는 `Client` 인데 응답 계약(`maskedPhone`)과 필드가 다르고 엔티티를 그대로 노출하지 않으므로 REUSE/EXTEND 불가 → `src/ClientSummary.java` 에 `public record ClientSummary(long id, String name, String maskedPhone) {}` 를 신설한다.
매핑은 `ClientService.summary` 안에서 생성자 직접 호출로 끝낸다 — 별도 converter/factory/helper 없음, 지역 변수는 조회 결과 `client` 하나:
```
Client client = <결정 1 의 조회>
return new ClientSummary(client.id(), client.name(), <결정 2 의 마스킹>(client.phone()));
```
## 결정 4: 컨트롤러 [REQUIRED] — NEW `ClientController`
탐색(같은 모듈·직접 의존): HTTP 진입점이 없다. `src/ClientService.java:L1-L10`·`src/ClientRepository.java:L1-L3`·`src/ClientCache.java:L1-L6`·`src/Client.java:L1-L1`·`src/MaskingUtil.java:L1-L7` 어디에도 컨트롤러·라우팅 symbol 이 없다. 가장 가까운 후보는 `Client` 진입점인 `ClientService` 인데 서비스 계층이라 HTTP 매핑을 소유하지 않고 request.md 가 `src/ClientController.java` 신규 작성을 범위로 지정했으므로 REUSE/EXTEND 불가 → 신설한다(같은 모듈에 컨트롤러 precedent 없음 — 여기서 정한다). `ClientService` 를 생성자 주입으로 받는 `private final ClientService service` 필드 하나. `GET /clients/by-phone/{phone}/summary` 핸들러 `public ClientSummary summaryByPhone(String phone)` 는 `service.summaryByPhone(phone)` 의 반환값을 지역 변수 없이 그대로 반환한다 — 응답 wrapper(ResponseEntity 등)·try/catch·상태 코드 설정 없음. NotFoundException → 404 는 기존 HTTP 계층 매핑(request.md)에 맡긴다.
## 결정 5: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
