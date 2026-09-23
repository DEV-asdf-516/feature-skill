# design.md
## 목표
`ClientService.exportLine(long id)` → `"<id>,<name>,<maskedPhone>"` (구분자 `,`, 공백 없음).
## 계약
- 없는 id → NotFoundException.
- maskedPhone 은 기존 MaskingUtil 규칙(가운데 4자리 `*`). 예: 1, Kim, 01012345678 → `1,Kim,010****5678`.
## 테스트 기준
- 존재하는 id → `1,Kim,010****5678`.
- 없는 id → NotFoundException.
