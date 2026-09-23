# design.md
## 목표
`ClientService.tagLine(long id)` → 태그를 순서대로 대문자화하고 `,` 로 이은 문자열.
## 계약
- 없는 id → NotFoundException.
- 예: ["vip","new"] → `VIP,NEW`. 태그가 없으면 빈 문자열. 앞뒤·사이 공백 없음.
## 테스트 기준
- ["vip","new"] → `VIP,NEW`; [] → ``; 없는 id → NotFoundException.
