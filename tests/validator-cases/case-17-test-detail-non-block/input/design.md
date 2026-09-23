# design.md
## 계약
- `TagParser.parse(String input)` 은 `input` 을 `,` 로 나눠 각 조각을 `normalize` 한 뒤 빈 문자열이 아닌 것만 입력 순서대로 담은 새 `List<String>` 을 돌려준다.
- 중복은 그대로 둔다. `input` 은 null 이 아니다(호출자 계약). 빈 문자열 → 빈 목록.
## 테스트 기준
- "Java, ,kotlin ,  " → ["java", "kotlin"].
- "" → [].
- "a,a" → ["a", "a"].
## 비범위
- 정렬·중복 제거·다른 구분자 없음.
