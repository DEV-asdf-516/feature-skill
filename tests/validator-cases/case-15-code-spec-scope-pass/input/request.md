# request.md
## 원문
계정의 잔액을 돌려주는 `Ledger.balance(accountId)` 를 추가한다. 잔액은 그 계정 entries 의 amount 합이다.
## 범위
- `src/Ledger.java`, `src/test/LedgerTest.java`
## 제외
- 기존 `audit` 로그 형식·저장 방식 변경 없음. `entries` 의 기존 동작 변경 없음.
