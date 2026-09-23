# request.md
## 원문
주문 요약 조회 `OrderService.summarize(orderId)` 를 추가한다. 결과는 orderId, totalCents(라인 금액 합), lineCount 세 필드다.
## 범위
- `src/OrderService.java` 에 summarize 추가, 요약에 필요한 파일은 `src/` 아래 신설 가능, `src/test/OrderSummaryTest.java` 신규.
## 기존 계약
없는 주문은 기존 `NotFoundException` 이며 HTTP 계층이 404 로 변환한다.
