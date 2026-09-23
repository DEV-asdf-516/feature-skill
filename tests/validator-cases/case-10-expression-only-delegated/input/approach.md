# approach.md
## 결정 1: 빈 입력 [REQUIRED]
빈 문자열은 그대로 돌려준다(design.md 계약).
## 결정 2: 연속 하이픈 축약 [REQUIRED]
정규식 `-{2,}` 를 `-` 로 치환한다(표준 라이브러리, 입력 한 번 순회, 별도 상태 없음). 같은 모듈에 선례 없음(`src/SlugNormalizer.java:L1-L5` 는 소문자 변환뿐).
## 결정 3: Pattern 보관 위치·반환 표현 [DELEGATED]
## 결정 4: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
