# design.md
## 목표
`TagMerger.missing(List<String> existing, List<String> incoming)` → existing 에 없는 incoming 태그 목록.
## 계약
- 비교는 정확한 문자열 일치다(대소문자 구분).
- 결과 순서는 incoming 의 순서를 따른다.
- incoming 안의 중복은 그대로 둔다(중복 제거는 이 기능의 일이 아니다).
- 두 목록은 항상 null 이 아니다(호출자 계약). 빈 목록이면 빈 결과.
## 테스트 기준
- existing=[a,b], incoming=[b,c,a,d] → [c,d].
- incoming 이 비면 빈 목록.
## 비범위
- 태그 정규화·대소문자 무시 없음.
