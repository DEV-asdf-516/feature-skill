# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L7-L9` 의 `findOrThrow` 를 그대로 호출한다.
## 결정 2: 프로필 변환 [REQUIRED] — 참조 `src/ClientService.java:L11-L14` 와 같은 생성자 호출
`profile` 과 같이 `new ClientProfile(client.id(), client.name())` 을 직접 쓴다. 기존 `profile(id)` 를 호출해 재사용하지 않는다(참조는 구조이지 호출 대상이 아니다 — `profile` 은 발행 없는 조회 API 로 그대로 둔다).
## 결정 3: 발행 [REQUIRED] — REUSE `ProfilePublisher.publish`
필드 `publisher` 의 `publish(profile)` 을 정확히 1회 호출한다. 탐색: 발행 경로는 `src/ProfilePublisher.java:L1-L3` 하나뿐이다.
## 결정 4: `publishProfile` 의 순서 [REQUIRED]
lookup → transform → publish → return 이다. 문서에 없는 분기(null 검사·조건부 발행)·fallback(발행 실패 시 대체 동작)·try/catch·재시도·발행 전후 로깅을 추가하지 않는다. 순서를 바꾸지 않는다(발행 전에 반환하거나, 변환 전에 발행할 수 없다).
## 결정 5: 테스트 [REQUIRED] — 참조 `src/test/ClientServiceTest.java:L30-L34` 복제
`profile_returnsIdAndName` 과 같은 형태로 두 테스트를 추가하고 `main` 에서 호출한다. publisher 는 기존 `RecordingPublisher` 를 쓴다.
## 결정 6: 포맷·import 순서 [DELEGATED]
## `ClientService.publishProfile` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 1: 없는 id → NotFoundException (결정 1)
주 경로: 클라이언트 조회 → ClientProfile 생성 → 발행 → 반환
금지: 위 목록에 없는 null·빈값 방어 분기 · fallback · 재시도 · try/catch · 타입별 if
