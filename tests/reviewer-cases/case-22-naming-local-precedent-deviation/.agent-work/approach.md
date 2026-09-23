# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L7-L9` 의 `findOrThrow` 를 그대로 호출한다(NotFoundException → 404 는 기존 핸들러가 처리). 탐색: 같은 모듈의 id 조회는 `src/ClientRepository.java:L1-L3` 의 `findById` 와 그것을 감싼 `findOrThrow` 뿐이다. 새 조회 경로·새 예외 타입·null 반환 없음.
## 결정 2: 전화번호 마스킹 [REQUIRED] — REUSE `MaskingUtil.maskPhone`
기존 `src/MaskingUtil.java:L3-L6` 의 `maskPhone` 을 `ClientSummary` 생성자의 세 번째 인자 자리에서 직접 호출한다(`MaskingUtil.maskPhone(client.phone())`). 마스킹 결과를 담는 지역 변수는 두지 않는다.
## 결정 3: `summary` 의 구조 [REQUIRED] — 참조 `src/ClientService.java:L11-L14` 복제
기존 `profile` 과 같은 구조로 쓴다: 조회 결과를 지역 변수 `client` 에 두고, 다음 줄에서 DTO 생성자에 `client` 의 접근자 값을 직접 넘겨 반환한다. private helper 를 추출하지 않는다(`profile` 도 helper 없이 두 줄이다). `profile` 과 달라지는 지점은 세 번째 인자가 결정 2 의 마스킹 호출이라는 것뿐이다.
```
public ClientSummary summary(long id) {
  Client client = findOrThrow(id);
  return new ClientSummary(client.id(), client.name(), MaskingUtil.maskPhone(client.phone()));
}
```
## 결정 4: DTO `ClientSummary` [REQUIRED] — NEW, 참조 `src/ClientProfile.java:L1-L7` 복제
`ClientProfile` 과 같은 형태(final 필드 + 한 줄 생성자 + 접근자 메서드)로 필드 `id`, `name`, `maskedPhone`. 탐색: 같은 모듈에 요약 DTO 는 없고 가장 가까운 것이 `ClientProfile`(필드 둘) 이며 maskedPhone 이 없어 REUSE 불가, 기존 프로필 응답 계약을 바꾸므로 EXTEND 불가.
## 결정 5: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
## `ClientService.summary` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 1: 없는 id → NotFoundException (결정 1)
주 경로: 클라이언트 조회 → 마스킹 → ClientSummary 반환
금지: 위 목록에 없는 null·빈값 방어 분기 · fallback · 재시도 · 타입별 if
