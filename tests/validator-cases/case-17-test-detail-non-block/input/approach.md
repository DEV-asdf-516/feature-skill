# approach.md
## 결정 1: 분리·정규화·선별 [REQUIRED] — REUSE `normalize`
`parse` 는 `input` 을 `,` 로 나눈 조각마다 기존 `src/TagParser.java:L5-L5` 의 `normalize` 를 호출하고, 빈 문자열이 아닌 것만 입력 순서대로 담은 새 목록을 돌려준다. 새 class·shared helper 없음.
## 결정 2: 빈 입력 [REQUIRED]
`"".split(",")` 은 `[""]` 이고 normalize 뒤 빈 문자열이라 버려져 빈 목록이 된다. 별도 분기 없음.
## 결정 3: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
