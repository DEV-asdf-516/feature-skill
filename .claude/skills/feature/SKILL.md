---
name: feature
description: 복잡한 피처를 다중 에이전트 합의 파이프라인으로 처리한다. Fable이 사용자 요구를 설계 문서(design.md)로 쓰고 이어서 워커용 구현 문서(implementation.md)를 쓰며, 각 문서를 Sol(Codex)이 검증해 수렴할 때까지 반복한 뒤, Luna가 구현을 완수하면 Sonnet이 리뷰하며 필요한 수정·리팩터링을 직접 수행하고, Fable이 최종 전체 테스트로 마감한다. 사용자가 "feature" 또는 "피처"를 명시하며 기능 구현을 요청할 때 사용한다. 사소한 수정·단일 파일 변경에는 사용하지 않는다.
---

# feature

피처 하나를 "설계 합의 → 구현 문서 합의 → 구현 → 리뷰 수렴 → 최종 테스트"로 끝까지 처리한다. 제어권은 이 세션(Fable, 오케스트레이터) 하나뿐이고 나머지는 전부 비대화형 하위 실행이다. 두 루프의 진행 로그는 `.agent-work/live.log`에 실시간 누적 — 별도 터미널에서 `./feature-live`로 관찰.

## 사전 조건

1. `config.sh` 모델 ID가 실제 환경과 일치. reasoning effort는 Claude(Fable/Sonnet) `medium`, Sol `high`, Luna `max` 고정 — 다르면 config.sh 가드가 실행 거부.
2. `claude`, `codex`, `jq`, `uuidgen`, `envsubst` 설치·로그인. 워커 프롬프트는 `prompts/*.md` 템플릿을 스크립트가 `envsubst`로 렌더링해 전달.
3. 저장소 루트에서 실행. `.agent-work/`는 `.gitignore`에 등록돼 있다.
4. Phase 0·4를 직접 수행하는 Fable 세션도 `medium` effort로 시작. 스크립트의 모든 Claude 하위 실행은 `--effort medium` 명시.

## Phase 0 — 초기화 (Fable 직접)

0. 새 피처 시작이면 `.agent-work/` 안의 이전 산출물 전부(`request.md`, `design.md`, `implementation.md`, `decisions.md`, `.session-*`, `reviews/`, `state.json`, `usage.jsonl` 등 — `archive/` 자신만 제외)를 삭제하지 말고 `.agent-work/archive/<이전-피처명-또는-날짜>/`로 `mv`(rm 금지 — 삭제는 사용자에게 요청). `.session-*`이 남으면 이전 피처 문맥이 섞이고, 명세·결정 기록은 덮어써져 유실된다. 같은 피처의 계속(Phase 4 재진입 등)이면 그대로 둔다 — 세션 이어가기가 캐시 절감의 핵심.
1. 빈 `.agent-work/decisions.md` 생성 — 이후 모든 기록은 append만, 재초기화 금지.
2. 사용자 요구를 `.agent-work/request.md`에 기록(원문 + 해석한 범위 + 명시적 제외). **모호하면 추측 대신 사용자에게 질문해 답을 받은 뒤 기록.**
3. `.agent-work/design.md` 초안 작성. 포함: 목표, API/데이터 계약, 에러·동시성 처리, 테스트 기준(무엇이 통과해야 완료인지), 비범위(non-goals). 갈리는 설계 판단은 임의로 정하지 말고 사용자에게 옵션을 제시해 결정받는다. 질문과 답은 `decisions.md`에 `- [USER-QUESTION] <질문> → <답>` 형식으로 기록 — Sol 이슈 판정(ACCEPT/REJECT)과 사용자 결정을 구분 추적하기 위함.

## Phase 1 — 설계 합의 (스크립트가 수렴 강제)

```bash
bash <skill_dir>/scripts/consensus-loop.sh design
```

Sol(Codex, read-only)이 `reviews/sol-design-round-NN.json`에 BLOCK/PASS 판정을 남기고, Fable(비대화형 하위 실행)이 이슈별 ACCEPT/REJECT 후 `design.md` 갱신. PASS + blocking 0건까지 반복. 종료 코드 2(교착/라운드 초과)면 **다음 단계 진행 금지** — 남은 쟁점만 사용자에게 보고하고 멈춘다.

## Phase 1.5 — 구현 문서 작성·합의

1. 합의된 `design.md` 기반으로 Fable이 `.agent-work/implementation.md`(Sonnet/Luna용)를 직접 작성. 포함: 변경·생성 파일 목록과 순서, 클래스/함수 수준 계획, 작성할 테스트 목록, 완료 판정 기준. 설계 합의를 재해석·번복하지 않는다.
2. 같은 루프로 합의:

```bash
bash <skill_dir>/scripts/consensus-loop.sh impl
```

Sol이 설계와 모순 없이 구현 가능한지 검토해 `reviews/sol-impl-round-NN.json`에 판정. 종료 코드 2면 Phase 1과 동일하게 사용자 에스컬레이션.

## Phase 2 — 구현 (Luna, 메인 작성자)

합의된 구현 문서로 Luna에게 위임. 가능하면 전용 브랜치에서:

```bash
source .claude/skills/feature/config.sh   # LUNA_EFFORT=max 가드 포함
git checkout -b feature/<이름>
codex exec -m "$LUNA_MODEL" -c "model_reasoning_effort=\"$LUNA_EFFORT\"" --sandbox workspace-write \
  "$(CORE_RULES="$(cat "$CORE_RULES_FILE")" WORK_DIR="$WORK_DIR" TEST_CMD="$TEST_CMD" \
    render_prompt .claude/skills/feature/prompts/luna-implement.md '${CORE_RULES} ${WORK_DIR} ${TEST_CMD}')" \
  </dev/null
```

Luna의 1차 구현 완료 전에는 다른 에이전트가 코드를 만지지 않는다. Sonnet은 Phase 3에서만 진입.

## Phase 3 — 구현 리뷰 수렴

```bash
bash <skill_dir>/scripts/impl-review-loop.sh
```

각 라운드: Sonnet이 읽기 전용 실행으로 diff를 리뷰해 JSON 판정 → 이슈 있으면 별도 실행에서 직접 수정·리팩터링. 수정분은 다음 라운드에서 재검증, APPROVE + 이슈 0건까지 반복(수정 최대 `MAX_IMPL_ROUNDS`회, 리뷰는 +1회). 종료 코드 2면 남은 이슈를 사용자에게 보고하고 멈춘다.

## Phase 4 — 최종 테스트 (Fable 직접)

1. `source .claude/skills/feature/config.sh` 후 `verify_approved_fingerprint` 실행 — 마지막 APPROVE 시점(`$WORK_DIR/approved.fingerprint`)과 현재 작업 트리 비교. APPROVAL_STALE이면 Phase 3 재실행으로 재승인 후 여기로 복귀.
2. `TEST_CMD`·`LINT_CMD` 전체 실행.
3. 실패 시: 실패 로그를 붙여 Luna에게 재수정(Phase 2와 같은 호출). Luna 수정 후 기존 승인은 무효이므로 **반드시 Phase 3 재승인 후** 1번부터 재수행. 재진입 최대 `MAX_TEST_RETRIES`회 — 그래도 실패면 내역 정리해 사용자 보고 후 중단.
4. 통과 시: 보고 전 `verify_approved_fingerprint` 재실행 — 테스트·린트가 코드를 바꿨을 수 있다(스냅샷 갱신, 자동 포맷 등). STALE이면 Phase 3 재실행 후 1번부터. 유효하면 변경 요약·라운드 수·decisions.md 주요 결정을 한 번에 보고. 커밋 절차는 강제 규칙 참조.

## 강제 규칙 (어길 수 없음)

- 모호한 요구·갈리는 설계 판단(Phase 0·1)은 추측 금지 — 사용자 질문 후 문서 반영, `decisions.md`에 `- [USER-QUESTION] <질문> → <답>` 기록. Sol과의 교착도 사용자 판단으로 푼다.
- 하위 실행은 반드시 `--model`/`-m` 명시. CLI 실패 시 다음 단계 진행 금지.
- effort는 Claude `medium`, Sol `high`, Luna `max`만 허용(config.sh 가드 + 모든 호출 명시). Phase 0·4의 Fable 직접 실행도 `medium` 세션. 규칙 주입: Sonnet은 `--append-system-prompt`, Luna(codex)는 프롬프트 선두 `[반드시 지킬 규칙]` 블록으로 `core_rules.md`를 매 실행 주입 + 프로젝트 codex hooks(`.codex/hooks.json` + `.codex/hooks/luna_guard.sh`)가 매 툴 호출 적용.
- 워커(Luna/Sonnet)는 라운드 중 커밋·푸시 금지. 커밋은 사용자가 요청했을 때만 — Phase 3 승인 + Phase 4 통과 후, Fable이 `verify_approved_fingerprint`로 승인 지문 유효성을 재확인하고 `touch .claude/ALLOW_COMMIT`(1회용 플래그 — `pre_bash_guard` 훅이 플래그 없는 커밋을 차단하므로 이 플래그가 곧 "사용자 지시 확인" 증거) 후 `sonnet-fix` 세션에 별도 호출로 위임해 Sonnet이 수행.
- 마지막 APPROVE 이후 코드가 조금이라도 바뀌면(누가 바꿨든) Phase 3 재리뷰 없이 파이프라인 종료 금지. 지문으로 강제: `impl-review-loop.sh`가 승인 시 작업 트리 지문(tracked diff + status + untracked 파일 내용)을 `$WORK_DIR/approved.fingerprint`에 남기고, Phase 4 진입 직전·테스트 통과 후·커밋 위임 직전에 `verify_approved_fingerprint`(config.sh)로 검증.
- 어떤 단계도 "대충 통과 간주" 금지. PASS/APPROVE는 스키마 검증된 JSON 파일에 남고 이슈 0건과 동시일 때만 인정 — 모순 응답은 스크립트가 즉시 거부.
- 라운드 초과·교착은 실패가 아니라 **사용자 에스컬레이션** — 쟁점 요약만 올리고 멈춘다.
- **모든 하위 실행은 stdin을 닫고 돌린다** — codex/claude 비대화형 실행은 stdin이 열린 채 상속되면 EOF를 기다리며 무기한 멈춘다. 루프 스크립트는 시작부 `exec </dev/null`로 일괄 차단돼 있고, 스크립트 밖에서 직접 호출하는 하위 실행(Phase 2·4의 Luna 등)은 `</dev/null`을 반드시 붙인다. `decisions.md` 기록(heredoc 등)과 장기 실행 명령을 같은 명령·파이프라인·백그라운드 블록으로 묶지 않는다 — 기록 먼저, 실행은 별도 명령으로.
- **진행 확인은 "프로세스 생존"이 아니라 "실제 진척"으로 판정** — `live.log`(또는 해당 실행의 로그)가 최근 수 분 내 갱신됐는지와 CPU 시간이 증가하는지를 본다. 둘 다 멈춰 있으면 effort가 높아 느린 게 아니라 입력 대기·행(hang)이다: 해당 PID만 정확히 TERM으로 정리하고(`pkill` 광역 금지) 원인 확인 후 재시작한다. 중단된 라운드의 산출물은 정상 결과와 섞이지 않게 archive로 옮긴다.

## 토큰 절약 구조 (스크립트에 내장)

- Claude 하위 실행은 역할별 세션 유지: `fable-doc`(설계·구현 문서 수정 공용 — 설계 라운드의 결정 문맥을 구현 문서 수정에 재활용), `sonnet-review`(리뷰), `sonnet-fix`(수정). 첫 호출이 `--session-id`로 UUID 생성, 이후 `--resume`(`$WORK_DIR/.session-<역할>`). 라운드 간 저장소 재탐색이 사라지고 동일 프리픽스는 프롬프트 캐시 처리.
- `sonnet-review`와 `sonnet-fix`는 절대 같은 세션으로 합치지 않는다 — 리뷰가 자기 수정 문맥에 오염되면 승인 독립성이 깨진다.
- Claude 하위 실행 사용량은 `$WORK_DIR/usage.jsonl`에 라운드별 누적(비용·캐시 적중 확인용). codex(Sol/Luna)는 출력의 "tokens used" 라인 참고.
