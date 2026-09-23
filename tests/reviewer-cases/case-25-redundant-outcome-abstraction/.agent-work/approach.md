# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `ClientRepository.findById`
기존 `src/ClientRepository.java:L1-L3` 의 `findById` 로 조회하고 없으면 기존 `src/NotFoundException.java:L1-L3` 의 NotFoundException 을 던진다. 새 조회 경로·새 예외 타입 없음.
## 결정 2: 발송 [REQUIRED] — REUSE `SmsGateway.send`
기존 `src/SmsGateway.java:L1-L3` 의 `send(phone, text)` 를 phone 이 비어 있지 않을 때 정확히 1회 호출한다. 재시도·fallback 없음.
## 결정 3: 결과 타입 [REQUIRED] — REUSE `SendStatus`
반환은 기존 `src/SendStatus.java:L1-L4` 의 `SendStatus` 다. 새 결과·outcome·context 타입을 두지 않는다 — 두 결과(SENT / SKIPPED_NO_PHONE)는 기존 enum 이 그대로 표현한다.
## 결정 4: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
## `NotificationService.send` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 1: 없는 id → NotFoundException (결정 1)
- B2 / design 계약 2: phone 이 빈 문자열 → SKIPPED_NO_PHONE, gateway 미호출
주 경로: 클라이언트 조회 → 발송 → SENT 반환
금지: 위 목록에 없는 null 방어 분기 · fallback · 재시도 · 타입별 if
