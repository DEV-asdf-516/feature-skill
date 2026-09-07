# design.md
## 목표
`GET /clients/{id}/summary` → `{id, name, maskedPhone}`.
## 계약
- 없는 id → 404.
- maskedPhone 은 전화번호 가운데 4자리를 `*` 로 가린 값.
## 비범위
- 캐시 계층 변경 없음.
