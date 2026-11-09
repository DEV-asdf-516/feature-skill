# design.md
## 계약
- `ClientService.register(String name, String phone)` 는 phone 에서 숫자가 아닌 문자를 모두 제거한 값을 저장한다. 반환값(새 id)은 그대로다.
## 테스트 기준
- `register("a", "010-1234-5678")` → repository 에 `"01012345678"` 이 저장된다.
## 비범위
- 자릿수 검증·국가번호 처리 없음.
