# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L6-L8` 의 `findOrThrow` 로 조회한다(없으면 NotFoundException). 새 조회 경로·새 예외 타입 없음.
## 결정 2: 전화번호 마스킹 [REQUIRED] — REUSE `MaskingUtil.maskPhone`
기존 `src/MaskingUtil.java:L3-L6` 의 `maskPhone` 으로 마스킹한다. 마스킹 규칙을 서비스에 다시 쓰지 않는다.
## 결정 3: 응답 타입 [REQUIRED] — NEW `ClientSummary`
`src/ClientSummary.java` 에 `public record ClientSummary(long id, String name, String maskedPhone)` 를 신설한다 — design 이 존재를 확정한 요약 응답 전용 feature-local 값 객체이며 기존 책임과 경쟁하지 않는다. 매핑은 `ClientService.summary` 안에서 한다(별도 converter·shared helper 없음).
## 결정 4: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
