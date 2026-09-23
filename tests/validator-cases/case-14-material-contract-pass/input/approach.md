# approach.md
## 결정 1: 항목 선별의 책임 위치 [REQUIRED] — EXTEND `Classifier`
판정과 결과 목록 조립은 `Classifier` 가 담당한다: `Classifier.accepted(List<Item> items)` 를 추가하고(EXTEND — 같은 모듈에 목록 단위 판정은 없고 항목 판정은 `src/Classifier.java:L2-L4` 의 `accepts` 뿐이므로 그것을 항목마다 호출해 감싼다, 새 class 없음), `Batch.accepted` 는 items 를 그대로 `classifier.accepted(items)` 에 넘겨 그 반환값을 돌려준다 — Batch 에는 판정·조립 코드가 없다. 한 번 순회, 결과 순서 = items 순서.
## 결정 2: 빈 입력 [REQUIRED]
빈 items 는 위 순회에서 빈 결과로 성립한다. 별도 분기를 두지 않는다.
## 결정 3: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
