# design.md
## 외부 응답
DART 응답 JSON: `{ "status": "000", "message": "정상", "data": [...] }`
## 계약
- `status == "000"` 이면 data 의 첫 항목 corp_code 를 반환한다.
- `status != "000"` 이면 `DartLookupException` 을 던진다.
- message 필드는 판정에 쓰지 않는다(로그 용도 외 요구 없음).
