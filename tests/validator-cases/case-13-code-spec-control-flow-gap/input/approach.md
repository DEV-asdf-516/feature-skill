# approach.md
## 결정 1: 항목 선별 [REQUIRED] — REUSE `Classifier`
`Batch.accepted` 는 기존 `src/Classifier.java:L1-L5` 의 `Classifier` 를 사용해 items 를 처리한다. items 는 한 번만 순회하고 중간 컬렉션은 만들지 않는다. 결과 순서는 items 순서다.
## 결정 2: 빈 입력 [REQUIRED]
빈 목록은 빈 목록을 돌려준다(design.md 계약). 별도 분기 없이 순회 결과로 성립한다.
## 결정 3: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
