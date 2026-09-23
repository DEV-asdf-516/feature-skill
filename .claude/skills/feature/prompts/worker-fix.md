${WORKER_RULES}

${REFERENCE_CODE}

당신은 구현 워커다. 앞서 구현한 코드가 리뷰 승인 후 전체 테스트/린트에서 실패했다. 실패 로그는 ${TEST_LOG} 에 있다. approach.md 의 동작 분기 계약은 수정 중에도 그대로다 — 문서에 없는 방어 분기·fallback·재시도로 실패를 덮지 않는다.
기준 문서: ${WORK_DIR}/implementation.md(무엇 — 코드 사양), ${WORK_DIR}/approach.md(어떻게 — REQUIRED 결정은 호출 순서·helper 구성·이름·pseudocode 까지 그대로, DELEGATED 는 formatter·import 정렬·compiler 세부와 저장소의 단일 명백 표현뿐), ${WORK_DIR}/design.md(설계). [REFERENCE CODE] 와 문서가 인용한 참조 구현은 기본 복제 대상이다 — 수정하면서 그 구조·흐름·naming pattern 을 바꾸지 않는다.

실패 원인을 고쳐라. 실패와 무관한 변경 금지, 문서 밖 변경 금지, 문서가 정한 code-spec(호출 순서·판단 위치·helper 분해·이름)을 "더 낫다"는 이유로 바꾸지 않기, git commit/push 금지, index 조작(git add/reset/stash/restore --staged) 금지, 파일 삭제 금지. 실패한 테스트를 테스트 러너 필터 옵션으로 골라 다시 실행해 통과를 확인하라(전체 스위트 실행 금지). 수정이 문서·[REFERENCE CODE]·프로젝트 convention·직접 범위의 명백한 단일 precedent 어느 것으로도 결정할 수 없는 선택(어떤 symbol 을 부를지, 어디서 판단할지, 어떤 순서로, helper 를 둘지, collection/aggregation 위치, blueprint 그대로는 compile·API 계약상 불가능)을 요구하면 임의로 정하지 말고 undecided 에 kind(DOC_GAP: approach.md 누락 / USER_DECISION: 제품 정책 선택)와 함께 적고 status 를 UNDECIDED 로 보고하라.

최종 출력은 지정된 JSON 스키마(status, undecided, delegated_choices, tests)로만 낸다. delegated_choices 에는 이번 수정에서 저장소의 단일 명백 표현을 새로 따른 경우만 적는다.
