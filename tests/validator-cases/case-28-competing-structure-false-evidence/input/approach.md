# approach.md
## 결정 1: 숫자만 남기기 [REQUIRED] — NEW `PhoneFormatter`
탐색(같은 모듈·직접 의존): `src/ClientService.java:L5-L9` 의 `register`·`maskedPhone` 과 `src/MaskingUtil.java:L1-L4` 를 확인했다. 전화번호에서 숫자만 남기는 구현은 없다. 가장 가까운 후보는 `MaskingUtil.maskPhone` 인데 가운데 자리를 가리는 용도라 REUSE/EXTEND 불가 → `src/PhoneFormatter.java` 에 `public static String digitsOnly(String phone)` 를 신설한다(final class, private 생성자).
## 결정 2: 적용 위치 [REQUIRED]
`ClientService.register` 가 `repo.insert` 호출 직전에 `PhoneFormatter.digitsOnly(phone)` 를 1회 호출해 그 결과를 넘긴다. `repo.insert` 호출은 지금처럼 1회다.
## 결정 3: 포맷·import 순서 [DELEGATED]
formatter 와 import 정렬 도구가 정한다.
