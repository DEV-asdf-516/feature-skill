# approach.md
## 결정 1: 없는 id 처리 [REQUIRED] — REUSE `findOrThrow`
기존 `src/ClientService.java:L6-L8` 의 `findOrThrow` 를 그대로 호출한다.
## 결정 2: 태그 포매터 [REQUIRED] — NEW `src/TagFormatter.java`
탐색: 같은 모듈과 직접 의존 코드에 태그 연결·대문자화 유틸이 없고(`Client.tags()` 는 목록만 돌려준다) 가장 가까운 후보도 없다 — REUSE/EXTEND 불가, NEW. 정확히 다음 형태로 만든다. 파일 위치 `src/TagFormatter.java`, 클래스 `public final class TagFormatter`(private 생성자, 인스턴스 상태 없음), public static 메서드 `joinUpper` 하나만. 파라미터 이름은 `tags`, 지역 변수는 `line`, 순회 변수는 `tag`. 인터페이스·추상 클래스·인스턴스 메서드·추가 오버로드·다른 유틸 메서드를 만들지 않는다.
```
public final class TagFormatter {
  private TagFormatter() {}
  public static String joinUpper(java.util.List<String> tags) {
    StringBuilder line = new StringBuilder();
    for (String tag : tags) {
      if (line.length() > 0) line.append(',');
      line.append(tag.toUpperCase());
    }
    return line.toString();
  }
}
```
## 결정 3: `tagLine` 의 구조 [REQUIRED] — 두 줄, 결정 2 의 symbol 사용
조회 결과를 지역 변수 `client` 에 두고 다음 줄에서 `TagFormatter.joinUpper(client.tags())` 를 직접 반환한다. `ClientService` 에 순회·연결 코드를 두지 않고, `TagFormatter` 를 우회하는 다른 helper 도 만들지 않는다.
```
public String tagLine(long id) {
  Client client = findOrThrow(id);
  return TagFormatter.joinUpper(client.tags());
}
```
## 결정 4: 테스트 [REQUIRED] — 참조 `src/test/ClientServiceTest.java:L15-L18` 복제
`get_returnsClient` 와 같은 형태로 세 테스트를 추가하고 `main` 에서 호출한다. `TagFormatter` 전용 테스트 파일은 만들지 않는다(implementation.md 의 테스트 목록에 없다).
## 결정 5: 포맷·import 순서 [DELEGATED]
## `ClientService.tagLine` 제어 흐름 [REQUIRED]
요구되는 분기:
- B1 / design 계약 1: 없는 id → NotFoundException (결정 1)
주 경로: 클라이언트 조회 → TagFormatter.joinUpper 반환
금지: 위 목록에 없는 null·빈값 방어 분기 · fallback · 재시도 · 타입별 if
## `TagFormatter.joinUpper` 제어 흐름 [REQUIRED]
요구되는 분기:
- B2 / design 계약 2: 첫 태그 앞에는 구분자를 붙이지 않는다 (`line.length() > 0` — blueprint 의 그 자리)
주 경로: 태그 순회(구분자·대문자 append) → 문자열 반환
금지: null 목록 방어 · stream/Collectors 로 대체
