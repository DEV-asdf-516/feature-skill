#!/usr/bin/env node
// =============================================================
// 테스트용 가짜 codex — `codex app-server` 의 stdio JSONL 프로토콜을 독립 프로세스로 흉내 낸다(모델 호출 없음).
// 파일 경로: tests/fake-codex-app-server.mjs
// 스모크가 CODEX_BIN 래퍼로 이 파일을 실행한다. 실제 서버의 프레이밍(응답에 jsonrpc 필드 없음, 알림에 emittedAtMs)을 따른다.
//
// 지원하는 argv:
//   --version                                   버전 한 줄
//   exec ...                                    FAKE_LOG 에 "EXEC ..." 를 남기고 exit 99 (app_server 모드에서 codex exec 가 불렸는지 검사하는 용도)
//   app-server --help
//   app-server generate-json-schema --out DIR   런타임 사전 검사가 읽는 최소 스키마 묶음 (FAKE_SCHEMA_DROP 으로 항목을 뺀다)
//   app-server ... --print-startup-config       FAKE_STRICT_BASE_FAIL=1 이면 항상 실패, FAKE_AGENTS_KEY_UNSUPPORTED=1 이면 agents.enabled 가 있을 때 실패
//   app-server [-c k=v ...] --listen stdio://   서버 본체
//
// 환경 변수:
//   FAKE_LOG      호출 로그(한 줄 하나): "spawn <argv>", "rpc <method> <요약>", "approval-response <json>"
//   FAKE_STATE    상태 디렉터리: threads.json(thread·turn·누적 사용량), reply-<n>.txt / reply-default.txt(n 번째 turn 의 최종 메시지)
//                 edit-<n>.sh(n 번째 turn 에서만 도는 편집) · scenario-<n>.txt(n 번째 turn 에만 거는 시나리오)
//   FAKE_SCENARIO 쉼표로 구분한 시나리오 이름(아래 has() 참조)
//   FAKE_USAGE_SCALE  이 프로세스의 turn 이 내는 사용량 토큰 수에 곱하는 정수(기본 1) — turn 마다 다른 크기의 사용량을 만들 때 쓴다
//   FAKE_USER_MULTI_AGENT_V2=1  사용자 설정이 features.multi_agent_v2 를 켠 상태(프로세스 인자 -c 로 덮어쓰지 않으면 켜져 있다)
//   FAKE_HOOK_SOURCE  hooks/list 가 프로젝트 훅의 sourcePath·key 로 돌려줄 hooks.json 경로(기본: 요청 cwd 의 .codex/hooks.json).
//                 linked worktree 에서 실제 서버가 원본 저장소의 hooks.json 을 돌려주는 동작을 흉내 낼 때 쓴다
//   FAKE_APP_EDIT_CMD turn 실행 중 sh -c 로 돌리는 명령(편집 역할 흉내 — 가짜 claude 의 FAKE_EDIT_CMD 와 이름을 나눈다)
// =============================================================
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import readline from 'node:readline';

const argv = process.argv.slice(2);
const LOG = process.env.FAKE_LOG || '/dev/null';
const STATE = process.env.FAKE_STATE || '.';
const scenario = new Set((process.env.FAKE_SCENARIO || '').split(',').map((s) => s.trim()).filter(Boolean));
const has = (s) => scenario.has(s);
const log = (line) => fs.appendFileSync(LOG, `${line}\n`);

const REQUESTS = ['initialize', 'thread/start', 'thread/resume', 'turn/start', 'turn/interrupt', 'thread/read', 'thread/turns/list', 'thread/items/list', 'config/read', 'experimentalFeature/list', 'hooks/list'];
const NOTIFICATIONS = ['thread/started', 'turn/started', 'turn/completed', 'item/started', 'item/completed', 'item/agentMessage/delta', 'thread/tokenUsage/updated', 'model/rerouted', 'error', 'configWarning', 'thread/compacted'];
const FIELDS = {
  'v2/TurnStartParams.json': ['threadId', 'input', 'outputSchema', 'effort', 'model', 'clientUserMessageId', 'cwd', 'approvalPolicy'],
  'v2/ThreadStartParams.json': ['ephemeral', 'sandbox', 'approvalPolicy', 'cwd', 'model'],
  'v2/ThreadResumeParams.json': ['threadId', 'excludeTurns', 'sandbox', 'approvalPolicy', 'cwd', 'model'],
};

if (argv[0] === '--version') { console.log('codex-cli 9.9.9-fake'); process.exit(0); }
if (argv[0] === 'exec') { log(`EXEC ${argv.join(' ')}`); console.error('fake codex: exec must not run in app_server mode'); process.exit(99); }
if (argv[0] !== 'app-server') { console.error(`fake codex: unexpected argv ${argv.join(' ')}`); process.exit(9); }
if (argv.includes('--help')) { console.log('fake codex app-server'); process.exit(0); }
if (argv[1] === 'generate-json-schema') {
  const out = argv[argv.indexOf('--out') + 1];
  const drop = new Set((process.env.FAKE_SCHEMA_DROP || '').split(',').filter(Boolean));
  if (drop.has('all')) { console.error('schema generation unsupported'); process.exit(1); }
  fs.mkdirSync(path.join(out, 'v2'), { recursive: true });
  const methods = (list) => ({ oneOf: list.filter((m) => !drop.has(m)).map((m) => ({ properties: { method: { enum: [m] } } })) });
  fs.writeFileSync(path.join(out, 'ClientRequest.json'), JSON.stringify(methods(REQUESTS)));
  fs.writeFileSync(path.join(out, 'ServerNotification.json'), JSON.stringify(methods(NOTIFICATIONS)));
  for (const [file, props] of Object.entries(FIELDS)) {
    fs.writeFileSync(path.join(out, file), JSON.stringify({ properties: Object.fromEntries(props.filter((p) => !drop.has(p)).map((p) => [p, {}])) }));
  }
  process.exit(0);
}
if (argv.includes('--print-startup-config')) {
  if (process.env.FAKE_STRICT_BASE_FAIL === '1') process.exit(1);
  if (process.env.FAKE_AGENTS_KEY_UNSUPPORTED === '1' && argv.some((a) => a.startsWith('agents.enabled'))) process.exit(1);
  console.log('{"appServerVersion":"9.9.9-fake"}'); process.exit(0);
}

// ---------------- 서버 본체 ----------------
log(`spawn ${argv.join(' ')}`);
const conf = {};
for (let i = 0; i < argv.length; i += 1) if (argv[i] === '-c') { const [k, ...v] = argv[i + 1].split('='); conf[k] = v.join('=').replace(/^"|"$/g, ''); }
const stateFile = path.join(STATE, 'threads.json');
const load = () => { try { return JSON.parse(fs.readFileSync(stateFile, 'utf8')); } catch { return { seq: 0, turnSeq: 0, threads: {} }; } };
const save = (s) => fs.writeFileSync(stateFile, JSON.stringify(s));
const send = (obj) => process.stdout.write(`${JSON.stringify(obj)}\n`);
const notify = (method, params) => send({ method, params, emittedAtMs: Date.now() });
const ZERO = { inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0 };
const add = (a, b) => Object.fromEntries(Object.keys(ZERO).map((k) => [k, a[k] + b[k]]));
const SANDBOX = { 'read-only': { type: 'readOnly', networkAccess: false }, 'workspace-write': { type: 'workspaceWrite', writableRoots: [], networkAccess: false } };

// 유효 설정: 사용자 설정(기본 multi_agent=true, multi_agent_v2=FAKE_USER_MULTI_AGENT_V2) 위에 프로세스 인자(-c)가 덮인다.
// policy_override_ignored: 서버가 multi_agent_v2 덮어쓰기를 무시한다 / policy_agents_null: agents.enabled 덮어쓰기가 반영되지 않는다
const tomlBool = (k, dflt) => (conf[k] === undefined ? dflt : conf[k] === 'true');
const effective = () => ({
  agentsEnabled: has('policy_agents_null') || conf['agents.enabled'] === undefined ? null : conf['agents.enabled'] === 'true',
  multi_agent: tomlBool('features.multi_agent', true),
  multi_agent_v2: has('policy_override_ignored') ? true : tomlBool('features.multi_agent_v2', process.env.FAKE_USER_MULTI_AGENT_V2 === '1'),
});
if (has('exit_before_init')) process.exit(3);
if (has('garbage_before_init')) process.stdout.write('this is not json\n');

// 직전 turn 의 마지막 사용량 이벤트 재전송(그 turn 의 id 그대로). 직전 turn 이 사용량을 내지 않았으면 보낼 것이 없다.
function replayLastUsage(threadId, t) {
  if (!t?.lastUsage || !t.lastTurnId) return;
  notify('thread/tokenUsage/updated', { threadId, turnId: t.lastTurnId, tokenUsage: { total: t.total, last: t.lastUsage, modelContextWindow: 400000 } });
}
let replayOnTurnStart = 0;   // 이 프로세스가 thread 를 재개했으면 다음 turn/start 응답 앞에 보낼 재전송 횟수
let pendingApproval = null;   // {threadId, turnId, finish}
const threadView = (id, t) => ({ id, ephemeral: has('ephemeral_true'), cliVersion: '9.9.9-fake', cwd: t.cwd, createdAt: 0, updatedAt: 0, modelProvider: 'openai', preview: '', projectId: 'p', sessionId: id, source: 'appServer', status: { type: 'idle' }, turns: [] });
const threadResponse = (id, t, p) => ({ thread: threadView(id, t), model: has('settings_model') ? 'some-other-model' : p.model, modelProvider: 'openai',
  approvalPolicy: has('settings_approval') ? 'on-request' : p.approvalPolicy, approvalsReviewer: 'user', cwd: p.cwd,
  sandbox: has('settings_sandbox') ? { type: 'dangerFullAccess' } : SANDBOX[p.sandbox], reasoningEffort: conf.model_reasoning_effort ?? null });

function runTurn(id, p) {
  const s = load(); const t = s.threads[p.threadId];
  s.turnSeq += 1; const n = s.turnSeq; const turnId = `turn-${n}`;
  // n 번째 turn 에만 거는 시나리오(여러 역할이 한 실행에 섞인 루프 스모크용): scenario-<n>.txt 에 쉼표로 구분한 이름
  const turnScenario = path.join(STATE, `scenario-${n}.txt`);
  if (fs.existsSync(turnScenario)) for (const x of fs.readFileSync(turnScenario, 'utf8').split(',').map((v) => v.trim()).filter(Boolean)) scenario.add(x);
  let replyFile = path.join(STATE, `reply-${n}.txt`); if (!fs.existsSync(replyFile)) replyFile = path.join(STATE, 'reply-default.txt');
  const reply = fs.existsSync(replyFile) ? fs.readFileSync(replyFile, 'utf8') : '{"ok":true}';
  const text = p.input.map((i) => i.text || '').join('');
  log(`rpc turn/start thread=${p.threadId} turn=${turnId} model=${p.model} effort=${p.effort} schema=${p.outputSchema ? 'yes' : 'no'} approval=${p.approvalPolicy} clientId=${p.clientUserMessageId} cwd=${p.cwd} sandboxPolicy=${p.sandboxPolicy ? 'yes' : 'no'}`);
  const status = has('turn_failed') || has('failed_with_message') ? 'failed' : has('turn_interrupted') ? 'interrupted' : 'completed';
  const userItem = { type: 'userMessage', id: `u-${n}`, clientId: has('no_client_id') ? null : (p.clientUserMessageId ?? null), content: [{ type: 'text', text }] };
  const agentItem = { type: 'agentMessage', id: `m-${n}`, text: reply, phase: has('no_final_phase') ? 'commentary' : 'final_answer' };
  const record = (st) => { const cur = load(); cur.turnSeq = Math.max(cur.turnSeq, n); const th = cur.threads[p.threadId];
    th.turns.push({ id: turnId, status: st, items: has('delta_only') || st !== 'completed' ? [userItem] : [userItem, agentItem] }); save(cur); };
  save(s);
  if (process.env.FAKE_APP_EDIT_CMD) execSync(process.env.FAKE_APP_EDIT_CMD, { stdio: 'ignore', shell: '/bin/sh' });
  const editFile = path.join(STATE, `edit-${n}.sh`);   // n 번째 turn 에서만 도는 편집(여러 역할이 한 실행에 섞인 종단 스모크용)
  if (fs.existsSync(editFile)) execSync(`sh "${editFile}"`, { stdio: 'ignore', shell: '/bin/sh' });
  // 응답 전에 죽는다. 기본은 'turn 은 실제로 실행·완료됐다'(thread 기록에 남음), crash_unrecorded 면 thread 기록에도 없다.
  if (has('crash_before_turn_response')) { if (!has('crash_unrecorded')) record('completed'); process.exit(7); }
  const turn = (st, extra = {}) => ({ id: turnId, status: st, items: [], itemsView: 'notLoaded', ...extra });
  const respond = () => send({ id, result: { turn: turn('inProgress') } });
  const events = () => {
    notify('turn/started', { threadId: p.threadId, turn: turn('inProgress') });
    if (has('crash_after_turn_started')) { record('completed'); process.exit(7); }
    if (has('resume_replay_late')) replayLastUsage(p.threadId, load().threads[p.threadId]);   // 재전송이 turn 시작 뒤에 끼어드는 경우
    if (has('late_completed')) notify('turn/completed', { threadId: p.threadId, turn: { id: 'turn-stale', status: 'completed', items: [] } });
    if (has('foreign_events')) {
      notify('item/completed', { threadId: 'thr-other', turnId: 'turn-x', completedAtMs: 1, item: { type: 'agentMessage', id: 'mx', text: '{"decoy":"other-thread"}', phase: 'final_answer' } });
      notify('item/completed', { threadId: p.threadId, turnId: 'turn-other', completedAtMs: 1, item: { type: 'agentMessage', id: 'my', text: '{"decoy":"other-turn"}', phase: 'final_answer' } });
      notify('turn/completed', { threadId: 'thr-other', turn: { id: 'turn-x', status: 'completed', items: [] } });
      notify('thread/tokenUsage/updated', { threadId: p.threadId, turnId: 'turn-other', tokenUsage: { total: { ...ZERO, inputTokens: 999999, totalTokens: 999999 }, last: { ...ZERO, inputTokens: 999999, totalTokens: 999999 } } });
    }
    // 하위 Agent 활동(금지 확인을 지나고도 관측되는 경우의 사후 탐지용): 부모 turn 의 item 또는 자식 thread 의 시작
    if (has('subagent_item')) notify('item/started', { threadId: p.threadId, turnId, startedAtMs: 1, item: { type: 'collabAgentToolCall', id: 'c-1', tool: 'spawnAgent', status: 'inProgress' } });
    if (has('subagent_thread')) notify('thread/started', { thread: threadView('thr-child', load().threads[p.threadId]) });
    if (has('rerouted')) notify('model/rerouted', { threadId: p.threadId, turnId, fromModel: p.model, toModel: 'gpt-safe-fallback', reason: 'highRiskCyberActivity' });
    notify('item/agentMessage/delta', { threadId: p.threadId, turnId, itemId: `m-${n}`, delta: reply.slice(0, 5) });
    if (has('garbage_mid_turn')) process.stdout.write('{"method":"item/completed","params":{broken\n');
    if (has('compaction')) notify('thread/compacted', { threadId: p.threadId, turnId });
    // 사용량: 이 turn 안에서 모델 요청 2번(600 + 400 입력). total 은 thread 누적이다.
    if (!has('no_usage')) {
      // usage_reset: 누적값을 프로세스마다 0 부터 다시 센다(실제 서버가 그렇게 동작할 경우 — 재개 호출의 차이는 틀린 값이 된다)
      const cur = load(); const th = cur.threads[p.threadId]; let total = has('usage_reset') ? { ...ZERO } : th.total;
      const scale = Number(process.env.FAKE_USAGE_SCALE || 1); let lastSeen = null;
      for (const base of [{ ...ZERO, inputTokens: 600, cachedInputTokens: 100, outputTokens: 20, reasoningOutputTokens: 5, totalTokens: 620 },
        { ...ZERO, inputTokens: 400, cachedInputTokens: 100, outputTokens: 30, reasoningOutputTokens: 5, totalTokens: 430 }]) {
        const last = Object.fromEntries(Object.entries(base).map(([k, v]) => [k, v * scale])); lastSeen = last;
        total = add(total, last);
        let tu = { total: has('usage_bad') ? { inputTokens: total.inputTokens } : total, last, modelContextWindow: 400000 };
        // 마지막 이벤트만 불완전한 경우(첫 이벤트는 정상): usage_last_bad = 입력 필드만 남음 / usage_last_no_input = 입력 필드까지 없음
        if (base.inputTokens === 400 && has('usage_last_bad')) tu = { total: { inputTokens: total.inputTokens }, last: { inputTokens: last.inputTokens }, modelContextWindow: 400000 };
        if (base.inputTokens === 400 && has('usage_last_no_input')) tu = { total: { inputTokens: total.inputTokens }, last: { outputTokens: last.outputTokens } };
        notify('thread/tokenUsage/updated', { threadId: p.threadId, turnId, tokenUsage: tu });
        if (has('usage_dup')) notify('thread/tokenUsage/updated', { threadId: p.threadId, turnId, tokenUsage: tu });
      }
      th.total = total; th.lastUsage = lastSeen; th.lastTurnId = turnId; save(cur);
    }
    if (has('crash_before_completed')) { record('completed'); process.exit(7); }
    if (has('partial_line_exit')) { record('completed'); process.stdout.write('{"method":"turn/completed","params":{"threadId":"'); process.exit(0); }
    const finish = (st) => {
      if (!has('delta_only') && (st === 'completed' || has('failed_with_message'))) {
        const ev = { threadId: p.threadId, turnId, completedAtMs: Date.now(), item: agentItem };
        notify('item/completed', ev); if (has('dup_items')) notify('item/completed', ev);
      }
      record(st);
      if (has('hang_turn')) return;
      notify('turn/completed', { threadId: p.threadId, turn: turn(st, st === 'failed' ? { error: { message: 'fake model failure' } } : {}) });
    };
    if (has('approval')) {
      pendingApproval = { threadId: p.threadId, turnId, finish };
      send({ id: 9001, method: 'item/commandExecution/requestApproval', params: { threadId: p.threadId, turnId, itemId: 'cmd-1', startedAtMs: 1, command: 'curl example.invalid' } });
      return;
    }
    finish(status);
  };
  for (; replayOnTurnStart > 0; replayOnTurnStart -= 1) replayLastUsage(p.threadId, load().threads[p.threadId]);
  if (has('reorder')) { events(); respond(); } else { respond(); events(); }
}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line); const p = msg.params || {};
  if (msg.method === undefined) {   // 서버 요청에 대한 클라이언트 응답
    log(`approval-response ${JSON.stringify(msg.result ?? msg.error)}`);
    if (pendingApproval && msg.result?.decision && msg.result.decision.startsWith('accept')) { const a = pendingApproval; pendingApproval = null; a.finish('completed'); }
    return;
  }
  switch (msg.method) {
    case 'initialize':
      log(`rpc initialize client=${p.clientInfo?.name} optOut=${(p.capabilities?.optOutNotificationMethods || []).length}`);
      if (has('init_error')) { send({ id: msg.id, error: { code: -32000, message: 'fake init failure' } }); break; }
      if (has('init_hang')) break;
      send({ id: msg.id, result: { userAgent: 'fake', codexHome: '/nonexistent', platformFamily: 'unix', platformOs: 'macos' } });
      notify('configWarning', { summary: 'fake config warning', details: null });
      break;
    case 'initialized': log('rpc initialized'); break;
    case 'thread/start': {
      const s = load(); s.seq += 1; const id = `thr-${s.seq}`;
      s.threads[id] = { cwd: p.cwd, model: p.model, turns: [], total: { ...ZERO } }; save(s);
      log(`rpc thread/start thread=${id} model=${p.model} sandbox=${p.sandbox} approval=${p.approvalPolicy} ephemeral=${p.ephemeral} cwd=${p.cwd}`);
      notify('thread/started', { thread: threadView(id, s.threads[id]) });
      if (has('extra_thread_started')) notify('thread/started', { thread: threadView('thr-stranger', s.threads[id]) });
      send({ id: msg.id, result: threadResponse(id, s.threads[id], p) });
      break;
    }
    case 'thread/resume': {
      const s = load(); const t = s.threads[p.threadId];
      log(`rpc thread/resume thread=${p.threadId} model=${p.model} sandbox=${p.sandbox} approval=${p.approvalPolicy} excludeTurns=${p.excludeTurns} cwd=${p.cwd}`);
      if (!t) { send({ id: msg.id, error: { code: -32600, message: `thread not found: ${p.threadId}` } }); break; }
      const id = has('resume_wrong_thread') ? 'thr-999' : p.threadId;
      send({ id: msg.id, result: threadResponse(id, t, p) });
      // 실제 서버의 동작(codex-cli 0.169.1 관측): 재개 직후, turn/start 응답 전에 직전 turn 의 id 로 마지막 사용량 이벤트를 한 번 다시 보낸다.
      // 기본은 클라이언트가 재개 응답을 처리한 뒤(thread 확정) · turn id 를 알기 전에 도착하도록 turn/start 를 받은 직후 응답보다 먼저 보낸다(runTurn — 순서가 결정적이다).
      // no_resume_replay: 보내지 않는다 / resume_replay_dup: 두 번 / resume_replay_early: 재개 응답과 같은 묶음으로도 한 번 / resume_replay_late: turn 이 시작된 뒤에도 한 번
      if (!has('no_resume_replay')) replayOnTurnStart = has('resume_replay_dup') ? 2 : 1;
      if (has('resume_replay_early')) replayLastUsage(p.threadId, t);
      break;
    }
    case 'turn/start': runTurn(msg.id, p); break;
    case 'turn/interrupt':
      log(`rpc turn/interrupt thread=${p.threadId} turn=${p.turnId}`);
      send({ id: msg.id, result: {} });
      if (pendingApproval && pendingApproval.turnId === p.turnId) { const a = pendingApproval; pendingApproval = null; a.finish('interrupted'); }
      break;
    case 'config/read': {
      log(`rpc config/read cwd=${p.cwd}`);
      if (has('policy_config_error')) { send({ id: msg.id, error: { code: -32000, message: 'fake config/read failure' } }); break; }
      const e = effective();
      send({ id: msg.id, result: { config: { agents: { enabled: e.agentsEnabled, max_depth: 2 }, features: { multi_agent: e.multi_agent, multi_agent_v2: e.multi_agent_v2 } } } });
      break;
    }
    case 'experimentalFeature/list': {
      log(`rpc experimentalFeature/list thread=${p.threadId ?? '-'} cursor=${p.cursor ?? '-'}`);
      const e = effective();
      // 두 페이지로 나눠 준다(끝 페이지까지 읽는지 확인). policy_thread_v2_on: 설정은 꺼져 있는데 thread 기준 기능 상태가 켜져 있다 / policy_list_endless: 끝나지 않는 목록
      const v2 = { name: 'multi_agent_v2', stage: 'stable', enabled: e.multi_agent_v2 || (has('policy_thread_v2_on') && !!p.threadId), defaultEnabled: false };
      const v1 = { name: 'multi_agent', stage: 'deprecated', enabled: e.multi_agent, defaultEnabled: true };
      if (has('policy_list_endless')) { send({ id: msg.id, result: { data: [v1], nextCursor: 'more' } }); break; }
      if (!p.cursor) send({ id: msg.id, result: { data: [{ name: 'js_repl', stage: 'stable', enabled: false, defaultEnabled: false }, v1], nextCursor: 'page-2' } });
      else send({ id: msg.id, result: { data: [v2], nextCursor: null } });
      break;
    }
    case 'hooks/list': {
      // 실제 서버(codex-cli 0.169.1)의 모양: cwd 마다 항목 하나, 훅마다 enabled·trustStatus·source·sourcePath. threadId 와 cwds 는 함께 보낼 수 없다.
      // 기본은 건강한 상태다: 사용자 층의 무관한 훅(미신뢰)과 경고 하나 + 프로젝트의 preToolUse worker_guard.sh(enabled·trusted).
      // hook_missing 프로젝트 훅 없음(미신뢰 프로젝트) / hook_disabled / hook_untrusted / hook_modified / hook_managed / hook_trust_weird / hook_async
      // hook_wrong_event 다른 이벤트에만 등록 / hook_wrong_source 다른 hooks.json 에서 옴 / hook_wrong_cwd 다른 cwd 의 항목만 / hook_bad_shape data 없음
      // hook_matcher 일부 도구에만 걸리는 matcher 가 붙음 / hook_wrong_command 스크립트 이름은 들어 있지만 무력화된 명령(… || true)
      // hook_list_error 조회 실패 / hook_thread_untrusted cwd 기준은 건강한데 thread 기준은 미신뢰
      log(`rpc hooks/list thread=${p.threadId ?? '-'} cwds=${(p.cwds || []).join(',') || '-'}`);
      if (has('hook_list_error')) { send({ id: msg.id, error: { code: -32000, message: 'fake hooks/list failure' } }); break; }
      if (p.threadId && Array.isArray(p.cwds) && p.cwds.length) { send({ id: msg.id, error: { code: -32600, message: 'specify either threadId or cwds' } }); break; }
      if (has('hook_bad_shape')) { send({ id: msg.id, result: { data: null } }); break; }
      const cwds = p.threadId ? [load().threads[p.threadId]?.cwd ?? process.cwd()] : (p.cwds && p.cwds.length ? p.cwds : [process.cwd()]);
      const base = { matcher: null, timeoutSec: 10, statusMessage: null, additionalContextLimit: null, pluginId: null, environmentId: null, isManaged: false, handlerType: 'command', async: false };
      const data = cwds.map((cwd) => {
        const src = process.env.FAKE_HOOK_SOURCE || path.join(cwd, '.codex', 'hooks.json');
        const trust = has('hook_untrusted') || (has('hook_thread_untrusted') && p.threadId) ? 'untrusted' : has('hook_modified') ? 'modified' : has('hook_managed') ? 'managed' : has('hook_trust_weird') ? 'pending' : 'trusted';
        const guard = { ...base, key: `${src}:pre_tool_use:0:0`, eventName: has('hook_wrong_event') ? 'postToolUse' : 'preToolUse', command: has('hook_wrong_command') ? 'bash .codex/hooks/worker_guard.sh || true' : 'bash .codex/hooks/worker_guard.sh',
          matcher: has('hook_matcher') ? '^never_matches_any_tool$' : null,
          sourcePath: has('hook_wrong_source') ? '/elsewhere/.codex/hooks.json' : src, source: has('hook_wrong_source') ? 'user' : 'project', displayOrder: 1,
          enabled: !has('hook_disabled'), async: has('hook_async'), isManaged: has('hook_managed'), currentHash: 'sha256:fake', trustStatus: trust };
        const user = { ...base, key: '/home/fake/.codex/hooks.json:session_start:0:0', eventName: 'sessionStart', command: 'node user-hook.mjs', sourcePath: '/home/fake/.codex/hooks.json', source: 'user', displayOrder: 0, enabled: true, currentHash: 'sha256:user', trustStatus: 'untrusted' };
        return { cwd: has('hook_wrong_cwd') ? '/somewhere/else' : cwd, hooks: has('hook_missing') ? [user] : [user, guard], warnings: ['fake unrelated user-layer warning'], errors: [] };
      });
      send({ id: msg.id, result: { data } });
      break;
    }
    case 'thread/read': {
      const s = load(); log(`rpc thread/read thread=${p.threadId}`);
      if (!s.threads[p.threadId]) { send({ id: msg.id, error: { code: -32600, message: 'thread not found' } }); break; }
      send({ id: msg.id, result: { thread: threadView(p.threadId, s.threads[p.threadId]) } }); break;
    }
    case 'thread/turns/list': {
      const s = load(); log(`rpc thread/turns/list thread=${p.threadId}`);
      const turns = (s.threads[p.threadId]?.turns || []).map((t) => ({ id: t.id, status: t.status, items: [], itemsView: 'notLoaded' })).reverse();
      send({ id: msg.id, result: { data: turns, nextCursor: null } }); break;
    }
    case 'thread/items/list': {
      const s = load(); log(`rpc thread/items/list thread=${p.threadId} turn=${p.turnId}`);
      const t = (s.threads[p.threadId]?.turns || []).find((x) => x.id === p.turnId);
      send({ id: msg.id, result: { data: (t?.items || []).map((item) => ({ turnId: p.turnId, item })), nextCursor: null } }); break;
    }
    default:
      log(`rpc ${msg.method} (unsupported)`);
      if (msg.id !== undefined) send({ id: msg.id, error: { code: -32601, message: `method not found: ${msg.method}` } });
  }
});
rl.on('close', () => process.exit(has('exit_nonzero_after_complete') ? 1 : 0));
