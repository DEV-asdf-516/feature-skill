# design.md
## 목표
`ClientService.summary(long id)` → `ClientSummary{id, name, maskedPhone}`.
## 계약
- 없는 id → NotFoundException(기존 타입).
- maskedPhone 은 전화번호 가운데 4자리를 `*` 로 가린 값(예: 01012345678 → 010****5678). phone 은 null 이 아니다(기존 계약).
- 응답 타입 `ClientSummary` 는 이 요약 응답 전용 값 객체다.
## 테스트 기준
- 존재하는 id → 세 필드 반환, maskedPhone == "010****5678".
- 없는 id → NotFoundException.
