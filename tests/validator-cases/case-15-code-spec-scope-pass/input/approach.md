# approach.md
## 결정 1: 합산 [REQUIRED] — REUSE `entries`
`balance` 는 `entries(accountId)` 를 한 번 호출해 그 반환값을 for-each 로 한 번 순회하며 지역 변수 `long total` 에 `entry.amount()` 를 누적하고 `total` 을 반환한다. stream·helper·중간 컬렉션 없음(같은 모듈에 합산 precedent 가 없어 여기서 정한다):
```
long total = 0;
for (Entry entry : entries(accountId)) {
    total += entry.amount();
}
return total;
```
## 결정 2: 빈 계정 [REQUIRED]
`entries` 가 빈 목록을 돌려주는 기존 동작(`src/Ledger.java:L8-L8`)에 의존해 위 순회에서 0 이 된다. 별도 분기 없음.
## 결정 3: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
