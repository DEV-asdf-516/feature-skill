# design.md
## 목표
`GET /clients/{id}/summary` → `{id, name, maskedPhone}`.
## 계약
- 없는 id → 404 (기존 NotFoundException 핸들러가 변환).
- maskedPhone 은 전화번호 가운데 4자리를 `*` 로 가린 값 (예: 01012345678 → 010****5678). Client.phone 은 항상 존재하며(DB NOT NULL) 저장 시 숫자 10~11자리로 검증된다(기존 계약).
- 응답은 위 세 필드뿐이다.
## 테스트 기준
- 존재하는 id → 세 필드 반환, maskedPhone 이 마스킹 규칙을 따른다.
- 없는 id → NotFoundException.
## 비범위
- 캐시 계층·MaskingUtil·기존 profile 조회 변경 없음.
