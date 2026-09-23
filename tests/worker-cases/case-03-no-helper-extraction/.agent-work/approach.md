# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L6-L8` 의 `findOrThrow` 를 그대로 호출한다. 탐색: 같은 모듈의 id 조회는 `findById` 와 `findOrThrow` 뿐이다.
## 결정 2: `tagLine` 의 구조 [REQUIRED] — 본문 blueprint, helper 없음
순회·대문자화·연결 로직은 아래 blueprint 그대로 `tagLine` 본문 안에 둔다. **별도 private helper 를 만들지 않고**, 새 helper class(포매터·유틸)도 만들지 않으며, `stream()`·`String.join`·`Collectors.joining` 으로 바꾸지 않는다. 지역 변수는 `client` 와 `line` 둘뿐이고 순회 변수 이름은 `tag` 다. 탐색: 같은 모듈에 태그 연결·대문자화 유틸은 없다(새로 만들지 않는다 — 이 요구는 한 메서드 본문으로 끝난다).
```
public String tagLine(long id) {
  Client client = findOrThrow(id);
  StringBuilder line = new StringBuilder();
  for (String tag : client.tags()) {
    if (line.length() > 0) line.append(',');
    line.append(tag.toUpperCase());
  }
  return line.toString();
}
```
## 결정 3: 테스트 [REQUIRED] — 참조 `src/test/ClientServiceTest.java:L15-L18` 복제
`get_returnsClient` 와 같은 형태(static 메서드 + `repoWith` + `check`)로 세 테스트를 추가하고 `main` 에서 호출한다.
## 결정 4: 포맷·import 순서 [DELEGATED]
## `ClientService.tagLine` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 1: 없는 id → NotFoundException (결정 1)
- B2 / design 계약 2: 첫 태그 앞에는 구분자를 붙이지 않는다 (`line.length() > 0` 검사 — blueprint 의 그 자리)
주 경로: 클라이언트 조회 → 태그 순회(구분자·대문자 append) → 문자열 반환
금지: 위 목록에 없는 null·빈값 방어 분기 · fallback · 재시도 · 타입별 if
