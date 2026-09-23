# design.md
## 목표
`ClientService.summary(long id)` → `ClientSummary{id, name, maskedPhone}`.
## 계약
- 없는 id → NotFoundException.
- maskedPhone 은 전화번호 가운데 4자리를 `*` 로 가린 값 (예: 01012345678 → 010****5678). Client.phone 은 항상 존재한다(기존 계약).
## 테스트 기준
- 존재하는 id → 세 필드 반환, maskedPhone == "010****5678".
- 없는 id → NotFoundException.
## 비범위
- `ClientSummary`·`MaskingUtil`·기존 `profile` 변경 없음.
