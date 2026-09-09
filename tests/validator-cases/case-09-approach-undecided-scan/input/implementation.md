# implementation.md
## 변경 파일
1. `src/SlugNormalizer.java` — `String collapse(String slug)` 추가. 기존 `lower` 는 그대로 둔다(`src/SlugNormalizer.java:L2-L4`).
## 테스트
- "a--b---c" → "a-b-c".
- "" → "".
- "a-b" → "a-b".
