#!/usr/bin/env node
// =============================================================
// feature-skill 내장 Codex App Server 런타임
// 파일 경로: .claude/skills/feature/scripts/codex-app-server.mjs
// 요구: Node.js 18 이상(내장 모듈만 사용 — npm 패키지 없음), 로컬 codex 바이너리(`codex app-server`, stdio JSONL).
//
// 사용(직접 부르지 않는다 — scripts/codex-app-server.sh 가 부른다):
//   node codex-app-server.mjs run <turn-record.json>         모델 호출 1회(turn 1개)를 실행하고 기록을 상태 전이로 갱신한다
//   node codex-app-server.mjs reconcile <turn-record.json>   조회 전용 — 저장된 thread 의 turn/item 을 읽어 증거가 있으면 기존 결과를 복구한다(turn/start 를 보내지 않는다)
//   node codex-app-server.mjs hooks <spec.json>               조회 전용 — 편집 역할의 필수 훅 게이트를 그 작업 루트에 대해 판정만 한다(thread·turn 을 만들지 않는다)
//
// 불변식:
//   - turn/start 바이트를 쓰기 전에 기록(state=SEND_UNCONFIRMED)을 디스크에 fsync 한다. 그 뒤의 전송 불명은 UNKNOWN 이고 재전송하지 않는다.
//   - 결과는 이 호출이 관측한 thread id / turn id 에 결속된 완료 agentMessage 만 쓴다. 델타·다른 turn·다른 thread 의 이벤트는 결과가 아니다.
//   - 서버가 보낸 승인·입력 요청은 수락하지 않는다(거절 응답 + 호출 불수용). 무응답으로 두지 않는다.
//   - 자식 프로세스 종료 코드만으로 turn 성패를 정하지 않는다. turn/completed.status 와 최종 메시지가 판정 근거다.
//   - 워커(disable_agents)는 하위 Agent 금지가 이 자식 프로세스에 실제로 적용된 것을 유효 설정으로 확인한 뒤에만 turn/start 를 보낸다(verifyAgentsPolicy).
//     확인하지 못하면 모델 0회로 멈춘다. turn 중 하위 Agent 활동이 관측되면(사후 탐지) turn 을 중단하고 결과를 쓰지 않는다.
//   - 편집 역할(role_kind=edit — 워커·수정자·디자이너)은 필수 훅(PreToolUse 의 worker_guard.sh)이 이 프로세스에서 등록·활성·신뢰 상태인 것을 hooks/list 로
//     확인한 뒤에만 turn/start 를 보낸다(verifyRequiredHook). thread 를 만들기 전에 한 번(cwd 기준), thread 를 연 뒤 그 thread 기준으로 한 번.
//     누락·비활성·미신뢰·조회 실패·사양 불일치는 모두 FAILED_BEFORE_SEND 다. 신뢰 설정을 고치거나 승인하지 않는다 — 판정만 한다.
//     훅 정의는 사양의 명령과 글자 그대로 같고 matcher 가 없어야 한다(일부 도구에만 걸리는 훅은 통과가 아니다). 가드 스크립트는 선언(계약 세대 줄)에 더해
//     파일 지문(sha256)을 사양의 검토된 지문 목록과 대조한다. 이 런타임은 가드 스크립트를 실행하지 않는다 — 훅의 신뢰가 확인되기 전에, sandbox 밖에서
//     작업 루트의 스크립트를 실행하면 그 파일이 변조돼 있을 때 조회 명령만으로 임의 코드가 사용자 권한으로 돈다. turn 전후로 가드·훅 정의 파일의 지문을 대조하고, 바뀌었으면 그 결과를 쓰지 않는다.
//   - 이 파일은 프로토콜 전송과 기록만 맡는다. 스키마·계약·범위 판정은 호출자(Shell 게이트)가 한다.
//
// run 종료 코드:  0 RESULT_READY / 10 turn/start 미전송(모델 0회) / 20 turn 은 끝났지만 쓸 결과 없음 / 30 전송·완료 불명(UNKNOWN) / 2 사용법·기록 오류
// =============================================================
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';

const RUNTIME_VERSION = '1';
const HOOK_GATE_VERSION = '3';                // Shell(codex-app-server.sh CODEX_APP_HOOK_GATE_VERSION)이 이 줄을 대조한다 — 게이트 없는 런타임과 섞인 설치를 호출 전에 가린다
const EXIT = { OK: 0, USAGE: 2, NOT_SENT: 10, TURN_FAILED: 20, UNKNOWN: 30 };
const MAX_LINE_BYTES = 64 * 1024 * 1024;   // 한 줄(JSONL 메시지 1개) 상한 — 넘으면 이벤트 파싱 오류로 본다
const MAX_TRACKED_TURNS = 16;              // turn/start 응답 전에 도착한 알림을 turn id 별로 잠시 모으는 상한
const MAX_NOTES = 8;
const SECRET_KEY = /(token|secret|api[_-]?key|authorization|password|credential)s?$/i;

const nowIso = () => new Date().toISOString();
const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
const clip = (s, n = 500) => { const t = String(s ?? ''); return t.length > n ? `${t.slice(0, n)}…(+${t.length - n})` : t; };
const diag = (m) => process.stderr.write(`[codex-app-server] ${m}\n`);

function writeAtomic(file, text, mode = 0o600) {
  const tmp = `${file}.tmp-${process.pid}`;
  const fd = fs.openSync(tmp, 'w', mode);
  try { fs.writeSync(fd, text); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(tmp, file);
}

class Journal {
  constructor(file) { this.file = file; this.rec = JSON.parse(fs.readFileSync(file, 'utf8')); }
  // 쓰기 전에 디스크의 기록이 여전히 이 호출의 것인지 본다 — 다른 실행이 같은 key 로 새 기록을 만들었으면 덮어쓰지 않는다(뒤늦게 깨어난 런타임이 남의 기록을 바꾸지 않게).
  save() {
    let onDisk = null;
    try { onDisk = JSON.parse(fs.readFileSync(this.file, 'utf8')).invocation_id; } catch { onDisk = null; }
    if (onDisk !== this.rec.invocation_id) { const e = new Error(`호출 기록의 소유가 바뀌었다(디스크 ${onDisk} / 이 호출 ${this.rec.invocation_id})`); e.code = 'JOURNAL_OWNERSHIP_LOST'; throw e; }
    writeAtomic(this.file, `${JSON.stringify(this.rec, null, 2)}\n`);
  }
  transition(state, patch = {}) {
    Object.assign(this.rec, patch);
    this.rec.state = state; this.rec.updated_at = nowIso();
    (this.rec.history ||= []).push({ state, at: this.rec.updated_at });
    this.save();
  }
  patch(p) { Object.assign(this.rec, p); this.rec.updated_at = nowIso(); this.save(); }
}

// 문자열 값만 가린다(토큰 수 같은 숫자 필드는 그대로). 로그에 인증 정보가 남지 않게 하는 최소 장치다.
function redact(value) {
  let changed = false;
  const walk = (v) => {
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === 'object') {
      const out = {};
      for (const [k, x] of Object.entries(v)) {
        if (typeof x === 'string' && x.length > 0 && SECRET_KEY.test(k)) { out[k] = '[REDACTED]'; changed = true; } else out[k] = walk(x);
      }
      return out;
    }
    return v;
  };
  const out = walk(value);
  return { out, changed };
}

class RpcFailure extends Error {
  constructor(kind, method, detail) { super(`${kind} ${method}: ${clip(typeof detail === 'string' ? detail : JSON.stringify(detail), 300)}`); this.kind = kind; this.method = method; this.detail = detail; }
}

class AppServer {
  constructor({ bin, args, cwd, eventsLog, sentLog, stderrLog }) {
    Object.assign(this, { bin, args, cwd });
    this.events = fs.createWriteStream(eventsLog, { flags: 'w', mode: 0o600 });
    this.sent = fs.createWriteStream(sentLog, { flags: 'w', mode: 0o600 });
    this.stderr = fs.createWriteStream(stderrLog, { flags: 'w', mode: 0o600 });
    this.seq = 0; this.pending = new Map(); this.partial = []; this.partialBytes = 0;
    this.stats = { lines: 0, parse_errors: 0, unmatched_responses: 0, by_method: {} };
    this.exited = null; this.stdinBroken = false;
    this.onNotification = () => {}; this.onServerRequest = () => {}; this.onParseError = () => {}; this.onExit = () => {};
  }
  start() {
    return new Promise((resolve, reject) => {
      let settled = false;
      this.child = spawn(this.bin, this.args, { cwd: this.cwd, stdio: ['pipe', 'pipe', 'pipe'], env: process.env });
      this.child.once('error', (e) => { if (!settled) { settled = true; reject(e); } });
      this.child.once('spawn', () => { if (!settled) { settled = true; resolve(); } });
      this.child.stdin.on('error', () => { this.stdinBroken = true; });
      this.child.stderr.pipe(this.stderr);
      this.child.stdout.on('data', (c) => this.#onData(c));
      this.child.stdout.on('end', () => { if (this.partialBytes > 0) { const b = Buffer.concat(this.partial); this.partial = []; this.partialBytes = 0; this.#onLine(b); } });
      // 서버가 띄운 손자 프로세스가 stdout 을 쥐고 있으면 'close' 가 오지 않는다 — 종료 3초 뒤에는 파이프를 닫아 판정이 무한히 밀리지 않게 한다.
      this.child.once('exit', () => { const t = setTimeout(() => { if (!this.exited) { this.child.stdout.destroy(); this.child.stderr.destroy(); } }, 3000); t.unref(); });
      // 'close' = 프로세스가 끝나고 stdout 도 다 읽었다. 'exit' 로 판정하면 아직 읽지 않은 마지막 줄(turn/completed 등)을 놓친다.
      this.child.once('close', (code, signal) => {
        this.exited = { exit_code: code, signal };
        for (const [, p] of this.pending) { clearTimeout(p.timer); p.reject(new RpcFailure('SERVER_EXITED', p.method, `exit ${code} signal ${signal}`)); }
        this.pending.clear();
        this.onExit(this.exited);
      });
    });
  }
  #onData(chunk) {
    let start = 0;
    for (;;) {
      const nl = chunk.indexOf(0x0a, start);
      if (nl === -1) break;
      const piece = chunk.subarray(start, nl);
      const line = this.partialBytes > 0 ? Buffer.concat([...this.partial, piece]) : piece;
      this.partial = []; this.partialBytes = 0;
      this.#onLine(line);
      start = nl + 1;
    }
    if (start < chunk.length) {
      const rest = chunk.subarray(start);
      this.partial.push(rest); this.partialBytes += rest.length;
      if (this.partialBytes > MAX_LINE_BYTES) { this.partial = []; this.partialBytes = 0; this.stats.parse_errors += 1; this.#log(this.events, '{"feature_skill_note":"line over size limit dropped"}'); this.onParseError('oversize'); }
    }
  }
  #log(stream, text) {
    if (!stream.write(`${text}\n`) && stream === this.events && this.child && !this.child.stdout.isPaused()) {
      this.child.stdout.pause(); stream.once('drain', () => this.child.stdout.resume());   // 디스크가 느리면 읽기를 멈춘다(메모리에 쌓지 않는다)
    }
  }
  #onLine(buf) {
    let text = buf.toString('utf8'); if (text.endsWith('\r')) text = text.slice(0, -1);
    if (text.trim() === '') return;
    this.stats.lines += 1;
    let msg;
    try { msg = JSON.parse(text); } catch { msg = undefined; }
    if (!msg || typeof msg !== 'object' || Array.isArray(msg)) { this.stats.parse_errors += 1; this.#log(this.events, text); this.onParseError('not-json'); return; }
    const r = redact(msg); this.#log(this.events, r.changed ? JSON.stringify(r.out) : text);
    if (typeof msg.method === 'string') {
      this.stats.by_method[msg.method] = (this.stats.by_method[msg.method] || 0) + 1;
      if (msg.id !== undefined && msg.id !== null) this.onServerRequest(msg); else this.onNotification(msg);
      return;
    }
    if (msg.id !== undefined && msg.id !== null) {
      const p = this.pending.get(msg.id);
      if (!p) { this.stats.unmatched_responses += 1; return; }   // 보낸 적 없는 id 의 응답은 어떤 요청의 결과로도 쓰지 않는다
      this.pending.delete(msg.id); clearTimeout(p.timer);
      if (msg.error !== undefined && msg.error !== null) p.reject(new RpcFailure('RPC_ERROR', p.method, msg.error)); else p.resolve(msg.result);
      return;
    }
    this.stats.parse_errors += 1; this.onParseError('not-jsonrpc');
  }
  write(obj, logObj) {
    if (this.exited || this.stdinBroken) throw new RpcFailure('SERVER_EXITED', obj.method || 'response', 'stdin closed');
    this.sent.write(`${JSON.stringify({ at: nowIso(), ...(logObj || obj) })}\n`);
    this.child.stdin.write(`${JSON.stringify(obj)}\n`);
  }
  request(method, params, timeoutMs, logParams) {
    const id = ++this.seq;
    return new Promise((resolve, reject) => {
      const timer = timeoutMs > 0 ? setTimeout(() => { this.pending.delete(id); reject(new RpcFailure('RPC_TIMEOUT', method, `${timeoutMs}ms`)); }, timeoutMs) : null;
      this.pending.set(id, { resolve, reject, timer, method });
      try { this.write({ id, method, params }, { id, method, params: logParams ?? params }); } catch (e) { this.pending.delete(id); clearTimeout(timer); reject(e); }
    });
  }
  notify(method, params) { this.write(params === undefined ? { method } : { method, params }); }
  respond(id, body) { try { this.write({ id, ...body }); } catch { /* 서버가 이미 죽었으면 응답할 곳이 없다 */ } }
  async shutdown(graceMs) {
    const info = { exit_code: null, signal: null, forced: null };
    const waitExit = (ms) => new Promise((res) => { if (this.exited) return res(true); const t = setTimeout(() => res(false), ms); this.child.once('close', () => { clearTimeout(t); res(true); }); });
    if (this.child && !this.exited) {
      try { this.child.stdin.end(); } catch { /* 이미 닫힘 */ }
      if (!(await waitExit(graceMs))) { info.forced = 'SIGTERM'; this.child.kill('SIGTERM'); if (!(await waitExit(2000))) { info.forced = 'SIGKILL'; this.child.kill('SIGKILL'); await waitExit(2000); } }
    }
    if (this.exited) Object.assign(info, this.exited);
    await Promise.all([this.events, this.sent, this.stderr].map((s) => new Promise((res) => s.end(res))));
    return info;
  }
  kill() { try { if (this.child && !this.exited) this.child.kill('SIGKILL'); } catch { /* 없음 */ } }
}

// approvalPolicy=never 에서 서버가 승인·입력을 요청하면 수락하지 않는다. 메서드별 거절 응답 형식은 생성 스키마의 Response 정의를 따른다.
function denyServerRequest(server, msg) {
  const deny = {
    'item/commandExecution/requestApproval': { result: { decision: 'decline' } },
    'item/fileChange/requestApproval': { result: { decision: 'decline' } },
    'item/permissions/requestApproval': { result: { permissions: {}, scope: 'turn' } },
    'item/tool/requestUserInput': { result: { answers: {} } },
    'mcpServer/elicitation/request': { result: { action: 'decline' } },
    'item/tool/call': { result: { success: false, contentItems: [] } },
    applyPatchApproval: { result: { decision: 'denied' } },
    execCommandApproval: { result: { decision: 'denied' } },
  }[msg.method] || { error: { code: -32601, message: 'feature-skill runtime does not handle this server request' } };
  server.respond(msg.id, deny);
  return { method: msg.method, at: nowIso(), answered: deny.result ? 'denied' : 'error' };
}

const USAGE_REQUIRED = ['inputTokens', 'cachedInputTokens', 'outputTokens', 'reasoningOutputTokens', 'totalTokens'];
const USAGE_FIELDS = [...USAGE_REQUIRED, 'cacheWriteInputTokens'];
function normBreakdown(b) {
  if (!b || typeof b !== 'object') return null;
  const out = {};
  for (const k of USAGE_REQUIRED) { if (!Number.isFinite(b[k]) || b[k] < 0) return null; out[k] = b[k]; }
  const w = b.cacheWriteInputTokens;
  if (w !== undefined && w !== null && (!Number.isFinite(w) || w < 0)) return null;
  out.cacheWriteInputTokens = w ?? 0;
  return out;
}
// 사용량은 thread 누적(total)의 차이로만 낸다: 새 thread 는 0 이 기준, 재개는 직전 호출 기록이 남긴 누적값이 기준이다.
// 기준이 없거나 누적값이 줄었거나 이벤트가 손상됐으면 추정하지 않고 unknown 으로 둔다(0 으로 적지 않는다).
// 컨텍스트 측정(context_last_turn · context_window)은 비용 판정과 따로다: '마지막으로 관측한' usage 이벤트(acc.observed)에서만 읽는다.
// 그 이벤트의 last.inputTokens 가 유효하면 비용이 partial 이어도 남기고, 유효하지 않으면 null 이다 — 앞선 이벤트의 값을 물려 쓰지 않는다.
function summarizeUsage(acc, rec, corrupt) {
  const out = { source: 'thread/tokenUsage/updated', updates: acc?.count ?? 0, duplicates: acc?.dups ?? 0, baseline_total: null, baseline_provenance: null,
    final_total: acc?.final?.total ?? null, delta: null, context_last_turn: acc?.observed?.context ?? null, context_window: acc?.observed?.window ?? null,
    status: 'complete', error: null };
  const bad = (status, error) => { out.status = status; out.error = error; return out; };
  if (!acc || acc.count === 0) return bad('unavailable', 'USAGE_EVENTS_MISSING');
  if (corrupt) return bad('partial', 'USAGE_EVENTS_CORRUPT');
  if (acc.invalid) return bad('partial', 'USAGE_FIELDS_INCOMPLETE');
  if (acc.nonMonotonic) return bad('partial', 'USAGE_NON_MONOTONIC');
  if (rec.mode === 'new') { out.baseline_total = Object.fromEntries(USAGE_FIELDS.map((k) => [k, 0])); out.baseline_provenance = 'new_thread'; }
  else if (rec.usage_baseline && rec.usage_baseline.thread_id === rec.thread_id && normBreakdown(rec.usage_baseline.total)) {
    out.baseline_total = normBreakdown(rec.usage_baseline.total); out.baseline_provenance = `previous_invocation_record:${rec.usage_baseline.invocation_id || '?'}`;
  } else return bad('partial', 'USAGE_BASELINE_UNAVAILABLE');
  // 재개: 이 turn 의 첫 이벤트가 '직전 누적 = 기준' 임을 스스로 증명해야 한다(total − last == 기준). 서버가 누적을 프로세스마다 다시 세거나
  // 그 사이 다른 호출이 thread 를 썼으면 차이가 양수여도 틀린 값이다 — 맞지 않으면 추정하지 않는다.
  if (rec.mode !== 'new' && !(acc.first && USAGE_FIELDS.every((k) => acc.first.total[k] - acc.first.last[k] === out.baseline_total[k]))) return bad('partial', 'USAGE_BASELINE_MISMATCH');
  const delta = {};
  for (const k of USAGE_FIELDS) { delta[k] = out.final_total[k] - out.baseline_total[k]; if (delta[k] < 0) return bad('partial', 'USAGE_BASELINE_MISMATCH'); }
  out.delta = delta;
  return out;
}

function newTurnAcc() { return { lastFinal: null, lastAny: null, messages: 0, ids: new Map(), conflict: false, usage: { count: 0, dups: 0, final: null, invalid: false, nonMonotonic: false }, completed: null, rerouted: [], errors: [] }; }
function pickFinal(acc) { return acc.lastFinal || (acc.lastAny && (acc.lastAny.phase === null || acc.lastAny.phase === undefined) ? acc.lastAny : null); }
function sameReal(a, b) { const r = (p) => { try { return fs.realpathSync(p); } catch { return p; } }; return r(a) === r(b); }
const SANDBOX_TYPE = { 'read-only': 'readOnly', 'workspace-write': 'workspaceWrite' };

function serverArgs(rec, readOnlyProbe = false) {
  const args = ['app-server', '-c', `sandbox_mode="${readOnlyProbe ? 'read-only' : rec.sandbox}"`, '-c', 'approval_policy="never"'];
  if (!readOnlyProbe) {
    args.push('-c', `model="${rec.model}"`, '-c', `model_reasoning_effort="${rec.effort}"`);
    // 워커 전용 — 이 자식 프로세스에만 적용된다(다른 역할은 다른 프로세스, 사용자 전역 설정 파일은 바꾸지 않는다). 목록은 Shell 이 기록에 적어 준다.
    if (rec.disable_agents) for (const o of rec.agents_policy_overrides || []) args.push('-c', o);
  }
  args.push('--listen', 'stdio://');
  return args;
}

async function initialize(server, rec, rpcMs) {
  await server.request('initialize', { clientInfo: { name: 'feature-skill', title: null, version: RUNTIME_VERSION },
    capabilities: { experimentalApi: false, optOutNotificationMethods: rec.opt_out_notifications || [] } }, rpcMs);
  server.notify('initialized');
}

// 워커의 하위 Agent 금지가 '이 프로세스에' 실제로 적용됐는지 모델 호출 없이 확인한다.
//   ① config/read(cwd=작업 루트 — 프로젝트 설정 층까지 합친 유효 설정): agents.enabled · features.multi_agent_v2 · features.multi_agent 가 정확히 false.
//      multi_agent_v2 가 켜져 있으면 agents.enabled=false 가 무시되고, multi_agent 는 V1 fallback 경로다. null·누락은 false 가 아니다.
//   ② experimentalFeature/list(끝 페이지까지, threadId 가 있으면 그 thread 기준): 같은 두 기능이 목록에 있으면 enabled 가 false.
// 조회 실패·형식 불일치·페이지를 끝까지 읽지 못함은 '확인하지 못함'이다 — 통과로 읽지 않는다. 반환: {ok, code, detail, observed}
const SUBAGENT_FEATURES = ['multi_agent_v2', 'multi_agent'];
const SUBAGENT_ITEM_TYPES = new Set(['collabAgentToolCall', 'subAgentActivity']);
async function verifyAgentsPolicy(server, rec, rpcMs, threadId) {
  const observed = { thread_id: threadId ?? null, config: null, features: null };
  const unverified = (detail) => ({ ok: false, code: 'CODEX_APP_SERVER_AGENTS_POLICY_UNVERIFIED', detail, observed });
  const notEnforced = (detail) => ({ ok: false, code: 'CODEX_APP_SERVER_AGENTS_POLICY_NOT_ENFORCED', detail, observed });
  let cfg;
  try { cfg = await server.request('config/read', { includeLayers: false, cwd: rec.project_root }, rpcMs); } catch (e) { return unverified(`config/read: ${e.message}`); }
  const c = cfg?.config;
  if (!c || typeof c !== 'object') return unverified('config/read 응답에 config 가 없다');
  observed.config = { 'agents.enabled': c.agents?.enabled ?? null, ...Object.fromEntries(SUBAGENT_FEATURES.map((f) => [`features.${f}`, c.features?.[f] ?? null])) };
  const bad = Object.entries(observed.config).filter(([, v]) => v !== false).map(([k, v]) => `${k}=${JSON.stringify(v)}`);
  if (bad.length) return notEnforced(`유효 설정이 false 가 아니다: ${bad.join(', ')}`);
  const seen = {}; let cursor = null, done = false;
  for (let page = 0; page < 50 && !done; page += 1) {
    let r;
    try { r = await server.request('experimentalFeature/list', { cursor, limit: 200, ...(threadId ? { threadId } : {}) }, rpcMs); } catch (e) { return unverified(`experimentalFeature/list: ${e.message}`); }
    if (!Array.isArray(r?.data)) return unverified('experimentalFeature/list 응답에 data 가 없다');
    for (const f of r.data) if (SUBAGENT_FEATURES.includes(f?.name)) seen[f.name] = f.enabled;
    cursor = r.nextCursor ?? null; done = cursor === null;
  }
  if (!done) return unverified('experimentalFeature/list 를 끝 페이지까지 읽지 못했다');
  observed.features = seen;
  const on = Object.entries(seen).filter(([, v]) => v !== false).map(([k, v]) => `${k}=${JSON.stringify(v)}`);
  if (on.length) return notEnforced(`기능 상태가 꺼져 있지 않다: ${on.join(', ')}`);
  return { ok: true, code: 'OK', detail: '', observed };
}

// 편집 역할의 필수 훅 게이트 — 작업 보호 훅(PreToolUse 의 worker_guard.sh)이 '이 프로세스에서' 실제로 돌 상태인지 모델 호출 없이 확인한다.
// 파일이 있다는 것, 경고 문자열이 없다는 것은 근거가 아니다. hooks/list 가 돌려준 항목으로만 판정한다:
//   작업 루트의 항목(cwd 일치) 안에 · eventName 이 사양의 이벤트 · command handler 가 그 스크립트를 부름 · source=project ·
//   sourcePath 가 사양이 허용한 hooks.json(작업 루트의 것, linked worktree 면 원본 저장소의 것 — codex 가 그렇게 읽는다) ·
//   command 가 사양의 명령과 글자 그대로 같음(부분 문자열 일치는 `… worker_guard.sh || true` 같은 무력화된 명령도 통과시킨다) ·
//   matcher 없음(codex 는 PreToolUse 의 matcher 로 훅을 걸 도구를 고른다 — matcher 가 있는 훅은 일부 도구 호출에만 돈다. 실제 서버는 matcher 없는 훅을 null 로 돌려준다) ·
//   enabled === true · async 아님 · trustStatus 가 trusted 또는 managed.
// enabled 만으로는 통과가 아니다: codex 는 검토되지 않은 훅을 enabled:true · trustStatus:"untrusted" 로 돌려주고 그 훅은 돌지 않는다.
// warnings 는 판정에 쓰지 않는다(사용자 층의 무관한 경고가 늘 있을 수 있다). 모르는 trustStatus 값은 통과가 아니다.
// 반환: {ok, code, reason, detail, observed}. reason(정적 조건 포함): spec_missing | list_unsupported | script_missing | script_outdated | script_unreviewed | ok | query_failed | bad_shape | missing | source_mismatch | command_mismatch | matcher_scoped | disabled | async | untrusted | modified | trust_unknown
const HOOK_TRUST_OK = new Set(['trusted', 'managed']);
function requiredHookSpecError(spec) {
  if (!spec || typeof spec !== 'object' || Array.isArray(spec)) return '기록에 필수 훅 사양(required_hook)이 없다';
  if (typeof spec.event !== 'string' || spec.event.length === 0) return 'required_hook.event 가 없다';
  if (typeof spec.script !== 'string' || spec.script.length === 0 || path.isAbsolute(spec.script) || spec.script.split('/').includes('..')) return 'required_hook.script 가 작업 루트 기준 상대 경로가 아니다';
  if (!Array.isArray(spec.source_paths) || spec.source_paths.length === 0 || spec.source_paths.some((p) => typeof p !== 'string' || !path.isAbsolute(p))) return 'required_hook.source_paths 가 절대 경로 목록이 아니다';
  if (typeof spec.script_contract !== 'string' || !/^[A-Z_]+=[0-9]+$/.test(spec.script_contract)) return 'required_hook.script_contract 가 없다';
  if (typeof spec.command !== 'string' || spec.command.trim().length === 0) return 'required_hook.command 가 없다';
  if (!Array.isArray(spec.reviewed_sha256) || spec.reviewed_sha256.length === 0 || spec.reviewed_sha256.some((h) => typeof h !== 'string' || !/^[0-9a-f]{64}$/.test(h))) return 'required_hook.reviewed_sha256 가 sha256 지문 목록이 아니다';
  return null;
}
// 가드 스크립트와 훅 정의 파일의 지문(turn 전후 대조용). 읽을 수 없는 파일은 null 이다(있다가 사라진 것도 변화로 본다).
function hookFileHashes(rec) {
  const files = [path.join(rec.project_root, rec.required_hook.script), ...rec.required_hook.source_paths];
  const out = {};
  for (const f of files) { try { out[f] = sha256(fs.readFileSync(f)); } catch { out[f] = null; } }
  return out;
}
async function verifyRequiredHook(server, rec, rpcMs, threadId) {
  const spec = rec.required_hook;
  const observed = { mode: threadId ? 'thread' : 'cwd', thread_id: threadId ?? null, entry_cwd: null, hooks_total: null, warnings: null, errors: [], candidates: [] };
  const res = (ok, code, reason, detail) => ({ ok, code, reason, detail, observed, checked_at: nowIso() });
  const unverified = (reason, detail) => res(false, 'CODEX_APP_SERVER_HOOK_GATE_UNVERIFIED', reason, detail);
  const inactive = (reason, detail) => res(false, 'CODEX_APP_SERVER_HOOK_GATE_NOT_ACTIVE', reason, detail);
  const name = path.basename(spec.script);
  const calls = new RegExp(`(^|[\\s/'"=])${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(['"\\s]|$)`);
  let r;
  // threadId 와 cwds 는 함께 보낼 수 없다(실제 서버가 -32600 으로 거부한다)
  try { r = await server.request('hooks/list', threadId ? { threadId } : { cwds: [rec.project_root] }, rpcMs); } catch (e) { return unverified('query_failed', `hooks/list: ${e.message}`); }
  if (!r || !Array.isArray(r.data)) return unverified('bad_shape', 'hooks/list 응답에 data 가 없다');
  const entries = r.data.filter((e) => e && typeof e.cwd === 'string' && sameReal(e.cwd, rec.project_root));
  if (entries.length !== 1) return unverified('bad_shape', `hooks/list 응답에 작업 루트(${rec.project_root})의 항목이 ${entries.length}개다(받은 cwd: ${r.data.map((e) => e?.cwd).join(', ') || '없음'})`);
  const entry = entries[0];
  if (!Array.isArray(entry.hooks)) return unverified('bad_shape', 'hooks/list 항목에 hooks 가 없다');
  observed.entry_cwd = entry.cwd; observed.hooks_total = entry.hooks.length;
  observed.warnings = Array.isArray(entry.warnings) ? entry.warnings.length : null;
  observed.errors = (Array.isArray(entry.errors) ? entry.errors : []).slice(0, 4).map((e) => ({ path: clip(e?.path, 200), message: clip(e?.message, 200) }));
  const named = entry.hooks.filter((h) => h && h.handlerType === 'command' && typeof h.command === 'string' && calls.test(h.command));
  observed.candidates = named.slice(0, 8).map((h) => ({ key: h.key ?? null, event: h.eventName ?? null, source: h.source ?? null, source_path: h.sourcePath ?? null,
    enabled: h.enabled ?? null, async: h.async ?? null, trust_status: h.trustStatus ?? null, is_managed: h.isManaged ?? null, matcher: h.matcher ?? null, command: clip(h.command, 200) }));
  const forEvent = named.filter((h) => h.eventName === spec.event);
  if (forEvent.length === 0) return inactive('missing', `작업 루트에 적용되는 ${spec.event} 훅 중 ${name} 을 부르는 command 훅이 없다(그 cwd 의 훅 ${entry.hooks.length}개${observed.errors.length ? `, 로드 오류 ${observed.errors.map((e) => `${e.path}: ${e.message}`).join(' / ')}` : ''}) — 프로젝트가 codex 에 신뢰되지 않았으면 프로젝트 훅은 목록에 나오지 않는다`);
  const fromProject = forEvent.filter((h) => h.source === 'project' && typeof h.sourcePath === 'string' && spec.source_paths.some((p) => sameReal(p, h.sourcePath)));
  const hasMatcher = (h) => h.matcher !== null && h.matcher !== undefined;
  if (fromProject.length === 0) return inactive('source_mismatch', `${name} 훅이 이 프로젝트의 hooks.json 에서 온 것이 아니다(받은 source/sourcePath: ${forEvent.map((h) => `${h.source}:${h.sourcePath}`).join(', ')} / 허용: ${spec.source_paths.join(', ')})`);
  const why = (h) => (h.command.trim() !== spec.command.trim() ? 'command_mismatch' : hasMatcher(h) ? 'matcher_scoped' : h.enabled !== true ? 'disabled' : h.async === true ? 'async'
    : HOOK_TRUST_OK.has(h.trustStatus) ? null : h.trustStatus === 'untrusted' ? 'untrusted' : h.trustStatus === 'modified' ? 'modified' : 'trust_unknown');
  if (fromProject.some((h) => why(h) === null)) return res(true, 'OK', 'ok', '');
  const h = fromProject[0]; const reason = why(h);
  const text = { command_mismatch: `훅 명령이 요구하는 명령(${spec.command})과 글자 그대로 같지 않다 — 받은 명령: ${clip(h.command, 200)}`,
    matcher_scoped: `훅에 matcher(${JSON.stringify(h.matcher)})가 있다 — 일부 도구 호출에만 걸리는 훅은 모든 도구 호출을 검사하지 못한다. matcher 없이 등록한다`,
    disabled: '훅이 꺼져 있다(enabled 가 true 가 아니다)', async: '훅이 async 다 — 도구 호출을 막지 못한다',
    untrusted: '훅 정의가 codex 에서 신뢰(검토)되지 않았다 — 프로젝트가 신뢰돼 있어도 검토되지 않은 훅은 돌지 않는다',
    modified: '훅 정의가 신뢰한 뒤에 바뀌었다 — 다시 검토하기 전에는 돌지 않는다', trust_unknown: '알 수 없는 신뢰 상태다' }[reason];
  return inactive(reason, `${name} ${spec.event} 훅(${h.key}): ${text} — enabled=${JSON.stringify(h.enabled)} trustStatus=${JSON.stringify(h.trustStatus)} async=${JSON.stringify(h.async)} matcher=${JSON.stringify(h.matcher ?? null)}`);
}
// 서버를 띄우기 전에 볼 수 있는 것: 사양이 온전한가, 설치된 codex 가 hooks/list 를 갖는가, 훅이 부를 스크립트가 작업 루트에 있는가.
// 스크립트가 있다는 것은 통과 조건이 아니라 필요 조건이다(훅이 등록·신뢰돼 있어도 부를 파일이 없거나 옛 세대면 보호가 없다).
function requiredHookStaticCheck(rec) {
  const fail = (code, reason, detail) => ({ ok: false, code, reason, detail, observed: null, checked_at: nowIso() });
  const specErr = requiredHookSpecError(rec.required_hook);
  if (specErr) return fail('CODEX_APP_SERVER_HOOK_GATE_UNVERIFIED', 'spec_missing', `${specErr} — 필수 훅 확인 없이 편집 역할을 띄우지 않는다`);
  if (rec.required_hook.list_supported !== true) return fail('CODEX_APP_SERVER_HOOK_GATE_UNVERIFIABLE', 'list_unsupported', '설치된 codex 의 app-server 에 hooks/list 가 없어 필수 훅의 등록·활성·신뢰 상태를 확인할 수 없다');
  const script = path.join(rec.project_root, rec.required_hook.script);
  let isFile = false; try { isFile = fs.statSync(script).isFile(); } catch { isFile = false; }
  if (!isFile) return fail('CODEX_APP_SERVER_HOOK_GATE_NOT_ACTIVE', 'script_missing', `훅이 부를 스크립트가 작업 루트에 없다: ${script}`);
  // 가드 계약 세대: 훅이 등록·신뢰돼 있어도 그 스크립트가 우회 가능한 옛 세대면 보호가 없다. 스크립트가 선언한 세대 줄을 대조한다(줄 전체 일치, 주석 줄은 세지 않는다).
  // 이 검사들은 파일을 읽기만 한다. 가드를 실행해 보지 않는다(위 불변식 — 신뢰가 확인되지 않은 스크립트를 sandbox 밖에서 돌리지 않는다).
  let raw = null; try { raw = fs.readFileSync(script); } catch { raw = null; }
  const body = raw ? raw.toString('utf8') : '';
  const declared = body.split('\n').map((l) => l.replace(/\s+#.*$/, '').trim()).filter((l) => l.startsWith(`${rec.required_hook.script_contract.split('=')[0]}=`));
  if (!declared.includes(rec.required_hook.script_contract)) return fail('CODEX_APP_SERVER_HOOK_GATE_NOT_ACTIVE', 'script_outdated',
    `훅 스크립트(${script})가 요구하는 가드 계약 세대(${rec.required_hook.script_contract})를 선언하지 않는다(선언: ${declared.join(', ') || '없음'}) — 우회 가능한 옛 가드로는 편집 역할을 실행하지 않는다`);
  // 계약 세대 줄은 선언일 뿐이다(줄만 있고 `exit 0` 인 스크립트도 선언은 한다). 본문 전체의 지문이 검토된 지문 — 배포본의 지문 또는 사용자가 본문을 검토하고
  // 등록한 지문 — 과 같을 때만 통과다. 가드의 판정 회귀는 tests/smoke-worker-guard.sh(무과금)가 본다.
  const digest = sha256(raw);
  if (!rec.required_hook.reviewed_sha256.includes(digest)) return fail('CODEX_APP_SERVER_HOOK_GATE_NOT_ACTIVE', 'script_unreviewed',
    `훅 스크립트(${script})의 지문(sha256 ${digest})이 검토된 지문 목록에 없다 — 배포본과 다르고 사용자가 등록하지도 않은 가드로는 편집 역할을 실행하지 않는다(이 검사는 스크립트를 실행하지 않는다)`);
  return null;
}

async function run(recFile) {
  const j = new Journal(recFile); const rec = j.rec;
  if (rec.state !== 'PREPARED') { diag(`기록 상태가 PREPARED 가 아님(${rec.state}) — 실행하지 않는다: ${recFile}`); return EXIT.USAGE; }
  const rpcMs = (rec.timeouts?.rpc_ms ?? 120000), turnMs = (rec.timeouts?.turn_ms ?? 0), graceMs = (rec.timeouts?.shutdown_ms ?? 5000);
  let sent = false, server = null, finished = false;
  const notes = []; const note = (s) => { if (notes.length < MAX_NOTES) notes.push(clip(s, 300)); };
  const serverRequests = [];
  const finish = async (state, code, detail, exit, patch = {}) => {
    if (finished) return exit; finished = true;
    let owned = true;
    try { j.transition(state, { outcome: { code, detail: clip(detail, 600) }, notes, server_requests: serverRequests, events: server ? server.stats : null, ...patch }); }
    catch (e) { owned = false; diag(`기록을 쓰지 못했다(${e.code || e.message}) — 결과를 넘기지 않는다`); }
    if (!owned) { if (server) await server.shutdown(graceMs); return sent ? EXIT.UNKNOWN : EXIT.NOT_SENT; }
    // 정상 완료한 turn 뒤에 서버 프로세스가 스스로 비정상 종료한 경우만 anomaly 로 남긴다(우리가 강제 종료한 것은 제외) — 결과 판정은 바꾸지 않는다.
    if (server) { const info = await server.shutdown(graceMs); try { j.patch({ server: { ...info, exit_anomaly: state === 'RESULT_READY' && !info.forced && (info.signal !== null || (info.exit_code !== null && info.exit_code !== 0)) } }); } catch (e) { diag(`서버 종료 정보 기록 실패: ${e.code || e.message}`); } }
    diag(`${rec.role}/${rec.key} ${rec.invocation_id}: ${state} ${code}${detail ? ` — ${clip(detail, 300)}` : ''}`);
    return exit;
  };
  const failEarly = (code, detail) => finish('FAILED_BEFORE_SEND', code, detail, EXIT.NOT_SENT);
  const onSignal = (sig) => { if (finished) return; const s = sent ? 'UNKNOWN' : 'FAILED_BEFORE_SEND'; finished = true;
    try { j.transition(s, { outcome: { code: 'CODEX_APP_SERVER_RUNNER_SIGNAL', detail: sig }, notes, server_requests: serverRequests }); } catch { /* 기록 실패는 다음 실행의 불명 판정이 덮는다 */ }
    if (server) server.kill(); process.exit(sent ? EXIT.UNKNOWN : EXIT.NOT_SENT); };
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => onSignal(sig));
  process.on('exit', () => { if (server) server.kill(); });

  try {
    j.patch({ runtime_pid: process.pid });   // 이 기록을 쥔 런타임 — Shell 게이트가 '준비 중인 다른 실행'을 가릴 때 본다
    // ---- 입력 고정 확인(모델 0회) ----
    let prompt, schema = null;
    try { prompt = fs.readFileSync(rec.prompt_file, 'utf8'); } catch (e) { return await failEarly('CODEX_APP_SERVER_PROMPT_UNREADABLE', e.message); }
    if (sha256(prompt) !== rec.prompt_sha256) return await failEarly('CODEX_APP_SERVER_PROMPT_CHANGED', '기록한 prompt 지문과 파일 내용이 다르다');
    if (rec.schema_file) {
      try { const raw = fs.readFileSync(rec.schema_file, 'utf8'); if (sha256(raw) !== rec.schema_sha256) return await failEarly('CODEX_APP_SERVER_SCHEMA_CHANGED', '기록한 schema 지문과 파일 내용이 다르다'); schema = JSON.parse(raw); }
      catch (e) { return await failEarly('CODEX_APP_SERVER_SCHEMA_UNREADABLE', e.message); }
      if (!schema || typeof schema !== 'object' || Array.isArray(schema)) return await failEarly('CODEX_APP_SERVER_SCHEMA_UNREADABLE', 'schema 가 JSON 객체가 아니다');
    }
    if (rec.disable_agents && !(Array.isArray(rec.agents_policy_overrides) && rec.agents_policy_overrides.length > 0)) return await failEarly('CODEX_APP_SERVER_AGENTS_POLICY_UNVERIFIED', '기록에 하위 Agent 금지 설정(agents_policy_overrides)이 없다 — 금지 없이 워커를 띄우지 않는다');
    // ---- 편집 역할: 필수 훅 게이트의 정적 조건(서버를 띄우기 전) ----
    const needsHook = rec.role_kind === 'edit';   // 기록의 선택 플래그가 아니라 역할 종류로 정한다 — 사양이 빠진 기록은 건너뛰지 않고 멈춘다
    let hookGate = null;
    if (needsHook) {
      hookGate = requiredHookStaticCheck(rec);
      if (hookGate) { j.patch({ hook_gate: hookGate }); return await failEarly(hookGate.code, hookGate.detail); }
    }
    // 가드·훅 정의 파일의 호출 전 지문 — turn 뒤에 다시 읽어 대조한다(사후 탐지. 예방은 sandbox 와 가드가 한다).
    const hookFilesBefore = needsHook ? hookFileHashes(rec) : null;
    // ---- 프로세스 ----
    server = new AppServer({ bin: rec.codex_bin, args: serverArgs(rec), cwd: rec.project_root, eventsLog: rec.events_log, sentLog: rec.sent_log, stderrLog: rec.stderr_log });
    try { await server.start(); } catch (e) { server = null; return await failEarly('CODEX_APP_SERVER_SPAWN_FAILED', `${rec.codex_bin}: ${e.message}`); }

    // ---- 이벤트 수집기 ----
    const turns = new Map(); let threadId = null, turnId = null, corrupt = false, otherThreadsBeforeSend = [], foreign = 0;
    // 하위 Agent 활동의 사후 탐지(워커 전용). 예방은 verifyAgentsPolicy 가 한다 — 이것은 그 확인을 지나고도 관측된 경우에 결과를 쓰지 않기 위한 장치다.
    const subagent = []; let subagentInterrupted = false;
    const subagentSeen = (what) => {
      if (!rec.disable_agents) return;
      if (subagent.length < 8) subagent.push({ what: clip(what, 200), at: nowIso() });
      if (sent && threadId && turnId && !subagentInterrupted) { subagentInterrupted = true; server.request('turn/interrupt', { threadId, turnId }, rpcMs).catch(() => {}); }
      wake();
    };
    let wake = () => {}; const waiter = () => new Promise((res) => { wake = res; });
    const accFor = (tid) => { let a = turns.get(tid); if (!a) { if (turns.size >= MAX_TRACKED_TURNS) return null; a = newTurnAcc(); turns.set(tid, a); } return a; };
    server.onParseError = () => { corrupt = true; wake(); };
    server.onExit = () => wake();
    server.onServerRequest = (msg) => {
      serverRequests.push(denyServerRequest(server, msg));
      if (sent && threadId && turnId) { server.request('turn/interrupt', { threadId, turnId }, rpcMs).catch(() => {}); }
      wake();
    };
    server.onNotification = (msg) => {
      const p = msg.params || {};
      if (msg.method === 'thread/started') { const id = p.thread?.id; if (id && id !== threadId) { if (!sent) otherThreadsBeforeSend.push(id); else subagentSeen(`thread/started ${id}`); } return; }
      // 하위 Agent item 은 어느 thread·turn 에 붙어 오든 본다(자식 thread 의 이벤트일 수 있다)
      if ((msg.method === 'item/started' || msg.method === 'item/completed') && SUBAGENT_ITEM_TYPES.has(p.item?.type)) subagentSeen(`${msg.method} ${p.item.type}`);
      if (msg.method === 'configWarning' || msg.method === 'warning' || msg.method === 'deprecationNotice') { note(`${msg.method}: ${p.summary || p.message || ''}`); return; }
      if (!p.threadId) return;
      if (threadId === null || p.threadId !== threadId) { foreign += 1; return; }   // 다른 thread 의 이벤트는 결과·사용량 어디에도 쓰지 않는다
      const tid = msg.method === 'turn/completed' || msg.method === 'turn/started' ? p.turn?.id : p.turnId;
      if (!tid) return;
      if (turnId !== null && tid !== turnId) { foreign += 1; return; }
      const acc = accFor(tid); if (!acc) { corrupt = true; return; }
      switch (msg.method) {
        case 'item/completed': {
          const it = p.item; if (!it || it.type !== 'agentMessage' || typeof it.text !== 'string') break;
          const h = sha256(it.text); const prev = acc.ids.get(it.id);
          if (prev !== undefined) { if (prev !== h) acc.conflict = true; break; }   // 같은 item 의 중복 완료 이벤트는 한 번만 센다
          if (acc.ids.size < 4096) acc.ids.set(it.id, h);
          acc.messages += 1; const m = { id: it.id, text: it.text, phase: it.phase ?? null };
          acc.lastAny = m; if (m.phase === 'final_answer') acc.lastFinal = m;
          break;
        }
        case 'thread/tokenUsage/updated': {
          const total = normBreakdown(p.tokenUsage?.total), last = normBreakdown(p.tokenUsage?.last); const u = acc.usage;
          // 컨텍스트 측정은 이 이벤트 하나로 판정한다(중복·불완전 이벤트 포함 — 매번 덮어써서 앞선 이벤트의 값이 남지 않게 한다)
          const ctx = p.tokenUsage?.last?.inputTokens, win = p.tokenUsage?.modelContextWindow;
          u.observed = { context: Number.isFinite(ctx) && ctx >= 0 ? ctx : null, window: Number.isFinite(win) && win > 0 ? win : null };
          if (!total || !last) { u.invalid = true; u.count += 1; break; }
          if (u.final && USAGE_FIELDS.every((k) => u.final.total[k] === total[k])) { u.dups += 1; break; }
          if (u.final && USAGE_FIELDS.some((k) => total[k] < u.final.total[k])) u.nonMonotonic = true;
          if (!u.first) u.first = { total, last };
          u.count += 1; u.final = { total, last, window: Number.isFinite(p.tokenUsage?.modelContextWindow) ? p.tokenUsage.modelContextWindow : null };
          break;
        }
        case 'turn/completed': if (!acc.completed) acc.completed = p.turn; wake(); break;
        case 'model/rerouted': acc.rerouted.push({ from: p.fromModel, to: p.toModel, reason: p.reason }); break;
        case 'error': if (acc.errors.length < 4) acc.errors.push({ message: clip(p.error?.message, 300), will_retry: p.willRetry === true }); break;
        default: break;
      }
    };

    // ---- handshake ----
    try { await initialize(server, rec, rpcMs); } catch (e) {
      const code = e.kind === 'RPC_TIMEOUT' ? 'CODEX_APP_SERVER_RPC_TIMEOUT' : e.kind === 'SERVER_EXITED' ? 'CODEX_APP_SERVER_EXITED' : 'CODEX_APP_SERVER_INIT_FAILED';
      return await failEarly(code, `initialize: ${e.message}`);
    }
    if (corrupt) return await failEarly('CODEX_APP_SERVER_EVENT_PARSE', 'handshake 중 JSON 으로 읽을 수 없는 출력');

    // ---- 워커: 하위 Agent 금지의 유효 적용 확인(모델 0회, thread 를 만들기 전) ----
    let agentsPolicy = null;
    if (rec.disable_agents) {
      agentsPolicy = await verifyAgentsPolicy(server, rec, rpcMs, null);
      j.patch({ agents_policy: agentsPolicy });
      if (!agentsPolicy.ok) return await failEarly(agentsPolicy.code, agentsPolicy.detail);
    }

    // ---- 편집 역할: 필수 훅 게이트(모델 0회, thread 를 만들기 전) ----
    // thread/start 보다 먼저다: 실제 서버는 thread/start 를 받으면 그 cwd 를 사용자 설정의 trusted project 로 스스로 등록한다(codex-cli 0.169.1 관측).
    // 훅이 확인되지 않은 루트에서 thread 를 열면 이 런타임이 신뢰를 대신 승인한 셈이 된다 — 그래서 실패하면 thread 도 만들지 않는다.
    if (needsHook) {
      hookGate = await verifyRequiredHook(server, rec, rpcMs, null);
      j.patch({ hook_gate: hookGate });
      if (!hookGate.ok) return await failEarly(hookGate.code, hookGate.detail);
      if (corrupt) return await failEarly('CODEX_APP_SERVER_EVENT_PARSE', '필수 훅 확인 중 JSON 으로 읽을 수 없는 출력');
    }

    // ---- thread (new | resume) ----
    const common = { model: rec.model, cwd: rec.project_root, approvalPolicy: 'never', sandbox: rec.sandbox };
    let th;
    try {
      th = rec.mode === 'resume'
        ? await server.request('thread/resume', { threadId: rec.thread_id, ...common, excludeTurns: true }, rpcMs)
        : await server.request('thread/start', { ...common, ephemeral: false }, rpcMs);
    } catch (e) {
      const code = e.kind === 'RPC_TIMEOUT' ? 'CODEX_APP_SERVER_RPC_TIMEOUT' : e.kind === 'SERVER_EXITED' ? 'CODEX_APP_SERVER_EXITED' : 'CODEX_APP_SERVER_THREAD_ERROR';
      return await failEarly(code, `${rec.mode === 'resume' ? 'thread/resume' : 'thread/start'}: ${e.message}`);
    }
    const tid = th?.thread?.id;
    if (typeof tid !== 'string' || tid.length === 0) return await failEarly('CODEX_APP_SERVER_THREAD_ERROR', '응답에 thread.id 가 없다');
    if (rec.mode === 'resume' && tid !== rec.thread_id) return await failEarly('CODEX_APP_SERVER_THREAD_MISMATCH', `요청 ${rec.thread_id} / 응답 ${tid}`);
    const echo = { model: th.model ?? null, model_provider: th.modelProvider ?? null, reasoning_effort: th.reasoningEffort ?? null, approval_policy: th.approvalPolicy ?? null,
      sandbox_type: th.sandbox?.type ?? null, cwd: th.cwd ?? null, ephemeral: th.thread?.ephemeral ?? null, cli_version: th.thread?.cliVersion ?? null };
    const mism = [];
    if (echo.model !== rec.model) mism.push(`model ${echo.model}≠${rec.model}`);
    if (echo.approval_policy !== 'never') mism.push(`approvalPolicy ${JSON.stringify(echo.approval_policy)}≠never`);
    if (echo.sandbox_type !== SANDBOX_TYPE[rec.sandbox]) mism.push(`sandbox ${echo.sandbox_type}≠${SANDBOX_TYPE[rec.sandbox]}`);
    if (echo.reasoning_effort !== null && echo.reasoning_effort !== rec.effort) mism.push(`effort ${echo.reasoning_effort}≠${rec.effort}`);
    if (typeof echo.cwd !== 'string' || !sameReal(echo.cwd, rec.project_root)) mism.push(`cwd ${echo.cwd}≠${rec.project_root}`);
    if (echo.ephemeral !== false) mism.push(`ephemeral ${echo.ephemeral}≠false`);
    j.patch({ thread_id: tid, settings_echo: echo });
    if (mism.length) return await failEarly('CODEX_APP_SERVER_SETTINGS_MISMATCH', mism.join(', '));
    threadId = tid;
    const strangers = otherThreadsBeforeSend.filter((x) => x !== tid);
    if (strangers.length) return await failEarly('CODEX_APP_SERVER_THREAD_NOT_UNIQUE', `이 호출의 thread(${tid}) 외에 thread/started ${strangers.join(',')}`);
    if (corrupt) return await failEarly('CODEX_APP_SERVER_EVENT_PARSE', 'thread 준비 중 JSON 으로 읽을 수 없는 출력');
    if (rec.disable_agents) {
      // 같은 확인을 이 thread 기준으로 한 번 더 한다(thread 가 다른 기능 상태로 열렸을 수 있다 — 재개한 thread 포함)
      agentsPolicy = await verifyAgentsPolicy(server, rec, rpcMs, tid);
      j.patch({ agents_policy: agentsPolicy });
      if (!agentsPolicy.ok) return await failEarly(agentsPolicy.code, `thread ${tid}: ${agentsPolicy.detail}`);
      if (corrupt) return await failEarly('CODEX_APP_SERVER_EVENT_PARSE', '하위 Agent 금지 확인 중 JSON 으로 읽을 수 없는 출력');
    }
    if (needsHook) {
      // 같은 확인을 이 thread 기준으로 한 번 더 한다(thread 가 실제로 쓰는 훅 목록 — 재개한 thread 포함). 이것이 turn/start 직전의 마지막 조회다.
      hookGate = await verifyRequiredHook(server, rec, rpcMs, tid);
      j.patch({ hook_gate: hookGate });
      if (!hookGate.ok) return await failEarly(hookGate.code, `thread ${tid}: ${hookGate.detail}`);
      if (corrupt) return await failEarly('CODEX_APP_SERVER_EVENT_PARSE', '필수 훅 확인 중 JSON 으로 읽을 수 없는 출력');
    }
    if (server.exited) return await failEarly('CODEX_APP_SERVER_EXITED', `thread 준비 뒤 서버 종료(exit ${server.exited.exit_code})`);
    j.transition('THREAD_READY');

    // ---- turn/start: 전송 의도를 먼저 디스크에 남긴다 ----
    const params = { threadId, input: [{ type: 'text', text: prompt, text_elements: [] }], cwd: rec.project_root, approvalPolicy: 'never',
      model: rec.model, effort: rec.effort, clientUserMessageId: rec.invocation_id };
    if (schema) params.outputSchema = schema;
    j.transition('SEND_UNCONFIRMED');
    sent = true;
    const logParams = { ...params, input: [{ type: 'text', text_sha256: rec.prompt_sha256, text_bytes: Buffer.byteLength(prompt) }], outputSchema: schema ? { sha256: rec.schema_sha256 } : undefined };
    let startRes = null, startErr = null;
    const startP = server.request('turn/start', params, rpcMs, logParams).then((r) => { startRes = r; }, (e) => { startErr = e; }).finally(() => wake());
    let turnTimer = null, timedOut = false, exitSeen = false;
    if (turnMs > 0) turnTimer = setTimeout(() => { timedOut = true; wake(); }, turnMs);

    const unknown = (code, detail, patch) => finish('UNKNOWN', code, detail, EXIT.UNKNOWN, patch);
    for (;;) {
      if (startErr) {
        clearTimeout(turnTimer);
        if (startErr.kind === 'RPC_ERROR') return await finish('TURN_FAILED', 'CODEX_APP_SERVER_TURN_START_ERROR', startErr.message, EXIT.TURN_FAILED);
        return await unknown(startErr.kind === 'RPC_TIMEOUT' ? 'CODEX_APP_SERVER_RPC_TIMEOUT' : 'CODEX_APP_SERVER_EXITED', `turn/start 응답 미확인: ${startErr.message}`);
      }
      if (startRes && turnId === null) {
        const id = startRes?.turn?.id;
        if (typeof id !== 'string' || id.length === 0) { clearTimeout(turnTimer); return await unknown('CODEX_APP_SERVER_TURN_ID_MISSING', 'turn/start 응답에 turn.id 가 없다'); }
        turnId = id;
        for (const k of [...turns.keys()]) if (k !== turnId) { turns.delete(k); foreign += 1; }
        j.transition('RUNNING', { turn_id: turnId });
        if (subagent.length && !subagentInterrupted) { subagentInterrupted = true; server.request('turn/interrupt', { threadId, turnId }, rpcMs).catch(() => {}); }
        const st = startRes.turn.status;
        if ((st === 'failed' || st === 'interrupted') && !turns.get(turnId)?.completed) accFor(turnId).completed = startRes.turn;
      }
      const acc = turnId ? turns.get(turnId) : null;
      if (acc?.completed) break;
      if (timedOut) { if (turnId) server.request('turn/interrupt', { threadId, turnId }, 3000).catch(() => {}); return await unknown('CODEX_APP_SERVER_TURN_TIMEOUT', `${turnMs}ms 안에 turn/completed 없음`); }
      if (server.exited) {
        if (!exitSeen) { exitSeen = true; await startP; continue; }   // 종료 직전에 도착한 응답·완료 이벤트를 한 번 더 반영한 뒤에 판정한다
        clearTimeout(turnTimer);
        return await unknown('CODEX_APP_SERVER_EXITED', `turn 완료 전 서버 종료(exit ${server.exited.exit_code}, signal ${server.exited.signal})`, { usage: summarizeUsage(turnId ? turns.get(turnId)?.usage : null, j.rec, true) });
      }
      await waiter();
    }
    clearTimeout(turnTimer);

    // ---- 판정: 이 호출의 turn 에 결속된 관측만 쓴다 ----
    const acc = turns.get(turnId); const turn = acc.completed; const status = turn?.status;
    const usage = summarizeUsage(acc.usage, j.rec, corrupt);
    const base = { turn_status: status ?? null, usage, foreign_events: foreign, turn_errors: acc.errors, model_rerouted: acc.rerouted,
      model_observed: { requested: rec.model, thread_echo: echo.model, rerouted_to: acc.rerouted.length ? acc.rerouted[acc.rerouted.length - 1].to : null } };
    base.subagent_activity = subagent;
    if (hookFilesBefore) {
      // turn 이 가드 스크립트·훅 정의를 바꿨으면 그 turn 의 나머지 도구 호출은 검사 없이 돌았을 수 있다 — 결과를 쓰지 않고, Shell 이 다음 단계 전달·세션 확정도 막는다.
      const after = hookFileHashes(rec);
      const changed = Object.keys(hookFilesBefore).filter((f) => hookFilesBefore[f] !== after[f]);
      base.hook_files = { changed, before: hookFilesBefore, after };
      if (changed.length && ['completed', 'failed', 'interrupted'].includes(status)) return await finish('REJECTED', 'CODEX_APP_SERVER_HOOK_FILES_CHANGED',
        `turn 전후로 가드 스크립트 또는 훅 정의가 바뀌었다(${changed.join(', ')}) — 결과를 쓰지 않는다`, EXIT.TURN_FAILED, base);
    }
    if (subagent.length && ['completed', 'failed', 'interrupted'].includes(status)) return await finish('REJECTED', 'CODEX_APP_SERVER_SUBAGENT_OBSERVED',
      `하위 Agent 금지 확인을 지났는데 turn 중 하위 Agent 활동이 관측됐다(${subagent.map((x) => x.what).join('; ')}) — 결과를 쓰지 않는다`, EXIT.TURN_FAILED, base);
    if (status === 'failed') return await finish('TURN_FAILED', 'CODEX_APP_SERVER_TURN_FAILED', turn?.error?.message || 'turn failed', EXIT.TURN_FAILED, base);
    if (status === 'interrupted') return await finish(serverRequests.length ? 'REJECTED' : 'TURN_FAILED', serverRequests.length ? 'CODEX_APP_SERVER_REQUEST_DENIED' : 'CODEX_APP_SERVER_TURN_INTERRUPTED',
      serverRequests.length ? `서버 요청 ${serverRequests.map((r) => r.method).join(',')} 을 수락하지 않고 turn 을 중단했다` : 'turn interrupted', EXIT.TURN_FAILED, base);
    if (status !== 'completed') return await unknown('CODEX_APP_SERVER_TURN_STATUS_UNEXPECTED', `turn.status=${status}`, base);
    if (corrupt) return await unknown('CODEX_APP_SERVER_EVENT_PARSE', 'turn 은 완료됐지만 이벤트 스트림에 읽을 수 없는 줄이 있어 최종 메시지를 확정할 수 없다(reconcile 로 thread 기록에서 확인)', base);
    if (serverRequests.length) return await finish('REJECTED', 'CODEX_APP_SERVER_REQUEST_DENIED', `서버 요청 ${serverRequests.map((r) => r.method).join(',')} — 자동 수락 없음`, EXIT.TURN_FAILED, base);
    if (acc.rerouted.length) return await finish('REJECTED', 'CODEX_APP_SERVER_MODEL_REROUTED', `요청 모델 ${rec.model} → ${base.model_observed.rerouted_to}`, EXIT.TURN_FAILED, base);
    if (acc.conflict) return await finish('REJECTED', 'CODEX_APP_SERVER_ITEM_CONFLICT', '같은 agentMessage item 이 서로 다른 내용으로 두 번 완료됐다', EXIT.TURN_FAILED, base);
    const fin = pickFinal(acc);
    if (!fin || fin.text.trim() === '') return await finish('REJECTED', 'CODEX_APP_SERVER_RESULT_MISSING', `완료된 최종 agentMessage 없음(완료 메시지 ${acc.messages}개)`, EXIT.TURN_FAILED, base);
    if (schema) {
      let parsed; try { parsed = JSON.parse(fin.text); } catch { parsed = undefined; }
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return await finish('REJECTED', 'CODEX_APP_SERVER_RESULT_NOT_JSON', '최종 메시지가 JSON 객체가 아니다(outputSchema 요청)', EXIT.TURN_FAILED, base);
    }
    writeAtomic(rec.result_tmp, fin.text);
    return await finish('RESULT_READY', 'OK', '', EXIT.OK, { ...base, final_message: { item_id: fin.id, phase: fin.phase, bytes: Buffer.byteLength(fin.text), sha256: sha256(fin.text), agent_messages: acc.messages } });
  } catch (e) {
    return await finish(sent ? 'UNKNOWN' : 'FAILED_BEFORE_SEND', 'CODEX_APP_SERVER_INTERNAL_ERROR', e?.stack || String(e), sent ? EXIT.UNKNOWN : EXIT.NOT_SENT);
  }
}

// 조회 전용 복구. 같은 thread id · turn id(또는 clientUserMessageId 로 결속된 turn) · prompt · 완료 결과의 증거가 모두 있을 때만 기록을 RESULT_READY 로 올린다.
// 증거가 없다는 것을 '실행되지 않았다'로 바꾸지 않는다 — 그 경우 기록은 그대로 두고 판정만 출력한다.
async function reconcile(recFile) {
  const j = new Journal(recFile); const rec = j.rec;
  const say = (verdict, detail, extra = {}) => { process.stdout.write(`${JSON.stringify({ verdict, detail, key: rec.key, invocation_id: rec.invocation_id, thread_id: rec.thread_id ?? null, turn_id: j.rec.turn_id ?? null, state: j.rec.state, ...extra })}\n`); return EXIT.OK; };
  if (!['SEND_UNCONFIRMED', 'RUNNING', 'UNKNOWN'].includes(rec.state)) return say('NOT_APPLICABLE', `상태 ${rec.state} 는 불명 상태가 아니다`);
  if (!rec.thread_id) return say('INSUFFICIENT_EVIDENCE', '기록에 thread id 가 없다');
  const base = `${rec.events_log}.reconcile-${Date.now()}`;
  const server = new AppServer({ bin: rec.codex_bin, args: serverArgs(rec, true), cwd: rec.project_root, eventsLog: `${base}.jsonl`, sentLog: `${base}.sent.jsonl`, stderrLog: `${base}.stderr.log` });
  const rpcMs = rec.timeouts?.rpc_ms ?? 120000;
  process.on('exit', () => server.kill());
  server.onServerRequest = (msg) => denyServerRequest(server, msg);
  const done = async (code) => { await server.shutdown(rec.timeouts?.shutdown_ms ?? 5000); return code; };
  try { await server.start(); } catch (e) { return say('QUERY_FAILED', `spawn: ${e.message}`); }
  try {
    await initialize(server, rec, rpcMs);
    const meta = await server.request('thread/read', { threadId: rec.thread_id, includeTurns: false }, rpcMs);
    if (meta?.thread?.id !== rec.thread_id) return await done(say('INSUFFICIENT_EVIDENCE', `thread/read 가 다른 thread 를 돌려줬다(${meta?.thread?.id})`));
    const itemsOf = async (turnId) => { const all = []; let cursor = null;
      for (let page = 0; page < 20; page += 1) { const r = await server.request('thread/items/list', { threadId: rec.thread_id, turnId, limit: 100, cursor }, rpcMs); for (const e of r?.data || []) if (e.turnId === turnId) all.push(e.item); cursor = r?.nextCursor ?? null; if (!cursor) break; }
      return all; };
    const hasClient = (items) => items.some((it) => it?.type === 'userMessage' && it.clientId === rec.invocation_id);
    let target = null, items = null, cursor = null, scanned = 0;
    outer: for (let page = 0; page < 5; page += 1) {
      const r = await server.request('thread/turns/list', { threadId: rec.thread_id, limit: 20, sortDirection: 'desc', itemsView: 'notLoaded', cursor }, rpcMs);
      for (const t of r?.data || []) {
        scanned += 1;
        if (rec.turn_id) { if (t.id === rec.turn_id) { target = t; break outer; } continue; }
        const its = await itemsOf(t.id); if (hasClient(its)) { target = t; items = its; break outer; }
      }
      cursor = r?.nextCursor ?? null; if (!cursor) break;
    }
    if (!target) return await done(say('NOT_FOUND', `thread 의 turn ${scanned}개 중 이 호출에 결속된 turn 을 찾지 못했다 — 미실행으로 단정하지 않는다(기록 그대로)`));
    items ||= await itemsOf(target.id);
    const userText = items.filter((it) => it?.type === 'userMessage').flatMap((it) => (it.content || []).filter((c) => c.type === 'text').map((c) => c.text)).join('');
    const evidence = { thread_id: rec.thread_id, turn_id: target.id, turn_status: target.status, client_id_match: hasClient(items), prompt_sha256_match: userText.length > 0 && sha256(userText) === rec.prompt_sha256 };
    if (!evidence.client_id_match && !evidence.prompt_sha256_match) return await done(say('INSUFFICIENT_EVIDENCE', '그 turn 의 사용자 메시지가 이 호출의 prompt 라는 증거(clientId·내용 지문)가 없다', { evidence }));
    if (target.status === 'inProgress') return await done(say('STILL_RUNNING', 'turn 이 아직 진행 중으로 기록돼 있다', { evidence }));
    if (target.status === 'failed' || target.status === 'interrupted') {
      j.transition('TURN_FAILED', { turn_id: target.id, turn_status: target.status, recovered: true, evidence, outcome: { code: 'CODEX_APP_SERVER_TURN_FAILED', detail: `reconcile: turn ${target.status}` } });
      return await done(say('TURN_FAILED', `turn 이 ${target.status} 로 끝났다 — 결과 없음`, { evidence }));
    }
    if (target.status !== 'completed') return await done(say('INSUFFICIENT_EVIDENCE', `turn.status=${target.status}`, { evidence }));
    const acc = newTurnAcc();
    for (const it of items) if (it?.type === 'agentMessage' && typeof it.text === 'string') { const m = { id: it.id, text: it.text, phase: it.phase ?? null }; acc.messages += 1; acc.lastAny = m; if (m.phase === 'final_answer') acc.lastFinal = m; }
    const fin = pickFinal(acc);
    if (!fin || fin.text.trim() === '') return await done(say('INSUFFICIENT_EVIDENCE', '완료 turn 에 최종 agentMessage 가 없다', { evidence }));
    if (rec.schema_file) { let p; try { p = JSON.parse(fin.text); } catch { p = undefined; } if (!p || typeof p !== 'object' || Array.isArray(p)) return await done(say('INSUFFICIENT_EVIDENCE', '최종 메시지가 JSON 객체가 아니다', { evidence })); }
    writeAtomic(rec.result_tmp, fin.text);
    j.transition('RESULT_READY', { turn_id: target.id, turn_status: 'completed', recovered: true, evidence,
      final_message: { item_id: fin.id, phase: fin.phase, bytes: Buffer.byteLength(fin.text), sha256: sha256(fin.text), agent_messages: acc.messages },
      usage: { source: 'reconcile', updates: 0, duplicates: 0, baseline_total: null, baseline_provenance: null, final_total: null, delta: null, context_last_turn: null, context_window: null, status: 'unavailable', error: 'USAGE_RECOVERED_NO_EVENTS' },
      outcome: { code: 'OK', detail: 'reconcile: 저장된 thread 기록에서 완료 결과를 복구했다(새 turn 없음)' } });
    return await done(say('RECOVERED', '완료 결과를 복구했다 — 재실행하면 새 turn 없이 이 결과가 호출자의 게이트로 간다', { evidence }));
  } catch (e) {
    return await done(say('QUERY_FAILED', e.message));
  }
}

// 조회 전용 판정(단독 명령 `codex-app-server.sh hooks`). initialize 와 hooks/list(cwd 기준)만 보낸다 — thread 를 만들지 않으므로 신뢰 등록 같은 부작용이 없다.
// 사양 파일: {project_root, codex_bin, required_hook, rpc_ms}. 한 줄 JSON 으로 판정을 출력한다. 종료 코드: 0 통과 / 10 통과 아님 / 2 사용법.
async function hooksCheck(specFile) {
  let rec; try { rec = JSON.parse(fs.readFileSync(specFile, 'utf8')); } catch (e) { diag(`사양 파일을 읽을 수 없다: ${e.message}`); return EXIT.USAGE; }
  const say = (v) => { process.stdout.write(`${JSON.stringify({ project_root: rec.project_root, required_hook: rec.required_hook, ...v })}\n`); return v.ok ? EXIT.OK : EXIT.NOT_SENT; };
  const early = requiredHookStaticCheck(rec);
  if (early) return say(early);
  const server = new AppServer({ bin: rec.codex_bin, args: ['app-server', '-c', 'sandbox_mode="read-only"', '-c', 'approval_policy="never"', '--listen', 'stdio://'], cwd: rec.project_root, eventsLog: '/dev/null', sentLog: '/dev/null', stderrLog: '/dev/null' });
  const rpcMs = rec.rpc_ms ?? 120000;
  process.on('exit', () => server.kill());
  server.onServerRequest = (msg) => denyServerRequest(server, msg);
  const unverified = (detail) => ({ ok: false, code: 'CODEX_APP_SERVER_HOOK_GATE_UNVERIFIED', reason: 'query_failed', detail, observed: null, checked_at: nowIso() });
  try { await server.start(); } catch (e) { return say(unverified(`spawn ${rec.codex_bin}: ${e.message}`)); }
  let verdict;
  try { await initialize(server, { opt_out_notifications: [] }, rpcMs); verdict = await verifyRequiredHook(server, rec, rpcMs, null); } catch (e) { verdict = unverified(`initialize: ${e.message}`); }
  await server.shutdown(5000);
  return say(verdict);
}

const [cmd, file] = process.argv.slice(2);
if (!['run', 'reconcile', 'hooks'].includes(cmd) || !file) { diag('사용: codex-app-server.mjs run|reconcile <turn-record.json> | hooks <spec.json>'); process.exit(EXIT.USAGE); }
if (Number(process.versions.node.split('.')[0]) < 18) { diag(`Node.js 18 이상이 필요하다(현재 ${process.versions.node})`); process.exit(EXIT.USAGE); }
(cmd === 'run' ? run(file) : cmd === 'reconcile' ? reconcile(file) : hooksCheck(file)).then((code) => process.exit(code), (e) => { diag(`치명적 오류: ${e?.stack || e}`); process.exit(EXIT.USAGE); });
