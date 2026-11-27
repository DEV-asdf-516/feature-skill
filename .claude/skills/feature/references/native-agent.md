# native Agent 인계 — exit 42 `NATIVE_AGENT_REQUIRED` / `NATIVE_RESULT_REJECTED`

`config.sh` 의 `CLAUDE_BACKEND="native"` 일 때, 모델 ID 가 `claude*` 인 역할은 `claude -p` 가 아니라 **이 대화형 세션의 네이티브 Agent** 로 실행된다. 역할이 아니라 모델이 정한다(`gpt-*`/`o*`/`codex*` 는 종전대로 codex CLI). Shell 은 Agent 도구를 직접 부를 수 없으므로 러너가 요청을 발행하고 **exit 42** 로 돌아온다. 이 문서는 그때 오케스트레이터가 하는 일의 전부다.

구현: `scripts/native-agent-bridge.sh`(요청·검증·수용), `.claude/hooks/feature_native_agent.sh`(dispatch 검증·프롬프트 주입·실행 확인·원문 캡처), `agents/feature-<역할>.md`(정의 템플릿).

## 반복 절차 (exit 42 를 받을 때마다)

1. 러너 출력의 `[NATIVE_AGENT_REQUIRED]` 블록(같은 내용이 worktree 의 `.agent-work/native-agent/pending.json` → `request_path` 파일에 있다)을 읽는다.
2. 요청 `state` 에 따라 **한 가지만** 한다.
   - `PREPARED` + `session_intent: NEW` → `Agent` 도구를 **정확히 한 번** 호출한다. `subagent_type` = 요청의 `agent_definition`, `prompt` = 요청의 `dispatch_line` **한 줄 그대로**.
   - `PREPARED` + `session_intent: RESUME` → `SendMessage` 도구를 **정확히 한 번** 호출한다. `to` = 요청의 `resume_agent_id`, `message` = `dispatch_line` 한 줄 그대로. 새 `Agent` 로 대신 열지 않는다.
   - `DISPATCHING` → dispatch 를 시도했지만 실행이 확인되지 않았다(아래 "dispatch 상태"). **다시 호출하지 않는다** — 훅이 같은 요청의 두 번째 호출을 거부한다. 방금 호출이 background 로 시작됐으면 완료 알림을 기다린다. 도구 호출이 오류로 돌아왔으면 같은 명령을 재실행해 러너의 판정을 받는다.
   - `DISPATCHED` → 실행이 확인됐다. 다시 호출하지 않고 그 Agent 의 완료 알림을 기다린다.
   - `RESULT_READY` → 아무것도 호출하지 않는다.
3. Agent 가 끝났다는 알림(또는 foreground 완료)을 받은 뒤 **같은 `feature-run.sh` 명령을 재실행**한다. Agent 호출이 "background 로 시작됨"으로 돌아오면 그것은 완료가 아니다 — 알림을 기다린다. 알림이 "is waiting on its own background work"(Agent 가 자기 백그라운드 명령을 기다리며 멈췄다 — 결과가 중간일 수 있다)이면 그것도 완료가 아니다 — 같은 Agent 가 이어서 처리하도록 같은 task-id 의 다음 알림을 기다린다. 그 사이 같은 명령을 재실행하는 것은 상태 확인일 뿐 새 모델 호출이 아니다 — 훅이 캡처를 보류해 두었으므로 요청은 `DISPATCHING`/`DISPATCHED` 그대로 exit 42 로 돌아오고, 그때 `Agent`/`SendMessage` 를 다시 보내지 않는다. 실제 완료 보고를 캡처한 `RESULT_READY` 만 러너가 기존 절차로 소비한다. 도구 호출 자체가 **오류·거부**로 돌아오면(다른 훅의 거부 포함) 다시 보내지 않고 바로 같은 명령을 재실행한다 — 러너가 그 호출의 거부 여부를 판정한다(아래 "dispatch 상태").
4. 다시 exit 42 면 1번부터 반복한다(다음 역할의 요청이다). 그 밖의 종료 코드는 SKILL.md 의 표대로 처리한다.

## dispatch 상태 — `DISPATCHING` 은 실행의 증거가 아니다

`PREPARED → DISPATCHING → DISPATCHED → RESULT_READY → CONSUMED`. 전이는 훅과 러너만 쓴다.

| 전이 | 누가 | 조건 |
|---|---|---|
| `PREPARED → DISPATCHING` | PreToolUse | 요청 검증·프롬프트 주입 통과. 시도(`dispatch_attempt`: `tool_use_id`·메인 세션·도구·전사 경로)만 기록한다. PreToolUse 훅들은 병렬로 돌고 하나라도 거부하면 도구가 실행되지 않으므로, 이 훅의 allow 로는 실행됐다고 보지 않는다 |
| `DISPATCHING → DISPATCHED` | PostToolUse | 같은 `tool_use_id`·메인 세션·도구의 **실행 성공** 응답. `Agent` 는 `status: async_launched` + `agentId`, `SendMessage` 는 `success: true` + `resumedAgentId` 가 요청의 `resume_agent_id` 와 같을 때(`success` 만으로는 재개의 증거가 아니다). 그 밖의 응답은 형태만 기록하고 상태는 그대로다 |
| `DISPATCHING`·`DISPATCHED` → `RESULT_READY` | SubagentStop | 전사 결속 통과(요청을 dispatch 한 메인 세션, 요청의 Agent 종류, 전사의 agent id, 재개면 `resume_agent_id`, PostToolUse 가 결속한 agent id). SubagentStop 은 PostToolUse 보다 먼저 올 수 있다. SubagentStop 은 Agent 의 턴 종료일 뿐 작업 완료의 증거가 아니다 — 보고가 `SubagentHandback` 이 아닌데 그 Agent 가 인계 뒤 띄운 백그라운드 Bash 명령(`run_in_background`·오래 걸린 명령의 자동 이동)의 종결 알림이 전사에 아직 없으면(`STOP_BACKGROUND_PENDING`), 또는 모두 종결됐지만 마지막 종결 알림 뒤의 새 보고가 아직 기록되지 않았으면(`STOP_BACKGROUND_REPORT_PENDING`) 중간 종료다. 전이하지 않고 결과 파일도 쓰지 않으며 `hook-trace.jsonl` 에 그 사유와 task id 만 남긴다(같은 Agent 가 다시 멈출 때 캡처한다) |

- 다른 호출의 이벤트(`tool_use_id`·세션·agent id 불일치)는 요청 상태를 바꾸지 못하고 `hook-trace.jsonl` 에 흔적만 남는다. 늦은·중복 PostToolUse 는 `RESULT_READY` 를 덮어쓰지 않는다.
- `DISPATCHING` 에서 PostToolUse 가 오지 않으면 **실행 여부 불명**이다. 러너는 재실행 때 메인 전사에서 그 `tool_use_id` 의 도구 결과를 읽어 판정한다.
  - **거부 확인** — 도구 결과가 오류이고 실행 전 거부 종류(다른 PreToolUse 훅·권한 규칙의 거부, 사용자 거절, auto mode 차단)다 → exit 2 `NATIVE_RESULT_REJECTED` / `NATIVE_DISPATCH_DENIED`. 요청 state 는 `DISPATCHING` 그대로이고 Agent 는 실행되지 않았다.
  - **그 밖(불명·실행됨)** → exit 42 로 대기한다. 러너도 훅도 같은 요청을 스스로 다시 보내지 않는다.

### `NATIVE_DISPATCH_DENIED` — 다른 훅이 dispatch 를 거부했다

1. detail 의 거부 사유(거부한 훅의 문구 그대로)를 **사용자에게 보고하고 멈춘다.** 같은 원인이면 다시 보내도 같은 거부가 난다 — 반복하지 않는다.
2. 거부한 훅을 끄거나 우회하지 않는다. 다른 Agent 종류·다른 모델·`claude -p` 로 대체하지 않는다. `config.sh` 의 모델을 스스로 바꾸지 않는다.
3. 사용자가 정한 뒤, 피처 worktree 루트에서 둘 중 하나를 실행한다(러너가 낸 복구 명령은 `cd <그 요청의 프로젝트 루트> && bash …` 형태다 — 그대로 쓴다).
   - 프로젝트 루트 선택: `FEATURE_PROJECT_ROOT` 가 있으면 그 경로(상대 경로면 실행한 디렉터리 기준의 절대 경로로 확정한다), 없으면 **현재 디렉터리가 속한 git worktree 의 루트**다 — 그 worktree 가 스킬이 설치된 저장소와 같은 저장소(git common dir 일치)일 때만이다. 다른 저장소·git 밖에서는 멈춘다(설치 저장소의 `.agent-work` 로 넘어가지 않는다). 스크립트 경로는 상대·절대 어느 쪽이어도 같다. 다른 worktree 의 요청은 찾지 않는다 — 그 worktree 의 요청 id 가 아니면 '요청 ID 불일치'로 거부한다. agent 정의 위치(원본 저장소의 `.claude/agents/`)는 이 선택과 무관하다.
   - 거부 원인이 해소됐다(사용자가 훅·설정을 고쳤다) → `bash <skill_dir>/scripts/native-agent-bridge.sh redispatch <request_id>`. 거부가 메인 전사에서 확인되고 작업 트리·원본 저장소가 요청 발행 시점 그대로일 때만, 그 시도를 `dispatch_history` 로 옮기고 **같은 요청**을 `PREPARED` 로 되돌린다(같은 id·payload·`session_intent` — 새 Agent 로 바뀌지 않는다). 그 뒤 같은 dispatch 한 줄을 한 번 보낸다.
   - 요청을 버린다(예: 사용자가 그 역할의 모델을 바꾸기로 했다) → `discard <request_id>` 뒤 설정을 바꾸고 재실행한다.
4. 거부가 확인되지 않은 요청에는 `redispatch` 가 거부된다(실행됐을 수 있다). 거부 증거는 그 dispatch 의 `tool_use_id` 에 결속된 것만 쓴다 — 전사 레코드 하나에 도구 결과가 여럿이면 그 레코드의 거부 정보(`toolDenialKind`·`permissionDecision`)가 다른 도구 호출의 것일 수 있으므로 거부로 보지 않는다(`UNKNOWN`). 남은 수단은 사용자 결정 뒤의 `discard` 뿐이다.

## 하지 않는 것

- `dispatch_line` 을 고치거나, 설명을 덧붙이거나, 프롬프트 본문을 직접 옮겨 적지 않는다. 본문은 PreToolUse 훅이 요청의 `prompt_path` 에서 그대로 넣는다(훅이 한 줄이 아닌 dispatch 를 거부한다).
- `Agent` 호출에 `model`·`isolation` 인자를 주지 않는다. 모델은 agent 정의의 full model ID 가 정한다(별칭 인자는 정의보다 우선하므로 훅이 거부한다).
- Agent 의 보고를 요약·재작성해 파일로 쓰거나 러너에 넘기지 않는다. Shell 은 훅이 전사에서 캡처한 원문만 읽는다. Agent 가 "완료"라고 해도 PASS/APPROVE/DONE 은 러너의 게이트가 정한다.
- 실패한 요청을 직접 대신 수행하지 않는다. 다른 Agent 종류·다른 모델·`claude -p` 로 대체하지 않는다.
- `.agent-work/native-agent/` 아래 파일과 `.session-*.native.json` 을 손으로 고치거나 지우지 않는다.
- feature 전용 Agent(`feature-designer|validator|worker|reviewer|fixer`)를 요청 없이 직접 부르지 않는다(훅이 거부한다).

## exit 2 `NATIVE_RESULT_REJECTED`

캡처된 결과나 pending 요청이 현재 요청과 결속되지 않았다. 러너는 결과를 수용하지 않았고 자동 재호출·자동 원복·자동 fresh 도 하지 않았다. 그대로 재실행하면 모델 호출 0회로 같은 사유가 나온다. detail 의 코드를 **그대로 사용자에게 보고**하고 멈춘다.

| 코드 | 뜻 |
|---|---|
| `NATIVE_MODEL_MISMATCH` / `NATIVE_EFFORT_MISMATCH` | 전사에서 관측한 모델·effort 가 요청과 다르다(fallback, 전역 override, 정의 미적용). 관측하지 못한 경우도 불수용이다 |
| `NATIVE_PROMPT_HASH_MISMATCH` | Agent 가 실제로 받은 프롬프트가 요청의 payload 와 다르다 |
| `NATIVE_OWNER_SESSION_MISMATCH` / `NATIVE_SESSION_MISMATCH` / `NATIVE_AGENT_TYPE_MISMATCH` | 다른 메인 세션·다른 Agent 의 결과다 |
| `NATIVE_STALE_REQUEST` | 요청 발행 뒤 config 의 모델·effort, agent 정의, 스킬(프롬프트·스키마·브리지), 이 호출의 입력(문서·작업 트리)이 바뀌었다. 워커는 Agent 가 도는 동안 계약 입력(request·design·implementation·approach·decisions, 범위·unit 선언, 워커 규칙·conventions)이 바뀐 경우다 — 워커가 고친 소스는 해당하지 않는다. 수정자는 Agent 가 도는 동안 계약 문서(request·design·implementation·approach)나 고칠 리뷰 JSON 이 바뀌었거나, `decisions.md` 의 기존 내용이 바뀌었거나, 수정자 권한 밖 기록(`[USER-QUESTION]` 줄, 다른 라운드의 `[fix round M]` 줄)이 추가된 경우다 — 이번 라운드의 `[fix round N]` ACCEPT/REJECT/DEFER 추가 기록과 수정자가 고친 소스는 해당하지 않는다 |
| `NATIVE_READONLY_VIOLATION` | 읽기 전용 역할(검증자·리뷰어) 호출 전후로 작업 트리가 다르다 |
| `NATIVE_WORKTREE_CONFUSION` / `NATIVE_WORKTREE_MISMATCH` | Agent 가 피처 worktree 가 아닌 원본 저장소를 고쳤거나, 요청의 worktree 와 러너의 작업 트리가 다르다 |
| `NATIVE_PENDING_BACKEND_CHANGED` | 처리되지 않은 요청이 남았는데 그 역할이 더는 native 로 라우팅되지 않는다(요청 발행 뒤 모델·`CLAUDE_BACKEND` 변경). 같은 호출 지점이어도 CLI 를 부르지 않는다. 요청 state 는 그대로다 — 설정을 되돌려 재실행하면 같은 요청이 이어지고, 변경이 의도라면 사용자 결정 뒤 discard 한다 |
| `NATIVE_DISPATCH_DENIED` | dispatch 가 실행 전에 거부됐다(다른 PreToolUse 훅·권한 규칙·사용자 거절). Agent 는 실행되지 않았고 요청 state 는 `DISPATCHING` 그대로다 — 위 "`NATIVE_DISPATCH_DENIED`" 절차를 따른다 |
| `NATIVE_PENDING_MISMATCH` | 처리되지 않은 요청이 남았는데 러너가 다른 호출 지점에 도달했다(그 사이 문서·설정·체크포인트가 바뀜) |

복구는 사용자가 정한다(`NATIVE_DISPATCH_DENIED` 의 재시도는 `redispatch` — 위 절). 요청을 버리고 같은 호출 지점에서 새 요청을 받으려면, 사용자 승인 뒤 **피처 worktree 루트에서** `bash <skill_dir>/scripts/native-agent-bridge.sh discard <request_id>` 를 실행한다 — 작업 트리가 요청의 호출 전 tree 와 같을 때만 치운다. Agent 가 남긴 변경이 있으면 거부하므로, 변경을 유지할지 되돌릴지 사용자가 먼저 정한다(자동 원복 없음).

## 그 밖의 중단

- `SESSION_CLI_MISMATCH` / `WORKER_SESSION_MISMATCH`: 그 key 의 세션이 다른 backend(`claude -p`·codex·native)에 결속돼 있다. 진행 중인 피처는 시작한 backend 로 마친다 — 묵시적 마이그레이션은 없다. 워커는 피처 전체에서 Agent 하나를 `SendMessage` 로 재개하며(unit·test-fix·check-fix·review-gap·verify worker-fix 모두), 세대 교체는 검증된 `worker-handoff.json` 뒤에만 새 Agent 를 연다. 그 Agent 가 다른 메인 세션에 결속돼 있으면 `WORKER_SESSION_MISMATCH` 로 멈춘다.
- `NATIVE_PARENT_SESSION_LOST`: 재개할 Agent 가 다른 메인 세션에 결속돼 있다(`/clear`·새 세션). 원래 세션을 재개(`claude --resume`)해 재실행하거나 사용자가 재시작 방식을 정한다. 새 Agent 를 조용히 만들지 않는다.
- `NATIVE_MODEL_OVERRIDE` / `NATIVE_EFFORT_OVERRIDE`: `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`·`CLAUDE_CODE_EFFORT_LEVEL` 이 정의의 모델·effort 를 덮는다. 해제하고 메인 세션을 다시 시작한다.
- `NATIVE_AGENT_DEFINITION_CONFLICT`: `.claude/agents/feature-<역할>.md` 가 사용자 파일이다(관리 표식 없음). 러너는 덮어쓰지 않는다.
- Agent 종류를 찾지 못함(`Agent type 'feature-…' not found`): `.claude/agents/feature-<역할>.md` 는 러너가 요청 직전에 쓰지만, 세션 시작 때 `.claude/agents/` 디렉터리가 없었으면 이 세션은 그 정의를 읽지 못한다. 이 오류가 돌아오면 다시 보내지 말고 같은 러너 명령을 재실행해 요청 state 를 확인한다. 안내는 state 에 따라 다르다.
  - `PREPARED` 그대로(PreToolUse 훅이 그 호출을 기록하지 않았다): Claude Code 세션을 재시작(같은 대화 재개)한 뒤 그 dispatch 를 한 번 보낸다(기존 1회 dispatch 계약 그대로).
  - `DISPATCHING`(훅이 시도를 기록했다): 실행 전 거부가 증명되지 않는다. 러너는 이 오류를 알려진 거부 종류(`toolDenialKind`)가 함께 있어도 `UNKNOWN` 으로 판정하고 exit 42 로 대기한다(`NATIVE_DISPATCH_DENIED` 가 아니다). 세션을 재시작한 뒤에도 그 요청을 다시 dispatch 하지 않고, `redispatch` 는 거부 증거가 없어 거절된다. 모델이 실행됐는지(진행 중인 Agent·작업 트리 변경)를 사용자와 확인하고, 사용자 결정 뒤 `discard` 로만 정리한다(작업 트리가 호출 전 tree 와 같아야 하며 "거부가 확인되지 않았다" 경고가 붙는다). 자동 재호출·자동 fresh·CLI 대체는 없다.
- `hook-trace.jsonl` 의 `STOP_BACKGROUND_PENDING`·`STOP_BACKGROUND_REPORT_PENDING`(과 `detail` 의 task id)은 진단 정보다. 백그라운드 명령은 오래 걸릴 수 있으므로 기다리는 것이 정상이다. 오래도록 종결 알림이나 새 보고가 오지 않으면 요청 state·사유·task id 를 사용자에게 보고하고 멈춘다 — 자동으로 다시 dispatch 하거나 요청을 버리지 않는다. 사용자가 버리기로 정했더라도 먼저 그 Agent 와 백그라운드 명령이 실제로 멈췄는지 확인한다(실행 중인 작업 위에서 원복·`discard` 하지 않는다). `discard` 의 작업 트리·요청 결속 검사는 그대로다.
- `DISPATCHING`·`DISPATCHED` 에서 Agent 가 끝났는데도 결과가 캡처되지 않으면 훅 등록(`.claude/settings.json` 의 PreToolUse·PostToolUse·SubagentStop)과 `.agent-work/native-agent/hook-trace.jsonl` 을 확인하고 사용자에게 보고한다. Agent 가 실행됐을 수 있으므로 다시 dispatch 하지 않는다.

## 전제와 한계

- 러너는 이 대화형 세션의 Bash 에서 실행한다. 터미널에서 단독 실행하면 요청만 발행하고 exit 42 로 끝난다 — 그 요청은 대화형 세션이 dispatch 해야 한다.
- Agent 의 작업 디렉터리는 이 세션의 cwd 다(피처 worktree 가 아닐 수 있다). payload 가 `worktree_root` 절대 경로와 "상대 경로는 worktree_root 기준" 을 전달하고, 범위 위반은 기존 Shell 게이트와 원본 저장소 상태 대조가 사후에 잡는다. 이 세션이 그 worktree 를 읽고 쓸 수 없으면(`--add-dir`/`/add-dir` 미설정) Agent 가 유효한 결과를 내지 못한다.
- 비용: native subagent 는 비용을 보고하지 않는다. usage 행은 전사에서 관측한 토큰(`usage_observation_status: transcript` — 미관측이 아니다)을 담고, 금액은 그 토큰을 Claude API 표준 요금(`config.sh` 의 `claude_model_pricing`, `pricing_basis` 에 조회 날짜)으로 환산한 **추정치**(`cost_kind: estimated`)다 — 입력·캐시 읽기·캐시 쓰기(5분/1시간 TTL 별 단가)·출력. 구독 사용량이나 실제 청구액이 아니다(구독 한도는 그대로 소모된다).
- 비용을 환산할 수 없으면 0 이 아니라 `unknown` 이다: 가격표에 없는 모델(프롬프트 길이별 요금인 `claude-haiku-5-5` 포함), 캐시 쓰기의 TTL 구분이 전사에 없는 경우, fast mode·US 전용 추론 요청이 섞인 경우, 전사의 usage 가 불완전하거나 없는 경우.
- usage 가 불완전하다는 것은 일부 API 요청에 usage 가 없거나(`usage_error: USAGE_REQUESTS_MISSING`), 네 토큰 필드(입력·출력·캐시 읽기·캐시 쓰기) 중 하나가 없거나 숫자가 아니거나 음수인 경우(`USAGE_FIELDS_INCOMPLETE`), 요청 안에 보조 모델 호출(`usage.iterations` 의 `advisor_message` 등 — 그 토큰은 요청의 usage 합계에 들어 있지 않다)이 있는 경우(`USAGE_ITERATIONS_EXCLUDED`), assistant 레코드에 `message.id` 가 없어 API 요청 단위로 묶을 수 없는 경우(`USAGE_REQUEST_ID_MISSING`)다 — 누락을 0 으로 계산하지 않고 `usage_observation_status: partial`, 토큰을 `null` 로 남긴다(usage 가 아예 없으면 `unavailable`). `partial`·`unavailable` 행은 '사용량 미관측'으로 센다. 이 판정은 telemetry 일 뿐이고 결과 수용·완료 판정을 바꾸지 않는다. `speed`·`inference_geo` 를 전사가 보고하지 않은 요청은 표준 요금으로 가정해 추정하고 그 가정을 `pricing_assumptions` 에 적는다(fast·us 로 보고된 요청이 있으면 추정하지 않는다). 이 추정은 새 버전의 훅이 캡처한 결과부터 적용된다 — 이미 기록된 `unknown` 행은 소급 수정하지 않는다.
- 컨텍스트 측정(`context_last_turn`)은 비용 관측과 따로 간다. 워커 세션 교체 판단의 실측값이라, 비용이 `unknown`·관측이 `partial` 이어도 마지막 본 모델 호출의 입력이 검증되면 그대로 남긴다. 훅은 인계 이후 마지막 assistant 레코드의 usage 만 본다(앞선 요청으로 거슬러 올라가지 않는다): `usage.iterations` 에 항목이 있으면 그중 마지막 `type: message` 항목(`context_source: last_message_iteration` — 보조 모델 호출이 낀 요청의 usage 합계는 본 모델 호출 여러 번의 합이라 컨텍스트 크기가 아니다), 없으면 그 요청의 usage(`last_request_usage`)에서 입력·캐시 읽기·캐시 쓰기를 더한다. 세 필드 중 하나라도 없거나 숫자가 아니거나 음수면, 또는 `iterations` 에 쓸 수 있는 `message` 항목이 없으면 `null` 이다 — 합계나 앞선 요청으로 대신하지 않는다. `null` 이면 세션 교체는 판단을 보류하고 세션을 유지한다(측정값이 없다고 새 세션을 만들지 않는다).
