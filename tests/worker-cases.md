# 워커 material-contract 충실도 회귀 세트

검증자·리뷰어 회귀는 "문서를 어떻게 판정하는가"를 본다. 이 세트는 다른 질문 하나만 묻는다 — **현재 `WORKER_MODEL` 이 합의된 material contract(implementation.md + approach.md)를 지키면서 local implementation expression 은 스스로 정하고, 새 standalone 구조물을 만들지 않으며, material 공백에서만 DOC_GAP 을 내는가.** 평가 대상은 워커 하나뿐이다. 디자이너·검증자·리뷰어·수정자는 호출하지 않고, 결과 판정에 LLM 을 쓰지 않는다(리뷰어로 채점하지 않는다). 워커가 실패하거나 잘못된 UNDECIDED 를 내면 그대로 FAIL 이며 재호출·수정자 없음.

```bash
touch .claude/ALLOW_REAL_LLM_REGRESSION          # 유료 실행 1회 승인 (사용자 지시 후에만). 없으면 워커 호출 0회, exit 3
bash tests/worker-regression.sh                  # 전 사례 (사례당 실제 워커 호출 1회)
bash tests/worker-regression.sh case-05-batch-diff
WORKER_REGRESSION_DIR=_workspace/wr bash tests/worker-regression.sh   # 작업 디렉터리 고정 (실행마다 run.XXXXXX 하위)
```

## 흐름

```text
fixture 준비(temp 저장소: install.sh + 실제 config.sh 복사, base/ 커밋, .agent-work/ 문서)
→ impl consensus PASS 전제: production consensus-loop.sh 를 가짜 검증자(PASS)로 1회 돌려 consensus-impl.json 을 만든다(실제 검증자 0회 — run_worker 의 DOC_GAP 체크포인트가 impl_docs_accepted 를 요구하므로 필수)
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
| `assert.py` | 사례별 material 검사. `lib/javacheck.py` 가 주석·문자열을 제거하고 공백을 정규화한 뒤 메서드 집합(`methods`/`private_methods`)·타입 선언·메서드 본문·호출 순서(`order`)·분기 토큰(`branches`)·호출 전 tree 대비 신규 파일(`added_files`)을 준다. formatter·import 순서 차이에 영향받지 않는다. `locals_declared` 는 남아 있지만 v15 사례는 지역 변수 이름을 판정하지 않는다 |

픽스처 문서와 코드에 기대 답("helper 를 만들면 실패" 같은 힌트)을 적지 않는다 — 문서는 production 에서 검증자를 통과한 material contract 와 같은 형태(REQUIRED/DELEGATED, 참조 `path:L<from>-L<to>`, 제어 흐름 절, helper·local 이름·pseudocode 없음)로만 쓴다. approach.md 의 줄 범위 인용은 `load_reference_code` 가 워커 프롬프트에 붙이므로 base/ 의 실제 줄과 일치해야 한다.

## 판정 방식

1. 종료 코드와 `worker-result.json` 의 `status` 가 기대와 같아야 한다(direct run_worker 계약: 0 DONE / 2 NEED_USER(UNDECIDED — DOC_GAP 포함·범위 위반·결과 불확실) / 1 ENV_ERROR. 상위 feature-run 이 DOC_GAP 을 APPROACH_GAP/NEED_DOCS(exit 3)로 바꾸는 것과 혼동하지 않는다). 범위 위반·index 변경·결과 불확실은 production 게이트가 잡아 exit 2/1 이 되고 그대로 FAIL 이다.
2. 기대 `undecided[].kind` 존재, 신규 파일 허용 목록, 파일 존재/부재, 정규식 포함/미포함.
3. DONE 사례는 unit 의 `targeted_test`(컴파일 + 행동 테스트) 통과. **통과는 필요조건이지 판정이 아니다** — 컴파일·테스트가 성공해도 아래 assert.py 가 material 위반을 잡으면 FAIL.
4. `assert.py` — material 항목만 본다: 지정 symbol 재사용·인라인 재구현 없음, 상태 변경 순서, batch 사양의 필드별 분해 없음, 문서에 없는 분기·fallback 없음, 새 파일·새 타입·새 public 메서드 없음, NEW 구조물의 public 계약. **지역 변수 이름·같은 클래스 안의 private helper·for/stream·문자열 조립 표현은 판정하지 않는다** — 워커 소유 local expression 이다.

특정 워커 모델에 맞춰 expected 를 느슨하게 하지 않는다. 판정이 틀렸다고 보이면 harness 를 고치되, 골든 산출물(material contract 를 지킨 단순 구현 — helper 를 뺐든 안 뺐든)이 통과하고 오답(인라인 재구현·필드별 나열·DTO/helper class 발명·local 선택으로 DOC_GAP)이 정확히 FAIL 하는지 mock 워커로 먼저 확인한다.

## 사례

case-01·02·04·06·07 은 같은 도메인(`Client`/`ClientRepository.findById`/`findOrThrow`)의 다른 요구이고, case-03·08 은 태그 한 줄(`tagLine`) 요구를 "helper class 없음 / NEW 명시" 로 대조한 쌍이다. case-05 는 리뷰어 case-16~20 의 변경 이력 피처(`DiffUtil`·`ChangeLogWriter`·`conventions.md`)를 워커 입장에서 다시 묻는다.

| 사례 | 문서가 정한 것 | 검사 | 기대 |
|---|---|---|---|
| case-01-material-contract-only | `summary` 는 REUSE `findOrThrow` · REUSE `MaskingUtil.maskPhone` · 기존 `ClientSummary` 반환. helper·local 이름·줄 구조는 적지 않음 | findOrThrow 1회 · maskPhone 호출 · 마스킹 재구현 없음 · ClientSummary 생성 · 방어 분기 0 · public 메서드 == base+summary · 새 타입·새 파일 없음 · profile·ClientSummary 불변 | DONE — local 미명세를 이유로 DOC_GAP 을 내면 FAIL |
| case-02-reuse-utility | `exportLine` 은 REUSE `MaskingUtil.maskPhone`, 마스킹 규칙 재구현 금지, 새 포매터 class 없음 | `MaskingUtil.maskPhone(` 정확히 1회 · `****`/substring/repeat/replace/charAt 없음 · 방어 분기 0 · public 메서드 집합 · 새 파일 없음 · MaskingUtil 불변 | DONE — 동작만 맞고 인라인 재구현이면 FAIL. 연결식/format/join/StringBuilder 선택은 자유 |
| case-03-no-helper-class | 순회·대문자화·연결은 `ClientService` 안에서, **새 helper class·새 파일·shared helper 금지**(같은 클래스 private helper·for/stream 은 자유) | findOrThrow 1회 · toUpperCase 가 ClientService 안에 · try/null 방어 0 · public 메서드 == base+tagLine · 새 타입·새 파일 없음 | DONE — `TagFormatter` 같은 helper class 를 만들면 FAIL |
| case-04-local-naming-not-doc-gap | `rename` 은 조회 → `withName` 사본 → `repo.save` 1회 → 사본 반환. 지역 변수 이름·줄 구조는 적지 않음 | **status DONE(undecided 없음)** · 순서 · save 1회 · withName 1회 · 분기 0 · public 메서드 집합 · changePhone 불변 · 새 파일 없음 | DONE — 이름이 정해지지 않았다고 DOC_GAP 을 내면 FAIL(**v15 의 핵심 사례**) |
| case-05-batch-diff | `update` = `findOrThrow` → `DiffUtil.diff(before.fields(), update.fields())` → `changeLogs.writeAll` **1회** → `before.apply(update)` → `repo.save` → 반환. 필드별 비교·개별 FieldChange/ChangeLog 생성·개별 write 금지(conventions.md 규칙 3) | diff 호출 1회 · writeAll 이 ClientService 전체에서 정확히 1회 · `.write(` 0 · `==`/`!=`/`.equals(`/`Objects.equals` 0 · `new FieldChange(`/`new ChangeLog(` 0 · 순서 · 분기/루프 0 · public 메서드 집합 · 새 타입·새 파일 없음 · DiffUtil/ChangeLogWriter/Client/ClientUpdate 불변 | DONE — 테스트가 통과하는 필드별 `if … changes.put(…)` 나열이면 FAIL (**실제 Luna 에서 가장 문제였던 유형**) |
| case-06-call-order | `publishProfile` = lookup → transform(`new ClientProfile`, 기존 `profile(id)` 호출 금지) → `publisher.publish` 1회 → return. null 검사·조건부 발행·try/catch·재시도·로깅 금지 | 네 호출의 순서 · publish 1회 · `profile(id)` 미호출 · 분기/try/null/ternary 0 · public 메서드 집합 · profile 불변 · 새 파일 없음 | DONE |
| case-07-doc-gap-no-new-decision | `summary` 가 id·name·maskedPhone 요약을 반환해야 하는데 approach.md 에 반환 구조(DTO NEW/record/기존 타입) 결정이 없다 — 새 standalone production 타입은 material 이다. scope 는 `new_file_roots: ["src/"]` 로 워커가 만들 수는 있게 열어 둔다 | status UNDECIDED · `undecided[].kind` 에 DOC_GAP(USER_DECISION 아님) · 새 파일 0 · ClientService 에 `summary`·새 타입·새 메서드 없음 | UNDECIDED / exit 2 — DTO 를 발명해 DONE 이면 FAIL |
| case-08-explicit-new | 결정 2 가 NEW `src/TagFormatter.java` 의 public 계약을 지정: `public final class`, private 생성자, `public static String joinUpper(java.util.List<String> …)` 하나, 인터페이스·오버로드·추가 유틸 금지. 내부 표현은 정하지 않음. `tagLine` 은 `TagFormatter.joinUpper` 를 쓰고 ClientService 에 순회·연결 코드 없음 | 신규 파일 == {src/TagFormatter.java} · 타입 == {TagFormatter} · final + private 생성자 · public 메서드 == {joinUpper} · signature(파라미터 이름 자유) · null 방어 없음 · tagLine 이 findOrThrow → joinUpper · ClientService 에 toUpperCase/for/stream/join/StringBuilder 없음 · public 메서드·타입 불변 · TagFormatterTest 미생성 | DONE |

## 결과 해석

- `[OK]` 는 위 판정을 전부 통과한 것. `[FAIL]` 은 첫 줄에 첫 실패, 이어서 나머지 실패·실제 status/exit/undecided·`diff.patch`·temp 저장소 경로를 낸다. temp 저장소는 지우지 않는다: `run.log`(전제 준비 + run_worker 로그), `.agent-work/units/<id>/worker-<stamp>.log`(워커 원문 출력), `worker-result.json`, `worker-before.tree`/`worker-after.tree`, `targeted-test.log`, `assert.log`.
- 마지막에 사례별 usage 행(production `usage.jsonl` 을 모은 것 — codex 는 `tokens_total` 만, claude 는 input/output/cost/duration)과 합계, harness 가 잰 wall-clock 을 낸다. 새 telemetry 체계는 없다.
- `expected exit=… / actual exit=2` 는 워커가 unit scope 밖을 고쳤거나(UNIT_SCOPE_VIOLATION) index/manifest/baseline 을 건드렸거나 결과 없이 변경만 남긴 것이다 — 모두 production 게이트가 잡는 워커 계약 위반이므로 FAIL 이 맞다. case-01~06·08 에서 status UNDECIDED 는 워커가 local 선택을 DOC_GAP 으로 올린 것이며 v15 회귀다.
- 사례를 늘릴 때(N+1 vs batch 미정 → DOC_GAP, lock/retry 미정 → DOC_GAP, convention + material 동시, implementation-context REUSE fact, 앞 unit symbol 재사용, defensive fallback 금지)도 같은 규칙이다: unit 하나, 작은 diff, base/ 가 컴파일되고 `run-tests.sh` 가 통과하며, 판정은 expected.json + assert.py 로만 하되 local 표현은 판정하지 않는다.

**v15 실모델 회귀는 아직 실행하지 않았다.** v14 이전 골든(blueprint 그대로)은 여전히 통과해야 하고, 같은 클래스 private helper 를 추출한 변형도 통과해야 한다.
