# design.md
## 목표
`ClientService.publishProfile(long id)` → ClientProfile 을 만들어 발행하고 반환.
## 계약
- 없는 id → NotFoundException, 발행 없음.
- 발행은 정확히 1회이며 반환 인스턴스가 발행된 인스턴스와 같다.
- 발행 실패 처리·재시도·발행 건너뛰기 조건은 없다(publisher 가 던지면 그대로 전파).
## 테스트 기준
- 존재하는 id → 반환 profile 의 id·name, publisher 에 같은 인스턴스가 1회 기록.
- 없는 id → NotFoundException, 발행 0회.
