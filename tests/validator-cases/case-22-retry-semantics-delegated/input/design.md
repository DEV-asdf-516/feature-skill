# design.md
## 목표
`NotificationService.send(long id)` → `SendStatus` (SENT | SKIPPED_NO_PHONE | FAILED).
## 계약
- 없는 id → NotFoundException(기존 타입).
- Client.phone 이 빈 문자열이면 gateway 를 호출하지 않고 SKIPPED_NO_PHONE.
- `SmsGateway.send` 가 GatewayException 을 던지면 최종 결과는 FAILED 다. 실패 시 재시도 여부·횟수는 구현 문서가 정한다(외부 SMS 는 건당 과금).
- 그 외에는 SENT.
## 테스트 기준
- phone 이 있는 id → SENT.
- phone 이 빈 id → SKIPPED_NO_PHONE, gateway 호출 없음.
- gateway 가 던지면 → FAILED.
- 없는 id → NotFoundException.
