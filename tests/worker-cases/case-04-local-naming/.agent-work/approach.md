# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L6-L8` 의 `findOrThrow` 를 그대로 호출한다.
## 결정 2: 갱신 사본 [REQUIRED] — REUSE `Client.withName`
`src/Client.java:L9` 의 `withName(String)` 으로 이름이 바뀐 사본을 만든다. 새 생성자 호출·setter·builder 없음.
## 결정 3: `rename` 의 구조와 지역 변수 이름 [REQUIRED] — 참조 `src/ClientService.java:L10-L15` 복제
기존 `changePhone` 과 같은 네 줄 구조로 쓴다. 지역 변수 이름은 문서가 정한다: 조회 결과는 `client`(참조와 같음), 갱신 사본은 `renamed`(참조의 `changed` 에 대응하는 이 요구의 이름). 다른 이름(`existing`, `found`, `entity`, `updated`, `result` 등)으로 바꾸지 않고, 지역 변수를 인라인해 줄을 줄이지도 않는다. private helper 없음.
```
public Client rename(long id, String newName) {
  Client client = findOrThrow(id);
  Client renamed = client.withName(newName);
  repo.save(renamed);
  return renamed;
}
```
## 결정 4: 테스트 [REQUIRED] — 참조 `src/test/ClientServiceTest.java:L21-L27` 복제
`changePhone_savesAndReturnsChanged` 와 같은 형태로 두 테스트를 추가하고 `main` 에서 호출한다.
## 결정 5: 포맷·import 순서 [DELEGATED]
## `ClientService.rename` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 1: 없는 id → NotFoundException (결정 1)
주 경로: 클라이언트 조회 → 갱신 사본 → 저장 → 사본 반환
금지: 위 목록에 없는 null·빈값 방어 분기 · fallback · 재시도 · 타입별 if
