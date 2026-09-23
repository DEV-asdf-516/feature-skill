# design.md
## 계약
- `SlugNormalizer.collapse(String slug)` 는 연속 하이픈 2개 이상을 하이픈 하나로 바꾼 문자열을 돌려준다.
- 빈 문자열 입력은 빈 문자열을 돌려준다.
- 하이픈이 아닌 문자는 그대로 둔다.
