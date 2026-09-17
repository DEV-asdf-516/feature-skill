# approach.md
## 결정 1: 요약용 클라이언트 조회 [REQUIRED]
새 `ClientSummaryRepository` 를 만들어 `findById(long id)` 로 조회하고, 없으면 NotFoundException 을 던진다(→ 404 는 기존 핸들러가 처리). summary 전용 조회 경로를 분리해 두면 이후 요약 필드가 늘어도 기존 조회에 영향이 없다.
## 결정 2: 전화번호 마스킹 [REQUIRED]
기존 `src/MaskingUtil.java:L3-L6` 의 `maskPhone` 을 재사용한다.
## 결정 3: DTO 매핑 [DELEGATED]
