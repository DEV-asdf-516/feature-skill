# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L6-L8` 의 `findOrThrow` 를 호출한다. 탐색: 같은 모듈의 id 조회는 `src/ClientRepository.java:L1-L3` 의 `findById` 와 그것을 감싼 `findOrThrow` 뿐이다.
## 결정 2: 전화번호 마스킹 [REQUIRED] — REUSE `MaskingUtil.maskPhone`
기존 `src/MaskingUtil.java:L3-L6` 의 `maskPhone` 을 호출한다. 마스킹 규칙(substring·`****`·길이 검사)을 `ClientService` 에 다시 쓰지 않는다 — 마스킹의 의미는 `MaskingUtil` 이 소유한다. 탐색: 마스킹 유틸은 같은 모듈에 `MaskingUtil` 하나뿐이다.
## 결정 3: `exportLine` 의 책임 [REQUIRED]
`exportLine` 은 조회 결과로 `id,name,maskedPhone` 형식의 csv 한 줄을 만들어 돌려준다. 새 포매터 class·shared helper 없음(한 메서드 범위 요구).
## 결정 4: 테스트 [REQUIRED] — 참조 `src/test/ClientServiceTest.java:L15-L18`
`get_returnsClient` 와 같은 형태(static 메서드 + `repoWith` + `check`)로 두 테스트를 추가하고 `main` 에서 호출한다.
## 결정 5: 포맷·import 순서 [DELEGATED]
## `ClientService.exportLine` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 1: 없는 id → NotFoundException (결정 1)
주 경로: 클라이언트 조회 → csv 한 줄 반환(마스킹 호출 포함)
금지: 위 목록에 없는 null·빈값 방어 분기 · fallback · 재시도 · 타입별 if
