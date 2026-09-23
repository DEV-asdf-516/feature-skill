# request.md
## 원문
클라이언트 내보내기 한 줄 `ClientService.exportLine(id)` 를 추가한다. 형식은 `id,name,maskedPhone` 이고 마스킹은 기존 MaskingUtil 을 그대로 쓴다.
## 범위
- `src/ClientService.java` 에 exportLine 추가, `src/test/ClientServiceTest.java` 에 테스트 추가.
## 제외
- `src/MaskingUtil.java` 와 기존 `get` 은 변경하지 않는다.
