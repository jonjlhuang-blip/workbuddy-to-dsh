#!/usr/bin/env node
/**
 * 把 cc-haha 的默认 provider 切到本地 WorkBuddy 桥。由 setup.sh / setup.ps1 的
 * `--cchh` 调用。这样 Windows 端也不需要再写一遍 JSON 处理。
 *
 *   node cchh-config.mjs --dir <cc-haha 配置目录> --port <桥端口> --model <模型> [--stamp <时间戳>]
 *
 * 做什么：
 *   - providers.json：新增/更新自定义 provider `workbuddy-bridge`，设为 activeId。
 *     apiKey 留空 —— cc-haha 会把 apiKey 原样抄进环境变量，不展开文件路径或
 *     `$VAR`；令牌由使用者在启动时从令牌文件注入 ANTHROPIC_AUTH_TOKEN。
 *   - settings.json：model 与 ANTHROPIC_*MODEL 改为目标模型，关掉
 *     CC_HAHA_GROK_OAUTH_PROVIDER（否则 Grok OAuth 会抢聊天请求）。
 *   - 两文件都先备份成 `*.bak-<stamp>`。
 *
 * 幂等：重复运行只会得到同样的结果，不会重复备份（同一 stamp 的文件已存在则跳过）。
 */
import { copyFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const args = process.argv.slice(2);
const opt = (name, fallback = '') => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};

const dir = opt('--dir');
if (!dir) {
  console.error('[x] 缺少 --dir');
  process.exit(1);
}
const port = opt('--port', '8793');
const model = opt('--model', 'deepseek-v4.1-flash');
const stamp = opt('--stamp', '');
const dryRun = args.includes('--dry-run');
const PROVIDER_ID = 'workbuddy-bridge';
const providersFile = join(resolve(dir), 'providers.json');
const settingsFile = join(resolve(dir), 'settings.json');

function readJson(file, fallback) {
  if (!existsSync(file)) return fallback;
  // 去 BOM：Windows 记事本/部分编辑器会加，JSON.parse 不认。
  return JSON.parse(readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
}

function backup(file) {
  if (!existsSync(file)) return;
  const target = stamp ? `${file}.bak-${stamp}` : `${file}.bak`;
  if (existsSync(target)) return;
  copyFileSync(file, target);
  console.log(`    backup: ${target}`);
}

function writeJson(file, data) {
  writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`);
}

if (dryRun) {
  console.log(`    [dry-run] ${providersFile}: activeId=${PROVIDER_ID}, baseUrl=http://127.0.0.1:${port}, apiKey 留空`);
  console.log(`    [dry-run] ${settingsFile}: model=${model}, CC_HAHA_GROK_OAUTH_PROVIDER=0`);
  process.exit(0);
}

const providers = readJson(providersFile, {});
providers.schemaVersion ??= 8;
providers.providers = Array.isArray(providers.providers) ? providers.providers : [];
const entry = {
  id: PROVIDER_ID,
  presetId: 'custom',
  name: 'WorkBuddy Bridge',
  apiKey: '',
  authStrategy: 'auth_token',
  baseUrl: `http://127.0.0.1:${port}`,
  apiFormat: 'anthropic',
  runtimeKind: 'anthropic_compatible',
  models: { main: model, haiku: model, sonnet: model, opus: model },
  modelContextWindows: { [model]: 300000 },
  supportsNestedToolResultMedia: true,
  notes: 'Local WorkBuddy bridge. Token injected at launch from ~/.workbuddy-bridge/bridge-token via ANTHROPIC_AUTH_TOKEN; apiKey stays empty on disk.',
};
const idx = providers.providers.findIndex((p) => p && p.id === PROVIDER_ID);
if (idx >= 0) providers.providers[idx] = { ...providers.providers[idx], ...entry };
else providers.providers.push(entry);
providers.activeId = PROVIDER_ID;
if (Array.isArray(providers.providerOrder) && !providers.providerOrder.includes(PROVIDER_ID)) {
  providers.providerOrder.push(PROVIDER_ID);
}

const settings = readJson(settingsFile, {});
settings.model = model;
settings.env = settings.env && typeof settings.env === 'object' ? settings.env : {};
settings.env.ANTHROPIC_MODEL = model;
settings.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = model;
settings.env.ANTHROPIC_DEFAULT_SONNET_MODEL = model;
settings.env.ANTHROPIC_DEFAULT_OPUS_MODEL = model;
settings.env.CC_HAHA_GROK_OAUTH_PROVIDER = '0';
const ctxKey = 'CLAUDE_CODE_MODEL_CONTEXT_WINDOWS';
let windows = {};
try { windows = JSON.parse(settings.env[ctxKey] || '{}') || {}; } catch { windows = {}; }
windows[model] = 300000;
settings.env[ctxKey] = JSON.stringify(windows);

backup(providersFile);
backup(settingsFile);
writeJson(providersFile, providers);
writeJson(settingsFile, settings);
console.log(`    cc-haha: activeId=${PROVIDER_ID}, baseUrl=http://127.0.0.1:${port}, model=${model}`);
