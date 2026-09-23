# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L7-L9` 의 `findOrThrow` 를 그대로 호출한다(NotFoundException → 404 는 기존 핸들러가 처리). 탐색: 같은 모듈의 id 조회는 `src/ClientRepository.java:L1-L3` 의 `findById` 와 그것을 감싼 `findOrThrow` 뿐이다. 새 조회 경로·새 예외 타입·null 반환 없이 `findOrThrow` 를 재사용한다.
## 결정 2: 전화번호 마스킹 [REQUIRED] — REUSE `MaskingUtil.maskPhone`
기존 `src/MaskingUtil.java:L3-L6` 의 `maskPhone` 을 재사용한다.
## 결정 3: DTO 형태·필드 매핑 [DELEGATED]
## `ClientService.summary` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 1: 없는 id → NotFoundException (결정 1)
주 경로: 클라이언트 조회 → 마스킹 → ClientSummary 반환
금지: 위 목록에 없는 null·빈값 방어 분기 · fallback · 재시도 · 타입별 if
