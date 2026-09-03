# 검증자 판정 감도 회귀 세트

스모크 테스트는 러너·스키마 연결만 확인한다. 검증자 프롬프트(`prompts/validator-review-*.md`), `schemas/spec-review.schema.json`, 또는 `consensus-loop.sh`의 연계 검사를 바꿨을 때는 이 세트를 **같은 모델·effort**(`config.sh`의 `VALIDATOR_MODEL`/`VALIDATOR_EFFORT`)로 돌린다. 매 설치 때 돌릴 필요는 없다. 실제 검증자 호출이 사례당 1회 발생한다(case-08 포함).

입력은 `tests/validator-cases/case-*/`에 고정돼 있다(request·design·(impl 사례는 implementation·approach)·필요한 `src/`·`expected.json`). 사람이 매번 문서를 새로 쓰지 않으므로, 결과 차이는 프롬프트·스키마 변경 때문이다. 픽스처 문서에 기대 답("러너 관할" 같은 힌트)을 적지 않는다.

```bash
bash tests/validator-regression.sh                       # 전 사례
bash tests/validator-regression.sh case-07-policy-undecided
bash tests/validator-regression.sh compare <validator-*-round-NN.json> <expected.json>
```

## 실행 전제

- `VALIDATOR_MODEL`, `VALIDATOR_EFFORT`, `CODEX_BIN`은 실제 값이어야 한다. 사전 검사가 이 세 대입문의 `CHANGE_ME`만 본다.
- `TEST_CMD`와 `LINT_CMD`는 스크립트가 설치된 복사본에서 `true`로 대체하므로 원본 config.sh에 `CHANGE_ME`로 남아 있어도 된다.
- 복사본은 공유 config.sh의 가드와 consensus-loop의 사전 점검을 그대로 거친다. 나머지 역할의 모델·effort와 `CLAUDE_BIN`도 유효한 값이어야 한다(가짜 디자이너를 쓰는 case-08 외에는 claude가 호출되지 않지만, 설치된 `claude` 실행 파일은 있어야 한다).

## 판정 방식

- 종료 코드가 먼저다. 기대 PASS 사례는 exit 0, 기대 BLOCK 사례는 exit 2(라운드 소진 또는 ASK_USER)여야 하며, 그 외(러너의 응답 거부·설정 오류·검증자 실패)는 결과 파일이 있어도 실패다.
- `expected.json`은 핵심 필드만 본다: verdict, blocking_issues 개수, 각 기대 이슈를 만족하는 이슈의 존재. 필드는 정확 일치(`"action": "REVISE_DOC"`) 또는 `<field>_any_of` 허용 집합(`"category_any_of": [...]`)으로 적는다. 자연어 본문은 대조하지 않는다.
- 감도 회귀의 관심사는 "중요하지 않은 것을 BLOCK했는가"와 "중대한 문제를 통과시켰는가"다. 같은 유효 문제에 어떤 라벨을 골랐는지는 여러 답이 맞을 수 있으면 `_any_of`로 열어 둔다.

| 사례 | 상황 | 단계 | 기대 |
|---|---|---|---|
| case-01-unrelated-existing-defect | 기존 캐시 결함이 있으나 이번 피처가 그 경로를 건드리지 않음 | impl | PASS |
| case-02-required-util-missing | request.md가 기존 유틸 재사용을 명시했는데 approach.md는 직접 구현 | impl | BLOCK / REVISE_DOC / REQUIREMENT_MISSING 또는 REQUIREMENT_CONTRADICTION / DIRECT_MISMATCH |
| case-03-runner-ops-missing | 정상 구현 문서. git diff 기준선 같은 파이프라인 운영 내용이 없을 뿐 | impl | PASS (러너 관할 — 문서에 힌트 없음) |
| case-04-unrequested-message-check | 외부 응답 `{status, message, data}`. status 판정만 합의, message는 요구 없음 | impl | PASS (message 허용값·null 검사를 새로 요구하면 회귀) |
| case-05a-secret-log-in-scope | 새 외부 호출이 API 키를 로그에 기록하지만 범위 안 클라이언트에서 제거 가능 | design | BLOCK / REVISE_DOC / CHANGE_INTRODUCES_SECURITY_RISK / REACHABLE_FAILURE |
| case-05b-secret-log-out-of-scope | 같은 노출. 프로젝트 계약상 모든 외부 HTTP는 수정 금지된 공용 컴포넌트를 거쳐야 하고 범위 내 대안 없음 | design | BLOCK / ASK_USER / CHANGE_INTRODUCES_SECURITY_RISK / REACHABLE_FAILURE |
| case-06-normalize-empty-persist | 정규화 후 빈 문자열이 corp_code로 저장될 수 있음 | impl | BLOCK / REVISE_DOC / CHANGE_INTRODUCES_DATA_RISK 또는 REQUIREMENT_CONTRADICTION / DIRECT_MISMATCH 또는 REACHABLE_FAILURE. **수동:** minimum_contract_needed가 불변식만 서술하는지(스크립트가 `[MANUAL]`로 값을 출력) |
| case-07-policy-undecided | idempotency 재요청 정책이 어디에도 없고 선례도 없음 | design | BLOCK / ASK_USER / POLICY_UNDECIDED / UNDECIDED_CHOICE |
| case-08-round2-new-issue | Round 1 리뷰(고정 `prev-review.json`, B-01 한 건)는 수정됐고, 처음부터 있었지만 그 리뷰에 없던 별개 결함(maskedPhone 테스트 누락)이 남아 있음 | impl, **Round 2** | **PASS** — 별개 결함을 새로 제기하면 프롬프트 회귀 |

## case-08의 실행 방식

한 번의 `consensus-loop.sh` 프로세스 안에서 Round 1 → 디자이너 → Round 2가 진행된다. 스크립트가 만든 가짜 codex가 Round 1 호출에만 `prev-review.json`을 그대로 출력하고(Round 1 검증자가 B-02를 놓쳤는지는 이 사례의 관심사가 아니다), 가짜 디자이너가 `revised/` 문서를 적용하고 `decisions-round1.md`를 기록한 뒤, Round 2는 실제 검증자가 돈다. 대조 대상은 `validator-impl-round-02.json`이다. 러너는 origin의 형식과 참조 대상 존재(직전 이슈 id, 스냅샷 대비 실제 바뀐 문서)만 검증하므로, Round 2에 blocker가 나오면 `reviews/docs-diff-impl-round-02.diff`와 사람이 대조해 revision_ref가 정말 그 결함의 원인인지 본다.

## 결과 해석

기대 결과는 `통과 9 / 실패 0`이고, case-06의 `[MANUAL] minimum_contract_needed`가 구현법 처방이 아니라 불변식만 담고 있으면 완료다. 실패는 세 부류로만 나눈다.

- 스크립트가 exit 1로 끝남 → 하네스·설정·스키마 또는 검증자 출력 형식 문제. 프롬프트 감도 문제가 아니다.
- 정상 종료인데 `[DIFF]` → 실제 검증자 판정 감도 문제. 그 사례가 드러낸 관할·입장 조건 문장만 최소 수정한다.
- case-08 Round 2가 BLOCK → docs diff와 blocker의 인과관계를 수동 확인한다.

실행 전에 프롬프트나 스키마를 더 보강하지 않는다. 기대와 다른 사례가 나왔을 때만 손댄다.

수동 확인은 두 곳뿐이다: case-06의 minimum_contract_needed가 구현 기법 처방이 아닌지, case-08에서 Round 2 blocker가 나왔을 때 docs diff가 실제 원인인지. 자연어 본문을 정규식으로 자동 판정하지 않는다.

판정이 기대와 다르면 개별 픽스처 문서를 늘리지 말고 검증자 프롬프트의 입장 조건·관할·탐색 범위 문구를 **최소로** 고친다. 사례 추가는 실제로 틀린 판정이 나온 상황에만 한다.
