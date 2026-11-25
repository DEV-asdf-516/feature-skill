# Codex App Server backend — 실행 · 호출 기록 · 중단 코드 · 수리

읽는 시점: 러너 출력이나 로그에 `CODEX_TURN_*` · `CODEX_APP_SERVER_*` · `SESSION_BACKEND_MISMATCH` 가 보일 때(대개 exit 1 `ENV_ERROR` 로 돌아온다), 그리고 `CODEX_BACKEND` 를 바꾸기 전.

## 무엇이 바뀌었나

모델 ID 가 `gpt-*`/`o*`/`codex*` 인 역할(기본 설정에서는 검증자·리뷰어)은 `config.sh` 의 `CODEX_BACKEND` 가 정한 수단으로 실행된다.

| 값 | 실행 | 비고 |
|---|---|---|
| `app_server` (기본값) | 하네스가 로컬 `codex app-server`(stdio JSON-RPC)를 자식 프로세스로 직접 띄우고 thread/turn 을 관리한다 | `codex exec` 0회. 로컬 codex 바이너리와 기존 codex 인증·설정을 그대로 쓴다. Node.js 18+ 필요(외부 패키지 없음) |
| `legacy_exec` | 종전의 `codex exec` / `codex exec resume` | 이미 `codex exec` 로 진행 중인 피처를 마칠 때와 CLI 어댑터 회귀에만 명시적으로 고른다. 이 줄이 없는 예전 `config.sh` 도 이 값으로 동작한다 |

```text
feature-run.sh / consensus-loop.sh / impl-review-loop.sh
  └─ run_readonly_json_role / run_edit_role        (인자·출력 경로·종료 의미는 그대로)
      ├─ claude 모델 → native Agent (exit 42 인계 — references/native-agent.md)
      └─ codex 모델  → scripts/codex-app-server.sh (사전 검사·게이트·기록·원장·사용량)
                         └─ node scripts/codex-app-server.mjs run <호출 기록>
                              └─ codex app-server  (호출 1회 = 프로세스 1개 = turn 1개)
                                   initialize → initialized → thread/start | thread/resume → turn/start → item/* · turn/completed
```

- native Agent 와 달리 **exit 42 가 없다.** Shell 이 자식 프로세스를 직접 띄우므로 메인 세션이 중계할 것이 없다. Codex 역할 호출은 한 번의 러너 실행 안에서 끝난다.
- 프로세스는 호출마다 뜨고 끝난다(daemon·네트워크 listener 없음). 이어지는 것은 codex 가 디스크에 저장하는 thread(`ephemeral:false`)이고, 다음 호출은 세션 원장의 thread id 로만 `thread/resume` 한다(`thread/list`·최근 thread 검색 없음).
- 실패해도 `codex exec` 로 자동 대체하지 않는다. 모델·thread 를 바꿔 다시 보내지도 않는다.

## 호출 한 번의 계약

| 항목 | 값 |
|---|---|
| 작업 디렉터리 | 프로세스 cwd 와 `thread/start`·`thread/resume`·`turn/start` 의 `cwd` 모두 현재 `PROJECT_ROOT`(피처 worktree 루트) |
| sandbox | 읽기 전용 역할(검증자·리뷰어) `read-only`, 편집 역할(워커·디자이너·수정자) `workspace-write` — 프로세스 인자(`-c sandbox_mode`)와 thread 요청 양쪽. turn 단위 `sandboxPolicy` 는 보내지 않는다(사용자 codex 설정의 workspace-write 세부를 덮어쓰지 않기 위해) |
| 승인 | `approvalPolicy: "never"`. 서버가 승인·입력을 요청하면 **거절 응답**을 보내고 turn 을 중단한 뒤 그 호출을 수용하지 않는다(`CODEX_APP_SERVER_REQUEST_DENIED`) |
| 모델·effort | 역할의 full model ID 와 effort 를 프로세스 인자·`thread/start`/`thread/resume`·`turn/start` 에 매번 넣는다. 서버 응답의 모델·sandbox·승인·cwd 가 요청과 다르면 turn 을 보내기 전에 멈춘다(`CODEX_APP_SERVER_SETTINGS_MISMATCH`) |
| 워커 하위 Agent 금지 | `-c agents.enabled=false -c features.multi_agent_v2=false -c features.multi_agent=false` 를 **워커 호출의 자식 프로세스 인자에만** 붙인다(사용자 전역 설정 파일은 바꾸지 않는다). 전달만으로 믿지 않는다 — 런타임이 그 프로세스에서 유효 설정(`config/read`, cwd = 작업 루트)과 기능 상태(`experimentalFeature/list`, 끝 페이지까지 · thread 를 연 뒤에는 그 thread 기준으로 한 번 더)를 읽어 셋 모두 `false` 인 것을 확인한 뒤에만 `turn/start` 를 보낸다. 확인하지 못하면 모델 0회로 멈춘다(아래 "워커의 하위 Agent 금지") |
| 편집 역할의 필수 훅 | 워커·수정자·디자이너 호출은 그 프로세스에서 `hooks/list` 로 `PreToolUse` 의 `worker_guard.sh` 가 등록·활성·신뢰 상태인 것을 확인한 뒤에만 `turn/start` 를 보낸다. 확인하지 못하면 `FAILED_BEFORE_SEND`(모델 0회)다(아래 "편집 역할의 필수 훅 게이트"). 읽기 전용 역할은 대상이 아니다 |
| 스키마 | 호출자의 JSON Schema 파일을 `turn/start.outputSchema` 로 그대로 보낸다. 서버가 `outputSchema` 를 지원하지 않으면 실행 전에 멈춘다(무스키마 실행 없음). 받은 결과는 기존 Shell 스키마·계약 검사를 그대로 거친다 |
| 결과 | 이 호출의 thread id · turn id 에 결속된 **완료(`item/completed`) agentMessage** 중 `phase: final_answer`(없으면 phase 없는 마지막 메시지). 델타, 다른 turn·thread 의 이벤트, 이전 호출의 파일은 결과가 아니다 |
| 완료 판정 | `turn/completed.status == "completed"` + 위 최종 메시지. 자식 프로세스 종료 코드로 판정하지 않는다 |

## 호출 기록과 상태

key(세션 이름)마다 가장 최근 호출 하나를 `.agent-work/.session-<key>.codex-turn.json` 에 둔다. 지난 기록은 `.agent-work/codex-app-server/<key>/<invocation id>.json` 으로 옮긴다(삭제하지 않는다).

| 상태 | 뜻 | 누가 쓰나 |
|---|---|---|
| `PREPARED` | 전송 의도를 기록했다(invocation id · key · 역할 · root · 모델/effort · sandbox · schema/prompt 지문). 모델 0회 | Shell |
| `THREAD_READY` | `thread/start` 또는 `thread/resume` 성공. `turn/start` 미전송(모델 0회) | 런타임 |
| `SEND_UNCONFIRMED` | `turn/start` 를 쓰기 **직전**에 디스크에 남긴다. 여기서부터는 turn 이 실행됐을 수 있다 | 런타임 |
| `RUNNING` | `turn/start` 응답 수신 — turn id 확정 | 런타임 |
| `RESULT_READY` | `turn/completed(completed)` + 최종 메시지를 invocation 전용 파일에 썼다 | 런타임 |
| `CONSUMED` | Shell 이 그 결과를 호출자의 경로로 넘겼다(호출자 게이트는 아직) | Shell |
| `ACCEPTED` | 호출자가 스키마·계약·범위 게이트 뒤 `role_session_accept` 로 수용했다 | Shell |
| `TURN_FAILED` | turn 이 `failed`/`interrupted` 로 끝났다 | 런타임 |
| `REJECTED` | turn 은 끝났지만 결과를 쓸 수 없다(최종 메시지 없음·JSON 아님·승인 요청·모델 reroute) | 런타임 |
| `FAILED_BEFORE_SEND` | `turn/start` 전에 실패했다 — 모델 0회가 확정 | 런타임 |
| `UNKNOWN` | 전송 뒤 서버 종료·timeout·스트림 손상 — 실행·완료 여부를 모른다 | 런타임 |

정상 흐름: `PREPARED → THREAD_READY → SEND_UNCONFIRMED → RUNNING → RESULT_READY → CONSUMED → ACCEPTED`.

**재실행 판정(모델 호출 전).** 같은 key 의 직전 기록 상태로 정한다.

| 직전 상태 | 재실행 |
|---|---|
| `PREPARED` · `THREAD_READY` · `FAILED_BEFORE_SEND` · `ACCEPTED` | 진행(전송 전 상태는 모델 0회가 기록으로 확정돼 있다) |
| `SEND_UNCONFIRMED` · `RUNNING` · `UNKNOWN` | `CODEX_TURN_UNCERTAIN` — 새 turn·fresh thread 없이 멈춘다 |
| `RESULT_READY` | 읽기 전용 역할이고 입력 지문(prompt·schema·모델·thread)이 같으면 **새 turn 없이** 그 결과를 호출자 검사로 넘긴다. 편집 역할이거나 입력이 다르면 `CODEX_TURN_RESULT_UNCONSUMED` |
| `CONSUMED` · `TURN_FAILED` · `REJECTED` | 읽기 전용 역할의 재개 호출이었다면 `SESSION_RESUME_UNCERTAIN`(수용되지 않은 응답 위에 같은 thread 로 다시 보내지 않는다). 그 외는 진행 |

**호출마다 key 가 바뀌는 역할(합의 루프의 검증자).** key 는 `validator-<target>-round-NN-<invocation id>` 라 재실행 때마다 다르다. 그래서 같은 key 의 기록뿐 아니라 **같은 역할·같은 label**(호출 지점마다 고정 — 예 `design-validator-round-01`)의 기록도 같은 규칙으로 본다: 불명 기록이 있으면 `CODEX_TURN_UNCERTAIN`, 완료 결과를 남긴 기록(`RESULT_READY`)은 입력 지문이 같을 때만 새 turn 없이 쓰고 다르면 `CODEX_TURN_RESULT_UNCONSUMED` 다. 메시지에 나오는 key 가 `status`/`reconcile`/`discard` 의 인자다.

**읽기 전용 역할의 사후 대조.** sandbox(`read-only`)가 1차 강제이고, 호출 전후의 작업 트리·git index 를 대조해 다르면 판정을 쓰지 않는다(`CODEX_APP_SERVER_READONLY_VIOLATION`, 자동 원복 없음). native Agent 의 `NATIVE_READONLY_VIOLATION` 과 같은 뜻이며 `codex exec` 경로에는 없던 확인이다.

**읽기 전용 역할의 스냅샷 실패.** 호출 전 작업 트리·index 스냅샷 중 하나라도 만들지 못하면 기록·서버·turn 을 만들지 않고 멈춘다(`CODEX_APP_SERVER_READONLY_SNAPSHOT_FAILED`, 모델 0회). 호출 뒤 스냅샷이 실패했거나 기록에 호출 전 값이 없으면(예전 기록·손상 — 저장된 완료 결과를 재사용할 때 포함) 그 결과를 쓰지 않는다(같은 코드, 기록은 `REJECTED`). "대조하지 못했다"를 "바뀌지 않았다"로 읽지 않는다.

**편집 역할(워커·디자이너·수정자)이 실패로 끝났을 때 — 완료가 확인됐는가로 나뉜다.**

| 호출 기록 | 뜻 | 범위 안 변경이 있을 때 |
|---|---|---|
| `TURN_FAILED` · `REJECTED` | turn 이 끝난 것이 확인됐다(종료 상태가 실패) | 종전 게이트 그대로 — 수정자·디자이너는 다음 리뷰어·검증자에게 넘기고(`CLI_EXIT_STATUS_MISMATCH`) 세션을 수용한다. 워커는 유효 결과가 없으므로 `WORKER_OUTCOME_UNCERTAIN` |
| `SEND_UNCONFIRMED` · `RUNNING` · `UNKNOWN` | 실행·완료 여부를 모른다(turn 이 아직 돌고 있을 수 있다) | **넘기지 않는다.** 리뷰 루프·합의 루프가 `CODEX_TURN_UNCERTAIN` 으로 멈춘다 — 리뷰어·검증자 호출 0회, 세션 원장 스테이징·확정 없음(`role_session_accept` 는 원장을 건드리지 않고 실패한다), anomaly 기록 없음. 체크포인트(`FIXER_PENDING`/`DESIGNER_PENDING`)·변경·기록은 그대로다. 워커는 `WORKER_OUTCOME_UNCERTAIN`(변경 있음) 또는 실행 실패(변경 없음)로 멈추고, 그 뒤의 재실행은 호출 전 게이트가 `CODEX_TURN_UNCERTAIN` 으로 멈춘다 |

불명 상태의 재실행도 같다: 두 루프는 "편집 역할이 고치다 죽음"(체크포인트 `*_PENDING` + 변경 흔적)을 보면 그 역할을 다시 부르지 않고 다음 리뷰어·검증자로 넘어가는데, 불명 기록이 남아 있으면 그 판정보다 먼저 멈춘다(모델 0회). 아래 "수리"로 완료가 확인되면(`reconcile` → `RECOVERED`) 그때 재실행이 리뷰어·검증자로 넘어간다.

## 워커의 하위 Agent 금지

- **적용**: 워커 호출의 `codex app-server` 자식 프로세스에만 `agents.enabled=false` · `features.multi_agent_v2=false` · `features.multi_agent=false` 를 `-c` 로 붙인다. `multi_agent_v2` 가 켜져 있으면 codex 는 `agents.enabled=false` 를 무시하고, `multi_agent` 는 V1 fallback 경로다 — 그래서 셋을 함께 끈다. 호출마다 프로세스가 따로라 다른 역할에 새지 않고, `~/.codex/config.toml` 은 읽기만 한다.
- **확인(모델 0회)**: 호출 전 Shell 이 설치된 codex 에 조회 수단(`config/read` · `experimentalFeature/list`)이 있는지와 덮어쓰기 키를 받는지 본다. 그 뒤 런타임이 워커 프로세스 안에서 유효 값을 읽는다 — thread 를 만들기 전에 한 번, thread 를 연 뒤 그 thread 기준으로 한 번. 세 값이 정확히 `false`(null·누락은 false 가 아니다)이고 기능 목록을 끝 페이지까지 읽었을 때만 통과다. 결과는 호출 기록의 `agents_policy` 에 남는다.
- **실패하면 `turn/start` 를 보내지 않는다**: 조회 수단 없음 → `CODEX_APP_SERVER_AGENTS_POLICY_UNVERIFIABLE`(서버 미기동), 키 거부 → `_UNSUPPORTED`(서버 미기동), 값이 false 가 아님 → `_NOT_ENFORCED`, 조회 실패·형식 불일치·끝나지 않는 목록 → `_UNVERIFIED`(둘 다 `FAILED_BEFORE_SEND`). 경고만 하고 실행하는 경로는 없다.
- **사후 탐지**: 확인을 지나고도 워커 turn 중에 하위 Agent 활동(`collabAgentToolCall` · `subAgentActivity` item, 전송 뒤 다른 thread 의 `thread/started`)이 관측되면 turn 을 중단하고 결과를 쓰지 않는다(`CODEX_APP_SERVER_SUBAGENT_OBSERVED`, `REJECTED`). 이것은 예방이 아니라 탐지다.
- **보장의 한계**: 모델 호출 없이 확인할 수 있는 것은 "그 프로세스의 유효 설정과 기능 상태"까지다. 모델에게 실제로 노출된 도구 목록은 turn 을 보내야만 드러나므로 사전에 직접 확인하지 못한다. 대조하는 항목은 위 세 개이며, codex 가 다른 이름의 하위 Agent 경로를 새로 들이면 이 목록(`CODEX_APP_WORKER_POLICY_OVERRIDES` · 런타임의 `SUBAGENT_FEATURES`)을 함께 늘려야 한다 — 그때까지 그 경로는 사후 탐지에만 걸린다.

## 편집 역할의 필수 훅 게이트

편집 역할(워커·수정자·디자이너)의 작업 보호 — 커밋·푸시·index 조작·파일 삭제 차단 — 는 프로젝트 codex 훅 `.codex/hooks.json` 의 `PreToolUse` → `.codex/hooks/worker_guard.sh` 가 맡는다. 이 훅이 돌지 않는 상태에서는 편집 역할을 실행하지 않는다.

- **대상**: `role_kind == "edit"` 인 호출 전부. 기록의 선택 플래그가 아니라 역할 종류로 정한다(사양이 빠진 기록은 건너뛰지 않고 멈춘다). 읽기 전용 역할(검증자·리뷰어)은 `hooks/list` 를 보내지 않는다.
- **무엇을 보는가**: 그 호출의 `codex app-server` 프로세스에 보낸 `hooks/list` 응답뿐이다. 파일이 있다는 것, 경고 문자열이 없다는 것은 통과 근거가 아니다. 작업 루트의 항목 안에 아래를 모두 만족하는 훅이 있어야 한다.

  | 조건 | 값 |
  |---|---|
  | `eventName` | `preToolUse` |
  | handler · `command` | `command` handler 이고 명령이 `bash .codex/hooks/worker_guard.sh` 와 **글자 그대로** 같다(앞뒤 공백만 무시). 스크립트 이름이 들어 있기만 한 명령 — 예 `… worker_guard.sh \|\| true` — 은 통과가 아니다 |
  | `matcher` | 없음(`null`). codex 는 `PreToolUse` 의 matcher 로 훅을 걸 도구를 고르므로 matcher 가 붙은 훅은 일부 도구 호출에만 돈다 — 절대 맞지 않는 정규식이면 한 번도 돌지 않는다. 실제 서버는 matcher 없는 훅을 `null` 로 돌려준다(codex-cli 0.169.1 관측) |
  | `source` / `sourcePath` | `project` / 작업 루트의 `.codex/hooks.json`. 작업 루트가 linked git worktree 면 **원본 저장소의** `.codex/hooks.json` 도 허용한다(아래 관측) |
  | `enabled` | 정확히 `true` |
  | `async` | `true` 가 아니다(async 훅은 도구 호출을 막지 못한다) |
  | `trustStatus` | `trusted` 또는 `managed`. `untrusted` · `modified` · 모르는 값은 통과가 아니다. `managed` 는 프로토콜 스키마의 값일 뿐 실제 서버 응답에서 본 적이 없다(가짜 서버로만 확인) |

  `enabled: true` 만으로는 통과가 아니다 — codex 는 검토되지 않은 훅을 `enabled: true` · `trustStatus: "untrusted"` 로 돌려주고 그 훅은 돌지 않는다. 응답의 `warnings` 는 판정에 쓰지 않는다(사용자 층의 무관한 경고가 늘 있을 수 있다).
- **언제**: 서버를 띄우기 전에 정적 조건(사양 · `hooks/list` 지원 · 훅이 부를 스크립트 파일이 작업 루트에 있고 요구하는 계약 세대를 선언하며, 그 파일의 sha256 이 검토된 지문 목록에 있음 — 파일을 읽기만 하고 실행하지 않는다)을 보고, `initialize` 뒤 **thread 를 만들기 전에** cwd 기준으로 한 번, thread 를 연 뒤(재개 포함) **그 thread 기준으로** 한 번 더 본다. 마지막 조회와 `turn/start` 사이에는 다른 요청이 없다. 결과는 호출 기록의 `hook_gate`(`ok` · `code` · `reason` · `observed.candidates`)에 남는다.
- **실패하면**: 어느 단계든 호출 기록은 `FAILED_BEFORE_SEND` 이고 모델 호출·usage 행·세션 원장 스테이징이 없다. cwd 기준 확인이 실패하면 thread 도 만들지 않는다. 리뷰 루프·합의 루프는 그 수정자·디자이너 뒤의 리뷰어·검증자를 부르지 않고 멈춘다. 원인이 풀린 뒤의 재실행은 같은 key 로 그대로 이어 간다(미전송이 기록으로 확정돼 있다).

  | `hook_gate.reason` | 코드 | 뜻 |
  |---|---|---|
  | `missing` | `_NOT_ACTIVE` | 그 cwd 에 적용되는 `preToolUse` 훅 중 `worker_guard.sh` 를 부르는 것이 없다. codex 가 신뢰하지 않은 프로젝트의 훅은 목록에 나오지 않는다 |
  | `script_missing` | `_NOT_ACTIVE` | 훅이 부를 `.codex/hooks/worker_guard.sh` 가 작업 루트에 없다(서버 미기동) |
  | `script_outdated` | `_NOT_ACTIVE` | 그 스크립트가 요구하는 가드 계약 세대 줄(`WORKER_GUARD_CONTRACT=3`)을 선언하지 않는다(서버 미기동). 1·2 세대 가드는 우회된다 — 아래 "가드 스크립트" |
  | `script_unreviewed` | `_NOT_ACTIVE` | 세대 줄은 선언하지만 그 파일의 sha256 이 검토된 지문 목록에 없다(서버 미기동). 목록은 배포본 가드의 지문(`codex-app-server.sh` 의 `CODEX_APP_REQUIRED_HOOK_SHA256`)과 사용자가 등록한 지문(`CODEX_APP_GUARD_REVIEWED_SHA256`)이다. 줄만 붙이고 `exit 0` 하는 가드, 차단 한 줄을 무력화한 가드, 등록하지 않은 채 고쳐 쓴 가드가 여기서 걸린다 — 아래 "가드 지문" |
  | `command_mismatch` | `_NOT_ACTIVE` | 그 훅의 명령이 요구하는 명령과 글자 그대로 같지 않다 |
  | `matcher_scoped` | `_NOT_ACTIVE` | 그 훅에 matcher 가 붙어 있다(일부 도구 호출에만 걸린다) |
  | `source_mismatch` | `_NOT_ACTIVE` | 그 훅이 이 프로젝트의 `hooks.json` 에서 온 것이 아니다 |
  | `disabled` · `async` | `_NOT_ACTIVE` | 꺼져 있거나 async 다 |
  | `untrusted` · `modified` · `trust_unknown` | `_NOT_ACTIVE` | 훅 정의가 검토되지 않았거나, 신뢰한 뒤 바뀌었거나, 모르는 신뢰 상태다 |
  | `query_failed` · `bad_shape` · `spec_missing` | `_UNVERIFIED` | `hooks/list` 실패, 응답에 작업 루트의 항목이 없음, 기록에 사양이 없음 |
  | `list_unsupported` | `_UNVERIFIABLE` | 설치된 codex 에 `hooks/list` 가 없다(서버 미기동). 런타임이 게이트 없는 세대로 섞여 설치된 경우도 같은 코드로 호출 전에 멈춘다 |
- **하지 않는 것**: `~/.codex/config.toml` 수정, 프로젝트·훅의 trust 승인, 훅을 건너뛰는 옵션으로 실행, `CODEX_BACKEND` 를 바꿔 우회. 하네스는 훅의 유효 상태를 판정만 한다 — 신뢰 설정은 사용자가 관리한다.
- **판정만 다시 보기**(모델 0회): `bash .claude/skills/feature/scripts/codex-app-server.sh hooks` — `initialize` 와 `hooks/list`(cwd 기준)만 보낸다. thread 를 만들지 않으므로 아래의 신뢰 등록 부작용이 없다. 통과면 exit 0. 조회 전용 단독 명령(`status` · `preflight` · `hooks`)은 프로젝트 명령을 실행하지 않으므로 `config.sh` 의 `TEST_CMD`/`LINT_CMD` 가 아직 `CHANGE_ME` 여도 돈다(설치 직후에도 훅 판정을 볼 수 있다). 모델·effort 의 `CHANGE_ME` 와 빈 값은 그대로 거부하고, 호출 기록을 바꾸는 `reconcile` · `discard` 와 러너·하위 루프는 이 예외의 대상이 아니다. 가드는 실행 중인 스크립트가 이 스킬의 `scripts/codex-app-server.sh` 자신(절대 경로 — 단독 진입이 절대 경로로 한 번 다시 실행한다)이고 그 스크립트가 조회 명령일 때 적는 표식이 자기 pid 인 경우에만 넘어간다. 표식 변수를 환경이나 `BASH_ENV` 로 심어도 다른 스크립트는 예외를 얻지 못한다. 다만 이것은 실수로 빈 설정으로 러너가 도는 것을 막는 가드이지, 셸 시작 파일로 임의 코드를 넣을 수 있는 환경에 대한 방어선이 아니다(그런 환경은 가드 자체를 다시 정의할 수 있다).
- **보장의 한계**: `hooks/list` 의 활성·신뢰 표시는 "그 훅이 돌 상태"까지다. 실제 turn 에서 훅이 금지 명령을 막는지는 이 게이트가 확인하지 않는다. 스크립트 자체의 차단 판정은 `tests/smoke-worker-guard.sh`(훅 입력 JSON 을 직접 넣는 무과금 회귀)가 보고, 실제 codex turn 에서의 발화·차단은 실모델 프로브(`codex-appserver-live-worker-probe.sh` 의 `guard` 모드 — 사용자가 승인하고 직접 실행)로만 확인할 수 있다. 그 프로브는 한 turn 에서 금지 호출 다섯 개 — 셸의 삭제 · `git add`, `apply_patch` 의 Delete File · 프로젝트 밖 Move to · `.codex/` 가드 수정 — 를 시키고 `hook/completed` 알림의 `status: "blocked"` 와 파일·index·가드 불변을 본다. 2026-11-25 에 2회 실행했고 두 번째 실행에서 다섯 개가 모두 실제로 거부됐다(아래 "검증 범위"). `legacy_exec`(`codex exec`) 경로에는 이 게이트가 없다.

**가드 스크립트(`.codex/hooks/worker_guard.sh`, 계약 세대 3).** 게이트가 지키는 것은 "이 스크립트가 돈다"이므로 스크립트가 우회되면 게이트도 의미가 없다. 세대 3 의 판정:

- 검사하지 못한 호출은 막는다: `jq` 없음 · 빈 입력 · JSON 아님 · `tool_input` 없음은 모두 exit 2 다(1 세대는 이 경우 exit 0 으로 허용했다).
- git 하위 명령은 전역 옵션(`-C <경로>` · `-c <k=v>` · `--git-dir …`)을 건너뛴 뒤의 것으로 본다 — `git -C . commit` 같은 형태도 커밋이다. 커밋·푸시(`commit` · `push` · `commit-tree` · `update-ref`), index 조작(`add` · `reset` · `stash` · `update-index` · `read-tree` · `restore --staged`), git 을 통한 삭제(`rm` · `clean`)를 막는다.
- 삭제는 명령 단위다: 한 호출 안의 삭제 명령(`rm` · `unlink` · `rmdir` · `shred`, `find -delete`)마다 **모든** 대상이 `.agent-work/` · `/tmp/` · `/private/tmp/` 하위여야 한다. 허용 경로를 지우는 명령이 같은 호출에 있어도 다른 삭제는 통과하지 못한다.
- 삭제 대상은 **글자 그대로 읽을 수 있는 경로**여야 한다: 영문·숫자와 `_ . / @ % + = : , -` 만으로 된 토큰만 대상으로 인정한다. 변수(`$X`) · 명령 치환 · 백틱 · 글로브(`*` `?` `[ ]`) · 중괄호 확장 · 역슬래시 · `~` · 공백이 든 대상은 허용 접두사로 시작해도 막는다 — `.agent-work/$TARGET` 은 셸이 풀기 전에는 어디를 가리키는지 알 수 없다(2 세대는 접두사만 보고 통과시켰다). `..` 가 든 경로와 대상을 확인할 수 없는 삭제(`xargs`)도 막는다. 명령 구분은 `;` `|` `&` 줄바꿈뿐이고 괄호·중괄호·`$(` 는 대상 토큰에 남겨 대상 검사에서 걸러 낸다(먼저 쪼개면 `.agent-work/a{,/../../src}` 의 앞부분만 남아 허용 경로로 읽힌다).
- 허용 경로 안의 **심볼릭 링크를 거쳐 가는** 대상은 막는다(`.agent-work/link/sub`, `.agent-work/link/`). 링크 자신을 지우는 것(`.agent-work/link`)은 통과다. 검사 시점에 파일시스템에 있는 링크만 본다.
- **프로젝트 안의 이동은 허용하고, 프로젝트 밖으로 옮기는 것만 삭제로 본다.** `mv` 의 목적지(마지막 인자, `-t` · `--target-directory` 형태면 그 값)와 `apply_patch` 의 `*** Move to:` 목적지가 글자 그대로 읽을 수 있는 프로젝트 안 경로(`..` 없는 상대 경로, 또는 작업 루트 아래의 절대 경로)면 통과다 — 이름 바꾸기·디렉터리 재배치는 워커의 정상 작업이다. 통과하는 `mv` 도 원본·옵션은 글자 그대로 읽혀야 한다(글로브 `*` `?` `[ ]` 는 허용, 변수·명령 치환·중괄호는 차단 — `mv $(rm -rf src) dst` 로 삭제를 숨길 수 없다). 삭제 허용 경로(`.agent-work/`)는 목적지로서 '프로젝트 안'이 아니다 — 거기로 옮긴 뒤 지우면 두 단계 삭제가 된다. 목적지가 프로젝트 밖(`/tmp/…` · `../…` · `~/…` · 다른 절대 경로)·삭제 허용 경로이거나 읽을 수 없으면(변수·글로브) 원본 전부에 삭제와 같은 허용 경로 규칙을 적용한다.
  원본을 알 수 없는 `Move to`(직전 `*** Update File:` 없음)는 막는다. `git mv` 는 index 를 바꾸므로 index 조작으로 막는다(목적지와 무관). `.codex/` 를 원본·목적지로 하는 `mv` 는 막는다. (2026-11-25 까지의 3 세대 초안은 프로젝트 안의 `mv a b` 까지 전부 막았다 — 외부 리뷰 반영으로 풀었다. `apply_patch` 의 Move to 에도 같은 규칙을 적용한 것은 이쪽의 판단이다.)
- `apply_patch` 의 `*** Delete File:` 은 삭제다(같은 허용 경로 규칙). 네이티브 `apply_patch` 도구의 본문은 파일 내용이므로 명령 검사에서 뺀다.
- `.codex/`(가드 스크립트와 훅 정의)를 대상으로 한 `apply_patch`(Add · Update · Delete · Move to)는 막는다. 이것은 인계철선이다 — 아래 "가드 파일 자체의 보호". 셸 명령의 `.codex/` 언급은 막지 않는다: 이 훅은 읽기 전용 역할(검증자·리뷰어)의 도구 호출에도 걸리고, 그 역할이 이 파일들을 읽는 것은 정당하다.
- 한계: 문자열 검사다. 다른 인터프리터로 지우는 경우(`python -c` 등), 변수·alias 로 명령 이름을 감춘 경우, 리다이렉션으로 내용을 비우는 경우, 같은 호출 안에서 심볼릭 링크를 만들고 곧바로 그 링크를 거쳐 지우는 경우는 잡지 못한다 — 그 경로는 러너의 사후 게이트(HEAD · index 지문 · 범위 대조)가 받는다. 삭제·이동 명령 이름은 명령 자리인지 따지지 않으므로 삭제 명령 이름을 인자로 넘기는 읽기 명령(`grep -n "rm -rf" …`)도 막힌다(막는 쪽으로 틀린다). `mv` 의 목적지가 프로젝트 안인지는 적힌 글자로만 본다 — 같은 호출에서 `cd` 로 디렉터리를 옮긴 뒤의 상대 경로, 프로젝트 밖을 가리키는 심볼릭 링크 목적지, 목적지에 이미 있던 파일을 덮어쓰는 이동은 가려내지 못한다(범위 밖 변경은 러너의 범위 대조가 받는다). codex 가 훅에 넘기는 `apply_patch` 입력의 실제 모양(`tool_name` · `tool_input` 의 키)은 확인하지 못했다: 가드는 `tool_input` 안의 모든 문자열을 보므로 키 이름에는 기대지 않지만, 본문을 명령 검사에서 빼는 것은 `tool_name` 이 `apply_patch` 일 때뿐이다(다르면 본문까지 검사한다 — 더 막는 쪽이다).

**가드 파일 자체의 보호.** 가드가 자기 자신을 지키는 것으로는 충분하지 않다(가드는 셸 명령으로 `.codex/` 아래를 고쳐 쓰는 것을 막지 않는다). 세 겹이다.

1. **sandbox(예방)**: codex 의 `workspace-write` sandbox 는 작업 루트의 `.codex/` 와 `.git/` 아래 쓰기를 거부한다. 설치된 codex 에서 모델 호출 없이 확인했다(codex-cli 0.169.1, 2026-11-25 — `codex sandbox -c 'sandbox_mode="workspace-write"' -- bash -c …`, macOS seatbelt, 임시 저장소): 일반 파일과 새 디렉터리는 쓰이고, `.codex/hooks/worker_guard.sh` · `.codex/hooks.json` 덧쓰기, `.codex/` 아래 새 파일, `.codex` 디렉터리 이름 바꾸기, `.git/` 아래 쓰기는 `Operation not permitted` 다. 확인한 것은 셸 명령 경로뿐이다 — `apply_patch` 도구가 같은 제한 아래에서 도는지는 실제 turn 을 보내야 알 수 있다(미확인). 다른 OS 의 sandbox 도 확인하지 않았다.
2. **가드의 인계철선**: 위의 `.codex/` 대상 `apply_patch` 차단. sandbox 확인이 닿지 않은 경로(`apply_patch`)를 가드가 받는다 — 단 이 차단이 실제 turn 에서 걸리는지는 훅 입력의 실제 모양에 달려 있고 그것은 확인하지 못했다.
3. **호출 전후 대조(사후 탐지)**: 런타임이 편집 역할의 turn 전후로 가드 스크립트와 훅 정의 파일(사양의 `source_paths`)의 sha256 을 대조한다. 바뀌었으면 그 호출은 `REJECTED`(`CODEX_APP_SERVER_HOOK_FILES_CHANGED`)이고, 리뷰 루프·합의 루프는 범위 안 변경이 있어도 다음 리뷰어·검증자로 넘기지 않으며 세션도 확정하지 않는다(`role_session_accept` 실패). 다음 호출은 호출 전 지문 대조(`script_unreviewed`)가 한 번 더 본다. 기록의 `hook_files`(`changed` · `before` · `after`)에 남는다.

실행 도중 바뀌는 것을 해시 검사로 막을 수는 없다 — 그래서 예방은 1·2 가 맡고 3 은 탐지다. 가드를 워커가 쓸 수 없는 위치(작업 루트 밖)로 옮기는 구조는 채택하지 않았다: 설치된 codex 의 sandbox 가 이미 `.codex/` 쓰기를 거부하고, 옮기면 `hooks.json` 의 명령이 바뀌어 기존 설치의 훅 신뢰가 전부 `modified` 가 된다. sandbox 가 `.codex/` 를 보호하지 않는 codex 버전·OS 가 확인되면 이 결정을 다시 본다.

- `install.sh` 는 기존 `worker_guard.sh` 를 덮어쓰지 않고 새 버전을 `.new` 로 둔다. 옛 가드(1·2 세대)가 남은 설치는 게이트가 `script_outdated` 로, 세대 줄은 같지만 본문이 지금의 배포본과 다른 가드(이전 배포본 포함)는 `script_unreviewed` 로 멈춘다 — 그 설치의 Codex 편집 역할은 사용자가 `.new` 를 병합하거나 자기 가드의 지문을 등록할 때까지 실행되지 않는다.
- **가드 지문.** 게이트는 가드 스크립트를 **실행하지 않는다.** 예전 초안은 대표 입력 열 개를 가드에 넣어 차단·허용 결과를 봤는데(`guardBehaviorError`), 그 실행은 `hooks/list` 의 신뢰 확인보다 앞이고 codex sandbox 밖(일반 Node 프로세스, 사용자 권한)이었다 — 가드 파일이 변조돼 있으면 `hooks` 조회 명령만으로 임의 코드가 돌았다(외부 리뷰 P1, 2026-11-25 제거). 지금은 파일을 읽어 sha256 만 대조한다.
  - 통과하는 지문: 이 스킬이 배포하는 가드의 지문(`scripts/codex-app-server.sh` 의 `CODEX_APP_REQUIRED_HOOK_SHA256` — `install.sh` 가 스크립트와 함께 갱신한다) 또는 사용자가 등록한 지문(`config.sh` 의 `CODEX_APP_GUARD_REVIEWED_SHA256`, 공백으로 여러 개. 환경 변수로도 준다).
  - 프로젝트에 맞게 가드를 고쳐 쓰면: 본문을 직접 검토하고 → `tests/smoke-worker-guard.sh` 로 판정 회귀를 보고(무과금, 스킬 원본 저장소에서) → 중단 메시지가 적어 주는 현재 지문을 `CODEX_APP_GUARD_REVIEWED_SHA256` 에 등록한다. 등록은 "이 본문을 읽고 승인했다"는 사용자의 표시다 — 하네스·오케스트레이터는 대신 등록하지 않는다.
  - 한계: 지문은 "검토된 본문과 같다"까지만 말한다. 배포본 가드의 판정이 옳은지는 무과금 스모크가, 실제 turn 에서 훅이 그 판정대로 거부하는지는 실모델 프로브가 본다. `config.sh` 는 sandbox 가 보호하는 경로가 아니다 — 편집 역할이 `config.sh` 의 지문 등록을 고치는 것은 범위 대조(범위 밖 변경)와, 가드 본문을 같이 바꿨다면 turn 전후 대조가 받는다.
- **codex 의 훅 신뢰는 스크립트 본문을 고정하지 않는다**(codex-cli 0.169.1 관측): `worker_guard.sh` 본문을 바꿔도 `hooks/list` 의 `currentHash` 와 `trustStatus` 는 그대로다. 신뢰가 걸리는 것은 `hooks.json` 의 정의(이벤트·command 문자열)다. 그래서 훅을 신뢰한 뒤 스크립트 본문이 약해져도 codex 는 알리지 않는다 — 그 빈틈은 게이트의 지문 대조가 메운다(본문이 한 글자라도 바뀌면 `script_unreviewed`). 고쳐 쓴 가드 본문의 검토는 사용자 몫이다.

설치된 codex 에서 모델 호출 없이 관측한 것(codex-cli 0.169.1, 2026-11-24 — `initialize` · `hooks/list` · `config/read` · turn 없는 `thread/start`):

- 프로젝트가 trusted 로 등록돼 있어도 훅 정의가 검토되지 않았으면 `hooks/list` 는 그 훅을 `enabled: true` · `trustStatus: "untrusted"` 로 돌려준다. 프로젝트 신뢰와 훅 신뢰는 별개의 층이다(사용자 설정의 `projects."<경로>".trust_level` 과 `hooks.state."<key>".trusted_hash`).
- codex 에 등록된 적 없는 새 저장소에서는 프로젝트 훅이 목록에 아예 없다(`config/read` 의 project 층에 `disabledReason` 이 붙는다) → `missing`.
- linked git worktree 는 원본 저장소의 프로젝트 신뢰를 물려받고, 훅 정의의 `sourcePath` 와 신뢰 key 도 **원본 저장소의** `.codex/hooks.json` 으로 나온다. 신뢰 key 가 원본 경로이므로 원본에서 훅을 신뢰하면 그 저장소의 worktree 에도 같이 적용될 것으로 보이지만, 이것은 key 에서 끌어낸 추정이다 — 신뢰된 `worker_guard.sh` 훅이 worktree 에서 `trusted` 로 나오는 것은 관측하지 못했다(이 환경의 원본·worktree 모두 `untrusted`). command 가 상대 경로라 실제로 도는 스크립트는 그 worktree 의 사본으로 보인다(실제 turn 으로는 확인하지 않았다).
- `hooks/list` 는 `cwds` 와 `threadId` 를 함께 받지 않는다(`-32600`). thread 기준 조회는 `threadId` 만 보낸다.
- **`thread/start` 는 그 cwd 를 사용자 설정의 trusted project 로 스스로 등록한다**(turn 을 보내지 않아도 `~/.codex/config.toml` 에 `trust_level = "trusted"` 항목이 생긴다). 그래서 이 게이트의 첫 확인은 `thread/start` 보다 앞에 있다 — 훅이 확인되지 않은 루트에서 편집 역할의 thread 를 열지 않는다. 이 등록은 sandbox 에 따라 갈린다(임시 `CODEX_HOME` 과 임시 저장소로 확인 — 루트의 `codex-appserver-trust-probe.sh`, 모델 0회): `workspace-write` 의 `thread/start` 는 trust 항목을 쓰고, **`read-only` 의 `thread/start` 는 설정 파일을 만들지도 바꾸지도 않는다.** 따라서 읽기 전용 역할(검증자·리뷰어)의 `thread/start` 는 신뢰를 남기지 않고(그 뒤의 `turn/start` 까지는 이 프로브가 보지 않았다 — 모델 호출이 든다), 편집 역할은 위 게이트가 `thread/start` 앞에서 막는다. 두 프로브 스크립트는 이 스킬의 원본 저장소 루트에만 있고 `install.sh` 로 설치되지 않는다. codex 버전이 바뀌면 이 프로브를 다시 돌린다.

## 중단 코드

모두 모델 재호출 없이 멈춘다. 러너에서는 대개 exit 1(`ENV_ERROR`)로 보인다.

| 코드 | 뜻 | 행동 |
|---|---|---|
| `CODEX_TURN_UNCERTAIN` | 직전 호출의 turn 이 실행·완료됐는지 모른다. 편집 역할이면 범위 안 변경이 있어도 다음 리뷰어·검증자·세션 확정으로 가지 않는다 | 아래 "수리" 절차. 기록을 손으로 고치지 않는다 |
| `CODEX_TURN_RESULT_UNCONSUMED` | turn 은 완료됐고 결과 파일도 있지만 호출자 검사를 거치지 않았다 | 결과 파일과 작업 트리 변경을 확인한 뒤 사용자가 `discard` 여부를 정한다 |
| `SESSION_RESUME_UNCERTAIN` | 수용되지 않은 재개 응답이 있다 | 호출자 쪽 중단 사유(예: `REVIEW_OUTPUT_INVALID`)를 먼저 해결한다. 새 리뷰는 새 attempt(새 key)로 간다 |
| `CODEX_TURN_IN_PROGRESS` | 같은 key 의 호출을 다른 실행이 준비 중이다 | 그 실행이 끝나기를 기다린다 |
| `SESSION_BACKEND_MISMATCH` | 같은 key 가 다른 Codex backend 의 세션·marker 에 결속돼 있다 | 진행 중인 피처는 시작한 backend 로 마친다(`CODEX_BACKEND` 를 되돌린다). 새 backend 는 새 attempt/`--new` 부터 |
| `SESSION_CLI_MISMATCH` | 같은 key 가 claude CLI·native Agent 세션에 결속돼 있다 | 모델 설정을 되돌리거나 새 attempt/`--new` |
| `SESSION_LEDGER_MISMATCH` | 원장의 모델·effort·계약·project_root·sandbox·schema 가 현재와 다르다 | 설정을 되돌리거나 새 attempt/단계로 시작. 자동 fresh·thread fork 없음 |
| `CODEX_APP_SERVER_NODE_MISSING` / `_NODE_TOO_OLD` | Node.js 18+ 가 없다 | 설치하거나 `CODEX_APP_SERVER_NODE_BIN` 지정 |
| `CODEX_APP_SERVER_UNSUPPORTED` / `_SCHEMA_UNAVAILABLE` / `_PROTOCOL_UNSUPPORTED` | 설치된 codex 의 app-server 가 없거나 필요한 메서드·필드(`outputSchema` 등)가 없다 | codex 업그레이드. 메시지가 빠진 항목을 나열한다 |
| `CODEX_APP_SERVER_AGENTS_POLICY_UNSUPPORTED` / `_UNVERIFIABLE` | codex 가 워커의 하위 Agent 금지 설정 키를 받지 않거나, 적용 여부를 읽을 조회(`config/read` · `experimentalFeature/list`)가 없다 | codex 업그레이드. 금지를 확인하지 못한 채 워커를 돌리지 않는다(서버 미기동) |
| `CODEX_APP_SERVER_AGENTS_POLICY_NOT_ENFORCED` / `_UNVERIFIED` | 워커 프로세스의 유효 설정·기능 상태에서 하위 Agent 가 꺼져 있지 않거나(값은 기록의 `agents_policy.observed`), 그 조회가 실패했다. `turn/start` 전(모델 0회) | 사용자에게 보고한다. 사용자 codex 설정·관리 정책이 덮어쓰기를 막는지 확인 — 권한·설정을 바꿔 우회하지 않는다 |
| `CODEX_APP_SERVER_HOOK_GATE_NOT_ACTIVE` | 편집 역할의 필수 훅(`PreToolUse` 의 `worker_guard.sh`)이 그 프로세스에서 등록·활성·신뢰 상태가 아니다(사유는 기록의 `hook_gate.reason`). `turn/start` 전(모델 0회) | 사용자에게 보고한다. 사용자가 codex 에서 프로젝트 신뢰·훅 검토 상태를 확인한다. 하네스·오케스트레이터는 `~/.codex/config.toml` 을 고치거나 trust 를 대신 승인하지 않는다. `codex-app-server.sh hooks` 로 판정만 다시 볼 수 있다 |
| `CODEX_APP_SERVER_HOOK_GATE_UNVERIFIED` / `_UNVERIFIABLE` | `hooks/list` 조회가 실패했거나 응답을 판정할 수 없다 / 설치된 codex 에 `hooks/list` 가 없거나 런타임이 게이트 없는 세대다. 모델 0회 | 조회 실패는 원인을 고치고 재실행. 조회 수단이 없으면 codex 업그레이드 또는 `install.sh` 재실행. 확인 없이 편집 역할을 돌리지 않는다 |
| `CODEX_APP_SERVER_SUBAGENT_OBSERVED` | 금지 확인을 지났는데 워커 turn 중 하위 Agent 활동이 관측됐다(turn 중단, 결과 불수용) | 기록의 `subagent_activity` 와 원본 이벤트 로그·작업 트리 변경을 사용자에게 보고한다. 자동 재실행 없음 |
| `CODEX_APP_SERVER_HOOK_FILES_CHANGED` | 편집 역할의 turn 전후로 가드 스크립트 또는 훅 정의 파일이 바뀌었다(결과 불수용). 그 turn 의 나머지 도구 호출은 가드 없이 돌았을 수 있다 — 범위 안 변경이 있어도 다음 리뷰어·검증자 전달·세션 확정 없음, 같은 key 의 재실행도 어느 역할이든 호출 전 게이트에서 모델 0회로 같은 사유 | 기록의 `hook_files.changed` 와 그 파일·작업 트리 변경을 사용자에게 보고한다. 가드를 되돌리는 것만으로는 풀리지 않는다 — 사용자가 변경을 확인한 뒤 `discard <key>`. 자동 원복 없음 |
| `CODEX_APP_SERVER_SPAWN_FAILED` / `_INIT_FAILED` / `_THREAD_ERROR` / `_THREAD_MISMATCH` / `_THREAD_NOT_UNIQUE` / `_SETTINGS_MISMATCH` | `turn/start` 전 실패(모델 0회) | 원인(로그인·설정·thread 소실)을 고치고 재실행하면 새 호출로 이어 간다 |
| `CODEX_APP_SERVER_RPC_TIMEOUT` / `_EXITED` / `_EVENT_PARSE` | 발생 시점이 전송 전이면 위와 같고, 전송 뒤면 `UNKNOWN` 이다 | 기록의 상태로 구분한다(`status`) |
| `CODEX_APP_SERVER_TURN_FAILED` / `_TURN_INTERRUPTED` / `_TURN_START_ERROR` | turn 이 결과 없이 끝났다 | stderr 로그의 원인(모델 오류·한도)을 확인 |
| `CODEX_APP_SERVER_RESULT_MISSING` / `_RESULT_NOT_JSON` / `_ITEM_CONFLICT` | 완료했지만 쓸 최종 메시지가 없다 | 원본 이벤트 로그 확인 |
| `CODEX_APP_SERVER_READONLY_VIOLATION` | 읽기 전용 역할(검증자·리뷰어) 호출 전후로 작업 트리 또는 git index 가 다르다 | 판정을 쓰지 않는다. 변경을 확인한다(같은 작업 트리의 다른 세션 변경일 수도 있다). 자동 원복 없음 |
| `CODEX_APP_SERVER_READONLY_SNAPSHOT_FAILED` | 읽기 전용 역할의 호출 전 또는 호출 뒤 작업 트리·git index 스냅샷을 만들지 못했다(또는 기록에 호출 전 값이 없다) | 호출 전이면 모델 0회 — git 상태(잠금·손상·디스크)를 고치고 재실행. 호출 뒤면 그 판정을 쓰지 않는다(기록 `REJECTED`) |
| `CODEX_APP_SERVER_REQUEST_DENIED` | 서버가 승인·입력을 요청했다(수락하지 않았다) | 그 역할이 sandbox 밖 동작을 시도했다는 뜻이다. 권한을 넓혀 재실행하지 않는다 — 사용자에게 보고 |
| `CODEX_APP_SERVER_MODEL_REROUTED` | 서버가 요청 모델을 다른 모델로 돌렸다 | 그 결과를 쓰지 않는다. 사용자에게 보고 |
| `CODEX_APP_SERVER_TURN_TIMEOUT` | `CODEX_APP_SERVER_TURN_TIMEOUT_SEC` 안에 끝나지 않았다(기본 0 = 한도 없음) | `UNKNOWN` — 수리 절차 |

## 수리 — 불명 상태의 확인과 정리

모델 호출 0회인 명령들이다. **그 기록이 속한 프로젝트·피처 worktree 루트에서** 실행한다(기록은 worktree 마다 따로다). 중단 메시지가 `cd <루트> && bash <절대 경로> …` 형태로 그대로 실행할 명령을 적어 준다.

```bash
bash .claude/skills/feature/scripts/codex-app-server.sh status [key]     # 기록·thread id·turn id·원본 로그 경로
bash .claude/skills/feature/scripts/codex-app-server.sh reconcile <key>  # 조회 전용: thread/read · thread/turns/list · thread/items/list
bash .claude/skills/feature/scripts/codex-app-server.sh discard <key>    # 사용자가 확인을 마친 기록을 보관 디렉터리로 옮긴다
bash .claude/skills/feature/scripts/codex-app-server.sh hooks            # 편집 역할의 필수 훅 게이트를 이 루트에 대해 판정만 한다(thread 없음)
```

- 스크립트는 상대·절대·심볼릭 링크 경로 어느 것으로 불러도 같다.
- 프로젝트 루트는 native 브리지의 단독 명령과 같은 규칙으로 정한다: `FEATURE_PROJECT_ROOT` 명시 > 현재 디렉터리가 속한 git worktree(이 스킬이 설치된 저장소의 worktree 일 때만) > 그 밖(git 밖·무관한 저장소)에서는 멈춘다. 설치 저장소의 기록으로 조용히 넘어가지 않는다.
- `reconcile`·`discard` 는 기록의 `project_root` 가 지금 정한 루트와 다르면 실행하지 않는다(다른 루트의 기록을 찾아 처리하지 않는다).

1. `status` 로 무엇이 멈췄는지 본다. 원본은 `<출력 경로>.appserver.jsonl`(서버 stdout 원문), `.appserver.sent.jsonl`(보낸 요청 — 프롬프트는 지문만), `.stderr.log`.
2. `reconcile` 은 저장된 thread 를 조회만 한다. `turn/start` 도 `thread/resume` 도 보내지 않는다. 판정:
   - `RECOVERED` — 같은 thread 에서 그 turn(turn id 또는 이 호출의 invocation id 가 `clientId` 로 붙은 사용자 메시지)을 찾았고, prompt 증거와 `completed` 상태·최종 메시지가 있다. 기록이 `RESULT_READY` 가 된다. 읽기 전용 역할이면 **그대로 재실행**하면 새 turn 없이 그 결과가 호출자 검사로 간다.
   - `TURN_FAILED` — 그 turn 이 failed/interrupted 로 끝난 것이 확인됐다.
   - `STILL_RUNNING` · `INSUFFICIENT_EVIDENCE` · `NOT_FOUND` · `QUERY_FAILED` — 기록을 바꾸지 않는다. `NOT_FOUND` 는 "실행되지 않았다"는 판정이 아니다.
3. 사용자가 원본 로그와 작업 트리 변경을 확인하고 **이 호출을 버리기로 정한 뒤에만** `discard` 를 실행한다. 그 뒤의 재실행은 같은 key 로 새 turn 을 보낸다(직전 turn 이 남긴 작업 트리 변경은 그대로다 — 되돌릴지는 사용자가 정한다).

오케스트레이터는 `discard` 를 스스로 실행하지 않고, 호출 기록·세션 원장을 손으로 고치거나 지우지 않으며, `CODEX_BACKEND` 를 바꿔 우회하지 않는다. 판정과 명령을 사용자에게 보고하고 결정을 받는다.

## 세션 원장과 backend 변경

- 원장 경로는 두 backend 가 같다(`.agent-work/.session-<key>.codex.json`). App Server 원장은 `version: 2, backend: "app_server"` 이고 `thread_id`·모델·effort·sandbox·계약 버전·project_root·schema 지문을 든다. `backend` 필드가 없는 원장은 `legacy_exec` 의 것이다.
- 확정은 종전과 같이 두 단계다: 호출이 결과를 내면 `.new` 스테이징, 호출자의 `role_session_accept` 가 확정. 수용되지 않은 세션은 다음 호출이 잇지 않는다.
- backend 가 다른 원장·marker·세션 위에서는 어느 방향으로도 자동 이관하지 않는다(`SESSION_BACKEND_MISMATCH` / `SESSION_CLI_MISMATCH`). Feature Worker 저널(`worker-session.json`)도 backend 를 기록한다 — `codex exec` 로 시작한 피처를 App Server 로 돌리면 `WORKER_SESSION_MISMATCH` 다.
- **전환 절차**(기존 설치): ① 진행 중인 피처를 종전 backend 로 마친다 ② `config.sh.new` 의 `Codex 모델의 실행 backend` 블록을 사용자 설정 영역에 옮겨 적는다 ③ `codex-app-server.sh preflight` 로 호환성을 확인한다 ④ 새 피처(`--new`)부터 App Server 로 돈다. `install.sh` 는 기존 `config.sh` 를 바꾸지 않는다.

## 사용량

- `thread/tokenUsage/updated` 의 `total` 은 thread 누적값이다. 런타임은 **이 호출의 turn 에 붙은 이벤트만** 골라 `마지막 누적 − 기준 누적` 을 이 호출의 사용량으로 쓴다. 기준은 새 thread 면 0, 재개면 같은 thread 의 직전 호출 기록이 남긴 마지막 누적값이다. 재개 호출은 그 turn 의 첫 이벤트가 `total − last == 기준` 을 만족해야 한다 — 서버가 누적값을 프로세스마다 다시 세거나 그 사이 다른 호출이 thread 를 썼으면 차이가 양수여도 틀린 값이므로 unknown(`USAGE_BASELINE_MISMATCH`)으로 둔다.
- 기준이 없거나(직전 기록의 사용량 미관측) 이벤트가 없거나 손상됐거나 누적값이 줄었으면 토큰·비용은 `null`(`cost_kind: unknown`)이고 `usage_error` 에 사유가 남는다(`USAGE_EVENTS_MISSING`·`USAGE_EVENTS_CORRUPT`·`USAGE_FIELDS_INCOMPLETE`·`USAGE_NON_MONOTONIC`·`USAGE_BASELINE_UNAVAILABLE`·`USAGE_BASELINE_MISMATCH`·`USAGE_RECOVERED_NO_EVENTS`). 0 으로 적지 않는다.
- 행은 호출 1개당 1개(`source: "codex-app-server"`, `backend: "codex_app_server"`, `cli: "codex"`). `turn/start` 를 보내지 않은 호출은 모델 호출이 아니므로 행이 없다. `codex exec` 이벤트 파서는 이 형식을 읽지 않는다.
- `context_last_turn`(마지막 모델 요청의 입력)·`context_window` 는 비용 판정과 따로 남긴다(워커 세션 교체 판단에 쓰인다). 그 호출 turn 에서 **마지막으로 관측한** `thread/tokenUsage/updated` 이벤트 하나로 판정한다 — 그 이벤트의 `last.inputTokens` 가 유효하면 비용이 `partial` 이어도 남기고, 유효하지 않으면 `null` 이다. 앞선 이벤트의 값을 물려 쓰지 않는다.
- 비용은 API 표준 요금 기준 환산 추정치다(실제 청구액·구독 사용량 아님). `usage_summary` 의 `by_source` 로 exec 행과 App Server 행을 나눠 볼 수 있다.

## 검증 범위

- 설치된 codex 에서 모델 호출 없이 확인한 것(codex-cli 0.169.1, 2026-11-24): 프로토콜 스키마의 메서드·필드, `initialize` 응답과 알림의 실제 프레이밍, `agents.enabled` 설정 키 인식, 그리고 `hooks/list` 의 실제 응답 모양(`cwds` 기준 · `threadId` 기준 — 위 "편집 역할의 필수 훅 게이트"의 관측 항목. `enabled` 로 나오는 훅도 `trustStatus` 가 `untrusted` 면 돌지 않으므로 enabled 는 발화의 근거가 아니다. 실제 turn 에서 발화·차단하는지는 미검증).
- 워커의 하위 Agent 금지에 대해 설치된 codex 에서 모델 호출 없이 확인한 것(codex-cli 0.169.1, 2026-11-24 — `initialize` 와 조회만, thread·turn 없음): 덮어쓰기 세 개를 붙인 프로세스의 `config/read` 가 `agents.enabled`·`features.multi_agent_v2`·`features.multi_agent` 를 모두 `false` 로 돌려주고, `experimentalFeature/list`(2 페이지)가 두 기능을 `enabled: false` 로 돌려준다. `--strict-config` 도 세 키를 받는다. 덮어쓰기가 유효 값에 반영되지 않는 경우(나중 순서의 `--enable multi_agent_v2`)에는 `multi_agent_v2: true` 가 그대로 읽힌다 — 이 런타임은 그 상태에서 turn 을 보내지 않는다. 확인하지 않은 것: 사용자 `config.toml` 이 `multi_agent_v2 = true` 인 환경에서 `-c` 덮어쓰기가 이기는지(전역 설정을 바꾸지 않으려고 시험하지 않았다 — 이기지 못하면 `_NOT_ENFORCED` 로 멈춘다), 유효 설정이 false 일 때 모델의 실제 도구 목록에 하위 Agent 도구가 없는지(turn 을 보내야 알 수 있다), 사후 탐지가 실제 이벤트에서 걸리는지, thread 를 연 뒤의 `experimentalFeature/list`(`threadId` 지정 — 재개한 thread 포함)를 실제 서버가 받는지(가짜 서버로만 확인 — 실제 서버가 거부하면 모든 워커 호출이 `turn/start` 전에 `_UNVERIFIED` 로 멈춘다).
- 러너 종단으로 돌리지 않은 것: Codex 워커가 불명(`UNKNOWN`)으로 끝난 뒤의 `WORKER_OUTCOME_UNCERTAIN` → 재실행 경로(어댑터 단위와 수정자·디자이너의 루프 단위로만 확인).
- `legacy_exec`(`codex exec`) 경로는 종전대로 `agents.enabled=false` 만 전달한다 — 위 확인은 App Server backend 에만 있다.
- 실제 Codex 모델 호출로 확인한 것(codex-cli 0.169.1, 2026-11-24 — 읽기 전용 리뷰어 2 turn 뿐: 신규 1회 + 다른 프로세스에서 같은 key 재개 1회, `run_readonly_json_role` → `role_session_accept` 경로, 도구를 쓰지 않는 고정 JSON 응답):
  - `thread/start`·`thread/resume`(`excludeTurns: true`)·`turn/start` 를 실제 서버가 받고, 호출 기록이 `RESULT_READY` → `ACCEPTED` 까지 간다. 재개는 같은 thread id 에 다른 turn id 로 붙는다.
  - 최종 메시지는 `item/completed` 의 `agentMessage`(`phase: "final_answer"`)와 `turn/completed`(`status: "completed"`)에서 읽힌다.
  - `clientUserMessageId` 는 그 turn 의 `userMessage` item 에 `clientId` 로 그대로 남는다(두 turn 모두 호출 id 와 일치).
  - `thread/tokenUsage/updated.total` 은 프로세스를 넘어 thread 단위로 누적된다(1회차 끝 24,181 → 2회차 끝 51,305). 재개 호출의 turn 이벤트는 `total − last == 직전 기록의 누적` 을 만족했고 사용량은 `complete`(기준 `previous_invocation_record`)로 기록됐다 — 입력 27,102 중 캐시 23,936.
  - 관측된 동작: `thread/resume` 직후 서버가 **직전 turn 의 id 로** 마지막 `thread/tokenUsage/updated` 를 한 번 다시 보낸다(`turn/start` 응답 전). 이 런타임은 사용량을 turn id 별로 모으고 응답으로 turn id 가 정해지면 다른 turn 의 누적기를 버리므로 그 이벤트는 이번 호출의 사용량에 섞이지 않는다(`foreign_events` 로만 센다). 재개 때는 `thread/goal/cleared` 알림도 온다(쓰지 않는다). 가짜 서버가 이 재전송을 기본 동작으로 흉내 낸다(회귀: `tests/smoke-codex-app-server.sh` U3 — 재전송 0·1·2회·도착 시점별로 이번 호출의 증분·비용·`context_last_turn` 이 같고, 새 이벤트가 없으면 과거 값을 올리지 않는다).
  - 이 두 turn 으로 알 수 없는 것: `outputSchema` 가 최종 메시지를 실제로 제약하는지(프롬프트가 같은 JSON 을 그대로 요구했다 — 전송·수락만 확인, 파이프라인의 리뷰·검증 스키마는 보내지 않았다), `last` 가 요청 단위인지 turn 단위인지(두 turn 모두 모델 요청이 1개라 구분되지 않는다 — `context_last_turn` 이 이 가정에 기댄다), 실제 청구액(행의 비용은 API 표준 요금 환산 추정치다 — 토큰 산술만 확인).
- 실제 Codex 모델 호출로 확인한 것 — 편집 역할(codex-cli 0.169.1, 2026-11-24 — 워커 신규 1 turn 뿐: `gpt-6-luna`/`max`, 새로 만든 격리 저장소에 설치한 스킬로 `run_edit_role` → `role_session_accept`, 파일 하나에 한 줄을 붙이는 작업):
  - `workspace-write` · `approvalPolicy: "never"` 로 thread 가 열리고(서버 응답의 sandbox·승인·모델·effort 가 요청과 일치) `turn/start` 1회로 끝난다. 호출 기록은 `ACCEPTED` 까지 갔고 승인 요청·모델 reroute·다른 thread 이벤트는 0건이다.
  - 하위 Agent 금지: 사용자 전역 설정이 `features.multi_agent = true` 인 환경에서 덮어쓰기 세 개가 이겼다 — `config/read` 2회(thread 전·후)가 세 값을 `false` 로, `experimentalFeature/list` 가 두 기능을 꺼짐으로 돌려줬다. **thread 를 연 뒤의 `experimentalFeature/list`(`threadId` 지정, 2 페이지)를 실제 서버가 받는다.** turn 중 하위 Agent 활동은 관측되지 않았다(모델의 도구 목록 자체는 여전히 볼 수 없다).
  - 도구 실행: 모델의 셸 명령 2개가 `commandExecution` item(`status: "completed"`, `exitCode: 0`)으로 왔고 작업 트리에는 허용한 파일 하나만 바뀌었다(git index·HEAD 불변).
  - `outputSchema`: 프롬프트에 결과 JSON 의 모양을 적지 않았는데(필드 이름 `undecided`·`delegated_choices`·`context_updates` 는 언급조차 없다) 최종 메시지가 워커 결과 스키마 모양 그대로 왔다. 스키마가 출력의 모양을 정한다는 증거다 — 스키마에 어긋나는 출력을 서버가 막는지는 여전히 확인하지 않았다(Shell 의 사후 검사가 그 경우를 받는다).
  - `thread/tokenUsage/updated` 의 `last` 는 **모델 요청 단위**다: 이 turn 에서 이벤트가 3번 왔고(요청 3개) `last.inputTokens` 23,539 + 24,082 + 24,196 = `total.inputTokens` 71,817 이다. 그래서 `context_last_turn`(마지막 이벤트의 `last.inputTokens` = 24,196)은 turn 누적이 아니라 마지막 요청의 컨텍스트다.
  - **관측된 주의점 — 신뢰하지 않은 프로젝트에서는 codex 훅이 꺼진다.** 새 경로의 저장소는 사용자 codex 설정(`~/.codex/config.toml` 의 `projects."<경로>".trust_level`)에 trusted 로 등록돼 있지 않아서, 서버가 `configWarning` 으로 "Project-local config, hooks, and exec policies are disabled … until the project is trusted" 를 냈다. 즉 그 호출에서 프로젝트 `.codex/hooks.json` 의 `worker_guard.sh`(커밋·푸시·index 조작·삭제 차단)는 로드되지 않았다. 이 호출 당시의 런타임은 그 경고를 호출 기록의 `notes` 에 남길 뿐 멈추지 않았다. **지금은 멈춘다**: 편집 역할은 필수 훅 게이트가 `hooks/list` 로 등록·활성·신뢰를 확인하지 못하면 `turn/start` 전에 `FAILED_BEFORE_SEND` 로 끝난다(위 "편집 역할의 필수 훅 게이트"). 따라서 이 워커 turn 은 실행·세션·토큰 계측의 증거이지 훅 기반 작업 보호의 증거가 아니다. 그 프로젝트 경로는 이 호출의 `thread/start` 가 사용자 설정에 trusted 로 등록했다(사용자가 승인한 것이 아니다).
- 실제 Codex 모델 호출로 확인한 것 — 훅의 실제 차단(codex-cli 0.169.1, 2026-11-25 — 워커 신규 turn 2회, 각각 다른 worktree·thread: `gpt-6-luna`/`max`, 원본 저장소의 linked worktree, `codex-appserver-live-worker-probe.sh` 의 `guard` 모드. 1차는 프로브 검사 1건 불일치로 FAIL 종료(세션은 수용하지 않았다), 프로브의 4번 지시를 고친 2차는 PASS 로 끝나 세션 수용까지 갔다):
  - 필수 훅 게이트의 **통과 경로**를 실제 서버에서 처음 봤다: 사용자가 원본 저장소에서 훅을 신뢰한 뒤 `hooks/list`(cwd 기준 · thread 기준)가 `trustStatus: "trusted"` 를 돌려줬다. **원본에서 신뢰한 훅은 linked worktree 에서도 `trusted` 로 나온다**(신뢰 key 가 원본 경로라는 데서 끌어낸 추정이 관측으로 확인됐다).
  - `PreToolUse` 훅이 실제 turn 에서 발화하고 차단한다: 2차 실행에서 `hook/completed` 의 `status: "blocked"` 5건(금지 호출 다섯 개 전부) — 셸의 `rm probe-victim.txt`, 셸의 `git -C . add …`, **`apply_patch` 도구의 `*** Delete File:`**, **`apply_patch` 도구의 프로젝트 밖 `*** Move to:`**, **`apply_patch` 도구의 `.codex/hooks/worker_guard.sh` 수정**(1차에서는 Move to 를 뺀 4건). `apply_patch` 시도 3건 중 실행까지 간 `fileChange` item 은 0건이다. 거부 사유(`entries`)에 가드의 메시지가 그대로 실렸고, 파일·git index·HEAD·가드 지문은 불변이다. 허용 명령(`cat`)은 `status: "completed"` 로 지나 `commandExecution` 으로 실행됐다.
  - 따라서 **훅은 `apply_patch` 도구 호출에도 걸리고**, 가드가 그 입력에서 patch 헤더를 읽는다(훅 입력의 키 이름은 여전히 직접 보지 않았다 — 가드는 `tool_input` 의 모든 문자열을 본다). 인계철선(`.codex/` 대상 `apply_patch` 차단)도 실제 turn 에서 걸렸다.
  - **`apply_patch` 의 Move to 는 2차 실행에서 확인했다**: 1차에서는 프로브가 시킨 "내용 변경 없는 순수 이름 바꾸기" patch 를 codex 의 patch 파서가 `invalid empty hunk` 로 훅보다 먼저 거부했다(그 호출에는 `preToolUse` 이벤트 자체가 없다 — 프로브의 지시가 잘못된 것이다). hunk 가 있는 이동으로 고친 2차에서는 훅이 거부했고(사유에 "Move to(프로젝트 밖)"), 원본 파일은 그대로이며 프로젝트 밖 목적지에 파일이 생기지 않았다. **확인하지 못한 것**: 셸의 `mv`, 프로젝트 안 Move to 의 허용 경로는 실제 turn 에서 보지 않았다.
  - 관측된 주의점: 사용자 층(`~/.codex/hooks.json`)의 `sessionStart` 훅도 이 워커 turn 에서 돌았고 그 출력이 워커의 응답 문체에 섞였다. 하네스는 사용자 층 훅을 끄지 않는다 — 워커 세션에 들어가면 안 되는 사용자 훅은 사용자가 관리한다.
- 가짜 App Server 로만 확인한 것(`tests/smoke-codex-app-server.sh` · `tests/smoke-codex-app-server-pipeline.sh`): `outputSchema` 에 어긋나는 출력을 서버가 막는지, `thread/read`·`thread/turns/list`·`thread/items/list` 의 실제 동작(reconcile 조회), 워커의 같은 thread 재개 turn, 수정자·디자이너의 실제 turn, 셸 `mv` 에 대한 훅의 실제 차단, matcher 가 붙은 훅·명령이 다른 훅의 거부(`matcher_scoped` · `command_mismatch` — 실제 서버에서는 matcher 없는 훅이 `null` 로 나오는 것만 봤다), turn 전후 가드 파일 대조(`CODEX_APP_SERVER_HOOK_FILES_CHANGED`), 불명 상태(`UNKNOWN`·`SEND_UNCONFIRMED`) 복구. `config/read`·`experimentalFeature/list` 의 실패·페이지 경계, 하위 Agent item·자식 thread 의 사후 탐지. 스모크가 실제로 호출하는 Codex 역할은 검증자·워커·리뷰어(종단)와 수정자·디자이너(어댑터 단위 + 불명 종료 시의 리뷰 루프·합의 루프)다 — Codex 디자이너의 합의 루프 한 바퀴(BLOCK → 디자이너 → PASS)는 종단으로 돌리지 않았다. **이 항목들은 실제 Codex 모델 호출로 검증하지 않았다.**
