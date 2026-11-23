---
name: feature
description: 복잡한 피처를 다중 에이전트 합의 파이프라인으로 처리한다. 오케스트레이터가 사용자 요구를 설계 문서(design.md)로 쓰고 이어서 워커용 구현 문서(implementation.md=무엇, approach.md=어떻게)를 쓰며, 러너(feature-run.sh)가 검증자 합의 → 워커 구현 → 리뷰 수렴 → 최종 테스트를 기계적으로 연결하고, 사용자 판단이 필요한 지점에서만 오케스트레이터로 돌아온다. 사용자가 "feature" 또는 "피처"를 명시하며 기능 구현을 요청할 때 사용한다. 사소한 수정·단일 파일 변경에는 사용하지 않는다.
---

# feature

피처 하나를 "설계 합의 → 구현 문서 합의 → 구현 → 리뷰 수렴 → 최종 테스트"로 끝까지 처리한다. 오케스트레이터(이 세션)가 하는 일은 **문서 작성과 사용자 질문뿐**이고, 나머지 결정론적 제어는 전부 `scripts/feature-run.sh`(교통정리기)가 맡는다. 러너는 agent 가 아니다 — 판단이 필요한 상태가 나오면 추가 추론 없이 즉시 이 세션으로 반환한다.

사용자가 세션 요약을 요청하면 `<skill_dir>/specs/feature_<번호>/session/SESSION-<YYYY-MM-DD>-<피처>.md`에 작성한다(결정·미해결 쟁점·다음 단계 위주).

`<skill_dir>` = 이 SKILL.md 가 있는 디렉터리(보통 `<저장소>/.claude/skills/feature`).

## 참조 문서 — 해당 분기 직전에 반드시 읽는다

이 파일은 진입 문서다. 상세 절차와 계약 원문은 `<skill_dir>/references/` 에 있다. 아래 시점마다 **행동하기 전에 그 파일을 Read 로 읽고**(그 행에 적힌 파일 전부, 다른 행의 파일은 읽지 않아도 된다), 이 요약만으로 문서 작성·사용자 질문·`decisions.md` 기록·재실행·finalize 를 하지 않는다.

| 시점 | 읽을 파일 |
|---|---|
| 피처 최초 진입 · `NEED_DOCS(DESIGN_MISSING)` · request.md/design.md 작성·수정 전 | `references/phase0-design.md` + worktree `conventions.md`(파일이 있는 경우) |
| `NEED_DOCS(IMPL_DOCS_MISSING)`·`(SCOPE_MISSING)` · implementation.md/approach.md/feature-scope.json/implementation-units.json 작성·수정 전 | `references/impl-docs.md` + `references/phase0-design.md`(3번 conventions 대조·4번 material decision 확인·지목된 선례 확인 — 구현 문서도 이 절차를 쓴다) + worktree `conventions.md`(파일이 있는 경우) |
| exit 2 `NEED_USER`(모든 reason) · exit 1 · 사용자 답을 기록하거나 문서를 고쳐 재실행하기 전 | `references/exit-states-resume.md` — 제목에 그 reason 이 든 절(`### … <reason> …`) 전체. 두 reason 이 한 절을 같이 쓰는 경우가 있다(`DEADLOCK`/`MAX_ROUNDS`, `TEST_RETRIES_EXHAUSTED`/`APPROVAL_STALE_REPEATED`). `WORKER_SESSION_*` 는 그 절에 더해 `references/pipeline-contracts.md` 의 worker stage 절도 읽는다 |
| exit 0 `DONE` · `--finalize` 실행 전과 결과 처리 · 커밋 요청 | `references/done-finalize.md` |
| exit 42 `NATIVE_AGENT_REQUIRED` · `NATIVE_RESULT_REJECTED` · `NATIVE_*`/`SESSION_CLI_MISMATCH` 중단 | `references/native-agent.md` |
| worker 단계(unit·워커 세션), 역할 경계, `decisions.md` 태그·scope, 범위·변경 소유권, 계약 버전, 비용 보고, `WORKER_SESSION_*` | `references/pipeline-contracts.md` |

- 러너는 멈출 때 `[SKILL REFERENCE]` 줄로 지금 읽을 파일의 절대 경로를 알려 준다(문서를 쓰는 반환에는 같은 줄의 `[CONVENTIONS]` 뒤에 worktree `conventions.md` 경로가 붙는다 — 그 파일이 없으면 붙지 않는다). 러너를 백그라운드 로그로 돌렸거나 출력을 `head`/`grep` 으로 줄여 읽었으면 이 줄을 반드시 찾아 그 파일들을 읽는다.
- **파일이 없거나 읽히지 않으면 진행하지 않는다.** 이전 세션 기억이나 이 요약으로 대신하지 않고, 누락 경로를 사용자에게 보고해 `install.sh` 재실행을 요청한다(러너도 references 가 빠지면 exit 1 로 시작을 거부한다).
- **압축·재개 뒤 복구.** 컨텍스트가 압축됐거나 세션을 재개했으면, 전에 읽었어도 현재 단계의 참조 문서를 디스크에서 다시 읽는다. 현재 단계를 모르면 같은 명령으로 러너를 재실행해 종료 상태로 확인한다(`run-state.json` 은 힌트). 설계·구현 문서를 쓰기 전에는 원본 저장소가 아니라 **피처 worktree 의** `conventions.md` 를(파일이 있는 경우) 다시 읽는다. 어느 worktree 인지 확신할 수 없으면 고르지 말고 러너 출력의 `피처 worktree:` 줄로 확인한다.

## 필수 불변식 (어길 수 없음 — 원문은 참조 문서)

- **문서를 쓰거나 고치기 전에 conventions 를 직접 읽고 대조한다.** design.md·implementation.md·approach.md 를 쓰거나 고칠 때마다(DOC_GAP·에스컬레이션 답 동기화 포함), 그 직전에 피처 worktree 의 `conventions.md` 를 **Read 도구로 처음부터 끝까지** 읽는다. `conventions.md` 는 선택 파일이다 — worktree 에 파일이 없으면(러너도 `[CONVENTIONS]` 경로를 붙이지 않는다) 이 읽기·대조 의무는 없고 그대로 진행한다. 세션 첫 프롬프트의 주입분·러너 출력 끝의 `[PROJECT CONVENTIONS]` 블록(출력을 자르면 사라진다)·이전에 읽은 기억으로 대신하지 않는다. 문서에 적는 material decision 마다, 그리고 `REQUIRED` 참조로 인용하는 기존 코드마다 적용 규칙과 실제로 대조한다 — 기존 코드가 규칙과 다르면 규칙이 우선이고 그 코드를 따를 선례로 인용하지 않는다. 절 번호 나열은 대조가 아니다(절차 원문: `references/phase0-design.md` 3번·4번 B).
- **막히면 사용자에게 묻는다.** 모호한 요구·갈리는 설계 판단·교착·라운드 초과·`UNDECIDED`·재시도 소진은 추측하거나 다른 에이전트에게 다시 묻지 않는다. 러너·검증자·리뷰어·워커의 질문과 선택지는 **그대로** 전달한다(우열 선택·임의의 '영향 없음' 금지).
- **사용자 결정은 `decisions.md` 에 추가만 한다.** `- [USER-QUESTION][scope=design|impl] <질문> → <답>`. scope = 그 결정이 처음 영향을 주는 단계(요구·외부 동작·설계 → `design`, 구현 수단만 → `impl`). 에스컬레이션·gap 의 답은 러너 detail 이 준 셋째 태그(`[escalation=…]`/`[review-issue=…]`/`[worker-gap=…]`)를 표기 그대로 붙인다. 기존 줄 수정·삭제, 빈 답·플레이스홀더 금지. 유일한 예외: `DECISION_SCOPE_REQUIRED` 로 멈췄을 때 detail 이 가리킨 scope 없는 옛 `- [USER-QUESTION] …` 줄에, 사용자와 확인한 `[scope=design|impl]` 태그만 붙인다(질문·답 문구는 그대로, 이미 scope 가 있는 줄은 대상 아님). 요구 자체가 바뀌면 gap 답으로 우회하지 않고 request.md `## 요구 변경/추가` 에 append 한다.
- **`USER_RESOLVED` 는 검증자 PASS 가 아니다.** 사용자 결정으로 단계를 넘어가도 리뷰 JSON 의 BLOCK 과 review/verify/DONE 게이트는 그대로다.
- **`DOC_GAP` 은 사용자 결정으로 종결된다.** 답을 approach.md 에 최소한으로 동기화하고, 검증자·디자이너 재승인을 요청하지 않으며, gap 과 무관한 절을 고치지 않는다.
- **워커가 진입한 뒤에는 합의 문서를 임의로 고치지 않는다.** 참조 절 본문이 한 글자라도 바뀌면 그 unit 과 뒤 unit 을 다시 실행해야 하고(`UNIT_CONTRACT_STALE`·`UNIT_CHECKPOINT_CHAIN_STALE`), 참조되지 않는 절이라도 합의 문서 안이면 검증자 재합의가 돈다. 측정 결과·관찰·메모는 합의 문서 밖(`.agent-work/notes.md`)에 적는다. 고친 뒤에는 재실행 전에 `--contract-impact` 로 영향을 확인하고, 계약을 실제로 바꿔야 하면 그 재실행 범위를 사용자에게 알려 결정을 받는다(`references/exit-states-resume.md`).
- **체크포인트·지문을 손으로 고치지 않는다.** `consensus-*.json`·`review-impl.json`·`doc-gap-resume.json`·`user-escalation-resume-*.json`·`*.lock.json`·`worker-baseline.tree`·`worker-session.json`·세션·가드 파일을 수정·재계산·삭제해 진행시키지 않는다. 참조 문서가 허용한 조작만, 사용자 확인 뒤에.
- **자동 원복 금지(변경 소유권).** 범위 밖 변경·불확실한 워커 결과·기준선/manifest 변조는 보존하고 사용자에게 보고한다. `git restore`/`checkout --`/`reset --hard` 로 되돌리지 않는다. 워커·리뷰어·수정자는 파일 삭제 금지.
- **자동 승인·임의 복구 금지.** 판정은 스키마 검증된 JSON(PASS/BLOCK, APPROVE/REQUEST_CHANGES, DONE/UNDECIDED)만 신뢰한다. "대충 통과 간주"·같은 프롬프트 재전송·세션 초기화·fresh 세션 강제를 하지 않는다. 마지막 APPROVE 뒤 코드가 바뀌면 재리뷰 없이 끝내지 않는다.
- **커밋·푸시·finalize 는 각각 사용자의 명시적 지시가 있을 때만.** `DONE` 은 커밋도 원본 반영도 아니다. finalize 는 물어서 승인받은 뒤에만, 커밋은 finalize 와 별개로 요청받았을 때만. 워커·리뷰어·수정자는 커밋·푸시 금지.
- **native Agent 의 보고는 판정이 아니다.** 러너가 준 dispatch 한 줄을 그대로 넘길 뿐이다 — 프롬프트·결과를 옮겨 적거나 요약하지 않고, 모델·Agent 를 바꾸지 않으며, 실패한 요청을 대신 수행하지 않는다(`references/native-agent.md`).
- **유료 실모델 회귀는 사용자 승인 없이 실행하지 않는다.** `.claude/ALLOW_*` 플래그를 지시 없이 만들지 않는다.

## 실행

사전 조건: `config.sh` 의 역할별 모델·effort·`TEST_CMD`·`LINT_CMD` 설정(선택: 리뷰 전 프로젝트 빠른 검사 `FAST_CHECK_CMD`, unit 별 정적 검사 `UNIT_CHECK_CMD`, 리뷰 승인 뒤 위험도별 추가 검증 `RISK_VERIFY_CMD` — `references/pipeline-contracts.md`), `claude`·`codex`·`jq`·`uuidgen`·`envsubst` 설치·로그인(native Agent 로 도는 역할은 CLI 대신 `feature_native_agent.sh` 훅 등록이 필요), 저장소 루트에서 실행.

```bash
bash <skill_dir>/scripts/feature-run.sh --feature <id>                        # 처음이든 재실행이든 항상 이 형태
bash <skill_dir>/scripts/feature-run.sh --feature <id> --new                  # 같은 worktree 에서 처음부터 다시(이전 산출물은 archive 로 mv)
bash <skill_dir>/scripts/feature-run.sh --feature <id> --new-review-attempt   # REVIEW_OUTPUT_INVALID 뒤, 사용자 승인 시에만
bash <skill_dir>/scripts/feature-run.sh --feature <id> --finalize             # DONE 뒤, 사용자 승인 시에만(원본 working tree 에서)
bash <skill_dir>/scripts/feature-run.sh --feature <id> --contract-impact      # 읽기 전용(모델 0회): 지금 문서로 재실행하면 다시 도는 합의·unit 미리 보기
```

- **worktree 기준.** 러너가 `--feature <id>` 로 전용 worktree(`<저장소 옆>/<repo>-feature-<id>`, branch `feature/<id>`)를 정한다. request.md·design.md·implementation.md·approach.md·feature-scope.json·implementation-units.json·decisions.md 와 `.agent-work/` 는 전부 **그 worktree 안에서만** 다룬다(경로: 로그의 `피처 worktree:` 줄). 원본 저장소의 같은 이름 파일은 기준이 아니다.
- 흐름: `preflight → design 합의 → impl 합의 → worker(unit 직렬) → review → verify → done`. 재실행은 항상 같은 명령이고 재개 지점은 러너가 고른다.
- 러너를 다른 명령·heredoc 과 한 줄로 묶지 않는다. `feature-live` 를 직접 실행하지 않는다. 진행은 worktree 의 `.agent-work/live.log`·`run-state.json` 으로 보고, 둘 다와 CPU 시간이 멈췄을 때만 해당 PID 를 TERM 으로 정리한 뒤 같은 명령으로 재실행한다.

## 종료 상태별 다음 행동 (요약 — 행동 전 위 표의 파일을 읽는다)

**종료 코드와 reason 으로만 다음 행동을 정한다.**

| exit | status / reason | 다음 행동 |
|---|---|---|
| 0 | `DONE` | 결과 보고(`.agent-work/post-run-report.json` 의 비용·검증·실패 분석·개선 후보 포함 — 후보는 제시만, 자동 수정 금지) → finalize 여부를 사용자에게 **질문**(자동 실행 금지) |
| 3 | `NEED_DOCS` `DESIGN_MISSING` | request.md·design.md 작성 → 재실행(첫 실행은 항상 이 상태) |
| 3 | `NEED_DOCS` `IMPL_DOCS_MISSING`/`SCOPE_MISSING` | 구현 문서 4종 작성·수정 → 재실행 |
| 2 | `NEED_USER` `ASK_USER`/`DEADLOCK`/`MAX_ROUNDS` | 마지막 리뷰의 모든 blocker 를 그대로 전달 → `[escalation=<id>]` 답 기록 → 재실행 |
| 2 | `NEED_USER` `UNDECIDED`/`REVIEW_DOC_GAP` | 미결정 항목을 그대로 전달 → 태그 답 기록 + approach.md 최소 동기화 → 재실행 |
| 2 | `NEED_USER` 그 밖(`DOC_GAP_*`·`SCOPE_*`·`UNIT*`·`WORKER_*`·`REVIEW_OUTPUT_INVALID`·`FAST_CHECK_*`·`UNIT_CHECK_*`·`RISK_VERIFY_*` 등) | detail 을 보고하고 멈춘다. 되돌릴지·보존할지·재시작할지는 사용자가 정한다 |
| 42 | `NATIVE_AGENT_REQUIRED` | 실패도 질문도 아니다. `references/native-agent.md` 절차대로 dispatch 한 줄을 `Agent`/`SendMessage` 에 **한 번** 넘기고, 완료 알림 뒤 같은 명령 재실행 |
| 1 | `ENV_ERROR` | 원인 확인 후 재실행. 진행 금지 |
| `--finalize` 0/2/1 | `FINALIZED` / `FINALIZE_CONFLICT`·`APPLIED_CLEANUP_INCOMPLETE` / 거부 | 결과 보고. 충돌은 자동 해결하지 않고 사용자에게 |

정확한 태그 형식, 재합의가 생략되는 조건, reason 별 복구 절차는 `references/exit-states-resume.md` 의 해당 절이 기준이다.
