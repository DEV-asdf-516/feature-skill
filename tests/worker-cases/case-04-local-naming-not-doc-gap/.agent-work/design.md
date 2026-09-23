# design.md
## 목표
`ClientService.rename(long id, String newName)` → 이름이 바뀐 Client 를 저장하고 반환.
## 계약
- 없는 id → NotFoundException.
- 반환 인스턴스가 저장된 인스턴스와 같다(한 번 저장).
## 테스트 기준
- 존재하는 id → 반환 name == newName, repo.save 1회(같은 인스턴스).
- 없는 id → NotFoundException, 저장 없음.
