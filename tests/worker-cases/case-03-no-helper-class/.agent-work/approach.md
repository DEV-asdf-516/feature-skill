# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L6-L8` 의 `findOrThrow` 를 호출한다. 탐색: 같은 모듈의 id 조회는 `findById` 와 `findOrThrow` 뿐이다.
## 결정 2: `tagLine` 의 책임 위치 [REQUIRED]
태그 순회·대문자화·`,` 연결은 `ClientService` 안에서 끝낸다. 새 helper class(포매터·유틸)·새 파일·shared helper 를 만들지 않는다. 탐색: 같은 모듈·직접 의존 코드에 태그 연결·대문자화 유틸이 없고, 이 요구는 한 메서드 범위라 NEW 구조물이 필요 없다.
## 결정 3: 테스트 [REQUIRED] — 참조 `src/test/ClientServiceTest.java:L15-L18`
`get_returnsClient` 와 같은 형태(static 메서드 + `repoWith` + `check`)로 세 테스트를 추가하고 `main` 에서 호출한다.
## 결정 4: 포맷·import 순서 [DELEGATED]
## `ClientService.tagLine` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 1: 없는 id → NotFoundException (결정 1)
- B2 / design 계약 2: 첫 태그 앞에는 구분자를 붙이지 않는다
주 경로: 클라이언트 조회 → 태그 연결 → 문자열 반환
금지: 위 목록에 없는 null·빈값 방어 분기 · fallback · 재시도 · 타입별 if
