#!/usr/bin/env node
/**
 * setup.sh / setup.ps1 共用的辅助逻辑。
 *
 * 两个平台的 setup 脚本只负责「外壳」（找 Node、npm install、写 .env、拉起进程、
 * 注册开机自启），凡是涉及 JSON / HTTP / 跨平台差异较细的部分都放在这里，
 * 这样 PowerShell 端不必重写一遍 JavaScript。
 *
 * 子命令：
 *   port <port>            端口是否空闲（退出码 0 空闲 / 2 占用）
 *   pick-port <port>       打印一个空闲端口：优先 <port>，占用则 8794..8899 依次尝试
 *   ensure-token [dir] [--no-print]
 *                          确保本地桥令牌文件存在（不存在则生成，权限 0600）。
 *                          默认打印**路径**（绝不打印令牌值）；--no-print 时完全不输出，
 *                          只靠退出码 —— 供不能安全捕获 stdout 的调用方使用。
 *   login [host] [port]    POST /v1/auth/device 打印登录链接，轮询直到登录成功
 *                          或 10 分钟过期；`--no-wait` 只打印链接不轮询
 *   chat [host] [port]     发一条最小的 chat 请求，断言回复包含「通了」
 *   is-bridge <port>       端口上是否为**本项目的桥**（GET /health 带 build 字段）。
 *                          退出码 0 是 / 2 不是（或有别的东西占着）/ 3 没东西监听
 *   noop                   运行环境正常即可（探针）
 *
 * 令牌读取顺序与 config.mjs 一致：环境变量 WORKBUDDY_LOCAL_TOKEN 优先，
 * 否则 ~/.workbuddy-bridge/bridge-token（可用 WORKBUDDY_DATA_DIR 覆盖）。
 * 本文件**永远不会把令牌写进 stdout/stderr**。
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import http from 'node:http';
import net from 'node:net';

const [, , command, ...rest] = process.argv;

/**
 * .env 里的键（只读、不写进程环境）。两个平台脚本都会先把端口写进 .env 再
 * 调这里；这样 `login` / `chat` 即使被 shell 漏传了 host/port，也只会用到
 * **实际生效的配置**，而不是悄悄回退到 8793。
 */
function dotEnvValue(key, root) {
  const file = join(root || process.env.WORKBUDDY_SETUP_ROOT || process.cwd(), '.env');
  try {
    for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
      const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
      if (!m || m[1] !== key) continue;
      return m[2].trim().replace(/^(['"])(.*)\1$/, '$2');
    }
  } catch { /* 没有 .env */ }
  return '';
}

function resolveTarget(host, port) {
  const h = host || dotEnvValue('WORKBUDDY_HOST') || '127.0.0.1';
  const p = port || dotEnvValue('WORKBUDDY_PORT') || '8793';
  return { host: h, port: p };
}

function fail(message, code = 1) {
  console.error(`[x] ${message}`);
  process.exit(code);
}

function tokenPath(dir = '') {
  if (process.env.WORKBUDDY_LOCAL_TOKEN) return '';
  const dataDir = dir
    ? resolve(dir)
    : (process.env.WORKBUDDY_DATA_DIR && process.env.WORKBUDDY_DATA_DIR.trim()
      ? resolve(process.env.WORKBUDDY_DATA_DIR.trim())
      : join(homedir(), '.workbuddy-bridge'));
  return join(dataDir, 'bridge-token');
}

/** 读令牌；失败返回空串（供探测用，不打印、不退出）。 */
function tryReadToken() {
  if (process.env.WORKBUDDY_LOCAL_TOKEN) return process.env.WORKBUDDY_LOCAL_TOKEN;
  try {
    const token = readFileSync(tokenPath(), 'utf8').trim();
    return /^[A-Za-z0-9._-]{16,}$/.test(token) ? token : '';
  } catch {
    return '';
  }
}

function readToken() {
  if (process.env.WORKBUDDY_LOCAL_TOKEN) return process.env.WORKBUDDY_LOCAL_TOKEN;
  const file = tokenPath();
  if (!existsSync(file)) fail(`本地令牌文件不存在：${file}（先启动一次桥或运行 ensure-token）`);
  const token = readFileSync(file, 'utf8').trim();
  if (!/^[A-Za-z0-9._-]{16,}$/.test(token)) fail(`本地令牌文件格式不正确：${file}`);
  return token;
}

function baseUrl(host = '127.0.0.1', port = '8793') {
  return `http://${host}:${port}`;
}

/** 无鉴权要求的最小探活端点；任何 HTTP 应答都说明该端口有（本项目的）服务。 */
function probeHttp(port) {
  return new Promise((resolveProbe) => {
    const req = http.request(
      { host: '127.0.0.1', port: Number(port), path: '/health', method: 'GET', timeout: 1500 },
      (res) => { res.resume(); resolveProbe(true); },
    );
    req.on('timeout', () => { req.destroy(); resolveProbe(false); });
    req.on('error', () => resolveProbe(false));
    req.end();
  });
}

/**
 * 端口状态：0 空闲 / 2 被占用。
 *
 * 先试 bind 再试 connect —— 只做 bind 会误判「由另一网络命名空间/别的用户
 * 持有」的监听端口（例如 Windows 上 Hyper-V 保留的端口段、Linux 容器宿主里
 * 已经存在的服务），后者在 bind 时可能拿到 EACCES 而非 EADDRINUSE。
 */
async function checkPort(port) {
  const bindStatus = await new Promise((resolvePort) => {
    const server = net.createServer();
    server.once('error', (err) => resolvePort(err.code === 'EADDRINUSE' ? 2 : 3));
    server.once('listening', () => server.close(() => resolvePort(0)));
    server.listen(Number(port), '127.0.0.1');
  });
  if (bindStatus === 2) return 2;
  if (bindStatus === 0) return 0;
  // bind 失败但不是 EADDRINUSE（EACCES 等）：再问一次 HTTP，能应答就当占用。
  return await probeHttp(port) ? 2 : 0;
}

async function pickPort(start) {
  const base = Number(start);
  for (let port = base; port <= base + 105; port += 1) {
    if (await checkPort(port) === 0) {
      console.log(port);
      return;
    }
  }
  fail(`端口 ${base}..${base + 105} 都被占用，请手动设置 WORKBUDDY_PORT`);
}

function ensureToken(dir = '', { print = true } = {}) {
  const say = (line) => { if (print) console.log(line); };
  if (process.env.WORKBUDDY_LOCAL_TOKEN) {
    say('env:WORKBUDDY_LOCAL_TOKEN');
    return;
  }
  const file = tokenPath(dir);
  if (existsSync(file)) {
    say(file);
    return;
  }
  mkdirSync(join(file, '..'), { recursive: true, mode: 0o700 });
  const token = randomBytes(24).toString('base64url');
  try {
    writeFileSync(file, `${token}\n`, { mode: 0o600, flag: 'wx' });
  } catch (e) {
    if (e?.code !== 'EEXIST') fail(`写令牌文件失败：${e.message}`);
  }
  say(file);
}

async function api(base, path, { token, method = 'GET', body } = {}) {
  const headers = { accept: 'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;
  if (body !== undefined) headers['content-type'] = 'application/json';
  const res = await fetch(`${base}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(20_000),
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { /* 非 JSON 原样返回文本 */ }
  return { status: res.status, ok: res.ok, data, text };
}

/**
 * 端口上跑的是不是本桥。桥的 /health 不需要令牌就会回状态码；带令牌时回
 * `{ok, pid, build, auth,…}`。`build` 是本桥特有的字段，用来区分「本桥」
 * 与「恰好占用了该端口的其它程序」—— 后者若被当成桥，会让我们跳过启动、
 * 再把 cc-haha 指到一个不是桥的地址上。
 */
async function isBridge(port) {
  const base = `http://127.0.0.1:${Number(port)}`;
  const token = tryReadToken();
  let res;
  try {
    res = await fetch(`${base}/health`, {
      headers: token ? { authorization: `Bearer ${token}` } : {},
      signal: AbortSignal.timeout(2000),
    });
  } catch (e) {
    return e?.name === 'TimeoutError' ? 2 : 3;
  }
  if (res.status === 401) {
    // 有令牌却 401 → 令牌不一致，不是（能用）的本桥；还没有令牌 → 无法确认，
    // 交给调用方的下一道判据（它们都在「启动之后」才用到这个结果）。
    return token ? 2 : 1;
  }
  let data = null;
  try { data = await res.json(); } catch { /* 非 JSON */ }
  return data && typeof data.build === 'string' && data.build ? 0 : 2;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

/** 等桥的 /health 可应答（桥先 listen、再读凭据，所以很快）。 */
async function waitBridge(base, timeoutMs = 20_000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      const r = await fetch(`${base}/health`, { signal: AbortSignal.timeout(2000) });
      // 没有令牌时 401 也说明端口已起来；桥令牌在这个时间点之前已经写好。
      if (r.status === 401 || r.ok) return true;
    } catch { /* 还没起来 */ }
    await sleep(400);
  }
  return false;
}

/** 当前是否已登录：返回账号展示名（uid 前 8 位兜底），未登录返回空串。 */
async function currentAccount(base, token) {
  try {
    const r = await api(base, '/v1/auth/credentials', { token });
    if (!r.ok || !Array.isArray(r.data?.credentials) || r.data.credentials.length === 0) return '';
    const active = r.data.credentials.find((c) => c && c.active) || r.data.credentials[0];
    if (!active || !active.uid) return '';
    // 昵称是打码过的（如 199****2769），可以直接展示；不再额外请求上游。
    return active.nickname || `${String(active.uid).slice(0, 8)}…`;
  } catch {
    return '';
  }
}

async function login(base, { noWait }) {
  const token = readToken();
  if (!await waitBridge(base)) fail(`桥没有在 ${base} 应答，先检查桥日志`);
  // 已经有可用凭据（桌面端登录文件或之前的插件登录）就不必再走设备码，
  // 直接确认身份 —— 重跑 setup 时这是常态，不该再弹一个登录链接。
  const who = await currentAccount(base, token);
  if (who) {
    console.log(`已登录：${who}，跳过设备登录`);
    return;
  }
  const started = await api(base, '/v1/auth/device', {
    token, method: 'POST', body: { region: process.env.WORKBUDDY_LOGIN_REGION || 'cn' },
  });
  if (!started.ok || !started.data?.state) {
    fail(`发起设备登录失败：HTTP ${started.status} ${started.data?.error || started.text.slice(0, 200)}`);
  }
  const { state, url, expiresAt } = started.data;
  // 直接写 stderr（同步、无缓冲）：管道/日志里也能第一时间看到链接。
  process.stderr.write(`登录链接：${url}\n`);
  process.stderr.write(`有效期至：${expiresAt}（10 分钟内有效，过期需重新运行）\n`);
  if (noWait) return;

  console.log('请在浏览器中打开上面的链接完成登录…（Ctrl+C 可跳过，稍后重跑 setup）');
  const deadline = Date.parse(expiresAt) || (Date.now() + 10 * 60 * 1000);
  let lastNote = 0;
  while (Date.now() < deadline) {
    await sleep(1500);
    let poll;
    try {
      poll = await api(base, `/v1/auth/device?state=${encodeURIComponent(state)}`, { token });
    } catch (e) {
      if (Date.now() - lastNote > 30_000) {
        lastNote = Date.now();
        console.log(`（轮询暂时失败，继续重试：${e.message}）`);
      }
      continue;
    }
    if (!poll.ok) {
      fail(`轮询登录失败：HTTP ${poll.status} ${poll.data?.error || poll.text.slice(0, 200)}（链接可能已过期，重跑 setup）`);
    }
    if (poll.data?.status === 'ready') {
      const name = poll.data.account?.nickname || poll.data.account?.uid || '已登录';
      console.log(`登录成功：${name}`);
      return;
    }
    const remain = Math.ceil((deadline - Date.now()) / 1000);
    if (remain % 60 === 0 && Date.now() - lastNote > 1000) {
      lastNote = Date.now();
      console.log(`仍在等待登录…（剩余约 ${remain} 秒）`);
    }
  }
  fail('登录链接已过期（10 分钟）。请重新运行 setup 获取新链接。', 3);
}

async function chat(base) {
  const token = readToken();
  if (!await waitBridge(base)) fail(`桥没有在 ${base} 应答`);
  const model = process.env.SETUP_SELFTEST_MODEL || 'deepseek-v4.1-flash';
  const r = await api(base, '/v1/chat/completions', {
    token,
    method: 'POST',
    body: {
      model,
      stream: false,
      max_tokens: 64,
      messages: [{ role: 'user', content: '只回复：通了' }],
    },
  });
  if (!r.ok) {
    const msg = r.data?.error?.message || r.text.slice(0, 300) || '';
    fail(`chat 自检失败：HTTP ${r.status} ${msg}`);
  }
  const content = r.data?.choices?.[0]?.message?.content;
  const answer = Array.isArray(content)
    ? content.map((c) => (typeof c === 'string' ? c : c?.text || '')).join('')
    : String(content ?? '');
  if (!answer.includes('通了')) {
    fail(`chat 自检未通过：回复中没有「通了」（模型 ${r.data?.model || model}，实际内容：${answer.slice(0, 120)}）`);
  }
  console.log(`自检通过：模型 ${r.data?.model || model} 回复了「通了」`);
}

switch (command) {
  case 'port':
    process.exit(await checkPort(rest[0] || '8793'));
    break;
  case 'pick-port':
    await pickPort(rest[0] || '8793');
    break;
  case 'ensure-token':
    ensureToken(rest.find((a) => !a.startsWith('--')), { print: !rest.includes('--no-print') });
    break;
  case 'login': {
    const t = resolveTarget(rest[0], rest[1]);
    await login(baseUrl(t.host, t.port), { noWait: rest.includes('--no-wait') });
    break;
  }
  case 'chat': {
    const t = resolveTarget(rest[0], rest[1]);
    await chat(baseUrl(t.host, t.port));
    break;
  }
  case 'is-bridge':
    process.exit(await isBridge(rest[0] || dotEnvValue('WORKBUDDY_PORT') || '8793'));
    break;
  case 'noop':
    // 确认 Node 版本、fetch 可用 —— setup 在进入正式流程前的探针。
    if (typeof fetch !== 'function') fail(`Node ${process.version} 没有内建 fetch，需要 Node >= 20`);
    break;
  default:
    fail(`未知子命令：${command || '(空)'}。可用：port | pick-port | is-bridge | ensure-token | login | chat | noop`);
}
