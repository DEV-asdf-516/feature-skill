# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L7-L9` 의 `findOrThrow` 를 호출한다(NotFoundException → 404 는 기존 핸들러가 처리). 탐색: 같은 모듈의 id 조회는 `src/ClientRepository.java:L1-L3` 의 `findById` 와 그것을 감싼 `findOrThrow` 뿐이다. 새 조회 경로·새 예외 타입·null 반환 없음.
## 결정 2: 전화번호 마스킹 [REQUIRED] — REUSE `MaskingUtil.maskPhone`
기존 `src/MaskingUtil.java:L3-L9` 의 `maskPhone` 으로 마스킹한다(가운데 4자리를 `*` 로). 마스킹 규칙을 서비스에 다시 쓰지 않는다.
## 결정 3: 응답 DTO `ClientSummary` [REQUIRED] — NEW
`src/ClientSummary.java` 신설, 불변 DTO `ClientSummary(long id, String name, String maskedPhone)` + 접근자. 기존 `src/ClientProfile.java:L1-L7` 과 같은 형태의 feature-local 응답 타입이다(요약 응답 계약에 직접 대응하며 기존 프로필 응답 계약을 바꾸지 않는다).
## 결정 4: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
## `ClientService.summary` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 1: 없는 id → NotFoundException (결정 1)
주 경로: 클라이언트 조회 → 마스킹 → ClientSummary 반환
금지: 위 목록에 없는 null·빈값 방어 분기 · fallback · 재시도 · 타입별 if
