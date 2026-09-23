# implementation.md
## 변경 파일
1. `src/Ledger.java` — `public long balance(long accountId)` 추가. 기존 `entries`(`src/Ledger.java:L8-L8`)·`audit`(`src/Ledger.java:L9-L9`)·`auditLog`(`src/Ledger.java:L10-L10`)는 그대로 둔다.
2. `src/test/LedgerTest.java` 신규 — 아래 테스트.
## 테스트
- `balance_sumsAmounts`: 계정 1 에 amount [10, -3, 5] → 12.
- `balance_unknownAccount_returnsZero`: entries 없는 계정 → 0.
## 테스트 setup
`new Ledger(Map.of(1L, List.of(...)))` 로 고정 entries 를 주입한다. 테스트 내부 helper·지역 구조는 정하지 않는다.
## 완료 기준
위 두 테스트 통과. 위 두 파일 외 변경 없음.
