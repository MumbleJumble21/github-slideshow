#!/usr/bin/env node
// Public evidence contains an RSA-encrypted browser handoff and a safe status only.
import { spawn } from 'node:child_process';
import { constants, publicEncrypt } from 'node:crypto';
import {
  existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync,
} from 'node:fs';
import { release } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const VERSION = '0.162.1';
const HANDOFF_MS = 90_000;
const LOGIN_MS = 16 * 60_000;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const stripAnsi = (value) => value.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '');
let context;
let activeChild;
let verifiedVersion = null;

function parseArgs() {
  const [mode, ...args] = process.argv.slice(2);
  if (!['start', 'worker', 'wait'].includes(mode) || args.length !== 10) {
    throw new Error('invalid arguments');
  }
  const options = {};
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i];
    if (!['--platform', '--codex-js', '--root', '--public-key', '--evidence'].includes(key)
      || key in options || !args[i + 1]) throw new Error('invalid arguments');
    options[key] = args[i + 1];
  }
  const platform = options['--platform'];
  if (!['windows', 'macos', 'wsl2'].includes(platform)) throw new Error('invalid platform');
  for (const key of ['--codex-js', '--root', '--public-key', '--evidence']) {
    if (!path.isAbsolute(options[key])) throw new Error('absolute path required');
  }
  const root = path.resolve(options['--root']);
  const evidenceBase = path.resolve(options['--evidence']);
  const relative = path.relative(root, evidenceBase);
  // Never allow an artifact path to contain the private credential directory.
  const reverse = path.relative(evidenceBase, root);
  const contains = (value) => value === '' || (!value.startsWith(`..${path.sep}`)
    && value !== '..' && !path.isAbsolute(value));
  if (contains(relative) || contains(reverse)) throw new Error('overlapping paths');
  const evidence = path.join(evidenceBase, platform);
  return {
    mode, platform, root, evidence, originalArgs: args,
    codexJs: options['--codex-js'], publicKey: options['--public-key'],
    codexHome: path.join(root, 'codex-home'),
    handoff: path.join(evidence, 'device-login-encrypted.json'),
    result: path.join(evidence, 'account-login-result.json'),
    marker: path.join(root, 'account-login-started'),
  };
}

function atomicJson(filename, value) {
  mkdirSync(path.dirname(filename), { recursive: true, mode: 0o700 });
  const temporary = `${filename}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  renameSync(temporary, filename);
}

function saveResult(outcome, authenticated = false) {
  atomicJson(context.result, {
    platform: context.platform,
    version: verifiedVersion,
    authenticated,
    auth_method: authenticated ? 'chatgpt' : null,
    outcome,
  });
}

async function terminate(child) {
  if (!child?.pid) return;
  if (process.platform === 'win32') {
    await new Promise((resolve) => {
      const killer = spawn('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], {
        stdio: 'ignore', windowsHide: true,
      });
      killer.once('error', resolve);
      killer.once('close', resolve);
    });
  } else {
    try { process.kill(-child.pid, 'SIGTERM'); } catch { /* already exited */ }
    await sleep(250);
    try { process.kill(-child.pid, 'SIGKILL'); } catch { /* already exited */ }
  }
}

// Output never goes to a terminal, a file, a thrown error, or the public CI log.
function runPrivate(args, timeoutMs, onOutput) {
  return new Promise((resolve) => {
    const env = { ...process.env, CODEX_HOME: context.codexHome };
    delete env.OPENAI_API_KEY;
    delete env.CODEX_ACCESS_TOKEN;
    const child = spawn(process.execPath, [context.codexJs, ...args], {
      cwd: context.root, env, stdio: ['ignore', 'pipe', 'pipe'],
      detached: true, windowsHide: true,
    });
    activeChild = child;
    let output = '';
    let timedOut = false;
    let settled = false;
    const finish = (exitCode) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (activeChild === child) activeChild = undefined;
      resolve({ exitCode, output: stripAnsi(output), timedOut });
    };
    const timer = setTimeout(async () => {
      timedOut = true;
      await terminate(child);
      finish(null);
    }, timeoutMs);
    const collect = (chunk) => {
      // Bound retained private output even if an unexpected CLI becomes verbose.
      output = (output + chunk.toString('utf8')).slice(-65_536);
      if (onOutput) {
        try { onOutput(stripAnsi(output)); }
        catch {
          void terminate(child).then(() => finish(null));
        }
      }
    };
    child.stdout.on('data', collect);
    child.stderr.on('data', collect);
    child.once('error', () => finish(null));
    child.once('close', finish);
  });
}

function nativePlatformMatches() {
  if (context.platform === 'windows') return process.platform === 'win32';
  if (context.platform === 'macos') return process.platform === 'darwin';
  return process.platform === 'linux' && /microsoft.*wsl2|wsl2/i.test(release());
}

async function worker() {
  let outcome = 'setup_failed';
  let authenticated = false;
  try {
    if (!nativePlatformMatches()) {
      outcome = 'native_platform_mismatch';
      return;
    }
    mkdirSync(context.codexHome, { mode: 0o700 });
    // Pin disk storage so the ephemeral account never reaches an OS keychain.
    writeFileSync(path.join(context.codexHome, 'config.toml'),
      'cli_auth_credentials_store = "file"\nforced_login_method = "chatgpt"\n',
      { mode: 0o600 });
    const version = await runPrivate(['--version'], 30_000);
    if (version.exitCode !== 0
      || !version.output.split(/\r?\n/).includes(`codex-cli ${VERSION}`)) {
      outcome = 'version_check_failed';
      return;
    }
    verifiedVersion = VERSION;
    const publicKey = readFileSync(context.publicKey, 'utf8');
    let handedOff = false;
    let handoffFailed = false;
    const handoffTimer = setTimeout(() => {
      if (!handedOff) void terminate(activeChild);
    }, HANDOFF_MS);
    const login = await runPrivate(['login', '--device-auth'], LOGIN_MS, (output) => {
      if (handedOff || handoffFailed) return;
      // This pinned CLI prints the user code on its own line after this prompt.
      const match = output.match(/2\. Enter this one-time code[^\r\n]*\r?\n[ \t]*([A-Za-z0-9][A-Za-z0-9-]{3,63})[ \t]*\r?\n/);
      if (!match || !/^[ \t]*https:\/\/auth\.openai\.com\/codex\/device[ \t]*\r?$/m.test(output)) return;
      try {
        const ciphertext = publicEncrypt({
          key: publicKey, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256',
        }, Buffer.from(JSON.stringify({
          verification_url: 'https://auth.openai.com/codex/device', user_code: match[1],
        }))).toString('base64');
        atomicJson(context.handoff, {
          algorithm: 'RSA-OAEP-SHA256', platform: context.platform,
          created_at: new Date().toISOString(), ciphertext,
        });
        handedOff = true;
        clearTimeout(handoffTimer);
      } catch {
        handoffFailed = true;
        throw new Error('handoff failed');
      }
    });
    clearTimeout(handoffTimer);
    if (handoffFailed || !handedOff) {
      outcome = 'handoff_failed';
      return;
    }
    if (login.exitCode !== 0) {
      outcome = login.timedOut ? 'login_timeout' : 'login_failed';
      return;
    }
    const status = await runPrivate(['login', 'status'], 30_000);
    authenticated = status.exitCode === 0
      && status.output.split(/\r?\n/).includes('Logged in using ChatGPT');
    outcome = authenticated ? 'passed' : 'status_check_failed';
  } catch {
    // The exception might contain CLI output or filesystem/account details.
    outcome = 'setup_failed';
  } finally {
    await terminate(activeChild);
    try { rmSync(context.codexHome, { recursive: true, force: true }); }
    catch {
      authenticated = false;
      outcome = 'credential_cleanup_failed';
    }
    saveResult(outcome, authenticated);
  }
}

async function start() {
  mkdirSync(context.root, { recursive: true, mode: 0o700 });
  mkdirSync(context.evidence, { recursive: true, mode: 0o700 });
  if (existsSync(context.handoff) || existsSync(context.result)) throw new Error('stale evidence');
  writeFileSync(context.marker, 'started\n', { flag: 'wx', mode: 0o600 });
  let launchFailed = false;
  const background = spawn(process.execPath, [fileURLToPath(import.meta.url),
    'worker', ...context.originalArgs], {
    detached: true, stdio: 'ignore', windowsHide: true,
  });
  background.once('error', () => { launchFailed = true; });
  background.unref();
  const deadline = Date.now() + HANDOFF_MS + 40_000;
  while (Date.now() < deadline) {
    if (existsSync(context.handoff)) {
      process.stdout.write(`Encrypted ${context.platform} sign-in handoff is ready.\n`);
      return;
    }
    if (launchFailed || existsSync(context.result)) break;
    await sleep(250);
  }
  if (!existsSync(context.result)) {
    if (process.platform === 'win32') await terminate(background);
    else {
      try { background.kill('SIGTERM'); } catch { /* already exited */ }
      const stopDeadline = Date.now() + 3_000;
      while (!existsSync(context.result) && Date.now() < stopDeadline) await sleep(100);
      if (!existsSync(context.result)) await terminate(background);
    }
    rmSync(context.codexHome, { recursive: true, force: true });
    if (!existsSync(context.result)) saveResult('handoff_failed');
  }
  process.stdout.write(`Account sign-in handoff failed for ${context.platform}.\n`);
  process.exitCode = 1;
}

async function wait() {
  const deadline = Date.now() + LOGIN_MS + 60_000;
  while (Date.now() < deadline) {
    if (existsSync(context.result)) {
      const result = JSON.parse(readFileSync(context.result, 'utf8'));
      const passed = result.authenticated === true && result.outcome === 'passed';
      process.stdout.write(`ChatGPT account check ${passed ? 'passed' : 'failed'} for ${context.platform}.\n`);
      process.exitCode = passed ? 0 : 1;
      return;
    }
    await sleep(1_000);
  }
  process.stdout.write(`ChatGPT account check timed out for ${context.platform}.\n`);
  process.exitCode = 1;
}

try {
  context = parseArgs();
  if (context.mode === 'worker') {
    let stopping = false;
    const stop = async () => {
      if (stopping) return;
      stopping = true;
      await terminate(activeChild);
      try { rmSync(context.codexHome, { recursive: true, force: true }); }
      catch { /* The entire hosted runner is disposable. */ }
      try { saveResult('interrupted'); } catch { /* Do not print raw errors. */ }
      process.exit(1);
    };
    process.once('SIGTERM', stop);
    process.once('SIGINT', stop);
  }
  await ({ start, worker, wait }[context.mode])();
} catch {
  process.stdout.write('Account authentication setup failed.\n');
  process.exitCode = 1;
}
