# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L6-L8` 의 `findOrThrow` 를 호출한다.
## 결정 2: 갱신 사본 [REQUIRED] — REUSE `Client.withName`
`src/Client.java:L9` 의 `withName(String)` 으로 이름이 바뀐 사본을 만든다. 새 생성자 호출·setter·builder 없음.
## 결정 3: `rename` 의 상태 변경 순서 [REQUIRED] — 참조 `src/ClientService.java:L10-L15`
기존 `changePhone` 과 같은 흐름이다: 조회 → 사본 생성 → `repo.save` 정확히 1회 → 저장한 사본 반환(반환 인스턴스 == 저장 인스턴스). 저장 전에 반환하거나 두 번 저장하지 않는다.
## 결정 4: 테스트 [REQUIRED] — 참조 `src/test/ClientServiceTest.java:L21-L27`
`changePhone_savesAndReturnsChanged` 와 같은 형태로 두 테스트를 추가하고 `main` 에서 호출한다.
## 결정 5: 포맷·import 순서 [DELEGATED]
## `ClientService.rename` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 1: 없는 id → NotFoundException (결정 1)
주 경로: 클라이언트 조회 → 갱신 사본 → 저장 → 사본 반환
금지: 위 목록에 없는 null·빈값 방어 분기 · fallback · 재시도 · 타입별 if
