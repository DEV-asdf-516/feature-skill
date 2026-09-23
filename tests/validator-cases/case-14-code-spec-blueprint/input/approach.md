# approach.md
## 결정 1: 항목 선별의 책임 위치 [REQUIRED] — EXTEND `Classifier`
`Batch.accepted` 는 items 를 그대로 `classifier.accepted(items)` 에 전달하고 반환 collection 만 소비한다 — Batch 에는 판정·조립 코드가 없고, 지역 변수 없이 호출 결과를 직접 반환한다.
`Classifier.accepted(List<Item> items)` 는 `Classifier` 에 메서드를 추가하는 EXTEND 다. 탐색: 같은 모듈에 목록 단위 판정은 없고 항목 판정은 `src/Classifier.java:L2-L4` 의 `accepts` 뿐이므로 그것을 감싼다(새 class/helper 없음). 각 item 의 판정과 결과 collection 조립을 이 메서드가 완료한다:
```
result = 새 ArrayList<Item>
for each item in items:
    if accepts(item): result.add(item)
return result
```
한 번 순회, 중간 컬렉션 없음, 결과 순서 = items 순서. 결과 변수 이름은 `result`, 순회는 for-each 다(같은 모듈에 precedent 가 없어 여기서 정한다).
## 결정 2: 빈 입력 [REQUIRED]
빈 items 는 위 순회에서 빈 `result` 로 성립한다. 별도 분기를 두지 않는다.
## 결정 3: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
