---
name: feature
description: 복잡한 피처를 다중 에이전트 합의 파이프라인으로 처리한다. Fable이 사용자 요구를 설계 문서(design.md)로 쓰고 이어서 워커용 구현 문서(implementation.md)를 쓰며, 각 문서를 Sol(Codex)이 검증해 수렴할 때까지 반복한 뒤, Luna가 구현을 완수하면 Sonnet이 리뷰하며 필요한 수정·리팩터링을 직접 수행하고, Fable이 최종 전체 테스트로 마감한다. 사용자가 "feature" 또는 "피처"를 명시하며 기능 구현을 요청할 때 사용한다. 사소한 수정·단일 파일 변경에는 사용하지 않는다.
---

# feature

복잡한 피처 하나를 "설계 합의 → 구현 문서 합의 → 구현 → 리뷰 수렴 → 최종 테스트"로 끝까지 처리하는 파이프라인. 제어권은 항상 이 세션(Fable, 오케스트레이터) 하나에만 있다. 다른 에이전트는 전부 비대화형 하위 실행이다. 두 루프 스크립트의 진행 로그는 `.agent-work/live.log` 에 실시간 누적된다 — 별도 터미널에서 `./feature-live` 로 관찰한다.

## 사전 조건

1. `config.sh` 의 모델 ID가 실제 환경과 일치해야 한다. reasoning effort 는 Claude(Fable/Sonnet) `medium`, Sol `high`, Luna `max`로 고정되며, 다른 값이면 config.sh 가드가 실행을 거부한다.
2. `claude`, `codex`, `jq`, `uuidgen`, `envsubst` 가 설치·로그인되어 있어야 한다. 워커 페르소나 프롬프트는 `prompts/*.md` 템플릿으로 관리되며 스크립트가 `envsubst` 로 변수를 채워 전달한다.
3. 저장소 루트에서 실행한다. `.agent-work/` 는 `.gitignore` 에 등록되어 있다.
4. Phase 0·4를 직접 수행하는 오케스트레이터 Fable 세션도 `medium` effort로 시작되어 있어야 한다. 스크립트가 생성하는 모든 Claude 하위 실행은 `--effort medium`을 명시한다.

## Phase 0 — 초기화 (Fable 직접 수행)

0. 새 피처 시작이면 `.agent-work/` 안의 이전 산출물 **전부**(`request.md`, `design.md`, `implementation.md`, `decisions.md`, `.session-*`, `reviews/`, `state.json`, `usage.jsonl` 등 — `archive/` 자신만 제외)를 **삭제하지 말고** `.agent-work/archive/<이전-피처명-또는-날짜>/` 로 `mv` 해서 치운다 (rm 금지 — 삭제는 사용자에게 요청). `.session-*` 가 작업 디렉터리에 남으면 이전 피처의 대화 문맥이 섞이고, 명세·결정 기록이 남으면 덮어써져 유실된다. 단 Phase 4 재진입 등 같은 피처의 계속이면 그대로 둔다 — 세션 이어가기가 캐시 절감의 핵심이다.
1. 사용자의 요구를 `.agent-work/request.md` 에 기록한다 (원문 + 해석한 범위 + 명시적 제외 사항). **요구가 모호하면 추측으로 메우지 말고 사용자에게 질문해 답을 받은 뒤 기록한다.**
2. `.agent-work/design.md` 초안(설계 문서)을 작성한다. 포함: 목표, API/데이터 계약, 에러·동시성 처리, 테스트 기준(어떤 테스트가 통과해야 완료인지), 비범위(non-goals). 작성 중 설계 판단이 갈리는 지점이 나오면 임의로 정하지 말고 사용자에게 옵션을 제시해 결정을 받는다.
   사용자에게 한 질문과 받은 답은 `.agent-work/decisions.md` 에 `- [USER-QUESTION] <질문> → <답>` 형식으로 기록한다 — Sol 이슈 판정(ACCEPT/REJECT)과 사용자 결정을 구분해 추적하기 위함이다.
3. 빈 `.agent-work/decisions.md` 를 만든다.

## Phase 1 — 설계 합의 (스크립트가 수렴 강제)

```bash
bash <skill_dir>/scripts/consensus-loop.sh design
```

- Sol(Codex, read-only)이 설계 문서를 검토해 `reviews/sol-design-round-NN.json` 에 BLOCK/PASS 판정을 남기고, Fable(비대화형 하위 실행)이 각 이슈를 ACCEPT/REJECT 하며 `design.md` 를 갱신한다. PASS + blocking 0건이 될 때까지 반복.
- 종료 코드 2(교착 또는 라운드 초과)면 **다음 단계로 넘어가지 말고** 남은 쟁점만 정리해 사용자에게 보고하고 멈춘다.

## Phase 1.5 — 구현 문서 작성·합의 (Fable 직접 작성 → 스크립트 합의)

1. 합의된 `design.md` 를 바탕으로 Fable이 `.agent-work/implementation.md` (Sonnet/Luna용 구현 문서)를 직접 작성한다. 포함: 변경·생성할 파일 목록과 순서, 클래스/함수 수준의 변경 계획, 작성할 테스트 목록, 완료 판정 기준. 설계에서 합의된 결정을 재해석하거나 뒤집지 않는다.
2. 구현 문서도 같은 루프로 합의한다:

```bash
bash <skill_dir>/scripts/consensus-loop.sh impl
```

- Sol이 `implementation.md` 가 설계와 모순 없이 구현 가능한 수준인지 검토해 `reviews/sol-impl-round-NN.json` 에 판정을 남긴다. 종료 코드 2면 Phase 1과 동일하게 사용자 에스컬레이션.

## Phase 2 — 구현 (Luna, 메인 작성자)

합의된 구현 문서로 Luna에게 구현을 위임한다. 가능하면 전용 브랜치에서:

```bash
source .claude/skills/feature/config.sh   # LUNA_EFFORT=max 가드 포함
git checkout -b feature/<이름>
codex exec -m "$LUNA_MODEL" -c "model_reasoning_effort=\"$LUNA_EFFORT\"" --sandbox workspace-write \
  "$(CORE_RULES="$(cat "$CORE_RULES_FILE")" WORK_DIR="$WORK_DIR" TEST_CMD="$TEST_CMD" \
    render_prompt .claude/skills/feature/prompts/luna-implement.md '${CORE_RULES} ${WORK_DIR} ${TEST_CMD}')"
```

Luna 가 1차 구현을 완수할 때까지 다른 에이전트는 코드를 만지지 않는다. Sonnet 은 Luna 완료 이후(Phase 3)에만 진입한다.

## Phase 3 — 구현 리뷰 수렴

```bash
bash <skill_dir>/scripts/impl-review-loop.sh
```

- 각 라운드: Sonnet 이 읽기 전용 실행으로 diff 를 리뷰해 JSON 판정을 남기고, 이슈가 있으면 별도 실행에서 직접 수정·리팩터링한다. 수정분은 다음 라운드 리뷰로 재검증되며, APPROVE + 이슈 0건까지 반복(수정 최대 `MAX_IMPL_ROUNDS`회, 리뷰는 +1회).
- 종료 코드 2면 남은 이슈를 사용자에게 보고하고 멈춘다.

## Phase 4 — 최종 테스트 (Fable 직접 수행)

1. `TEST_CMD` 와 `LINT_CMD` 를 전체 실행한다.
2. 실패 시: 실패 로그를 붙여 Luna에게 재수정을 맡긴다(Phase 2와 같은 호출). Luna 수정 후에는 기존 Sonnet 승인이 최신 코드에 대한 승인이 아니므로 **반드시 Phase 3 을 재실행해 재승인을 받은 뒤** 1번부터 다시 수행한다. 이 재진입은 최대 `MAX_TEST_RETRIES` 회. 그래도 실패하면 실패 내역을 정리해 사용자에게 보고하고 멈춘다.
3. 통과 시: 변경 요약, 라운드 수, decisions.md 의 주요 결정을 한 번에 보고한다. 커밋은 사용자가 요청했을 때만, Fable이 `sonnet-fix` 세션에 별도 호출로 위임해 Sonnet 이 수행한다.

## 강제 규칙 (어길 수 없음)

- 설계 단계(Phase 0·1)에서 모호한 요구나 갈리는 설계 판단은 추측으로 메우지 않는다 — 사용자에게 질문해 답을 받은 뒤 문서에 반영하고, `decisions.md` 에 `- [USER-QUESTION] <질문> → <답>` 형식으로 남긴다. Sol과의 교착도 사용자 판단으로 푼다.
- 각 하위 실행은 반드시 `--model` / `-m` 으로 모델을 명시한다. CLI가 실패하면 다음 단계로 넘어가지 않는다.
- reasoning effort 는 Claude(Fable/Sonnet) `medium`, Sol `high`, Luna `max`만 허용한다 (config.sh 가드 + 모든 하위 호출에 명시). Phase 0·4의 Fable 직접 실행도 `medium` 세션이어야 한다. 규칙 주입: Sonnet 은 `--append-system-prompt`, Luna(codex)는 프롬프트 선두의 `[반드시 지킬 규칙]` 블록으로 `core_rules.md` 를 매 실행 주입하고, 프로젝트 레벨 codex hooks(`.codex/hooks.json` + `.codex/hooks/luna_guard.sh`)가 매 툴 호출마다 적용된다.
- 파이프라인 라운드 중 워커(Luna/Sonnet)는 커밋·푸시하지 않는다. 커밋은 사용자가 요청했을 때만, Phase 3 승인 + Phase 4 테스트 통과 이후 Fable이 `sonnet-fix` 세션에 별도 호출로 위임해 Sonnet 이 수행한다. 위임 직전 Fable이 `touch .claude/ALLOW_COMMIT` 으로 1회용 허용 플래그를 만든다 (`pre_bash_guard` 훅이 플래그 없는 커밋을 차단하므로, 이 플래그가 곧 "사용자 지시 확인" 증거다).
- Sonnet 의 마지막 APPROVE 이후 코드가 조금이라도 바뀌면(누가 바꿨든) Phase 3 재리뷰 없이 파이프라인을 끝내지 않는다.
- 어떤 단계도 "대충 통과한 것으로 간주"하지 않는다. PASS/APPROVE 판정은 반드시 스키마 검증된 JSON 파일에 남아야 하며, 이슈 0건과 동시일 때만 통과로 인정한다 (모순 응답은 스크립트가 거부).
- 라운드 한도 초과·교착은 실패가 아니라 **사용자 에스컬레이션**이다. 쟁점 요약만 올리고 멈춘다.

## 토큰 절약 구조 (스크립트에 내장)

- Claude 하위 실행은 역할별 세션을 이어간다: `fable-doc`(설계·구현 문서 수정 공용 — 설계 라운드의 결정 문맥을 구현 문서 수정에서도 그대로 활용), `sonnet-review`(리뷰), `sonnet-fix`(수정). 첫 호출이 `--session-id` 로 UUID를 만들고 이후 `--resume` 한다 (`$WORK_DIR/.session-<역할>`). 라운드 간 저장소 재탐색이 사라지고 동일 프리픽스는 프롬프트 캐시로 처리된다.
- `sonnet-review` 와 `sonnet-fix` 는 절대 같은 세션으로 합치지 않는다 — 리뷰가 자기 수정 문맥에 오염되면 승인 독립성이 깨진다.
- Claude 하위 실행의 사용량은 `$WORK_DIR/usage.jsonl` 에 라운드별로 누적된다 (비용·캐시 적중 확인용). codex(Sol/Luna) 사용량은 codex 출력의 "tokens used" 라인 참고.
