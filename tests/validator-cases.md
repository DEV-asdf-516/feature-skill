# 검증자 판정 감도 회귀

고정된 `input/*.md`와 `src/`를 임시 저장소의 `.agent-work/`와 `src/`로 복사해 실제 validator를 실행한다. fixture 원본은 Git으로 관리하고 `.agent-work/`는 실행 산출물로만 쓴다. 모델 응답에 기대값이나 판정 힌트를 주지 않는다.

```bash
python3 tests/validator-fixture-smoke.py              # 유료 호출 없는 fixture/비교 검사
# 사용자 지시 후에만 1회용 승인 파일 생성:
touch .claude/ALLOW_REAL_LLM_REGRESSION
bash tests/validator-regression.sh                   # 11개, 최대 실제 검증자 11회
bash tests/validator-regression.sh case-08b-round2-new-issue # 08a 먼저 + 08b, 최대 2회
bash tests/validator-regression.sh compare review.json expected.json [full|gate]
```

실제 호출은 config.sh의 VALIDATOR_MODEL/EFFORT/PROFILE을 사용한다. TEST_CMD와 LINT_CMD는 임시 사본에서 true로 바꾸며 원본 설정을 수정하지 않는다. case-08b의 디자이너는 고정 수정 적용용 가짜 실행기이고, 디자이너 모델 행동은 이 회귀로 검증하지 않는다.

## 사례

| 사례 | 검사하는 경계 | 기대 |
|---|---|---|
| 01 unrelated-existing-defect | 새 조회는 repo를 직접 사용하며 기존 캐시 결함 경로를 활성화하지 않음 | impl PASS |
| 02 required-util-missing | 사용자 명시 MaskingUtil 재사용 대신 직접 구현 | impl BLOCK / REVISE_DOC / DIRECT_MISMATCH |
| 03 runner-ops-missing | 정상 optional subtitle 응답 변경. 문서의 미커밋 메모·미정 baseline/archive는 운영 문제 | impl PASS |
| 04 unrequested-message-check | status 판정만 합의. message 검사 요구를 새로 만들지 않음 | impl PASS |
| 05a document-security-conflict | 키 비기록 요구와 키 포함 URL 로깅 설계가 문서만으로 충돌 | design BLOCK / REVISE_DOC / SECURITY / DIRECT_MISMATCH |
| 05b reachable-security-failure | 직접 의존 코드가 키 포함 URL을 기록. 해당 공용 코드 수정 허용 | design BLOCK / REVISE_DOC / SECURITY / REACHABLE_FAILURE |
| 05c out-of-scope-security-conflict | 05b와 같은 design·code. 인증 키 원문 전달·유일한 호출 경로·공용 코드/로그 설정 수정 금지로 범위 내 대안 없음 | design BLOCK / ASK_USER / SECURITY / REACHABLE_FAILURE |
| 06 normalize-empty-persist | 숫자 정규화 뒤 무조건 저장이 8자리/미저장+400 계약 위반 | impl BLOCK / REVISE_DOC, category/evidence는 expected의 허용 집합 |
| 07 policy-undecided | idempotency 재요청 정책이 미정이고 선례 없음 | design BLOCK / ASK_USER / POLICY_UNDECIDED / UNDECIDED_CHOICE |
| 08a round1-blockers | A=필수 마스킹 유틸 미사용, B=없는 id에 404 대신 200. 두 독립 요구 위반 | impl Round 1 BLOCK / REVISE_DOC 2건 / DIRECT_MISMATCH |
| 08b round2-new-issue | 직전 리뷰에는 A만 있음. A만 수정되고 이전부터 보인 별개 B는 그대로 | impl Round 2 PASS |

SECURITY는 표를 위한 축약이며 실제 JSON은 `CHANGE_INTRODUCES_SECURITY_RISK`다.

05c는 공통 프롬프트의 **확정 계약 충돌 예외**를 검사한다. 새 category는 없다. 일반 ASK_USER 네 조건은 유지하고, 피처 관련 blocker·정확한 근거·안전한 범위 내 대안 부재가 입증된 계약 충돌에 한해서만 1·3조건의 예외로 사용자 결정을 다시 요구한다. 확정 범위를 임의로 넓히거나 설계자에게 사용자 결정을 고치라고 보내지 않는다.

## 08의 두 실행을 분리하는 이유

08a와 08b의 초기 input/src는 동일하다. 먼저 실제 validator로 08a의 A+B 검출을 검사하고, 자동 비교에 실패하면 08b의 유료 호출은 생략한다. 두 이슈가 실제 A/B인지는 manual-check로 응답 본문을 확인한다. 같은 결함을 둘로 중복 보고했다면 count/label이 맞아도 의미 검사 통과가 아니다.

08b에서는 08a의 실제 리뷰를 이어 붙이지 않는다. 고정 `prev-review.json`에는 A만 넣는다. 가짜 디자이너는 `revised-input/`을 적용해 A만 고친다. B는 변경 전부터 있었지만 직전 리뷰에는 없었으므로, Round 2에서 처음 등록하면 suppression 실패다.

**직전 리뷰에 A+B가 모두 있었다면 미해결 B를 `UNRESOLVED_PREVIOUS`로 내는 것이 올바르다.** 그 상황에서 PASS를 요구하면 기존 Round 2 계약을 깨뜨린다. 따라서 별도의 Round 1 대조와 A만 포함한 종결 검사로 나눈다. 이전 미해결 이슈 유지나 수정으로 새로 생긴 회귀를 검사하는 사례는 이번 suppression 사례와 별개다.

## 채점

- **Gate:** 유효한 runner 종료 + PASS/BLOCK + action별 이슈 수.
- **Classification:** Gate에 더해 category/evidence/origin 등 expected의 모든 issue 필드. 전체 사례 수를 분모로 사용하므로 gate 실패도 classification 실패다.
- **실행·출력 오류:** runner가 JSON 필드 연계를 거부했거나 CLI/실행이 실패한 사례. 두 점수에서 통과로 세지 않고 별도로 표시한다.
- **선행 실패로 생략:** 08a 실패로 08b를 호출하지 않은 경우. 통과로 세지 않는다.

예를 들어 보안 문제를 올바르게 BLOCK/REVISE_DOC했으나 evidence만 틀리면 Gate는 통과, Classification은 실패다. blocker를 PASS하면 둘 다 실패다. 단순 최종 exit 1만으로 CLI 오류와 판정 실패를 구분하지 않는다. `run.log`의 사례 종료와 비교 결과를 함께 본다.

비교는 이슈 순서나 id에 의존하지 않으며, 실제 이슈 하나를 여러 기대 이슈에 재사용하지 않는 일대일 매칭이다. `_any_of`는 의미상 허용되는 category/evidence 차이를 열어 두는 데 사용한다. 질문 문장·선택지 표현·구체 해결 기법은 고정하지 않는다.

## 수동 확인과 한계

- 06: 최소 불변식만 요구하고 구현 기법을 처방하지 않는가.
- 08a: 두 응답이 실제로 마스킹 재사용 위반 A와 404/200 위반 B인가.
- 08b가 BLOCK이면 docs diff와 revision_ref의 실제 인과를 확인한다.
- 문서/코드 인용 범위의 존재는 로컬 fixture 검사로 확인한다. 단편 Java 코드는 모델 입력이며 완성된 애플리케이션 빌드 테스트가 아니다.
- guided는 새 05b 실행 전에 탐색 전략을 바꾸지 않는다. 결과가 실패하면 공통 계약의 직접 의존 확인 범위와 충돌하는지 검토한다.
- 같은 점수라도 gate 누락과 taxonomy 불일치는 다르다. 모델·effort·profile과 반복 수를 함께 기록한다.
