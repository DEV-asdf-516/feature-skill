# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L7-L9` 의 `findOrThrow` 를 그대로 호출한다. 탐색: 같은 모듈의 id 조회는 `src/ClientRepository.java:L1-L4` 의 `findById` 와 그것을 감싼 `findOrThrow` 뿐이다.
## 결정 2: 변경 감지·이력 기록 [REQUIRED] — REUSE `DiffUtil.diff` + `ChangeLogWriter.writeAll`
변경 감지는 `src/Client.java:L11-L15` 의 `fields()` 와 `src/ClientUpdate.java:L9-L13` 의 `fields()` 로 만든 필드 Map 두 개를 `src/DiffUtil.java:L3-L10` 의 `diff` 에 넘겨 `Map<String, FieldChange>` 를 얻고, 그 Map 을 `src/ChangeLogWriter.java:L7-L11` 의 `writeAll` 에 **한 번에** 넘긴다. 필드별로 값을 비교하거나(`equals`/`!=` 나열), 개별 `FieldChange`·`ChangeLog` 를 만들거나, `write(...)` 를 필드마다 부르거나, 변경 목록을 따로 모아 합치는 코드를 서비스에 두지 않는다(컨벤션 규칙 3 의 Map 기반 일괄 처리). 탐색: 같은 모듈에서 변경 감지는 `DiffUtil.diff`, 이력 기록은 `ChangeLogWriter` 뿐이다.
## 결정 3: 갱신 사본 [REQUIRED] — REUSE `Client.apply`
`src/Client.java:L16-L18` 의 `apply(ClientUpdate)` 로 갱신 사본을 만들고 `ClientRepository.save` 에 넘긴 뒤 그 사본을 반환한다.
## 결정 4: `update` 의 상태 변경 순서 [REQUIRED]
조회 → 변경 Map 계산(`DiffUtil.diff`) → 이력 일괄 기록(`changeLogs.writeAll` 1회) → 갱신 사본(`before.apply(update)`) → `repo.save` → 사본 반환. 이력 기록은 저장 전에 한 번, 저장은 한 번이다. 새 helper class·수집 구조물 없음.
## 결정 5: 테스트 [REQUIRED] — 참조 `src/test/ClientServiceTest.java:L10-L14` 복제
`get_returnsClient` 와 같은 형태(`logs` 목록 + `InMemoryClientRepository` + `check`)로 두 테스트를 추가하고 `main` 에서 호출한다.
## 결정 6: 포맷·import 순서 [DELEGATED]
## `ClientService.update` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 1: 없는 id → NotFoundException (결정 1)
주 경로: 클라이언트 조회 → 변경 Map 계산 → 이력 일괄 기록 → 갱신 사본 저장 → 반환
금지: 위 목록에 없는 null·빈값 방어 분기 · fallback · 재시도 · 타입별 if · 필드별 if
