# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L6-L8` 의 `findOrThrow` 를 그대로 호출한다. 탐색: 같은 모듈의 id 조회는 `src/ClientRepository.java:L1-L4` 의 `findById` 와 그것을 감싼 `findOrThrow` 뿐이다.
## 결정 2: 검증 규칙 [REQUIRED]
name: null 또는 `isBlank()` 면 `IllegalArgumentException("name")`. phone: null 이거나 정규식 `\d{10,11}` 에 맞지 않으면 `IllegalArgumentException("phone")`. name 검증이 먼저다. 검증 유틸은 같은 모듈에 없으므로(탐색: `src/` 전체에 검증 helper 없음) 표준 라이브러리로 직접 검사한다 — NEW helper 클래스를 만들지 않는다.
## 결정 3: 검증된 갱신 값을 Client 에 전달하는 형태 [DELEGATED]
전달 형태·타입명·내부 표현은 워커가 정한다. 전용 타입이 필요하면 NEW 허용: 같은 모듈에 갱신 값 전용 타입이 없고(확인: `src/Client.java`, `src/ClientRepository.java`) 가장 가까운 후보는 이번에 신설하는 `ClientUpdateRequest` 뿐이다.
## 결정 4: 갱신 사본 생성 [REQUIRED] — EXTEND `Client`
`Client` 에 갱신 사본을 반환하는 메서드를 추가한다(새 Client 인스턴스 반환, setter 금지). 메서드 이름·인자 타입은 결정 3 을 따른다.
## `ClientService.update` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 1: 없는 id → NotFoundException (결정 1)
- B2 / design 계약 2: name 검증 실패 → IllegalArgumentException("name") (결정 2)
- B3 / design 계약 2: phone 검증 실패 → IllegalArgumentException("phone") (결정 2)
주 경로: 클라이언트 조회 → 검증 → 갱신 사본 생성 → 저장 → 반환
금지: 위 목록에 없는 null·빈값 방어 분기 · fallback · 재시도 · 타입별 if
