# approach.md
## 결정 1: 합산 [REQUIRED] — REUSE `entries`
`balance` 는 `entries(accountId)`(`src/Ledger.java:L8-L8`)를 한 번 호출해 그 항목들의 `amount` 를 합산해 돌려준다. 새 class·shared helper·별도 상태 구조 없음.
## 결정 2: 빈 계정 [REQUIRED]
`entries` 가 빈 목록을 돌려주는 기존 동작(`src/Ledger.java:L8-L8`)에 의존해 0 이 된다. 별도 분기 없음.
## 결정 3: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
