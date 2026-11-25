# 파이프라인 계약 — 구현 단위 실행 · 강제 규칙 · 변경 소유권 · 세션/사용량

> feature 스킬 참조 문서(`SKILL.md` 에서 분리한 원문). 읽는 시점: 러너의 worker 단계 동작(unit·세션·rolling context·세션 교체)을 판단하거나 사용자에게 설명해야 할 때, 검증자·리뷰어·워커 역할 경계나 `decisions.md` 태그·scope 규칙을 적용할 때, 범위·기준선·worktree 소유권 문제(`SCOPE_*`·`FOREIGN_WORKTREE_CHANGE`)를 다룰 때, 프롬프트·스키마·계약 버전을 바꿀 때, 비용·사용량을 보고할 때. 커밋·finalize 규칙은 `references/done-finalize.md` 에 있다.

## 구현 단위 직렬 실행 (worker stage)

큰 feature 를 워커 한 턴에 맡기면 후반부로 갈수록 conventions 가 soft constraint 처럼 밀려 기존 utility/predicate 재구현, `a == X || a == Y` 나열, 불필요한 분기, 책임 배치 이탈이 누적된다. 작은 기능 범위에서는 워커가 기존 컨벤션을 잘 따르므로, 설계 일관성은 전체 문서 합의로 유지하고 **실제 코드 작성만 unit 크기의 턴으로 제한**한다.
워커 모델을 바꾸는 것도, 리뷰 구조를 바꾸는 것도 아니다. **Unit 은 구현·검증·재개 단위이고, Worker 는 Feature 전체의 단일 구현 주체다** — 구현 단계는 Feature 당 하나의 지속되는 Claude CLI 세션(`FEATURE_WORKER_SESSION`, 최초 `--session-id` → 이후 `--resume`)이 unit 순서대로 턴을 이어 가며, 앞 unit 에서 파악한 기존 API·컨벤션·선택된 구현을 다음 unit 이 같은 세션 문맥에서 재사용한다.
unit 마다 CLI 를 다시 부르는 것은 러너이고(Feature 당 프로세스 1회가 아니다 — unit 별 테스트·체크포인트 게이트를 위해), 다음 unit 시작 권한도 러너만 갖는다. 그 앞뒤(design/impl 합의, 전체 review/fixer, 전체 verify)의 의미는 그대로다. unit 별 design·review·fixer, Worker pool, Group/Wave, 병렬은 두지 않는다.

- **직렬만.** 러너는 `implementation-units.json` 을 워커 진입 시 `implementation-units.lock.json` 으로 확정(`feature-scope.lock.json` 과 같은 철학 — 원본≠lock 이면 `UNITS_MANIFEST_CHANGED`, 호출 중 바뀌어도 같은 사유)하고 배열 순서대로 하나씩 돈다. Unit N 이 끝나기(워커 DONE + targeted test 통과) 전에 N+1 을 시작하지 않는다. 병렬 워커·DAG·우선순위·worker pool·투기 실행은 없고 앞으로도 그 추상화를 두지 않는다. 러너는 unit 을 건너뛸지 판단하지 않는다 — 완료 체크포인트가 유효한가만 본다.
- **unit 하나의 흐름.** `units/<id>/` 를 만들고 시작 tree(`before.tree`)를 기록 → **Feature Worker 세션의 턴**(`prompts/worker-unit.md`, 세션은 피처 공통 `feature-worker` — 최초 턴만 [CORE RULES]/[REFERENCE CODE] 전체를 받고 후속 턴은 짧은 재명시 + unit 명세만 받는다
  — 단 아래 "워커 규칙 원문 재전달 경계" 에서는 후속 턴도 규칙 원문을 다시 받는다; 결과 `worker-result.json`, `DOC_GAP`/`USER_DECISION` 처리는 전체 워커와 같다) → **targeted test**(`targeted_test` 를 저장소 루트에서 실행, `targeted-test-NN.log`) → `done.json`(version·unit_id·spec_hash·worker/targeted_test 상태·completed_at, 임시 파일 +
  `mv`). 세션 전제(cli·모델·effort·워커 규칙 지문·세대·결속 여부)는 `worker-session.json` 저널로 고정하고, 불일치하면 `WORKER_SESSION_MISMATCH` 로 자동 resume 도 자동 fresh 도 없이 멈춘다. 실제 세션 ID 는 CLI 어댑터 한 곳에서만 관리한다
  — claude 는 `.session-feature-worker`, codex 는 `.session-feature-worker.codex.json` 원장(`thread_id` 를 저널에 복사하지 않는다). 저널의 `session_bound` 는 모든 게이트 + 결과 계약 검사를 지난 결과 수용(`role_session_accept`
  — DONE/UNDECIDED 모두) 뒤에만 true 가 되며, "아직 세션 미생성"(false + 원장 없음)과 "수용된 세션 소실"(true + 원장 없음)을 구별해 소실·그리고 원장 존재+미결속 불일치는 전부 fail-closed 로 멈춘다(자동 fresh 금지). 예전 fresh-워커 실행이 남은 피처는 묵시적으로 마이그레이션하지 않는다(`WORKER_SESSION_MISSING`
  — `--new` 또는 사용자가 `worker-session.migrate` 마커로 명시). `run_worker` 의 장치(워커 규칙·[REFERENCE CODE]·스키마·index 지문·기준선 가드·before/after tree·manifest 불변·write-set 검사·DONE/UNDECIDED 모순 검사)는 unit 호출에 그대로 쓰이고, 전체 범위 검사 뒤에 **같은 함수로 unit scope 검사**를 한 번 더 한다(`UNIT_SCOPE_VIOLATION`, 원복 없음).
  unit 사이에 리뷰어·수정자·검증자를 부르지 않는다.
- **워커 규칙 원문 재전달 경계.** 최초 턴에 넣은 [CORE RULES]/[PROJECT CONVENTIONS]/[WORKER SKILL] 을 모델 기억만으로 신뢰하지 않는다. 같은 세션을 잇는 턴이라도 ① 러너 (재)실행 뒤 첫 워커 턴(중단 뒤 재실행·장기 재개) ② 작업 단위가 바뀌는 턴(새 unit 의 첫 턴, unit → verify 의 worker-fix / review-gap) ③ 직전 워커 호출의 이벤트 로그에서 컨텍스트 압축이 관측된 다음 턴(claude
  `stream-json` 의 `system/compact_boundary`, codex 이벤트의 `*compact*` type)에는 `core_rules.md` + **현재 worktree 의** `conventions.md` + `WORKER_SKILLS` 원문 전체를 `[RULES RECHECK — 규칙 원문 재전달: <사유>]` 블록으로 다시 싣는다(`load_worker_rules`
  — 최초 턴과 같은 로더). 그 밖의 턴(같은 unit 의 test-fix 반복 등)은 짧은 필수 불변식 + 규칙 원문 파일 경로만 받는다 — 매 턴 전문을 중복 삽입하지 않는다. handoff 뒤 fresh 세대의 첫 턴은 종전대로 최초 턴 전문이다. 경계 판단은 러너 프로세스 메모리만 쓴다(새 상태 파일 없음
  — 러너가 다시 뜨면 ① 이 된다). 재전달은 프롬프트 본문일 뿐이다: `worker-session.json`·`implementation-context.json`·session resume·handoff·계약 지문·Shell 게이트의 의미는 그대로이고, 규칙이 바뀌었다는 이유로 fresh 세션을 만들거나 체크포인트를 우회하지 않는다(규칙 변경은 종전대로 `WORKER_SESSION_MISMATCH`/`UNIT_CONTRACT_IMPACT_REQUIRED` 가 멈춘다).
  전달 범위는 `live.log` 의 `워커 규칙 전달 … full|short, N bytes` 줄에 남는다. 회귀: `tests/smoke-implementation-units.sh` 사례 P.
- **unit 간 rolling context.** 세션이 이어져도 세션 기억을 체크포인트로 삼지 않는다 — 앞 unit 이 **실제 코드로 확정한** 구현 문맥만 `implementation-context.json`(`{version, completed_units, facts[{kind, subject, note, source_unit}]}`, kind 는 `CONTRACT_BINDING`·`REUSE`·`ENTRY_POINT`·`INVARIANT` 넷뿐)으로 압축해 다음 unit
  워커·test-fix 프롬프트의 `[IMPLEMENTATION CONTEXT]` 블록에 넣는다. 별도 요약 모델·stage·합의·리뷰는 없다 — 각 unit 워커(및 test-fix)가 결과 JSON 의 `context_updates{upsert,remove}` 로 후보를 내고 러너가 `(kind, subject)` 키로 기계적으로 fold 한다(같은 키 upsert 는 제자리 교체, remove 는 삭제;
  의미 병합 없음). 확정은 targeted test **PASS 뒤**에만: 워커 → fix 순서의 update 를 `units/<id>/context-updates.json` 에 보존하고 `done.json` 을 쓴 뒤 lock 순서대로 유효한 done 체크포인트의 update 를 다시 fold 해 파일을 재구성한다(파생 상태
  — 실패한 unit 의 update 는 pending 으로 버려지고, spec_hash 로 무효화된 체크포인트의 update 는 재사용하지 않으며, 같은 unit 재처리로 중복 append 되지 않는다). 규범(무엇을 해야 하는가)은 합의 문서 > 현재 코드 > 이 파일, 현재 상태(무엇이 존재하는가)는 현재 코드 기준이다
  — 앞 unit 의 코드가 문서와 충돌하면 그 코드를 precedent 로 따르지 않고 scope 밖이면 DOC_GAP 으로 보고한다. 워커는 적힌 symbol 의 현재 구현을 확인·재사용하되 코드 탐색을 생략하지 않는다. hard size limit 은 두지 않는다 — 중복 키 금지·문서 복제 금지·obsolete 제거로 수렴시킨다.
- **targeted test 는 리뷰의 대체물이 아니다.** 다음 unit 이 깨진 코드 위에 쌓이는 것을 막는 장치일 뿐이다. 실패하면 unit 범위 안에서만 수정(`prompts/worker-unit-fix.md`, 워커 역할, 이후 unit 기능 선행 구현 금지)하고 바로 재테스트한다 — 리뷰어를 부르지 않는다. 수정 횟수는 `MAX_TEST_RETRIES` 를 재사용하며 소진하면 `UNIT_TEST_RETRIES_EXHAUSTED`.
- **checkpoint / resume.** `run-state.json` 은 힌트다. 재실행은 lock 검증 → 앞에서부터 `units/<id>/done.json` 의 내용과 현재 lock 의 unit spec 지문(`spec_hash`)을 대조 → 첫 미완료 unit 부터 **같은 Worker 세션으로** 재개한다(01/02 완료 후 03 에서 멈췄으면 01/02 워커를 다시 부르지 않는다).
  단일 세션에서는 대화 진도와 코드 진도가 둘 다 있으므로 중간에 멈춘 unit 의 재개는 **결과 JSON + 실제 tree** 로 판정한다: 직전 시도의 유효한 DONE 결과의 after-tree 가 현재 tree 와 일치하면(워커는 끝났고 테스트 전에 죽음) CLI 재호출 없이 테스트부터 재개하고(건너뛴 호출 몫의 scope 게이트는 다시 돈다), before-tree 만 있고 after-tree 가 없는 시도 위에 tree 까지 바뀌었으면(CLI 호출 중 사망
  — 대화 진도 불명) `WORKER_OUTCOME_UNCERTAIN` 으로 멈춘다(새 세션 생성·자동 재호출·원복 없음). 그 외에는 워커 턴부터 다시 돌되 `before.tree` 는 첫 시도의 것을 재사용한다(unit 시작 시점의 증거). manifest 를 바꾸면 impl PASS 가 무효라 재합의를 거치고, 워커 진입에서 lock 과 다르면 멈춘다
  — 사용자가 lock 을 지우면 spec 이 그대로인 unit 의 체크포인트만 유지된다. 단 **직렬 의존성**: 어떤 unit N 을 다시 실행해야 하는데 N 뒤에 완료 체크포인트가 있는 unit 이 있으면 `UNIT_CHECKPOINT_CHAIN_STALE` 로 멈춘다(뒤 unit 의 spec 이 그대로여도 재사용하지 않고, 자동 원복·replay 도 하지 않는다).
  어느 체크포인트도 최종 품질 승인이 아니다.
- **세션 교체(회전)는 unit 경계에서만.** 단일 세션이 길어질 때의 컨텍스트 오염·압축 손실·cache-read 증가는 실제 위험이다 — 논리적 워커는 하나로 유지하되, unit 완료(targeted test PASS) 직후 마지막 워커 invocation 의 **마지막 턴 실제 컨텍스트**(`usage.jsonl` 의 `context_last_turn`
  — claude 는 `stream-json` 마지막 assistant 메시지 usage 합, codex 는 rollout 마지막 `token_count.last_token_usage.input_tokens`(Codex App Server backend 는 그 호출 turn 의 마지막 `thread/tokenUsage/updated` 의 `last.inputTokens`·`modelContextWindow`), native Agent 는 전사의 마지막 본 모델 호출 입력(비용 관측이 `partial` 이어도 따로 검증해 남긴다 — `references/native-agent.md`); 없으면 `input_per_turn` = `input_effective / num_turns` 근사
  — `input_effective` 자체는 invocation 누적 입력이라 기준이 아니다)이 `WORKER_SESSION_ROTATE_INPUT_TOKENS`(기본 1000000, 0 이면 비활성; 창 크기 `context_window` 까지 관측되면 고정 임계치 대신 `context_last_turn / context_window ≥ WORKER_SESSION_ROTATE_CONTEXT_RATIO`(기본 0.8);
  실측 없이 근사를 쓰면 그 사실을 로그에 남긴다; 판단은 그 unit 에서 이 실행이 부른 마지막 워커 호출의 행만 — `units/<id>/last-usage-label`) 이상이면 `worker-handoff.json`(`schemas/worker-handoff.schema.json` — generation·last/next unit·source_tree·계약 지문·context 파일)을 쓰고 다음 unit 부터 fresh 세대로 교체한다.
  새 세대의 첫 호출 전에 스키마·계약 지문·git tree 일치를 검증하며(불일치 → `WORKER_SESSION_MISMATCH`, 검증 없는 fresh 생성 금지), 첫 턴은 최초 턴과 같이 계약 문서·context 색인을 전부 다시 받는다. telemetry 가 둘 다 없으면 임의 추정 없이 세션을 유지하고, claude 는 세션 파일을·codex 는 원장(`.session-<key>.codex.json`)을 세대 접미사로 은퇴시키며, test-fix 도중이나 unit 중간에는 교체하지
  않는다. 구현 사실은 `implementation-context.json`, 이관 제어는 `worker-handoff.json` — 역할을 섞지 않는다.
- **워커 CLI 도구 제한은 SH 가 강제한다(프롬프트 아님).** `run_edit_role` 은 `role=WORKER` 인 호출(unit·test-fix·verify 의 worker-fix·review-gap, 최초·resume·handoff 뒤 새 세대 모두)에만 claude 는 `--disallowedTools "Agent,ScheduleWakeup"` + child 프로세스 전용 환경변수
  `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`·`CLAUDE_CODE_DISABLE_AGENT_VIEW=1`, codex 는 `exec`/`exec resume` 양쪽에 `-c 'agents.enabled=false'`(다른 `-c` 뒤, 전역 `~/.codex/config.toml` 불변)를 Bash 배열로 붙인다(`eval` 없음). Codex App Server backend 에서는 그 워커 호출의 `codex app-server` 자식 프로세스 인자에만 `agents.enabled=false`·`features.multi_agent_v2=false`·`features.multi_agent=false` 가 들어가고(호출마다 프로세스가 따로다, `multi_agent_v2` 가 켜져 있으면 `agents.enabled=false` 가 무시되므로 함께 끈다), 런타임이 그 프로세스의 유효 설정·기능 상태를 읽어 셋 모두 false 인 것을 확인한 뒤에만 turn 을 보낸다 — 키를 받지 않거나 확인하지 못하면 워커를 띄우지 않거나 `turn/start` 전에 멈춘다(`CODEX_APP_SERVER_AGENTS_POLICY_*` — `references/codex-app-server.md`).
  `SendMessage`·`Monitor` 는 막지 않고 Read/Edit/일반 Bash 테스트는 그대로다(`--allowedTools Bash` 유지 — 이것은 독점 허용 목록이 아니라 `Agent` 차단을 대체하지 못한다). CLI 가 옵션을 거부하면 그 호출은 실패로 끝나고 제한을 풀어 재실행하지 않는다.
  DESIGNER/VALIDATOR/REVIEWER/FIXER 의 인자는 바뀌지 않는다. 막는 것은 CLI 관리형 하위 Agent 와 내장 백그라운드 기능이다 — 워커가 일반 Bash 에서 `&`/nohup/별도 CLI 를 띄우는 것까지 OS 수준에서 막지는 않고 그걸 위한 프로세스 감시도 두지 않는다.
  이 정책은 호출별 CLI 인자이지 세션 대화 계약이 아니므로 `worker-session.json` 의 계약 지문에는 들어가지 않는다(단, 이번 변경의 `worker-unit.md` 수정으로 프롬프트 지문이 바뀌어 진행 중 피처는 기존 `WORKER_SESSION_MISMATCH` 절차를 거친다 — 묵시적 새 세션 전환 없음).
  회귀: `tests/smoke-worker-tool-policy.sh`.
- **claude 워커의 result 이벤트는 정확히 하나여야 한다.** `--output-format stream-json` 원본(`<raw>.stream.jsonl`)에서 `type=result` 이벤트가 **1개**이고 결과가 워커 스키마에 맞을 때만 수용한다(`claude_stream_extract_result`
  — 마지막 이벤트를 고르던 `tail -1` 제거). 0개(`CLAUDE_RESULT_MISSING`)·2개 이상(`CLAUDE_RESULT_MULTIPLE` — 하위 Agent·백그라운드 실행이 result 를 여러 번 남긴 경우)·파싱 실패(`CLAUDE_RESULT_INVALID` — result 가 1개여도 JSON 으로 읽을 수 없는 줄이 섞여 있으면 포함)는 각각 명시적 오류이며 중간의 유효해 보이는 이벤트를 자동 선택하지 않는다.
  그 경우 결과 파일을 만들지 않으므로 호출자는 "유효 결과 없음" 경로를 탄다. 판정 순서는 결과 유효성이 먼저다: CLI rc 가 0 이어도 결과가 워커 스키마/의미 검증(`worker_result_valid`)에 실패했고 작업 트리가 바뀌었으면 같은 `WORKER_OUTCOME_UNCERTAIN` 가드(before/after tree·`invocation_id`·raw 로그 경로·원본 rc·이유
  — `WORKER_RESULT_SCHEMA_INVALID`/`WORKER_RESULT_MISSING`/`CLAUDE_RESULT_*`)로 `NEED_USER` 중단(변경 보존·자동 재호출 없음), 바뀌지 않았으면 실행 실패(재실행 허용). `CLI_EXIT_STATUS_MISMATCH` 복구(rc≠0 + 유효 결과)는 **유일하고 유효한 결과**에만 적용된다(claude 도 codex 의 `-o` 파일처럼 CLI rc 와 무관하게 유일한 result 의 `structured_output` 을 꺼내
  호출자가 판정한다). claude 워커 세션의 확정(`.session-feature-worker.new` → 확정 파일)은 CLI rc 가 아니라 호출자의 `role_session_accept` 가 `worker_result_valid` 통과 뒤에만 한다(codex 원장과 같은 2단계) — 첫 턴의 결과가 무효면 그 대화는 다음 실행에서 이어지지 않고 새 `--session-id` 로 시작한다.
  이미 확정된 세션의 후속 턴이 무효로 끝난 경우는 되돌릴 수 없으므로, 복구 뒤 재개 턴은 재개 프롬프트의 서열(합의 문서 → 현재 코드 → 세션 기억)로 그 턴의 기억을 덮는다. 디자이너·수정자(스키마 없는 편집 역할)의 세션 확정은 바뀌지 않는다. 레거시 단일 객체(`type` 없는 JSON 한 줄
  — 구형 json 출력·테스트 mock)만 별도 명시 경로로 읽는다. 판정은 셸/jq 뿐이다. 회귀: `tests/smoke-claude-result-events.sh`.
- **해결된 unit 미결정은 재개 프롬프트에 ID 로 전달된다.** unit 워커가 `UNDECIDED` 로 멈추고 사용자가 `decisions.md` 에 `[worker-gap=<unit-id>#<n>]` 답을 적어 체크포인트가 `WORKER_PENDING` 으로 수리되면, **그 unit 의 다음 워커 턴에만** `worker-unit.md` 의 `[RESOLVED GAPS]`(`${GAP_CONTEXT}`) 블록에 각 항목의 ID·원 질문·선택지·`decisions.md` 답
  줄·approach.md 참조를 넣는다(`doc-gap-resume.json` 의 `gaps[].key` 와 태그로만 연결, 다른 unit 의 gap 은 넣지 않음, 정상 최초 호출은 빈 블록). 답이 없거나 일부만 있으면 해결로 추정하지 않는다(기존 WAITING_USER 계약). 전달 항목은 `units/<id>/resolved-gaps.json` 에 남고, 그 턴이 같은 ID·같은 질문·같은 위치를 다시 undecided 로 내면 세션 수용 전에 `RESOLVED_GAP_REPEATED` 로
  멈추고, 그 턴의 변경을 턴 이전 tree 로 되돌린 뒤에만 재개된다(`references/exit-states-resume.md` 의 `RESOLVED_GAP_REPEATED` 절). 회귀: `tests/smoke-resolved-gap-context.sh`.
- **기존 전체 review / verify 는 그대로다.** 모든 unit 완료 후 unit 별 `worker-result.json` 을 합쳐 `.agent-work/worker-result.json` 으로 두고 기존 `impl-review-loop.sh`(워커 진입 기준선 대비 전체 feature diff) → verify(`TEST_CMD`/`LINT_CMD`) 를 현재와 동일하게 수행한다. 컨벤션·설계 일치 판정은 전부 이 전체 review 의 책임이며, unit 분할은 그 책임을 줄이지 않는다.

이 정책의 회귀는 `tests/smoke-implementation-units.sh`(LLM 호출 없음, mock claude/fake codex): 01→02→03 직렬·겹침 없음 / Unit 01 실패 시 02 미호출 / 03 중단 후 재실행은 03 부터 / spec_hash 불일치 체크포인트 무효 / lock≠원본·호출 중 변경 → `UNITS_MANIFEST_CHANGED` / unit scope 밖 → `UNIT_SCOPE_VIOLATION`(원복 없음) / unit 사이 리뷰어·수정자
호출 0회 / targeted test 실패 → fix → 재테스트 · 재시도 소진 / 모든 unit 뒤 final review 1회 → verify → DONE / manifest 변경 시 impl PASS 무효 / 스키마·부분집합 검사 / **Feature 당 Worker 세션 1개**(01 `--session-id`, 02/03 과 test-fix 는 같은 ID `--resume`, 저널 일치) / 워커 응답 직후 중단 시 유효 결과 + after-tree 일치면 CLI 재호출 없이
테스트부터 재개 / 세션 전제(모델·세션 파일) 불일치 → `WORKER_SESSION_MISMATCH`(모델 0회), 복구 후에만 같은 세션 재개 / 예전 fresh-워커 잔존 → `WORKER_SESSION_MISSING`(묵시적 마이그레이션 금지, `worker-session.migrate` 후에만 새 세션) / 임계치 도달 시 unit 경계에서만 세션 교체(handoff 스키마·tree 검증, 변조 시 fresh 거부) / codex 워커도 세션 1 thread(thread_id 는
원장에만, 저널은 `session_bound` — 원장 소실·결속 불일치 fail-closed) / rolling context(01 fact → 02 프롬프트, 실패 unit 미확정, fix 정정 반영, 같은 키 replace, remove 미전달, 재개 시 전달, 무효 체크포인트 미재사용, 추가 모델 호출 0회) / 앞 unit 무효화 + 뒤 unit 완료 → `UNIT_CHECKPOINT_CHAIN_STALE`(워커 0회, 원복 없음).

## 프로젝트 빠른 검사 (선택 — 리뷰 전 결정론적 검사)

적용 프로젝트가 제공한 빠른 컨벤션 검사 명령을 LLM 구현 리뷰어 호출 전에 실행해, 명백한 위반에 리뷰 호출을 쓰지 않게 한다. 하네스는 명령 연결·결과 구분·증거 보존·실패 처리만 한다 — 어떤 도구로 무엇을 검사할지는 프로젝트가 정하고, 언어·프레임워크별 규칙은 스킬에 없다. 구현: `scripts/fast-check.sh`(실행), `scripts/impl-review-loop.sh`(게이트), `scripts/feature-run.sh`(위반·오류 처리).

**설정** (`config.sh` 사용자 설정 영역, 둘 다 선택)

```bash
FAST_CHECK_CMD="scripts/convention-check.sh"   # 비어 있거나 줄이 없으면 미설정
FAST_CHECK_TIMEOUT_SEC=120                      # 제한 시간(초, 양의 정수)
```

- 미설정(빈 값, 또는 이 줄이 없는 기존 config.sh)이면 종전 흐름 그대로다. 로그에 `[fast-check] 생략(…): FAST_CHECK_CMD 미설정` 한 줄만 남고, 실행·통과로 집계하지 않으며 `fast-check/` 기록도 만들지 않는다.
- 진행 중인 피처가 있을 때 켜거나 끄지 않는다. 설정 여부는 워커 세션 계약 지문에 들어가므로(검사 위반 수정 프롬프트 `worker-check-fix.md` 를 워커가 받을 수 있는가) 도중에 바꾸면 다음 워커 호출이 `WORKER_SESSION_MISMATCH` 로 멈춘다. 명령 문자열만 바꾸는 것은 지문과 무관하다.

**명령 계약**

- 실행 위치: **피처 worktree 루트**(`git rev-parse --show-toplevel`)에서 `bash -c "$FAST_CHECK_CMD"`, stdin 은 `/dev/null`. 상대 경로 명령은 worktree 기준이므로 검사 스크립트는 저장소에 커밋돼 있어야 worktree 에 존재한다.
- 환경 변수: `FAST_CHECK_ROOT`(worktree 루트 절대 경로), `FAST_CHECK_CHANGED_FILES`(이번 피처가 바꾼 파일 목록 파일의 절대 경로 — 한 줄에 저장소 상대 경로 하나, 삭제 제외, feature-scope 범위 안, 기준은 워커 진입 기준선). 변경 파일만 검사하려는 도구가 쓰며, 쓰지 않아도 된다. 경로는 git 의 인용 표기가 아니라 실제 문자열 그대로다(한글·공백·따옴표 포함 — 경로 안의 개행만 표현하지 못한다).
- 종료 코드: `0` = 정상 완료(위반 없음) / `1` = 규칙 위반 / 그 외 = 실행 오류. 기존 도구의 종료 코드가 다르면(예: 위반을 2 로 알림) 프로젝트의 얇은 어댑터 스크립트가 이 셋으로 옮긴다.
- 진단: 위반(exit 1)이면 수정에 필요한 규칙·파일·위치·내용을 stdout/stderr 로 낸다. 형식은 자유다(별도 결과 스키마 없음) — 워커가 그 원본을 그대로 읽는다. exit 1 인데 출력이 비어 있으면 실행 오류(`NO_DIAGNOSTICS`)다.
- 읽기 전용 위반 뒤의 재실행(세 검사 공통 엔진): 마지막 기록이 index 를 바꾼 실행이면 현재 index 지문이 그 실행 전 지문(`index_before`)으로 돌아오기 전에는 명령을 실행하지 않고 같은 `INDEX_MODIFIED` 로 멈춘다 — 실행 전후만 비교하면 바뀐 index 를 둔 재실행이 '이번에는 안 바꿨다'로 통과한다. 새 기록은 쓰지 않는다(마지막 기록은 그 위반 그대로).
- 읽기 전용: 자동 수정·포매팅·파일 생성/삭제·`git add` 를 하지 않는다. 러너가 실행 전후의 작업 트리 tree 스냅샷(gitignore 적용, `.agent-work` 제외)과 git index 지문을 비교해, 달라졌으면 종료 코드와 무관하게 실행 오류(`WORKTREE_MODIFIED`/`INDEX_MODIFIED`)로 멈춘다. 변경은 원복하지 않는다(범위 밖 경로는 `out_of_scope_paths` 로 따로 기록). gitignore 된 도구 캐시는 영향이 없다.
- 타임아웃: 명령은 자기 프로세스 그룹에서 돈다. `FAST_CHECK_TIMEOUT_SEC` 를 넘으면 그룹 전체(명령이 띄운 자식·손자 포함)에 TERM → KILL 을 보내고, 정리가 끝난 뒤에 사후 비교를 해 실행 오류(`TIMEOUT`)로 처리한다. TERM 을 무시하는 자식이 판정 뒤에 소스를 바꾸지 못한다(`setsid` 로 그룹을 벗어난 프로세스는 잡지 못한다).

**실행 시점** — 리뷰어를 부르기 직전마다 한 번(같은 경계에서 두 번 돌지 않는다)

- 모든 unit 완료 뒤 첫 구현 리뷰어 호출 전.
- 수정자(Fixer) 완료 뒤 다음 리뷰어 호출 전.
- 다른 수정 경로에서 전체 리뷰로 돌아올 때: verify 실패의 워커 수정(`worker-fix.md`) 뒤, 리뷰 DOC_GAP 의 review-gap 워커 뒤, 재개로 리뷰어 차례가 된 때, 저장된 리뷰 출력을 재사용하는 재개.
- 승인 체크포인트를 재사용하기 전(리뷰어 호출 없음). 그래서 검사가 설정된 설치는 verify 로 바로 재개하는 실행도 review 를 지난다 — 승인 뒤 검사가 새로 설정됐거나 규칙 입력이 바뀌었을 수 있다.
- unit 마다 돌지 않는다. unit 의 `targeted_test`, 최종 `TEST_CMD`/`LINT_CMD`, 승인 지문 재확인은 그대로다 — 이 검사는 그것들을 대신하지 않는다.
- 성공 캐시는 없다. `fast-check/last.json`·`history.jsonl` 은 증거일 뿐이고 어떤 게이트도 과거 PASS 기록으로 검사를 건너뛰지 않는다.

**결과 처리**

- 통과: 그대로 리뷰어 호출(또는 승인 재사용)로 간다.
- 규칙 위반(리뷰 루프 exit 5): 리뷰어를 부르지 않고 리뷰 체크포인트도 바꾸지 않는다. 리뷰 JSON 이 없으므로 수정자(입력 계약 = 리뷰 JSON)를 쓰지 않고, verify 실패와 같은 형태로 **Feature Worker 세션의 수정 턴 1회**(`prompts/worker-check-fix.md`, 진단 로그 경로 전달) → review 재진입 → 검사부터 다시 → 통과한 코드만 리뷰어로 간다.
  수정이 코드를 바꾸면 그 전의 리뷰·승인은 지문이 달라 재사용되지 않는다(수정자 뒤였다면 새 attempt Round 1). 한도는 `MAX_TEST_RETRIES` 를 재사용하되 verify 재시도와 따로, 피처 전체에 누적해 끝난 수정 턴만 센다(`run-state.json` 의 `fast_check_retries`). 소진되면 `FAST_CHECK_RETRIES_EXHAUSTED`.
- 워커 수정 턴의 범위 밖 수정·index 변경·기준선/manifest 변조·결과 불확실은 기존 게이트(`SCOPE_VIOLATION`, `WORKER_OUTCOME_UNCERTAIN` 등)가 그대로 처리한다. 규칙이 합의 문서·conventions 와 충돌하거나 모호하면 워커가 `UNDECIDED` 로 돌려보내 사용자 결정 경로(`doc-gap-resume.json`)로 간다 — 이 경우 한도를 쓰지 않는다.
- 수정 턴은 `run_worker` 가 돌아왔을 때만 끝난 것이다. 러너는 호출 직전에 진행 기록(`check-fix.pending.json`)을 남기고, 시작할 때마다 모델·검사 호출 전에 그 턴을 판정한다: 작업 트리가 호출 전과 같으면 기록을 닫고 진행 / 바뀌었는데 호출 후 tree 기록이 없으면(CLI 도중 중단) `WORKER_OUTCOME_UNCERTAIN` / 호출 전 tree 이후 범위 밖 경로가 바뀌어 있으면 `SCOPE_VIOLATION` / 범위 안 변경 + 유효한 DONE 결과면 재호출 없이 끝난 턴으로 확정 / 유효한 UNDECIDED 결과면(코드를 바꾸지 않은 턴 포함) 그 턴의 미결정 체크포인트(`doc-gap-resume.json`)가 있는지 확인하고, 없으면 결과 JSON 에서 다시 기록해 `UNDECIDED` 로 멈춘다(작업 트리가 그 턴의 호출 후 tree 와 다르면 기록하지 않고 `WORKER_OUTCOME_UNCERTAIN`) / 결과가 없거나 깨졌으면 `WORKER_OUTCOME_UNCERTAIN`.
  확정은 멱등이다 — 진행 기록의 `retries_before`(호출 전 한도 값)와 `check-fix-NN-merge-base.json`(호출 전 `worker-result.json` 사본)으로 계산하므로, 확정 도중 중단돼 같은 DONE 을 다시 확정해도 한도와 리뷰 입력 병합은 한 번만 반영된다.
  그래서 수정 도중 강제 종료되거나 게이트에서 멈춘 턴을 그대로 재실행해도 그 변경이 범위 검사 없이 리뷰·DONE 으로 가지 않고, 반쯤 적용된 편집 위에 같은 수정 턴이 다시 돌지 않는다.
- 실행 오류(리뷰 루프 exit 6): 통과·생략·위반 어느 것으로도 처리하지 않고, 리뷰어·수정자·워커를 부르지 않은 채 `FAST_CHECK_ERROR` 로 멈춘다. kind: `COMMAND_NOT_RUNNABLE`·`TIMEOUT`·`UNEXPECTED_EXIT`·`NO_DIAGNOSTICS`·`INVALID_CONFIG`·`WORKTREE_MODIFIED`·`INDEX_MODIFIED`.
- 재개: 어느 중단이든 같은 명령으로 재실행하면 같은 지점에서 검사부터 다시 한다. 실패 상태에서는 승인 지문이 생기지 않으므로 verify·DONE·finalize 로 갈 수 없다. reason 별 복구는 `references/exit-states-resume.md` 의 `FAST_CHECK_RETRIES_EXHAUSTED`·`FAST_CHECK_ERROR` 절.

**산출물** (`.agent-work/fast-check/` — 실행마다 새 번호, 덮어쓰지 않는다)

- `check-NNNN.log`: 명령의 stdout+stderr 원본. `check-NNNN.changed-files.txt`: 넘긴 변경 파일 목록. `check-NNNN.timeout`: 타임아웃으로 종료시킨 실행에만.
- `last.json` / `history.jsonl`: `status`(PASS·VIOLATION·ERROR), `kind`, `cmd`, `cwd`, `exit_code`, `timed_out`, `duration_sec`, `log`, `tree_before`/`tree_after`, `index_modified`, `modified_paths`, `out_of_scope_paths`, `label`(어느 경계의 실행인지), 시작·종료 시각.
- 워커 수정 턴: `check-fix-NN-result.json`, `check-fix-NN-before.tree`/`-after.tree`, 원문 로그 `reviews/check-fix-NN-*.log`, 병합 기준 `check-fix-NN-merge-base.json`, 진행 기록 `check-fix.pending.json`(`active`·`tag`·`retries_before`·`outcome` — 지우거나 고쳐서 넘기지 않는다).

회귀: `tests/smoke-fast-check.sh`(LLM 호출 없음 — fixture 프로젝트의 정상·위반·실행 오류 명령): 미설정 생략 / 첫 검사 위반 시 리뷰어 0회 / 수정자 뒤 위반 시 다음 리뷰어 0회 / 수정 → 재검사 → 리뷰 → TEST → LINT 순서 / 한도 소진·실행 오류·타임아웃·읽기 전용 위반 / worktree 실행 / 승인·과거 PASS 기록 오용 방지 / 혼합 설치 / 한글 경로 전달 / TERM 무시 자식 정리 / 수정 턴 도중 강제 종료·범위 위반 뒤 재실행 / 미결정 체크포인트 기록 전 중단(질문 복구) / 확정 도중 중단(한도·병합 1회) / codex 워커의 거부된 호출(`SESSION_RESUME_UNCERTAIN`)이 resume marker 를 지우지 않음.

## Unit 정적 검사 · 위험도별 추가 검증 (선택 — 결정론적 검증 게이트)

두 검사 모두 프로젝트가 제공한 명령을 하네스가 연결만 한다. 실행 엔진은 프로젝트 빠른 검사와 같은 하나(`scripts/fast-check.sh` 의 `project_check_run`)이고 계약도 같다: 피처 worktree 루트에서 `bash -c`, exit 0 = 정상 / exit 1 = 위반(진단 출력 필수) / 그 외·타임아웃 = 실행 오류, 읽기 전용(실행 전후 tree·index 비교), 실행마다 새 번호의 로그·기록, **성공 캐시 없음**. 미설정(빈 값 또는 줄이 없는 기존 config.sh)이면 `[unit-check] 생략`/`[risk-verify] 생략` 로그만 남고 종전 흐름이다 — 생략은 통과(PASS)로 세지 않는다. 새 LLM 호출·리뷰어·수정 루프·재시도 한도는 없다.

```bash
UNIT_CHECK_CMD="scripts/unit-check.sh"     # unit 마다, targeted test 앞.  UNIT_CHECK_TIMEOUT_SEC=120
RISK_VERIFY_CMD="scripts/risk-verify.sh"   # 리뷰 승인 뒤, TEST_CMD 앞.    RISK_VERIFY_TIMEOUT_SEC=600
```

| 검사 | 실행 시점 | 대상 | 위반 처리 | 한도 |
|---|---|---|---|---|
| Unit 정적 검사 `UNIT_CHECK_CMD` | unit 워커 턴 뒤, 그 unit 의 targeted test 앞(수정 턴 뒤 매번 다시) | 그 unit 이 바꾼 파일 | 같은 unit 수정 턴(`worker-unit-fix.md`) | `MAX_TEST_RETRIES` — targeted test 수정과 공유(unit 별) |
| 프로젝트 빠른 검사 `FAST_CHECK_CMD` | 모든 unit 뒤, 리뷰어 호출 직전마다 | 피처 전체 변경 | `worker-check-fix.md` → 재검사 → 리뷰 | `MAX_TEST_RETRIES` — 피처 누적 |
| 위험도별 추가 검증 `RISK_VERIFY_CMD` | 리뷰 승인 뒤, `TEST_CMD` 앞(verify 진입마다) | 승인된 코드 | 기존 `worker-fix.md` → 재리뷰 → 재검증 | `MAX_TEST_RETRIES` — 최종 테스트 수정과 공유 |

같은 비싼 검사를 두 곳에 걸지 않는다: Unit 검사에는 빠르고 국소적인 규칙(변경 파일의 formatter 검사·lint), 빠른 검사에는 전역 규칙(아키텍처 의존성·전체 범위 규칙), 위험도 검증에는 기본 테스트가 다루지 않는 위험(권한 우회·멱등성·마이그레이션 등)을 둔다. `FAST_CHECK_CMD` 를 unit 마다 자동으로 되풀이하지 않는다.

**Unit 정적 검사** (`scripts/feature-run.sh` 의 `run_unit`)

- 환경 변수: `UNIT_CHECK_ROOT`, `UNIT_CHECK_UNIT_ID`, `UNIT_CHECK_CHANGED_FILES`(그 unit 의 시작 tree `units/<id>/before.tree` → 현재, unit scope 안, 삭제 제외 — 한 줄에 경로 하나). 목록은 입력이지 강제 범위가 아니다 — 파일 목록만으로 안전성을 판단할 수 없는 검사기는 더 넓게 검사해도 된다.
- 결과: PASS → targeted test / SKIPPED(미설정) → targeted test / VIOLATION → targeted test 까지 돌린 뒤 **수정 턴 1회**(검사 진단과 테스트 결과를 `units/<id>/unit-verify-NN.diag.log` 로 묶어 `${TEST_LOG}` 로 전달 — 검사용·테스트용 턴을 따로 쓰지 않는다) → 검사·테스트 재실행 / ERROR → 워커·테스트 호출 없이 `UNIT_CHECK_ERROR`.
- 수정 턴은 기존 unit 게이트(index·manifest·기준선·feature scope·unit scope·결과 계약·세션 수용)를 그대로 지난다. 워커 프롬프트 템플릿은 바뀌지 않았다(워커 세션 계약 지문 불변 — 검사를 켜거나 꺼도 `WORKER_SESSION_MISMATCH` 가 아니다).
- 완료 조건: 워커 결과 계약·unit scope·unit 계약 지문·targeted test PASS 에 더해, 설정돼 있으면 **같은 회차의 검사 PASS**. 한도 뒤에도 위반이 남으면 `UNIT_CHECK_RETRIES_EXHAUSTED`(테스트도 실패했으면 종전대로 `UNIT_TEST_RETRIES_EXHAUSTED`) — `done.json` 을 쓰지 않는다.
- 재개: 미완료 unit 은 재개할 때마다 검사부터 다시 한다(과거 PASS 기록으로 건너뛰지 않는다). 유효한 워커 결과 + tree 일치면 워커 재호출 없이 검사 → 테스트부터다.
- 증거의 결속: 완료 unit 의 증거는 `units/<id>/unit-check/last.json` 이다 — status PASS 에 더해 그 PASS 가 **무엇을 무엇으로 검사한 것인지**를 세 값으로 든다(`done.json` 형식은 그대로다).
  `cmd_sha256`(명령 문자열) · `subject_fingerprint`(그 unit 의 scope — files + new_file_roots — 안 경로의 내용 = 검사 대상 코드) · `policy_fingerprint`(정책 입력 = 검사 스크립트·규칙·설정의 내용). 두 지문은 작업 트리 tree 의 해시다(모델 호출 없음).
  정책 입력은 세 부분의 합이다: ① 어느 unit 의 scope 에도 속하지 않는 경로 전부 ② `UNIT_CHECK_CMD` 의 토큰 중 작업 트리의 파일인 것(검사 스크립트 자체) ③ `config.sh` 의 `UNIT_CHECK_POLICY_PATHS`(선택 — 공백 구분 저장소 상대 경로, 파일·디렉터리)로 선언한 경로. ②③ 은 어느 unit 의 scope 안에 있어도 포함된다 — ① 만으로는 **다른 unit 이 소유한 규칙 파일**(그 unit 의 scope 안이라 ① 에서 빠진다)이 바뀌어도 지문이 그대로이기 때문이다. 선언한 경로가 작업 트리에 없으면(오타·gitignore) 검사를 실행하지 않고 `ENV_ERROR` 다(빈 지문으로 넘어가지 않는다).
  러너는 이 판정을 unit 루프에 들어가기 전에 먼저 한다(모델·검사 명령 0회): 없는 경로는 워커를 부르기 전에 `ENV_ERROR` 로 멈춘다. 예외는 하나다 — 첫 unit 이 아직 실행 전이고 그 경로가 그 unit 의 scope 안이면(워커가 만들 규칙 파일) 통과시키고, 만들어지지 않으면 그 unit 의 검사에서 종전대로 멈춘다. 뒤 unit 만 만들 수 있는 경로는 앞 unit 의 검사 시점에 없으므로 통과시키지 않는다.
  셋 중 하나라도 지금과 다르면 과거 PASS 를 쓰지 않는다: 완료 뒤 검사를 새로 켰거나 명령을 바꿈 / 뒤 unit(겹치는 scope)·수정자·worker-fix·사용자가 그 unit 의 코드를 고침 / 명령 문자열은 같고 검사 스크립트·규칙만 바뀜 / 지문이 없는 이전 형식의 기록.
  전체 tree 를 통째로 비교하지 않는다 — 다른 unit 의 scope 에만 속한 변경(독립 unit 의 정상 작업)은 이 unit 의 증거를 무효화하지 않는다.
- 재검증: 증거가 현재 것이 아니면 **워커 재호출 없이 그 unit 의 검사만** 다시 돌린다(LLM 호출보다 결정론적 재검증이 먼저다). 판정 지점은 ① 러너 시작(stage 결정 — review·verify 로 바로 가지 않고 worker stage 로) ② 완료 unit 을 건너뛸 때(`run_unit`) ③ **review·verify 진입마다**(같은 실행 안에서 뒤 unit·수정자·worker-fix 가 이미 검사한 코드를 바꾼 경우 — 리뷰어·`TEST_CMD` 앞). 수정자가 바꾼 경우도 다음 리뷰어 호출 **전**이다: 리뷰 루프가 수정자 뒤에 지문만 비교해(검사 명령·모델 0회) 낡았으면 exit 7 로 러너에 돌려보내고, 러너가 ③ 의 재검증을 한 뒤 같은 attempt 의 리뷰어로 돌아간다(새 루프·새 한도 없음 — 위반 코드에 리뷰어 호출을 쓰지 않는다). 통과하면 증거를 갱신하고 체크포인트를 유지하며, 위반이면 `UNIT_CHECK_STALE_VIOLATION`(완료된 unit 에 자동 수정 턴을 다시 열지 않는다 — 직렬 체크포인트 사슬 보존). 검사를 끄면(빈 값) 요구할 증거가 없다 — 끄는 것은 사용자가 명시적으로 정할 때만.
- 읽기 전용 위반(`WORKTREE_MODIFIED`·`INDEX_MODIFIED`)으로 멈춘 뒤에는 **검사가 만든 변경이 실제로 해소될 때까지** 재실행이 검사·모델 0회로 다시 멈춘다: 그 실행이 바꾼 경로(`tree_before` → `tree_after`)가 전부 검사 전 내용으로 돌아오고, index 지문이 검사 전 지문(`index_before`)과 같아야 한다. 다른 파일을 더 고쳐 tree 가 달라진 것, 검사기를 고쳐 '이번 실행은 아무것도 안 바꾼' 것은 복구가 아니다(검사가 만든 변경이 unit scope 검사를 거치지 않고 다음 워커 턴의 '호출 전 tree' 에 섞이는 것을 막는다). 자동 원복은 없다. 복구가 확인되면 `unit-check/readonly-restored.json` 표식을 남긴다(그 뒤의 정상적인 코드 변경을 같은 위반으로 다시 세지 않는다).
- 실행 로그: `targeted-test-NN.log`·`unit-verify-NN.diag.log` 의 NN 은 unit 디렉터리 안에서 이어서 센다 — 재개한 실행이 01 부터 다시 써서 앞선 실행의 로그를 덮어쓰지 않는다. `targeted-test.history.jsonl`(append-only)의 각 행은 그 실행 당시의 로그를 계속 가리킨다.
- 제한: 하네스는 검사기가 실제로 무엇을 읽는지 알 수 없다. 지문에 없는 것 — ⓐ gitignore 된 설정·전역 도구 버전 같은 트리 밖 입력 ⓑ 어느 unit 의 scope 안에 있으면서 명령 문자열에도 `UNIT_CHECK_POLICY_PATHS` 에도 나오지 않는 규칙·설정 파일 ⓒ 검사기가 다른 unit 의 코드까지 읽는 교차 파일 규칙. ⓑ 는 프로젝트가 `UNIT_CHECK_POLICY_PATHS` 에 선언해 닫는다(이번 피처가 규칙 파일을 직접 고치는 경우에만 필요하다 — 선언은 재검증을 늘릴 뿐 줄이지 않는다). ⓐⓒ 는 캐시 없는 프로젝트 빠른 검사·리뷰·verify 가 맡는다. 모든 unit 변경마다 전체를 다시 검사하는 방식은 쓰지 않는다(unit 수 × 검사 시간). 어느 unit 의 scope 에도 없는 파일이 하나라도 바뀌면 모든 완료 unit 을 다시 검사한다(보수적 — 검사 명령의 실행 시간만 든다).

**위험도별 추가 검증** (`scripts/feature-run.sh` 의 verify stage)

- 프로젝트 명령 하나가 변경(`RISK_VERIFY_CHANGED_FILES` — 빠른 검사와 같은 목록, `RISK_VERIFY_ROOT`)을 보고 위험도를 판정하고 그 위험도에 필요한 검증을 직접 수행한다. 하네스에는 위험도 규칙·정책 DSL·테스트 명령이 없다.
- 결과 JSON(`$RISK_VERIFY_RESULT` 경로에 명령이 쓴다): `{"risk_level":"LOW|MEDIUM|HIGH|CRITICAL|UNKNOWN", "checks":[{"name":"…","status":"PASS|FAIL|SKIPPED"}], "reasons":["…"], "needs_human":false}` — `risk_level` 만 필수. `checks`·`reasons` 는 있으면 항목 형식까지 검사한다(`checks[]` = 비어 있지 않은 문자열 `name` + `status` 가 PASS·FAIL·SKIPPED 중 하나, `reasons[]` = 문자열).
  LOW = 국소 변경(추가 검증 없음) / MEDIUM = 일반 기능·API 변경(필요한 계약 테스트) / HIGH = 인증·인가·결제·동시성·데이터 정합성(추가 계약·보안·통합 테스트) / CRITICAL = 데이터 손실 가능·파괴적 변경(강화된 검증, 필요하면 `needs_human`) / UNKNOWN = 규칙으로 판정할 수 없음.
- 판정(하네스): exit 0 + 유효한 결과 + LOW~CRITICAL + `needs_human` 아님 → PASS → `TEST_CMD`. exit 1(+ 진단) → VIOLATION. exit 0 인데 결과가 없거나 형식이 틀림(`checks`·`reasons` 항목 형식 포함) → 실행 오류 `RESULT_INVALID`(**위험도를 LOW 로 가정하지 않는다** — 기록의 `risk_level` 은 UNKNOWN). exit 0 인데 `checks` 에 `FAIL` 이 있음 → 실행 오류 `RESULT_INCONSISTENT`(종료 코드와 개별 검증 결과가 모순 — **통과로 받지 않고 코드 위반으로도 보내지 않는다**: 검증 명령의 결과 계약 오류다. 실패한 검증이 있으면 명령은 exit 1 + 진단을 내야 한다). `risk_level=UNKNOWN` 또는 `needs_human=true` → `RISK_VERIFY_NEEDS_USER`(모델에게 추측·수정을 맡기지 않는다).
- VIOLATION: `TEST_CMD` 실패와 같은 경로다 — 기존 `worker-fix.md` 1회(진단 묶음 `risk-verify/check-NNNN.diag.log` 를 `${TEST_LOG}` 로) → **review(재승인 필수)** → verify 재진입 시 검증부터 다시. 한도 `MAX_TEST_RETRIES` 를 최종 테스트 수정과 공유하고(`run-state.json` 의 `test_retries`) 소진되면 `RISK_VERIFY_RETRIES_EXHAUSTED`. 승인 없이 수정된 코드가 `TEST_CMD`·DONE 으로 가는 경로는 없다.
- ERROR(도구 누락·타임아웃·해석 불가 종료 코드·읽기 전용 위반·`RESULT_INVALID`·`RESULT_INCONSISTENT`): 워커를 부르지 않고 한도도 쓰지 않은 채 `RISK_VERIFY_ERROR`. 검증이 범위 안 소스를 바꿨으면 승인 지문이 달라져 재리뷰를 지나야 한다. 검증이 git index 를 바꿨으면(`INDEX_MODIFIED`) index 지문이 검증 전(`index_before`)으로 돌아오기 전의 재실행은 stage 와 무관하게 검증 명령·리뷰어·`TEST_CMD` 0회로 다시 멈춘다(자동 복구 없음).
- 사람의 확인(`needs_human`)을 어떻게 받는지는 프로젝트가 정한다 — 검증 명령이 자기 승인 조건(예: 프로젝트가 정한 승인 기록)을 확인해 충족되면 `needs_human` 없이 통과시킨다. 하네스에는 별도 승인 상태가 없다.
- verify 에 들어올 때마다 실행한다(재개·수정 뒤 재승인 포함). 이전 PASS 를 캐시하지 않으므로 승인·코드가 달라진 뒤 옛 검증 결과가 쓰이는 일이 없다. 이미 `TEST_CMD`/`FAST_CHECK_CMD` 가 돌리는 검사를 여기서 되풀이하지 않는 것은 프로젝트 명령의 몫이다(`.agent-work/fast-check/last.json` 의 `tree_after` 로 같은 코드에 대한 결과인지 직접 대조할 수 있다).

**산출물**: `units/<id>/unit-check/`·`risk-verify/` 에 빠른 검사와 같은 형식(`check-NNNN.log`, `last.json`, `history.jsonl`) + unit 검사 기록의 `unit_id`, 위험도 검증 기록의 `risk_level`·`result_valid`·`needs_human`·`checks`·`reasons`·`result`(`check-NNNN.result.json`). 실행 기록(증거 — 재개 판정에 쓰지 않는다): `units/<id>/targeted-test.history.jsonl`, `reviews/verify.history.jsonl`. 최종 검증 로그는 `reviews/verify-<YYYYMMDD-HHMMSS>.log` 이고 같은 초에 다시 돌면 `-2`, `-3` … 이 붙는다(기록이 가리키는 앞선 로그를 덮어쓰지 않는다).

## 검사 계획 사전 전달 · 검사 진단 요약 (선택 검사가 설정됐을 때만)

워커가 코드를 쓰고 난 뒤에야 검사 규칙을 알게 되면 수정 턴(unit test-fix · check-fix)이 한 번씩 더 든다. 러너는 워커 호출 **직전**에 설정값과 작업 트리만으로 작은 검사 계획을 만들고(검사 명령·모델 호출 0회), 긴 검사 출력은 코드로 색인해 요약만 먼저 보게 한다. 새 stage·새 검사 엔진·새 수정 턴·새 리뷰어 호출은 없다 — 실제 검사는 종전 위치에서 종전대로 다시 돌고, 판정은 종료 코드다.

**검사 계획 (`check-plan.json`)** — `scripts/fast-check.sh` 의 `check_plan_prepare`
- 위치: unit 턴은 `units/<id>/check-plan.json`, 그 밖의 워커 턴(check-fix · verify worker-fix · review-gap)은 `check-plan.json`. 둘 다 그 worktree 의 산출물 디렉터리 안이다.
- 내용: `unit_id` · `unit_scope`(scope.json 경로) · `checks[]`(unit-check / fast-check 각각 설정 여부·명령·실행 시점·`policy_paths`·`rule_sources`) · `guide`(선택 안내 문서의 경로·지문) · `conventions` · `targeted_test` · `later_stages`(TEST/LINT/RISK 의 실행 시점만) · `fingerprint` · `changed_since_previous` · `advisory:true`.
- `policy_paths` 는 **선언된 것만**이다: `UNIT_CHECK_POLICY_PATHS` 와, 명령 문자열의 토큰 중 작업 트리의 파일인 것(정책 지문과 같은 규칙). 명령 문자열을 해석해 규칙을 추측하지 않는다 — 선언된 경로가 없으면 `rule_sources` 는 `"unknown"` 이다.
- `CHECK_GUIDE_FILE`(config.sh, 선택): 프로젝트가 쓴 검사 규칙 안내 문서 하나의 worktree 상대 경로. 설정했으면 워커 호출 전에 검증한다(저장소 상대·canonical·glob 없음·worktree 안의 일반 파일) — 틀리면 `ENV_ERROR`, 모델 호출 0회. 본문은 프롬프트에 붙이지 않고 경로·지문만 전달한다. 줄이 없는 기존 config.sh 는 미설정이다.
- Unit 검사·빠른 검사·안내 문서가 **전부 미설정이면 아무것도 만들지 않는다**(파일·프롬프트 블록·추가 스냅샷 없음). 미설정 검사는 계획에 `disabled` 로 적힌다 — 통과가 아니다.
- 워커 프롬프트(`worker-unit.md` · `worker-unit-fix.md` · `worker-implement.md` 의 `${CHECK_PLAN}`)에는 경로와 짧은 요약만 들어간다. 블록이 금지하는 것은 검사를 통과시키거나 피하려는 검사 명령·스크립트·규칙/설정 파일 변경과 억제 표시다 — 합의 문서가 요구하고 그 작업 scope 안에 있는 규칙·설정 파일 변경은 정상 구현으로 둔다. 수정 턴의 지시(unit 진단 묶음의 "수정 규칙" · `worker-check-fix.md` · 위험도별 검증 진단 묶음)도 같은 원칙이다: 우회·억제 목적의 정책 변경만 금지하고, 합의 문서가 명시적으로 요구한 scope 안 정책 파일 변경은 허용하며, 계약과 검사 규칙이 충돌하면 UNDECIDED 다. 전달 범위는 규칙 재전달과 같은 경계다: fresh 세션 최초 턴·규칙 재전달 경계·unit 구현 턴·지문이 바뀐 계획은 전문, 같은 작업 단위의 후속 턴(unit 수정 턴)은 한 줄(경로·지문·변경 없음)이고, 그 사이 계획 지문이 바뀌었으면 '직전 계획에서 바뀜' 표시와 함께 전문이다. `worker-check-fix.md` 는 계획 파일 경로를 고정 문장으로 가리킨다.
- native 워커 요청: 계획은 요청 발행(PREPARE) 전에 한 번 만들어 payload 에 실리고, 재실행 pass 는 다시 만들지 않는다. 요청의 입력 지문에는 검사 설정(두 명령·두 제한 시간 `UNIT_CHECK_TIMEOUT_SEC`/`FAST_CHECK_TIMEOUT_SEC`·`UNIT_CHECK_POLICY_PATHS`·안내 문서 경로), 그 계획 파일, 안내 문서의 현재 내용, 그리고 계획에 실린 선언 경로(`policy_paths`) 가운데 **그 턴의 워커가 고칠 수 없는 것**의 현재 내용이 들어간다 — 요청 발행 뒤 바뀌면 `NATIVE_STALE_REQUEST` 로 불수용한다(요청을 새 설정으로 덮어쓰지 않는다). 그 턴의 쓰기 범위(unit 턴은 그 unit 의 scope, 그 밖은 feature-scope) 안에 있는 정책 파일·안내 문서의 내용은 넣지 않는다(워커가 합의된 scope 의 규칙 파일을 정상적으로 고칠 수 있고 지문은 수용 직전에 다시 계산된다 — 그 변경은 Unit 검사 증거 지문이 맡는다). 선언되지 않은 범위 밖 파일도 넣지 않는다. 작업 트리 스냅샷에 보이는 범위 밖 파일의 변경은 종전대로 범위 검사(`SCOPE_VIOLATION`)가 먼저 멈춘다 — 입력 지문은 스냅샷에 없는 입력(gitignore 된 안내 문서)과 설정값을 닫는다. 전부 미설정이면 입력 지문은 이 기능 이전과 같다.
- 계획은 어떤 게이트의 입력도 아니다. `UNIT_CHECK_POLICY_PATHS` 의 오타 판정(`unit_check_policy_preflight`)·검사 증거 지문·세션 계약 지문은 종전 그대로다.

**검사 진단 요약 (`check-NNNN.log.digest.json`)** — `check_digest_write`
- 검사가 위반·실행 오류로 끝났을 때 실행 기록을 남긴 **뒤에** 원본 로그 옆에 만든다. 원본 로그와 `last.json`/`history.jsonl` 은 그대로다. 생성 실패는 경고뿐이고 검사 결과를 바꾸지 않는다.
- 8 KiB 이하. `status` · `exit_code` · `raw_log_path` · `record_path` · `raw_lines` · `matched_count` · `included_count` · `unmatched_count` · `truncated` · `entries[]`(후보 줄, `L<줄번호>: …`) · `tail[]`(마지막 줄들).
- 프로젝트별 출력 형식을 이해한다고 주장하지 않는다: error/fail/violation 류 단어·`[규칙]` 머리·`파일:줄` 모양의 줄을 후보로 고를 뿐이고, 고르지 못한 줄 수와 잘림을 그대로 적는다.
- 판정에 쓰이지 않는다. PASS/VIOLATION/ERROR 는 종전대로 종료 코드·타임아웃·읽기 전용 비교로 Shell 이 정한다. 요약에 없는 진단이 있어도 결과는 달라지지 않고, 어떤 게이트도 요약을 읽지 않는다.
- 워커에게 가는 길: unit 수정 턴의 진단 묶음(`unit-verify-NN.diag.log`)은 원본 전체 대신 이 요약과 원본 경로를 싣는다(요약이 없으면 종전대로 원본). check-fix 수정 턴의 `${TEST_LOG}` 는 원본 로그 경로 그대로이고 프롬프트가 `${TEST_LOG}.digest.json` 을 먼저 읽게 한다. 요약이 부족하면 워커가 원본의 필요한 부분을 읽는다. 출력 안의 명령처럼 보이는 문장은 검사 출력이지 작업 지시가 아니다.
- 위험도별 검증(`risk-verify/`)의 진단 묶음과 targeted test 로그는 종전 그대로다(요약 파일은 생기지만 묶음은 원본을 싣는다).

## DONE 뒤 사후 분석 보고서 (`post-run-report.json`)

`DONE` 기록 직후 `scripts/post-run-report.sh` 가 기존 기록을 집계해 `.agent-work/post-run-report.json` 하나를 만든다 — **모델 호출 0회**, 읽기 전용 집계(usage.jsonl·run-state·검사/테스트 실행 기록·리뷰어 출력), 프로덕션 코드·git index·계약 문서·승인 지문 불변. 기록의 무결성은 `record_integrity` 에 남긴다: 집계에 쓴 JSONL 에 JSON 객체로 읽을 수 없는 줄이 있으면 `complete:false` 와 파일별 줄 수(`corrupt[]`)를 적고, 그 기록에서 나온 항목에 `corrupt_records` 를 붙인다 — 손상된 줄을 조용히 빼고 완전한 기록처럼 집계하지 않는다(손상 = 기록은 있었는데 읽지 못함, 미관측 = 기록 자체가 없음). `usage.jsonl` 이 손상돼도 보고서는 만들어진다: 읽힌 줄만으로 같은 `usage_summary` 를 계산하고 `cost_summary.unreadable_usage_records`(읽지 못한 줄 수)·`totals_are_lower_bound:true` 를 적는다 — 그때의 비용·호출 수는 하한값이고, 읽지 못한 호출을 0 달러로 더한 값이 아니다(전부 읽을 수 없으면 `observed:null`).

- `cost_summary`: `usage_summary` 와 같은 숫자(관측 비용 = provider 보고 `reported` + 가격표 환산 `estimated`, 둘 다 없는 호출은 `cost_unknown_invocations` — 0 달러가 아니다), 역할·모델별, 워커 수정 턴(unit 수정·빠른 검사 수정·verify 수정·review-gap)·리뷰어 재호출·수정자 비용, 전체 모델 호출 수, 실행 시간. `counterfactual_savings.usd` 는 항상 `null`(unknown) — 기계적 검증이 막은 횟수만 관측값이고 실행되지 않은 LLM 호출의 비용은 계산하지 않는다.
- `verification_summary`: `unit`(Unit 정적 검사·targeted test·수정 턴)과 `feature`(빠른 검사·리뷰·위험도 검증·최종 검증)를 나눠 실행·통과·위반·오류 횟수를 적는다. 기록이 없으면 0 이 아니라 `observed:false`/`SKIPPED` 다.
- `failure_analysis`: 관측된 실패 유형별 횟수·근거 경로·`candidate_cause`(후보 분류). `root_cause` 는 직접 증거가 없으면 `"UNKNOWN"`, `confirmed:false` — 근거를 모델 호출로 채우지 않는다. 실패가 없으면 빈 배열이다.
- `rule_candidates`: 반복 오류의 개선 **후보**(`CODEBASE_CONSTRAINT`·`STATIC_CHECK`·`RUNTIME_TEST`·`LLM_REVIEW_REQUIRED`·`NEEDS_HUMAN_ANALYSIS`) — 관측된 오류·반복 근거·관련 로그/리뷰 issue·자동화 가능성·오탐 위험·`auto_promote:false`. 같은 오류라는 근거가 기록에 있을 때만 만든다: 같은 규칙 id(진단 줄 맨 앞의 `[rule-id]`)가 서로 다른 검사 실행에서 반복 / 리뷰어가 같은 근거(`basis_refs[0]`)로 서로 다른 issue / 같은 issue 가 수정 뒤에도 남음. 같은 category 가 여러 번 나온 것만으로는 만들지 않는다. Feature 간 반복 여부는 항상 `unverified`(전역 오류 DB 없음).
- **분석과 후보 제시까지만 자동이다.** DONE 뒤 코드·conventions·검사 규칙을 자동으로 고치지 않는다 — 승인된 작업 트리의 승인·검증 근거가 무효가 된다. 사용자가 고른 개선은 별도 작업으로 한다.
- 멱등·실패 처리: 유효한 보고서가 있으면 다시 만들지 않는다. 이미 `DONE` 인 재실행은 워커·리뷰어·테스트·검사 명령·완료 알림을 다시 부르지 않고 보고서가 없을 때만 기존 기록에서 다시 만든다(같은 입력이면 같은 내용 — `generated_at` 은 DONE 기록 시각). 생성 실패는 경고와 `post-run-report.error.log` 만 남기고 `DONE`·exit 0 을 바꾸지 않는다. 중단(NEED_USER 등) 시의 비용 보고(`usage-summary.json`)는 종전 그대로다.

회귀: `tests/smoke-verification-gates.sh`(LLM 호출 없음 — fixture 프로젝트의 unit 검사·위험도 검증 명령): 미설정 시 종전 흐름 / PASS·위반·실행 오류·읽기 전용 위반 / 검사 위반 + 테스트 실패의 수정 턴 1회 / unit scope 게이트 / PASS 재사용 금지 / 앞 unit 체크포인트 유지 / 설정 변경 뒤 완료 unit 재검증 / 위험도 LOW·HIGH·UNKNOWN·needs_human·결과 없음 / 위반 → worker-fix → 재승인 → 재검증 / 보고서 생성·usage 집계 일치·미관측 ≠ 0·근거 있는 후보만·재생성 동일·실패해도 DONE·DONE 재실행 시 호출 0회 / 검사 PASS 뒤 코드·검사 스크립트 변경 시 완료 unit 재검증(worker-fix·수정자·겹치는 뒤 unit·수동 수정) / 읽기 전용 위반 뒤 다른 파일 수정·index 미복구 재실행 차단 / `checks` FAIL + exit 0·형식 오류 결과 / 재개 시 targeted test 로그 보존 / 손상된 JSONL 기록의 구분 / 다른 unit 의 scope 안 정책 파일(선언·명령 토큰이면 재검사, 없는 경로 선언은 ENV_ERROR) / 수정자 뒤 재검증이 다음 리뷰어 앞 / 같은 초의 verify 로그 경로 고유 / 손상된 usage.jsonl 에서도 보고서 생성(하한값 표시).

## 강제 규칙 (어길 수 없음)

- **검증자는 게이트지 설계자가 아니다.** REVISE_DOC은 여섯 가지 입장 조건(요구·결정·계약 위반 / 근거: 문서 대조 DIRECT_MISMATCH 또는 실행 경로 REACHABLE_FAILURE / 명시 계약과 다른 결과·권한·비밀·영속 데이터·구현 불가 영향 / 이번 변경이 만들거나 활성화 / 지금 결정 없이는 진행 불가 / 정확한 근거 위치)을 모두 만족할 때만, ASK_USER는 별도 네 조건(어디에도 미결정 / 동작·데이터·보안·범위가 갈림 / 기존 계약·패턴이 확정 못 함 /
  없이는 시작 불가)을 만족할 때 등록된다. 단, 이번 피처가 직접 만들거나 활성화하는 blocker가 정확히 입증되고 확정 요구·사용자 결정·범위를 함께 지킬 안전한 구현이 없을 때는 ASK_USER 1·3조건의 예외로, 충돌이 입증된 계약에 한해서만 사용자 결정을 다시 요구한다. 범위 안의 안전한 대안이 있거나 기존 결함만 있는 경우에는 적용하지 않는다.
  스키마와 러너가 근거 필드, 사용하지 않는 필드의 공백, id 유일성, Round 2 `origin`의 형식과 참조 대상 존재(직전 이슈 id, docs diff에서 실제 바뀐 파일)를 강제하며 어긋나면 검증자 응답 오류로 중단한다. 수정과 신규 blocker 사이의 의미적 인과관계까지 러너가 보장하지는 않는다
  — 그것은 `tests/validator-cases.md` 감도 회귀 세트의 몫이다. 순수 정책 미결정은 `POLICY_UNDECIDED` + `UNDECIDED_CHOICE`로 표현해 충돌 계약이나 실패 경로를 지어내지 않게 한다. 검증자 프롬프트는 두 층이다 — 공통 계약(`prompts/validator-review-design.md`/`-impl.md`:
  관할·탐색 범위·입장 조건·출력 형식, 모델과 무관)과 판정 전략 오버레이(`prompts/validator-overlays/<프로필>.md`, `[VALIDATOR PROFILE: …]` 블록으로 task prompt 끝에 붙음). 프로필은 `config.sh`의 `VALIDATOR_PROFILE`(compact / guided / conservative / none)이며 기본은 명시 `guided` 다.
  비워 두면 `validator_profile` 헬퍼가 `VALIDATOR_MODEL`의 정확한 ID 로 기본값을 고른다(gpt-6-sol·gpt-5.6-sol→compact, gpt-6-astra·gpt-6.2-astra→guided, 그 외→conservative). 오버레이는 계약을 바꾸지 못하고 "그 계약을 어떤 순서·깊이로 판정할지"만 담는다
  — 모델별로 계약 파일을 복제하지 않는다. 프로필 이름이 있는데 파일이 없으면 검증자를 부르지 않고 실패한다. 검증자 프롬프트(공통 계약·오버레이 모두)·스키마·러너 검사 중 하나라도 바뀌면 `config.sh`의 `VALIDATOR_CONTRACT_VERSION`을 올린다. 러너가 그 값과 다른 이전 PASS를 자동 무효화하므로 `--new` 없이 재실행하면 된다.
  검증자는 문서의 사실 주장을 그대로 믿지 않는다 — 명시적 convention 규칙과의 직접 충돌, 요구·확정 결정·기존 필수 계약에 근거 없는 새 제품 동작, 변경 대상의 직접 호출부·피호출부 누락으로 인한 계약 위반, 직접 범위 코드와 어긋나는 NEW 탐색 근거를 독립적으로 대조한다(확정적인 위반만 BLOCK, 탐색은 변경 대상과 직접 의존까지, 필수 파생 기술 변경·local expression 은 대상 아님).
  검증자는 최소 불변식만 요구하고 해결 방법을 처방하지 않는다. 디자이너는 5단계 판정을 거쳐 REJECT하고, ACCEPT해도 검증자의 처방을 복사하지 않는다. Round 1은 전부, Round 2부터는 직전 이슈 종결 검토와 직접 회귀만. 파이프라인 운영(git 기준선·지문·테스트 순서)은 러너 책임이며 문서 blocking 사유가 아니다.
- **리뷰어는 병합 게이트지 개선자가 아니다.** issue 는 여섯 가지 입장 조건(이번 diff 가 만든 문제 / 아홉 category 중 하나: CONTRACT_VIOLATION·UNDECLARED_BEHAVIOR·REACHABLE_BUG·SECURITY_OR_DATA_RISK·REDUNDANT_CONTROL_FLOW·REDUNDANT_CODE·TEST_CONTRACT_GAP·OUT_OF_SCOPE_CHANGE·UNDECIDED_APPROACH / 증거:
  DIRECT_MISMATCH·REACHABLE_FAILURE·SEMANTIC_REDUNDANCY / verify 전에 반드시 해결(UNDECIDED_APPROACH 는 동작이 맞아도 예외) / 기존 결함·장래 개선이 아님 / 정확한 위치)을 모두 만족할 때만 등록된다. 명명·포맷·선호 리팩터링·정상 대응 분기·`delegated_choices` 보고 누락·합의된 동작의 추가 black-box 테스트는 issue 가 아니다.
  `required_outcome` 은 결과만 적고 기법을 처방하지 않는다. action 은 `FIX_CODE`(수정자) / `DOC_GAP`(사용자 결정 — 루프 exit 3 → 러너 `NEED_USER/REVIEW_DOC_GAP`) 둘뿐이다. DOC_GAP 에는 `user_question`(비어 있지 않음)·`options`(≥2, 실제로 갈리는 solution shape 만, 우열 없음)가 필수이고 FIX_CODE 는 둘 다 빈 값이다(스키마 + 루프 검사).
  DOC_GAP 은 impl 재합의(검증자·디자이너)로 가지 않는다 — 사용자가 고른 순간 그 gap 의 설계 판단은 종결이며 review-gap 워커가 그대로 구현하고 다음 리뷰가 검증한다. 같은 리뷰의 FIX_CODE 는 그 워커가 함께 처리하므로 DOC_GAP 이 하나라도 있으면 수정자를 먼저 부르지 않는다.
  리뷰 diff 는 러너가 워커 진입 직전에 기록한 `worker-baseline.tree` 대비다(피처 이전 미커밋 변경은 이번 작업이 아니다). `OUT_OF_SCOPE_CHANGE` 는 수정자에게 가지 않는다 — 러너가 수정자 호출 전에 `FOREIGN_WORKTREE_CHANGE` 로 사용자에게 돌려보내며, 어떤 역할도 범위 밖 파일을 원복하지 않는다(`pre_bash_guard` 가 `git restore`/`checkout --`/`reset --hard` 를 차단).
  워커·수정자의 git index 조작(add/reset/stash/restore --staged)은 금지이며, 러너·루프가 호출 전후 index 지문을 비교해 바뀌었으면 자동 복구 없이 중단한다. 루프가 증거·action 별 필드, id 유일성, Round 2 `origin`(UNRESOLVED_PREVIOUS / FIX_REGRESSION / NEWLY_EXPOSED_BY_FIX)과 참조 대상을 강제한다
  — `UNRESOLVED_PREVIOUS` 는 직전 리뷰의 같은 id(`previous_issue_id`=id, `fix_ref` 빈 값), `FIX_REGRESSION`/`NEWLY_EXPOSED_BY_FIX` 는 `previous_issue_id` 빈 값 + `fix_ref` 필수이며 `fix_ref` 는 **직전 수정으로 실제 바뀐 소스 파일 경로:L시작-L끝**(패치 파일 `fix-diff-round-N.patch` 의 경로·행 번호가 아니라 수정 후 소스의 행 번호, git tree 로
  계산한 변경 hunk 와 겹쳐야 한다 — 정의 문장은 `config.sh` 의 `REVIEW_FIX_REF_RULE` 하나를 프롬프트·스키마·검사가 같이 쓴다). 어긋난 출력은 `ENV_ERROR` 가 아니라 `REVIEW_OUTPUT_INVALID`(`references/exit-states-resume.md` 의 해당 절)로 멈추고, 재실행은 리뷰어를 다시 부르지 않는다.
  Round 1 은 전부, Round 2 부터는 직전 이슈 종결 검토와 수정이 만든 직접 회귀만. 같은 이슈가 내용 변화 없이 반복되면 `DEADLOCK`. 수정자는 `FIX_CODE` 의 required_outcome 만 구현하고 잘못된 이슈는 `decisions.md` 에 `[fix round N] <id> REJECT` 로 남긴다.
  리뷰어 프롬프트·스키마·루프 검사 중 하나라도 바뀌면 `config.sh`의 `REVIEWER_CONTRACT_VERSION`을 올리고 `tests/reviewer-cases.md` 감도 회귀를 돌린다 — 유료 실행이므로 사용자 승인 후 `touch .claude/ALLOW_REAL_LLM_REGRESSION`(1회용)이 있어야 스크립트가 돈다.
  오케스트레이터가 지시 없이 만들지 않는다.
- **막히면 AI끼리 풀지 말고 사용자에게 묻는다.** 러너가 자동으로 도는 루프는 성공 조건이 기계적인 두 가지뿐 — (리뷰 이슈 → 수정자 → 재리뷰), (테스트 실패 → 워커 1회 수정 → 재리뷰 → 재테스트). unit 단계의 (targeted test 실패 → unit 범위 수정 → 재테스트)는 두 번째 형태와 같고 같은 한도를 쓴다. 교착·라운드 초과·`UNDECIDED`·재시도 소진은 전부 즉시 사용자 반환이며, 러너·오케스트레이터 어느 쪽도 "다른 에이전트에게 다시 물어보는" 자동 복구를 추가하지 않는다.
- **테스트는 동작 계약 검증용이다** — 작성 순서는 강제하지 않는다. 워커는 `implementation.md`가 명시한 동작 계약을 검증하는 테스트만 쓰고, 테스트 편의만을 위한 운영 API·분기·추상화·가시성 변경과 커버리지 수치 목적의 테스트는 금지. 리뷰어는 명시 요구 테스트의 누락, 내부 호출·private 상태만 검증하는 테스트, 테스트 편의용 운영 코드 변경을 `TEST_CONTRACT_GAP` 으로 올린다. 이미 합의된 외부 동작을 검증하는 추가 black-box 테스트는 문서에 이름이 없어도 issue 가 아니다.
- **합의 문서는 코드 diff 를 사전에 고정하지 않는다 — material implementation contract 를 고정한다.** `implementation.md`+`approach.md` 가 material decision(외부 동작·API 계약, public/package 계약, 영속 데이터, transaction/lock/concurrency, 보안 경계, 책임 배치, REUSE/EXTEND vs 새 병렬 책임, sync/async, retry/fallback/cache/error
  semantics, 외부 호출 topology·횟수, 의미 있는 비용 특성, 새 production 구조물, 사용자·convention 이 직접 요구한 방식)을 결정하고 검증자가 합의한다(검증자 `CODE_SPEC_GAP` = material 구현 계약 하나가 열려 있음, 일곱 입장 조건 + "이 선택을 워커에게 맡기면 제품/아키텍처/책임 경계/상태 의미/I/O 비용/안전성 중 무엇이 달라지는가" gate
  — helper/local naming/intermediate/if·switch/for·stream/동등 overload/bounded local collection 표현은 근거가 아니다). 워커는 그 계약 안에서 convention → material contract → 직접 범위의 기존 표현 → 관용 표현 → 가장 단순한 구현 순으로 local implementation expression 을 직접 고르되, 문서가 요구하지 않은 standalone production
  class·interface·repository·service·converter·shared helper·새 persistence/query path·새 state/result/context abstraction 은 만들지 않는다(local autonomy 는 확대, architectural surface area autonomy 는 확대하지 않음).
  워커·수정자가 material REQUIRED 와 다른 기법·책임 위치·호출 횟수·상태 순서를 쓰거나 REUSE/EXTEND 로 지정된 symbol 옆에 같은 책임의 병렬 구현을 만들면 **동작이 같아도** 리뷰어가 `CONTRACT_VIOLATION` 으로 잡고, 단순 직접 구현으로 완전히 대체 가능한 새 standalone abstraction 은 `REDUNDANT_CODE` 로 잡는다.
  반대로 helper/local naming/intermediate/if·switch/for·stream/동등 overload/bounded collection 표현/반환 직전 alias 의 차이는 approach.md 가 REQUIRED 로 적어 두었더라도 issue 가 아니다(명시 convention·사용자 결정이 요구한 경우만 예외)
  — 문서에 적혀 있다는 사실만으로 모든 문장이 동등한 강도의 contract 가 되는 것은 아니다. 리뷰어의 근거는 문서·project convention·인용된 reference 뿐이며 문서가 지정하지 않은 재사용 후보를 찾지 않는다. 워커가 material decision(책임 위치, shared component 확장 vs 병렬 책임, 호출 횟수가 달라지는 접근, transaction/lock/cache/retry, 외부 동작이 달라지는 분기, 새 standalone abstraction
  필요 여부)을 문서·reference·convention·직접 범위 precedent 어디서도 찾지 못하면 `DOC_GAP` 으로 돌려보내고, 골라 버렸으면 리뷰어가 `UNDECIDED_APPROACH` + `DOC_GAP` 으로 잡는다 — 어느 쪽이 나은지는 판단하지 않는다. local expression 으로는 DOC_GAP 을 만들지 않는다.
  합의의 역할 경계: design consensus = 구현 전 요구·설계 계약 확정, impl consensus = **최초 워커 진입 전** implementation/approach/units 의 실행 가능성 검증(사전 게이트), 워커·리뷰어 DOC_GAP = 구현 중 발견된 미결정 material 사항 → 사용자에게 직접 escalation → 사용자 결정이 최종 → child validator/designer 재승인 없음.
  리뷰어·워커의 구체적 질문에 답해 approach 를 보강한 것은 새 implementation proposal 이 아니라 pending gap 의 resolution 이다.
- 모호한 요구·갈리는 설계 판단은 추측 금지 — 사용자 질문 후 문서 반영, `decisions.md`에 `- [USER-QUESTION][scope=design|impl] <질문> → <답>` 기록. scope 는 "그 질문이 어디서 발생했는가"가 아니라 **"그 결정이 처음 영향을 주는 단계"** 다:
  요구·외부 동작·설계(`design.md`)에 영향을 주는 결정은 질문이 impl 합의·워커·리뷰 중 어디서 나왔어도 `scope=design`(design·impl 검증자가 모두 본다), 합의된 설계는 그대로이고 구현 수단(`implementation.md`·`approach.md`·unit 분할·범위)에만 영향을 주는 결정은 `scope=impl`(impl 검증자만 본다
  — design PASS 를 깨지 않는다). `scope=impl` 전부를 design 검증자에게 넘기지 않는다(단계 격리). 신규 규칙은 앞으로 기록하는 결정에 적용한다 — 이미 기록된 `scope=impl` 줄을 문구로 추정해 재분류하지 않는다. 합의 에스컬레이션(ASK_USER/DEADLOCK/MAX_ROUNDS)의 답은 어느 blocker 에 대한 답인지 기계적으로 확인되도록 세 번째 태그를 붙인다
  — `[USER-QUESTION][scope=design|impl][escalation=<blocker id>]`(모든 blocker 에 답이 있어야 그 단계 검증자 재호출 없이 다음 단계로 간다. `[USER-QUESTION]` 줄이 하나 늘었다는 사실만으로는 수리되지 않는다). 구현 후 gap 의 답도 어느 pending gap 에 대한 답인지 기계적으로 확인되도록 세 번째 태그를 붙인다(`[escalation=…]` 과 서로의 답으로 인정되지 않는다)
  — `[USER-QUESTION][scope=impl][review-issue=<issue id>]`(리뷰어) / `[USER-QUESTION][scope=impl][worker-gap=<unit id 또는 review-gap>#<n>]`(워커). 모든 pending gap 에 비어 있지 않은 답이 있어야 워커가 재개되며, 기존 `[scope=impl]` 의미(impl 지문 포함, design PASS 무영향)는 그대로다.
  **태그 달린 답 줄의 scope 는 그 체크포인트 계약이 정한 값 그대로 둔다**(`[escalation=…]` 은 발생 단계, `[review-issue=…]`/`[worker-gap=…]` 은 `scope=impl`) — 이 태그들은 "어느 pending 항목의 답인가"이고 scope 승격 수단이 아니다.
  후기 단계의 답이 순수 구현 gap(예: unit scope 에 테스트 파일 추가, 조회 방식 선택)이면 그 답 줄과 approach.md 반영으로 끝나고 design 은 다시 검증되지 않는다. 답이 **요구·외부 동작·설계 자체를 바꾸는 신규 제품 요구**면 gap 답으로 우회하지 않는다 — ① request.md 에 `## 요구 변경/추가` 를 append(어느 옛 규칙을 어느 범위에서 대체하는지 명시) ② 태그 없는
  `- [USER-QUESTION][scope=design] <질문> → <답>` 줄을 추가 ③ design.md(필요하면 implementation.md/approach.md)를 갱신한 뒤 재실행한다. design PASS 가 stale 이 되어 정상 design → impl 재합의를 거치고(옛 `doc-gap-resume.json` 은 재합의를 건너뛰는 데 쓰이지 않으며 impl 재합의가 끝나면 `SUPERSEDED` 로 남는다), 그 unit 은 `[CHANGED CONTRACT]` 를 받아
  다시 돈다.
- 판정은 스키마 검증된 JSON만 신뢰한다: 검증자(`PASS/BLOCK`), 리뷰어(`APPROVE/REQUEST_CHANGES`), 워커(`DONE/UNDECIDED` + `context_updates`, `schemas/worker-result.schema.json`). 모순 응답은 스크립트가 즉시 거부. "대충 통과 간주" 금지.
- 하위 실행은 반드시 `--model`/`-m` 명시(`config.sh` 한 곳에서 관리). 역할별 CLI 는 고정이 아니라 모델 ID 로 라우팅한다(`claude*` → claude, `gpt-*`/`o*`/`codex*` → codex, 그 외는 `<ROLE>_CLI` 명시). 검증자·리뷰어는 `run_readonly_json_role`(읽기 전용 + 스키마 JSON), 디자이너·수정자·워커는 `run_edit_role`(편집)로 호출되며 두 CLI 의 플래그 차이는 이 헬퍼 안에서만 다룬다.
  `core_rules.md`는 워커에게만, 선택 `conventions.md`는 전 역할에 이 헬퍼가 명시 주입한다(claude 호출은 `FEATURE_ROLE_CHILD=1` 을 달아 프로젝트 `inject_conventions.sh` 훅이 중복 주입하지 않게 한다; 훅은 interactive 오케스트레이터 세션당 첫 프롬프트에만 넣는다.
  컨텍스트 압축 직후에는 `SessionStart`(compact) 훅 `compact_recovery.sh` 가 1회, SKILL.md·현재 단계 참조 문서를 디스크에서 다시 읽으라는 지침을 넣는다 — conventions 본문은 싣지 않는다(훅 출력이 10,000자를 넘으면 잘려 전달되므로 크기와 무관하게 경로만): 피처 worktree 가 하나도 없으면 프로젝트 루트 파일 경로를, 있으면 worktree 사본 경로를 알려 주고 다시 읽게 한다.
  child 에는 넣지 않는다). Claude 세션은 stage/attempt 단위(`designer-<design|impl>`, `validator-<design|impl>`, `reviewer-aNN`, `fixer-aNN`)와 Feature 단위(워커 — `feature-worker` 하나로 unit·test-fix·worker-fix·review-gap 전부, `worker-session.json` 저널로 전제 고정)로만 `--resume` 하고 그 밖으로 대화 문맥을 넘기지 않는다
  — 상태는 문서·JSON·체크포인트·지문으로만 전달. 워커에는 추가로 `config.sh`의 `WORKER_SKILLS`(기본 비어 있음; 탐색 순서 `.claude/skills/<이름>/SKILL.md` → `.agents/skills/<이름>/SKILL.md`)의 본문을 `[WORKER SKILL]` 블록으로 붙일 수 있다.
  목록에 있는데 어디에도 없으면 워커를 실행하지 않고 실패한다. 프로젝트 codex hooks(`.codex/hooks.json` + `worker_guard.sh`)는 매 툴 호출에 별도 적용. Codex App Server backend 의 편집 역할(워커·수정자·디자이너)은 이 훅이 그 프로세스에서 등록·활성·신뢰 상태인 것을 `hooks/list` 로 확인한 뒤에만 실행된다 — 아니면 모델 0회로 멈춘다(`CODEX_APP_SERVER_HOOK_GATE_*`, `references/codex-app-server.md`).
- **워커와 리뷰어·수정자는 파일 삭제 절대 금지** — 어느 CLI 로 돌아도 훅이 강제한다(claude 쪽 `pre_bash_guard`, codex 쪽 `worker_guard`). 러너의 `--new` 아카이브도 `mv`만 쓴다. 삭제가 필요하면 `decisions.md`에 대상·사유를 남기고 사용자 에스컬레이션.
- 모든 하위 실행은 stdin을 닫고 돌린다(스크립트 시작부 `exec </dev/null`). 러너를 다른 명령·heredoc과 한 줄로 묶지 않는다.
- **진행 확인은 "프로세스 생존"이 아니라 "실제 진척"으로 판정** — `live.log` 최근 갱신과 CPU 시간 증가를 본다. 둘 다 멈춰 있으면 입력 대기·행(hang)이다: 해당 PID만 TERM으로 정리하고(`pkill` 광역 금지) 원인 확인 후 같은 명령으로 재실행하면 러너가 재개 지점을 찾는다. 중단된 라운드 산출물은 archive로 옮긴다.

## 공유 working tree 와 변경 소유권

`worker-baseline.tree` 는 시점 기준선이지 변경 소유권 증거가 아니다. git 은 같은 working tree 에서 생긴 변경이 워커의 것인지 다른 채팅 세션의 것인지 기록하지 않는다. 그래서:

- 같은 working tree 에서 피처 실행 중 다른 writer 의 변경이 존재할 수 있으므로, **범위 밖 변경은 자동 원복하지 않는다.** 현재 내용을 보존하고 `FOREIGN_WORKTREE_CHANGE`(리뷰어 판정) 또는 `SCOPE_VIOLATION`(write-set 대조) 으로 중단한다. 되돌릴지 보존할지는 사용자가 정한다.
- 이번 피처의 변경은 시점이 아니라 **범위**(`feature-scope.json` → 워커 진입 시 `feature-scope.lock.json` 으로 확정)로 정의한다. 리뷰 diff 와 승인 지문은 범위 경로만 본다(`new_file_roots` 아래는 기준선에 없던 신규 파일만). manifest 는 검사 기준이면서 에이전트가 쓸 수 있는 `.agent-work` 안에 있으므로, 호출 전후 원본·lock 해시를 대조해 바뀌었으면 `SCOPE_MANIFEST_CHANGED` 로 중단한다.
  같은 이유로 `worker-baseline.tree` 도 호출 전에 읽은 값으로만 소유권을 판정하고, 호출 중 바뀌었으면 `SCOPE_BASELINE_CHANGED` 로 중단한다. 범위 안 파일을 다른 세션이 동시에 고치는 경우는 구분할 수 없다 — 그 파일의 변경은 이번 작업으로 리뷰된다.
- **모든 피처는 처음부터 피처별 전용 git worktree 에서 돈다** (`feature-run.sh --feature <id>`, Phase 0). 같은 프로젝트의 여러 피처를 동시에 실행해도 서로의 `.agent-work`·문서·리뷰·소스 변경이 섞이지 않고, 원본 working tree 에도 보이지 않는다.
  부트스트랩(`scripts/feature-worktree.sh`)은 원본의 지문 → `snapshot_worktree_tree` → 지문 재확인으로 일관된 snapshot 만 쓰고(다르면 worktree 를 만들지 않고 실패), `git worktree add --no-checkout` + 임시 index 의 `read-tree`/`checkout-index` 로 materialize 한 뒤 worktree 에서 다시 snapshot 해 같은 tree 인지 검증한다.
  worktree 의 index 는 HEAD 이므로 원본의 미커밋 변경은 unstaged 로 보인다. 원본에서 러너가 실행 중이거나(`.agent-work/.runner.lock/pid` 생존) dirty submodule 이 있으면 거부한다. 러너는 진입 시 `.agent-work/.runner.lock` 을 `mkdir` + pid 기록 한 단위로 원자적으로 잡아 같은 트리에 두 러너가 들어오지 못하게 하고, 종료 시 푼다.
  pid 가 있고 죽은 stale 락만 회수하며 pid 가 아직 없는 락은 초기화 중으로 보고 훔치지 않는다(그런 락이 확실히 죽은 것이면 사용자가 직접 지운다). gitignore 된 `.codex/`·`.claude/settings.json`·`.claude/hooks/` 는 worktree 에 없으면 원본에서 복사해 훅 게이트를 유지한다(복사 실패는 부트스트랩 실패).
  worktree 로 들어간 뒤 `PROJECT_ROOT`·`CORE_RULES_FILE`·`CONVENTIONS_FILE` 은 그 worktree 로 재바인딩되고 하위 루프에도 `FEATURE_PROJECT_ROOT` 로 상속된다 — 규칙·conventions·프로젝트 로컬 워커 스킬을 원본이 아니라 snapshot 시점의 사본에서 읽는다(실행 엔진 위치 `SKILL_DIR` 는 그대로).
  피처 worktree 밖의 파일은 워커·수정자·리뷰·승인 대상이 아니며, 다른 세션은 원래 디렉터리에서 계속 작업한다. 완료 후 merge·commit·rebase·worktree 삭제는 자동으로 하지 않는다 — 사용자에게 branch/worktree 결과를 보고하고 finalize 여부를 묻는다. 유일한 예외는 **사용자 승인에 따른 명시적 finalize 명령**(`--feature <id> --finalize`, Phase 2)이며, 그때도 원본에는 working tree 변경만 들어가고
  커밋은 별도 요청이 있어야 한다. 부트스트랩은 finalize 의 기준선 B 를 `feature.json.bootstrap_tree`(version 2) 로 영구 기록한다 — 신규 snapshot 경로는 그 snapshot tree, 기존 브랜치 체크아웃(`new-from-branch`)은 생성 직후 worktree 의 snapshot 이다.
  수동 `--worktree <디렉터리> --branch <이름>` 도 그대로 동작한다.

권장 구성: `--feature <id>` 전용 worktree + `feature-scope.json` 필수 + write-set 검사 + 범위 밖 변경 자동 원복 금지 + main 자동 반영 금지. `--feature` 없이 공유 worktree 에서 돌리는 것은 호환용이며, 그때는 앞의 원복 금지·범위 한정이 최소 안전장치다.
부트스트랩·finalize 회귀는 `tests/smoke-feature-worktree.sh`(LLM 호출 없음): clean 생성 / dirty tracked·untracked·권한·symlink 동일 materialize / `.agent-work`·ignored 제외 / 원본 HEAD·branch·index·working tree 불변 / 피처 간·원본 간 격리 / snapshot 도중 원본 변경 시 실패 / 동일 피처 재실행 재사용 / 수동 `--worktree` 호환 / 러너 실행
중·dirty submodule 거부, 그리고 finalize(러너 대신 run-state `DONE` + 승인 지문을 파일로 재현): clean 원본 반영·커밋 없음·index 불변·worktree/브랜치 제거·archive / 재실행 already finalized·delta 중복 없음 / bootstrap 당시 dirty X 중복 적용 없음·untracked 신규 전달 / 원본 별도 변경·staged 상태 보존 / 같은 파일 비충돌 자동 병합 / 같은 hunk 충돌 →
`FINALIZE_CONFLICT` 전부 보존 / binary·실행 권한·symlink / archive 실패 시 불변 / 브랜치 삭제 실패 → `APPLIED_CLEANUP_INCOMPLETE` 후 정리만 재시도 / 기준선 없는 이전 metadata 거부 / 러너 실행 중·DONE 아님·승인 stale·잘못된 cwd·검증 뒤 원본 변경 거부.

이 정책의 회귀는 저장소 루트의 `tests/smoke-foreign-change.sh` 다(실제 LLM 호출 없음, mock claude, 임시 저장소). 다섯 사례: ① 기준선 기록 후 워커 역할이 범위 안 파일을, 다른 세션 역할이 범위 밖 파일을 고친 상태에서 리뷰어가 `OUT_OF_SCOPE_CHANGE` 를 내면 exit 2 / `FOREIGN_WORKTREE_CHANGE` / 수정자 호출 0회 / 두 파일과 index 불변 / 리뷰어 diff 가 실제로 캡처됐고 범위 안 파일은 있고
범위 밖 파일은 없음 ② 수정자의 범위 밖 쓰기 → `SCOPE_VIOLATION`, 원복 없음 ③ 승인 지문 양방향 — 범위 밖 외부 변경은 승인 유지·재사용, 범위 안 내용·실행 권한·범위 정의 변경은 승인 무효 ④ 범위 밖 파일을 범위 안 경로로 rename 하면 출발지가 위반으로 잡힘(`--no-renames`) ⑤ manifest 가 있는데 잘못되면 전체 트리 지문으로 조용히 돌아가지 않고 실패 ⑥ manifest canonical 규칙과 roots-only 유효 ⑦ 기본 설정에서 워커
스킬 미주입 ⑧ 수정자가 manifest 를 넓혀도 `SCOPE_MANIFEST_CHANGED`, 원복·재호출 없음, lock≠원본이면 진행 불가 ⑨ `new_file_roots` 아래 기준선 파일 수정은 위반·신규 생성은 허용, 지문은 신규 엔트리만 ⑩ 이전 호출이 만든 root 파일의 후속 수정은 허용 ⑪ APPROVE 뒤 lock 은 그대로 두고 원본 manifest 만 바뀌면 승인 지문 실패(원본·lock 일치 검사가 `compute_approval_fingerprint` 안에 있다) ⑫
피처가 만든 root 파일의 삭제·symlink 화(D/T)는 위반 ⑬ 수정자가 `worker-baseline.tree` 를 빈 tree 로 바꾸고 root 아래 기존 파일을 고치면 `SCOPE_BASELINE_CHANGED`, 파일·기준선 모두 자동 복구 없음, 복구 없이 재실행하면 모델 호출 0회로 다시 중단, 복구 후에만 재개 ⑭ 기준선과 manifest 를 함께 바꾸면 `SCOPE_MANIFEST_CHANGED` 로 먼저 멈추더라도 가드가 남아, manifest 만 고친 재실행은
`SCOPE_BASELINE_CHANGED` 로 모델 0회 재중단. `tests/install-smoke.sh` 8절은 필수 워커 스킬이 없으면 `run_worker` 가 실제로 중단하고 codex 를 부르지 않음, worker 단계 진입 시 원본≠lock 이면 `NEED_USER`/`SCOPE_MANIFEST_CHANGED` 가 실제로 기록되고 codex 를 부르지 않음, 11d 절은 verify 단계의 worker-fix 가 기준선과 범위 밖 파일을 바꿔 멈춘 뒤 테스트가 통과하도록 바뀐
재실행이 테스트·codex·리뷰어 호출 0회로 다시 멈추고 기준선 복구 후에만 DONE 에 이르는지 본다. 그리고 워커가 `worker-baseline.tree` 를 빈 tree 로 바꾸고 root 아래 기존 파일을 고치면 `SCOPE_BASELINE_CHANGED` 로 review 에 들어가지 않고 원복도 하지 않으며, 복구 없이 재실행하면 codex 호출 0회로 다시 멈추고 복구 후에만 워커가 재개됨을 본다.
리뷰 루프·수정자 프롬프트·범위 함수(`config.sh`)를 바꾸면 돌린다. 범위 지문은 `snapshot_worktree_tree` 의 tree 엔트리(모드·유형·blob·경로)와 manifest 자체를 해시하므로 내용뿐 아니라 실행 권한·symlink 목적지·생성/삭제까지 잡는다.

## 토큰 절약 구조 (스크립트에 내장)

- 오케스트레이터는 러너 호출 1회당 턴 1회만 소비한다. 러너 내부의 라운드 진행·재진입은 상위 세션 API 호출을 발생시키지 않는다.
- claude 로 라우팅된 역할은 역할별 세션 유지: `designer-doc`, `validator`, `feature-worker`(모든 워커 호출 — unit·test-fix·verify 의 worker-fix·review-gap), `reviewer`, `fixer`. 첫 호출이 `--session-id`, 이후 `--resume`.
  `reviewer`와 `fixer`는 절대 같은 세션으로 합치지 않는다. 합의 루프의 검증자도 예외다 — 호출마다 fresh 세션(`validator-<target>-round-NN-<invocation id>`)이며, 종결 검토는 직전 blocker 의 구조화된 주장·증거(`reviews/prev-blockers-*.json`, `why_blocks_now` 제외)와 문서 diff 만 받고 이전 검증자 대화·디자이너의 ACCEPT/REJECT 사유는 받지 않는다(디자이너 세션은 stage 단위로
  유지). 검증자는 `decisions.md` 원본 대신 러너가 `[USER-QUESTION][scope=…]` 줄만 추린 `reviews/user-decisions-<target>.md` 를 확정 사용자 결정으로 읽는다. 워커 세션은 Feature 단위다 — unit 마다 세션을 만들지 않고 같은 `feature-worker` 세션을 턴으로 이어 가며(최초 턴만 전체 규칙·참조 코드, 후속 턴은 짧은 재명시 + unit 명세
  — 규칙 원문은 재전달 경계에서 다시 싣는다), 전제는 `worker-session.json` 저널이 고정하고 임계치 도달 시 unit 경계에서만 `worker-handoff.json` 검증을 거쳐 fresh 세대로 교체한다. 세션 정책은 CLI 와 독립이다 — codex 로 라우팅된 역할도 같은 key 정책을 따른다:
  호출자가 결과를 수용한 key(`role_session_accept` — 현재 리뷰어·수정자, attempt 단위)는 세션 원장 `.session-<key>.codex.json` 의 `thread_id` 로 `codex exec resume` 을 하고, 새 attempt·검증자(고유 key)·수용되지 않은 호출은 항상 새 `codex exec` 다.
  (위는 `CODEX_BACKEND=legacy_exec` 의 수단이다. 기본값 `app_server` 에서는 같은 key 정책을 하네스가 직접 띄운 `codex app-server` 로 실행한다 — 수용된 key 는 원장(`backend: "app_server"`)의 thread id 로 `thread/resume` 뒤 `turn/start`,
  그 외는 `thread/start`. marker 대신 호출 기록 `.session-<key>.codex-turn.json` 의 상태(`PREPARED → … → ACCEPTED`, 불명은 `UNKNOWN`)가 재전송을 막고(`CODEX_TURN_UNCERTAIN` / `SESSION_RESUME_UNCERTAIN`), 편집 역할의 불명 호출은 범위 안 변경이 있어도 `CLI_EXIT_STATUS_MISMATCH` 복구(다음 리뷰어·검증자 전달)와 세션 수용을 타지 않으며, 두 backend 의 원장은 서로 잇지 않는다(`SESSION_BACKEND_MISMATCH`) — `references/codex-app-server.md`.)
  thread id 는 최초 실행 이벤트 JSONL 의 `thread.started` 에서만 취득하며(`--last`·자동 검색 금지), resume 실패 시 새 세션으로 조용히 대체하지 않고 중단한다(결과 수용이 불확실하면 `.session-<key>.resume-pending.json` marker 가 재전송을 막는다).
  수정자의 resume 이벤트 thread id 가 원장과 다르면(`SESSION_THREAD_MISMATCH`) 리뷰 루프가 그 사유를 marker 에 남기고(`unaccepted`), 범위 안 변경이 있어도 일반 `CLI_EXIT_STATUS_MISMATCH` 복구(리뷰어로 전달)·세션 수용을 타지 않는다 — 변경·marker·체크포인트(`FIXER_PENDING`)를 보존한 채 exit 1 로 멈추며, 재실행도 사람이 marker 를 확인하고 치우기 전에는 모델 호출 0회로 같은 사유로 멈춘다(치운 뒤에는 수정자 재호출 없이 리뷰어가 남은 변경을 판정). 이 차단은 체크포인트가 아니라 marker 의 `unaccepted` 표시로 판정한다 — 같은 호출이 범위 위반 등 다른 게이트에 먼저 걸려(그 오류가 우선 보고된다) 체크포인트가 `NONE` 으로 초기화돼도, 그 오류만 복구한 재실행은 marker 를 치우기 전에는 새 attempt·리뷰어 호출·승인 재사용 없이 같은 사유로 멈춘다(범위 lock·기준선 가드 다음, 재개 판정·빠른 검사 앞). 회귀: `tests/smoke-codex-resume.sh` L3·L4.
  리뷰어 모델을 Claude↔Codex 로 바꿔도 attempt 단위 재사용 의미는 같고 CLI 플래그만 다르다. 세션 재사용은 비용 최적화일 뿐 판정 근거가 아니다 — 승인은 계속 리뷰 JSON·diff·지문으로만 검증한다.
- 사용량은 `$WORK_DIR/usage.jsonl`에 CLI invocation 한 번당 행 1개(세션 누계 아님, `--resume` 해도 invocation 별). 필드: `role`/`cli`/`model`/`label`/`invocation_id`, `input_uncached`(cache 제외 입력)·`cache_read`·`cache_write`·`output`·`input_effective`(셋의 합, 진단용 파생값), `reasoning_output`(codex 만, output 의
  부분집합 — total/cost 에 다시 더하지 않음), `num_turns`·`duration_ms`, `exit_code`/`success`. 비용은 provenance 로 나뉜다: `cost_usd` = provider 가 직접 보고한 실제 비용(claude `total_cost_usd`, codex 는 항상 `null`), `estimated_cost_usd` = codex 토큰 관측값 × 명시적 가격표(`config.sh` `codex_model_pricing`
  — OpenAI API Standard, 2026-10-30 조회, USD/1M tokens, 컬럼 입력 / 캐시 입력 / 30분 캐시 쓰기 / 12시간 캐시 쓰기 / 출력: `gpt-6.2-astra` 8/0.4/10/20/40(장문 16/0.8/20/40/60, 2026-11-18 조회), `gpt-6-astra` 10/1/12.5/25/50(장문 20/2/25/50/75), `gpt-5.6-sol` 4/0.4/5/10/20(장문 8/0.8/10/20/30
  — 2026-11-30 까지 최소 유지 예정인 프로모션 단가 — 2026-11-24 확인), `gpt-6-sol` 2/0.2/2.5/5/10(장문 4/0.4/5/10/15), `gpt-5.6-luna` 0.2/0.02/0.25/0.5/1.2(장문 0.4/0.04/0.5/1/1.8), `gpt-6-luna` 0.1/0.01/0.125/0.25/0.5(장문 0.2/0.02/0.25/0.5/0.75).
  규칙: 장문 = 요청 입력 > 272,000(정확히 272,000 은 단문)이면 **요청 전체**에 적용, 장문 단가 = 입력·캐시 입력·캐시 쓰기 단문×2 / 출력 ×1.5, 30분 캐시 쓰기 = 입력×1.25, 12시간 = ×2.5(캐시 쓰기는 입력 단가 위의 할증이 아니라 배타적 입력 토큰 분류).
  정확한 모델 ID 만 매칭하며(`gpt-6-sol` ≠ `gpt-6.1-sol`) 가격표에 없는 모델은 `null`), `cost_kind` = `reported|estimated|unknown`, `pricing_basis`, `pricing_assumptions`(판단할 수 없는 과금 조건을 명시한 가정 목록), `long_context_turns`.
  codex 추정(schema_version 4)은 turn(`turn.completed`)마다 `(uncached × input + cache_read × cached + cache_write_30m 토큰 × 30분 단가 + cache_write_12h 토큰 × 12시간 단가 + output × output) / 1,000,000` 을 더한 값이다
  — `uncached = max(0, input_tokens − cached − cache_write)`(음수 방지, 캐시 쓰기 토큰을 일반 입력으로 다시 과금하지 않음), `reasoning_output_tokens` 는 output 의 부분집합이라 다시 더하지 않는다. 12시간 캐시 쓰기 토큰이 이벤트에 분리 관측될 때(`cache_write_12h_input_tokens`)만 12시간 단가를 쓰고, 관측되지 않으면 전부 30분으로 보고 `cache_write_ttl=30m(assumed…)`
  가정을 남긴다. 장문 기준은 API 요청 단위이지만 codex 이벤트는 요청 단위 입력을 주지 않으므로 **turn 별 입력**(`turn.completed.usage.input_tokens`)을 proxy 로 쓰고 `long_context_tier=turn_proxy(…)` 로 한계를 명시한다 — invocation 누적 토큰으로는 판정하지 않는다(작은 turn 여럿의 합이 272K 를 넘어도 장문이 아니다).
  service tier(Flex/Batch/Fast)·리전 할증은 관측 못 하므로 standard 가정. 이 값은 ChatGPT/Codex 구독 결제액·크레딧 차감이 아니라 **API 표준 요금 기준 환산 추정치**다. 실제로 시작한 모든 child invocation 은 `invocation_id` 기준 행 1개를 남긴다
  — 결과를 판정할 수 없거나(claude result 0개/복수/파싱 실패) usage 이벤트가 없으면 비용·토큰을 0 이 아니라 `null` 로 둔 `cost_kind: unknown` 행에 `usage_observation_status`(partial|unavailable)·`usage_error`(진단 코드)·`raw_log` 를 남기고, `usage_summary` 의 `cost_unknown_invocations`/`usage_unobserved_invocations` 가 그 수를(native Agent 호출의 `transcript` 는 전사에서 토큰을 읽은 관측이라 미관측에 넣지 않고 — 일부 요청의 usage 누락·필수 토큰 필드 누락·음수·합계에 없는 보조 모델 호출은 `partial` 이라 미관측에 넣는다 — , 금액은 Claude API 표준 요금 환산 추정치다 — `references/native-agent.md`)
  센다(원본 로그·invocation id 보존, 모델 재호출 없음, CLI 실행 전 preflight 실패는 invocation 이 아님). 완료 판정과 telemetry 오류는 분리된다. 러너는 DONE 뿐 아니라 NEED_USER/NEED_DOCS/ENV_ERROR 로 멈출 때도, 그리고 명시적 종료 함수를 거치지 않은 예기치 않은 종료(`set -e`·시그널
  — EXIT trap 이 상태가 아직 ENV_ERROR 가 아닐 때만 1회)에도(`report_usage_on_exit`) `usage_summary` 의 같은 숫자로 "Claude 보고 비용 + 추정 비용(codex·claude native — API 요금 기준 환산) + 합계 추정(실제 청구액 아님) + 추정 불가 건수(사용량 미관측 건수) + by_cli" 한 줄을 `live.log` 에 남기고 `usage-summary.json` 을 쓴다(usage.jsonl 이 없으면 "child invocation 없음" 으로
  표시, 이중 카운트 없음) — 오케스트레이터는 최종 보고에 이 줄을 그대로 옮기고 `reported + estimated` 를 청구액처럼 적지 않는다. 과거 행은 소급 수정하지 않으며 요약의 `pricing_bases` 로 요금표 버전 차이를 구분한다. Codex App Server 행(`source: codex-app-server`)은 thread 누적값의 차이(그 호출 turn 의 `thread/tokenUsage/updated` 마지막 `total` − 기준; 기준이 없으면 unknown)로 내며 `by_source` 로 구분된다 — `turn/start` 를 보내지 않은 호출은 행이 없다. legacy_exec 의 codex 행은 `codex exec --json` 이벤트 JSONL(`<raw>.events.jsonl`, stderr 는 `<raw>.stderr.log` 로 분리)의 `turn.completed.usage` 를 invocation 안에서
  합산한다(input_total = uncached + cache_read + cache_write = `input_effective`, `tokens_total` = input_total + output). plain "tokens used" 텍스트는 읽지 않는다. telemetry 는 best effort
  — 작업은 그대로 성공하며 같은 invocation 을 재실행하지 않지만, 행은 생략하지 않는다: 이벤트 JSONL 에 JSON 으로 읽을 수 없는 줄이 하나라도 있으면(`USAGE_EVENTS_CORRUPT` — 정상 turn 만 합산해 complete 로 적으면 과소 집계다) · `turn.completed.usage` 에 필수 필드(`input_tokens`/`output_tokens` 숫자)가 없는 이벤트가 있으면(`USAGE_FIELDS_INCOMPLETE`
  — `usage:{}` 를 0 으로 읽지 않는다) · `turn.completed` 가 없으면(`USAGE_EVENTS_MISSING`) 비용·토큰 `null` 의 `unknown` 행(`usage_observation_status` partial|unavailable)으로 남긴다. `cache_read` 는 invocation 안의 turn 누계일 수 있으니 `num_turns` 와 함께 읽는다.
  집계는 `usage_summary`(config.sh) 로 별도 계산한다 — 전체와 `by_role`/`by_label`/`by_session`/`by_cli`/`by_model` 마다 `invocations`·`reported_cost_usd`(= 옛 `cost_usd`, 의미 불변)·`estimated_cost_usd`·`combined_cost_usd_estimate`(reported + estimated, 추정치)·`cost_unknown_invocations`(둘 다
  null)·`cache_read`·`num_turns`·`output`·`reasoning_output`·`cache_read_per_turn` 을 내며, legacy 행(`in`/`out`, v2 codex `tokens_total` 만 있는 행)도 읽는다. 임계치나 자동 판단은 두지 않는다. `usage.jsonl` 은 child invocation 만 담으므로 interactive 오케스트레이터 자체의 cache read 는 측정하지 못한다
  — 변경 전후 비교는 상위 오케스트레이터는 CodeBurn, 하위 역할은 `usage_summary` 로 각각 보고, 세션 분리로 `cache_write`·`input_uncached` 가 늘 수 있으므로 성공 기준은 `cache_read` 단독 감소가 아니라 동일 피처 A/B 실행의 총비용·calls/turns·cache_read 를 함께 비교하는 것이다.
