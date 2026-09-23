# approach.md
## 결정 1: 주문 조회 [DELEGATED]
## 결정 2: 없는 id [REQUIRED]
기존 `src/NotFoundException.java:L1-L3` 의 NotFoundException 을 던진다(→ 404 는 기존 핸들러). 새 예외 타입·null·부분 결과 없음.
## 결정 3: 결과 순서 [REQUIRED]
결과는 ids 의 순서를 따른다(design 계약).
## 결정 4: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
