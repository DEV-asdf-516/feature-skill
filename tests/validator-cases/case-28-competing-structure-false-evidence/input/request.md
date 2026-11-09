# request.md
## 원문
고객사 등록(`ClientService.register`) 때 전화번호를 숫자만 남겨 저장한다. 지금은 입력 그대로(`010-1234-5678`) 저장된다.
## 범위
- `src/ClientService.java`, 필요한 파일은 `src/` 아래 신설 가능, `src/test/ClientRegisterTest.java`
## 제외
- 전화번호 수정(`updatePhone`)·마스킹 동작 변경 없음.
