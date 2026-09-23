# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `ClientRepository.findById`
기존 `src/ClientRepository.java:L1-L3` 의 `findById` 로 조회하고 없으면 기존 `src/NotFoundException.java:L1-L3` 의 NotFoundException 을 던진다.
## 결정 2: 발송 [REQUIRED] — REUSE `SmsGateway.send`
기존 `src/SmsGateway.java:L1-L3` 의 `send(phone, text)` 를 phone 이 비어 있지 않을 때 호출한다.
## 결정 3: 게이트웨이 실패 처리 [DELEGATED]
## 결정 4: 결과 타입 [REQUIRED] — REUSE `SendStatus`
반환은 기존 `src/SendStatus.java:L1-L5` 의 `SendStatus` 다. 새 결과·outcome 타입 없음.
## 결정 5: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
