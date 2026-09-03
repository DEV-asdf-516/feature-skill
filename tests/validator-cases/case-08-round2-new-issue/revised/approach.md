# approach.md
## 결정 1: 없는 id 처리 [REQUIRED]
기존 `src/ClientService.java:L8-L11` 의 `findOrThrow` 패턴을 그대로 쓴다(NotFoundException → 404 는 기존 핸들러가 처리).
## 결정 2: 전화번호 마스킹 [REQUIRED]
기존 `src/MaskingUtil.java:L3-L6` 의 `maskPhone` 을 재사용한다.
## 결정 3: DTO 매핑 [DELEGATED]
