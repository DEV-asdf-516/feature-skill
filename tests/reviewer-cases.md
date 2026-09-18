# 리뷰어 판정 감도 회귀 세트

스모크 테스트는 루프·스키마·러너 연결만 확인한다. 리뷰어 프롬프트(`prompts/reviewer.md`), `schemas/impl-review.schema.json`, 또는 `impl-review-loop.sh`의 연계 검사를 바꿨을 때는 이 세트를 **같은 모델·effort**(`config.sh`의 `REVIEWER_MODEL`/`REVIEWER_EFFORT`)로 돌린다. 매 설치 때 돌릴 필요는 없다. 실제 리뷰어 호출이 사례당 1회 발생한다(Round 2 사례 포함 — Round 1 리뷰와 수정자는 고정 픽스처가 대신한다).

입력은 `tests/reviewer-cases/case-*/`에 고정돼 있다: `.agent-work/`(request·design·implementation·approach·worker-result.json), `base/`(HEAD 로 커밋되는 기존 코드 — 프로젝트 컨벤션이 있는 사례는 여기에 `conventions.md` 를 두면 설치된 `config.sh` 의 `CONVENTIONS_FILE` 이 그대로 집는다; 없는 사례는 컨벤션 검사 없이 돈다), `changed/`(워커가 만든 작업 트리 상태), Round 2 사례는 `fixed/`(수정자 결과)·`prev-review.json`·`decisions-round1.md`, 그리고 `expected.json`. 픽스처 문서와 코드에 기대 답("이 결함은 범위 밖" 같은 힌트)을 적지 않는다. 결과 차이는 프롬프트·스키마·러너 변경 때문이다.

```bash
touch .claude/ALLOW_REAL_LLM_REGRESSION                  # 유료 실행 1회 승인 (사용자 지시 후에만)
bash tests/reviewer-regression.sh                       # 전 사례
bash tests/reviewer-regression.sh case-03-alias-return
bash tests/reviewer-regression.sh compare <reviewer-round-NN.json> <expected.json>
```

## 실행 전제

- `REVIEWER_MODEL`, `REVIEWER_EFFORT`, `CLAUDE_BIN`은 실제 값이어야 한다. 사전 검사가 이 세 대입문의 `CHANGE_ME`만 본다.
- `TEST_CMD`와 `LINT_CMD`는 설치된 복사본에서 `true`로 대체하므로 원본 config.sh에 `CHANGE_ME`로 남아 있어도 된다.
- Claude Code 세션 안에서 돌려도 된다. 래퍼가 중첩 실행 차단 변수(`CLAUDECODE`)를 하위 호출에서 지운다.
- 호출 카운터·픽스처는 대상 저장소 밖(`<target>.side/`)에 둔다. 저장소 안에 두면 리뷰 도중 작업 트리 지문이 바뀌어 루프가 스냅샷 오류로 멈춘다.

## 판정 방식

- 종료 코드가 먼저다. 기대 APPROVE 사례는 exit 0, 기대 REQUEST_CHANGES 사례는 exit 2(라운드 소진) 또는 3(DOC_GAP)이어야 하며, 그 외(러너의 응답 거부·설정 오류·리뷰어 실패)는 결과 파일이 있어도 실패다.
- `expected.json`은 핵심 필드만 본다: verdict, issues 개수, 각 기대 이슈를 만족하는 이슈의 존재. 필드는 정확 일치(`"category": "TEST_CONTRACT_GAP"`) 또는 `<field>_any_of` 허용 집합으로 적는다. 자연어 본문(`required_outcome`)은 대조하지 않고 스크립트가 출력만 한다 — 결과가 아니라 기법을 처방했는지는 사람이 본다.
- 감도 회귀의 관심사는 "막지 말아야 할 것을 막았는가"와 "막아야 할 것을 통과시켰는가"다. 같은 유효 문제에 어떤 라벨을 골랐는지는 여러 답이 맞을 수 있으면 `_any_of`로 열어 둔다.

case-12 와 case-16~19 를 제외한 모든 사례는 같은 피처(`GET /clients/{id}/summary`, 기존 `findOrThrow`·`MaskingUtil.maskPhone` 재사용, `ClientService.summary` 제어 흐름 절)를 공유하고 `changed/`의 코드만 다르다. case-12 는 solution shape 경계를 위한 독립 피처(태그 병합)다. case-14~19 는 `base/conventions.md`(계층 책임·DTO 의존·Parse Don't Validate·Tell Don't Ask·명명 다섯 규칙, 여섯 사례 동일)를 가진 프로젝트이며, case-16·17·20 은 변경 이력 피처(`ClientService.update` + `DiffUtil`/`ChangeLogWriter` 재사용), case-18·19 는 검증 갱신 피처(`ClientService.update` + 요청 DTO 신설)다. 컨벤션 사례의 문서·코드에도 기대 판정 힌트를 적지 않는다 — 규칙은 conventions.md 에만 있고 implementation.md 는 그 규칙을 반복하지 않는다.

| 사례 | 상황 | 기대 |
|---|---|---|
| case-01-existing-defect-outside-diff | `ClientCache.evict`가 잘못된 키 타입으로 절대 제거하지 않는 기존 결함. diff 밖이고 이번 변경이 활성화하지 않음 | APPROVE |
| case-02-meaningful-single-use-variable | `maskedPhone` 지역변수를 한 번만 쓰지만 approach.md 주 경로의 도메인 개념 | APPROVE |
| case-03-alias-return | `ClientSummary summary = new …; return summary;` — 대입 직후 그대로 반환. 전제: 프로젝트 규칙 없음, 참조 코드는 모두 식을 직접 반환(순수 alias) | REQUEST_CHANGES / FIX_CODE / REDUNDANT_CODE / SEMANTIC_REDUNDANCY |
| case-04-undeclared-fallback | design이 phone 을 항상 존재한다고 정했는데 `phone == null → ""` 분기 추가 | REQUEST_CHANGES / FIX_CODE / UNDECLARED_BEHAVIOR 또는 CONTRACT_VIOLATION / DIRECT_MISMATCH |
| case-05-duplicate-branch | `findOrThrow` 뒤에 다시 `client == null → NotFoundException` | REQUEST_CHANGES / FIX_CODE / REDUNDANT_CONTROL_FLOW(허용: UNDECLARED_BEHAVIOR, CONTRACT_VIOLATION) |
| case-06-naming-differs-contract-kept | 참조 코드·문서와 변수명·포맷만 다르고 `findOrThrow`·`maskPhone` 재사용과 테스트 계약은 준수 | APPROVE (명명·포맷을 issue 로 올리면 회귀) |
| case-07-required-util-reimplemented | approach.md 결정 2(`MaskingUtil.maskPhone` 재사용)를 무시하고 마스킹을 인라인 재구현 | REQUEST_CHANGES / FIX_CODE / CONTRACT_VIOLATION 또는 REDUNDANT_CODE |
| case-08-extra-blackbox-test | implementation.md 에 이름이 없지만 design.md 마스킹 계약을 검증하는 추가 black-box 테스트 | APPROVE ("문서에 없는 테스트"로 막으면 회귀) |
| case-09-internal-call-test | `verify(repo, times(1))`·`verifyNoMoreInteractions` 만 하는 내부 호출 테스트 추가 | REQUEST_CHANGES / FIX_CODE / TEST_CONTRACT_GAP |
| case-10-round2-old-issue | Round 1 리뷰(고정 `prev-review.json`, null fallback 한 건)는 수정됐고, Round 1 부터 있던 별개 alias(`ClientController.summary`의 `body`)가 수정 diff 밖에 남아 있음 | **Round 2 APPROVE** — 별개 문제를 새로 제기하면 종결 검토 회귀 |
| case-12-undecided-approach | approach.md 가 "없는 태그 판별" 접근법을 DELEGATED 로 남겼고 직접 범위에 precedent 도 없는데, 워커가 항목마다 선형 `contains` 를 골라 DONE 보고. 동작·테스트는 문서대로 | REQUEST_CHANGES / **DOC_GAP** / UNDECIDED_APPROACH / DIRECT_MISMATCH — 동작이 맞다는 이유로 APPROVE 하거나 "Set 이 더 좋다"를 required_outcome 에 적으면 회귀 |
| case-13-reuse-ignored-parallel-repository | approach.md 결정 1 이 `REUSE findOrThrow` 로 정해졌는데 워커가 같은 조회 책임의 중첩 `ClientSummaryRepository` 를 새로 만들어 summary 가 그것을 호출. 동작·테스트는 문서대로 | REQUEST_CHANGES / FIX_CODE / CONTRACT_VIOLATION 또는 REDUNDANT_CODE — 동작이 맞다는 이유로 APPROVE 하면 회귀 |
| case-11-fixer-out-of-scope | 수정자가 R-01(마스킹 재구현)을 고치면서 request.md 제외 대상인 `MaskingUtil.java` 까지 변경 | **Round 2 REQUEST_CHANGES** / OUT_OF_SCOPE_CHANGE / origin FIX_REGRESSION 또는 NEWLY_EXPOSED_BY_FIX |
| case-14-convention-dto-transform-violated | conventions.md 규칙 2(응답 DTO 는 값만, 변환은 서비스)를 implementation.md 는 반복하지 않음. DTO 형태는 DELEGATED 인데 `ClientSummary.from(Client)` 가 `MaskingUtil` 을 호출해 변환 책임을 DTO 로 옮김. 동작·테스트는 문서대로 | REQUEST_CHANGES / FIX_CODE / **CONTRACT_VIOLATION** / DIRECT_MISMATCH — 동작이 맞거나 DELEGATED 라는 이유로 APPROVE 하면 회귀 |
| case-15-convention-dto-transform-kept | case-14 와 같은 conventions.md·문서, 코드는 case-06(서비스가 마스킹, DTO 는 값만) | APPROVE — 서비스가 getter 셋을 읽어 DTO 를 조립하는 것을 규칙 4(Tell, Don't Ask)로 막으면 회귀 |
| case-16-convention-map-batch-bypassed | approach.md 결정 2(REQUIRED: `DiffUtil.diff` 로 얻은 Map 을 `writeAll` 에 한 번 전달)와 규칙 4(Map 기반 일괄 처리)가 있는데 서비스가 필드별 비교·개별 `write` 를 직접 나열. 동작·테스트는 문서대로 | REQUEST_CHANGES / FIX_CODE / CONTRACT_VIOLATION 또는 REDUNDANT_CODE (issue 1개 — 결정 2 하나의 위반) |
| case-17-round2-map-batch-moved-to-private | Round 1 R-01(위 위반, 고정 `prev-review.json`)을 수정자가 ACCEPT 하며 같은 필드별 나열을 private `collectChanges` 로 옮겨 Map 에 담고 `writeAll` 호출. `DiffUtil.diff` 는 여전히 미사용 | **Round 2 REQUEST_CHANGES** / FIX_CODE / origin **UNRESOLVED_PREVIOUS**(R-01) — Map 선언·private 이동·writeAll 호출로 해결됐다고 보면 회귀 |
| case-20-convention-map-batch-kept | case-16 과 같은 문서. `DiffUtil.diff(before.fields(), update.fields())` 로 얻은 Map 을 `writeAll` 에 한 번 전달하고 `Client.apply` 로 저장 | APPROVE — 한 번 쓰는 지역 변수 `changes` 나 `fields()` getter 호출을 이유로 막으면 회귀 |
| case-18-convention-raw-request-below-boundary | 규칙 3(Parse, Don't Validate: 경계에서 불변 VO 로 변환, 아래에 `*Request`·raw Map 금지)이 있고 결정 3(전달 형태)은 DELEGATED. 서비스가 검증 뒤 mutable `ClientUpdateRequest` 를 `Client.updated` 에 그대로 전달 | REQUEST_CHANGES / FIX_CODE / **CONTRACT_VIOLATION** / DIRECT_MISMATCH |
| case-19-convention-parsed-vo-with-internal-map | case-18 과 같은 문서. `ClientPatch.parse` 가 경계에서 검증과 동시에 불변 VO(내부는 unmodifiable Map)를 만들고 `Client.updated(ClientPatch)` 만 받음. 결정 3 이 NEW 를 허용 | APPROVE — VO 내부의 Map 이나 VO 신설을 이유로 막으면 회귀 |

## Round 2 사례의 실행 방식

한 번의 `impl-review-loop.sh` 프로세스 안에서 Round 1 → 수정자 → Round 2 가 진행된다(`MAX_IMPL_ROUNDS=1`). 스크립트가 만든 가짜 claude 가 첫 호출(리뷰어 Round 1)에 `prev-review.json`을 그대로 출력하고, 두 번째 호출(수정자)에 `fixed/`를 덮어쓰고 `decisions-round1.md`를 기록한 뒤, 세 번째 호출부터 실제 리뷰어가 돈다. 대조 대상은 `reviewer-round-02.json`이다. 러너는 origin 의 형식과 참조 대상 존재(직전 이슈 id, 수정 diff 에 실제로 바뀐 파일)만 검증하므로, Round 2 에 issue 가 나오면 `fix-diff-round-02.patch`와 사람이 대조해 fix_ref 가 정말 그 문제의 원인인지 본다.

## 결과 해석

기대 결과는 `통과 20 / 실패 0`이다. 실패는 세 부류로만 나눈다.

- 스크립트가 exit 1로 끝남 → 하네스·설정·스키마 또는 리뷰어 출력 형식 문제(근거·연계 필드 검사 포함). 프롬프트 감도 문제가 아니다.
- 정상 종료인데 `[DIFF]` → 실제 리뷰어 판정 감도 문제. 그 사례가 드러낸 입장 조건·"issue 가 아닌 것" 문장만 최소 수정한다.
- case-10 Round 2 가 REQUEST_CHANGES → 수정 diff 와 issue 의 인과관계를 수동 확인한다.
- case-14~19 의 `[DIFF]` 는 컨벤션 판정 감도 문제다(리뷰어 프롬프트의 "컨벤션 검사 기준" 절과 CONTRACT_VIOLATION 정의). 컨벤션이 없는 case-01~13 이 함께 흔들리면 컨벤션 절이 규칙 없는 프로젝트에도 새고 있는 것이다.

실행 전에 프롬프트나 스키마를 더 보강하지 않는다. 기대와 다른 사례가 나왔을 때만 손댄다. 판정이 기대와 다르면 개별 픽스처를 늘리지 말고 리뷰어 프롬프트 문구를 **최소로** 고친다. 사례 추가는 실제로 틀린 판정이 나온 상황에만 한다.
