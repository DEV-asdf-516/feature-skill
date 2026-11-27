# 러너 실행 · 종료 상태별 행동 · 재개 규칙

> feature 스킬 참조 문서(`SKILL.md` 에서 분리한 원문). 읽는 시점: 러너가 exit 2(`NEED_USER`)·exit 1(`ENV_ERROR`) 로 돌아온 직후 — 아래 "종료 상태별 행동" 에서 **그 reason 의 절 전체**를 읽고 그대로 따른다(reason 마다 `###` 절 하나). 사용자 답을 `decisions.md` 에 기록하거나 문서를 고쳐 재실행하기 직전에도 다시 읽는다(태그·scope·재합의 우회 조건). 본문의 "구현 문서 작성" 은 `references/impl-docs.md`, "Phase 0"/"Phase 2" 는 `references/phase0-design.md`/`references/done-finalize.md` 다.

## Phase 1 — 러너 실행

```bash
bash <skill_dir>/scripts/feature-run.sh --feature <id>
```

러너가 Phase 0 에서 확정한 worktree 로 들어가 `preflight → design → impl → worker → review → verify → done`을 연결한다. worker 는 전체 feature 를 워커 한 번에 맡기지 않고 `implementation-units.json` 의 구현 단위를 순서대로 직렬 실행한다(아래 "구현 단위 직렬 실행")
— unit 사이에는 review/verify 가 없고, 모든 unit 이 끝난 뒤 기존 전체 review(`impl-review-loop.sh`) 를 한 번, 이어서 verify(`TEST_CMD` → `LINT_CMD`, 실패하면 워커 수정 → 재리뷰) 를 기존과 같은 의미로 수행한다. 복잡도·중복·dead code 분석은 프로젝트가 `LINT_CMD`에 구성한다
— 프로젝트가 `FAST_CHECK_CMD`(선택)를 설정했으면 리뷰어를 부르기 직전마다 그 빠른 검사를 먼저 돌린다(계약·실행 시점·결과 처리는 `references/pipeline-contracts.md` 의 "프로젝트 빠른 검사", 미설정이면 생략 로그만 남는다)
— 같은 방식의 선택 검사가 둘 더 있다: `UNIT_CHECK_CMD`(unit 마다 targeted test 앞의 정적 검사)와 `RISK_VERIFY_CMD`(리뷰 승인 뒤 `TEST_CMD` 앞의 위험도별 추가 검증). 계약은 `references/pipeline-contracts.md` 의 "Unit 정적 검사 · 위험도별 추가 검증", 미설정이면 생략 로그만 남는다
— 스킬은 언어 독립이라 자체 코드 검사를 갖지 않고, 커버리지 % 게이트도 두지 않는다(숫자 채우기 테스트 유발). 실시간 로그 창(`feature-live`)은 러너가 연다 — **오케스트레이터는 `feature-live` 를 직접 실행하지 않는다.** 러너가 `.agent-work/.feature-live.lock/viewer.pid` 의 PID 생존으로 이미 열려 있는지 확인하고 절대 경로로 새 터미널을 연다.
열려 있는지 궁금하면 그 pid 파일만 본다(`kill -0 "$(cat .agent-work/.feature-live.lock/viewer.pid)"`). 사람이 수동으로 열 때만 절대 경로 `"$(git rev-parse --show-toplevel)/feature-live"` 를 쓴다(피처 worktree 에는 `feature-live` 가 gitignore 되지 않은 경우에만 snapshot 으로 복사된다
— 없으면 원본 저장소 루트의 파일을 worktree 로 `cd` 한 뒤 절대 경로로 실행한다). 진행은 피처 worktree 의 `.agent-work/live.log`와 `run-state.json`으로 관찰한다. **종료 코드로만 다음 행동을 정한다.**

## 종료 상태별 행동 (reason 마다 절 하나)

### `DONE` — exit 0

Phase 2 보고

### `DESIGN_MISSING` — exit 3 `NEED_DOCS`

Phase 0의 2·3 수행 후 재실행

### `IMPL_DOCS_MISSING` — exit 3 `NEED_DOCS`

설계 합의 완료. 아래 "구현 문서 작성" 후 재실행. `implementation-units.json` 이 없거나 스키마에 어긋나거나 unit scope 가 전체 범위 밖일 때도 이 reason 이며 `detail` 에 사유가 있다 — 고친 뒤 재실행하면 impl 재합의를 거친다

### `ASK_USER` — exit 2 `NEED_USER`

검증자가 문서 재작성으로 풀 수 없다고 판정(허용 범위 밖 공용 컴포넌트 수정 필요, 또는 제품 정책 선택). `state.json.review`의 해당 이슈 `user_question`과 `options`를 **그대로** 사용자에게 전달. 러너는 `user-escalation-resume-<stage>.json`(WAITING_USER
— 마지막 리뷰 경로·내용 해시·blocker 사본·발생 시점 지문)을 남긴다. **사용자 결정이 최종이다**: 그 리뷰의 **모든 blocker**(같은 리뷰에 섞인 `REVISE_DOC` 포함 — 묵시적으로 승인되지 않는다)마다 답을 `decisions.md` 에 **추가**한다 — `- [USER-QUESTION][scope=<stage>][escalation=<blocker id>] <질문·쟁점> → <답>`(stage 가 design 이면 `scope=design`, impl 이면
`scope=impl`. `<질문·쟁점>` 은 detail 의 문구 그대로 두고 `<답>` 을 실제 결정으로 바꾼다. 빈 답·`<답>` 같은 꺾쇠 플레이스홀더·다른 scope·다른 id·질문 문구가 그 blocker 와 다른 줄·태그 없는 줄은 답이 아니다) → 결정 내용을 그 단계 문서(design:
`design.md` / impl: `implementation.md`·`approach.md`)에 반영(**`ASK_USER` 는 필수** — 그 문서가 발생 시점과 같으면 답이 다 있어도 수리되지 않고 모델 0회로 다시 멈춘다. 러너는 변경 여부만 보며 내용이 결정과 일치하는지는 오케스트레이터 책임이다) → 재실행.
그러면 **그 단계의 검증자·디자이너를 다시 부르지 않고**(호출 0회) 다음 단계로 간다: design → impl(impl 합의는 정상 수행), impl → worker. 답이 없거나 일부만 있으면 모델 호출 0회로 같은 사유로 다시 멈춘다(detail 에 답 없는 blocker 목록). 이 상태는 `USER_RESOLVED` 이며 **검증자 PASS 가 아니다**
— `consensus-<stage>.json` 은 PASS 가 되지 않고 리뷰 JSON 의 BLOCK 도 그대로 남는다. review/verify/DONE 게이트는 그대로다

### `DEADLOCK` / `MAX_ROUNDS` — exit 2 `NEED_USER`

마지막 리뷰 JSON(`state.json.review`)의 쟁점만 사용자에게 보고하고 멈춘다(마지막 실제 리뷰와 blocker 는 `user-escalation-resume-<stage>.json` 에 보존된다). `ASK_USER` 와 같은 규칙이다: 마지막 리뷰의 모든 blocker 마다 `- [USER-QUESTION][scope=<stage>][escalation=<blocker id>] <쟁점> → <답>` 을 `decisions.md` 에 추가하고(design 단계면
`scope=design`, impl 단계면 `scope=impl` — 러너 detail 에 blocker id 와 써야 할 형식이 그대로 있다), 수용한 요구는 그 단계 문서에 반영한 뒤 재실행. 사용자가 검증자 요구를 **기각**한 경우도 같은 형식의 답이며 문서 변경 없이 기록만 하면 된다. 재실행은 그 단계의 검증자·디자이너를 다시 부르지 않고 다음 단계로 간다(`USER_RESOLVED`
— 검증자가 사용자 결정을 다시 심판하지 않는다. impl 의 `scope=impl` 결정은 design PASS 를 깨지 않는다). `consensus-*.json`·`user-escalation-resume-*.json` 지문 재계산·리뷰 JSON 수정 같은 수동 복구는 없다. **이 우회가 성립하지 않는 경우**(종전 규칙대로 Round 1 부터 재합의):
대기 중 `request.md`·`conventions.md`·(impl) `design.md`·`feature-scope.json`·`implementation-units.json`·`scope=design` 결정·`decisions.md` 기존 줄을 바꿨거나, 검증 계약·체크포인트 버전이 바뀌었거나, 수리 뒤 문서·결정·범위를 **또** 바꾼 경우
— 에스컬레이션 체크포인트는 `SUPERSEDED` 로 남고 정상 재합의한다. 사용자 결정 없이 문서를 다시 써서 재검증받고 싶으면 `user-escalation-resume-<stage>.json` 을 치우고 재실행한다

### `UNDECIDED` — exit 2 `NEED_USER`

워커(unit 워커·review-gap 워커·verify 의 worker-fix)가 `undecided`를 냄 — `DOC_GAP`(제품 동작은 정해져 있는데 approach.md 에 그 material 결정만 빠짐)이든 `USER_DECISION`(어느 문서에도 없는 제품 정책)이든 **구현 시점에 워커가 정할 권한이 없는 material 선택이므로 둘 다 사용자 판단**이다(kind 는 진단 정보일 뿐, 정책은 같다).
러너는 `doc-gap-resume.json`(WAITING_USER, 발생 시점 source tree·문서 지문·pending gap 목록)을 남기고 멈춘다. 각 항목의 `decision_needed`·`options`·위치를 **그대로** 사용자에게 전달하고, 답을 `- [USER-QUESTION][scope=impl][worker-gap=<unit id>#<n>] <질문> → <답>`(태그는 detail 에 그대로 있다
— 같은 번호의 미결정이 앞서 있었으면 `#<n>@2` 처럼 `@N` 이 붙어 있으니 표기된 값 그대로 쓴다, 빈 답 불가)으로 기록 → 오케스트레이터가 그 결정을 `approach.md` 에 최소한으로 동기화 → 재실행. **검증자·디자이너(child DESIGNER)를 부르지 않는다** — 재실행은 impl 재합의 없이 같은 unit(완료된 앞 unit 은 건너뜀)부터 워커를 다시 돌린다

### `REVIEW_DOC_GAP` — exit 2 `NEED_USER`

리뷰어가 `DOC_GAP` issue(UNDECIDED_APPROACH 등)를 냄 — 구현 리뷰 시점에 드러난 미결정 solution shape. 같은 리뷰에 `FIX_CODE` 가 섞여 있어도 수정자를 먼저 돌리지 않고 리뷰 전체를 체크포인트한 뒤 돌아온다. `doc-gap-resume.json` / detail 의 issue id·`user_question`·`options`·basis/code refs·`impact` 를 **그대로** 사용자에게 전달(리뷰어는 우열을 고르지 않는다).
답을 `- [USER-QUESTION][scope=impl][review-issue=<issue id>] <질문> → <답>` 으로 기록 → `approach.md` 최소 동기화 → 재실행. tag 는 detail·`doc-gap-resume.json` 의 `gaps[].tag` 에 표기된 값을 **그대로** 쓴다:
리뷰어 issue id 는 리뷰마다 `R-01` 부터 다시 시작하므로, 그 tag 가 이미 쓰였으면(decisions.md·approach.md·앞선 해결 기록) 러너가 `review-issue=R-01@2` 처럼 `@N` 을 붙여 서로 다른 리뷰의 같은 id 를 구분한다 — 앞 gap 의 답 줄은 새 gap 의 답으로 인정되지 않는다.
**unit 이 `references` 로 가리키는 기존 approach.md 절을 고쳐 반영할 때는 그 절 본문에 gap tag `[review-issue=<issue id>]` 를 적는다**(새 절을 추가하는 반영은 해당 없음) — 러너는 tag 가 적힌 절 변경만 그 gap 의 해결로 인정하고, 표시 없는 절 변경은 `DOC_GAP_SCOPE_EXCEEDED` 로 멈춘다.
gap 과 무관한 절은 이 경로에서 고치지 않는다. 재실행은 검증자·디자이너·impl 재합의 없이 **review-gap 워커 1회**(`prompts/worker-review-gap.md`: DOC_GAP 은 사용자 결정 그대로 구현 + 같은 리뷰의 FIX_CODE 를 함께 해결, 새 설계 선택 금지, 기존 `run_worker` 의 scope/index/baseline/manifest/write-set 게이트 그대로) → 새 attempt 의 리뷰로 간다.
워커가 또 새 gap 을 내면 다시 `UNDECIDED` 로 돌아온다(자동 루프 없음)

### `DOC_GAP_SOURCE_CHANGED` — exit 2 `NEED_USER`

사용자 답을 기다리는 동안(또는 review-gap 워커 호출 직전, 또는 완료 기록된 review-gap 워커 결과를 재사용하려는데 현재 tree 가 그 after tree 와 다름, 또는 REVIEW_PENDING 재개인데 리뷰가 아직 진행되지 않은 상태에서 tree 가 그 after tree 와 다름
— 리뷰 루프가 이미 진행됐으면(수정자 등) tree 는 `review-impl.json` 의 지문이 판정한다, 또는 해결된 미결정을 전달하는 unit 워커 재개 턴 직전) source worktree 가 DOC_GAP 발생 시점 tree 와 달라짐. 기존 리뷰·워커 결과를 조용히 재사용하지 않고 멈춘다(자동 restore 없음).
`.agent-work` 의 decisions/approach 변경은 source 변경이 아니다. 사용자가 ① 그 tree 로 명시적으로 되돌리고 재실행하거나 ② 변경을 유지하려면 `doc-gap-resume.json` 을 치우고 재실행(새 리뷰 필요 — 이때 impl 지문이 stale 이면 impl 재합의를 거친다)

### `DECISION_SCOPE_REQUIRED` — exit 2 `NEED_USER`

`decisions.md`에 scope 없는 옛 형식 `- [USER-QUESTION] …` 줄이 있음(LLM 호출 전 preflight). 러너는 어느 단계의 결정인지 추정하지 않는다 — detail 의 행번호를 보고 사용자와 확인해 `[USER-QUESTION][scope=design]`(요구·외부 동작·설계에 영향) 또는 `[USER-QUESTION][scope=impl]`(구현 수단에만 영향) 로 고친 뒤 재실행.
이미 scope 가 붙은 과거 줄을 문구로 추정해 일괄 재분류하지 않는다

### `TEST_RETRIES_EXHAUSTED` / `APPROVAL_STALE_REPEATED` — exit 2 `NEED_USER`

로그(`reviews/verify-*.log`)와 상황을 정리해 사용자 보고 후 멈춘다

### `FAST_CHECK_RETRIES_EXHAUSTED` — exit 2 `NEED_USER`

프로젝트 빠른 검사(`config.sh` 의 `FAST_CHECK_CMD`, 계약은 `references/pipeline-contracts.md` 의 "프로젝트 빠른 검사")가 규칙 위반(exit 1)을 보고했고, 워커 자동 수정 한도(`MAX_TEST_RETRIES`, 피처 누적 — 끝난 수정 턴만 센다) 뒤에도 위반이 남았다.
리뷰어는 호출되지 않았고(위반이 남은 코드는 리뷰로 가지 않는다) 승인도 없다. 추가 자동 수정은 없다.

- 진단: detail 의 `fast-check/check-NNNN.log`(검사 명령 출력 원본 — 규칙·파일·위치·내용), `fast-check/last.json`(명령·cwd·종료 코드·실행 시간·tree), `fast-check/history.jsonl`(이전 실행 전부), 워커 수정 결과 `check-fix-NN-result.json`.
- 사용자에게 진단을 그대로 보고한다. 복구는 사용자가 정한다: ① 위반을 feature-scope 범위 안에서 직접 고친다 ② 규칙이나 검사 명령이 틀렸으면 프로젝트의 검사 쪽을 고친다 ③ 규칙이 합의 문서·conventions 와 충돌하면 어느 쪽이 맞는지 정한다(문서를 바꾸면 기존 합의 규칙대로 재합의).
- 그 뒤 같은 명령으로 재실행하면 검사부터 다시 돈다 — 통과해야 리뷰로 가고, 여전히 위반이면 모델 호출 0회로 같은 사유로 멈춘다.
- 하지 않는 것: `run-state.json` 의 `fast_check_retries`·stage 수정, `fast-check/`·리뷰 체크포인트 삭제, 사용자 지시 없이 `FAST_CHECK_CMD` 를 비우기, 억제 주석으로 위반 숨기기.

워커 수정(`worker-check-fix.md`)이 낸 미결정은 이 reason 이 아니라 `UNDECIDED`, 범위 밖 수정은 `SCOPE_VIOLATION` 으로 온다(기존 절 그대로).
수정 턴이 도중에 중단됐거나 게이트에서 멈춘 뒤의 재실행은 러너가 `check-fix.pending.json` 으로 먼저 판정한다(모델·검사 호출 0회): 범위 밖 변경이 남아 있으면 다시 `SCOPE_VIOLATION`, 완료를 확인할 수 없는데 코드가 바뀌었으면 `WORKER_OUTCOME_UNCERTAIN` — 호출 전 tree(`check-fix-NN-before.tree`)로 되돌리거나 범위 밖 변경을 정리하는 것은 사용자가 한다. 그 턴이 미결정을 돌려줬는데 `doc-gap-resume.json` 이 남기 전에 중단됐으면 러너가 결과 JSON 에서 미결정을 다시 기록해 `UNDECIDED` 로 멈춘다(작업 트리가 그 턴의 호출 후 tree `check-fix-NN-after.tree` 와 다르면 기록하지 않고 `WORKER_OUTCOME_UNCERTAIN` — 그 tree 로 되돌린 뒤 재실행). 끝난 턴을 다시 확정해도 한도는 한 번만 센다. 사용자 결정 뒤 재실행은 검사 → 남은 한도 안의 수정 → 재검사 → 리뷰 순서다.

### `FAST_CHECK_ERROR` — exit 2 `NEED_USER`

프로젝트 빠른 검사를 끝까지 실행하지 못했다. 통과·생략·규칙 위반 어느 것도 아니다 — 리뷰어·수정자·워커를 부르지 않았고 자동 코드 수정도 없다(도구가 못 돈 것은 코드 수정으로 풀리지 않는다). detail 의 kind 로 원인을 구분한다.

- `COMMAND_NOT_RUNNABLE`(exit 126/127): 도구 누락·경로 오류·실행 권한 없음. 명령은 피처 worktree 루트에서 실행된다 — 상대 경로의 스크립트가 worktree 에 있는지(커밋됐는지) 확인.
- `TIMEOUT`: `FAST_CHECK_TIMEOUT_SEC`(기본 120초) 초과로 종료시켰다. 검사 범위를 줄이거나(`FAST_CHECK_CHANGED_FILES`) 제한을 조정.
- `UNEXPECTED_EXIT`: 0(정상)·1(위반) 이외의 종료 코드. `NO_DIAGNOSTICS`: exit 1 인데 출력이 비어 있어 고칠 대상을 알 수 없다. 둘 다 프로젝트 어댑터가 종료 코드 계약을 따르게 고친다.
- `INVALID_CONFIG`: `FAST_CHECK_TIMEOUT_SEC` 가 양의 정수가 아니다(명령은 실행되지 않았다).
- `WORKTREE_MODIFIED` / `INDEX_MODIFIED`: 검사가 읽기 전용 계약을 어기고 파일이나 git index 를 바꿨다(자동 수정·포매팅·`git add`). 변경은 **원복하지 않고 그대로** 있다 — `fast-check/last.json` 의 `modified_paths`·`out_of_scope_paths` 를 보고하고, 파일 변경을 되돌릴지 유지할지는 사용자가 정한다(자동 원복 금지). 명령에서 자동 수정을 뺀다. index 변경(`INDEX_MODIFIED`)은 index 가 검사 전 상태로 돌아오기 전에는 재실행이 검사 명령을 실행하지 않고 같은 사유로 다시 멈춘다 — 사용자 확인 뒤 직접 되돌린다.

원인을 고친 뒤 같은 명령으로 재실행하면 검사부터 다시 돈다(고치지 않은 재실행은 모델 호출 0회로 같은 사유). 검사가 바꾼 코드를 유지하면 그 코드는 재검사·재리뷰를 지난다 — 이전 승인은 지문이 달라 재사용되지 않는다. `FAST_CHECK_CMD` 를 비워 검사를 끄는 것은 사용자가 명시적으로 정할 때만 한다.

### `UNIT_CHECK_RETRIES_EXHAUSTED` / `UNIT_CHECK_ERROR` / `UNIT_CHECK_STALE_VIOLATION` — exit 2 `NEED_USER`

Unit 정적 검사(`config.sh` 의 `UNIT_CHECK_CMD`, 계약은 `references/pipeline-contracts.md` 의 "Unit 정적 검사 · 위험도별 추가 검증")에서 멈췄다. 세 경우 모두 그 unit 의 `done.json` 은 새로 확정되지 않았고 다음 unit·리뷰로 가지 않았다. detail 의 `units/<id>/unit-check/check-NNNN.log`(검사 출력 원본)와 `last.json` 을 사용자에게 보고한다.

- `UNIT_CHECK_RETRIES_EXHAUSTED`: 규칙 위반이 unit 수정 한도(`MAX_TEST_RETRIES`, targeted test 수정과 공유) 뒤에도 남았다(targeted test 는 통과). 추가 자동 수정은 없다. 사용자가 ① 위반을 unit scope 안에서 직접 고치거나 ② 규칙·검사 명령 쪽이 틀렸으면 프로젝트의 검사 설정을 고치거나 ③ 규칙이 합의 문서·conventions 와 충돌하면 어느 쪽이 맞는지 정한다. 그대로 재실행하면 모델 호출 0회로 같은 사유다. 검사 설정만 고쳤으면 검사부터, 코드를 직접 고쳤으면 기존 재개 규칙대로 그 unit 의 워커 턴부터 다시 돈다.
- `UNIT_CHECK_ERROR`: 검사를 끝까지 실행하지 못했다(통과·생략·위반 어느 것도 아니다 — 워커·테스트 호출 없음). kind 는 `FAST_CHECK_ERROR` 와 같다(`COMMAND_NOT_RUNNABLE`·`TIMEOUT`·`UNEXPECTED_EXIT`·`NO_DIAGNOSTICS`·`INVALID_CONFIG`·`WORKTREE_MODIFIED`·`INDEX_MODIFIED`). 원인을 고친 뒤 재실행하면 워커 재호출 없이 그 unit 의 검사부터 다시 돈다.
  `WORKTREE_MODIFIED` 는 검사가 파일을, `INDEX_MODIFIED` 는 git index 를 바꾼 것이다 — 변경은 원복되지 않고 남아 있으며, **검사가 만든 변경이 해소되기 전에 재실행하면 검사·모델 0회로 다시 멈춘다.** 해소 = 검사가 바꾼 경로(`last.json` 의 `modified_paths`)가 검사 전 내용(`tree_before`)으로 돌아오고 index 가 검사 전 상태로 돌아온 것이다. 다른 파일을 더 고치거나 검사 명령만 고치는 것은 해소가 아니다. 사용자 확인 뒤 그 경로·index 를 직접 되돌리고 명령에서 자동 수정·포매팅·`git add` 를 뺀다(자동 원복 금지 — detail 에 아직 남은 경로가 적힌다).
- `UNIT_CHECK_STALE_VIOLATION`: 이미 완료된 unit 이 **지금의 코드·지금의** `UNIT_CHECK_CMD` 로는 위반이다 — 완료 당시의 PASS 는 지금 상태에 대한 것이 아니다(detail 의 '재검증 사유': 완료 뒤 검사를 새로 켰거나 명령을 바꿈 / 검사 뒤 그 unit 의 코드가 바뀜 — 뒤 unit·수정자·worker-fix·수동 수정 / 검사 스크립트·규칙(`UNIT_CHECK_POLICY_PATHS` 로 선언한 경로 포함)이 바뀜). 수정자가 만든 위반이면 다음 리뷰어를 부르기 전에 멈춘 것이다. review·verify 진입에서 났으면 리뷰어·`TEST_CMD` 는 호출되지 않았다. 완료 체크포인트·뒤 unit 은 그대로이고 워커를 다시 부르지 않았다. 사용자가 ① 위반을 unit scope 안에서 직접 고치거나(재실행은 검사부터 — 통과하면 다음 단계로 가고 고친 코드는 전체 review 를 지난다) ② 설정·검사 스크립트 변경이 의도가 아니면 되돌린다.

하지 않는 것: `units/<id>/unit-check/`·`done.json`·`run-state.json` 을 지우거나 고쳐서 넘기기, 사용자 지시 없이 `UNIT_CHECK_CMD` 를 비우기, 억제 주석으로 위반 숨기기. 수정 턴이 낸 미결정은 `UNDECIDED`, unit scope 밖 수정은 `UNIT_SCOPE_VIOLATION` 으로 온다(기존 절 그대로).

### `RISK_VERIFY_RETRIES_EXHAUSTED` / `RISK_VERIFY_ERROR` / `RISK_VERIFY_NEEDS_USER` — exit 2 `NEED_USER`

리뷰 승인 뒤의 위험도별 추가 검증(`config.sh` 의 `RISK_VERIFY_CMD`)에서 멈췄다. 세 경우 모두 `TEST_CMD` 는 실행되지 않았고 `DONE` 이 아니다. detail 의 `risk-verify/check-NNNN.log`·`last.json`(`risk_level`·`checks`·`reasons`)을 사용자에게 보고한다.

- `RISK_VERIFY_RETRIES_EXHAUSTED`: 검증 위반이 워커 수정 한도(`MAX_TEST_RETRIES`, 최종 테스트 수정과 공유) 뒤에도 남았다. 사용자가 범위 안에서 직접 고치면(고친 코드는 재리뷰 → 재검증을 지난다) 또는 검증 명령 쪽을 고치면 같은 명령으로 재실행한다. 그대로 재실행하면 검증 1회·모델 0회로 같은 사유다.
- `RISK_VERIFY_ERROR`: 검증을 끝까지 실행하지 못했다 — 워커를 부르지 않았고 한도도 쓰지 않았다. kind 는 `FAST_CHECK_ERROR` 의 것에 `RESULT_INVALID`(exit 0 인데 `$RISK_VERIFY_RESULT` 결과 JSON 이 없거나 형식이 틀림 — `checks`·`reasons` 항목 형식 포함. 위험도를 LOW 로 가정하지 않는다)와 `RESULT_INCONSISTENT`(exit 0 인데 `checks` 에 `FAIL` 이 있음 — 통과도 코드 위반도 아니다: 실패한 검증이 있으면 exit 1 + 진단을 내도록 검증 명령을 고친다. 워커에게 코드를 고치게 하지 않는다)가 더해진다. 프로젝트 어댑터·환경을 고친 뒤 재실행. 검증이 소스를 바꿨으면(`WORKTREE_MODIFIED`) 되돌릴지는 사용자가 정하고, 범위 안 변경이 남으면 재리뷰를 지난다. 검증이 git index 를 바꿨으면(`INDEX_MODIFIED`) **index 를 검증 전 상태로 되돌리기 전의 재실행은 검증 명령·모델 0회로 다시 멈춘다** — 사용자 확인 뒤 직접 되돌린다(자동 복구 금지).
- `RISK_VERIFY_NEEDS_USER`: 검증 명령이 위험도를 판정하지 못했거나(`RISK_UNKNOWN`) 사람의 확인을 요구했다(`HUMAN_REVIEW_REQUIRED`). **위험도를 추측하거나 LOW 로 간주해 진행하지 않는다.** 판정 근거(`reasons`)와 실행한 검증(`checks`)을 그대로 보고하고 사용자 결정을 받는다 — 분류 규칙을 프로젝트 검증 명령에 추가하거나, 프로젝트가 정한 확인 절차를 사용자가 수행한 뒤 재실행한다.

하지 않는 것: 사용자 지시 없이 `RISK_VERIFY_CMD` 를 비우기, 결과 JSON·`risk-verify/` 기록·`run-state.json` 을 고쳐서 넘기기, 검증 명령·규칙을 워커에게 고치게 하기.

### `REVIEW_OUTPUT_INVALID` — exit 2 `NEED_USER`

리뷰어가 JSON 을 돌려줬지만 출력 계약(스키마 → 버전 → origin/`fix_ref` → DOC_GAP `code_refs` 경로 → verdict 일관성)에 어긋남. 승인도 수정 요청도 아니며 수정자는 호출되지 않았다. 원본 결과·이벤트 로그·invocation id·입력 지문·구조화 진단(`issue_id`/`field`/`observed`/`expected`/`rule_id`)이 `reviews/invalid-review.json` 에 남는다.
**그대로 재실행해도 리뷰어는 호출되지 않고 같은 진단이 나온다**(같은 프롬프트를 같은 세션에 재전송하지 않는다 — codex resume marker·미수용 세션을 지우거나 우회하지 않는다). detail 의 위반 목록을 사용자에게 보고하고, ① 검사기(impl-review-loop) 버그였으면 고치고 `scripts/lib/runtime.sh` 의 `REVIEW_CHECKER_VERSION` 을 올린 뒤 같은 명령으로 재실행(입력이 같으면 저장된 출력을 로컬 재검증
— 모델 0회. 입력에는 작업 트리·범위·직전 리뷰뿐 아니라 계약 문서 request/design/implementation/approach/decisions 의 내용도 들어간다 — 코드가 그대로여도 계약 문서가 바뀌었으면 재사용되지 않고 detail 이 달라진 문서를 알려 준다) ② 새 리뷰가 필요하면 사용자 승인 뒤 `--new-review-attempt` 를 붙여 재실행(새 attempt Round 1·새 세션, `--new` 아님).
`fix_ref` 를 추정으로 고쳐 넣지 않는다. 검사는 스키마 파일 전체(required·enum·minItems·minLength·정의되지 않은 필드)를 먼저 보고(`SCHEMA_INVALID`, 위반 필드마다 따로), 통과한 출력에만 조건부 필드 규칙을 적용한다

### `UNIT_CONTRACT_IMPACT_REQUIRED` — exit 2 `NEED_USER`

unit 계약의 영향 여부를 러너가 정할 수 없음(모델 0회): ① 완료된 unit 인데 전역 입력(request.md·conventions.md·unit 에 묶이지 않은 사용자 결정·references 에 절이 없는 design.md)만 바뀜 ② 계약 스냅샷이 없는 과거 산출물 ③ unit `references` 가 가리키는 절이 삭제·개명·중복됨.
①② 는 detail 의 대상 unit 을 사용자와 확인해 `.agent-work/unit-contract-impact.json` 에 `{"version":2,"target_fingerprint":"<detail·unit-contract-impact.request.json 의 값 그대로>","affected_units":[…],"unaffected_units":[…]}`(대상을 빠짐없이 한쪽에만)로 확정하고 재실행.
`target_fingerprint` 는 사용자가 본 계약(대상 unit 의 절 본문·전역 입력)의 지문이다 — 확정한 뒤 계약 문서가 또 바뀌면(합의 단계의 디자이너 수정 포함) 같은 파일은 적용되지 않고 모델 0회로 다시 멈추므로, 새 diff 를 사용자에게 다시 보여 주고 새 지문으로 다시 확정한다(값만 바꿔 끼우지 않는다).
지문 없는 version 1 은 거부된다 — `unaffected` 는 완료 체크포인트 유지, `affected` 는 그 unit 이 변경 계약으로 다시 돈다. ③ 은 heading 을 복구하거나 references 를 정확한 절로 고친다. 오케스트레이터가 임의로 '영향 없음'을 적지 않는다(각 unit 의 `global-impact.diff` 를 사용자에게 보여 준다)

### `UNIT_CONTRACT_STALE` — exit 2 `NEED_USER`

unit 완료 확정 직전 또는 review/verify/DONE 진입 직전에, 완료 체크포인트가 현재 계약(문서 절 본문·그 unit 의 사용자 결정·unit JSON)에 대해 유효하지 않음이 드러남(같은 실행 도중 문서·결정이 바뀐 경우). 이전 완료·승인은 재사용되지 않았다. 같은 명령으로 재실행하면 합의 상태를 다시 확인한 뒤 첫 stale unit 부터 `[CHANGED CONTRACT]` 를 받은 워커 턴 → targeted test 로 새 `done.json` 을 만든다

**실행 중 계약 문서 수정(예방과 복구)** — unit 계약 지문은 `references` 가 가리키는 절의 본문 그대로를 해시한다. 의미가 같은 문장 손질·메모 추가도 그 unit 을 stale 로 만들고, 뒤 unit 이 이미 완료돼 있으면 `UNIT_CHECKPOINT_CHAIN_STALE` 로 이어진다(의미 동등성은 판정하지 않는다 — 의도된 안전장치다).

- 측정 결과·관찰·진행 메모: **합의 문서 밖**의 별도 파일(`.agent-work/notes.md` — 어떤 지문에도 들어가지 않는다)에 적는다. 참조되지 않는 절에 적어도 unit 은 유지되지만, 합의 PASS 지문은 request/design/implementation/approach 문서 전체를 해시하므로 그 단계 검증자 재합의(유료 호출)가 돈다(빈 줄 하나도 같다).
- 고치기 전·고친 뒤 재실행 전: `feature-run.sh --feature <id> --contract-impact` 로 확인한다(모델·검사 명령 0회, run-state·체크포인트·합의 지문 불변 — 파일 시스템 전체가 불변인 것은 아니다: 계약 렌더링 파생물 `.agent-work/.unit-contract/` 를 갱신하고 `live.log` 에 출력을 덧붙이며 실행 동안 러너 락을 잡는다). 지금 문서 상태로 재실행하면 어느 합의가 무효가 되고 어느 unit 이 다시 실행되는지(바뀐 절·되돌릴 원문·뒤 unit 사슬), 진행된 unit 이 참조해 고치면 안 되는 절이 무엇인지 출력한다. 러너의 판정을 그대로 보여 줄 뿐 의미가 같은 변경인지는 판단하지 않는다. 기존 worktree 를 찾아 검증만 한다 — 부트스트랩하지 않고 누락된 안전 게이트 설정(`.codex`·`.claude/settings.json`·`.claude/hooks`)도 복사하지 않으며(`[주의]` 로 보고만), 실패해도 run-state 를 쓰지 않는다. run-state 가 이미 `DONE` 이면 일반 재실행은 합의·unit 을 다시 보지 않고 즉시 끝나므로, 출력의 `[DONE]` 줄대로 위 판정은 재실행 결과가 아니라 **문서 변경의 잠재적 영향**이다 — DONE 뒤 문서 변경은 재실행으로 구현에 반영되지 않는다(되돌리거나, 반영이 필요하면 사용자에게 알려 결정을 받는다).
- 참조 절을 실수로 고쳤다: 절 본문을 원래 내용으로 되돌리고 재실행 — 지문이 다시 맞아 완료 체크포인트가 그대로 쓰인다(워커 0회). 원문은 `units/<id>/contract/baseline/contract.txt` 에 있다.
- 구현 계약을 실제로 바꿔야 한다: 그 unit 과 뒤의 완료 unit 이 다시 실행된다. 고치기 **전에** 영향 unit·재실행 범위(`--contract-impact` 의 요약)를 사용자에게 알리고 결정을 받는다.
- 영향을 판단할 수 없다: 임의로 '영향 없음'으로 두지 않는다 — 재실행 비용을 알리고 사용자가 정한다.

계약 변경을 유지할 때만 뒤 unit 재실행이 필요하다. 자동으로 뒤 unit 을 다시 돌리거나 모델에게 변경의 무해성을 판정시키지 않는다.

### `SCOPE_MISSING` — exit 3 `NEED_DOCS`

`feature-scope.json` 이 없다. 아래 "구현 문서 작성" 3번대로 작성 후 재실행

### `FOREIGN_WORKTREE_CHANGE` — exit 2 `NEED_USER`

리뷰어가 `OUT_OF_SCOPE_CHANGE` 를 냄. **자동 원복하지 않는다** — 같은 working tree 의 다른 세션 변경일 수 있다. `state.json.review` 의 해당 이슈 파일 목록을 사용자에게 보여 주고, 사용자가 "워커 과잉 변경이라 되돌린다 / 다른 작업이라 보존하고 범위를 넓힌다" 를 결정한다.
파이프라인은 어느 쪽도 스스로 하지 않는다

### `SCOPE_VIOLATION` — exit 2 `NEED_USER`

워커·수정자 호출 전후 write-set 이 `feature-scope.json` 범위를 벗어남(`state.json.files`). 위와 같이 사용자 결정. 자동 원복 금지

### `SCOPE_MANIFEST_CHANGED` — exit 2 `NEED_USER`

`feature-scope.json` 이 워커 진입 시 확정한 `feature-scope.lock.json` 과 다르거나, 워커·수정자 호출 중 둘 중 하나가 바뀜(범위를 넓혀 검사를 우회하는 경로). 자동 복구 없음. 의도한 범위 변경이면 사용자가 lock 을 지우고 재실행(impl 재합의 → 새 lock), 아니면 원본을 lock 과 같게 되돌린다

### `SCOPE_BASELINE_CHANGED` — exit 2 `NEED_USER`

워커·수정자 호출 중 `worker-baseline.tree` 가 바뀜. 이 파일은 `new_file_roots` 아래 소유권 판정의 기준이라 바꾸면 기존 파일 보호가 풀린다(빈 tree 로 바꾸는 우회). 러너·루프는 호출 전에 읽은 값으로 판정하고 파일 변경은 자동 복구 없이 중단하며, 기대값을 `worker-baseline.guard.json` 에 남긴다(index·manifest 검사보다 먼저 기록하므로 다른 사유로 먼저 종료해도 가드는 남는다).
복구 전 재실행은 stage 와 무관하게 러너 진입 시 전역 검사에서 모델·테스트 호출 0회로 같은 사유로 다시 멈춘다(변조된 값을 새 기준선으로 읽는 우회, verify 의 worker-fix 중단 뒤 verify 재진입으로 DONE 이 되는 우회 차단). 사용자가 원래 값(`expected`)으로 되돌리고 워커·수정자 변경을 확인한 뒤 재실행

### `UNITS_MANIFEST_CHANGED` — exit 2 `NEED_USER`

`implementation-units.json` 이 워커 진입 시 확정한 `implementation-units.lock.json` 과 다르거나 unit 워커 호출 중 바뀜. 자동 복구 없음. 의도한 분할 변경이면 사용자가 lock 을 지우고 재실행(impl 재합의 → 새 lock, spec 이 그대로인 unit 의 완료 체크포인트는 유지), 아니면 원본을 lock 과 같게 되돌린다

### `UNIT_SCOPE_VIOLATION` — exit 2 `NEED_USER`

unit 워커가 전체 범위 안이지만 현재 unit 의 scope 밖 경로를 바꿈(`detail` 에 경로). 원복하지 않고 멈춘다 — 과잉 구현이라 되돌릴지, 분할이 잘못돼 `implementation-units.json` 을 고칠지(impl 재합의) 사용자가 정한다. 다음 unit 으로 가지 않는다

### `UNIT_CHECKPOINT_CHAIN_STALE` — exit 2 `NEED_USER`

다시 실행해야 하는 unit N 뒤에 완료 체크포인트가 있는 unit 이 있음(`detail` 에 목록과 N 의 `before.tree`). 뒤 unit 은 옛 N 결과 위에 작성됐고 그 코드가 worktree 에 남아 있으므로 spec_hash 가 그대로여도 재사용하지 않는다. 자동 원복·replay 없음
— 사용자가 worktree 를 N 의 `before.tree` 로 되돌리고 뒤 unit 의 `units/<id>/` 를 치운 뒤 재실행. N 이 다시 실행 대상이 된 이유가 참조 절의 의도하지 않은 수정이면, 그 절을 원래 내용으로 되돌리는 것만으로 풀린다(위 "실행 중 계약 문서 수정")

### `UNIT_TEST_RETRIES_EXHAUSTED` — exit 2 `NEED_USER`

unit 의 `targeted_test` 가 `MAX_TEST_RETRIES` 회 수정 뒤에도 실패. `units/<id>/targeted-test-NN.log` 를 정리해 사용자 보고(Unit 정적 검사가 설정돼 있고 같은 회차에 위반도 남았으면 detail 에 그 진단 로그가 함께 적힌다 — 한도는 둘이 공유한다)

### `DESIGNER_SCOPE_VIOLATION` — exit 2 `NEED_USER`

디자이너(편집 역할)가 합의 문서·`decisions.md` 밖의 source 작업 트리를 바꿈(CLI 종료코드와 무관). 검증자는 문서를 검증하는 역할이지 디자이너가 바꾼 구현 코드를 승인하는 역할이 아니므로 검증자로 넘기지 않는다. 자동 원복·같은 디자이너 자동 재호출 없음 — 호출 전 tree 를 `designer-scope.guard.json` 에 남기고, 복구 전 재실행은 모델 호출 0회로 같은 사유로 멈춘다.
사용자가 변경을 확인한 뒤 작업 트리를 그 tree 로 되돌리면 재개된다(문서까지 바뀌어 있었다면 기존 재개 규칙대로 디자이너를 다시 부르지 않고 다음 검증 라운드로)

### `WORKER_OUTCOME_UNCERTAIN` — exit 2 `NEED_USER`

워커 CLI 가 non-zero 로 끝났고 이번 호출의 결과 JSON 이 없거나 깨졌는데 작업 트리는 바뀜(index·manifest·기준선·write-set 게이트는 모두 통과). 완료 여부를 알 수 없으므로 같은 워커를 자동 재호출하지 않고 변경도 원복하지 않는다 — 호출 전 tree 를 `worker-outcome.guard.json` 에 남기고, 복구 전 재실행은 모델 호출 0회로 같은 사유로 다시 멈춘다.
사용자가 변경을 확인한 뒤 작업 트리를 그 tree 로 명시적으로 되돌리면(`git checkout <tree> -- <경로>` 등, 러너는 하지 않는다) 재실행 시 워커가 다시 돈다. 결과 JSON 이 유효하면(parse·필드·DONE/UNDECIDED 모순 검사) non-zero 여도 이 사유가 아니라 `[WARN] CLI_EXIT_STATUS_MISMATCH` 로 기록하고 재실행 없이 진행한다(디자이너·수정자는 변경이 있으면 각각 다음 검증자·리뷰어에게 넘긴다;
`cli-anomalies.jsonl` 에 append, `usage.jsonl` 의 raw exit_code/success 는 그대로). **review-gap 워커 재개에서도 같은 사유를 쓴다**(가드 파일 없이 `doc-gap-resume.json` 의 `worker_run` 으로 판정, 모델 0회):
기록된 실행의 식별자가 지금의 리뷰 내용·미결정·사용자 결정·계약과 다르거나, 시작만 기록됐는데(STARTED) 결과 파일이 시작 기록 당시와 다른 내용으로 남아 있거나(유효한 JSON 인지와 무관 — CLI 가 실제로 돌았다, 게이트·세션 수용 완료 여부 불명. 빈 파일·파일 없음은 결과가 아니므로 tree 가 그대로면 워커부터 다시 돈다), 완료 기록(DONE)의 결과 파일이 기록 당시와 다르다.
**리뷰 대기(REVIEW_PENDING) 재개도 같은 증명을 요구한다** — `worker_run` 이 없거나 DONE 이 아니거나, 식별자·결과 파일 해시가 완료 기록과 다르면 리뷰로 들어가지 않는다(이 검증 이전에 만들어진 `worker_run` 없는 REVIEW_PENDING 체크포인트도 여기에 해당한다).
**빠른 검사 수정 턴(check-fix) 재개에서도 같은 사유를 쓴다**(`check-fix.pending.json`, 모델 0회): 그 턴이 CLI 호출 중에 중단돼 호출 후 tree 기록이 없거나 유효한 결과 JSON 이 없는데 작업 트리가 호출 전 tree 와 다르다. 변경을 확인하고 호출 전 tree 로 명시적으로 되돌린 뒤 재실행하면 검사부터 다시 돈다.
이때는 결과를 재사용하지도 워커를 자동 재호출하지도 않는다 — 사용자가 작업 트리와 `review-gap-result.json` 을 확인한 뒤, 그 호출을 버리고 새 리뷰부터 다시 하려면 `doc-gap-resume.json` 을 치우고 재실행한다(체크포인트를 손으로 고치지 않는다)

### `DOC_GAP_SCOPE_EXCEEDED` — exit 2 `NEED_USER`

구현 후 gap 의 사용자 해결이 허용 범위(approach.md 반영 + decisions.md 추가)를 벗어남(모델 0회): ① implementation.md·implementation-units.json·feature-scope.json 변경, decisions.md 기존 줄 수정·삭제, 답 줄 삭제, 밑바탕 합의 무효 ② 리뷰 DOC_GAP 해결 과정에서 gap 해결로 확정할 수 없는 unit 계약 변경이 생김
— 해결 예외는 ⓐ gap 의 경로(체크포인트 `gaps[].paths` — 워커 미결정의 `paths` / 리뷰 issue 의 `code_refs`; 자유 문자열 `location` 은 표시용일 뿐 판정에 쓰지 않는다)가 scope 안인 unit 의 ⓑ approach.md 절 가운데 ⓒ 본문에 그 gap 의 tag(`[review-issue=<id>]` / `[worker-gap=review-gap#<n>]`)가 적힌 절의 변경에만 적용된다.
**이 검사는 지문을 고정하기 전에 한다** — 실패하면 체크포인트는 `WAITING_USER` 그대로이고(수리 지문 없음), detail 이 바뀐 unit·바뀐 approach 절·연결된 tag 를 구분해 알려 준다. 사용자가 절을 되돌리거나 tag 를 보완해 재실행하면 **같은 체크포인트에서 다시 평가**된다(체크포인트를 치우지 않는다).
앞서 해결한 gap 은 다음 gap 체크포인트의 `prior_gaps`(원본 리뷰 경로·내용 해시, 이슈 ID·tag, 사용자 결정 줄, 그 해결의 입력 지문)로 넘어가 같은 조건으로 계속 인정된다 — 리뷰 DOC_GAP 이 연달아 나와도 앞 해결로 바뀐 절을 잊지 않는다. 단 앞선 해결은 그 답 줄이 기록 당시 그대로 있고 원본 리뷰 JSON 이 기록 당시 내용이며 그 리뷰에 그 id 의 DOC_GAP 이 있을 때만 센다(연결이 깨지면 그 해결로는 덮지 않는다.
답 줄 원문·리뷰 내용 해시가 기록에 없어 확인할 수 없는 해결도 세지 않는다). gap 과 연결되지 않은 unit 의 절, 같은 unit 의 다른 절, tag 표시가 없는 절 변경은 덮이지 않고 그 unit 의 완료 체크포인트는 재사용되지 않는다(러너는 절과 gap 의 관계를 추정하지 않는다). detail 의 unit·절 목록을 사용자에게 보고하고, 의도하지 않은 변경이면 gap 발생 시점으로 되돌린 뒤 재실행, gap 해결로 고친 절인데 표시만 빠졌으면 사용자 확인 뒤 tag 를 적고
재실행(둘 다 같은 체크포인트), gap 과 무관하게 의도한 변경이면 새 구현 제안이므로 `doc-gap-resume.json` 을 치우고 재실행(impl 재합의 → 그 unit 부터 변경 계약으로 다시 돈다). 이미 `WORKER_PENDING` 이상으로 고정된 체크포인트에서 문서를 다시 고쳤으면 러너는 새 지문을 묵시적으로 발급하지 않는다
— 고정 시점 상태로 되돌리거나 사용자 확인 뒤 명시적으로 재시작한다. 오케스트레이터가 임의로 되돌리지 않는다

### `DOC_GAP_LOCATION_UNRESOLVED` — exit 2 `NEED_USER`

gap 의 위치를 파일 경로로 확정할 수 없다(모델 0회, 체크포인트는 `WAITING_USER` 그대로) — ⓐ gap 해결로 바뀐 approach.md 절에 적힌 tag 의 gap, 또는 ⓑ 수리하려는 **현재 gap**(유효하지 않은 완료 unit 이 하나도 없어도 멈춘다. 앞서 해결된 `prior_gaps` 는 ⓑ 에 넣지 않는다).
`paths` 가 없는 옛 체크포인트에서만 생긴다 — 리뷰 gap 은 내용이 확인된 원본 리뷰의 `code_refs`, 그 밖에는 자유 문자열 위치를 해석하며(근거 참조 `basis_refs` 는 코드 위치로 쓰지 않는다), basename 뿐인 위치가 잠긴 scope·units manifest 의 파일 0개 또는 2개 이상과 맞는 경우다.
러너는 경로를 추정하거나 저장소를 검색하지 않고, 이것을 "무관한 unit 의 계약 변경"(`DOC_GAP_SCOPE_EXCEEDED`)으로 단정하지도 않는다. detail 의 원문·후보를 사용자에게 그대로 보고한다: 그 절 변경이 이 gap 의 해결이 아니면 되돌리고 재실행, 위치가 확정된 다른 gap 의 해결이면 그 tag 를 적고 재실행(같은 체크포인트), 그 gap 의 해결로만 설명되거나 ⓑ 이면 사용자 확인 뒤 명시적으로 재시작(`doc-gap-resume.json` 을 옮기고 재실행 →
impl 재합의). 체크포인트를 손으로 고치지 않는다

### `RESOLVED_GAP_REPEATED` — exit 2 `NEED_USER`

unit 미결정을 사용자가 `decisions.md` 에 답하고 러너가 재개한 워커 턴이, 그 **같은 ID·같은 질문·같은 위치**(`doc-gap-resume.json` 의 `<unit-id>#<n>` ↔ `[worker-gap=<unit-id>#<n>]` 태그, `decision_needed` 와 `location` 문자열 완전 일치)를 다시 `undecided` 로 냈다.
재개 프롬프트의 `[RESOLVED GAPS]` 블록에 ID·원 질문·답 줄·approach.md 참조가 들어갔는데도 반복한 것이므로 판정은 **세션 수용(`role_session_accept`) 앞**에서 하고 그 턴은 수용하지 않는다 — 자동 재시도·세션 초기화·자동 원복 없이 멈춘다. 근거는 `units/<id>/resolved-gap-repeated.json`(ID·답·반환된 항목·결과 경로·반복 턴 전/후 tree `expected`/`observed`).
재실행은 사용자가 그 턴의 코드 변경(`git diff <expected> <observed>`)을 확인하고 **작업 트리를 `expected` 로 되돌린 뒤**에만 같은 세션의 워커 턴으로 돈다(가드가 자동 비활성화; 파일 삭제는 복구가 아니다 — 가드 파일만 지우고 재실행하면 재개 턴 직전의 체크포인트 `source_tree` 검사가 `DOC_GAP_SOURCE_CHANGED` 로 모델 호출 0회에 멈춘다.
approach.md 를 더 고쳐야 하면 기존 post-DOC_GAP 계약대로 `doc-gap-resume.json` 을 치우고 impl 재합의). 표현만 비슷한 **새** 질문, 같은 문구라도 **다른 위치**의 미결정은 완전 일치가 아니므로 정상 `UNDECIDED` 다. 이미 확정된 세션에 남은 반복 턴의 문맥은 되돌릴 수 없어 재개 프롬프트 서열(합의 문서 → 현재 코드 → 세션 기억)이 덮는다

### `WORKER_SESSION_MISMATCH` — exit 2 `NEED_USER`

Feature Worker 세션의 전제가 기록과 다르다(모델 호출 0회). 러너는 다른 전제의 세션을 자동 resume 하지도, 자동으로 fresh 세션을 만들지도 않는다. detail 이 다음 중 어느 경우인지 알려 준다.
- 세션 전제 불일치: cli·모델·effort·워커 규칙 지문이 `worker-session.json` 저널과 다르거나, 저널의 버전이 다르다.
- 수용된 세션 소실·불일치: 저널의 세션 ID 와 CLI 세션 파일이 다르거나, `session_bound=true` 인데 세션 파일(codex 는 세션 원장)이 없거나, 원장은 확정됐는데 저널이 미결속이다.
- 세션 교체(handoff) 검증 실패: `worker-handoff.json` 이 스키마와 다르거나 없거나, 계약 지문이 현재 규칙·프롬프트와 다르거나, 이관 시점 tree 와 현재 작업 트리가 다르다.

detail 을 그대로 보고하고 멈춘다. 복구 방식은 사용자가 정한다: 설정·규칙·세션 파일·작업 트리를 기록 시점으로 되돌린 뒤 재실행(같은 세션으로 재개)하거나, 의도한 변경이면 `--new` 등 재시작 방식을 명시한다.
오케스트레이터는 `worker-session.json`·`worker-handoff.json`·세션 파일·체크포인트를 손으로 고치지 않고, 작업 트리를 대신 되돌리지 않는다.
세션 저널·결속·교체 계약의 원문은 `pipeline-contracts.md` 의 "구현 단위 직렬 실행 (worker stage)" 절이다 — 이 reason 에서는 그 절도 함께 읽는다.

### `WORKER_SESSION_MISSING` — exit 2 `NEED_USER`

`worker-session.json` 저널이 없는데 이전 fresh-워커 체계의 세션 파일이나 완료된 unit 체크포인트가 남아 있다(예전 방식의 실행이거나 저널 삭제, 모델 호출 0회). 러너는 예전 실행을 단일 워커 세션으로 묵시적으로 마이그레이션하지 않고, 자동으로 fresh 세션을 만들어 잇지도 않는다.
detail 을 보고하고 사용자가 고르게 한다: ① `--new` 로 새로 시작, ② 이어 돌리려면 사용자가 작업 디렉터리에 `worker-session.migrate` 마커 파일(정확한 경로는 detail 에 있다)을 만들고 재실행(마커는 1회 소비되고, 유효한 완료 체크포인트는 건너뛰고 첫 미완료 unit 부터 새 세션으로).
마커는 사용자의 명시적 선택이므로 오케스트레이터가 묻지 않고 만들지 않는다. 계약 원문은 `pipeline-contracts.md` 의 "구현 단위 직렬 실행 (worker stage)" 절이다 — 이 reason 에서는 그 절도 함께 읽는다.

### `ENV_ERROR` — exit 1

원인 확인 후 재실행. 진행 금지

- 로그에 `CODEX_TURN_UNCERTAIN` · `CODEX_TURN_RESULT_UNCONSUMED` · `SESSION_RESUME_UNCERTAIN` · `SESSION_BACKEND_MISMATCH` · `CODEX_APP_SERVER_*` 가 있으면 Codex 역할 호출(App Server backend)이 멈춘 것이다.
  `references/codex-app-server.md` 를 읽고 그 절차를 따른다. 그대로 재실행해도 모델 호출 0회로 같은 사유가 나온다 — 호출 기록(`.session-<key>.codex-turn.json`)·세션 원장을 손으로 고치거나 지우지 않고,
  `codex-app-server.sh discard` 를 스스로 실행하지 않으며, `CODEX_BACKEND` 를 바꿔 우회하지 않는다. `status`/`reconcile`(조회 전용) 결과를 사용자에게 보고하고 결정을 받는다.

## 재개 규칙 — 재개 지점 선택 · 지문 · 체크포인트

재실행은 항상 같은 명령이다(`--feature <id>`, 수동 `--worktree`/`--branch` 를 썼다면 그 인자도 같이). 러너가 `run-state.json`의 stage 힌트와 실제 산출물(합의 체크포인트 `consensus-design.json`/`consensus-impl.json`의 PASS + 현재 입력 지문 + 참조 리뷰 JSON 내용, `worker-result.json` + `units/<id>/done.json`, `approved.fingerprint`)을 교차
확인해 재개 지점을 스스로 고른다 — 오케스트레이터가 단계를 지정하지 않는다. impl 이상으로 가려면 design PASS **또는 design 에스컬레이션의 유효한 사용자 수리**(`user-escalation-resume-design.json` 이 `USER_RESOLVED` 이고 수리 시점에 고정한 입력 지문이 현재와 같음
— `consensus_stage_accepted`)가, worker 이상으로 가려면 impl PASS 또는 impl 사용자 수리가 현재 입력(design: request/design + `[USER-QUESTION][scope=design]` 줄, impl: request/design/implementation/approach/feature-scope/implementation-units + `[scope=design]`·`[scope=impl]` 줄
— downstream 은 upstream 결정을 상속하지만 upstream 은 downstream 결정을 보지 않는다)에 대해 유효해야 하며, 문서를 고치고 재실행하면 해당 합의부터 다시 돈다. 두 지문 모두 그 worktree 의 `conventions.md` 내용을 포함한다(없으면 고정 부재 표지)
— conventions 가 바뀌면 이전 design·impl PASS 는 재사용되지 않고 design 부터 다시 검증된다. 예외는 하나다: `conventions.md` 가 피처 범위(`feature-scope` 의 `files` — lock 이 있으면 lock)에 정확히 들어 있으면 이 피처의 산출물이므로, 워커 기준선(`worker-baseline.tree`)이 생긴 뒤에는 합의·unit 전역 계약·승인 계약 문서·워커 세션 지문이 작업 트리 파일 대신 **기준선의 내용**을
쓴다(`conventions_contract_content`) — 워커가 고친 규칙으로 피처가 자기 입력을 무효로 만들지 않는다. 범위 밖이거나 기준선이 없으면 예외가 없다(종전대로 무효). 역할 프롬프트에는 항상 작업 트리의 현재 파일이 들어간다: 리뷰어·수정자·새 세대 워커는 본문 그대로, 같은 세션을 잇는 워커 재개 턴은 파일이 기준선과 달라졌을 때 `[PROJECT CONVENTIONS — 현재 파일 전문]` 블록으로 받는다(`[round N]` 같은 합의 이력 줄은 여전히 어느 지문에도
들어가지 않는다). **문서가 바뀌어도 재합의하지 않는 경우는 두 가지 사용자 결정 경로뿐이다.** ① **합의 단계 에스컬레이션 수리**: `ASK_USER`/`DEADLOCK`/`MAX_ROUNDS` 로 멈춘 뒤 사용자가 모든 blocker 에 `[escalation=<id>]` 답을 추가하면 합의 루프가 `user-escalation-resume-<target>.json` 을 `WAITING_USER → USER_RESOLVED` 로 수리하고 그 시점의 입력
지문(`resolved_input_fingerprint`)을 고정한다 — 이후 재실행·중간 종료 뒤 재개·`consensus-loop.sh` 단독 실행 모두 지문이 같으면 그 단계 검증자·디자이너 0회다. `USER_RESOLVED` 는 검증자 PASS 와 다른 provenance 다(합의 체크포인트·리뷰 JSON 을 위조하지 않는다).
수리 뒤 문서·결정·범위·conventions·계약 버전이 달라지면 무효(`SUPERSEDED`)이고 정상 재합의다. ② **구현 후 DOC_GAP 해결**: `doc-gap-resume.json` 이 pending(WAITING_USER/WORKER_PENDING/REVIEW_PENDING)이면 impl 지문 추론보다 먼저 `doc-gap` 경로로 간다
— 사용자가 답과 approach 동기화를 마치면 러너가 그 시점의 impl 입력 지문을 `resolved_impl_fingerprint` 로 고정하고(기존 validator PASS 는 위조·덮어쓰기하지 않는다, `base_consensus_review` 가 그 PASS 를 가리킨다 — impl 이 사용자 수리로 워커에 들어온 경우에는 `base_kind=USER_RESOLVED` 로 그 수리 체크포인트의 리뷰·수리 지문을 밑바탕으로 든다), 이후 impl PASS 가 stale 이어도 그
지문이 현재 입력과 같으면 impl 로 되돌리지 않는다(`impl_docs_accepted`). 그 뒤 문서를 또 고치면 지문이 달라져 정상적으로 impl 재합의를 거친다. 즉 최초 구현 전 source of truth 는 합의 문서이고, post-DOC_GAP 은 합의 문서 + 해당 gap 의 명시적 사용자 결정 + 동기화된 approach 다.
WAITING_USER 동안은 모델을 부르지 않으며, 프로세스가 워커 직전/직후/리뷰 직전에 죽어도 다음 실행은 체크포인트 단계(WORKER_PENDING → 워커, REVIEW_PENDING → 리뷰)부터 잇는다(review-gap 워커 결과는 `doc-gap-resume.json` 의 `worker_run` 이 증명할 때만 재호출 없이 재사용한다
— 실행 식별자[리뷰 경로 + 리뷰 내용 + 미결정 ID + 사용자 결정 줄 + 수리 시점 impl 입력 지문의 해시]가 같고, 완료 기록(DONE)이 있고, 호출 전 tree 가 체크포인트 source tree 이고, 현재 tree 가 기록된 after tree 이고, 결과 파일이 기록 당시 내용의 유효한 DONE 일 때.
코드 변경이 없던 실행도 같은 조건이다. `review-gap-*.tree`·`review-gap-result.json` 만으로는 판정하지 않는다 — 앞 gap 의 워커가 코드를 바꾸지 않았으면 그 파일들이 다음 gap 의 tree 와 전부 같기 때문이다. 새 gap 이 기록되면 체크포인트에 `worker_run` 이 없으므로 그 gap 의 워커는 반드시 다시 돈다.
불확실하면 `WORKER_OUTCOME_UNCERTAIN`). review 이상으로 가려면 `implementation-units.lock.json` 이 있을 때 모든 unit 의 `done.json` 이 유효해야 한다. 문서 합의 루프는 stage 보다 잘게 `consensus-design.json` / `consensus-impl.json` 에 round 와 다음 단계(`VALIDATOR_PENDING` / `DESIGNER_PENDING` / `PASS`)를 기록한다
— 검증자가 끝난 뒤 디자이너 호출이 실패(모델 ID 오류 등)하면 재실행은 같은 리뷰 JSON 으로 디자이너만 다시 부르고, 디자이너가 문서를 일부 고친 뒤 죽었으면(입력 지문 불일치) 같은 수정을 반복하지 않고 다음 검증 라운드로 간다. PASS 도 입력 지문과 함께 캐시되어 입력이 그대로이고 참조 리뷰가 실제 현재 계약의 PASS 이면 검증자를 다시 부르지 않는다.
지문은 세 종류다: editable(대상 문서 + `decisions.md` 전체 — 스냅샷·diff·변경 파일 목록과 같은 집합, 디자이너 부분 실행 감지), upstream(design 은 `request.md`, impl 은 `request.md`+`design.md`, + `[USER-QUESTION]`
— 바뀌면 저장된 리뷰가 무효라 Round 1 부터), PASS(입력 문서 전체 + `[USER-QUESTION]` — 이후 판정 기록이 쌓여도 PASS 가 무효화되지 않음). 체크포인트 포맷은 `scripts/lib/runtime.sh`의 `CONSENSUS_CHECKPOINT_VERSION`/`REVIEW_CHECKPOINT_VERSION`으로 따로 버전을 매기며, 지문 의미가 바뀌면 올린다
— 다른 버전의 체크포인트는 지문을 비교하지 않고 처음(Round 1 / 새 attempt)으로 돌아간다. `ASK_USER`/`DEADLOCK`/`MAX_ROUNDS` 로 멈추면 마지막 리뷰·blocker 를 `user-escalation-resume-<target>.json` 에 먼저 남긴 뒤 합의 체크포인트를 Round 1 로 초기화한다
— 이 초기화는 재검증 예약이 아니다: 사용자가 모든 blocker 를 결정하면 재검증 없이 다음 단계로 가고, 위 우회 조건이 깨졌을 때만 Round 1 부터 재검증한다. 구현 리뷰 루프도 같은 구조로 `review-impl.json` 에 attempt·round·다음 단계(`REVIEWER_PENDING` / `FIXER_PENDING` / `APPROVE`)와 작업 트리 지문을 기록한다
— 리뷰어가 `REQUEST_CHANGES` 를 낸 뒤 수정자 호출이 실패하면 재실행은 같은 attempt 에서 기존 리뷰 JSON 으로 수정자만 다시 부르고, 수정자가 코드나 `decisions.md`를 일부 고친 뒤 죽었으면(작업 트리 + `decisions.md` 지문 불일치) 다음 리뷰 라운드로 간다.
수정자가 완료된 뒤(`REVIEWER_PENDING`) 외부 변경이 들어왔으면 종결 검토에 섞이지 않도록 새 attempt 의 Round 1 로 간다. `APPROVE` 는 작업 트리만의 지문이 그대로이고 참조 리뷰가 실제 현재 계약의 APPROVE 이면 재사용하고, 바뀌었으면 새 attempt 를 시작한다.
러너도 verify 로 바로 들어가기 전에 같은 조건(`impl_approval_current`: 체크포인트 APPROVE + 계약·포맷 버전 + 트리 지문 + `approved.fingerprint` 일치 + 실제 APPROVE 리뷰)을 확인하고, 아니면 review 부터 다시 간다. `DEADLOCK`/`MAX_ROUNDS`/`DOC_GAP` 종료 시 체크포인트는 초기화되어 다음 재진입은 새 attempt 의 Round 1 이다(리뷰어 DOC_GAP 은 `doc-gap-resume.json`
에 리뷰 경로·attempt/round·source tree 를 따로 남긴다).

### `NATIVE_AGENT_RESTART_REQUIRED` — agent 정의를 이 세션이 등록했다는 증거가 없다

`CLAUDE_BACKEND=native` 에서 러너가 native 역할의 agent 정의(`.claude/agents/feature-<역할>.md`)를 이번 실행에 썼거나, 그 정의가 메인 Claude Code 프로세스(`CLAUDE_PID`)보다 나중에 쓰였다. 러너는 요청을 만들지 않고 멈췄다. 피처 시작 때의 확인은 Codex 검증자 같은 유료 호출보다 먼저 한다. 모델 호출은 0회이고, dispatch 할 것도 없다. `PREPARED` 요청이 남아 있으면 그 요청은 그대로 둔다. 합의·리뷰 루프를 단독으로 실행했을 때는 같은 사유가 `NEED_USER` 가 아니라 exit 43 과 `[STOP] NATIVE_AGENT_RESTART_REQUIRED` 줄로 온다. 대응은 같다. detail 이 "정의 파일이 없다" 또는 "내용이 요청 발행 때와 다르다" 면 재시작 전에 정의 복구가 먼저다. 사용자 결정 뒤 요청 발행 때 설정으로 `prepare-agents` 를 실행하거나, 설정 변경이 의도였다면 `discard` 한다(`references/native-agent.md`).

- detail 의 정의 목록을 사용자에게 보여 주고 **Claude Code 세션 재시작(같은 대화 재개)** 을 요청한다. 재시작한 세션에서 같은 명령을 재실행한다. 재시작 없이 다시 돌리면 같은 사유로 멈춘다.
- 정의 파일을 손으로 고치거나 수정 시각을 바꾸지 않는다. 다른 Agent·`claude -p`·backend 변경으로 대체하지도 않는다. 예방과 판정 근거는 `references/native-agent.md` 의 "agent 정의 사전 준비" 가 기준이다.

### `NATIVE_RESULT_REJECTED` — native Agent 결과 불수용

`CLAUDE_BACKEND=native` 에서 캡처된 Agent 결과(또는 남아 있는 pending 요청)가 현재 요청과 결속되지 않았다. 러너는 결과를 수용하지 않았고 자동 재호출·자동 원복·자동 fresh 도 하지 않았다 — 그대로 재실행하면 모델 호출 0회로 같은 사유가 나온다.

- detail 의 코드(`NATIVE_MODEL_MISMATCH`·`NATIVE_PROMPT_HASH_MISMATCH`·`NATIVE_STALE_REQUEST`·`NATIVE_READONLY_VIOLATION`·`NATIVE_WORKTREE_CONFUSION`·`NATIVE_PENDING_MISMATCH` 등)를 그대로 사용자에게 보고하고 멈춘다. 코드별 의미와 복구(`native-agent-bridge.sh discard <request_id>` — 사용자 승인 뒤, 작업 트리가 호출 전 상태일 때만)는 `references/native-agent.md` 가 기준이다.
- `NATIVE_DISPATCH_DENIED` 는 결과가 아니라 **dispatch 자체가 실행 전에 거부된** 경우다(다른 PreToolUse 훅·권한 규칙·사용자 거절 — Agent 미실행, 요청 state 는 `DISPATCHING` 그대로). 거부 사유를 그대로 보고하고 멈춘다. 거부한 훅을 끄거나 모델·Agent 를 바꿔 다시 보내지 않는다. 사용자가 원인을 해소한 뒤에만 `native-agent-bridge.sh redispatch <request_id>` 로 같은 요청을 되돌리고, 아니면 `discard` 한다.
- `Agent type '…' not found`(Agent 정의 미발견)로 돌아온 dispatch 는 `NATIVE_DISPATCH_DENIED` 가 아니다. 요청이 `DISPATCHING` 이면 러너는 거부 종류가 함께 있어도 실행 여부 불명(`UNKNOWN`)으로 보고 exit 42 로 대기한다 — 세션을 재시작한 뒤에도 다시 dispatch 하지 않고, `redispatch` 는 거절된다. 사용자와 실행 여부를 확인한 뒤 `discard` 로만 정리하고, 세션을 다시 시작한 다음 재실행한다. 요청이 `PREPARED` 그대로면 세션 재시작 뒤 그 dispatch 를 한 번 보낸다(`references/native-agent.md`). `CLAUDE_PID` 를 볼 수 있는 러너는 등록 증거가 없는 정의로 요청을 만들지 않는다(위 `NATIVE_AGENT_RESTART_REQUIRED`).
- 결과를 직접 다시 쓰거나, 요청·캡처·세션 원장(`.agent-work/native-agent/`, `.session-*.native.json`)을 손으로 고쳐 진행시키지 않는다. exit 42 `NATIVE_AGENT_REQUIRED` 는 이 절이 아니라 `references/native-agent.md` 의 반복 절차를 따른다.
