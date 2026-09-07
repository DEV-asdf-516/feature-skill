# approach.md
## 결정 1: 없는 id 처리 [REQUIRED]
repo.findById가 비어 있으면 예외를 던지지 않고 id=요청값, name="", maskedPhone=""인 응답을 HTTP 200으로 반환한다. 이 조회는 캐시를 사용하지 않는다.
## 결정 2: 전화번호 마스킹 [REQUIRED]
서비스 안에서 `phone.replaceAll(...)` 로 직접 가린다.
## 결정 3: DTO 매핑 [DELEGATED]
