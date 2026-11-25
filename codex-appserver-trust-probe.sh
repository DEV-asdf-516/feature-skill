#!/usr/bin/env bash
# Codex App Server: `thread/start` 가 그 cwd 를 trusted project 로 스스로 등록하는지, sandbox 별로 확인한다.
# 모델 호출 0회(turn 을 보내지 않는다). 사용자 전역 설정은 건드리지 않는다 — 임시 CODEX_HOME 과 임시 저장소만 쓴다.
# 사용: bash <이 파일>          (설치된 codex 바이너리 필요. CODEX_BIN 으로 다른 바이너리를 줄 수 있다)
#
# 왜 필요한가: 하네스는 trust 를 대신 승인하지 않는다는 규칙을 갖는다. 그런데 thread/start 자체가 설정에 신뢰 항목을 쓰면,
#   읽기 전용 역할(검증자·리뷰어)의 호출도 사용자가 승인한 적 없는 신뢰를 남긴다. 편집 역할은 필수 훅 게이트가 thread/start 앞에서 막는다.
# 출력: sandbox(read-only · workspace-write)마다 thread/start 전후의 임시 CODEX_HOME/config.toml 변화.
# 종료 코드: 0 = 관측 완료(등록 여부는 출력으로 본다) / 1 = 관측 실패 / 3 = 사용자 전역 설정이 바뀌었다(있어서는 안 된다)
set -u
bin="${CODEX_BIN:-codex}"
command -v "$bin" >/dev/null 2>&1 || { echo "[FAIL] codex 바이너리 없음: $bin" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo '[FAIL] node 없음' >&2; exit 1; }
real_home="${CODEX_HOME:-$HOME/.codex}"
sum() { if [ -f "$1" ]; then shasum -a 256 "$1" | cut -d' ' -f1; else echo absent; fi; }
real_before="$(sum "$real_home/config.toml")"
work="$(mktemp -d "${TMPDIR:-/tmp}/feature-codex-trust-probe-XXXXXX")" || exit 1
echo "codex: $("$bin" --version 2>/dev/null | head -1) / 임시 작업 위치: $work"

cat > "$work/probe.mjs" <<'EOF'
// initialize → thread/start(turn 없음) 만 보낸다. 결과는 한 줄 JSON.
import { spawn } from 'node:child_process';
const [bin, cwd, sandbox] = process.argv.slice(2);
const c = spawn(bin, ['app-server', '-c', `sandbox_mode="${sandbox}"`, '-c', 'approval_policy="never"', '--listen', 'stdio://'], { cwd, stdio: ['pipe', 'pipe', 'ignore'], env: process.env });
let buf = ''; const pend = new Map(); let seq = 0; const warnings = [];
c.stdout.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); if (!l.trim()) continue; let m; try { m = JSON.parse(l); } catch { continue; }
  if (m.method) { if (m.method === 'configWarning') warnings.push(String(m.params?.summary || '').slice(0, 120)); if (m.id !== undefined) c.stdin.write(JSON.stringify({ id: m.id, error: { code: -32601, message: 'probe does not handle server requests' } }) + '\n'); continue; }
  const p = pend.get(m.id); if (p) { pend.delete(m.id); p(m); } } });
const req = (method, params) => new Promise((res) => { const id = ++seq; pend.set(id, res); c.stdin.write(JSON.stringify({ id, method, params }) + '\n'); });
const done = (o) => { console.log(JSON.stringify({ sandbox, ...o, warnings })); try { c.stdin.end(); } catch {} setTimeout(() => { c.kill('SIGKILL'); process.exit(0); }, 1500); };
setTimeout(() => done({ ok: false, error: 'timeout' }), 40000).unref();
c.on('error', (e) => done({ ok: false, error: `spawn: ${e.message}` }));
const init = await req('initialize', { clientInfo: { name: 'trust-probe', title: null, version: '0' }, capabilities: { experimentalApi: false } });
if (init.error) done({ ok: false, error: `initialize: ${JSON.stringify(init.error)}` });
else {
  c.stdin.write(JSON.stringify({ method: 'initialized' }) + '\n');
  const th = await req('thread/start', { cwd, approvalPolicy: 'never', sandbox, ephemeral: false });
  done(th.error ? { ok: false, error: `thread/start: ${JSON.stringify(th.error).slice(0, 300)}` } : { ok: true, thread: th.result?.thread?.id ?? null });
}
EOF

rc=0
for sandbox in read-only workspace-write; do
  home="$work/home-$sandbox"; repo="$work/repo-$sandbox"
  mkdir -p "$home" "$repo" && git -C "$repo" init -q && printf 'x\n' > "$repo/a.txt"
  repo="$(cd "$repo" && pwd -P)"
  before="$(sum "$home/config.toml")"
  out="$(CODEX_HOME="$home" node "$work/probe.mjs" "$bin" "$repo" "$sandbox" 2>/dev/null)"
  after="$(sum "$home/config.toml")"
  echo "--- sandbox=$sandbox"
  echo "    호출: ${out:-출력 없음}"
  if ! printf '%s' "$out" | grep -q '"ok":true'; then echo "    [관측 실패] thread/start 가 성공하지 않았다 — 이 sandbox 의 등록 여부는 알 수 없다"; rc=1; continue; fi
  if [ "$before" = "$after" ]; then
    echo "    config.toml: 변화 없음($before) → 이 sandbox 의 thread/start 는 신뢰를 등록하지 않았다"
  else
    echo "    config.toml: $before → 바뀜. 임시 CODEX_HOME 에 쓰인 내용:"
    sed 's/^/      | /' "$home/config.toml"
    if grep -qF "$repo" "$home/config.toml" && grep -q 'trust_level' "$home/config.toml"; then echo "    → thread/start 가 이 cwd 를 스스로 trusted project 로 등록했다"; else echo "    → 바뀌었지만 이 cwd 의 trust 항목은 아니다"; fi
  fi
done
real_after="$(sum "$real_home/config.toml")"
if [ "$real_before" != "$real_after" ]; then echo "[FAIL] 사용자 전역 설정($real_home/config.toml)이 이 프로브 동안 바뀌었다 — 격리가 깨졌다." >&2; exit 3; fi
echo "사용자 전역 설정($real_home/config.toml): 불변"
echo "임시 파일은 남겨 둔다(직접 정리): $work"
exit "$rc"
