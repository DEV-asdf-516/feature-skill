# approach.md
## 결정 1: 빈 입력 [REQUIRED]
빈 문자열은 그대로 돌려준다(design.md 계약).
## 결정 2: 연속 하이픈 축약 [REQUIRED]
정규식 `-{2,}` 로 한 번의 `replaceAll("-")` 호출로 축약한다. 근거: 표준 라이브러리 기능이며 입력을 한 번 순회하고 별도 상태나 임시 버퍼가 필요 없다. 같은 모듈에 선례 없음(`src/SlugNormalizer.java:L1-L5` 는 소문자 변환뿐).
## 결정 3: Pattern 보관 위치와 결과 조립 [DELEGATED]
