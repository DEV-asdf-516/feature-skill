# design.md
## 계약
- `Ledger.balance(long accountId)` 는 `entries(accountId)` 가 돌려주는 항목들의 `amount` 합을 long 으로 돌려준다.
- 계정이 없거나 entries 가 비어 있으면 0 (`entries` 가 빈 목록을 돌려주는 기존 동작에 의존).
- `balance` 는 `audit` 를 호출하지 않는다(비범위).
## 테스트 기준
- amount [10, -3, 5] → 12.
- 없는 계정 → 0.
## 비범위
- 정렬·통화 변환·오버플로 처리 없음. audit 로그 형식은 기존 그대로.
