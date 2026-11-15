# Phase 2 — DONE 보고 · finalize · 커밋 경계

> feature 스킬 참조 문서(`SKILL.md` 에서 분리한 원문). 읽는 시점: 러너가 exit 0(`DONE`) 으로 돌아온 직후, `--finalize` 를 실행하기 직전과 그 결과(exit 0/1/2)를 처리할 때, 사용자가 커밋을 요청했을 때.

## Phase 2 — 보고 + finalize 질문 (오케스트레이터)

`DONE`이면 변경 요약·라운드 수(`run-state.json.history`, `usage.jsonl`)·`decisions.md` 주요 결정·`delegated_choices`를 한 번에 보고한다. 실행 중 워커 `DOC_GAP`, 리뷰어 `CONTRACT_VIOLATION`/`UNDECIDED_APPROACH`, 반복된 수정자 수정이 있었으면 그 지점의 implementation.md/approach.md 가 material decision 을 충분히 정했는지(어떤 material 선택이
워커에게 남았는지, 반대로 local expression 을 불필요하게 REQUIRED 로 적었는지)를 함께 분석해 보고한다 — 모델 이름별 문서 길이 조정·capability score·profile 은 만들지 않는다. `DONE` 은 리뷰 승인 + 전체 `TEST_CMD`/`LINT_CMD` 통과 + 승인 지문 유효를 뜻하며 여기서 상태 기계는 끝난다
— 러너는 worktree 를 지우거나 원본에 반영하지 않는다.

보고 뒤 **사용자에게 finalize 여부를 묻는다**(자동 실행 금지):

> 작업이 완료되었습니다. 피처 worktree 결과를 원래 작업공간에 커밋 없이 반영하고 worktree 를 정리할까요?

- **승인** → `--finalize` 를 실행한다. 러너는 기존 worktree 만 찾고(없으면 만들지 않음) 검증(같은 저장소·브랜치 일치·러너 없음·`DONE`·승인 지문·기준선 B 존재·dirty submodule 없음) → archive → 원본에 무커밋 3-way 반영 → worktree/피처 브랜치 정리 순으로 진행하고, 결과를 보고한다. 종료 코드 0 = `FINALIZED`(또는 already finalized), 2 = `FINALIZE_CONFLICT` / `APPLIED_CLEANUP_INCOMPLETE`(사용자 확인 필요), 1 = 거부·오류(원본·worktree 불변).
  ```bash
  bash <skill_dir>/scripts/feature-run.sh --feature <id> --finalize     # 원본 working tree 에서 실행 (수동 --worktree/--branch 를 썼다면 같은 인자)
  ```
  반영 모델은 `HEAD` 대비 diff 가 아니다. worktree 생성 시 원본의 dirty 상태까지 snapshot 했으므로 `B` = 생성 당시 tree(`feature.json.bootstrap_tree`), `F` = 지금 worktree tree, `O` = 지금 원본 tree 로 두고 **`merge(B, O, F)`** 를 `git merge-tree --write-tree --merge-base=B O F` 로 object 상에서만 계산한다
  — B 에 있던 원본 dirty 변경은 중복 적용되지 않고, 피처 실행 중 원본에서 생긴 변경(O)은 보존되며, 같은 파일의 떨어진 hunk 는 자동 병합된다. 결과는 원본에 **working tree 변경으로만** 들어간다: commit·stash·branch 변경·checkout·reset 없음, 실제 index 는 읽지도 쓰지도 않으므로 staged 상태가 byte 그대로 남는다(임시 index 로 `read-tree O` → `read-tree -m -u O R`).
  적용 뒤 원본을 다시 snapshot 해 계산해 둔 merge tree 와 같은지 검증하고, 그 뒤에만 `git worktree remove` + `git branch -D`(정확히 피처 브랜치이고 다른 worktree 가 쓰지 않을 때) 를 한다. 결과 상태: 원래 브랜치 + 피처 코드가 working tree 에 반영 + 커밋 없음 + worktree/브랜치 제거.
  **여기서 피처 작업은 끝이다.** 커밋은 사용자가 따로 요청할 때만(강제 규칙).
  - archive: 반영·삭제보다 먼저 `<원본>/.agent-work/archive/worktree/<id>/<timestamp>/` 에 `manifest.json`(feature.json + B/O/F/merge tree), `feature.patch`(B→F, `--binary`), `finalize.json`(status·trees·`source_after_tree`·cleanup·충돌 목록), `agent-work/`(worktree 의 `.agent-work` 사본)를 남긴다. archive 실패 = finalize 중단(아무것도 바꾸지 않음).
  - `FINALIZE_CONFLICT`(exit 2): B/O/F 가 같은 부분을 바꿨다. 자동 해결·모델 위임 없음. 원본 내용·index·worktree·브랜치·archive 전부 그대로이고 충돌 경로는 로그와 `finalize.json.conflict_files` 에 있다. 사용자가 원본 쪽을 정리하거나 worktree 쪽을 고친 뒤(worktree 를 고쳤으면 러너 재실행으로 재승인·verify) 같은 명령으로 재시도한다.
  - `APPLIED_CLEANUP_INCOMPLETE`(exit 2): 원본 반영과 검증은 끝났는데 worktree 제거나 브랜치 삭제가 실패했다. 반영은 되돌리지 않는다. 사유(`finalize.json.cleanup.error`)를 사용자에게 보고하고, 해소 뒤 같은 명령을 다시 실행하면 정리만 재시도한다(delta 재적용 없음).
  - 재실행 안전: 같은 lifecycle 의 `FINALIZED` 기록이 있으면 `already finalized` 로 끝나고(worktree 재생성·delta 재적용 없음), finalize 이후 원본이 바뀌었으면 `FINALIZE_STALE` 로 알린다. `bootstrap_tree` 가 없는 오래된 worktree(version 1 의 `new-from-branch`)는 기준선을 추측하지 않고 거부한다 — 그 결과는 사람이 옮긴다.
- **거부·보류** → worktree·피처 브랜치·원본 모두 그대로 두고 종료한다. 사용자에게 worktree 경로와 브랜치만 다시 알려 준다.

## 커밋·finalize 강제 규칙 (어길 수 없음)

- 워커·리뷰어·수정자는 커밋·푸시 금지. 커밋은 사용자가 요청했을 때만 — **finalize 와 commit 은 별개다.** 두 상태를 구분한다: ① worktree 가 아직 있는 `DONE` — 오케스트레이터가 그 worktree 에서 `verify_approved_fingerprint`(config.sh)로 승인 지문을 재확인한 뒤 `touch .claude/ALLOW_COMMIT`(1회용 플래그) 후 `fixer` 세션에 별도 호출로 위임.
  ② `FINALIZED`(worktree 는 없고 결과가 원본 working tree 에 있음) — 승인 지문은 worktree 와 함께 사라졌으므로 대신 원본에서 `feature_finalized_source_current <id>`(feature-worktree.sh; archive `finalize.json.source_after_tree` 와 지금 원본 tree 대조)가 성공해야만 커밋을 허용한다.
  finalize 이후 사용자가 원본을 고쳤으면(`FINALIZE_STALE`) 승인된 상태 그대로가 아니므로 그 변경을 사용자에게 확인시킨 뒤 결정한다. 어느 경우든 커밋은 원본 working tree 에서, 사용자 지시 뒤에만.
  ```bash
  bash -c 'source <skill_dir>/config.sh; source <skill_dir>/scripts/feature-worktree.sh; feature_finalized_source_current <id>'
  ```
- **finalize 는 사용자 승인 없이는 실행하지 않는다.** `DONE` 뒤 오케스트레이터가 반드시 묻고, 승인 답이 있을 때만 `--feature <id> --finalize` 를 실행한다. 러너·훅·다른 에이전트가 자동으로 부르지 않는다.
- **finalize 의 불변식.** 3-way(B/O/F) 충돌은 자동 해결하지 않는다(모델 위임 금지, `FINALIZE_CONFLICT` 로 반환). 원본 index 는 읽지도 쓰지도 않는다(임시 index 만). 원본에 commit·stash·checkout·reset 을 하지 않는다. archive 가 만들어지기 전에는 어떤 파괴적 정리도 하지 않고, finalize 가 실패하면 worktree·브랜치를 삭제하지 않는다. 적용 결과가 기대 merge tree 와 다르면 실패로 보고만 하고 자동 원복하지 않는다(사용자 변경을 추측해 지우지 않는다 — archive 의 patch/tree 로 사람이 복구).
- 마지막 APPROVE 이후 코드가 조금이라도 바뀌면 재리뷰 없이 종료 금지 — 러너의 verify 단계가 지문으로 강제한다.
