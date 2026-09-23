# design.md
## 목표
`NotificationService.send(long id)` → `SendStatus` (SENT | SKIPPED_NO_PHONE).
## 계약
- 없는 id → NotFoundException(기존 타입).
- Client.phone 이 빈 문자열이면 gateway 를 호출하지 않고 SKIPPED_NO_PHONE.
- 그 외에는 `SmsGateway.send(phone, "안내 메시지")` 를 정확히 1회 호출하고 SENT.
- phone 은 null 이 아니다(DB NOT NULL, 빈 문자열 허용 — 기존 계약).
## 테스트 기준
- phone 이 있는 id → SENT, gateway 1회 호출.
- phone 이 빈 id → SKIPPED_NO_PHONE, gateway 호출 없음.
- 없는 id → NotFoundException.
## 비범위
- 재시도·큐·발송 이력 저장 없음.
