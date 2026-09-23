# 워커 code-spec 충실도 회귀 세트

검증자·리뷰어 회귀는 "문서를 어떻게 판정하는가"를 본다. 이 세트는 다른 질문 하나만 묻는다 — **현재 `WORKER_MODEL` 이 합의된 code-spec(implementation.md + approach.md)을 그대로 코드로 옮기는가.** 평가 대상은 워커 하나뿐이다. 디자이너·검증자·리뷰어·수정자는 호출하지 않고, 결과 판정에 LLM 을 쓰지 않는다(리뷰어로 채점하지 않는다). 워커가 실패하거나 잘못된 UNDECIDED 를 내면 그대로 FAIL 이며 재호출·수정자 없음.

```bash
touch .claude/ALLOW_REAL_LLM_REGRESSION          # 유료 실행 1회 승인 (사용자 지시 후에만). 없으면 워커 호출 0회, exit 3
bash tests/worker-regression.sh                  # 전 사례 (사례당 실제 워커 호출 1회)
bash tests/worker-regression.sh case-05-batch-diff
WORKER_REGRESSION_DIR=_workspace/wr bash tests/worker-regression.sh   # 작업 디렉터리 고정 (실행마다 run.XXXXXX 하위)
```

## 흐름

```text
fixture 준비(temp 저장소: install.sh + 실제 config.sh 복사, base/ 커밋, .agent-work/ 문서)
→ production 워커 stage 전제(scope lock · units lock · worker-baseline.tree · units/<id>/unit.json·scope.json·before.tree · implementation-context.json)
→ scripts/worker-invoke.sh 의 run_worker 로 실제 WORKER_MODEL 1회 (prompts/worker-unit.md, WORKER_RULES, REFERENCE CODE, 스키마, CLI 라우팅, usage.jsonl, 사후 게이트 전부 production 그대로)
→ units/<id>/worker-result.json + worker-before.tree / worker-after.tree + diff.patch
→ deterministic assertion (expected.json + assert.py)
→ PASS/FAIL
```

`run_worker` 는 feature-run.sh 안에 있던 함수를 본문 그대로 `scripts/worker-invoke.sh` 로 옮긴 것이다(feature-run.sh 가 source). 테스트용 워커 구현·프롬프트·CLI 인자 복제는 없다 — 실행 파일만 `real-claude`/`real-codex` 래퍼(중첩 세션 차단 변수 `CLAUDECODE` 해제, 인자 그대로 통과)로 감싼다. codex 워커의 service tier 는 production 호출이 플래그를 넘기지 않으므로 codex 전역 설정(`~/.codex/config.toml` 의 `service_tier`)이 그대로 상속되며, 시작 출력의 `Worker fast tier` 는 그 값을 관측해 보고만 한다.

## 실행 전제

- `WORKER_MODEL`, `WORKER_EFFORT`, `CLAUDE_BIN`/`CODEX_BIN` 은 실제 값. `TEST_CMD`·`LINT_CMD` 는 복사본에서 `true` 로 바꾸므로 원본에 `CHANGE_ME` 여도 된다.
- `javac`/`java`(JDK 17 이상), `python3`, `jq`, `uuidgen`, `envsubst`, `git`. 픽스처는 외부 라이브러리 없이 컴파일된다(`base/run-tests.sh` = javac + main 기반 테스트).
- Claude Code 세션 안에서 돌려도 된다(래퍼가 중첩 차단 변수를 지운다).
- 시작 출력 `Worker CLI / Worker model / Worker effort / Worker fast tier` 로 어느 워커를 검증했는지 바로 확인한다. 검증자·리뷰어 모델 정보는 섞지 않는다.

## 픽스처 구조 (`tests/worker-cases/case-*/`)

| 경로 | 내용 |
|---|---|
| `base/` | HEAD 로 커밋되는 기존 코드: `src/*.java`, `src/test/*Test.java`(main + `check(...)` 방식), `run-tests.sh`, `.gitignore`(build/·.agent-work/·.claude/·.codex/), 필요한 사례만 `conventions.md`(설치된 config.sh 의 `CONVENTIONS_FILE` 이 그대로 집는다) |
| `.agent-work/` | 합의 완료로 취급하는 입력: request.md · design.md · implementation.md · approach.md · feature-scope.json · implementation-units.json(**unit 정확히 1개**, `targeted_test` = `bash run-tests.sh ClientServiceTest`). 검증자 재합의는 돌리지 않는다 |
| `expected.json` | `expected_status`(DONE\|UNDECIDED) · `expected_exit`(0 DONE \| 2 UNDECIDED — direct `run_worker` 는 DOC_GAP/USER_DECISION 모두 NEED_USER) · `undecided_kinds` · `allowed_new_files`(호출 전후 tree 의 A 경로는 이 목록 안에서만) · `files_must_exist` / `files_must_not_exist` · `must_contain` / `must_not_contain`(파일 → ERE 목록, 원문 기준) · `run_targeted_test` |
| `assert.py` | 사례별 구조 검사. `lib/javacheck.py` 가 주석·문자열을 제거하고 공백을 정규화한 뒤 메서드 집합(`methods`/`private_methods`)·타입 선언·메서드 본문·호출 순서(`order`)·지역 변수 선언 이름(`locals_declared`)·분기 토큰(`branches`)·호출 전 tree 대비 신규 파일(`added_files`)을 준다. formatter·import 순서 차이에 영향받지 않는다 |

픽스처 문서와 코드에 기대 답("helper 를 만들면 실패" 같은 힌트)을 적지 않는다 — 문서는 production 에서 검증자를 통과한 code-spec 과 같은 형태(REQUIRED/DELEGATED, 참조 `path:L<from>-L<to>`, pseudocode blueprint, 제어 흐름 절)로만 쓴다. approach.md 의 줄 범위 인용은 `load_reference_code` 가 워커 프롬프트에 붙이므로 base/ 의 실제 줄과 일치해야 한다.

## 판정 방식

1. 종료 코드와 `worker-result.json` 의 `status` 가 기대와 같아야 한다(direct run_worker 계약: 0 DONE / 2 NEED_USER(UNDECIDED — DOC_GAP 포함·범위 위반·결과 불확실) / 1 ENV_ERROR. 상위 feature-run 이 DOC_GAP 을 APPROACH_GAP/NEED_DOCS(exit 3)로 바꾸는 것과 혼동하지 않는다). 범위 위반·index 변경·결과 불확실은 production 게이트가 잡아 exit 2/1 이 되고 그대로 FAIL 이다.
2. 기대 `undecided[].kind` 존재, 신규 파일 허용 목록, 파일 존재/부재, 정규식 포함/미포함.
3. DONE 사례는 unit 의 `targeted_test`(컴파일 + 행동 테스트) 통과. **통과는 필요조건이지 판정이 아니다** — 컴파일·테스트가 성공해도 아래 assert.py 가 code-spec 위반을 잡으면 FAIL.
4. `assert.py` — 문서가 정한 것만 본다: 참조 구조 복제, 지정 symbol 호출, helper 없음, 지역 변수 이름, 호출 순서, 문서에 없는 분기·fallback 없음, batch 사양의 필드별 분해 없음, NEW 구조물의 정확한 형태.

특정 워커 모델에 맞춰 expected 를 느슨하게 하지 않는다. 판정이 틀렸다고 보이면 harness 를 고치되, 골든 산출물(문서 blueprint 그대로 옮긴 코드)이 8/8 통과하고 오답(helper 추출·인라인 재구현·필드별 나열·DTO 발명)이 정확히 FAIL 하는지 mock 워커로 먼저 확인한다.

## 사례

case-01·02·04·06·07 은 같은 도메인(`Client`/`ClientRepository.findById`/`findOrThrow`)의 다른 요구이고, case-03·08 은 태그 한 줄(`tagLine`) 요구를 helper 금지 / NEW 명시로 대조한 쌍이다. case-05 는 리뷰어 case-16~20 의 변경 이력 피처(`DiffUtil`·`ChangeLogWriter`·`conventions.md`)를 워커 입장에서 다시 묻는다.

| 사례 | 문서가 정한 것 | 검사 | 기대 |
|---|---|---|---|
| case-01-reference-structure | `summary` 는 참조 `profile`(L10-L13)의 두 줄 구조 복제 — 지역 변수 `client` 하나, `findOrThrow` → `return new ClientSummary(…, MaskingUtil.maskPhone(client.phone()))`, helper 없음. pseudocode 명시 | 본문이 blueprint 와 정규화 후 동일 · 호출 순서 · 지역 변수 == [client] · 분기 0 · 메서드 집합 == base+summary · private helper 없음 · 새 파일 없음 · 기존 profile 불변 | DONE |
| case-02-reuse-utility | `exportLine` 은 REUSE `MaskingUtil.maskPhone` 을 연결식 안에서 직접 호출, 마스킹 규칙 재구현·지역 변수·helper·format/join/StringBuilder 금지 | `MaskingUtil.maskPhone(client.phone())` 정확히 1회 · `****`/substring/repeat/replace/charAt/format/join/StringBuilder 없음 · 지역 변수 == [client] · 분기 0 · 메서드 집합 · MaskingUtil 불변 | DONE — 동작만 맞고 인라인 재구현이면 FAIL |
| case-03-no-helper-extraction | `tagLine` 본문에 for-each·StringBuilder blueprint 그대로, **별도 private helper·helper class·stream/join 금지**, 지역 변수 `client`/`line`/순회 `tag` | for-each·append·구분자 if 가 tagLine 본문 안에 · 지역 변수 == [client, line, tag] · if 1개뿐 · 메서드 집합 == base+tagLine · private helper == base · 새 타입·새 파일 없음 · stream/join/Collectors 없음 | DONE — 기능 동일한 `joinUpper` 추출이면 FAIL (리뷰어 case-21 과 같은 계약을 워커 단계에서 직접 본다) |
| case-04-local-naming | `rename` 은 참조 `changePhone`(L10-L15)의 네 줄 구조, 지역 변수 이름 `client`·`renamed` 를 문서가 지정(`existing`/`found`/`entity`/`updated`/`result` 금지, 인라인 금지) | 지역 변수 == [client, renamed] · 네 줄 각각 존재 · 순서 · 분기 0 · 메서드 집합 · changePhone 불변 · 새 파일 없음 | DONE — 이름만 달라도 FAIL |
| case-05-batch-diff | `update` = `findOrThrow` → `DiffUtil.diff(before.fields(), update.fields())` 를 지역 변수 `changes` 에 → `changeLogs.writeAll(id, changes)` **1회** → `before.apply(update)` → `repo.save(after)` → 반환. 필드별 비교·개별 FieldChange/ChangeLog 생성·개별 write·별도 수집 금지(conventions.md 규칙 3) | diff 호출 1회 · writeAll 이 ClientService 전체에서 정확히 1회 · `.write(` 0 · `==`/`!=`/`.equals(`/`Objects.equals` 0 · `new FieldChange(`/`new ChangeLog(`/`put(`/`add(` 0 · 지역 변수 == [before, changes, after] · 순서 · 분기/루프 0 · private helper 없음 · DiffUtil/ChangeLogWriter/Client/ClientUpdate 불변 | DONE — 테스트가 통과하는 필드별 `if … changes.put(…)` 나열이면 FAIL (**실제 Luna 에서 가장 문제였던 유형**) |
| case-06-call-order | `publishProfile` = lookup → transform(`new ClientProfile(client.id(), client.name())`, 기존 `profile(id)` 호출 금지) → `publisher.publish(profile)` 1회 → `return profile`. null 검사·조건부 발행·try/catch·재시도·로깅 금지 | 네 호출의 순서 · publish 1회 · `profile(id)` 미호출 · 지역 변수 == [client, profile] · 분기/try/null/ternary 0 · 메서드 집합 · profile 불변 · 새 파일 없음 | DONE |
| case-07-doc-gap-no-new-decision | `summary` 가 id·name·maskedPhone 요약을 반환해야 하는데 approach.md 에 반환 구조(DTO NEW/record/기존 타입) 결정이 없다. scope 는 `new_file_roots: ["src/"]` 로 워커가 만들 수는 있게 열어 둔다 | status UNDECIDED · `undecided[].kind` 에 DOC_GAP(USER_DECISION 아님) · 새 파일 0 · ClientService 에 `summary`·새 타입·새 메서드 없음 | UNDECIDED / exit 2 — DTO 를 발명해 DONE 이면 FAIL. 워커 계약상 그 부분은 손대지 않는다 |
| case-08-explicit-new | 결정 2 가 NEW `src/TagFormatter.java` 를 정확히 지정: `public final class`, private 생성자, `public static String joinUpper(java.util.List<String> tags)` 하나(지역 `line`, 순회 `tag`), 인터페이스·오버로드·추가 유틸 금지. `tagLine` 은 두 줄로 `TagFormatter.joinUpper(client.tags())` 반환 | 신규 파일 == {src/TagFormatter.java} · 타입 == {TagFormatter} · final + private 생성자 · 메서드 == {joinUpper} · signature 정규화 일치 · joinUpper 본문 blueprint(for-each·append, 지역 변수 [line, tag], null/stream 없음) · tagLine 본문 == blueprint · ClientService 메서드 집합·private helper·타입 불변 · ClientService 에 for/stream/join/StringBuilder 없음 · TagFormatterTest 미생성 | DONE |

## 결과 해석

- `[OK]` 는 위 판정을 전부 통과한 것. `[FAIL]` 은 첫 줄에 첫 실패, 이어서 나머지 실패·실제 status/exit/undecided·`diff.patch`·temp 저장소 경로를 낸다. temp 저장소는 지우지 않는다: `run.log`(전제 준비 + run_worker 로그), `.agent-work/units/<id>/worker-<stamp>.log`(워커 원문 출력), `worker-result.json`, `worker-before.tree`/`worker-after.tree`, `targeted-test.log`, `assert.log`.
- 마지막에 사례별 usage 행(production `usage.jsonl` 을 모은 것 — codex 는 `tokens_total` 만, claude 는 input/output/cost/duration)과 합계, harness 가 잰 wall-clock 을 낸다. 새 telemetry 체계는 없다.
- `expected exit=… / actual exit=2` 는 워커가 unit scope 밖을 고쳤거나(UNIT_SCOPE_VIOLATION) index/manifest/baseline 을 건드렸거나 결과 없이 변경만 남긴 것이다 — 모두 production 게이트가 잡는 워커 계약 위반이므로 FAIL 이 맞다.
- 사례를 늘릴 때(overload/reference pattern, switch/if/loop 형태 지정, direct return 에 alias 금지, convention + code-spec 동시, implementation-context REUSE fact, 앞 unit symbol 재사용, defensive fallback 금지)도 같은 규칙이다: unit 하나, 작은 diff, base/ 가 컴파일되고 `run-tests.sh` 가 통과하며, 판정은 expected.json + assert.py 로만.
