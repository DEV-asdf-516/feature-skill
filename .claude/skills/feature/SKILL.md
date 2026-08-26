---
name: feature
description: 복잡한 피처를 다중 에이전트 합의 파이프라인으로 처리한다. 오케스트레이터가 사용자 요구를 설계 문서(design.md)로 쓰고 이어서 워커용 구현 문서(implementation.md=무엇, approach.md=어떻게)를 쓰며, 러너(feature-run.sh)가 검증자 합의 → 워커 구현 → 리뷰 수렴 → 최종 테스트를 기계적으로 연결하고, 사용자 판단이 필요한 지점에서만 오케스트레이터로 돌아온다. 사용자가 "feature" 또는 "피처"를 명시하며 기능 구현을 요청할 때 사용한다. 사소한 수정·단일 파일 변경에는 사용하지 않는다.
---

# feature

피처 하나를 "설계 합의 → 구현 문서 합의 → 구현 → 리뷰 수렴 → 최종 테스트"로 끝까지 처리한다. 오케스트레이터(이 세션)가 하는 일은 **문서 작성과 사용자 질문뿐**이고, 나머지 결정론적 제어는 전부 `scripts/feature-run.sh`(교통정리기)가 맡는다. 러너는 agent 가 아니다 — 판단이 필요한 상태가 나오면 추가 추론 없이 즉시 이 세션으로 반환한다.

사용자가 세션 요약을 요청하면 `<skill_dir>/specs/feature_<번호>/session/SESSION-<YYYY-MM-DD>-<피처>.md`에 작성한다(결정·미해결 쟁점·다음 단계 위주).

## 사전 조건

1. `config.sh`의 역할별 `*_MODEL`·`*_EFFORT`·`TEST_CMD`·`LINT_CMD`가 실제 환경과 일치. 빈 값이나 `CHANGE_ME`가 남으면 가드가 실행 거부.
2. `claude`, `codex`, `jq`, `uuidgen`, `envsubst` 설치·로그인.
3. 저장소 루트에서 실행. `.agent-work/`는 `.gitignore`에 등록돼 있다.

## Phase 0 — 초기화 + 문서 작성 (오케스트레이터)

1. 새 피처면 러너를 `--new`로 한 번 실행한다. 이전 산출물을 `.agent-work/archive/<이름>/`으로 `mv`(rm 금지)하고 `decisions.md`를 비운 뒤, `design.md`가 없으므로 `NEED_DOCS(DESIGN_MISSING)`(exit 3)로 즉시 돌아온다 — 정상이다. 같은 피처의 계속이면 `--new`를 쓰지 않는다(세션 이어가기가 캐시 절감의 핵심).

```bash
bash <skill_dir>/scripts/feature-run.sh --new --archive-as <이전-피처명>
```

2. 사용자 요구를 `.agent-work/request.md`에 기록(원문 + 해석한 범위 + 명시적 제외). 스펙 폴더(`<skill_dir>/specs/feature_<번호>/`)에 문서·이미지가 있으면 전부 읽어 반영. **모호하면 추측 대신 사용자에게 질문**하고 `decisions.md`에 `- [USER-QUESTION] <질문> → <답>` 형식으로 기록.
3. `.agent-work/design.md` 초안: 목표, API/데이터 계약, 에러·동시성 처리, 테스트 기준, 비범위. 갈리는 설계 판단은 옵션을 제시해 사용자 결정을 받는다.

## Phase 1 — 러너 실행

```bash
bash <skill_dir>/scripts/feature-run.sh [--branch feature/<이름>]
```

러너가 `preflight → design → impl → worker → review → verify → done`을 연결한다. 실시간 로그 창(`feature-live`)은 러너가 연다. 진행은 `.agent-work/live.log`와 `run-state.json`으로 관찰한다. **종료 코드로만 다음 행동을 정한다:**

| exit | status | reason | 오케스트레이터 행동 |
|---|---|---|---|
| 0 | `DONE` | — | Phase 2 보고 |
| 3 | `NEED_DOCS` | `DESIGN_MISSING` | Phase 0의 2·3 수행 후 재실행 |
| 3 | `NEED_DOCS` | `IMPL_DOCS_MISSING` | 설계 합의 완료. 아래 "구현 문서 작성" 후 재실행 |
| 2 | `NEED_USER` | `DEADLOCK` / `MAX_ROUNDS` | 마지막 리뷰 JSON의 쟁점만 사용자에게 보고하고 멈춘다. 답을 `decisions.md`에 `[USER-QUESTION]`으로 기록, 해당 문서에 반영 후 재실행 |
| 2 | `NEED_USER` | `UNDECIDED` | `worker-result.json`의 `undecided` 항목을 **합의 루프 없이 그대로 사용자에게 질문**. 답 기록 → `approach.md` 반영 → 재실행(러너가 worker 부터 재개) |
| 2 | `NEED_USER` | `TEST_RETRIES_EXHAUSTED` / `APPROVAL_STALE_REPEATED` | 로그(`reviews/verify-*.log`)와 상황을 정리해 사용자 보고 후 멈춘다 |
| 1 | `ENV_ERROR` | — | 원인 확인 후 재실행. 진행 금지 |

재실행은 항상 같은 명령이다. 러너가 `run-state.json`의 stage 힌트와 실제 산출물(합의 PASS 파일, `worker-result.json`, `approved.fingerprint`)을 교차 확인해 재개 지점을 스스로 고른다 — 오케스트레이터가 단계를 지정하지 않는다.

### 구현 문서 작성 (`IMPL_DOCS_MISSING` 반환 시)

합의된 `design.md` 기반으로 두 파일을 쓴다. 설계 합의를 재해석·번복하지 않는다.

1. `.agent-work/implementation.md` — **무엇을** 구현하는가(도메인 지식). 변경·생성 파일 목록과 순서, 클래스/함수 수준 계획(시그니처·입출력 계약), 작성할 테스트 목록, 완료 판정 기준.
2. `.agent-work/approach.md` — **어떻게** 구현하는가(CS 지식). 단위는 함수가 아니라 **구현 결정**이며, 결정마다 `REQUIRED` 또는 `DELEGATED`를 표시한다.
   - **REQUIRED(결정 필수)** — 다음 7종은 반드시: ① 아키텍처/모듈 경계 ② 횡단 관심사 ③ 상태 변경·영속화 ④ 동시성·트랜잭션 ⑤ 보안·권한·개인정보 ⑥ 비자명 알고리즘 ⑦ 입력 파싱·변환·검증. 기법·구조·금지 방식을 적고, 근거를 **우선순위 고정**으로 붙인다: 저장소에 같은 종류의 문제를 푸는 기존 코드가 있으면 그 패턴을 최우선으로 따르고 위치(파일 경로·심볼)를 직접 열어 확인한 뒤 인용 → 없으면 탐색 근거와 함께 그 문제 유형에 가장 적합한 표준 기법 + 선택 이유.
   - **DELEGATED(위임)** — 그 밖의 로컬 세부(단순 mapper·delegation·getter·DTO 값 전달 등). 기법을 적지 않는다. 워커가 "기존 패턴 우선 → 표준 라이브러리 우선 → 새 추상화 금지" 제약 안에서 정하고 결과 JSON의 `delegated_choices`에 보고하며, 리뷰어는 그 목록으로 제약 위반만 검사한다.
   - 애매하면 REQUIRED. 단 분류 단위가 "결정"이므로 모든 메서드가 REQUIRED로 회귀하지 않는다. 예: `마스킹 여부 판정 규칙`·`전화/이메일 마스킹 규칙`·`AOP 적용 위치` = REQUIRED, `DTO 필드 값 전달`·`단순 mapper` = DELEGATED.

## Phase 2 — 보고 (오케스트레이터)

`DONE`이면 변경 요약·라운드 수(`run-state.json.history`, `usage.jsonl`)·`decisions.md` 주요 결정·`delegated_choices`를 한 번에 보고한다. 커밋 절차는 강제 규칙 참조.

## 강제 규칙 (어길 수 없음)

- **막히면 AI끼리 풀지 말고 사용자에게 묻는다.** 러너가 자동으로 도는 루프는 성공 조건이 기계적인 두 가지뿐 — (리뷰 이슈 → 수정자 → 재리뷰), (테스트 실패 → 워커 1회 수정 → 재리뷰 → 재테스트). 교착·라운드 초과·`UNDECIDED`·재시도 소진은 전부 즉시 사용자 반환이며, 러너·오케스트레이터 어느 쪽도 "다른 에이전트에게 다시 물어보는" 자동 복구를 추가하지 않는다.
- **구현 방식(어떻게)의 REQUIRED 결정은 워커가 정하지 않는다** — `approach.md`에서 오케스트레이터가 결정하고 검증자가 합의한다. 워커·수정자가 REQUIRED와 다른 기법을 쓰면 리뷰어가 문서 위반으로 잡는다. DELEGATED는 워커 선택을 존중하되 세 제약 위반만 issue.
- 모호한 요구·갈리는 설계 판단은 추측 금지 — 사용자 질문 후 문서 반영, `decisions.md`에 `- [USER-QUESTION] <질문> → <답>` 기록.
- 판정은 스키마 검증된 JSON만 신뢰한다: 검증자(`PASS/BLOCK`), 리뷰어(`APPROVE/REQUEST_CHANGES`), 워커(`DONE/UNDECIDED`, `schemas/worker-result.schema.json`). 모순 응답은 스크립트가 즉시 거부. "대충 통과 간주" 금지.
- 하위 실행은 반드시 `--model`/`-m` 명시(`config.sh` 한 곳에서 관리). `core_rules.md`는 워커에게만, 선택 `conventions.md`는 전 역할에 주입. 프로젝트 codex hooks(`.codex/hooks.json` + `worker_guard.sh`)는 매 툴 호출에 별도 적용.
- **워커(codex)와 리뷰어·수정자는 파일 삭제 절대 금지** — 훅이 강제한다(claude 쪽 `pre_bash_guard`, codex 쪽 `worker_guard`). 러너의 `--new` 아카이브도 `mv`만 쓴다. 삭제가 필요하면 `decisions.md`에 대상·사유를 남기고 사용자 에스컬레이션.
- 워커·리뷰어·수정자는 커밋·푸시 금지. 커밋은 사용자가 요청했을 때만 — `DONE` 이후 오케스트레이터가 `verify_approved_fingerprint`(config.sh)로 승인 지문을 재확인하고 `touch .claude/ALLOW_COMMIT`(1회용 플래그) 후 `fixer` 세션에 별도 호출로 위임.
- 마지막 APPROVE 이후 코드가 조금이라도 바뀌면 재리뷰 없이 종료 금지 — 러너의 verify 단계가 지문으로 강제한다.
- 모든 하위 실행은 stdin을 닫고 돌린다(스크립트 시작부 `exec </dev/null`). 러너를 다른 명령·heredoc과 한 줄로 묶지 않는다.
- **진행 확인은 "프로세스 생존"이 아니라 "실제 진척"으로 판정** — `live.log` 최근 갱신과 CPU 시간 증가를 본다. 둘 다 멈춰 있으면 입력 대기·행(hang)이다: 해당 PID만 TERM으로 정리하고(`pkill` 광역 금지) 원인 확인 후 같은 명령으로 재실행하면 러너가 재개 지점을 찾는다. 중단된 라운드 산출물은 archive로 옮긴다.

## 토큰 절약 구조 (스크립트에 내장)

- 오케스트레이터는 러너 호출 1회당 턴 1회만 소비한다. 러너 내부의 라운드 진행·재진입은 상위 세션 API 호출을 발생시키지 않는다.
- Claude 하위 실행은 역할별 세션 유지: `designer-doc`, `reviewer`, `fixer`. 첫 호출이 `--session-id`, 이후 `--resume`. `reviewer`와 `fixer`는 절대 같은 세션으로 합치지 않는다.
- 사용량은 `$WORK_DIR/usage.jsonl`에 라운드별 누적. codex는 출력의 "tokens used" 참고.
