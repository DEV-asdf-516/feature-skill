# approach.md
## 결정 1: 정규화 [REQUIRED]
`rawCode.replaceAll("[^0-9]", "")` 로 숫자만 남긴 뒤 `repo.saveCorpCode(clientId, normalized)` 를 호출한다(`src/CorpCodeService.java:L3-L6`).
## 결정 2: 저장 [DELEGATED]
