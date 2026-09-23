# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L6-L8` 의 `findOrThrow` 로 조회한다(없으면 NotFoundException). 새 조회 경로·새 예외 타입 없음.
## 결정 2: 전화번호 마스킹 [REQUIRED] — REUSE `MaskingUtil.maskPhone`
기존 `src/MaskingUtil.java:L3-L9` 의 `maskPhone` 으로 가운데 4자리를 `*` 로 가린다. 마스킹 규칙을 서비스에 다시 쓰지 않는다.
## 결정 3: 응답 [REQUIRED] — REUSE `ClientSummary`
기존 `src/ClientSummary.java:L1-L1` 의 record 를 `summary` 안에서 직접 생성해 돌려준다. 새 DTO·converter 없음.
## 결정 4: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
