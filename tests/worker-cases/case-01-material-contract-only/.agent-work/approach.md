# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L6-L8` 의 `findOrThrow` 를 호출한다. 탐색: 같은 모듈의 id 조회는 `src/ClientRepository.java:L1-L3` 의 `findById` 와 그것을 감싼 `findOrThrow` 뿐이다. 새 조회 경로·새 예외 타입·null 반환 없음.
## 결정 2: 전화번호 마스킹 [REQUIRED] — REUSE `MaskingUtil.maskPhone`
기존 `src/MaskingUtil.java:L3-L6` 의 `maskPhone` 으로 마스킹한다. 마스킹 규칙을 서비스에 다시 쓰지 않는다.
## 결정 3: 응답 DTO [REQUIRED] — REUSE `ClientSummary`
`src/ClientSummary.java:L1-L9` 를 그대로 쓴다(필드·생성자 변경 없음). 새 DTO·record·builder·converter 없음. 매핑은 `summary` 안에서 한다.
## 결정 4: 테스트 [REQUIRED] — 참조 `src/test/ClientServiceTest.java:L26-L30`
`profile_returnsIdAndName` 과 같은 형태(static 메서드 + `repoWith` + `check`)로 두 테스트를 추가하고 `main` 에서 호출한다.
## 결정 5: 포맷·import 순서 [DELEGATED]
formatter 가 정한다.
## `ClientService.summary` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 1: 없는 id → NotFoundException (결정 1)
주 경로: 클라이언트 조회 → 마스킹 → ClientSummary 반환
금지: 위 목록에 없는 null·빈값 방어 분기 · fallback · 재시도 · 타입별 if
