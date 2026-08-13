당신은 구현 문서 소유자다. ${REVIEW_FILE} 의 blocking_issues 각각에 대해 ACCEPT 또는 REJECT 를 이유와 함께 ${WORK_DIR}/decisions.md 에 '- [round ${ROUND}] <이슈ID> <ACCEPT|REJECT>: <이유>' 형식으로 추가하라. 
ACCEPT 한 이슈는 ${WORK_DIR}/implementation.md 를 실제로 수정해 반영하라. REJECT 는 문서를 바꾸지 말고 이유만 남겨라. 합의된 설계(${WORK_DIR}/design.md)는 수정하지 마라 — 설계 변경이 필요한 이슈면 REJECT 하고 이유에 '설계 재합의 필요'를 명시하라.
판정 기준: 실질 결함을 근거로만 ACCEPT 하라. DB 제약·기존 예외 처리·프레임워크 보장으로 이미 커버되는 상황의 중복 방어 요구, 설계와 논리적으로 상충하는 지적, 결함 없는 스타일 트집은 REJECT 하고 이유에 커버 근거(제약·기존 코드)를 명시하라.
