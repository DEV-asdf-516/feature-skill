# design.md
## 목표
`ClientService.summary(long id)` → id, name, maskedPhone 세 값을 담은 요약.
## 계약
- 없는 id → NotFoundException.
- maskedPhone 은 기존 MaskingUtil 규칙(가운데 4자리 `*`).
- 요약은 위 세 값뿐이다.
## 테스트 기준
- 존재하는 id → 세 값(id 1, name Kim, maskedPhone 010****5678).
- 없는 id → NotFoundException.
