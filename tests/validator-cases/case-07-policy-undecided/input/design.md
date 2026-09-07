# design.md
## 계약
- `POST /orders` → 201 + 주문 id.
- 같은 idempotency-key 재요청: **미정** (기존 결과 반환 또는 409 중 어느 쪽도 요구사항에 없음. 저장소에 idempotency 처리 선례 없음.)
